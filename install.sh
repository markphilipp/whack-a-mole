#!/usr/bin/env bash
# whack-a-mole installer.
#
# Idempotent:
#   - Validates required deps (gh, jq, yq, claude).
#   - Creates ~/.local/state/whack-a-mole/{logs} for state + logs
#   - Symlinks the repo into ~/.claude/whack-a-mole
#   - Renders the launchd plist (from the .template) into ~/Library/LaunchAgents/
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

# --- Scaffold config.yaml from template ---------------------------------------

CONFIG_FILE="$SCRIPT_DIR/config.yaml"
CONFIG_EXAMPLE="$SCRIPT_DIR/config.yaml.example"
if [[ -f "$CONFIG_FILE" ]]; then
  ok "config: $CONFIG_FILE"
elif [[ -f "$CONFIG_EXAMPLE" ]]; then
  cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
  warn "created config.yaml from config.yaml.example — edit it (repos, git_user, git_user_email) before running"
else
  err "neither config.yaml nor config.yaml.example found in $SCRIPT_DIR"
  exit 1
fi

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

# --- Render launchd plist -----------------------------------------------------

PLIST_SRC="$SCRIPT_DIR/launchd/com.markphilipp.whack-a-mole.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/com.markphilipp.whack-a-mole.plist"
mkdir -p "$HOME/Library/LaunchAgents"
# Render the template: launchd does not expand $HOME in plist string values, so
# we substitute the real home path here. rm first to break any prior symlink (a
# previous install symlinked this file) — otherwise `>` would follow it.
rm -f "$PLIST_DST"
sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
ok "rendered plist: $PLIST_DST"

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
