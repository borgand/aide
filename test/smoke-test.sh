#!/usr/bin/env bash
# smoke-test.sh — Verify aide container boots and claude is available.
# Run after building: ./test/smoke-test.sh
set -euo pipefail

IMAGE_NAME="${1:-aide:latest}"
PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== aide smoke tests ==="
echo "Image: $IMAGE_NAME"
echo ""

# Helper: run a command in the image without the entrypoint
runit() { docker run --rm --entrypoint "" "$IMAGE_NAME" "$@" 2>/dev/null || true; }

# --- Test 1: Image exists ---
if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  ok "image exists"
else
  fail "image does not exist"
  echo "Build the image first: aide build (or docker build -t $IMAGE_NAME .)"
  exit 1
fi

# --- Test 2: aide user is uid 1000 ---
uid=$(runit id -u aide 2>/dev/null || true)
if [[ "$uid" == "1000" ]]; then
  ok "aide user is uid 1000"
else
  fail "aide user uid is '$uid' (expected 1000)"
fi

# --- Test 3: claude binary exists ---
claude_path=$(runit which claude 2>/dev/null || true)
if [[ -n "$claude_path" ]]; then
  ok "claude binary found at $claude_path"
else
  fail "claude binary not found"
fi

# --- Test 4: node is available ---
node_ver=$(runit node --version 2>/dev/null || true)
if [[ "$node_ver" =~ ^v[0-9]+ ]]; then
  ok "node available: $node_ver"
else
  fail "node not available"
fi

# --- Test 5: go is available ---
go_ver=$(runit go version 2>/dev/null || true)
if [[ "$go_ver" =~ ^go\ version ]]; then
  ok "go available: $go_ver"
else
  fail "go not available"
fi

# --- Test 6: entrypoint.sh exists and is executable ---
ep=$(runit test -x /usr/local/bin/entrypoint.sh && echo "ok" || true)
if [[ "$ep" == "ok" ]]; then
  ok "entrypoint.sh is executable"
else
  fail "entrypoint.sh not executable"
fi

# --- Test 7: init-firewall.sh exists and is executable ---
fw=$(runit test -x /usr/local/bin/init-firewall.sh && echo "ok" || true)
if [[ "$fw" == "ok" ]]; then
  ok "init-firewall.sh is executable"
else
  fail "init-firewall.sh not executable"
fi

# --- Test 8: settings policy baked into image ---
policy=$(runit test -f /etc/aide/settings-policy.json && echo "ok" || true)
if [[ "$policy" == "ok" ]]; then
  ok "settings-policy.json baked in"
else
  fail "settings-policy.json missing"
fi

# --- Test 9: mcp-defaults baked into image ---
mcp=$(runit test -f /etc/aide/mcp-defaults.json && echo "ok" || true)
if [[ "$mcp" == "ok" ]]; then
  ok "mcp-defaults.json baked in"
else
  fail "mcp-defaults.json missing"
fi

# --- Test 10: aide-statusline exists and is executable ---
sl=$(runit test -x /usr/local/bin/aide-statusline && echo "ok" || true)
if [[ "$sl" == "ok" ]]; then
  ok "aide-statusline is executable"
else
  fail "aide-statusline not executable"
fi

# --- Test 11: no sudo for aide user ---
sudo_check=$(runit gosu aide sudo -n true 2>&1 || true)
if [[ -z "$sudo_check" || "$sudo_check" == *"not found"* || "$sudo_check" == *"command not found"* || "$sudo_check" == *"not allowed"* ]]; then
  ok "aide user has no sudo"
else
  fail "aide user might have sudo access"
fi

# --- Test 12: kubectl binary exists ---
kubectl_path=$(runit which kubectl 2>/dev/null || true)
if [[ -n "$kubectl_path" ]]; then
  ok "kubectl binary found at $kubectl_path"
else
  fail "kubectl binary not found"
fi

# --- Test 13: socat binary exists ---
socat_path=$(runit which socat 2>/dev/null || true)
if [[ -n "$socat_path" ]]; then
  ok "socat binary found at $socat_path"
else
  fail "socat binary not found"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
