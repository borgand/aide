#!/usr/bin/env bash
set -euo pipefail

# Apply network firewall (runs as root)
/usr/local/bin/init-firewall.sh

# Persist ~/.claude.json via the aide-claude volume.
# The file lives in $HOME but our volume is at $HOME/.claude — symlink it in.
CLAUDE_JSON=/home/aide/.claude.json
CLAUDE_JSON_STORE=/home/aide/.claude/.claude.json
if [[ ! -e "$CLAUDE_JSON_STORE" ]]; then
  # Fresh volume: seed from the baked-in image copy
  cp "$CLAUDE_JSON" "$CLAUDE_JSON_STORE" 2>/dev/null || true
fi
# Replace the baked-in file with a symlink to the volume copy
rm -f "$CLAUDE_JSON"
ln -sf "$CLAUDE_JSON_STORE" "$CLAUDE_JSON"
chown -h aide:aide "$CLAUDE_JSON"
chown aide:aide "$CLAUDE_JSON_STORE" 2>/dev/null || true

# Merge team permissions policy + statusline into user settings.
# Team policy wins on conflicts (permissions block); user preferences (theme etc.) survive.
POLICY=/etc/aide/policy.json
STATUSLINE='{"statusLine":{"type":"command","command":"/usr/local/bin/aide-statusline"}}'
USER_SETTINGS=/home/aide/.claude/settings.json
mkdir -p /home/aide/.claude
if [[ -f "$USER_SETTINGS" && -f "$POLICY" ]]; then
  jq -s '.[0] * .[1] * .[2]' "$USER_SETTINGS" "$POLICY" <(echo "$STATUSLINE") > /tmp/aide-settings.json \
    && mv /tmp/aide-settings.json "$USER_SETTINGS"
elif [[ -f "$POLICY" ]]; then
  jq -s '.[0] * .[1]' "$POLICY" <(echo "$STATUSLINE") > "$USER_SETTINGS"
fi
chown aide:aide "$USER_SETTINGS"

# Write git identity config for aide user if provided via env vars
if [[ -n "${GIT_AUTHOR_NAME:-}" || -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
  {
    echo "[user]"
    [[ -n "${GIT_AUTHOR_NAME:-}" ]]  && echo "	name = $GIT_AUTHOR_NAME"
    [[ -n "${GIT_AUTHOR_EMAIL:-}" ]] && echo "	email = $GIT_AUTHOR_EMAIL"
  } > /home/aide/.gitconfig
  chown aide:aide /home/aide/.gitconfig
  # Unset env vars so repo-level .gitconfig in workspace can take precedence
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
fi

# Persist ~/.ssh/known_hosts via the aide-claude volume so SSH host keys
# survive container restarts (avoids repeated "authenticity of host" prompts).
SSH_DIR=/home/aide/.ssh
SSH_KNOWN_HOSTS_STORE=/home/aide/.claude/.ssh/known_hosts
mkdir -p /home/aide/.claude/.ssh
touch "$SSH_KNOWN_HOSTS_STORE"
chmod 700 /home/aide/.claude/.ssh
chmod 600 "$SSH_KNOWN_HOSTS_STORE"
chown -R aide:aide /home/aide/.claude/.ssh
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown aide:aide "$SSH_DIR"
# Symlink known_hosts → volume-backed copy
rm -f "$SSH_DIR/known_hosts"
ln -sf "$SSH_KNOWN_HOSTS_STORE" "$SSH_DIR/known_hosts"
chown -h aide:aide "$SSH_DIR/known_hosts"

# Set up SSH agent forwarding via TCP proxy (macOS host → container)
if [[ -n "${SSH_AGENT_PROXY_PORT:-}" ]]; then
  socat UNIX-LISTEN:/tmp/ssh_agent.sock,fork,user=aide,group=aide,mode=600 \
    TCP:host.docker.internal:"$SSH_AGENT_PROXY_PORT" &
  export SSH_AUTH_SOCK=/tmp/ssh_agent.sock
fi

# Drop privileges and execute CMD as aide user
exec gosu aide "$@"
