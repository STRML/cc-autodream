#!/bin/bash
# cc-autodream installer.
#
# Symlinks the scripts + prompts from this repo into ~/.claude/autodream/
# so the standard paths resolve. Idempotent — safe to re-run.
#
# Usage:
#   ./install.sh             # symlink into $HOME/.claude/autodream/
#   ./install.sh /path/to    # symlink into /path/to/autodream/

set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_PARENT="${1:-$HOME/.claude}"
TARGET="$TARGET_PARENT/autodream"

mkdir -p "$TARGET" "$TARGET_PARENT/dreams" "$TARGET/findings" "$TARGET/inbox" "$TARGET/logs"

link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ] || [ -f "$dst" ]; then
    rm -f "$dst"
  fi
  ln -s "$src" "$dst"
  echo "  $dst -> $src"
}

echo "Installing cc-autodream into $TARGET"
link "$REPO_DIR/bin/run.sh"             "$TARGET/run.sh"
link "$REPO_DIR/bin/review.sh"          "$TARGET/review.sh"
link "$REPO_DIR/bin/notify.sh"          "$TARGET/notify.sh"
link "$REPO_DIR/prompts/PROMPT.md"      "$TARGET/PROMPT.md"
link "$REPO_DIR/prompts/SESSION_TRIAGE.md" "$TARGET/SESSION_TRIAGE.md"

chmod +x "$REPO_DIR/bin/"*.sh

echo
echo "Installed. Try:"
echo "  $TARGET/run.sh \$(date -v-1d +%Y-%m-%d)   # process yesterday"
echo "  $TARGET/review.sh                        # triage the latest report"
echo
echo "To schedule overnight runs see launchd/com.user.autodream.plist.example"
