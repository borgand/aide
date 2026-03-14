# PRD-04: CLI Launcher

## Overview

`bin/aide` is the user-facing entry point. It is a Bash script that resolves its own location (following symlinks), parses flags, loads configuration files, assembles `docker run` arguments, starts host-side socat proxies, and launches the container. It handles subcommands (`build`, `pull`, `shell`) and the default run mode.

## Requirements

- **FR-04-01** `aide` MUST resolve its own location by following symlinks so it works when installed as a symlink in `~/bin`.
- **FR-04-02** `aide build` MUST rebuild the Docker image; `aide pull` MUST git-pull then rebuild.
- **FR-04-03** `aide shell` MUST open an interactive bash shell in the container with the same mounts as a normal run.
- **FR-04-04** `-p "prompt"` MUST run non-interactively (no TTY, no permission prompts).
- **FR-04-05** `--docker` MUST mount the Docker socket; `rancher` preset MUST resolve correctly per OS.
- **FR-04-06** `--kube` MUST mount the kubeconfig and start a socat proxy for local clusters.
- **FR-04-07** `--lan-host` MUST start a host-side socat proxy and pass the mapping to the container.
- **FR-04-08** All background socat proxies and temp files MUST be cleaned up on exit via a trap.
- **FR-04-09** The startup plan (active options) MUST be printed before `docker run`.
- **FR-04-10** `aide.yaml` and `aide.local.yaml` MUST be auto-loaded from `$PWD`; lists MUST append, scalars MUST override.

## Design

### Script Structure

```
bin/aide
├── AIDE_ROOT resolution (follow symlinks)
├── IMAGE_NAME="aide:latest"
├── Helper functions
│   ├── usage()
│   ├── die()
│   ├── parse_aide_config()
│   ├── load_project_config()
│   ├── resolve_docker_socket()
│   ├── extract_kube_server()
│   ├── is_local_server()
│   ├── extract_port()
│   ├── preflight()
│   ├── image_exists()
│   └── setup_docker_flags()
├── Subcommands
│   ├── cmd_build()
│   ├── cmd_pull()
│   └── cmd_run()     ← default; also handles shell mode
└── Main (case statement)
```

### AIDE_ROOT Resolution

The script must work when installed as a symlink (e.g., `~/bin/aide → /path/to/repo/bin/aide`):

```bash
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR=$(cd -P "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
AIDE_ROOT=$(cd -P "$(dirname "$SOURCE")/.." && pwd)
```

### Flag Reference

| Flag | Description |
|------|-------------|
| `build` | Rebuild the Docker image |
| `pull` | `git pull --ff-only` then rebuild |
| `shell` | Interactive bash shell (same mounts as run) |
| `-m <path>` | Mount `<path>` read-only at `/extra/<basename>` |
| `-mw <path>` | Mount `<path>` read-write at `/extra/<basename>` |
| `-p "prompt"` | Non-interactive mode; passes `-p` to Claude |
| `--caffeinate` / `-c` | Run under `caffeinate -i` (macOS only; prevents sleep) |
| `--dangerous` / `-d` | Pass `--dangerously-skip-permissions` to Claude |
| `--docker [rancher\|path]` | Mount Docker socket; `rancher` → `/var/run/docker.sock` (macOS) or `~/.rd/docker.sock` (Linux) |
| `--kube <path>` | Mount kubeconfig; auto-detects local clusters |
| `--host-ip <ip>` | Override host IP for socat binding |
| `--lan-host <host[:port]>` | Proxy a LAN host (default port 443) |
| `--config <path>` | Load project config from explicit path |
| `--` | Pass remaining args directly to `docker run` |
| `-h` / `--help` | Print usage |

### Config File Parsing

A pure-Bash subset YAML parser handles the `aide.yaml` schema. It recognizes these patterns:

```
docker: <value>           → scalar
kube: <value>             → scalar (~ expanded to $HOME)
host_ip: <value>          → scalar
extra_domains:            → list header
  - domain1               → list item
lan_hosts:                → list header
  - host:port             → list item
```

Any other line terminates the current list context. Comments (`#`) and blank lines are skipped.

```bash
parse_aide_config() {
  local file="$1" prefix="$2"
  local in_list="" docker_val="" kube_val="" host_ip_val="" domains_val="" lan_hosts_val=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    if [[ "$line" =~ ^docker:[[:space:]]*(.+)$ ]]; then
      docker_val="${BASH_REMATCH[1]}"; in_list=""
    elif [[ "$line" =~ ^kube:[[:space:]]*(.+)$ ]]; then
      kube_val="${BASH_REMATCH[1]/#\~/$HOME}"; in_list=""
    elif [[ "$line" =~ ^host_ip:[[:space:]]*(.+)$ ]]; then
      host_ip_val="${BASH_REMATCH[1]}"; in_list=""
    elif [[ "$line" =~ ^extra_domains:[[:space:]]*$ ]]; then
      in_list="domains"
    elif [[ "$line" =~ ^lan_hosts:[[:space:]]*$ ]]; then
      in_list="lan_hosts"
    elif [[ -n "$in_list" && "$line" =~ ^[[:space:]]+-[[:space:]]*(.+)$ ]]; then
      local item="${BASH_REMATCH[1]}"
      [[ "$in_list" == "domains"   ]] && domains_val="${domains_val:+$domains_val }$item"
      [[ "$in_list" == "lan_hosts" ]] && lan_hosts_val="${lan_hosts_val:+$lan_hosts_val }$item"
    else
      in_list=""
    fi
  done < "$file"

  printf -v "${prefix}_docker"        '%s' "$docker_val"
  printf -v "${prefix}_kube"          '%s' "$kube_val"
  printf -v "${prefix}_host_ip"       '%s' "$host_ip_val"
  printf -v "${prefix}_extra_domains" '%s' "$domains_val"
  printf -v "${prefix}_lan_hosts"     '%s' "$lan_hosts_val"
}
```

### Config Layering

```
load_project_config():
  1. Parse aide.yaml (or --config path) → base values
  2. Parse aide.local.yaml (only if using auto-discovery, not --config)
     - scalars: local overrides base
     - lists: local appended to base
  3. Warn if aide.local.yaml exists but is not in .gitignore
```

Priority (highest wins): `CLI flag > aide.local.yaml > aide.yaml > env var > default`

### Core Docker Flags

```bash
docker_flags=(
  --rm --init
  --cap-add=NET_ADMIN --cap-add=NET_RAW
  -v "$PWD:/workspace"
  -v "$AIDE_ROOT/.claude:/home/aide/.claude"
  -e ANTHROPIC_API_KEY
  -e "ANTHROPIC_BASE_URL=https://api.anthropic.com"
  -w /workspace
)
```

`--init` provides a proper PID 1 (tini) to reap zombie processes. `NET_ADMIN` + `NET_RAW` are required for iptables inside the container.

The `.claude` directory bind mount provides persistence for:
- `.claude.json` (Claude's state, via the inotifywait mechanism)
- `settings.json` (user preferences)
- `mcp.json` (user MCP servers)
- `.ssh/known_hosts` (SSH host keys)

### Build Subcommand

```bash
cmd_build() {
  local build_args=()
  # Auto-inject CA cert if present
  for f in "$AIDE_ROOT"/certs/*.crt "$AIDE_ROOT"/certs/*.pem "$AIDE_ROOT"/certs/*.cer; do
    [[ -f "$f" ]] && {
      build_args+=(--build-arg "EXTRA_CA_CERT_B64=$(base64 < "$f" | tr -d '\n')")
      break
    }
  done
  # AIDE_CA_CERT_FILE env var takes precedence
  [[ -n "${AIDE_CA_CERT_FILE:-}" ]] && \
    build_args+=(--build-arg "EXTRA_CA_CERT_B64=$(base64 < "$AIDE_CA_CERT_FILE" | tr -d '\n')")

  docker build -t "$IMAGE_NAME" "${build_args[@]}" "$AIDE_ROOT"
}
```

### Startup Plan Display

Before `docker run`, `cmd_run` prints a summary of active options:

```
aide: starting with:
  caffeinate       off
  docker           off
  kube             ~/.kube/config
  lan-host         none
  permissions      acceptEdits
```

### Cleanup Trap

A single `EXIT` trap kills all background socat processes and removes temp directories:

```bash
cleanup() {
  [[ -n "${SSH_PROXY_PID:-}"  ]] && kill "$SSH_PROXY_PID"  2>/dev/null || true
  [[ -n "${kube_proxy_pid:-}" ]] && kill "$kube_proxy_pid" 2>/dev/null || true
  [[ -n "${tmp_kube_dir:-}"   ]] && rm -rf "$tmp_kube_dir"              || true
  for _pid in "${lan_proxy_pids[@]+"${lan_proxy_pids[@]}"}"; do
    kill "$_pid" 2>/dev/null || true
  done
}
trap cleanup EXIT
```

### Docker Socket Resolution

```bash
resolve_docker_socket() {
  local val="$1"
  case "$val" in
    rancher)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "/var/run/docker.sock"   # Lima native socket
        return
      fi
      echo "$HOME/.rd/docker.sock"
      ;;
    *) echo "$val" ;;
  esac
}
```

**Pitfall — Rancher Desktop on macOS:** `~/.rd/docker.sock` is on the macOS filesystem, which Rancher's Lima VM shares via 9p/virtiofs. These filesystems do not support Unix domain sockets. Docker containers inside the Lima VM cannot bind-mount that path. Use `/var/run/docker.sock` instead — this is the Lima VM's native Docker socket and is directly accessible inside containers without cross-filesystem issues.

### Permission Modes

| Mode | Flag | Claude arg |
|------|------|------------|
| Default (interactive) | (none) | `--permission-mode acceptEdits` |
| Non-interactive | `-p` | `--permission-mode acceptEdits` |
| Dangerous | `--dangerous` / `-d` | `--dangerously-skip-permissions` |

### Git Identity Forwarding

```bash
git_name=$(git config --global user.name 2>/dev/null || true)
git_email=$(git config --global user.email 2>/dev/null || true)
[[ -n "$git_name"  ]] && docker_flags+=(-e "GIT_AUTHOR_NAME=$git_name" -e "GIT_COMMITTER_NAME=$git_name")
[[ -n "$git_email" ]] && docker_flags+=(-e "GIT_AUTHOR_EMAIL=$git_email" -e "GIT_COMMITTER_EMAIL=$git_email")
```

### Project Name

The current directory's basename is passed as `AIDE_PROJECT_NAME` so the statusline can display the real project name:

```bash
docker_flags+=(-e "AIDE_PROJECT_NAME=$(basename "$PWD")")
```

### Dependencies

**Depends on:** Docker CLI (`docker`), optional `socat`, optional `kubectl` (for kubeconfig server extraction), optional `python3` (for port allocation and host IP detection)

**Required by:** Users (direct invocation); see PRD-05 for config schema details, PRD-06 for network proxy details

## Acceptance Criteria

- `aide` starts Claude Code interactively with `$PWD` mounted at `/workspace`
- `aide build` rebuilds the image
- `aide pull` pulls the repo then rebuilds
- `aide shell` opens an interactive bash shell with the same mounts
- `aide -p "hello"` runs non-interactively and exits
- `aide --dangerous` skips permission prompts
- Background proxies are killed when `aide` exits (test by checking `pgrep socat` before and after)
- `aide.local.yaml` without a `.gitignore` entry produces a warning

## Open Questions / Future Work

- `aide update` self-update subcommand (currently `aide pull`)
- Windows host support (WSL2 path handling)
