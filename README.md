# aide

**Claude Code in a secured Docker container** — default-deny firewall, non-root execution, and domain allowlisting out of the box.

aide wraps Claude Code inside an isolated container so that AI-generated shell commands cannot reach arbitrary network destinations, escalate privileges, or tamper with your host. You get the full Claude Code experience — git, Node.js, Go, kubectl, Playwright — with hard network boundaries enforced by iptables before any user process starts.

### Key properties

- **Default-deny firewall** — only resolved IPs of explicitly allowed domains are reachable; everything else is rejected.
- **Non-root execution** — Claude Code runs as an unprivileged `aide` user via `gosu`.
- **Portable tooling** — Node.js 22, Go 1.24, kubectl, helm, gh, and more, managed by [mise](https://mise.jdx.dev) and baked into the image.
- **Zero host dependencies** — only Docker (or Rancher Desktop) is required on the host.

---

## How it works

```
┌─── Host ────────────────────────────────────────────────────┐
│                                                             │
│  aide CLI (bin/aide)                                        │
│    ├── parses aide.yaml / aide.local.yaml                   │
│    ├── starts socat proxies (SSH, K8s, LAN hosts)           │
│    └── docker run ──▶ ┌─── Container ───────────────────┐   │
│                       │                                 │   │
│                       │  entrypoint.sh (root)           │   │
│                       │    1. init-firewall.sh           │   │
│                       │       └── iptables default-deny  │   │
│                       │       └── ipset allowed-domains   │   │
│                       │       └── IPv6 fully blocked     │   │
│                       │    2. restore session tokens     │   │
│                       │    3. merge settings & MCP       │   │
│                       │    4. forward git identity       │   │
│                       │    5. set up SSH / K8s / LAN     │   │
│                       │    6. gosu aide ── claude         │   │
│                       │                                 │   │
│                       │  aide user (uid 1000)            │   │
│                       │    └── claude code (interactive) │   │
│                       └─────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Quick start

### Prerequisites

- **Docker** (Docker Desktop, Rancher Desktop, or Docker Engine on Linux)
- **macOS or Linux** host
- An **Anthropic API key** or an existing Claude session (`~/.claude.json`)

### Install

```bash
git clone <repo-url> ~/aide
ln -s ~/aide/bin/aide ~/bin/aide   # or anywhere on your PATH
```

### First run

- If using Claude Subscription, just run `aide` and follow the setup wizard to log in.
- If using API Key:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
cd ~/my-project
aide
```

On the first invocation, aide automatically builds the Docker image. Your current directory is mounted at `/workspace` inside the container.

### Non-interactive mode

```bash
aide -p "explain the main function in src/index.ts"
```

---

## CLI reference

```
Usage: aide [subcommand] [options] [-- docker-args...]

Subcommands:
  build         Rebuild the Docker image
  pull          git pull --ff-only then rebuild
  shell         Interactive bash shell (same mounts as run)

Options:
  -p "prompt"               Non-interactive mode
  -m <path>                 Mount <path> read-only at /extra/<basename>
  -mw <path>                Mount <path> read-write at /extra/<basename>
  -c, --caffeinate          macOS: prevent sleep during session
  -d, --dangerous           Skip permission prompts
  --docker [rancher|path]   Mount Docker socket
  --kube <path>             Mount kubeconfig; proxy local clusters
  --host-ip <ip>            Override host IP for socat binding
  --lan-host <host[:port]>  Proxy a LAN host (default port 443)
  --config <path>           Load project config from explicit path
  --                        Pass remaining args to docker run
  -h, --help                Show this help
```

### Examples

```bash
# Open a bash shell inside the container
aide shell

# Mount a directory read-only for reference
aide -m ~/shared-libs

# Mount a directory read-write
aide -mw ~/output

# Pass Docker socket for container-in-container workflows
aide --docker rancher

# Use a kubeconfig with automatic local-cluster proxying
aide --kube ~/.kube/config

# Proxy a LAN host through the firewall
aide --lan-host registry.internal:5000

# Pass extra flags to docker run
aide -- --cpus=4 --memory=8g
```

---

## Configuration

aide uses per-project YAML configuration files discovered from your current working directory.

### `aide.yaml`

Commit this to your repo for shared team settings.

```yaml
# Docker socket passthrough: "rancher" or absolute path
docker: rancher

# Kubeconfig path (~ expanded to $HOME)
kube: ~/.kube/config

# Override host IP for socat proxy binding
host_ip: 192.168.64.1

# Extra domains to add to the firewall allowlist
extra_domains:
  - registry.example.com
  - npm.pkg.github.com

# LAN hosts to proxy through the Docker bridge
lan_hosts:
  - harvester.local
  - myhost.local:8080
```

### `aide.local.yaml`

Personal/local overrides to project configuration.
Scalar values (docker, kube, host_ip) replace the base; list values (extra_domains, lan_hosts) are appended.
Keep this in `.gitignore`.

### Precedence

Settings are resolved in this order (highest wins):

1. CLI flags (`--docker`, `--kube`, etc.)
2. `aide.local.yaml`
3. `aide.yaml`
4. Environment variables (`AIDE_EXTRA_DOMAINS`)
5. Built-in defaults

Extra domains can also be specified via `firewall-domains.local.txt` (one domain per line) in the aide repo root, or the `AIDE_EXTRA_DOMAINS` environment variable. All sources are merged.

---

## Security model

### Default-deny firewall

The firewall is applied by `init-firewall.sh` as the very first step of container init, before any user process starts. It is **fail-closed** — if any rule fails to apply, the container exits.

#### Allowed domains (built-in)


| Domain                               | Purpose             |
| -------------------------------------- | --------------------- |
| `api.anthropic.com`                  | Claude API          |
| `claude.ai`                          | Claude web          |
| `auth.anthropic.com`                 | Authentication      |
| `statsig.anthropic.com`              | Feature flags       |
| `registry.npmjs.org`                 | npm packages        |
| `pypi.org`, `files.pythonhosted.org` | Python packages     |
| `proxy.golang.org`, `sum.golang.org` | Go modules          |
| `github.com`, `gitlab.com`           | Git hosting         |
| `objects.githubusercontent.com`      | GitHub raw content  |
| `playwright.azureedge.net`           | Playwright browsers |

Additional domains can be added via `extra_domains` in config, the `AIDE_EXTRA_DOMAINS` env var, or `firewall-domains.local.txt`.

#### How it works

1. All existing iptables rules are flushed (Docker DNS NAT rules are preserved).
2. IPv6 is **completely blocked** (DROP policy on all chains).
3. Loopback, DNS (UDP 53), and established connections are allowed.
4. The Docker bridge gateway is allowed (for host communication).
5. Feature-specific rules are added (SSH proxy, K8s proxy, LAN proxies).
6. Allowed domains are resolved to IPs and added to an `ipset`.
7. Default policies are set to **DROP** on INPUT, FORWARD, and OUTPUT.
8. Outbound traffic matching the ipset is allowed.
9. RFC-1918 private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) and link-local (`169.254.0.0/16`) are explicitly **REJECTED**.
10. All other traffic is **REJECTED**.
11. A verification step confirms TEST-NET (192.0.2.1) is unreachable and `api.anthropic.com:443` is reachable.

### Permission policy

Claude Code runs with `--permission-mode acceptEdits` by default. The container ships a settings policy (`settings.json`) that denies dangerous patterns:

```json
{
  "permissions": {
    "deny": [
      "Bash(rm -rf /)",
      "Bash(curl * | bash)",
      "Bash(wget * | bash)"
    ]
  }
}
```

User settings from `.claude/settings.json` are merged with the policy — allow lists are combined, and policy deny rules always apply.

### CA certificates

Corporate or self-signed CA certificates can be injected at build time so that tools running inside the container (curl, git, Node.js, Go, etc.) trust your internal PKI.

**Option 1 — drop files into `certs/`**

Place one or more `.crt`, `.pem`, or `.cer` files in the `certs/` directory before building:

```
certs/
└── my-corp-ca.crt
```

All files in `certs/` are copied into the image and registered with `update-ca-certificates`. Node.js is additionally pointed at the system bundle via `NODE_EXTRA_CA_CERTS`.

**Option 2 — `AIDE_CA_CERT_FILE` environment variable**

If you prefer not to keep the certificate in the repo, set `AIDE_CA_CERT_FILE` to its path before building:

```bash
export AIDE_CA_CERT_FILE=/path/to/my-corp-ca.crt
aide build
```

`AIDE_CA_CERT_FILE` takes precedence over any file in `certs/`. The certificate is passed to Docker as a base64-encoded build argument and is not stored outside the image.

> **Note:** `certs/` is listed in `.gitignore` (only the placeholder `certs/.gitkeep` is tracked) so certificates are never accidentally committed.

---

## Network features

### SSH agent forwarding

Your host SSH agent is automatically forwarded into the container.

- **macOS**: A socat TCP bridge proxies the Unix socket (virtiofs can't forward Unix sockets). Requires `socat` installed on the host.
- **Linux**: The SSH socket is bind-mounted directly.

### Docker socket passthrough

```bash
aide --docker rancher      # Uses ~/.rd/docker.sock
aide --docker /var/run/docker.sock
```

The container's `aide` user is automatically added to the Docker socket's group.

### Kubernetes proxying

```bash
aide --kube ~/.kube/config
```

If the kubeconfig points to a local cluster (`127.0.0.1` or `localhost`), aide starts a socat proxy chain:

1. **Host-side**: socat binds to the Docker bridge IP and forwards to the local K8s API.
2. **Container-side**: socat on `127.0.0.1` forwards to the host proxy through `host.docker.internal`.
3. The kubeconfig is rewritten to point to the proxied port.

Remote cluster kubeconfigs are mounted as-is.

### LAN host proxying

```bash
aide --lan-host registry.internal:5000
```

For each LAN host, aide:

1. Resolves the hostname on the host.
2. Starts a socat proxy on the Docker bridge IP.
3. Inside the container, adds the hostname to `/etc/hosts` pointing to `127.0.0.1` and starts a matching socat listener.

This lets the container reach LAN services that would otherwise be blocked by the RFC-1918 rejection rules.

---

## Bundled tools

All tools are installed at build time via [mise](https://mise.jdx.dev) and pinned to specific versions.

### Runtimes (`mise/runtimes.toml`)


| Tool    | Version |
| --------- | --------- |
| Node.js | 22      |
| Go      | 1.24    |

### CLI tools (`mise/cli-tools.toml`)


| Tool              | Version |
| ------------------- | --------- |
| kubectl           | latest  |
| helm              | latest  |
| kustomize         | latest  |
| gh (GitHub CLI)   | latest  |
| glab (GitLab CLI) | latest  |
| delta (git diff)  | latest  |

### Applications (`mise/apps.toml`)


| Tool        | Version          |
| ------------- | ------------------ |
| Claude Code | latest (via npm) |

### System packages

Installed via apt: `curl`, `git`, `jq`, `socat`, `gosu`, `inotify-tools`, `gnupg`, `iptables`, `ipset`, `dnsutils`, `bash`, `fzf`, `procps`, `python3`, Docker CLI.

---

## MCP servers & extensibility

### Default MCP servers

The container ships with Playwright MCP pre-configured in `mcp-defaults.json`:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp", "--browser", "chromium"]
    }
  }
}
```

Chromium is pre-installed via Playwright, including system dependencies.

### Adding custom MCP servers

Place your own `mcp.json` in `.claude/mcp.json` (mounted from the aide repo's `.claude/` directory). At container startup, the defaults and your custom servers are merged — your servers are added alongside Playwright.

### Custom skills

Place skill definitions in `.claude/skills/` to make them available inside the container. The `.claude/` directory is persisted across sessions.

---

## Status line

aide includes a custom status line (`statusline.py`) that displays:


| Segment  | Example                                | Description                         |
| ---------- | ---------------------------------------- | ------------------------------------- |
| Model    | `🔮 Claude Opus 4`                     | Current model with color coding     |
| Project  | `📁 my-project`                        | Working directory name              |
| Agent    | `🤖 code-reviewer`                     | Active subagent (if any)            |
| Git      | `🌿 main ✚2 ~1 ?3`                    | Branch, staged, modified, untracked |
| Context  | `████████░░░░░░░░ 50%` | Context window usage                |
| Cost     | `💰 $0.142`                            | Session cost                        |
| Duration | `⏱️ 5m 30s`                          | Session duration                    |

The status line updates every 5 seconds (cached) and is automatically configured via the settings merge at startup.

---

## Troubleshooting

### `aide: error: Docker is not installed or not in PATH`

Install Docker Desktop, Rancher Desktop, or Docker Engine.

### `aide: warning: ANTHROPIC_API_KEY is not set and no Claude session token found`

Either export `ANTHROPIC_API_KEY` or run `claude login` inside the container (use `aide shell`).

### `ERROR: firewall verification failed — api.anthropic.com not reachable`

DNS resolution of `api.anthropic.com` failed inside the container. Check your host DNS and network connectivity. If behind a corporate proxy, ensure the CA certificate is installed (see [CA certificates](#ca-certificates)).

### `ERROR: firewall verification failed — TEST-NET is reachable`

The firewall rules did not apply correctly. This indicates a serious problem — the container will refuse to start. Check that `NET_ADMIN` and `NET_RAW` capabilities are available (aide adds them automatically).

### `aide: warning: socat not installed; SSH agent forwarding disabled`

On macOS, install socat: `brew install socat`.

### `aide: warning: aide.local.yaml exists but is not in .gitignore`

Add `aide.local.yaml` to your project's `.gitignore` to avoid committing personal configuration.

### Session tokens not persisting

The `.claude/` directory in the aide repo root is mounted into the container. Ensure it exists and is writable. Session tokens from `~/.claude.json` are automatically persisted there via an inotify watcher.

---

## Project structure

```
├── bin/aide              # CLI launcher (bash)
├── Dockerfile            # Multi-stage build
├── entrypoint.sh         # Container init (firewall → settings → gosu)
├── init-firewall.sh      # iptables default-deny firewall
├── aide.yaml             # Example project config
├── settings.json         # Permission policy (deny rules)
├── mcp-defaults.json     # Default MCP server config
├── statusline.py         # ANSI status line for Claude Code
├── mise/
│   ├── runtimes.toml     # Node.js, Go versions
│   ├── cli-tools.toml    # kubectl, helm, gh, etc.
│   └── apps.toml         # Claude Code (npm)
├── certs/                # Drop CA certificates here
├── .claude/              # Persistent state (sessions, settings, MCP)
└── PRDs/                 # Design documents
```
