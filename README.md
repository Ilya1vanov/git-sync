# git-sync

git-sync keeps local clones fresh in the background on macOS. A launchd agent
periodically fetches the remotes of the repos you register and fast-forwards
selected local branches, but only when that is safe. It never merges, rebases,
resets, stashes or commits. Anything that would need judgment is recorded as a
*blocker* and left alone.

Requirements: macOS, git >= 2.31. It is a single POSIX `sh` file with no other
dependencies.

## Install

```sh
sh install.sh          # copies git-sync to ${PREFIX:-$HOME/.local/bin}
git-sync init          # creates ~/.git-sync with default config
cd /path/to/repo
git-sync install       # register the repo (repeat per repo)
git-sync install -r ~/projects   # or: register every repo directly inside a folder
git-sync start         # write the LaunchAgent and load it
```

`~/.local/bin` must be on your `PATH`. `git-sync start` is idempotent and also
reloads the agent. Changing the global `sync.period` reloads it automatically.

## Modes

Set per repo (`git-sync config sync.mode <mode>`) or globally with `--global`.

| Mode | Behavior |
|---|---|
| `maintain-only` | Only housekeeping (see Maintenance). |
| `maintain-and-fetch` | `git fetch --prune` for every remote, then housekeeping. |
| `fast-forward` (default) | Fetch, fast-forward the selected branches, then housekeeping. |

Branches to fast-forward: `sync.branches` if set, else the branch
`origin/HEAD` points to, else the first of `develop main master` that exists
locally. A branch needs an upstream to be updated. A branch that is only
ahead of its upstream (local commits, nothing new upstream) is left alone and
reported as a note (`develop: ahead 1 (not pushed)`). A branch that is both
ahead and behind has diverged and is a blocker, checked out or not. A
checked-out branch that could fast-forward is skipped (reported as a note)
unless `sync.ffCheckedOut` is `true`. Then it is fast-forwarded in place,
provided its worktree is clean and not mid-merge/rebase/etc.; otherwise it is
a blocker.

Caution: with `sync.ffCheckedOut=true` the in-place fast-forward is a real
`git merge --ff-only`, so the repo's `post-merge` hook runs unattended under
launchd (no terminal, launchd's environment).

## Configuration

Resolution order: per-repo value, then global value, then default. Inspect with
`git-sync config` (inside a repo shows the effective config with sources).

| Key | Per-repo | Default | Valid values |
|---|---|---|---|
| `sync.period` | no | `20m` | number with optional `s`/`m`/`h`, at least 60 s |
| `sync.mode` | yes | `fast-forward` | `maintain-only`, `maintain-and-fetch`, `fast-forward` |
| `sync.branches` | yes | unset | space-separated branch names |
| `sync.ffCheckedOut` | yes | `false` | `true`, `false` |
| `sync.jobs` | no | `8` | repos synced in parallel by `sync --all`, 1–64 |
| `sync.jitter` | no | `5s` | random 0–N s delay before each repo in `sync --all`, 0–60 |
| `log.maxSize` | no | `3M` | number with optional `K`/`M`/`G`, bytes if no unit |
| `notify.enabled` | no | `false` | `true`, `false` |
| `notify.events` | no | `blocked` | non-empty subset of `finished blocked` |

```sh
git-sync config sync.mode maintain-and-fetch      # this repo only
git-sync config sync.branches "develop main"      # this repo only
git-sync config --global sync.period 1h           # global, reloads agent
git-sync config --unset sync.mode                 # revert to the next level
```

`sync.repo` (the repo list) is managed only by `install`/`uninstall`.
`install -r <dir>` registers each immediate subdirectory of `<dir>` that is a
git working tree (depth 1, hidden folders skipped); linked worktrees resolve to
their main worktree, so they are counted as already installed.
Unknown keys are rejected unless `--force` is given.

## Commands

```
git-sync init | install [<path>] | install -r <dir> | uninstall [<path>] | list
git-sync status [--verbose] [--list-order]
git-sync start | stop
git-sync config [--global] [--force] [--unset] [<key> [<value>]]
git-sync sync [<path> | --all]
git-sync notifications [enable|disable]
git-sync help
```

- `git-sync sync` syncs the current repo, `sync <path>` the repo containing
  `<path>`, `sync --all` every registered repo.
  It prints one line per repo and exits 1 if any repo is not `ok`. Manual runs
  never send notifications.
- `sync --all` (and the scheduled job) syncs up to `sync.jobs` repos at once;
  each waits a random 0–`sync.jitter` seconds first to spread network load.
  Lines are printed in finishing order. Syncing a single repo never waits.
- A linked worktree is registered as its main worktree (with a warning).
- Only one sync runs at a time (lock in `~/.git-sync/lock`); a concurrent run
  logs that and exits 0.

## Results and blockers

Result per repo: `ok`, `blocked` (at least one blocker), `error`, `missing`
(path no longer exists). Precedence: `missing` > `error` > `blocked` > `ok`.

| Blocker | Meaning |
|---|---|
| `<branch>:dirty` | Checked-out branch's worktree has modified tracked files (`ffCheckedOut=true`). |
| `<branch>:in-progress` | Merge, rebase, cherry-pick, revert or bisect in that worktree (`ffCheckedOut=true`). |
| `<branch>:diverged` | Local branch is both ahead of and behind its upstream, so it cannot fast-forward. (Ahead only is a note, not a blocker.) |
| `<branch>:ff-failed` | Git refused the fast-forward (for example mid-rebase, an untracked file in the way, `index.lock`). |
| `fetch-failed:<remote>` | `git fetch` failed for that remote. Branches tracking it are skipped. |
| `maintenance:failed` | `git maintenance run` failed. |
| `repo:invalid` | The path exists but is not a git repository (result `error`). |

Checked-out branches that could fast-forward with `ffCheckedOut=false`, and
branches that are only ahead of their upstream, are reported as notes
(`main: skipped (checked out)`, `develop: ahead 1 (not pushed)`), not
blockers. Blockers clear on their own the
next time the condition is gone.

Fetches run non-interactively (`GIT_TERMINAL_PROMPT=0`, ssh `BatchMode=yes`),
so credential prompts fail the fetch instead of hanging. Stalled transfers
also fail instead of hanging: ssh gets `ConnectTimeout=30` and
`ServerAliveInterval=15`/`ServerAliveCountMax=3`, and http fetches abort below
1000 B/s for 60s. A repo's own `core.sshCommand` or a caller-set
`GIT_SSH_COMMAND` is respected (and then these ssh options are not added).

## Maintenance

After each sync, in every mode, git-sync runs
`git maintenance run --auto` with the commit-graph, loose-objects,
incremental-repack and pack-refs tasks enabled (gc disabled). Tasks run only
when Git's own thresholds say so. Git's maintenance scheduler
(`git maintenance start/register`) is not used.

## Status and logs

```sh
git-sync status            # agent state, period, notifications, then per repo:
                           #   <result> <last run, time ago> <path>, plus
                           #   blocker keys (or notes) on a second line
git-sync status --verbose  # full per-repo detail: mode, last run/success,
                           #   every blocker with its detail, every note
git-sync status -l         # keep sync-list order (default: blocked, error,
                           #   missing first, then the rest; combines with -v)
git-sync list              # one line per repo: path, mode, last result
```

Compact example:

```
blocked  5 minutes ago  ~/projects/api
                        blocked by: develop:dirty, fetch-failed:upstream
missing  2 days ago     ~/projects/old
ok       < 1m ago       ~/projects/app
ok       5 minutes ago  ~/projects/web
                        note: main: skipped (checked out)
pending  never          ~/projects/new
```

`pending` means the repo is registered but has not been synced yet.

Files under `~/.git-sync` (override with `GIT_SYNC_HOME`):

| Path | Content |
|---|---|
| `config` | Global config (git-config format) |
| `status/<id>` | Last result per repo (rewritten each run) |
| `git-sync.log`, `git-sync.log.1` | Rotating log; rotates when over `log.maxSize` |
| `launchd.log` | Agent stdout/stderr, truncated on each `start` |

The LaunchAgent is `~/Library/LaunchAgents/com.git-sync.agent.plist`.

## Notifications

Off by default. Only runs started by the agent notify.

```sh
git-sync notifications enable
git-sync config --global notify.events "blocked finished"
git-sync notifications            # show current state
```

Events: `finished` (counts of ok/blocked/failed), `blocked` (a repo gained a
blocker it did not have in its previous run). A run sends at most one
notification, at its end, combining both: e.g. title
`git-sync: 2 repos newly blocked`, message
`api: develop:dirty; web: fetch-failed:origin — 40 repos: 38 ok, 2 blocked, 0 failed`.
A legacy `start` in `notify.events` is ignored.

Delivery uses `osascript`, so notifications appear as coming from "Script
Editor". You may need to allow notifications for Script Editor in System
Settings > Notifications. Delivery from a launchd agent is not guaranteed;
failures are logged and ignored.

## Uninstall

```sh
git-sync stop                  # unload agent, remove the plist
rm ~/.local/bin/git-sync
rm -r ~/.git-sync
```

Optionally run `git-sync uninstall` in each repo first to drop its per-repo
`git-sync.*` settings.

## Tests

```sh
sh tests/run.sh                 # all tests
sh tests/run.sh test_name ...   # selected tests
```

Tests run in temporary sandboxes with stubbed `launchctl` and notifier, so they
never touch your real `~/.git-sync` or LaunchAgents.
