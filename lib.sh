#!/usr/bin/env bash
# whack-a-mole — shared helpers. Sourced by watcher.sh and dispatch.sh.

set -euo pipefail

# --- Paths ---------------------------------------------------------------------

WAM_HOME="${WAM_HOME:-$HOME/.claude/whack-a-mole}"
WAM_CONFIG="${WAM_CONFIG:-$WAM_HOME/config.yaml}"
WAM_STATE_DIR="${WAM_STATE_DIR:-$HOME/.local/state/whack-a-mole}"
WAM_STATE_FILE="$WAM_STATE_DIR/state.json"
WAM_LOG_DIR="$WAM_STATE_DIR/logs"
WAM_WATCHER_LOG="$WAM_LOG_DIR/watcher.log"

# Sentinel exit code dispatch.sh uses to signal a failure that happened BEFORE
# the Claude session launched (SSH agent locked, transient network, deps install
# — no tokens spent). The watcher treats it as retryable rather than burning the
# at-most-once token. Chosen to match sysexits.h EX_TEMPFAIL.
WAM_TEMPFAIL_EXIT=75

mkdir -p "$WAM_STATE_DIR" "$WAM_LOG_DIR"
[[ -f "$WAM_STATE_FILE" ]] || echo '{}' > "$WAM_STATE_FILE"

# --- Logging -------------------------------------------------------------------

log() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s %s\n' "$ts" "$*" >> "$WAM_WATCHER_LOG"
  printf '%s %s\n' "$ts" "$*" >&2
}

die() { log "FATAL: $*"; exit 1; }

# --- Time ----------------------------------------------------------------------

now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Print an ISO-8601 UTC timestamp <hours> from now. BSD (macOS) date first,
# GNU date fallback — same pattern as the cursor seeding in watcher.sh.
deadline_from_now_hours() {
  local hours="$1"
  date -u -v+"${hours}H" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "+${hours} hours" +"%Y-%m-%dT%H:%M:%SZ"
}

# --- Config (yq) ---------------------------------------------------------------

cfg() {
  # cfg <yq-expression>  e.g.  cfg '.mode'
  yq -r "$1" "$WAM_CONFIG"
}

cfg_repo_count() { yq -r '.repos | length' "$WAM_CONFIG"; }

cfg_repo() {
  # cfg_repo <index> <yq-suffix>  e.g.  cfg_repo 0 .github
  yq -r ".repos[$1]$2" "$WAM_CONFIG"
}

cfg_repo_quick_checks() {
  yq -r ".repos[$1].quick_checks[]" "$WAM_CONFIG"
}

cfg_repo_setup() {
  # Optional per-repo worktree provisioning commands. Absent ⇒ empty output.
  yq -r ".repos[$1].worktree_setup[]?" "$WAM_CONFIG"
}

# --- State (atomic) ------------------------------------------------------------
#
# Callers pass arbitrary jq filter expressions. We wrap with atomic tmp+mv.
# Example mutation:
#   state_apply --arg slug "$slug" --arg ts "$ts" '.repos[$slug].bugbot_last_seen = $ts'
# Example read:
#   state_read --arg slug "$slug" '.repos[$slug].bugbot_last_seen // ""'

state_apply() {
  local tmp="$WAM_STATE_FILE.tmp.$$"
  jq "$@" "$WAM_STATE_FILE" > "$tmp" && mv "$tmp" "$WAM_STATE_FILE"
}

state_read() {
  jq -r "$@" "$WAM_STATE_FILE"
}

# --- GitHub helpers ------------------------------------------------------------

pr_author() {
  gh api "repos/$1/pulls/$2" --jq '.user.login' 2>/dev/null || true
}

pr_head_ref() {
  gh api "repos/$1/pulls/$2" --jq '.head.ref'
}

pr_head_sha() {
  gh api "repos/$1/pulls/$2" --jq '.head.sha'
}

# "open" | "closed" | "" (on error). Note: GitHub reports merged PRs as "closed".
pr_state() {
  gh api "repos/$1/pulls/$2" --jq '.state' 2>/dev/null || true
}

# Print the databaseId (one per line) of every review comment that belongs to a
# RESOLVED review thread on the PR. Empty output ⇒ nothing resolved / error.
# Only review (line) comments live in threads; issue comments never appear here.
pr_resolved_review_comment_ids() {
  local slug="$1" pr="$2"
  local owner="${slug%%/*}" name="${slug##*/}"
  gh api graphql \
    -f query='query($owner:String!,$name:String!,$pr:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$pr){
          reviewThreads(first:100){
            nodes{ isResolved comments(first:100){ nodes{ databaseId } } }
          }
        }
      }
    }' \
    -f owner="$owner" -f name="$name" -F pr="$pr" 2>/dev/null \
    | jq -r '.data.repository.pullRequest.reviewThreads.nodes[]?
             | select(.isResolved) | .comments.nodes[]?.databaseId' 2>/dev/null \
    || true
}

# Count commits on origin/<branch> in <local_repo> whose trailers match <pattern>.
count_trailers() {
  local local_repo="$1" branch="$2" pattern="$3"
  (
    cd "$local_repo" || return 0
    git fetch --quiet origin "$branch" 2>/dev/null || true
    git log --format='%(trailers)' "origin/$branch" 2>/dev/null \
      | grep -c "$pattern" || true
  )
}

head_has_trailer() {
  local local_repo="$1" branch="$2" pattern="$3"
  local trailers
  trailers=$(
    cd "$local_repo" || return 1
    git log -1 --format='%(trailers)' "origin/$branch" 2>/dev/null || true
  )
  [[ "$trailers" == *"$pattern"* ]]
}
