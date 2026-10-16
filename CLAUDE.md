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

- `git-sync` and `install.sh` are POSIX `sh` (`set -u`), with `local` as the only extension. No bashisms. Requires git >= 2.31; macOS tools only (`launchctl`, `osascript`, `shasum`, `route`).
- `git-sync-completion.sh` is sourced by both bash (incl. 3.2) and zsh; one shared hint generator (`__git_sync_hints`, prints `word<TAB>description`) feeds shell-specific front ends. Do not define `_git_sync` in bash: it clashes with git's own completion of `git sync`.
- Fetches must stay non-interactive and stall-proof (see `git_env_for`): `GIT_TERMINAL_PROMPT=0`, ssh BatchMode/timeouts, http low-speed limits, while respecting a repo's `core.sshCommand` or the caller's `GIT_SSH_COMMAND`.

## Architecture (single file: `git-sync`)

Sections are marked `# ---- name ----`; commands are `cmd_<name>` functions, dispatched by the `case` at the bottom of the file. `require_init` guards every command except `help`/`init`.

- **Config**: three layers, resolved by `cfg_get KEY [REPO]`: per-repo git config (`git-sync.mode|branches|ffCheckedOut`, mapped by `cfg_repo_name`), then global `~/.git-sync/config` (git-config format, read with `git config -f`), then `cfg_default`. Adding a key means updating `cfg_known`, `cfg_default`, `validate_value`, possibly `cfg_repo_name`, the key list in `cmd_config`, the completion file's key/value lists, and the README table. `sync.repo` (the repo list), `sync.root` (watched roots) and `sync.exclude` (exclusions) are changed only by `install`/`uninstall` (and `sync.repo` also by `watch_scan`); `config` reads them but refuses to set them.
- **Sync pipeline**: `cmd_sync` takes the lock (`lock_acquire`; a concurrent run exits 0); for `--all` it then runs `watch_scan` (installs new repos under watched roots, records `status.watchInstalled` for the 24h `new` note) and only then reads the repo list. Next it runs the offline check (`is_online`, skipped by `sync.disableOfflineCheck` or when no repo fetches per `needs_offline_check`): an offline run syncs nothing and records the streak (`streak_record`) in `~/.git-sync/state`, a run with at least one repo clears it (`streak_clear`). It then either runs `sync_one_report` inline (single repo) or, for `--all`, re-execs itself through `xargs -P sync.jobs` as the hidden `__sync-one` command (`cmd___sync_one`: jitter, then sync); xargs runs in the background and the parent `wait`s, so signals are handled at once. INT/TERM go through `on_signal` (deferred by `sig_defer`/`sig_resume` while a background job starts): the parent's `run_interrupted` reaps its fetch and TERMs xargs and the workers (which ignore INT), waits for them, KILLs stragglers and removes leftover `fetch.*` dirs; a worker's `worker_interrupted` stops its jitter sleep and fetch (`fetch_abort`: TERM, then KILL after `GS_ABORT_GRACE`). Each worker appends one `result\tnew-blocker-keys\trepo` line to a shared `run.$$` file in a single write; the parent aggregates those lines for exit code and notifications. `--job` / `GS_JOB=1` marks agent-started runs: they print no per-repo lines and are the only runs that notify.
- **Per repo** (`sync_repo`): `sync_reset` clears the `SYNC_*` globals, then `sync_fetch` → `sync_ff` → `sync_maintenance` per mode. `sync_fetch` runs each remote through `fetch_bounded`: the fetch in its own process group plus a sleeper (own group) that, after `sync.fetchTimeout`, marks the timeout and reaps the group (`group_reap`: TERM, KILL after `GS_FETCH_GRACE`); a fired timer yields `fetch-timeout:<remote>`, else a failure is `fetch-failed:<remote>`. Problems go through `add_blocker`/`add_note`. `status_write` stores the result in `~/.git-sync/status/<sha1(path) first 16 hex>` (git-config format). The previous run's blocker keys (`prev_blocker_keys`, read before `status_write`; a previous host-skip note for `<remote>` counts as `fetch-failed:<remote>`) feed `new_blocker_keys` for the "newly blocked" notification.
- **Unreachable hosts** (per-run shared state): before each remote's fetch, `sync_fetch` gets its host (`remote_host`: URL via `git ls-remote --get-url`, so `insteadOf` applies; `ssh://`, `git://`, `http(s)://` and scp-style, IPv6 in brackets, lowercased, port only if explicit; local paths, `file://`, `<transport>::` and anything else have no host and are never grouped). If the host's marker dir exists (`host_unreachable`), the remote is not fetched: `host_skip` adds the note `<remote>: skipped (host <H> unreachable)` and appends `<repo>\t<remote>` to the marker's `skips`, and the remote joins `SYNC_FAILED_REMOTES` (no blocker). A `fetch-failed` whose stderr (the fetch runs with `LC_ALL=C`) matches `is_connection_error` creates the marker (`host_mark_unreachable`: atomic `mkdir`, writes `name`; rc 1 if it already existed). Markers are `~/.git-sync/host.<sha1(host) first 16 hex>/{name,skips}`; the lock-owning run removes them (`host_state_clear`) at run start (leftovers of a killed run), at run end and in `run_interrupted`.
- **Agent**: `agent_write_plist` writes `~/Library/LaunchAgents/com.git-sync.agent.plist`, which runs `git-sync sync --all --job` every `sync.period`, with the caller's `PATH` and `GIT_SYNC_HOME` captured at `start` time. Changing `sync.period` reloads the agent if installed.

## Tests (`tests/run.sh`)

Each `test_*` function runs in a subshell after `sandbox`, which creates a temp `HOME`, sets `GIT_SYNC_HOME`, `GIT_SYNC_AGENTS_DIR`, `GIT_CONFIG_GLOBAL`, and stubs `launchctl` (`GIT_SYNC_LAUNCHCTL`), the notifier (`GIT_SYNC_NOTIFY_CMD`) and `route` (`GIT_SYNC_ROUTE`; offline iff `$STUB_DIR/offline` exists), and sets `GIT_SYNC_FETCH_TIMEOUT_MIN=1` (lowers the 30s minimum of `sync.fetchTimeout`); stub calls are logged to `$STUB_DIR/*.calls`. Helpers: `make_repos [dir]` (bare `remote.git`, clone `$WORK`, second clone `pusher`), `push_commit <branch>`, `gs` (runs the script and sets `sync.jitter=0` after `init`), `assert_eq`/`assert_contains`/…, `hints_in`/`tab_complete` for completion. New tests are discovered automatically by the `test_*()` name pattern. Use repo paths with spaces/colons where relevant (existing tests do).

## Agent skills

### Issue tracker

Issues live in GitHub Issues on Ilya1vanov/git-sync, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `GLOSSARY.md` + `docs/adr/`. See `docs/agents/domain.md`.
