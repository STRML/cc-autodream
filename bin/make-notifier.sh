#!/bin/bash
# Build a rebranded notifier app bundle so autodream's notifications show up as
# "cc-autodream" instead of "terminal-notifier".
#
# terminal-notifier attributes each notification to its OWN app bundle (the sender
# name + icon come from the bundle's Info.plist). There is no flag to set an arbitrary
# sender name — `-sender` only borrows ANOTHER existing app's identity. So to brand the
# notifications we make our own copy of terminal-notifier.app, rename it in the plist,
# ad-hoc re-sign it (editing the plist invalidates the original signature), and register
# it with LaunchServices. notify.sh then posts through this bundle's binary.
#
# Idempotent: a no-op if the branded bundle already exists (use --force to rebuild).
# Degrades gracefully: if terminal-notifier isn't installed there is nothing to copy,
# so it prints a note and exits 0 — notify.sh falls back to plain terminal-notifier or
# an osascript banner.
#
# Usage: make-notifier.sh [--force]
#
# Env:
#   AUTODREAM_DIR  where the branded bundle is written  default: $HOME/.claude/autodream

set -u

AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
DEST="$AUTODREAM_DIR/cc-autodream.app"
PB=/usr/libexec/PlistBuddy
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ -d "$DEST" ] && [ "$FORCE" -eq 0 ]; then
  echo "make-notifier.sh: $DEST already exists (use --force to rebuild)"
  exit 0
fi

# Locate the system terminal-notifier.app to clone.
SRC="$(brew --prefix terminal-notifier 2>/dev/null)/terminal-notifier.app"
if [ ! -d "$SRC" ]; then
  TN="$(command -v terminal-notifier || true)"
  [ -n "$TN" ] && SRC="$(cd "$(dirname "$(readlink -f "$TN" 2>/dev/null || echo "$TN")")/.." && pwd)/terminal-notifier.app"
fi
if [ ! -d "$SRC" ]; then
  echo "make-notifier.sh: terminal-notifier not installed; skipping (notify.sh will fall back)"
  exit 0
fi

mkdir -p "$AUTODREAM_DIR"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

PL="$DEST/Contents/Info.plist"
$PB -c "Set :CFBundleName cc-autodream" "$PL"
$PB -c "Set :CFBundleIdentifier com.samuelreed.cc-autodream" "$PL"
$PB -c "Add :CFBundleDisplayName string cc-autodream" "$PL" 2>/dev/null \
  || $PB -c "Set :CFBundleDisplayName cc-autodream" "$PL"

# Editing the plist breaks the inherited signature; ad-hoc re-sign so macOS will run it.
codesign --force --deep -s - "$DEST" >/dev/null 2>&1 || true
# Register the new bundle id with LaunchServices so it appears under its own name.
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

echo "make-notifier.sh: built $DEST (notifications will show as cc-autodream)"
echo "make-notifier.sh: enable it once under System Settings > Notifications > cc-autodream (style: Alerts)"
