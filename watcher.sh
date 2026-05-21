#!/usr/bin/env bash
# whack-a-mole — polling daemon. Long-running.
#
# Polls allowlisted repos for two trigger kinds:
#   A) new bugbot comments on PRs you authored
#   B) new failed CI checks on the head SHA of PRs you authored
#
# Each new trigger is handed to dispatch.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ -f "$WAM_CONFIG" ]] || die "config not found at $WAM_CONFIG (run install.sh)"

log "whack-a-mole watcher starting (config=$WAM_CONFIG)"
log "mode=$(cfg .mode)  poll_interval=$(cfg .poll_interval_seconds)s  only_my_prs=$(cfg .only_my_prs)"

# --- Trigger A: bugbot comments ------------------------------------------------

poll_bugbot_for_repo() {
  local idx="$1"
  local slug; slug=$(cfg_repo "$idx" .github)
  local me; me=$(cfg .my_github_login)
  local only_mine; only_mine=$(cfg .only_my_prs)

  local since
  since=$(state_read --arg slug "$slug" '.repos[$slug].bugbot_last_seen // ""')
  if [[ -z "$since" ]]; then
    # First run: only look at the past hour to avoid replaying ancient comments.
    since=$(date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '-1 hour' +"%Y-%m-%dT%H:%M:%SZ")
  fi

  local newest="$since"

  # Three endpoints: PR review line comments, issue comments (general PR comments),
  # and PR reviews (summary reviews). Bugbot uses all three depending on finding.
  local endpoints=(
    "repos/$slug/pulls/comments"
    "repos/$slug/issues/comments"
  )

  for ep in "${endpoints[@]}"; do
    local raw
    raw=$(gh api --paginate "$ep?sort=created&direction=asc&since=$since&per_page=100" 2>/dev/null || echo '[]')
    # Filter to cursor[bot] comments on PRs (issues/comments includes issues too;
    # filter by issue_url containing "/pulls/" when present).
    local matches
    matches=$(echo "$raw" | jq -c '
      .[]
      | select(.user.login == "cursor[bot]")
      | select((.pull_request_url // .pull_request // .html_url // "") | test("/pull/|/pulls/"))
    ')
    [[ -z "$matches" ]] && continue

    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      local pr_url comment_id created
      pr_url=$(echo "$row" | jq -r '.pull_request_url // .html_url')
      comment_id=$(echo "$row" | jq -r '.id')
      created=$(echo "$row" | jq -r '.created_at')

      # Derive PR number from URL.
      local pr
      pr=$(echo "$pr_url" | grep -oE '/(pull|pulls)/[0-9]+' | grep -oE '[0-9]+$')
      [[ -z "$pr" ]] && continue

      # Author filter.
      if [[ "$only_mine" == "true" ]]; then
        local author
        author=$(pr_author "$slug" "$pr")
        [[ "$author" == "$me" ]] || continue
      fi

      # Loop guard: count Bugbot-Auto-Fix trailers on PR.
      local head_ref; head_ref=$(pr_head_ref "$slug" "$pr")
      local local_repo; local_repo=$(cfg_repo "$idx" .local)
      local trailer_count; trailer_count=$(count_trailers "$local_repo" "$head_ref" "Bugbot-Auto-Fix")
      local cap; cap=$(cfg .max_bugbot_fixes_per_pr)
      if (( trailer_count >= cap )); then
        log "bugbot SKIP pr=$pr comment=$comment_id (trailer count $trailer_count >= cap $cap)"
        continue
      fi

      log "bugbot DISPATCH repo=$slug pr=$pr comment=$comment_id"
      "$SCRIPT_DIR/dispatch.sh" \
        --kind bugbot \
        --repo "$slug" \
        --pr "$pr" \
        --trigger-id "$comment_id" \
        --trigger-json "$row" || log "dispatch returned non-zero for pr=$pr comment=$comment_id"

      [[ "$created" > "$newest" ]] && newest="$created"
    done <<< "$matches"
  done

  # Also poll /pulls/reviews (summary reviews). gh api doesn't support `since`
  # on this endpoint; we have to iterate PRs. Cheap because we only look at
  # OPEN PRs by `me` (Trigger B already enumerates these).

  if [[ "$newest" != "$since" ]]; then
    state_apply --arg slug "$slug" --arg ts "$newest" '.repos[$slug].bugbot_last_seen = $ts'
  fi
}

# --- Trigger B: failed CI checks -----------------------------------------------

poll_ci_for_repo() {
  local idx="$1"
  local slug; slug=$(cfg_repo "$idx" .github)
  local me; me=$(cfg .my_github_login)
  local local_repo; local_repo=$(cfg_repo "$idx" .local)
  local cap; cap=$(cfg .max_ci_fix_attempts)

  # List open PRs authored by me.
  local prs
  prs=$(gh api --paginate "repos/$slug/pulls?state=open&per_page=50" \
    | jq -c --arg me "$me" '.[] | select(.user.login == $me) | {number, sha: .head.sha, ref: .head.ref}')
  [[ -z "$prs" ]] && return 0

  while IFS= read -r pr_row; do
    [[ -z "$pr_row" ]] && continue
    local pr sha head_ref
    pr=$(echo "$pr_row" | jq -r '.number')
    sha=$(echo "$pr_row" | jq -r '.sha')
    head_ref=$(echo "$pr_row" | jq -r '.ref')

    # Get failed check-runs for this SHA.
    local runs
    runs=$(gh api --paginate "repos/$slug/commits/$sha/check-runs?per_page=100" 2>/dev/null \
      | jq -c '.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")' \
      || echo '')
    [[ -z "$runs" ]] && continue

    while IFS= read -r run; do
      [[ -z "$run" ]] && continue
      local check_id check_name
      check_id=$(echo "$run" | jq -r '.id')
      check_name=$(echo "$run" | jq -r '.name')
      local key="$pr-$sha-$check_id"

      # Already dispatched for this exact failure?
      local seen
      seen=$(state_read --arg slug "$slug" --arg k "$key" '.repos[$slug].ci_seen[$k] // ""')
      [[ -n "$seen" ]] && continue

      # Suppression: HEAD already has a CI-Auto-Fix trailer for this check+sha.
      if head_has_trailer "$local_repo" "$head_ref" "CI-Auto-Fix: $check_name@$sha"; then
        log "ci SUPPRESS pr=$pr check=$check_name (HEAD trailer matches)"
        state_apply --arg slug "$slug" --arg k "$key" '.repos[$slug].ci_seen[$k] = "suppressed"'
        continue
      fi

      # Loop cap.
      local trailer_count
      trailer_count=$(count_trailers "$local_repo" "$head_ref" "CI-Auto-Fix")
      if (( trailer_count >= cap )); then
        log "ci SKIP pr=$pr check=$check_name (trailer count $trailer_count >= cap $cap)"
        state_apply --arg slug "$slug" --arg k "$key" '.repos[$slug].ci_seen[$k] = "capped"'
        continue
      fi

      log "ci DISPATCH repo=$slug pr=$pr check=$check_name sha=${sha:0:7}"
      "$SCRIPT_DIR/dispatch.sh" \
        --kind ci \
        --repo "$slug" \
        --pr "$pr" \
        --trigger-id "$check_id" \
        --trigger-json "$run" || log "dispatch returned non-zero for pr=$pr check=$check_name"

      state_apply --arg slug "$slug" --arg k "$key" '.repos[$slug].ci_seen[$k] = "dispatched"'
    done <<< "$runs"
  done <<< "$prs"
}

# --- Main loop -----------------------------------------------------------------

main() {
  local interval; interval=$(cfg .poll_interval_seconds)
  local bugbot_on; bugbot_on=$(cfg .triggers.bugbot_comments)
  local ci_on; ci_on=$(cfg .triggers.ci_failures)

  while true; do
    local n; n=$(cfg_repo_count)
    for ((i=0; i<n; i++)); do
      local slug; slug=$(cfg_repo "$i" .github)
      log "poll repo=$slug"
      if [[ "$bugbot_on" == "true" ]]; then
        poll_bugbot_for_repo "$i" || log "bugbot poll failed for $slug (continuing)"
      fi
      if [[ "$ci_on" == "true" ]]; then
        poll_ci_for_repo "$i" || log "ci poll failed for $slug (continuing)"
      fi
    done
    sleep "$interval"
  done
}

main "$@"
