# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

git-sync: a macOS tool that keeps local git clones fresh via a launchd agent. It fetches remotes and fast-forwards selected branches only when safe. It never merges, rebases, resets, stashes or commits; anything needing judgment becomes a *blocker*. User-facing behavior (modes, config keys, blockers, status output) is specified in `README.md` — keep it in sync when behavior changes.

## Commands

```sh
sh tests/run.sh                    # all tests
sh tests/run.sh test_a test_b      # selected tests (names are test_* functions in tests/run.sh)
sh install.sh                      # copy git-sync to ${PREFIX:-~/.local/bin}, completion to ${XDG_DATA_HOME:-~/.local/share}/git-sync
```

No build or lint step. Some completion tests need `zsh` and/or `expect` and skip without them.

## Constraints

- `git-sync` and `install.sh` are POSIX `sh` (`set -u`), with `local` as the only extension. No bashisms. Requires git >= 2.31; macOS tools only (`launchctl`, `osascript`, `shasum`).
- `git-sync-completion.sh` is sourced by both bash (incl. 3.2) and zsh; one shared hint generator (`__git_sync_hints`, prints `word<TAB>description`) feeds shell-specific front ends. Do not define `_git_sync` in bash: it clashes with git's own completion of `git sync`.
- Fetches must stay non-interactive and stall-proof (see `git_env_for`): `GIT_TERMINAL_PROMPT=0`, ssh BatchMode/timeouts, http low-speed limits, while respecting a repo's `core.sshCommand` or the caller's `GIT_SSH_COMMAND`.

## Architecture (single file: `git-sync`)

Sections are marked `# ---- name ----`; commands are `cmd_<name>` functions, dispatched by the `case` at the bottom of the file. `require_init` guards every command except `help`/`init`.

- **Config**: three layers, resolved by `cfg_get KEY [REPO]`: per-repo git config (`git-sync.mode|branches|ffCheckedOut`, mapped by `cfg_repo_name`), then global `~/.git-sync/config` (git-config format, read with `git config -f`), then `cfg_default`. Adding a key means updating `cfg_known`, `cfg_default`, `validate_value`, possibly `cfg_repo_name`, the completion file's key/value lists, and the README table. `sync.repo` (the repo list) is changed only by `install`/`uninstall`.
- **Sync pipeline**: `cmd_sync` takes the lock (`lock_acquire`; a concurrent run exits 0), then either runs `sync_one_report` inline (single repo) or, for `--all`, re-execs itself through `xargs -P sync.jobs` as the hidden `__sync-one` command (`cmd___sync_one`: jitter, then sync). Each worker appends one `result\tnew-blocker-keys\trepo` line to a shared `run.$$` file in a single write; the parent aggregates those lines for exit code and notifications. `--job` / `GS_JOB=1` marks agent-started runs: they print no per-repo lines and are the only runs that notify.
- **Per repo** (`sync_repo`): `sync_reset` clears the `SYNC_*` globals, then `sync_fetch` → `sync_ff` → `sync_maintenance` per mode. Problems go through `add_blocker`/`add_note`. `status_write` stores the result in `~/.git-sync/status/<sha1(path) first 16 hex>` (git-config format). The previous run's blocker keys feed `new_blocker_keys` for the "newly blocked" notification.
- **Agent**: `agent_write_plist` writes `~/Library/LaunchAgents/com.git-sync.agent.plist`, which runs `git-sync sync --all --job` every `sync.period`, with the caller's `PATH` and `GIT_SYNC_HOME` captured at `start` time. Changing `sync.period` reloads the agent if installed.

## Tests (`tests/run.sh`)

Each `test_*` function runs in a subshell after `sandbox`, which creates a temp `HOME`, sets `GIT_SYNC_HOME`, `GIT_SYNC_AGENTS_DIR`, `GIT_CONFIG_GLOBAL`, and stubs `launchctl` (`GIT_SYNC_LAUNCHCTL`) and the notifier (`GIT_SYNC_NOTIFY_CMD`); stub calls are logged to `$STUB_DIR/*.calls`. Helpers: `make_repos [dir]` (bare `remote.git`, clone `$WORK`, second clone `pusher`), `push_commit <branch>`, `gs` (runs the script and sets `sync.jitter=0` after `init`), `assert_eq`/`assert_contains`/…, `hints_in`/`tab_complete` for completion. New tests are discovered automatically by the `test_*()` name pattern. Use repo paths with spaces/colons where relevant (existing tests do).
