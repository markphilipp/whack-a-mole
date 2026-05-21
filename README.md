# whack-a-mole

Moles keep popping up on your PRs — Cursor bugbot findings, failing CI checks. `whack-a-mole` watches for them and bonks each one with a Claude session before you have to.

It's a small bash daemon that polls allowlisted GitHub repos every few minutes and, when it sees a new `cursor[bot]` review comment or a new failed CI check on a PR you authored, spins up a headless Opus session in an isolated git worktree on that PR's branch. The session reads the trigger, fixes if it's confident, pushes, and replies. Otherwise it pings you via the Claude app and tags you on the PR.

## Why

Two sources of friction during PR review:

- **Bugbot comments** — each one is a context switch to read, evaluate, and respond.
- **Failed CI checks** — read the log, find the cause, fix, push, wait.

Both are tractable for a focused Claude session. `whack-a-mole` automates the obvious ones so you only get pulled in for the ambiguous ones.

The CI trigger is intentionally allowed to loop: fix → CI re-runs → fail → fix again, up to a capped number of attempts.

## Requirements

- macOS (launchd plist; trivial to port to systemd if needed)
- `bash`, `git`, `gh` (authenticated), `jq`, `yq`, `claude`

```bash
brew install gh jq yq
gh auth login   # if not already
```

## Install

```bash
git clone https://github.com/markphilipp/whack-a-mole.git ~/Projects/whack-a-mole
cd ~/Projects/whack-a-mole
./install.sh
```

The installer:

- Validates `gh`/`jq`/`yq`/`claude` are present and `gh` is authenticated
- Creates `~/.local/state/whack-a-mole/{logs,}` for state + logs
- Symlinks the repo into `~/.claude/whack-a-mole`
- Symlinks the launchd plist into `~/Library/LaunchAgents/`

Edit `config.yaml` (set `my_github_login`, add your repos), then:

```bash
./install.sh --load    # starts the watcher via launchd
```

The config lives in the repo at `./config.yaml`. The daemon reads it in place via the `~/.claude/whack-a-mole` symlink — no separate copy is kept under `~/.config`. Treat the repo as private if your paths or login are sensitive.

## Config

See `config.yaml` for the full schema. Key fields:

| Field | What it does |
|---|---|
| `mode` | `alpha` = detect only · `beta` = full dispatch except push/reply · `live` = end-to-end |
| `only_my_prs` | If `true`, only act on PRs whose author == `my_github_login` |
| `my_github_login` | Your GitHub username |
| `max_bugbot_fixes_per_pr` | Tight cap (default 2) on auto-fix commits for bugbot findings |
| `max_ci_fix_attempts` | Higher cap (default 10) on auto-fix commits for CI failures |
| `poll_interval_seconds` | How often the daemon polls each repo (default 180) |
| `repos[].github` | `owner/repo` slug |
| `repos[].local` | Absolute path to your local clone |
| `repos[].worktree_root` | Relative path inside the repo where worktrees go (default `.claude/worktrees`) |
| `repos[].quick_checks` | Commands the spawned Claude is allowed to run for validation. **MUST be fast and file-scoped.** Use `{changed}` placeholder for changed file paths. |
| `triggers.bugbot_comments` | Enable/disable trigger A |
| `triggers.ci_failures` | Enable/disable trigger B |

## Rollout

The three modes exist so you can de-risk progressively:

1. **alpha** (recommended starting mode) — the watcher polls and logs every trigger it *would* dispatch, but never spawns Claude. Run for a few business days. Tail `~/.local/state/whack-a-mole/logs/watcher.log` to confirm it detects the things you'd expect (and nothing you wouldn't — e.g. dependabot or teammates' PRs should be ignored).
2. **beta** — the watcher fully dispatches: it creates a worktree, runs Claude, lets Claude edit files locally. But `git push` and `gh api` reply calls are skipped. The worktree is kept on disk for inspection. Use this to eyeball one or two real auto-fixes before flipping to live.
3. **live** — end-to-end. Pushes commits with auto-fix trailers and posts replies on the PR.

Flip the mode by editing `config.yaml` in the repo and re-saving. The daemon re-reads config every poll cycle, so no restart needed.

## Adding a repo

1. Append to the `repos:` list in `config.yaml`.
2. Make sure the `local:` path exists and is a clean checkout.
3. List `quick_checks` appropriate to the language stack — linter / formatter check / type checker only. Never tests or docker.

The daemon picks it up on the next poll cycle.

## Loop protection

| Loop type | Mechanism | Cap |
|---|---|---|
| Bugbot ↔ fix | Commits with `Bugbot-Auto-Fix: <comment_id>` trailer | `max_bugbot_fixes_per_pr` (default 2) |
| CI fail ↔ fix | Commits with `CI-Auto-Fix: <check>@<sha>` trailer | `max_ci_fix_attempts` (default 10) |
| CI re-run after push | Head commit's `CI-Auto-Fix:` trailer matches the failing `<check>@<sha>` | implicit (suppression) |

When a cap is hit, the watcher sends a PushNotification to the Claude app instead of dispatching another fix.

## What the spawned Claude does (and doesn't)

It uses **Opus** with **auto** permission mode — `claude --model opus --permission-mode auto`. Auto mode lets Opus make judgment calls about which actions are safe rather than blanket-accepting every edit. When it does need to prompt, the existing `~/.claude/settings.json` Notification hook fires a local mac notification, and the rubric tells Claude to additionally call **PushNotification** for the Claude app.

It is restricted to:

- Running linters/formatters/type-checkers from `quick_checks`
- Editing files inside the worktree
- `git commit` + `git push origin HEAD:<pr_branch>`
- `gh api` to post replies

It is explicitly disallowed (via `--disallowed-tools`) from running: `make test`, `make docker-test`, `pytest`, `pnpm test`, `npm test`, `vitest`, `playwright`, `docker`, `docker-compose`, `make start`. CI runs those.

## Layout

Source (this repo, lives at `~/Projects/whack-a-mole`):

```
.
├── README.md                                       (you are here)
├── config.yaml                                     live config (read in place via symlink)
├── watcher.sh                                      polling loop
├── dispatch.sh                                     per-trigger handler
├── lib.sh                                          shared helpers
├── prompts/
│   ├── bugbot-comment.md                           rubric for bugbot trigger
│   └── ci-failure.md                               rubric for CI trigger
├── launchd/com.markphilipp.whack-a-mole.plist      auto-start
├── install.sh                                      idempotent installer
├── uninstall.sh
└── .gitignore
```

Runtime (after `install.sh`):

```
~/.claude/whack-a-mole → ~/Projects/whack-a-mole           (symlink — daemon reads config + scripts through here)
~/Library/LaunchAgents/com.markphilipp.whack-a-mole.plist → ...  (symlink)
~/.local/state/whack-a-mole/
├── state.json                                              last-seen comment IDs + ci failures per repo
└── logs/
    ├── watcher.log                                         poll loop output
    ├── launchd.{out,err}.log                               launchd's stdout/stderr capture
    └── dispatch-{kind}-pr{n}-{trigger_id}.log              per-dispatch
```

## Troubleshooting

| Symptom | Try |
|---|---|
| `launchctl list \| grep whack-a-mole` shows nothing | `launchctl load ~/Library/LaunchAgents/com.markphilipp.whack-a-mole.plist` |
| Watcher running but nothing detected | tail `watcher.log`; confirm `gh auth status` works; confirm `mode`/`only_my_prs` settings |
| Dispatch creates worktree but Claude does nothing | tail the matching `dispatch-*.log`; check `WHACKAMOLE_*` env vars are set; check `claude` is on the PATH listed in the plist |
| Same trigger fires repeatedly | check the trailer was committed correctly (`git log --format='%(trailers)' origin/<branch>`); state file may be stale (`rm ~/.local/state/whack-a-mole/state.json` to reset) |
| Stuck worktrees | `cd <repo> && git worktree list` and `git worktree remove --force <path>` |
| Want to stop the daemon | `launchctl unload ~/Library/LaunchAgents/com.markphilipp.whack-a-mole.plist` |
| Want to fully remove | `./uninstall.sh --purge` |

## Uninstall

```bash
~/Projects/whack-a-mole/uninstall.sh          # remove symlinks + launchd, keep state
~/Projects/whack-a-mole/uninstall.sh --purge  # also delete state dir
```
