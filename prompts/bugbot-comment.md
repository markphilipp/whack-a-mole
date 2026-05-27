# Rubric: handling a Cursor bugbot comment

You were spawned by `whack-a-mole` because Cursor's bugbot left a new review comment on a PR I authored. Your job is to read it, decide if it's valid, and either fix it, push back, or escalate — without bothering me unless you have to.

## What you have

These env vars are set in your shell:

- `WHACKAMOLE_REPO` — `owner/repo` slug (e.g. `leaflink/marketplace`)
- `WHACKAMOLE_PR_NUMBER` — the PR number
- `WHACKAMOLE_HEAD_REF` — the PR's head branch name on the remote
- `WHACKAMOLE_HEAD_SHA` — the commit SHA bugbot reviewed
- `WHACKAMOLE_WORKTREE` — your CWD; a git worktree on the PR branch
- `WHACKAMOLE_TRIGGER_ID` — the comment ID (use this in the trailer)
- `WHACKAMOLE_TRIGGER_JSON` — the raw GitHub comment JSON
- `WHACKAMOLE_MODE` — `beta` (no push, no reply) or `live` (full)
- `WHACKAMOLE_QUICK_CHECKS` — newline-separated commands you may run for validation; `{changed}` placeholder expands to changed file paths
- `WHACKAMOLE_MAINTAINER` — GitHub login to @-mention when escalating (the repo owner)

## Decide one of three outcomes

### A) Valid finding + you can fix it confidently

1. Read the cited file and surrounding code.
2. Make the smallest correct edit.
3. **Validate locally with quick checks only.** Run the commands from `WHACKAMOLE_QUICK_CHECKS`, scoped to the files you changed. **Do NOT run** `make test`, `pytest`, `pnpm test`, `vitest`, `playwright`, `docker`, `docker-compose`, `make start`, migrations, or anything that touches the DB or network. CI will run those.
4. Commit with this exact trailer format:

   ```
   fix: <one-line summary>

   Addresses cursor[bot] review comment.

   Bugbot-Auto-Fix: $WHACKAMOLE_TRIGGER_ID
   Co-Authored-By: Claude <noreply@anthropic.com>
   ```

   (Keep `Co-Authored-By` in the same contiguous trailer block as `Bugbot-Auto-Fix` — no blank line between trailers — so the fix is attributed to Claude.)

5. If `WHACKAMOLE_MODE` is `live`:
   - Push: `git push origin HEAD:$WHACKAMOLE_HEAD_REF`
   - **Never** push to `main` or `master`. Verify the target ref before pushing.
   - **Do not reply on the comment.** The fix speaks through the pushed commit and its `Co-Authored-By: Claude` trailer — no acknowledgement reply.
   If `WHACKAMOLE_MODE` is `beta`: print the commit SHA, then stop. Do not push, do not call gh api.

### B) Not a real problem (false positive / can't reproduce / out of scope)

Don't push back publicly in my name. **Do not post a reply.** Report your reasoning (which code, why it's a false positive) in your final output and stop — no `gh api` call in any mode.

### C) Ambiguous — needs my judgment

When you're not confident enough to fix OR to confidently reject:

1. Call the **PushNotification** tool with a short, actionable message:
   `bugbot PR #<n> in <repo>: <short title> — needs your call`
2. In `live` mode, also leave a PR comment tagging me so the PR reflects it:
   ```
   gh api -X POST "repos/$WHACKAMOLE_REPO/pulls/$WHACKAMOLE_PR_NUMBER/comments/$WHACKAMOLE_TRIGGER_ID/replies" -f body="@$WHACKAMOLE_MAINTAINER — whack-a-mole couldn't auto-resolve this. Notes: <your notes>"
   ```
3. Do not push code.

## Rules

- Stay inside `$WHACKAMOLE_WORKTREE`. Don't `cd` out.
- Push only to `$WHACKAMOLE_HEAD_REF` on `origin`. Never to `main`, `master`, or any branch you didn't fetch into this worktree.
- Quick checks only. If you genuinely can't validate without heavy checks, that's a signal to use outcome C, not to run them.
- Be concise in comments and commit messages. The trailer is mandatory.
