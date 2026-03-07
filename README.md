# aide

Claude Code in a secure, network-isolated Docker container.

`aide` (AI Dev Environment) is a thin wrapper that launches Claude Code inside a locked-down Docker container with an iptables firewall, an unprivileged user, and no sudo. Your current directory is mounted as `/workspace`; everything else on the host stays untouched.

## Quick Start

```bash
git clone https://github.com/borgand/aide.git ~/aide
~/aide/install.sh
aide
```

The installer symlinks `aide` into `~/bin`, builds the Docker image, and prints next steps. If `~/bin` is not on your `PATH`, add `export PATH="$HOME/bin:$PATH"` to your shell profile.

## What You Get

**Toolchain (pre-installed in the image):**

- Node.js 22.x
- Go 1.23.x
- Python 3 with venv and pipx
- Docker CLI (client only, no daemon)
- Playwright with headless Chromium
- git, git-delta, fzf, jq, zsh

**Security:**

- iptables default-deny firewall with a curated domain allowlist
- No sudo -- the `aide` user cannot modify firewall rules or install system packages
- `ANTHROPIC_BASE_URL` locked to `https://api.anthropic.com` (cannot be overridden by project config)
- Permissions policy (`settings.json`) denies reading `.env` files and `WebFetch`
- Broad command allow-list (git, kubectl, docker, go, python, npm, make, cargo, etc.) -- the container is the sandbox, not the permissions

## Usage

### Launch interactively

```bash
aide
```

Opens Claude Code in your current directory. The directory is mounted read-write at `/workspace` inside the container.

### Build the Docker image

```bash
aide build
```

Rebuilds the image from the Dockerfile. Normally only needed after editing the Dockerfile or firewall script.

### Update aide

```bash
aide pull
```

Runs `git pull --ff-only` on the aide repo, then rebuilds the image.

### Mount additional directories

```bash
aide -m ~/docs                  # read-only at /extra/docs
aide -mw ~/shared-libs          # read-write at /extra/shared-libs
```

You can pass `-m` or `-mw` multiple times.

### Non-interactive mode

```bash
aide -p "fix all failing tests and commit"
```

Sends the prompt directly to Claude Code and exits when done. Permissions are auto-accepted.

### Prevent machine sleep (macOS)

```bash
aide --caffeinate
```

Wraps the Docker run in `caffeinate` so the machine stays awake during long-running sessions.

### Pass extra Docker flags

```bash
aide -- --cpus=4 --memory=8g
```

Everything after `--` is forwarded verbatim to `docker run`.

## Adding Domains to the Allowlist

The firewall resolves domain names to IPs at container startup and blocks everything else.

**Default allowed domains:**

- `api.anthropic.com` -- Claude API
- `registry.npmjs.org` -- npm packages
- `pypi.org`, `files.pythonhosted.org` -- pip packages
- `proxy.golang.org`, `sum.golang.org` -- Go modules
- `github.com`, `objects.githubusercontent.com` -- git operations
- `playwright.azureedge.net` -- Playwright browser binaries

### Temporary: environment variable

Set `AIDE_EXTRA_DOMAINS` with a space-separated list of fully qualified domain names:

```bash
AIDE_EXTRA_DOMAINS="api.example.com registry.example.com" aide
```

This only applies to the current session.

### Permanent: edit the allowlist

Add entries to the `ALLOWED_DOMAINS` array in `init-firewall.sh` and rebuild:

```bash
# in init-firewall.sh
ALLOWED_DOMAINS=(
  api.anthropic.com
  ...
  api.example.com       # <-- add here
)
```

Then run `aide build` to bake the change into the image.

## Corporate Proxy / CA Certificates

If your network uses a TLS-intercepting proxy, aide can inject your corporate CA certificate into the image at build time.

**Option 1 -- Drop a certificate file into `certs/`:**

Place your `.crt`, `.pem`, or `.cer` file in the `certs/` directory at the root of the aide repo, then run `aide build`. The first matching certificate file found will be installed into the system trust store.

**Option 2 -- Use the `AIDE_CA_CERT_FILE` environment variable:**

```bash
AIDE_CA_CERT_FILE=/path/to/corporate-ca.pem aide build
```

The certificate is base64-encoded and passed as a Docker build argument. It takes precedence over files in `certs/`.

Both methods run `update-ca-certificates` during the build and also set `NODE_EXTRA_CA_CERTS` so Node.js (and Claude Code) trusts the certificate.

## SSH / Git Authentication for Private Repositories

aide forwards your host SSH agent into the container so private GitLab/GitHub repos work without putting credentials inside the image. The private key **never enters the container**.

### Setup

1. **Install `socat` on your Mac** (required for SSH agent forwarding):
   ```bash
   brew install socat
   ```

2. **Ensure your SSH key is loaded on the host:**
   ```bash
   ssh-add ~/.ssh/id_ed25519   # or id_rsa, etc.
   ssh-add -l                   # verify it's loaded
   ```

3. **Launch aide** — if `SSH_AUTH_SOCK` is set in your shell, the agent is forwarded automatically. No extra flags needed.

4. **Use SSH URLs** when cloning or installing plugins from private repos:
   ```bash
   # Instead of: https://gitlab.lhv.eu/group/repo.git
   /plugin marketplace add git@gitlab.lhv.eu:group/repo.git
   ```

   Or configure git to rewrite HTTPS → SSH for your GitLab host inside the container:
   ```bash
   git config --global url."git@gitlab.lhv.eu:".insteadOf "https://gitlab.lhv.eu/"
   ```

### How it works

On **Linux**, `bin/aide` bind-mounts the `SSH_AUTH_SOCK` socket directly into the container.

On **macOS**, Docker VMs (Docker Desktop, Rancher Desktop) cannot bind-mount Unix domain sockets. Instead, `aide` starts a `socat` TCP proxy on the host that bridges `SSH_AUTH_SOCK` to a TCP port. Inside the container, another `socat` instance creates a Unix socket that connects back to the host via `host.docker.internal`. The firewall allows this specific connection. No key material is copied.

> **macOS note:** Run `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` once to add your key to the Keychain — it will auto-load across reboots.

## Skills

Skills are reusable instruction sets that Claude Code auto-discovers from `~/.claude/skills/<name>/SKILL.md`. aide provides a simple distribution mechanism with two directories:

- **`skills-repo/`** (committed) -- library of all available team skills. Add here skills to be shared with upstream.
- **`skills/`** (gitignored) -- your active skills, bind-mounted into the container. Add your custom skills HERE.

### Activate a skill

```bash
cd ~/aide
ln -s ../skills-repo/my-skill skills/my-skill
```

### Deactivate a skill

```bash
rm skills/my-skill
```

### How it works

The `skills/` directory is mounted read-only at `~/.claude/skills/` inside the container. Claude Code automatically discovers any `SKILL.md` files within subdirectories. The installer activates all skills from `skills-repo/` by default.

### Creating a skill

Add a new subdirectory under `skills-repo/` with a `SKILL.md` file:

```
skills-repo/my-skill/SKILL.md
```

The `SKILL.md` file contains instructions that Claude Code will follow when the skill is active. Commit it to share with the team.

## Docker & Kubernetes

### Docker socket passthrough

Allow the agent to build images, run containers, and interact with Docker:

```bash
aide --docker rancher           # Rancher Desktop rootless socket (~/.rd/docker.sock)
aide --docker /path/to/sock     # Explicit socket path (any runtime)
```

Inside the container, `docker` CLI connects via `/var/run/docker.sock`. With Rancher Desktop's rootless socket the blast radius is contained to the Lima VM — the agent cannot access the host filesystem or processes. Mounting `/var/run/docker.sock` (system Docker) is effectively root-equivalent on the host; use it with that in mind.

### Kubernetes: remote cluster

Mount a kubeconfig read-only so `kubectl`, `helm`, and `kustomize` can reach a remote cluster:

```bash
aide --kube ~/.kube/config
```

The kubeconfig is mounted at `/home/aide/.kube/config` inside the container. You can pre-scope it to a service account with limited RBAC — the agent cannot exceed those permissions regardless of what it attempts.

> **Kubernetes firewall:** aide does not automatically allowlist your Kubernetes API server.
> Add the cluster hostname to `extra_domains` in `aide.yaml` or `firewall-domains.local.txt`.
> This is intentional — firewall changes require explicit acknowledgement and should not happen
> silently.

### Kubernetes: local cluster (localhost API server)

Rancher Desktop and similar tools expose K3s at `https://127.0.0.1:6443`. This address is the host's loopback — unreachable from inside a container.

When aide detects that the kubeconfig's current-context server is `localhost` or `127.0.0.1`, it automatically passes `AIDE_KUBE_LOCAL_PORT` into the container. The firewall startup script adds an iptables DNAT rule that transparently forwards `127.0.0.1:PORT` → `host.docker.internal:PORT`. The kubeconfig is mounted unmodified — no rewriting required.

No extra firewall configuration is needed for local K8s; `host.docker.internal` is already in the gateway subnet allowlist.

### Project config: aide.yaml

Commit an `aide.yaml` to your project repo to set defaults for everyone on the team:

```yaml
# aide.yaml
docker: rancher                    # or /path/to/docker.sock
kube: ~/.kube/contexts/myproject.yaml  # path to kubeconfig (~ expanded)
extra_domains:                     # appended to firewall allowlist
  - my-registry.example.com
  - dev-cluster.internal.example.com
```

aide auto-loads `aide.yaml` from the current directory on every run.

### Per-engineer overrides: aide.local.yaml

Create `aide.local.yaml` alongside `aide.yaml` for machine-specific overrides (different kubeconfig path, local mirror domains, etc.). **Add it to `.gitignore`** — it is not committed.

```yaml
# aide.local.yaml  (gitignored)
kube: ~/.kube/contexts/myproject-personal.yaml
extra_domains:
  - internal-mirror.lan
```

Scalar fields (`docker`, `kube`) in `aide.local.yaml` win over `aide.yaml`. `extra_domains` lists are **appended** (base + local).

Use `--config <path>` to load a config from an explicit path, bypassing CWD auto-discovery (including `aide.local.yaml`):

```bash
aide --config /path/to/custom-aide.yaml
```

## VS Code Devcontainer

The repository includes a `devcontainer.json` for use with VS Code's Dev Containers extension. Open the aide repo in VS Code, choose "Reopen in Container", and you get the same isolated environment with zsh as the default terminal. The container receives `NET_ADMIN` and `NET_RAW` capabilities for the firewall, and runs as the `aide` user.

## Security Model

1. The container starts as `root`. The entrypoint script (`entrypoint.sh`) calls `init-firewall.sh` to apply iptables rules, then drops privileges to the unprivileged `aide` user via `gosu`.
2. The `aide` user has no sudo access. Claude Code cannot modify firewall rules, install system packages, or escalate privileges.
3. The firewall sets the default iptables OUTPUT policy to DROP, then allows outbound connections only to the resolved IPs of domains in the allowlist. Blocked connections receive REJECT (not DROP) for fast failure feedback instead of timeouts.
4. IPv6 is blocked entirely (default DROP on all ip6tables chains).
5. `ANTHROPIC_BASE_URL` is set to `https://api.anthropic.com` by the wrapper script and locked in the container environment. Project-level `.env` files or Claude Code settings cannot override it.
6. The permissions policy in `settings.json` is merged into user settings at startup. Team policy wins on conflicts.

If the firewall fails to apply, the entrypoint aborts and Claude Code does not start.

## Persistence

**Persists across runs (Docker volume `aide-claude`):**

- `~/.claude/` directory (Claude Code config, authentication, conversation history)
- `~/.claude.json` (symlinked into the volume)
- `settings.json` (merged from team policy on each startup)

**Does not persist:**

- Installed packages (pip, npm, go modules) -- reinstalled each session unless cached in the image
- Files outside `/workspace` and `/extra` mounts
- Firewall rules -- reapplied on every container start
- The container itself (`--rm` ensures cleanup)

Your project files in the mounted working directory persist because they live on the host filesystem.
