#!/usr/bin/env bash
# entrypoint.sh — Container init process for aide.
# Runs as root; drops to aide user at the end via gosu.
set -euo pipefail

CLAUDE_JSON=/home/aide/.claude.json
CLAUDE_JSON_STORE=/home/aide/.claude/.claude.json
POLICY=/etc/aide/settings-policy.json
MCP_DEFAULTS=/etc/aide/mcp-defaults.json
USER_SETTINGS=/home/aide/.claude/settings.json
MCP_USER=/home/aide/.claude/mcp.json
SSH_KNOWN_HOSTS_STORE=/home/aide/.claude/.ssh/known_hosts

# ======================================================================
# Step 1: Apply firewall (abort on failure)
# ======================================================================
/usr/local/bin/init-firewall.sh

# ======================================================================
# Step 2: Restore .claude.json from persistent store
# ======================================================================
if [[ -s "$CLAUDE_JSON_STORE" ]]; then
  gosu aide cp "$CLAUDE_JSON_STORE" "$CLAUDE_JSON"
fi

# ======================================================================
# Step 3: inotifywait background watcher for .claude.json persistence
# ======================================================================
(
  inotifywait -q -m -e moved_to --format '%f' /home/aide/ 2>/dev/null | \
  while IFS= read -r fname; do
    [[ "$fname" == ".claude.json" ]] || continue
    gosu aide cp -f "$CLAUDE_JSON" "$CLAUDE_JSON_STORE" 2>/dev/null || true
  done
) &

# ======================================================================
# Step 3a: Ensure .claude directory exists (owned by aide)
# ======================================================================
gosu aide mkdir -p /home/aide/.claude

# ======================================================================
# Step 4: Settings merge (policy + statusline + user prefs)
# ======================================================================
STATUSLINE='{"statusLine":{"type":"command","command":"/usr/local/bin/aide-statusline"}}'

if [[ -s "$USER_SETTINGS" ]]; then
  jq -s --argjson sl "$STATUSLINE" '
    .[0] as $user | .[1] as $policy
    | .[0] * .[1] * $sl
    | .permissions.allow = ((($user.permissions.allow // []) + ($policy.permissions.allow // [])) | unique)
  ' "$USER_SETTINGS" "$POLICY" \
    | gosu aide tee "$USER_SETTINGS" > /dev/null
else
  jq -n --slurpfile policy "$POLICY" --argjson sl "$STATUSLINE" \
    '$policy[0] * $sl' \
    | gosu aide tee "$USER_SETTINGS" > /dev/null
fi

# ======================================================================
# Step 5: MCP merge (image defaults + user servers)
# ======================================================================
if [[ -s "$MCP_USER" ]]; then
  jq -s '.[0] * .[1]' "$MCP_DEFAULTS" "$MCP_USER" \
    | gosu aide tee "$MCP_USER" > /dev/null
else
  gosu aide cp "$MCP_DEFAULTS" "$MCP_USER"
fi

# ======================================================================
# Step 6: Git identity forwarding
# ======================================================================
if [[ -n "${GIT_AUTHOR_NAME:-}" || -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
  [[ -n "${GIT_AUTHOR_NAME:-}" ]]  && gosu aide git config --global user.name  "$GIT_AUTHOR_NAME"
  [[ -n "${GIT_AUTHOR_EMAIL:-}" ]] && gosu aide git config --global user.email "$GIT_AUTHOR_EMAIL"
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
fi

# ======================================================================
# Step 7: SSH known_hosts persistence
# ======================================================================
gosu aide mkdir -p /home/aide/.claude/.ssh
gosu aide touch "$SSH_KNOWN_HOSTS_STORE"
gosu aide chmod 600 "$SSH_KNOWN_HOSTS_STORE"

rm -f /home/aide/.ssh/known_hosts
ln -sf "$SSH_KNOWN_HOSTS_STORE" /home/aide/.ssh/known_hosts

printf 'Host *\n  UserKnownHostsFile %s\n' "$SSH_KNOWN_HOSTS_STORE" >> /home/aide/.ssh/config
chmod 600 /home/aide/.ssh/config
chown aide:aide /home/aide/.ssh/config

# ======================================================================
# Step 8: K8s in-container socat proxy
# ======================================================================
if [[ -n "${AIDE_KUBE_LOCAL_PORT:-}" ]]; then
  HOST_IP=$(getent hosts host.docker.internal 2>/dev/null | awk '{print $1}' || true)
  if [[ -n "$HOST_IP" ]]; then
    socat "TCP-LISTEN:${AIDE_KUBE_LOCAL_PORT},bind=127.0.0.1,reuseaddr,fork" \
      "TCP:${HOST_IP}:${AIDE_KUBE_LOCAL_PORT}" &
  fi
fi

# ======================================================================
# Step 9: LAN host socat proxies
# ======================================================================
if [[ -n "${AIDE_LAN_PROXIES:-}" ]]; then
  HOST_IP=$(getent hosts host.docker.internal 2>/dev/null | awk '{print $1}' || true)
  if [[ -n "$HOST_IP" ]]; then
    for spec in $AIDE_LAN_PROXIES; do
      IFS=: read -r lan_domain lan_port proxy_port <<< "$spec"
      socat "TCP-LISTEN:${lan_port},bind=127.0.0.1,reuseaddr,fork" \
        "TCP:${HOST_IP}:${proxy_port}" &
      echo "127.0.0.1 $lan_domain" >> /etc/hosts
    done
  fi
fi

# ======================================================================
# Step 10: SSH agent TCP-to-Unix proxy
# ======================================================================
if [[ -n "${SSH_AGENT_PROXY_PORT:-}" ]]; then
  socat UNIX-LISTEN:/tmp/ssh_agent.sock,fork,user=aide,group=aide,mode=600 \
    TCP:host.docker.internal:"$SSH_AGENT_PROXY_PORT" &
  export SSH_AUTH_SOCK=/tmp/ssh_agent.sock
fi

# ======================================================================
# Step 11: Docker socket GID adjustment
# ======================================================================
if [[ -S /var/run/docker.sock ]]; then
  docker_sock_gid=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)
  if [[ -n "$docker_sock_gid" && "$docker_sock_gid" != "0" ]]; then
    getent group "$docker_sock_gid" >/dev/null 2>&1 \
      || groupadd --gid "$docker_sock_gid" docker_aide 2>/dev/null || true
    usermod -aG "$docker_sock_gid" aide 2>/dev/null || true
  fi
fi

# ======================================================================
# Step 12: Drop privileges and exec Claude Code
# ======================================================================
exec gosu aide "$@"
