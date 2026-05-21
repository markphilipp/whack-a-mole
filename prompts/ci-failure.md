# Rubric: handling a failed CI check

You were spawned by `whack-a-mole` because a CI check failed on the head SHA of a PR I authored. Your job is to read the failing log, identify the cause, fix it, and push — without bothering me unless you can't.

This trigger is intentionally allowed to loop: if CI fails again after your fix, you'll be spawned again on the new SHA. Don't worry about the loop — there's a cap.

## What you have

These env vars are set in your shell:

- `WHACKAMOLE_REPO` — `owner/repo` slug
- `WHACKAMOLE_PR_NUMBER` — the PR number
- `WHACKAMOLE_HEAD_REF` — the PR's head branch name on the remote
- `WHACKAMOLE_HEAD_SHA` — the commit SHA the check ran against (use in trailer)
- `WHACKAMOLE_WORKTREE` — your CWD; a git worktree on the PR branch
- `WHACKAMOLE_TRIGGER_ID` — the check-run ID
- `WHACKAMOLE_TRIGGER_JSON` — the raw check-run JSON (contains `name`, `details_url`, `html_url`, `output.summary`, etc.)
- `WHACKAMOLE_MODE` — `beta` or `live`
- `WHACKAMOLE_QUICK_CHECKS` — newline-separated commands you may run

## Step 1: read the failing log

Get the failure details. Try in order:

1. `gh api "repos/$WHACKAMOLE_REPO/check-runs/$WHACKAMOLE_TRIGGER_ID/annotations"` — most actionable when populated
2. If the check is a GitHub Actions run: pull the `details_url` from `$WHACKAMOLE_TRIGGER_JSON`, derive the run ID, then `gh run view <id> --log-failed`
3. `output.summary` and `output.text` inside `$WHACKAMOLE_TRIGGER_JSON`

Identify the actual error — file paths, line numbers, the failing assertion or rule.

## Step 2: decide one of three outcomes

### A) You can fix it confidently

1. Make the smallest correct edit to address the root cause.
2. **If the failing check is a TEST failure: do NOT run the test locally.** Tests can require DB / network / docker setup. Instead, read the test code, diff against the change you made, and reason about whether your edit fixes the failing assertion. Trust CI to verify.
3. **If the failing check is a LINT / FORMAT / TYPE check**, run the equivalent local command from `WHACKAMOLE_QUICK_CHECKS` on the changed files. That's the whole point of those commands.
4. Commit with this exact trailer format:

   ```
   fix: <one-line summary of what CI was complaining about>

   Addresses failing CI check "<check name>".

   CI-Auto-Fix: <check name>@$WHACKAMOLE_HEAD_SHA
   ```

   (The trailer uses the SHA the check was *against* — the dispatcher uses this for loop suppression.)
5. If `WHACKAMOLE_MODE` is `live`:
   - Push: `git push origin HEAD:$WHACKAMOLE_HEAD_REF`
   - **Never** push to `main`/`master`. Verify the ref.
   - Optional: comment on the PR with `gh api -X POST "repos/$WHACKAMOLE_REPO/issues/$WHACKAMOLE_PR_NUMBER/comments" -f body="Attempted CI fix for \`<check>\` in $(git rev-parse HEAD)"`
   If `WHACKAMOLE_MODE` is `beta`: print the commit SHA + the would-be comment, then stop.

### B) Cause is clear but not safely fixable from this context

Examples: flaky test, infra outage, dependency-version conflict that needs a broader judgment call.

Post an issue comment summarizing what you found, then stop. In `beta`, print what you would have posted.

### C) Cause unclear / multiple plausible fixes

1. Call **PushNotification**: `CI failing PR #<n> in <repo>: <check name> — needs your call`
2. In `live`, also leave a PR comment with your analysis tagging me.
3. Do not push code.

## Rules

- Stay inside `$WHACKAMOLE_WORKTREE`.
- Push only to `$WHACKAMOLE_HEAD_REF` on `origin`.
- **Quick checks only.** Specifically: NEVER run `make test`, `pytest`, `pnpm test`, `vitest`, `playwright`, `docker`, `docker-compose`, `make start`, migrations, or anything touching DB/network. If the failing check is one of those, see step 2 — read the test code, fix, trust CI.
- The `CI-Auto-Fix: <check>@<sha>` trailer is mandatory. The dispatcher reads it to suppress duplicate dispatches on the same SHA.
- Be concise.
