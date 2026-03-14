# PRD-03: Entrypoint

## Overview

`entrypoint.sh` is the container init process. It runs as root, applies the firewall, sets up persistence and proxy infrastructure, merges configuration files, then drops privileges to the `aide` user and execs Claude Code. Every step that fails terminates the container immediately (`set -euo pipefail`).

## Requirements

- **FR-03-01** The entrypoint MUST apply the firewall as its first action; container MUST abort if firewall fails.
- **FR-03-02** `.claude.json` MUST be persisted across container restarts via the bind-mounted `.claude/` directory.
- **FR-03-03** Team policy (`settings.json`) MUST be merged with user settings; the deny list MUST win.
- **FR-03-04** The `permissions.allow` array MUST be deduplicated after merge.
- **FR-03-05** MCP defaults MUST be deep-merged with user `mcp.json`; user-defined servers MUST win on name collision.
- **FR-03-06** Git identity (`user.name`, `user.email`) MUST be forwarded into the container via env vars and written to git config.
- **FR-03-07** SSH `known_hosts` MUST persist across restarts via the `.claude/.ssh/known_hosts` path.
- **FR-03-08** Privileges MUST be dropped via `exec gosu aide "$@"` as the final step.
- **FR-03-09** In-container socat proxies MUST be started for K8s and LAN hosts if the corresponding env vars are set.
- **FR-03-10** Docker socket GID MUST be detected and applied dynamically if `/var/run/docker.sock` is mounted.

## Design

### Initialization Sequence

```
Step 1:  /usr/local/bin/init-firewall.sh          (abort on failure)
Step 2:  .claude.json copy from store              (if store exists)
Step 3:  inotifywait background watcher            (persist on every rename)
Step 3a: gosu aide mkdir -p /home/aide/.claude     (must exist before settings merge writes files)
Step 4:  settings.json merge                       (policy + statusline + user prefs)
Step 5:  mcp.json merge                            (image defaults + user servers)
Step 6:  Git identity forwarding                   (env vars → git config --global)
Step 7:  SSH known_hosts persistence               (symlink + ssh config)
Step 8:  K8s in-container socat proxy              (if AIDE_KUBE_LOCAL_PORT set)
Step 9:  LAN host socat proxies                    (if AIDE_LAN_PROXIES set)
Step 10: SSH agent TCP-to-Unix proxy               (if SSH_AGENT_PROXY_PORT set)
Step 11: Docker socket GID adjustment              (if /var/run/docker.sock mounted)
Step 12: exec gosu aide "$@"                       (privilege drop; CMD = claude)
```

### .claude.json Persistence

Claude Code writes `~/.claude.json` atomically via `rename()` (write to temp file, then rename). A rename in the container's overlay filesystem replaces any symlink at that path with a fresh inode — the new inode is invisible on the host mount. A bind mount on the `.claude/` directory (not the file) resolves this.

**Approach:**
1. On startup, copy the persisted file into the container's home directory.
2. Use `inotifywait` in background to detect every `moved_to` event on `/home/aide/`, which corresponds to a `rename()` completing.
3. On each event matching `.claude.json`, copy the file to the bind-mounted store.

```bash
CLAUDE_JSON=/home/aide/.claude.json
CLAUDE_JSON_STORE=/home/aide/.claude/.claude.json

if [[ -s "$CLAUDE_JSON_STORE" ]]; then
  gosu aide cp "$CLAUDE_JSON_STORE" "$CLAUDE_JSON"
fi

(
  inotifywait -q -m -e moved_to --format '%f' /home/aide/ 2>/dev/null | \
  while IFS= read -r fname; do
    [[ "$fname" == ".claude.json" ]] || continue
    gosu aide cp -f "$CLAUDE_JSON" "$CLAUDE_JSON_STORE" 2>/dev/null || true
  done
) &
```

**Pitfall:** Do not use a symlink at `/home/aide/.claude.json → /home/aide/.claude/.claude.json`. Claude's `rename()` will replace the symlink with a regular file in the overlay layer, breaking persistence immediately.

### Settings Merge

Three JSON objects are merged in order:
1. `$USER_SETTINGS` — user's existing `~/.claude/settings.json` (if present)
2. `$POLICY` — `/etc/aide/policy.json` (team policy; deny list, immutable permissions)
3. `$STATUSLINE` — `{"statusLine":{"type":"command","command":"/usr/local/bin/aide-statusline"}}`

The merge uses `jq -s` with object merge (`*`), which means later objects win on key conflicts. The `permissions.allow` array is explicitly deduplicated:

```bash
POLICY=/etc/aide/policy.json
STATUSLINE='{"statusLine":{"type":"command","command":"/usr/local/bin/aide-statusline"}}'
USER_SETTINGS=/home/aide/.claude/settings.json

jq -s '
  .[0] as $user | .[1] as $policy
  | .[0] * .[1] * .[2]
  | .permissions.allow = ((($user.permissions.allow // []) + ($policy.permissions.allow // [])) | unique)
' "$USER_SETTINGS" "$POLICY" <(echo "$STATUSLINE") > /tmp/aide-settings.json \
  && gosu aide mv /tmp/aide-settings.json "$USER_SETTINGS"
```

If no user settings exist yet, merge policy + statusline only:
```bash
jq -s '.[0] * .[1]' "$POLICY" <(echo "$STATUSLINE") > /tmp/aide-settings.json \
  && gosu aide mv /tmp/aide-settings.json "$USER_SETTINGS"
```

### MCP Merge

Image defaults (`/etc/aide/mcp-defaults.json`) are merged with the user's `mcp.json`. The user wins on name collision (user config is on the right side of `*`):

```bash
MCP_DEFAULTS=/etc/aide/mcp-defaults.json
MCP_USER=/home/aide/.claude/mcp.json

if [[ -f "$MCP_USER" ]]; then
  jq -s '.[0] * .[1]' "$MCP_DEFAULTS" "$MCP_USER" > /tmp/aide-mcp.json \
    && gosu aide mv /tmp/aide-mcp.json "$MCP_USER"
else
  gosu aide cp "$MCP_DEFAULTS" "$MCP_USER"
fi
```

**Pitfall:** Do not use a shallow merge (replace) for MCP servers. A shallow merge would overwrite the entire `mcpServers` object, losing user-defined servers. Use `jq -s '.[0] * .[1]'` for deep merge.

### Git Identity

Host git identity is forwarded into the container via `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` environment variables (set by `bin/aide`). The entrypoint writes them to `git config --global` and then unsets the env vars so workspace-level `.gitconfig` can override:

```bash
if [[ -n "${GIT_AUTHOR_NAME:-}" || -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
  [[ -n "${GIT_AUTHOR_NAME:-}" ]]  && gosu aide git config --global user.name  "$GIT_AUTHOR_NAME"
  [[ -n "${GIT_AUTHOR_EMAIL:-}" ]] && gosu aide git config --global user.email "$GIT_AUTHOR_EMAIL"
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
fi
```

`git config --global` with separate `user.name` and `user.email` calls avoids injection via newlines in the value.

### SSH known_hosts Persistence

SSH host keys are stored in the `.claude/.ssh/known_hosts` path (inside the bind-mounted `.claude/` directory) and symlinked from `/home/aide/.ssh/known_hosts`. An SSH config entry provides belt-and-suspenders coverage:

```bash
SSH_KNOWN_HOSTS_STORE=/home/aide/.claude/.ssh/known_hosts
gosu aide mkdir -p /home/aide/.claude/.ssh
gosu aide touch "$SSH_KNOWN_HOSTS_STORE"
gosu aide chmod 600 "$SSH_KNOWN_HOSTS_STORE"

rm -f /home/aide/.ssh/known_hosts
ln -sf "$SSH_KNOWN_HOSTS_STORE" /home/aide/.ssh/known_hosts

# Belt-and-suspenders: SSH config also points at the store
printf 'Host *\n  UserKnownHostsFile %s\n' "$SSH_KNOWN_HOSTS_STORE" >> /home/aide/.ssh/config
chmod 600 /home/aide/.ssh/config
```

### K8s In-Container Proxy

When `AIDE_KUBE_LOCAL_PORT` is set (by `bin/aide` when a local cluster is detected), an in-container socat proxy listens on `127.0.0.1:<port>` and forwards to the host-side proxy via `host.docker.internal`:

```bash
if [[ -n "${AIDE_KUBE_LOCAL_PORT:-}" ]]; then
  HOST_IP=$(getent hosts host.docker.internal | awk '{print $1}' 2>/dev/null || true)
  if [[ -n "$HOST_IP" ]]; then
    socat TCP-LISTEN:"$AIDE_KUBE_LOCAL_PORT",bind=127.0.0.1,reuseaddr,fork \
      TCP:"$HOST_IP":"$AIDE_KUBE_LOCAL_PORT" &
  fi
fi
```

This pairs with the host-side socat started by `bin/aide` (see PRD-06).

### LAN Host Proxies

When `AIDE_LAN_PROXIES` is set (format: `"domain:port:proxy_port [...]"`), one in-container socat per entry forwards the real service port to the host-side proxy, and `/etc/hosts` is patched so the domain resolves to `127.0.0.1`:

```bash
for spec in "${_lan_specs[@]}"; do
  IFS=: read -r lan_domain lan_port proxy_port <<< "$spec"
  socat "TCP-LISTEN:${lan_port},bind=127.0.0.1,reuseaddr,fork" \
    "TCP:${HOST_IP}:${proxy_port}" &
  echo "127.0.0.1 $lan_domain" >> /etc/hosts
done
```

### SSH Agent Proxy

When `SSH_AGENT_PROXY_PORT` is set, a socat converts the TCP proxy (started by `bin/aide` on macOS) back to a Unix socket, and sets `SSH_AUTH_SOCK`:

```bash
if [[ -n "${SSH_AGENT_PROXY_PORT:-}" ]]; then
  socat UNIX-LISTEN:/tmp/ssh_agent.sock,fork,user=aide,group=aide,mode=600 \
    TCP:host.docker.internal:"$SSH_AGENT_PROXY_PORT" &
  export SSH_AUTH_SOCK=/tmp/ssh_agent.sock
fi
```

### Docker Socket GID

The Docker socket GID varies by runtime (Docker Desktop, Rancher Desktop, native Linux). `entrypoint.sh` detects it at startup and adds `aide` to the correct group dynamically:

```bash
if [[ -S /var/run/docker.sock ]]; then
  docker_sock_gid=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)
  if [[ -n "$docker_sock_gid" && "$docker_sock_gid" != "0" ]]; then
    getent group "$docker_sock_gid" >/dev/null 2>&1 \
      || groupadd --gid "$docker_sock_gid" docker_aide 2>/dev/null || true
    usermod -aG "$docker_sock_gid" aide 2>/dev/null || true
  fi
fi
```

**Pitfall:** Do not hardcode a Docker GID in the image. The GID inside the container depends on the host runtime and VM layer.

### Privilege Drop

```bash
exec gosu aide "$@"
```

`gosu` performs a proper `setuid`/`setgid`/`initgroups` then `exec`, replacing the root shell with the Claude Code process. The `exec` means there is no parent root process running while Claude Code is active.

### Dependencies

**Depends on:** `init-firewall.sh`, `gosu`, `jq`, `inotify-tools`, `socat` (all in image); `.claude/` bind mount (from `bin/aide`); `/etc/aide/policy.json` and `/etc/aide/mcp-defaults.json` (baked into image)

**Required by:** Claude Code (runs as the final `CMD`)

## Acceptance Criteria

- Container starts without errors; firewall verification passes
- After restarting the container, Claude Code resumes with the same `.claude.json` state
- `id` inside the container shows `uid=1000(aide)`
- Team deny list in `settings.json` is present in the merged settings
- User-defined MCP servers in `mcp.json` survive the merge
- K8s proxy is reachable at `127.0.0.1:<AIDE_KUBE_LOCAL_PORT>` when the flag is set
- `ssh-add -l` works inside the container when SSH agent forwarding is active
