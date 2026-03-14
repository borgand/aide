# PRD-01: Docker Image

## Overview

The Docker image packages Claude Code and all supporting tools into a reproducible, pinned environment. It is built from `debian:bookworm-slim`, uses [mise](https://mise.jdx.dev/) for declarative tool version management with integrity verification, creates a non-root `aide` user, and sets up user-space tools (Playwright browsers, zsh) as that user. The image is multi-arch (amd64 + arm64).

## Requirements

- **FR-01-01** All tool versions MUST be pinned in mise configuration files with a lockfile (`mise.lock`).
- **FR-01-02** Binary downloads MUST be verified against SHA256 checksums (enforced by mise's always-on checksum verification and Cosign/SLSA attestation support).
- **FR-01-03** Package installations MUST NOT use `curl | bash` patterns.
- **FR-01-04** The `aide` user MUST have uid/gid 1000 and no sudo access.
- **FR-01-05** The image MUST support `linux/amd64` and `linux/arm64`.
- **FR-01-06** Optional corporate CA certificates MUST be injectable at build time without modifying the Dockerfile.
- **FR-01-07** `ANTHROPIC_BASE_URL` MUST be locked to `https://api.anthropic.com` in the image ENV.
- **FR-01-08** The image MUST include a healthcheck that verifies Claude Code is running as the `aide` user.
- **FR-01-09** Docker layer structure MUST be optimized so that a version bump to one tool does not invalidate unrelated layers.

## Design

### Architecture

The Dockerfile uses a multi-stage build with mise as the tool manager. Tool installations are split across multiple stages by change frequency, so a version bump to one group does not invalidate Docker layer cache for others.

```
Stage 1: base
    Layer 0: CA certificates (optional)
    Layer 1: System packages (single RUN — apt cache cleaned)
    Layer 2: Non-root user creation
    Layer 3: Playwright system dependencies (as root)
    Layer 4: Environment variables

Stage 2: mise-runtimes (FROM base)
    Layer 5: Install mise
    Layer 6: COPY mise/runtimes.toml + mise/runtimes.lock
    Layer 7: mise install (Go, Node.js)

Stage 3: mise-cli-tools (FROM base)
    Layer 8: Install mise
    Layer 9: COPY mise/cli-tools.toml + mise/cli-tools.lock
    Layer 10: mise install (kubectl, helm, kustomize, gh, glab, delta)

Stage 4: mise-apps (FROM base)
    Layer 11: Install mise
    Layer 12: COPY mise/apps.toml + mise/apps.lock
    Layer 13: mise install (Claude Code)

Stage 5: final (FROM base)
    Layer 14: COPY --from=mise-runtimes (Go, Node.js)
    Layer 15: COPY --from=mise-cli-tools (kubectl, helm, etc.)
    Layer 16: COPY --from=mise-apps (Claude Code)
    Layer 17: User-space installs (as aide user)
        - Playwright MCP + Chromium browser
        - zsh + plugins (git, fzf) via zsh-in-docker (SHA256 verified)
    Layer 18: Copy scripts + policy files
```

### Layer Cache Optimization

The key insight is splitting mise configuration into **three files by change frequency**:

| Config file | Contents | Change frequency |
|---|---|---|
| `mise/runtimes.toml` | Go, Node.js | Rare (major LTS cycles) |
| `mise/cli-tools.toml` | kubectl, helm, kustomize, gh, glab, delta | Occasional (monthly) |
| `mise/apps.toml` | Claude Code | Frequent (weekly+) |

Each file is `COPY`'d in a separate builder stage. When only Claude Code's version changes, only `Stage 4: mise-apps` rebuilds — the runtime and CLI tool layers remain cached. Each config file has its own lockfile (`runtimes.lock`, `cli-tools.lock`, `apps.lock`).

### Version Pinning Strategy — mise

[mise](https://mise.jdx.dev/) is a Rust-based polyglot tool version manager that uses the [aqua standard registry](https://github.com/aquaproj/aqua-registry) as its default backend. It provides:

- **Always-on checksum verification** — SHA256 checksums enforced by default, no opt-in needed
- **Cosign / SLSA / Minisign / GitHub Artifact Attestation** verification — native Rust implementation, no external CLIs required
- **Auto-updating lockfile** — `mise.lock` generated on `mise install`, contains per-platform checksums and download URLs
- **Multi-arch** — transparent amd64/arm64 support via aqua registry platform detection
- **Renovate integration** — first-class [Renovate mise manager](https://docs.renovatebot.com/modules/manager/mise/) for automated version bumping with checksum updates

**`mise/runtimes.toml`:**
```toml
[tools]
node = "22"
go = "1.23.6"
```

**`mise/cli-tools.toml`:**
```toml
[tools]
kubectl = "1.32.2"
helm = "3.17.1"
kustomize = "5.5.0"
gh = "2.65.0"
glab = "1.52.0"
delta = "0.18.2"
```

**`mise/apps.toml`:**
```toml
[tools]
claude-code = "2.1.74"
```

Each file produces a corresponding `mise/<name>.lock` with per-platform SHA256 checksums. These lockfiles are committed to the repository.

### Dockerfile Structure

```dockerfile
FROM debian:bookworm-slim AS base

# --- Layer 0: CA certificates (optional) ---
COPY certs/ /tmp/extra-certs/
ARG EXTRA_CA_CERT_B64=""
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && if [ -n "$EXTRA_CA_CERT_B64" ]; then \
         echo "$EXTRA_CA_CERT_B64" | base64 -d > /usr/local/share/ca-certificates/corporate-ca.crt; \
       fi \
    && for f in /tmp/extra-certs/*.crt /tmp/extra-certs/*.pem /tmp/extra-certs/*.cer; do \
         [ -f "$f" ] && cp "$f" /usr/local/share/ca-certificates/"$(basename "$f" | sed 's/\.\(pem\|cer\)$/.crt/')"; \
       done; true \
    && update-ca-certificates \
    && rm -rf /tmp/extra-certs

# --- Layer 1: System packages ---
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl git jq socat gosu inotify-tools \
       iptables ipset dnsutils \
       zsh fzf \
    && rm -rf /var/lib/apt/lists/*

# --- Layer 2: Docker CLI (signed APT repo — not in mise, stays as APT) ---
RUN curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
       https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# --- Layer 3: Playwright system deps (must run as root) ---
RUN npx --yes playwright install-deps chromium

# --- Layer 4: Non-root user ---
RUN groupadd -g 1000 aide \
    && useradd -m -u 1000 -g aide -s /usr/bin/zsh aide \
    && mkdir -p /home/aide/.ssh /home/aide/.kube \
    && chmod 700 /home/aide/.ssh \
    && chown -R aide:aide /home/aide/.ssh /home/aide/.kube

# ======================================================================
# Builder stages — each installs a group of tools via mise
# ======================================================================

FROM base AS mise-runtimes
ARG MISE_VERSION=2025.3.0
RUN curl -fsSL https://mise.jdx.dev/install.sh.checksum | sh -s -- -v ${MISE_VERSION}
COPY mise/runtimes.toml /tmp/mise/.mise.toml
COPY mise/runtimes.lock /tmp/mise/mise.lock
RUN cd /tmp/mise && mise install --yes \
    && mise where node > /tmp/node-path \
    && mise where go > /tmp/go-path

FROM base AS mise-cli-tools
ARG MISE_VERSION=2025.3.0
RUN curl -fsSL https://mise.jdx.dev/install.sh.checksum | sh -s -- -v ${MISE_VERSION}
COPY mise/cli-tools.toml /tmp/mise/.mise.toml
COPY mise/cli-tools.lock /tmp/mise/mise.lock
RUN cd /tmp/mise && mise install --yes

FROM base AS mise-apps
ARG MISE_VERSION=2025.3.0
RUN curl -fsSL https://mise.jdx.dev/install.sh.checksum | sh -s -- -v ${MISE_VERSION}
COPY mise/apps.toml /tmp/mise/.mise.toml
COPY mise/apps.lock /tmp/mise/mise.lock
RUN cd /tmp/mise && mise install --yes

# ======================================================================
# Final stage — assemble from builders
# ======================================================================

FROM base AS final

# --- Layer 14-16: Copy tool installations from builder stages ---
COPY --from=mise-runtimes /root/.local/share/mise/installs/node/ /usr/local/lib/node/
COPY --from=mise-runtimes /root/.local/share/mise/installs/go/  /usr/local/go/
COPY --from=mise-cli-tools /root/.local/share/mise/installs/ /usr/local/share/mise-tools/
COPY --from=mise-apps /root/.local/share/mise/installs/claude-code/ /usr/local/lib/claude-code/

# --- Symlink binaries into PATH ---
RUN ln -sf /usr/local/lib/node/bin/* /usr/local/bin/ \
    && ln -sf /usr/local/go/bin/* /usr/local/bin/ \
    && for tool in kubectl helm kustomize gh glab delta; do \
         find /usr/local/share/mise-tools/ -name "$tool" -type f \
           -exec ln -sf {} /usr/local/bin/"$tool" \; ; \
       done \
    && ln -sf /usr/local/lib/claude-code/bin/claude /usr/local/bin/claude

# --- Environment variables ---
ENV ANTHROPIC_BASE_URL=https://api.anthropic.com \
    DISABLE_AUTOUPDATER=1 \
    PLAYWRIGHT_BROWSERS_PATH=/home/aide/.cache/ms-playwright \
    DEVCONTAINER=true \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PATH="/home/aide/.local/bin:/usr/local/go/bin:/usr/local/bin:${PATH}"

# --- Layer 17: User-space installs (as aide user) ---
USER aide
ARG ZSH_IN_DOCKER_VERSION=1.2.1
ARG ZSH_IN_DOCKER_SHA256_AMD64="<checksum>"
ARG ZSH_IN_DOCKER_SHA256_ARM64="<checksum>"
RUN npm config set prefix '/home/aide/.local' \
    && npm install -g "@playwright/mcp@0.0.68" \
    && npx playwright install chromium

# zsh-in-docker (SHA256 verified)
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) SHA256="${ZSH_IN_DOCKER_SHA256_AMD64}" ;; \
         arm64) SHA256="${ZSH_IN_DOCKER_SHA256_ARM64}" ;; \
       esac \
    && curl -fsSL "https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh" \
         -o /tmp/zsh-in-docker.sh \
    && echo "${SHA256}  /tmp/zsh-in-docker.sh" | sha256sum -c - \
    && bash /tmp/zsh-in-docker.sh -p git -p fzf \
    && rm /tmp/zsh-in-docker.sh

# --- Layer 18: Switch back to root for entrypoint ---
USER root
COPY entrypoint.sh init-firewall.sh statusline.py /usr/local/bin/
COPY settings.json /etc/aide/settings-policy.json
COPY mcp-defaults.json /etc/aide/mcp-defaults.json
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD pgrep -u aide claude || exit 1

ENTRYPOINT ["entrypoint.sh"]
CMD ["claude"]
```

### CA Certificate Support

Two mechanisms for injecting custom CA certificates (unchanged from previous design):

1. **Build-time directory**: Place `.crt`, `.pem`, or `.cer` files in `certs/` in the repository root. They are copied into the image and added to the system trust store.

2. **Build arg**: Pass `--build-arg EXTRA_CA_CERT_B64=<base64-encoded-cert>`. The `bin/aide build` subcommand handles encoding automatically when a cert file is found.

### Non-Root User

```dockerfile
RUN groupadd -g 1000 aide \
    && useradd -m -u 1000 -g aide -s /usr/bin/zsh aide \
    && mkdir -p /home/aide/.ssh /home/aide/.kube \
    && chmod 700 /home/aide/.ssh \
    && chown -R aide:aide /home/aide/.ssh /home/aide/.kube
```

No `sudoers` entry. No `setuid` binaries added.

### Environment Variables

```dockerfile
ENV ANTHROPIC_BASE_URL=https://api.anthropic.com \
    DISABLE_AUTOUPDATER=1 \
    PLAYWRIGHT_BROWSERS_PATH=/home/aide/.cache/ms-playwright \
    DEVCONTAINER=true \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PATH="/home/aide/.local/bin:/usr/local/go/bin:/usr/local/bin:${PATH}"
```

`ANTHROPIC_BASE_URL` is locked so it cannot be accidentally overridden to an untrusted endpoint. `DISABLE_AUTOUPDATER=1` prevents Claude Code from auto-updating inside the container (versions are managed by mise). `NODE_EXTRA_CA_CERTS` ensures Node.js tools respect the system CA bundle (important in corporate proxy environments).

### MCP Defaults

The image bakes in a default MCP server configuration at `/etc/aide/mcp-defaults.json`:

```json
{"mcpServers":{"playwright":{"command":"npx","args":["@playwright/mcp","--browser","chromium"]}}}
```

`entrypoint.sh` deep-merges this with the user's `mcp.json` at startup (user servers win on name collision).

### Healthcheck

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD pgrep -u aide claude || exit 1
```

### Tool Inventory

| Tool | Version source | Install method | Integrity verification |
|------|---------------|----------------|----------------------|
| Claude Code | `mise/apps.toml` | mise (aqua backend) | SHA256 + Cosign/SLSA |
| Go | `mise/runtimes.toml` | mise (core backend) | SHA256 + Cosign/SLSA |
| Node.js | `mise/runtimes.toml` | mise (core backend) | SHA256 |
| kubectl | `mise/cli-tools.toml` | mise (aqua backend) | SHA256 + Cosign/SLSA |
| helm | `mise/cli-tools.toml` | mise (aqua backend) | SHA256 + Cosign/SLSA |
| kustomize | `mise/cli-tools.toml` | mise (aqua backend) | SHA256 + Cosign/SLSA |
| GitHub CLI (gh) | `mise/cli-tools.toml` | mise (aqua backend) | SHA256 + Cosign/SLSA |
| GitLab CLI (glab) | `mise/cli-tools.toml` | mise (aqua backend) | SHA256 |
| git-delta | `mise/cli-tools.toml` | mise (aqua backend) | SHA256 |
| Docker CLI | APT (Docker signed repo) | APT | GPG-signed repo |
| Playwright + Chromium | npm (user-space) | npm install | npm checksums |
| zsh + plugins | Dockerfile ARG | SHA256-verified script | SHA256 (per-arch) |
| socat, gosu, jq, inotify-tools | system | APT | GPG-signed repo |

### Automated Version Updates — Renovate

Renovate has a [first-class mise manager](https://docs.renovatebot.com/modules/manager/mise/) that detects `.mise.toml` files and auto-creates PRs for version bumps. Configuration:

```json5
// renovate.json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "mise": {
    "fileMatch": ["mise/.+\\.toml$"]
  }
}
```

Renovate will:
- Detect new versions of all tools in the mise config files
- Create PRs that update version strings in `*.toml` files
- CI pipeline runs `mise install` to regenerate lockfiles with updated checksums
- No manual SHA256 maintenance required

### What Stays Outside mise

Two categories of tools are not managed by mise:

1. **Docker CLI** — Installed via Docker's signed APT repository. mise's aqua backend could manage it, but APT-based installation integrates better with Debian's package management and receives security patches via the standard APT update path.

2. **Playwright MCP + zsh-in-docker** — Installed as user-space packages (npm / script). Playwright MCP is an npm package that requires Node.js (provided by mise). zsh-in-docker is a one-off script with manual SHA256 verification.

### Dependencies

**Depends on:** Docker build environment, internet access to package registries (or a caching proxy for airgapped builds), mise registry (aqua standard registry on GitHub)

**Required by:** `entrypoint.sh`, `init-firewall.sh`, `bin/aide` (all run inside this image)

## Acceptance Criteria

- `docker build -t aide:latest .` completes without errors on amd64 and arm64
- `docker run --rm aide:latest id` outputs `uid=1000(aide)`
- `docker run --rm aide:latest which claude` returns a valid path
- `docker run --rm aide:latest go version` returns the version pinned in `mise/runtimes.toml`
- `docker run --rm aide:latest claude --version` returns the version pinned in `mise/apps.toml`
- `aide build` with a cert file in `certs/` produces an image with the cert in the trust store
- Bumping only the Claude Code version in `mise/apps.toml` does NOT invalidate the runtime or CLI tool layers
- All lockfiles (`mise/*.lock`) contain per-platform SHA256 checksums
- No `curl | bash` patterns appear in the Dockerfile (FR-01-03)
- Renovate detects all three mise config files and creates version bump PRs

## Open Questions / Future Work

- Airgapped builds: a private registry mirror for mise/aqua downloads
- Image size optimization: squash layers after all installs
- Moving Playwright MCP into mise once npm backend supports lockfile checksums for npm packages
- Evaluating `aqua cp` for even slimmer final images (trade-off: losing mise's npm backend)
