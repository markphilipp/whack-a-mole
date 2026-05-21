#!/usr/bin/env bash
# whack-a-mole — per-trigger dispatcher.
#
# Sets up a worktree on the PR branch, launches a headless Claude session with
# the appropriate rubric, then tears down (unless mode=beta, which keeps the
# worktree for inspection).
#
# Usage:
#   dispatch.sh --kind bugbot|ci --repo <slug> --pr <num> \
#               --trigger-id <id> --trigger-json <json>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- Parse args ----------------------------------------------------------------

KIND="" REPO="" PR="" TRIGGER_ID="" TRIGGER_JSON=""
while (( $# > 0 )); do
  case "$1" in
    --kind)         KIND="$2"; shift 2;;
    --repo)         REPO="$2"; shift 2;;
    --pr)           PR="$2"; shift 2;;
    --trigger-id)   TRIGGER_ID="$2"; shift 2;;
    --trigger-json) TRIGGER_JSON="$2"; shift 2;;
    *) die "unknown arg: $1";;
  esac
done

[[ -n "$KIND" && -n "$REPO" && -n "$PR" && -n "$TRIGGER_ID" ]] \
  || die "missing required args"
[[ "$KIND" == "bugbot" || "$KIND" == "ci" ]] || die "invalid --kind $KIND"

MODE="$(cfg .mode)"
DISPATCH_LOG="$WAM_LOG_DIR/dispatch-$KIND-pr${PR}-${TRIGGER_ID}.log"

dlog() {
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s %s\n' "$ts" "$*" | tee -a "$DISPATCH_LOG" >> "$WAM_WATCHER_LOG"
}

dlog "dispatch start kind=$KIND repo=$REPO pr=$PR trigger_id=$TRIGGER_ID mode=$MODE"

# --- Locate repo + resolve PR branch info -------------------------------------

# Find the repo's local checkout + worktree_root from config.
REPO_IDX=""
N=$(cfg_repo_count)
for ((i=0; i<N; i++)); do
  if [[ "$(cfg_repo "$i" .github)" == "$REPO" ]]; then
    REPO_IDX="$i"
    break
  fi
done
[[ -n "$REPO_IDX" ]] || die "repo $REPO not in config"

LOCAL_REPO="$(cfg_repo "$REPO_IDX" .local)"
WT_ROOT="$(cfg_repo "$REPO_IDX" .worktree_root)"
[[ -d "$LOCAL_REPO/.git" ]] || die "local repo not found at $LOCAL_REPO"

HEAD_REF="$(pr_head_ref "$REPO" "$PR")"
HEAD_SHA="$(pr_head_sha "$REPO" "$PR")"

dlog "pr head_ref=$HEAD_REF head_sha=${HEAD_SHA:0:7}"

# --- Mode alpha: log and exit --------------------------------------------------

if [[ "$MODE" == "alpha" ]]; then
  dlog "alpha mode → would-dispatch (no worktree, no claude). Trigger JSON:"
  dlog "$TRIGGER_JSON"
  exit 0
fi

# --- Worktree setup ------------------------------------------------------------

WT_BRANCH="wam-${KIND}-pr${PR}-${TRIGGER_ID}"
WT_PATH="$LOCAL_REPO/$WT_ROOT/$WT_BRANCH"

cleanup_worktree() {
  if [[ "$MODE" == "beta" ]]; then
    dlog "beta mode → keeping worktree at $WT_PATH for inspection"
    return
  fi
  dlog "tearing down worktree $WT_PATH"
  (
    cd "$LOCAL_REPO"
    git worktree remove --force "$WT_PATH" 2>/dev/null || true
    git branch -D "$WT_BRANCH" 2>/dev/null || true
  )
}
trap cleanup_worktree EXIT

(
  cd "$LOCAL_REPO"
  dlog "fetching PR head into $WT_BRANCH"
  # `gh pr checkout` would mutate the working tree; we want only the local branch.
  git fetch origin "pull/$PR/head:$WT_BRANCH" 2>&1 | tee -a "$DISPATCH_LOG"
  mkdir -p "$WT_ROOT"
  if [[ -d "$WT_PATH" ]]; then
    dlog "worktree path already exists, removing first"
    git worktree remove --force "$WT_PATH" 2>/dev/null || true
  fi
  dlog "creating worktree at $WT_PATH"
  git worktree add "$WT_PATH" "$WT_BRANCH" 2>&1 | tee -a "$DISPATCH_LOG"
)

# Set upstream so `git push` lands on the right remote branch.
(
  cd "$WT_PATH"
  git branch --set-upstream-to="origin/$HEAD_REF" "$WT_BRANCH" 2>/dev/null || true
)

# --- Build quick-checks env var ------------------------------------------------

QUICK_CHECKS=$(cfg_repo_quick_checks "$REPO_IDX" | paste -sd $'\n' -)

# --- Launch headless Claude ----------------------------------------------------

case "$KIND" in
  bugbot) PROMPT_FILE="$SCRIPT_DIR/prompts/bugbot-comment.md";;
  ci)     PROMPT_FILE="$SCRIPT_DIR/prompts/ci-failure.md";;
esac
[[ -f "$PROMPT_FILE" ]] || die "prompt file missing: $PROMPT_FILE"

# User-message body: a concise context block. The system prompt (rubric) is
# appended via --append-system-prompt; the actual trigger data goes in env
# vars + a short user message so Claude has everything in one place.
USER_MSG=$(cat <<EOF
A new $KIND trigger fired for $REPO PR #$PR. Follow your rubric.

Context (also available as env vars WHACKAMOLE_*):
- repo: $REPO
- pr: $PR
- mode: $MODE  (live = push & reply; beta = stop short of push & reply)
- head_ref: $HEAD_REF
- head_sha: $HEAD_SHA
- worktree: $WT_PATH
- trigger_id: $TRIGGER_ID

Trigger JSON:
$TRIGGER_JSON
EOF
)

dlog "launching claude (mode=$MODE, kind=$KIND, model=opus, permission=auto)"

# Export env vars for the spawned Claude (and any tool calls it makes).
export WHACKAMOLE_TRIGGER_KIND="$KIND"
export WHACKAMOLE_REPO="$REPO"
export WHACKAMOLE_PR_NUMBER="$PR"
export WHACKAMOLE_HEAD_REF="$HEAD_REF"
export WHACKAMOLE_HEAD_SHA="$HEAD_SHA"
export WHACKAMOLE_WORKTREE="$WT_PATH"
export WHACKAMOLE_TRIGGER_ID="$TRIGGER_ID"
export WHACKAMOLE_TRIGGER_JSON="$TRIGGER_JSON"
export WHACKAMOLE_MODE="$MODE"
export WHACKAMOLE_QUICK_CHECKS="$QUICK_CHECKS"

# Run claude inside the worktree. Disallow tests/docker/etc at the tool level
# as a belt-and-suspenders against the rubric.
DISALLOWED='Bash(make test*) Bash(make docker-test*) Bash(pytest*) Bash(pnpm test*) Bash(npm test*) Bash(vitest*) Bash(playwright*) Bash(docker*) Bash(docker-compose*) Bash(make start*)'

(
  cd "$WT_PATH"
  claude --print \
    --model opus \
    --permission-mode auto \
    --append-system-prompt "$(cat "$PROMPT_FILE")" \
    --disallowed-tools $DISALLOWED \
    --output-format text \
    "$USER_MSG" 2>&1 | tee -a "$DISPATCH_LOG"
)

dlog "claude session done (exit $?)"

# Teardown happens via trap.
