# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/Ilya1vanov/git-sync/security/advisories/new),
not in a public issue. Include the git-sync commit, your macOS and git
versions, and steps to reproduce.

Only the latest commit on `main` is supported.

## Trust model

git-sync runs as you, with your credentials. It does not sandbox git.

- **The setup line trusts GitHub and `main`.** Piping `install.sh` to `sh`
  runs whatever is on `main` (or on the `GIT_SYNC_REF` you give) at that
  moment, downloaded over HTTPS from `raw.githubusercontent.com` and
  `github.com`. There are no checksums, signatures or tagged releases; each
  update by re-running the line trusts `main` again. To review first,
  download `install.sh`, read it, then run it with `sh < install.sh` (it
  still downloads the archive of the ref), or set up from a clone you have
  read with `sh install.sh`.
- **Repo config is trusted.** Every git command git-sync runs in a repo reads
  that repo's config, including `core.sshCommand`, credential helpers and
  hooks (a fast-forward of a checked-out branch runs `post-merge`). Anyone who
  can write a repo's `.git/config` can run code as you the next time it syncs.
- **Watched roots adopt new repos automatically.** Any folder with a `.git`
  that appears directly inside a watched root is installed and synced at the
  next `sync --all`. Do not watch folders where untrusted content lands, such
  as `~/Downloads`: an extracted archive can carry a `.git` with a hostile
  config.
- **Credentials.** git-sync only fetches, but it uses your normal ssh keys
  and credential helpers. Fetches never prompt: `GIT_TERMINAL_PROMPT=0` and,
  unless you set your own ssh command, ssh `BatchMode=yes`.
- **Local files.** `~/.git-sync` (set to mode 700 by `install`, `start`, `sync` and
  settings changes; a warning is printed if that fails) holds repo
  paths and the first line of fetch errors. git redacts `user:password@` from
  URLs in those errors, but avoid credentials in remote URLs anyway.
- **Environment.** `GIT_SYNC_*` variables (for example
  `GIT_SYNC_NOTIFY_CMD`) override paths and commands for tests and are
  trusted. The launchd agent receives only `PATH` and `GIT_SYNC_HOME`,
  captured at `git-sync start`.

Config values that git-sync parses as numbers are validated on every read, so
a hand-edited `~/.git-sync/config` or `git-sync.*` repo key cannot inject
shell code.
