# AGENTS.md

`whack-a-mole` is a bash launchd daemon that polls allowlisted GitHub repos and auto-fixes "moles" (Cursor bugbot comments, failed CI) by spawning headless Claude in isolated git worktrees. **`README.md` is the source of truth** — this file is just a map. Don't duplicate README tables here.

## Spine

| File | Role |
| --- | --- |
| `watcher.sh` | Poll loop: reads config, detects triggers, dedupes via `state.json`, dispatches |
| `dispatch.sh` | Per-trigger handler: worktree + model routing + spawns headless `claude` (owns `--disallowed-tools`) |
| `lib.sh` | Shared helpers: `cfg*`, `state_*`, `pr_*`, trailer counting, `log`/`die` |
| `prompts/{bugbot-comment,ci-failure}.md` | Rubrics injected into the spawned Claude |
| `config.yaml.example` | Committed config schema; `config.yaml` is the live copy (gitignored, read in place) |
| `install.sh` / `uninstall.sh` | Idempotent symlink + launchd setup/teardown |

## When you are…

| Task | Read |
| --- | --- |
| Changing trigger detection / dedupe | `watcher.sh` (`bugbot_cursor`/`bugbot_seen`/`ci_seen` in `state.json`) + README "Loop protection" |
| Changing what spawned Claude may do | `prompts/*.md` + `--disallowed-tools` in `dispatch.sh` + README "What the spawned Claude does" |
| Changing config schema | `config.yaml.example` (the template) + README "Config" |
| Debugging runtime | README "Troubleshooting" + `~/.local/state/whack-a-mole/logs/` |

## Invariants

- Schema changes go in `config.yaml.example` — `config.yaml` is gitignored and never committed.
- Daemon re-reads config every poll: `mode`, `poll_interval_seconds`, and `triggers.*` hot-reload, no restart.
- Spawned Claude must never run tests/docker — CI owns those (`--disallowed-tools`).
- Every auto-fix commit carries its trailer (`Bugbot-Auto-Fix:` / `CI-Auto-Fix: <check>@<sha>`); loop protection reads it — never drop it.
