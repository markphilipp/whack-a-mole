#!/usr/bin/env bash
# whack-a-mole uninstaller. Reverses install.sh.
#
# By default: unloads launchd, removes symlinks. Leaves state in place.
# Pass --purge to also delete ~/.local/state/whack-a-mole.

set -euo pipefail

PURGE=0
while (( $# > 0 )); do
  case "$1" in
    --purge) PURGE=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

PLIST="$HOME/Library/LaunchAgents/com.markphilipp.whack-a-mole.plist"
CLAUDE_LINK="$HOME/.claude/whack-a-mole"

if [[ -e "$PLIST" || -L "$PLIST" ]]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "✓ removed $PLIST"
fi

if [[ -L "$CLAUDE_LINK" ]]; then
  rm "$CLAUDE_LINK"
  echo "✓ removed symlink $CLAUDE_LINK"
fi

if (( PURGE )); then
  rm -rf "$HOME/.local/state/whack-a-mole"
  echo "✓ purged state"
else
  echo "ℹ state kept. --purge to remove it."
fi
