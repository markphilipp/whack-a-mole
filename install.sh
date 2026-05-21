#!/usr/bin/env bash
# whack-a-mole installer.
#
# Idempotent:
#   - Validates required deps (gh, jq, yq, claude).
#   - Creates ~/.local/state/whack-a-mole/{logs} for state + logs
#   - Symlinks the repo into ~/.claude/whack-a-mole
#   - Symlinks the launchd plist into ~/Library/LaunchAgents/
#   - Optionally loads launchd (--load)
#
# Config lives in the repo at ./config.yaml. Edit it directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD=0

while (( $# > 0 )); do
  case "$1" in
    --load) LOAD=1; shift;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

say() { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

# --- Validate deps ------------------------------------------------------------

say "Checking dependencies"
missing=()
for cmd in gh jq yq claude git; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd → $(command -v "$cmd")"
  else
    err "$cmd not found"
    missing+=("$cmd")
  fi
done
if (( ${#missing[@]} > 0 )); then
  err "Missing: ${missing[*]}"
  echo "Install with: brew install ${missing[*]}" >&2
  exit 1
fi

# --- Validate gh auth ---------------------------------------------------------

say "Checking gh auth"
if ! gh auth status >/dev/null 2>&1; then
  err "gh not authenticated. Run: gh auth login"
  exit 1
fi
ok "gh authenticated as $(gh api user --jq .login)"

# --- Create runtime dirs ------------------------------------------------------

STATE_DIR="$HOME/.local/state/whack-a-mole"
LOG_DIR="$STATE_DIR/logs"

say "Creating runtime dirs"
mkdir -p "$STATE_DIR" "$LOG_DIR"
ok "$STATE_DIR"
ok "$LOG_DIR"

# --- Confirm config is present in the repo -----------------------------------

CONFIG_FILE="$SCRIPT_DIR/config.yaml"
[[ -f "$CONFIG_FILE" ]] || { err "config not found: $CONFIG_FILE"; exit 1; }
ok "config: $CONFIG_FILE"

# --- Initialize state file if absent ------------------------------------------

STATE_FILE="$STATE_DIR/state.json"
[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
ok "state: $STATE_FILE"

# --- Symlink repo into ~/.claude/whack-a-mole --------------------------------

CLAUDE_LINK="$HOME/.claude/whack-a-mole"
mkdir -p "$HOME/.claude"
if [[ -L "$CLAUDE_LINK" ]]; then
  current=$(readlink "$CLAUDE_LINK")
  if [[ "$current" != "$SCRIPT_DIR" ]]; then
    warn "symlink $CLAUDE_LINK currently points to $current → updating"
    rm "$CLAUDE_LINK"
    ln -s "$SCRIPT_DIR" "$CLAUDE_LINK"
  fi
elif [[ -e "$CLAUDE_LINK" ]]; then
  err "$CLAUDE_LINK exists and is not a symlink — refusing to overwrite"
  exit 1
else
  ln -s "$SCRIPT_DIR" "$CLAUDE_LINK"
fi
ok "symlink: $CLAUDE_LINK → $SCRIPT_DIR"

# --- Symlink launchd plist ----------------------------------------------------

PLIST_SRC="$SCRIPT_DIR/launchd/com.markphilipp.whack-a-mole.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.markphilipp.whack-a-mole.plist"
mkdir -p "$HOME/Library/LaunchAgents"
if [[ -L "$PLIST_DST" ]]; then
  rm "$PLIST_DST"
elif [[ -e "$PLIST_DST" ]]; then
  err "$PLIST_DST exists and is not a symlink — refusing to overwrite"
  exit 1
fi
ln -s "$PLIST_SRC" "$PLIST_DST"
ok "symlink: $PLIST_DST → $PLIST_SRC"

# --- Make scripts executable --------------------------------------------------

chmod +x "$SCRIPT_DIR/watcher.sh" "$SCRIPT_DIR/dispatch.sh" "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh" 2>/dev/null || true

# --- Validate config ----------------------------------------------------------

say "Validating config"
if yq -e '.repos | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then
  count=$(yq -r '.repos | length' "$CONFIG_FILE")
  ok "config has $count repo(s)"
else
  warn "config has no repos configured — edit $CONFIG_FILE"
fi

# --- Optional launchd load ----------------------------------------------------

if (( LOAD )); then
  say "Loading launchd agent"
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  launchctl load "$PLIST_DST"
  ok "loaded com.markphilipp.whack-a-mole"
  echo
  ok "tail logs with: tail -f $LOG_DIR/watcher.log"
else
  echo
  ok "Install complete. To start the watcher:"
  echo "    $0 --load"
  echo "  or manually run for one cycle:"
  echo "    $SCRIPT_DIR/watcher.sh"
fi
