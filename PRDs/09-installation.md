# PRD-09: Installation

## Overview

aide is installed by cloning the repository and symlinking `bin/aide` into a directory on `$PATH`. The Docker image is built locally. Upgrading is a single `aide pull` command.

## Requirements

- **FR-09-01** Installation MUST NOT require root or sudo on the host.
- **FR-09-02** `aide` MUST work when invoked from any directory after installation.
- **FR-09-03** The ANTHROPIC_API_KEY MUST be set in the environment before using `aide`.
- **FR-09-04** `aide pull` MUST update the repository and rebuild the image in one command.

## Design

### Prerequisites

| Requirement | Notes |
|-------------|-------|
| Docker | Must be running; tested with Docker Desktop, Rancher Desktop, OrbStack, native Linux Docker |
| `~/bin` in `$PATH` | Standard for user-local binaries; add to shell profile if missing |
| `ANTHROPIC_API_KEY` | Set in shell profile or pass as env var |

**Optional (for network features):**
- `socat` — required for SSH agent forwarding on macOS, LAN host proxying, and local K8s access
- `kubectl` — required for kubeconfig server URL detection (local cluster proxy)

### Installation Steps

```bash
# 1. Clone the repository
git clone https://github.com/your-org/aide.git ~/aide

# 2. Create a symlink in ~/bin
mkdir -p ~/bin
ln -sf ~/aide/bin/aide ~/bin/aide

# 3. Verify ~/bin is in PATH (add to ~/.bashrc or ~/.zshrc if not)
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc  # or ~/.bashrc

# 4. Set your API key (add to shell profile for persistence)
export ANTHROPIC_API_KEY="sk-ant-..."

# 5. Build the Docker image
aide build

# 6. Test the installation
aide -p "Say hello"
```

### First Run

After installation, run `aide` from any project directory:

```bash
cd ~/projects/myapp
aide
```

Claude Code opens in the container with `~/projects/myapp` mounted at `/workspace`.

On first run:
- `bin/aide` creates `$AIDE_ROOT/.claude/` if it doesn't exist (e.g., `~/aide/.claude/`) — persistence directory
- The container applies the firewall and starts Claude Code
- Claude Code creates `~/.claude/settings.json` and `~/.claude.json` inside the container; these are persisted to `AIDE_ROOT/.claude/`

### Upgrading

```bash
aide pull
```

This runs `git pull --ff-only` in `AIDE_ROOT` and then rebuilds the Docker image. If you have local changes, the git pull will fail — stash or commit them first.

### Directory Structure After Install

```
~/aide/                          ← AIDE_ROOT (git repository)
├── bin/
│   └── aide                     ← main launcher script
├── Dockerfile
├── mise/                        ← mise tool version configs (split for Docker layer caching)
│   ├── runtimes.toml            ← Go, Node.js (rarely changes)
│   ├── runtimes.lock            ← lockfile with per-platform SHA256 checksums
│   ├── cli-tools.toml           ← kubectl, helm, kustomize, gh, glab, delta
│   ├── cli-tools.lock
│   ├── apps.toml                ← Claude Code (changes frequently)
│   └── apps.lock
├── entrypoint.sh
├── init-firewall.sh
├── statusline.py
├── settings.json                ← team policy (baked into image)
├── aide.yaml                    ← example project config
├── certs/                       ← optional CA certs (empty by default)
├── .claude/                     ← created on first run
│   ├── .claude.json             ← Claude Code session state (persisted)
│   ├── settings.json            ← user Claude Code settings
│   ├── mcp.json                 ← user MCP servers
│   ├── .ssh/
│   │   └── known_hosts          ← SSH host keys (persisted)
│   ├── commands/                ← custom slash commands
│   ├── skills/                  ← skill definitions
│   └── agents/                  ← agent definitions
├── skills-repo/                 ← shared skill library
└── commands-repo/               ← shared command library

~/bin/
└── aide -> ~/aide/bin/aide      ← symlink
```

### Per-Project Configuration

For projects that need specific settings (custom domains, Docker socket, kubeconfig), add `aide.yaml` to the project root:

```yaml
# myapp/aide.yaml
extra_domains:
  - api.mycompany.example.com
kube: ~/.kube/myapp-config
```

For engineer-specific settings that should not be committed:

```yaml
# myapp/aide.local.yaml (gitignored)
docker: rancher
extra_domains:
  - internal.mycompany.example.com
```

Add to `myapp/.gitignore`:
```
aide.local.yaml
firewall-domains.local.txt
.claude/
```

### Common Issues

**"Docker is not installed or not in PATH"**
Install Docker Desktop (macOS/Windows) or Docker Engine (Linux). Ensure the Docker daemon is running: `docker info`.

**"aide: image not found, building first..."**
Normal on first run — aide will automatically build the image. If it fails, run `aide build` manually to see the full error.

**"api.anthropic.com is not reachable"**
The firewall verification step is failing. Check:
1. `ANTHROPIC_API_KEY` is set correctly
2. Your network allows outbound HTTPS to `api.anthropic.com`
3. If behind a corporate proxy, inject the corporate CA cert (see PRD-01)

**SSH agent not forwarded (macOS)**
Install socat: `brew install socat`. Verify `$SSH_AUTH_SOCK` is set in your shell: `echo $SSH_AUTH_SOCK`.

**Local Kubernetes cluster not accessible**
Install socat and kubectl on the host. Ensure the kubeconfig is passed with `--kube` or `kube:` in `aide.yaml`. Check that the cluster is running: `kubectl get nodes`.

**Container runs as root (unexpected)**
Check that `entrypoint.sh` ends with `exec gosu aide "$@"`. If gosu is not installed in the image, the privilege drop is skipped. Rebuild with `aide build`.

### Uninstalling

```bash
# Remove the symlink
rm ~/bin/aide

# Remove the Docker image
docker rmi aide:latest

# Optionally remove the cloned repository
rm -rf ~/aide
```

## Acceptance Criteria

- `aide -p "echo hello"` runs successfully after following the installation steps above
- `aide build` completes without errors on a fresh clone
- `aide pull` updates the repository and rebuilds the image
- `aide` works from any directory (not just `AIDE_ROOT`)
- No root/sudo required at any point

## Open Questions / Future Work

- Homebrew formula for macOS installation
- `install.sh` script for one-command setup
- Automatic `~/bin` PATH detection and shell profile update
