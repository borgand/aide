# PRD-00: Project Overview

## Overview

`aide` runs Claude Code inside a Docker container with a default-deny iptables firewall and no sudo. The container is the security boundary: Claude can do anything inside it, but nothing on the host changes without explicit volume mounts. The goal is to give engineers a powerful AI coding assistant without exposing the host machine to arbitrary network access or privilege escalation.

**Security is Key** in `aide` design - if `aide` fails at security, then it fails at it's sole purpose of existance.

## Requirements

- **FR-00-01** The system MUST run Claude Code as a non-root user inside a Docker container.
- **FR-00-02** The container MUST apply a default-deny outbound firewall before Claude Code starts.
- **FR-00-03** The container MUST fail to start if the firewall cannot be applied.
- **FR-00-04** The host filesystem MUST NOT be modified except through explicitly declared volume mounts.
- **FR-00-05** No secrets (API keys, credentials) MUST be hardcoded anywhere; all secrets pass through environment variables, mounted files, or socket forwarding (SSH agent case).
- **FR-00-06** The tool MUST support Linux and macOS hosts. Windows support should be attempted as long as it does not interfere with macOS/Linux and does not overly complicate the design.
- **FR-00-07** All third-party tool versions MUST be pinned and verified at build time to prevent supply-chain vulnerabilities. Version pinning is managed by [mise](https://mise.jdx.dev/) with lockfile-based integrity verification (SHA256, Cosign, SLSA).

## Design

### Architecture

```
Host
├── bin/aide           ← user entry point (bash script)
│   ├── parses flags
│   ├── loads aide.yaml / aide.local.yaml
│   ├── starts host-side socat proxies (SSH agent, K8s, LAN hosts)
│   └── docker run → Container
│
Container (docker run --cap-add NET_ADMIN --cap-add NET_RAW)
├── entrypoint.sh      ← runs as root
│   ├── init-firewall.sh   ← applies iptables rules; aborts on failure
│   ├── .claude.json persistence (inotifywait copy)
│   ├── settings.json merge (team policy + user prefs)
│   ├── mcp.json merge (image defaults + user servers)
│   ├── git identity forwarding
│   ├── SSH known_hosts persistence
│   ├── in-container socat proxies (K8s, LAN, SSH agent)
│   ├── Docker socket GID adjustment
│   └── exec gosu aide claude   ← drops to non-root
│
└── aide user (uid/gid 1000)
    └── claude         ← Claude Code
```

### Security Model

| Layer | Mechanism |
|-------|-----------|
| Process isolation | Docker container |
| Network isolation | Default-deny iptables + ipset domain allowlist |
| Privilege isolation | No sudo; root only for entrypoint init, then `gosu aide` |
| Policy enforcement | `settings.json` deny list wins over user preferences |
| Secret hygiene | ANTHROPIC_API_KEY via env var only |

### Design Principles

1. **Fail closed.** If the firewall cannot be applied, the container exits immediately rather than running unprotected.
2. **REJECT not DROP.** All denied traffic returns ICMP unreachable immediately, giving Claude fast feedback instead of hanging.
3. **Pinned versions.** Every tool is version-pinned via mise configuration files (`mise/*.toml`) with auto-generated lockfiles containing per-platform SHA256 checksums. Cosign/SLSA attestations are verified natively where available.
4. **No `curl | bash`.** All package installations use mise (aqua backend), signed APT repositories, or SHA256-verified downloads. Claude Code is installed via mise's aqua backend, not the native `curl | bash` installer.
5. **Minimal trust surface.** The `aide` user has no `sudo`, no `setuid` tools, and no writable paths outside `/workspace` and `/home/aide`.
6. **socat over DNAT.** Debian bookworm uses nf_tables, which does not support DNAT of loopback-destined traffic. socat proxies are used instead for K8s, LAN, and SSH agent forwarding.

### Technology Choices

| Component | Choice | Reason |
|-----------|--------|--------|
| Base image | debian:bookworm-slim | Stable LTS, minimal size, nf_tables kernel |
| Shell | Bash | Ubiquitous, no external deps |
| Firewall | iptables + ipset | Mature, flexible, supports hash:net sets |
| Privilege drop | gosu | Proper exec-based drop (not `su` wrapper) |
| Proxy | socat | Available as APT package, single binary, no daemon |
| Config | YAML subset | Human-readable; parsed with pure Bash (no YAML library) |

### Dependencies

- Docker (host): required to build and run the container
- NET_ADMIN + NET_RAW capabilities: required for iptables inside the container

## Acceptance Criteria

- `aide` runs Claude Code interactively in the current directory
- Outbound traffic to disallowed hosts fails with immediate ICMP reject
- `api.anthropic.com` is reachable from inside the container
- The container process runs as `aide` (uid 1000), not root
- The host filesystem is unchanged after container exit except for files in the mounted workspace

## Open Questions / Future Work

- Rootless Docker mode (podman) compatibility
- Incremental image rebuilds for faster iteration
