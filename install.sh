#!/usr/bin/env bash
# Install this repo as a Claude Code skill via a symlink.
# Usage: ./install.sh

set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="cloudflare-tunnel-routes"
TARGET_DIR="${HOME}/.claude/skills/${SKILL_NAME}"

if [ -L "$TARGET_DIR" ]; then
    echo "==> Removing existing symlink: $TARGET_DIR"
    rm "$TARGET_DIR"
elif [ -d "$TARGET_DIR" ]; then
    echo "ERROR: $TARGET_DIR exists and is a real directory (not a symlink)."
    echo "       Remove it manually first if you want to replace it."
    exit 1
elif [ -e "$TARGET_DIR" ]; then
    echo "ERROR: $TARGET_DIR exists and is a regular file (not a symlink)."
    echo "       Remove it manually first if you want to replace it."
    exit 1
fi

mkdir -p "$(dirname "$TARGET_DIR")"
ln -s "$REPO_DIR" "$TARGET_DIR"

# Make sure scripts are executable
chmod +x "$REPO_DIR"/scripts/*.sh

echo "==> Linked: $TARGET_DIR -> $REPO_DIR"
echo "==> Done. Restart Claude Code (or open a new session) to activate the skill."
