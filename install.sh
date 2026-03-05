#!/usr/bin/env bash
set -euo pipefail

# install.sh — One-time setup for aide

AIDE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/bin"
SYMLINK="${BIN_DIR}/aide"

echo "aide: installing..."

# ── Check prerequisites ──────────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
  echo "aide: error: Docker is not installed. Please install Docker first." >&2
  exit 1
fi

if ! docker info &>/dev/null 2>&1; then
  echo "aide: error: Docker daemon is not running. Please start Docker." >&2
  exit 1
fi

# ── Create symlink ───────────────────────────────────────────────────────────

mkdir -p "$BIN_DIR"

if [[ -L "$SYMLINK" ]]; then
  echo "aide: updating existing symlink"
  rm "$SYMLINK"
elif [[ -e "$SYMLINK" ]]; then
  echo "aide: error: ${SYMLINK} already exists and is not a symlink" >&2
  exit 1
fi

ln -s "${AIDE_ROOT}/bin/aide" "$SYMLINK"
echo "aide: symlinked ${SYMLINK} -> ${AIDE_ROOT}/bin/aide"

# ── Build image ──────────────────────────────────────────────────────────────

echo "aide: building Docker image (this may take a few minutes)..."
"$SYMLINK" build

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "aide: installation complete!"
echo ""
echo "Usage:"
echo "  aide                  Launch Claude Code in current directory"
echo "  aide build            Rebuild the Docker image"
echo "  aide -p \"prompt\"      Run non-interactively"
echo "  aide --help           Show all options"
echo ""

# Check if ~/bin is in PATH
if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
  echo "NOTE: ${BIN_DIR} is not in your PATH."
  echo "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
  echo ""
  echo "  export PATH=\"\$HOME/bin:\$PATH\""
  echo ""
fi
