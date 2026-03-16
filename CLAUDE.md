# CLAUDE.md

## 1. Constitution

These rules are non-negotiable. Violating them is a showstopper.

- **Security is the product.** Never weaken the firewall, bypass privilege isolation, or introduce network access outside the allowlist. If a change touches `init-firewall.sh`, `entrypoint.sh`, or Docker capabilities — think twice.
- **Fail closed.** If a security mechanism cannot be applied, the system must abort — never fall back to an unprotected state.
- **No secrets in code.** API keys, tokens, and credentials must never be hardcoded. They flow through env vars, mounted files, or socket forwarding only.
- **No sudo for aide user.** The non-root `aide` user must never gain elevated privileges inside the container.
- **Run tests after every change.** After modifying any script or Dockerfile, run `./test/smoke-test.sh` against a fresh build to verify nothing is broken. If the image hasn't been rebuilt, build first with `bin/aide build` (or `docker build -t aide:latest .`).
- **Pin all versions.** Third-party tools are version-pinned via `mise/*.toml`. Never add unversioned `curl | bash` installs.

## 2. Project Overview

**aide** runs Claude Code inside a Docker container with a default-deny iptables firewall and no sudo. The container is the security boundary — Claude can do anything inside it, but nothing on the host changes without explicit volume mounts.

### Key files

| File | Purpose |
|------|---------|
| `bin/aide` | Host-side CLI launcher (Bash). Parses flags, loads config, starts socat proxies, runs `docker run`. |
| `Dockerfile` | Multi-stage build using mise for tool version management. Base is `debian:bookworm-slim`. |
| `entrypoint.sh` | Container init (runs as root). Applies firewall, merges settings/MCP, sets up proxies, drops to `aide` user via `gosu`. |
| `init-firewall.sh` | Default-deny iptables + ipset domain allowlist. Blocks IPv6. Verifies firewall works before proceeding. |
| `statusline.py` | Python status line for Claude Code (model, git, context, cost). |
| `aide.yaml` | Project config (Docker socket, kube, LAN hosts, extra domains). `aide.local.yaml` for local overrides. |
| `settings.json` | Claude Code policy (deny list wins over user prefs). Baked into image at `/etc/aide/settings-policy.json`. |
| `mcp-defaults.json` | Default MCP server config. Merged with user's at container start. |
| `mise/*.toml` | Tool version definitions: `runtimes.toml` (node, go), `cli-tools.toml` (kubectl, helm, etc.), `apps.toml` (claude). |
| `test/smoke-test.sh` | Post-build smoke tests (13 checks). Run as `./test/smoke-test.sh [image-name]`. |
| `PRDs/` | Design documents. `00-project-overview.md` is the authoritative architecture reference. |

### Architecture in a nutshell

Host (`bin/aide`) -> `docker run` with `NET_ADMIN`+`NET_RAW` -> `entrypoint.sh` (root: firewall + setup) -> `gosu aide claude` (unprivileged).

Network: default-deny iptables, allowed domains resolved to IPs in an ipset. REJECT (not DROP) for fast feedback. socat proxies for K8s, LAN hosts, and SSH agent forwarding (no DNAT — nf_tables limitation on bookworm).

## 3. Critical Memory

<!--
MAINTENANCE RULES FOR CLAUDE — read these every conversation, follow them exactly.

WHEN TO ADD AN ENTRY:
- You hit a non-obvious bug or failure mode (e.g., a command that silently breaks something).
- You discover a workaround that isn't documented anywhere in the codebase.
- A build, test, or runtime issue wastes significant debugging time and the root cause wasn't obvious.
- The user corrects your approach on something project-specific that you'd get wrong again.

WHEN TO UPDATE OR REMOVE AN ENTRY:
- The underlying code changed and the pitfall no longer applies — delete it.
- An entry is vague or stale — rewrite it to reflect current reality.
- Two entries overlap — merge them.

FORMAT — each entry is exactly:
  ### <short title>
  <1-3 sentences: what happens, why, and what to do instead>

RULES:
- Maximum 15 entries. If full, remove the least relevant one before adding.
- No generic advice ("write good code"). Only project-specific, hard-won knowledge.
- No duplicating information already in sections 1 or 2 above.
- Review this section at the start of every task. If you notice a stale entry, fix it immediately.
-->

*No entries yet. Claude will add lessons learned here as issues are encountered.*
