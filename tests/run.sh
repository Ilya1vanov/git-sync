#!/bin/sh
# Test runner for git-sync. Usage: tests/run.sh [test_name ...]
set -u
ROOT=$(cd -P "$(dirname "$0")/.." && pwd)
GS="$ROOT/git-sync"
COMP="$ROOT/git-sync-completion.sh"
FAILS=0
PASSES=0

# --- helpers ---
fail() { echo "    $*" >&2; return 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected [$2] got [$1]${3:+ ($3)}"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected to contain [$2] in: $1";; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected NOT to contain [$2] in: $1";; *) ;; esac; }
assert_file() { [ -f "$1" ] || fail "missing file $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "unexpected file $1"; }

# Fresh sandbox; called at the start of every test (inside its subshell).
sandbox() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/gs-test.XXXXXX")
  T=$(cd -P "$T" && pwd)
  export HOME="$T/home"; mkdir -p "$HOME"
  export GIT_SYNC_HOME="$HOME/.git-sync"
  export GIT_SYNC_AGENTS_DIR="$HOME/Library/LaunchAgents"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test; git config --global user.email t@t
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  # launchctl stub: records calls; `print` succeeds only if $T/loaded exists
  mkdir -p "$T/bin"
  cat > "$T/bin/launchctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_DIR/launchctl.calls"
case "$1" in
  bootstrap) touch "$STUB_DIR/loaded" ;;
  bootout) [ -e "$STUB_DIR/loaded" ] || exit 3; rm -f "$STUB_DIR/loaded" ;;
  print) [ -e "$STUB_DIR/loaded" ] || exit 113 ;;
esac
exit 0
EOF
  cat > "$T/bin/notify" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "$1" "$2" >> "$STUB_DIR/notify.calls"
EOF
  # route stub: records calls; reports a default route (online) unless $STUB_DIR/offline exists
  cat > "$T/bin/route" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_DIR/route.calls"
[ ! -e "$STUB_DIR/offline" ]
EOF
  chmod +x "$T/bin/launchctl" "$T/bin/notify" "$T/bin/route"
  export STUB_DIR="$T" GIT_SYNC_LAUNCHCTL="$T/bin/launchctl" GIT_SYNC_NOTIFY_CMD="$T/bin/notify"
  export GIT_SYNC_ROUTE="$T/bin/route"
  # lowers the 30s minimum of sync.fetchTimeout so tests can use short timeouts
  export GIT_SYNC_FETCH_TIMEOUT_MIN=1
  cd "$T" || exit 1
}

# Creates $T/remote.git (bare), $T/work (clone under test), $T/pusher (second clone).
# Optional $1 = dir name for the work clone (may contain spaces).
make_repos() {
  local work="${1:-work}"
  git init -q --bare "$T/remote.git"
  git clone -q "$T/remote.git" "$T/pusher" 2>/dev/null
  ( cd "$T/pusher" && git commit -q --allow-empty -m init && git push -q origin main \
    && git checkout -q -b develop && git push -q -u origin develop && git checkout -q main ) || exit 1
  git -C "$T/remote.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$T/remote.git" "$T/$work" || exit 1
  git -C "$T/$work" branch -q --track develop origin/develop
  WORK="$T/$work"
}

# push_commit <branch> [msg]: new commit on remote branch via pusher.
push_commit() {
  ( cd "$T/pusher" && git checkout -q "$1" && git commit -q --allow-empty -m "${2:-c}" && git push -q origin "$1" ) || exit 1
}

# After `init`, sync.jitter is set to 0 so parallel test runs don't sleep.
gs() {
  "$GS" "$@" || return
  if [ "${1:-}" = init ]; then git config -f "$GIT_SYNC_HOME/config" sync.jitter 0; fi
}
# quiet CMD...: run, discard output, always succeed (for steps whose exit code is not under test).
quiet() { "$@" >/dev/null 2>&1; return 0; }
# hints_in SHELL WORD...: prints __git_sync_hints output for WORDs, run in SHELL (bash|zsh).
hints_in() {
  local sh=$1; shift
  [ "$sh" = zsh ] && sh="zsh -f"
  $sh -c '. "$1"; shift; __git_sync_hints "$@"' _ "$COMP" "$@"
}
hints() { hints_in bash "$@"; }
# bash_complete WORD...: runs __git_sync_bash with COMP_WORDS=WORDs (last one is being
# completed); prints COMPREPLY one per line. Prefers /bin/bash (3.2 on macOS).
bash_complete() {
  local b=bash
  [ -x /bin/bash ] && b=/bin/bash
  "$b" --norc --noprofile -c '
    . "$1"; shift
    COMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); COMPREPLY=()
    __git_sync_bash
    if [ ${#COMPREPLY[@]} -gt 0 ]; then printf "%s\n" "${COMPREPLY[@]}"; fi' _ "$COMP" "$@"
}
# zsh_complete WORD...: runs _git_sync_zsh with words=WORDs (last one is being
# completed) and stubbed _describe/_files/_message that print what they receive.
zsh_complete() {
  zsh -f -c '
    . "$1" 2>/dev/null; shift
    _describe() { local c; for c in "${(@P)4}"; do print -r -- "describe $c"; done; }
    _files() { print -r -- "files $*"; }
    _message() { print -r -- "message $*"; }
    words=("$@"); CURRENT=$#
    _git_sync_zsh' _ "$COMP" "$@"
}
# tab_complete SHELL LINE: types LINE<TAB><Enter> in an interactive SHELL (bash|zsh)
# with the completion loaded and git-sync stubbed to print its args one per line.
# Real readline/zle, so it sees what is actually inserted. Needs expect.
tab_complete() {
  local start init
  case $1 in
    bash) start="/bin/bash --norc --noprofile -i"; init=". '$COMP'" ;;
    zsh) start="zsh -f -i"; init="autoload -Uz compinit; compinit -u -D; . '$COMP'" ;;
  esac
  cat > "$T/tab.exp" <<'EOF'
set timeout 5
log_user 0
lassign $argv start init out line
spawn -noecho {*}$start
send "PS1='P''ROMPT>'\r"
expect "PROMPT>"
send "$init; git-sync() { printf '%s\\n' \"\$@\" > '$out'; }\r"
expect "PROMPT>"
send "$line\t"
sleep 1
send "\r"
expect "PROMPT>"
send "exit\r"
expect eof
EOF
  rm -f "$T/tab.out"
  expect -f "$T/tab.exp" "$start" "$init" "$T/tab.out" "$2" && cat "$T/tab.out"
}

# --- tests ---
test_help() {
  out=$(gs help) && assert_contains "$out" "Usage: git-sync" && assert_contains "$out" "notifications" &&
  assert_contains "$out" "install -r <dir> --watch" && assert_contains "$out" "uninstall -r <dir> --watch"
}
test_unknown_command_exit2() {
  gs bogus >/dev/null 2>"$T/err"; rc=$?
  assert_eq "$rc" 2 && assert_contains "$(cat "$T/err")" "git-sync: unknown command: bogus"
}
test_requires_init() {
  gs list >/dev/null 2>"$T/err"; rc=$?
  assert_eq "$rc" 1 && assert_contains "$(cat "$T/err")" "not initialized; run 'git-sync init'"
}
test_init_creates_defaults() {
  gs init >/dev/null &&
  assert_file "$GIT_SYNC_HOME/config" && [ -d "$GIT_SYNC_HOME/status" ] &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" sync.period)" 20m &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" sync.mode)" fast-forward &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" sync.ffCheckedOut)" false &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" log.maxSize)" 3M &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" notify.enabled)" false &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" notify.events)" blocked &&
  ! git config -f "$GIT_SYNC_HOME/config" sync.branches >/dev/null &&
  ! git config -f "$GIT_SYNC_HOME/config" sync.repo >/dev/null
}
test_init_idempotent_no_overwrite() {
  gs init >/dev/null && git config -f "$GIT_SYNC_HOME/config" sync.period 5m &&
  out=$(gs init) && assert_contains "$out" "already initialized" &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" sync.period)" 5m
}
test_init_prints_next_steps() {
  out=$(gs init) && assert_contains "$out" "git-sync install" && assert_contains "$out" "git-sync start"
}
test_install_sh_copies() {
  PREFIX="$T/bin2" sh "$ROOT/install.sh" >/dev/null && [ -x "$T/bin2/git-sync" ] &&
  cmp -s "$T/bin2/git-sync" "$GS" &&
  PREFIX="$T/bin2" sh "$ROOT/install.sh" >/dev/null
}

test_config_get_defaults() {
  gs init >/dev/null &&
  assert_eq "$(gs config sync.period)" 20m &&
  assert_eq "$(gs config sync.mode)" fast-forward &&
  assert_eq "$(gs config sync.branches)" ""
}
test_config_set_global_and_validate() {
  gs init >/dev/null &&
  gs config --global sync.period 30m && assert_eq "$(gs config sync.period)" 30m &&
  { gs config --global sync.period abc 2>"$T/err"; [ $? -ne 0 ]; } &&
  { gs config --global sync.period 30s 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global sync.mode foo 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global log.maxSize 3X 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global notify.events "blocked nope" 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global sync.branches "bad..name" 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global sync.ffCheckedOut yes 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global sync.period "$(printf '20m\nx')" 2>/dev/null; [ $? -ne 0 ]; } &&
  gs config --global notify.events "finished blocked" &&
  gs config --global log.maxSize 512K && gs config --global sync.period 90 &&
  assert_eq "$(gs config sync.period)" 90
}
test_config_fetch_timeout_default_and_valid_values() {
  gs init >/dev/null &&
  assert_eq "$(gs config sync.fetchTimeout)" 5m &&
  assert_contains "$(gs config)" "sync.fetchTimeout = 5m (default)" &&
  for v in 30s 5m 1h 90 3600s 60m; do
    gs config --global sync.fetchTimeout "$v" && assert_eq "$(gs config sync.fetchTimeout)" "$v" || return 1
  done
}
test_config_fetch_timeout_rejects_invalid() {
  unset GIT_SYNC_FETCH_TIMEOUT_MIN
  gs init >/dev/null &&
  for v in 29s 29 3601 61m 2h abc 0 5x 1.5m ""; do
    { gs config --global sync.fetchTimeout "$v" 2>"$T/err"; [ $? -ne 0 ]; } &&
    assert_contains "$(cat "$T/err")" "sync.fetchTimeout must" || { echo "    accepted [$v]"; return 1; }
  done &&
  assert_contains "$(gs config)" "sync.fetchTimeout = 5m (default)"
}
test_config_fetch_timeout_min_test_hook() {
  gs init >/dev/null &&
  gs config --global sync.fetchTimeout 2s && assert_eq "$(gs config sync.fetchTimeout)" 2s &&
  { GIT_SYNC_FETCH_TIMEOUT_MIN=10 gs config --global sync.fetchTimeout 9 2>"$T/err"; [ $? -ne 0 ]; } &&
  GIT_SYNC_FETCH_TIMEOUT_MIN=10 gs config --global sync.fetchTimeout 10 &&
  { gs config --global sync.fetchTimeout 3601 2>/dev/null; [ $? -ne 0 ]; }
}
test_config_fetch_timeout_repo_override() {
  gs init >/dev/null && make_repos && gs config --global sync.fetchTimeout 2m &&
  cd "$WORK" &&
  assert_contains "$(gs config)" "sync.fetchTimeout = 2m (global)" &&
  gs config sync.fetchTimeout 20m &&
  assert_eq "$(git config git-sync.fetchTimeout)" 20m &&
  assert_eq "$(gs config sync.fetchTimeout)" 20m &&
  assert_contains "$(gs config)" "sync.fetchTimeout = 20m (repo)" &&
  { gs config sync.fetchTimeout 2h 2>/dev/null; [ $? -ne 0 ]; } &&
  assert_eq "$(gs config --global sync.fetchTimeout)" 2m
}
test_config_repo_override_and_unset() {
  gs init >/dev/null && make_repos && cd "$WORK" &&
  gs config sync.mode maintain-only &&
  assert_eq "$(git config git-sync.mode)" maintain-only &&
  assert_eq "$(gs config sync.mode)" maintain-only &&
  out=$(gs config) && assert_contains "$out" "sync.mode = maintain-only (repo)" &&
  gs config --unset sync.mode && assert_eq "$(gs config sync.mode)" fast-forward &&
  gs config --unset sync.mode
}
test_config_global_only_key_in_repo_is_usage_error() {
  gs init >/dev/null && make_repos && cd "$WORK" &&
  { gs config sync.period 30m 2>"$T/err"; assert_eq $? 2; } &&
  assert_contains "$(cat "$T/err")" "global-only"
}
test_config_outside_repo_without_global() {
  gs init >/dev/null && mkdir "$T/plain" && cd "$T/plain" &&
  { gs config sync.mode maintain-only 2>/dev/null; assert_eq $? 2; }
}
test_config_unknown_key() {
  gs init >/dev/null &&
  { gs config --global foo.bar 1 2>/dev/null; assert_eq $? 2; } &&
  gs config --global --force foo.bar 1 &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" foo.bar)" 1
}
test_config_sync_repo_forbidden() {
  gs init >/dev/null &&
  { gs config --global sync.repo /x 2>"$T/err"; assert_eq $? 2; } &&
  assert_contains "$(cat "$T/err")" "install/uninstall"
}
test_config_list_shows_sources() {
  gs init >/dev/null && gs config --global sync.period 45m &&
  out=$(gs config) && assert_contains "$out" "sync.period = 45m (global)" &&
  assert_contains "$out" "sync.mode = fast-forward (global)" &&
  assert_not_contains "$out" "sync.repo"
}
test_config_disable_offline_check() {
  gs init >/dev/null && make_repos &&
  assert_eq "$(gs config sync.disableOfflineCheck)" false &&
  assert_contains "$(gs config)" "sync.disableOfflineCheck = false (default)" &&
  { gs config --global sync.disableOfflineCheck maybe 2>"$T/err"; [ $? -ne 0 ]; } &&
  assert_contains "$(cat "$T/err")" "sync.disableOfflineCheck must be true or false" &&
  gs config --global sync.disableOfflineCheck true &&
  assert_contains "$(gs config)" "sync.disableOfflineCheck = true (global)" &&
  gs config --global sync.disableOfflineCheck false &&
  assert_eq "$(gs config sync.disableOfflineCheck)" false &&
  { (cd "$WORK" && gs config sync.disableOfflineCheck true 2>"$T/err"); assert_eq $? 2; } &&
  assert_contains "$(cat "$T/err")" "global-only"
}

test_install_current_repo() {
  gs init >/dev/null && make_repos && cd "$WORK" &&
  out=$(gs install) && assert_contains "$out" "Installed: $WORK" &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$WORK"
}
test_install_idempotent() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  out=$(gs install "$WORK") && assert_contains "$out" "Already installed" &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo | wc -l | tr -d ' ')" 1
}
test_install_subdir_resolves_root() {
  gs init >/dev/null && make_repos && mkdir -p "$WORK/a/b" &&
  gs install "$WORK/a/b" >/dev/null &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$WORK"
}
test_install_linked_worktree_registers_main() {
  gs init >/dev/null && make_repos && git -C "$WORK" worktree add -q "$T/wt" -b feature &&
  gs install "$T/wt" >/dev/null 2>"$T/err" &&
  assert_contains "$(cat "$T/err")" "linked worktree" &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$WORK" &&
  assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "WARN"
}
test_install_not_a_repo() {
  gs init >/dev/null && mkdir "$T/plain" &&
  { gs install "$T/plain" 2>"$T/err"; assert_eq $? 1; } &&
  assert_contains "$(cat "$T/err")" "not a git repository"
}
test_install_sets_origin_head() {
  gs init >/dev/null && make_repos && git -C "$WORK" remote set-head origin -d &&
  gs install "$WORK" >/dev/null &&
  assert_eq "$(git -C "$WORK" symbolic-ref --short refs/remotes/origin/HEAD)" origin/main
}
test_install_path_with_spaces() {
  gs init >/dev/null && make_repos "my repo" &&
  gs install "$WORK" >/dev/null &&
  out=$(gs list) && assert_contains "$out" "$WORK  fast-forward  never" &&
  gs uninstall "$WORK" >/dev/null && assert_eq "$(gs list)" "No repos."
}
test_uninstall_cleans_up() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  (cd "$WORK" && gs config sync.mode maintain-only) &&
  sf="$GIT_SYNC_HOME/status/$(printf %s "$WORK" | shasum -a 1 | cut -c1-16)" &&
  : > "$sf" &&
  out=$(gs uninstall "$WORK") && assert_contains "$out" "Uninstalled: $WORK" &&
  ! git -C "$WORK" config git-sync.mode >/dev/null && assert_no_file "$sf" &&
  assert_eq "$(gs list)" "No repos."
}
test_uninstall_not_listed() {
  gs init >/dev/null && make_repos &&
  { gs uninstall "$WORK" 2>/dev/null; assert_eq $? 1; }
}
test_uninstall_missing_path() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && rm -rf "$WORK" &&
  gs uninstall "$WORK" >/dev/null && assert_eq "$(gs list)" "No repos."
}
test_list_formats() {
  gs init >/dev/null && assert_eq "$(gs list)" "No repos." &&
  make_repos && gs install "$WORK" >/dev/null &&
  (cd "$WORK" && gs config sync.mode maintain-and-fetch) &&
  assert_eq "$(gs list)" "$WORK  maintain-and-fetch  never" &&
  rm -rf "$WORK" && assert_eq "$(gs list)" "$WORK  fast-forward  missing"
}

sf_of() { echo "$GIT_SYNC_HOME/status/$(printf %s "$1" | shasum -a 1 | cut -c1-16)"; }
sget() { git config -f "$(sf_of "$1")" "status.$2"; }

test_sync_outside_repo_usage() {
  gs init >/dev/null && mkdir "$T/p" && cd "$T/p" &&
  { gs sync 2>"$T/err"; assert_eq $? 2; } && assert_contains "$(cat "$T/err")" "--all"
}
test_sync_fetch_updates_remote_refs() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  (cd "$WORK" && gs config sync.mode maintain-and-fetch) &&
  push_commit main m2 && cd "$WORK" && out=$(gs sync) &&
  assert_eq "$out" "$WORK: ok" &&
  assert_eq "$(git rev-parse origin/main)" "$(git -C "$T/remote.git" rev-parse main)" &&
  assert_eq "$(sget "$WORK" result)" ok && assert_eq "$(sget "$WORK" mode)" maintain-and-fetch &&
  [ -n "$(sget "$WORK" lastRun)" ] && [ -n "$(sget "$WORK" lastSuccess)" ]
}
test_sync_prunes_deleted_remote_branch() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  (cd "$T/pusher" && git push -q origin main:tmp) && (cd "$WORK" && gs sync >/dev/null) &&
  git -C "$WORK" rev-parse -q --verify origin/tmp >/dev/null &&
  (cd "$T/pusher" && git push -q origin :tmp) && (cd "$WORK" && gs sync >/dev/null) &&
  ! git -C "$WORK" rev-parse -q --verify origin/tmp >/dev/null
}
test_sync_maintain_only_no_fetch() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  (cd "$WORK" && gs config sync.mode maintain-only) && before=$(git -C "$WORK" rev-parse origin/main) &&
  push_commit main m2 && (cd "$WORK" && gs sync >/dev/null) &&
  assert_eq "$(git -C "$WORK" rev-parse origin/main)" "$before" && assert_eq "$(sget "$WORK" result)" ok
}
test_fetch_dead_remote_isolated() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  (cd "$WORK" && gs config sync.mode maintain-and-fetch) &&
  git -C "$WORK" remote add dead "$T/nope.git" && push_commit main m2 &&
  { (cd "$WORK" && gs sync >"$T/out"); assert_eq $? 1; } &&
  assert_eq "$(git -C "$WORK" rev-parse origin/main)" "$(git -C "$T/remote.git" rev-parse main)" &&
  assert_eq "$(sget "$WORK" result)" blocked &&
  assert_contains "$(git config -f "$(sf_of "$WORK")" --get-all status.blocker)" "fetch-failed:dead " &&
  assert_contains "$(cat "$T/out")" "$WORK: blocked (fetch-failed:dead)"
}
test_sync_all_and_missing() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  git clone -q "$T/remote.git" "$T/other" && gs install "$T/other" >/dev/null && rm -rf "$T/other" &&
  { gs sync --all >"$T/out" 2>&1; assert_eq $? 1; } &&
  assert_contains "$(cat "$T/out")" "$WORK: ok" && assert_contains "$(cat "$T/out")" "$T/other: missing" &&
  assert_eq "$(sget "$T/other" result)" missing && assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "WARN"
}
test_sync_all_no_repos() {
  gs init >/dev/null &&
  { gs sync --all >"$T/out" 2>&1; assert_eq $? 0; } &&
  { gs sync --all --job >>"$T/out" 2>&1; assert_eq $? 0; } &&
  assert_eq "$(cat "$T/out")" "" &&
  assert_eq "$(grep -c "run end: 0 ok, 0 blocked, 0 failed" "$GIT_SYNC_HOME/git-sync.log")" 2
}
test_sync_invalid_repo() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && rm -rf "$WORK/.git" &&
  { gs sync --all >/dev/null 2>&1; assert_eq $? 1; } &&
  assert_eq "$(sget "$WORK" result)" error &&
  assert_contains "$(git config -f "$(sf_of "$WORK")" --get-all status.blocker)" "repo:invalid"
}
test_sync_unlisted_repo_no_status() {
  gs init >/dev/null && make_repos && cd "$WORK" &&
  gs sync >/dev/null 2>"$T/err" && assert_contains "$(cat "$T/err")" "git-sync install" &&
  assert_no_file "$(sf_of "$WORK")"
}
test_status_file_rewritten_not_grown() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  git -C "$WORK" remote add dead "$T/nope.git" &&
  quiet "$GS" sync --all && quiet "$GS" sync --all && quiet "$GS" sync --all &&
  assert_eq "$(git config -f "$(sf_of "$WORK")" --get-all status.blocker | wc -l | tr -d ' ')" 1 &&
  ! ls -a "$GIT_SYNC_HOME/status" | grep -q tmp
}
test_last_success_carried_over() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  (cd "$WORK" && gs sync >/dev/null) && ok_at=$(sget "$WORK" lastSuccess) && [ -n "$ok_at" ] &&
  sleep 1 && git -C "$WORK" remote add dead "$T/nope.git" && (cd "$WORK" && gs sync >/dev/null);
  assert_eq "$(sget "$WORK" result)" blocked && assert_eq "$(sget "$WORK" lastSuccess)" "$ok_at"
}
test_lock_held_skips() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null || return 1
  printf '#!/bin/sh\nsleep 30\n' > "$T/bin/git-sync-holder" && chmod +x "$T/bin/git-sync-holder" || return 1
  "$T/bin/git-sync-holder" & pid=$! ; mkdir "$GIT_SYNC_HOME/lock" && echo $pid > "$GIT_SYNC_HOME/lock/pid" &&
  out=$(gs sync --all) ; rc=$? ; kill $pid ;
  assert_eq $rc 0 && assert_contains "$out" "another run in progress" && assert_no_file "$(sf_of "$WORK")"
}
test_offline_check_online_syncs() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && push_commit develop &&
  gs sync --all >/dev/null && assert_eq "$(cat "$T/route.calls")" "-n get default" &&
  assert_eq "$(git -C "$WORK" rev-parse origin/develop)" "$(git -C "$T/remote.git" rev-parse develop)" &&
  assert_eq "$(sget "$WORK" result)" ok
}
test_offline_job_run_skipped() {
  gs init >/dev/null && gs notifications enable >/dev/null && gs config --global notify.events "blocked finished" &&
  make_repos && gs install "$WORK" >/dev/null && quiet "$GS" sync --all && rm -f "$T/notify.calls" &&
  cp "$(sf_of "$WORK")" "$T/status.before" && before=$(git -C "$WORK" rev-parse origin/develop) &&
  git -C "$WORK" remote add dead "$T/nope.git" && push_commit develop && touch "$T/offline" || return 1
  out=$(gs sync --all --job 2>&1); rc=$?
  assert_eq $rc 0 && assert_eq "$out" "" &&
  cmp -s "$(sf_of "$WORK")" "$T/status.before" &&
  assert_eq "$(git -C "$WORK" rev-parse origin/develop)" "$before" &&
  assert_eq "$(ncalls)" "" &&
  assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "INFO offline, run skipped"
}
test_offline_manual_runs_skipped() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && touch "$T/offline" &&
  git clone -q "$T/remote.git" "$T/un listed" || return 1
  out=$(gs sync --all 2>&1); rc=$?
  assert_eq $rc 1 && assert_eq "$out" offline || return 1
  out=$(cd "$T" && gs sync "$WORK" 2>&1); rc=$?
  assert_eq $rc 1 && assert_eq "$out" offline || return 1
  out=$(cd "$WORK" && gs sync 2>&1); rc=$?
  assert_eq $rc 1 && assert_eq "$out" offline || return 1
  out=$(cd "$T/un listed" && gs sync 2>&1); rc=$?
  assert_eq $rc 1 && assert_eq "$out" offline &&
  assert_no_file "$(sf_of "$WORK")" && assert_no_file "$(sf_of "$T/un listed")" &&
  assert_eq "$(grep -c 'INFO offline, run skipped' "$GIT_SYNC_HOME/git-sync.log")" 4
}
streak_get() { git config -f "$GIT_SYNC_HOME/state" "offline.$1"; }
test_offline_streak_written_and_updated() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && touch "$T/offline" || return 1
  quiet "$GS" sync --all --job
  since=$(streak_get since) && last=$(streak_get lastSkip) &&
  case $since in 20*T*) ;; *) echo "bad since: $since"; return 1 ;; esac &&
  assert_eq "$last" "$since" && assert_no_file "$(sf_of "$WORK")" || return 1
  sleep 1 && quiet "$GS" sync --all
  assert_eq "$(streak_get since)" "$since" &&
  case $(streak_get lastSkip) in "$since"|'') echo "lastSkip not updated"; return 1 ;; esac
}
test_offline_zero_repos_keeps_streak() {
  gs init >/dev/null && touch "$T/offline" &&
  git config -f "$GIT_SYNC_HOME/state" offline.since 2000-01-01T00:00:00+0000 &&
  git config -f "$GIT_SYNC_HOME/state" offline.lastSkip 2000-01-02T00:00:00+0000 || return 1
  quiet "$GS" sync --all --job
  assert_eq "$(streak_get since)" 2000-01-01T00:00:00+0000 &&
  assert_eq "$(streak_get lastSkip)" 2000-01-02T00:00:00+0000
}
test_offline_streak_status_and_cleared() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null || return 1
  assert_not_contains "$(gs status)" "Offline:" || return 1
  git config -f "$GIT_SYNC_HOME/state" offline.since 2000-01-01T00:00:00+0000 &&
  git config -f "$GIT_SYNC_HOME/state" offline.lastSkip 2000-01-02T00:00:00+0000 || return 1
  out=$(gs status)
  assert_eq "$(printf '%s\n' "$out" | sed -n 4p)" \
    "Offline:       skipped since 2000-01-01T00:00:00+0000 (last 2000-01-02T00:00:00+0000)" || return 1
  gs sync --all >/dev/null
  assert_eq "$(streak_get since)$(streak_get lastSkip)" "" && assert_eq "$(sget "$WORK" result)" ok &&
  assert_not_contains "$(gs status)" "Offline:"
}
test_offline_lock_held_reports_in_progress() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && touch "$T/offline" || return 1
  printf '#!/bin/sh\nsleep 30\n' > "$T/bin/git-sync-holder" && chmod +x "$T/bin/git-sync-holder" || return 1
  "$T/bin/git-sync-holder" & pid=$! ; mkdir "$GIT_SYNC_HOME/lock" && echo $pid > "$GIT_SYNC_HOME/lock/pid" &&
  git config -f "$GIT_SYNC_HOME/state" offline.since 2000-01-01T00:00:00+0000 &&
  cp "$GIT_SYNC_HOME/state" "$T/state.before" &&
  out=$(gs sync --all) ; rc=$? ; kill $pid ;
  assert_eq $rc 0 && assert_eq "$out" "another run in progress" && assert_no_file "$T/route.calls" &&
  cmp -s "$GIT_SYNC_HOME/state" "$T/state.before"
}
test_offline_all_maintain_only_not_checked() {
  gs init >/dev/null && make_repos &&
  git clone -q "$T/remote.git" "$T/sec ond:repo" && (cd "$T/sec ond:repo" && gs config sync.mode maintain-only) &&
  gs config --global sync.mode fast-forward && (cd "$WORK" && gs config sync.mode maintain-only) &&
  gs install "$WORK" >/dev/null && gs install "$T/sec ond:repo" >/dev/null && touch "$T/offline" || return 1
  gs sync --all --job >/dev/null; rc=$?
  assert_eq $rc 0 && assert_no_file "$T/route.calls" &&
  assert_eq "$(sget "$WORK" result)" ok && assert_eq "$(sget "$T/sec ond:repo" result)" ok
}
test_offline_manual_maintain_only_not_checked() {
  gs init >/dev/null && make_repos && (cd "$WORK" && gs config sync.mode maintain-only) &&
  gs install "$WORK" >/dev/null && touch "$T/offline" || return 1
  out=$(cd "$T" && gs sync "$WORK" 2>&1); rc=$?
  assert_eq $rc 0 && assert_no_file "$T/route.calls" && assert_not_contains "$out" offline &&
  assert_eq "$(sget "$WORK" result)" ok
}
test_offline_mixed_modes_skipped() {
  gs init >/dev/null && gs config --global sync.mode maintain-only && make_repos &&
  git clone -q "$T/remote.git" "$T/fetch er" && (cd "$T/fetch er" && gs config sync.mode maintain-and-fetch) &&
  gs install "$WORK" >/dev/null && gs install "$T/fetch er" >/dev/null && touch "$T/offline" || return 1
  out=$(gs sync --all 2>&1); rc=$?
  assert_eq $rc 1 && assert_eq "$out" offline && assert_file "$T/route.calls" &&
  assert_no_file "$(sf_of "$WORK")" && assert_no_file "$(sf_of "$T/fetch er")"
}
test_offline_missing_repo_skipped() {
  gs init >/dev/null && gs config --global sync.mode maintain-only && make_repos &&
  mkdir "$T/gone" && git init -q "$T/gone" &&
  gs install "$WORK" >/dev/null && gs install "$T/gone" >/dev/null && rm -rf "$T/gone" && touch "$T/offline" || return 1
  out=$(gs sync --all 2>&1); rc=$?
  assert_eq $rc 1 && assert_eq "$out" offline && assert_file "$T/route.calls" &&
  assert_no_file "$(sf_of "$WORK")"
}
test_offline_check_disabled() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  git -C "$WORK" remote add dead "$T/nope.git" && touch "$T/offline" || return 1
  git -C "$WORK" config git-sync.disableOfflineCheck true &&
  out=$(cd "$WORK" && gs sync 2>&1); rc=$?
  assert_eq $rc 1 && assert_eq "$out" offline || return 1
  rm -f "$T/route.calls" && gs config --global sync.disableOfflineCheck true || return 1
  gs sync --all --job >/dev/null 2>&1
  assert_no_file "$T/route.calls" &&
  assert_eq "$(sget "$WORK" result)" blocked &&
  assert_contains "$(sget "$WORK" blocker)" "fetch-failed:dead"
}
test_lock_reused_pid_reclaimed() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null || return 1
  sleep 30 & pid=$! ; mkdir "$GIT_SYNC_HOME/lock" && echo $pid > "$GIT_SYNC_HOME/lock/pid" &&
  gs sync --all >/dev/null ; rc=$? ; kill $pid ;
  assert_eq $rc 0 && assert_file "$(sf_of "$WORK")" && [ ! -d "$GIT_SYNC_HOME/lock" ]
}
test_lock_stale_reclaimed() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  mkdir "$GIT_SYNC_HOME/lock" && echo 999999 > "$GIT_SYNC_HOME/lock/pid" &&
  gs sync --all >/dev/null && assert_file "$(sf_of "$WORK")" && [ ! -d "$GIT_SYNC_HOME/lock" ]
}
test_log_rotation() {
  gs init >/dev/null && gs config --global log.maxSize 1K && make_repos && gs install "$WORK" >/dev/null &&
  head -c 2000 /dev/zero | tr '\0' x > "$GIT_SYNC_HOME/git-sync.log" &&
  gs sync --all >/dev/null && assert_file "$GIT_SYNC_HOME/git-sync.log.1" &&
  [ "$(wc -c < "$GIT_SYNC_HOME/git-sync.log")" -lt 1024 ] &&
  assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "run start"
}
# ssh stub: records its args and GIT_OPTIONAL_LOCKS, then fails.
ssh_stub() {
  cat > "$T/bin/ssh" <<'EOF'
#!/bin/sh
echo "$* GIT_OPTIONAL_LOCKS=${GIT_OPTIONAL_LOCKS:-}" >> "$STUB_DIR/ssh.args"; exit 1
EOF
  chmod +x "$T/bin/ssh"
}
test_sync_env_injected() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && ssh_stub &&
  git -C "$WORK" remote add sshr "ssh://example.invalid/x.git" &&
  ( unset GIT_SSH_COMMAND GIT_SSH GIT_OPTIONAL_LOCKS; PATH="$T/bin:$PATH"; cd "$WORK" && gs sync >/dev/null 2>&1 );
  a=$(cat "$T/ssh.args" 2>/dev/null) &&
  assert_contains "$a" "BatchMode=yes" && assert_contains "$a" "ConnectTimeout=30" &&
  assert_contains "$a" "ServerAliveInterval=15" && assert_contains "$a" "GIT_OPTIONAL_LOCKS=0" &&
  assert_contains "$(blockers)" "fetch-failed:sshr"
}
test_sync_env_respects_core_sshcommand() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && ssh_stub &&
  git -C "$WORK" remote add sshr "ssh://example.invalid/x.git" &&
  git -C "$WORK" config core.sshCommand "\"$T/bin/ssh\" --marker" &&
  ( unset GIT_SSH_COMMAND GIT_SSH; cd "$WORK" && gs sync >/dev/null 2>&1 );
  a=$(cat "$T/ssh.args" 2>/dev/null) &&
  assert_contains "$a" "--marker" && assert_not_contains "$a" "BatchMode=yes"
}
# hang_stub [ignore-term]: fake ssh that never finishes. Its command line holds
# $T/bin/ssh, a unique marker for leak checks (`marked`).
hang_stub() {
  { echo '#!/bin/sh'
    [ "${1:-}" = ignore-term ] && echo "trap '' TERM"
    echo 'while :; do sleep 1; done'; } > "$T/bin/ssh"
  chmod +x "$T/bin/ssh"
}
# marked: PIDs of live processes carrying the stub marker or a sleeper of N seconds ($1).
marked() { pgrep -f "$T/bin/ssh"; [ -z "${1:-}" ] || pgrep -fx "sleep $1"; }
# gs_ssh ARGS...: run git-sync with the fake ssh first on PATH and no inherited ssh command.
gs_ssh() { ( unset GIT_SSH_COMMAND GIT_SSH; PATH="$T/bin:$PATH"; gs "$@" ); }

test_fetch_timeout_hung_remote() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && hang_stub &&
  gs config --global sync.fetchTimeout 2s && gs config --global sync.branches develop &&
  git -C "$WORK" remote add up "$T/remote.git" &&
  push_commit develop d2 && git -C "$WORK" fetch -q origin &&
  old=$(git -C "$WORK" rev-parse develop) &&
  git -C "$WORK" remote set-url origin "ssh://example.invalid/x.git" || return 1
  start=$(date +%s)
  out=$(cd "$WORK" && gs_ssh sync 2>&1); rc=$?
  el=$(( $(date +%s) - start ))
  assert_eq $rc 1 && assert_eq "$out" "$WORK: blocked (fetch-timeout:origin)" &&
  [ "$el" -lt 8 ] || { echo "    took ${el}s"; return 1; }
  assert_eq "$(blockers)" "fetch-timeout:origin timed out after 2s" &&
  assert_eq "$(git -C "$WORK" rev-parse develop)" "$old" &&
  git -C "$WORK" rev-parse -q --verify refs/remotes/up/develop >/dev/null &&
  assert_eq "$(marked)" "" &&
  assert_contains "$(gs status -v)" "  blocker:       fetch-timeout:origin timed out after 2s" &&
  assert_not_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "Terminated" || return 1
  git -C "$WORK" remote set-url origin "$T/remote.git" &&
  (cd "$WORK" && gs_ssh sync >/dev/null) && assert_eq "$(blockers)" "" &&
  assert_eq "$(git -C "$WORK" rev-parse develop)" "$(git -C "$T/remote.git" rev-parse develop)"
}
test_fetch_timeout_normal_fetch_unchanged() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  gs config --global sync.fetchTimeout 47 && push_commit main m2 && git -C "$WORK" checkout -q develop &&
  out=$(cd "$WORK" && gs sync 2>&1) && assert_eq "$out" "$WORK: ok" &&
  assert_eq "$(git -C "$WORK" rev-parse main)" "$(git -C "$T/remote.git" rev-parse main)" &&
  assert_eq "$(marked 47)" ""
}
test_fetch_timeout_parallel_and_notify() {
  gs init >/dev/null && gs notifications enable >/dev/null && gs config --global sync.jobs 2 &&
  gs config --global sync.fetchTimeout 2 && gs config --global sync.branches develop &&
  make_repos && gs install "$WORK" >/dev/null && ssh_stub &&
  git clone -q "$T/remote.git" "$T/r2" && git -C "$T/r2" branch -q --track develop origin/develop &&
  gs install "$T/r2" >/dev/null &&
  git -C "$WORK" remote add sshr "ssh://example.invalid/x.git" &&
  quiet gs_ssh sync --all --job && assert_contains "$(ncalls)" "fetch-failed:sshr" &&
  rm -f "$T/notify.calls" && hang_stub && push_commit develop d2 || return 1
  out=$(gs_ssh sync --all 2>&1); rc=$?
  assert_eq $rc 1 && assert_contains "$out" "$WORK: blocked (fetch-timeout:sshr)" &&
  assert_contains "$out" "$T/r2: ok" && assert_not_contains "$out" "Terminated" &&
  assert_eq "$(git -C "$T/r2" rev-parse develop)" "$(git -C "$T/remote.git" rev-parse develop)" &&
  assert_eq "$(git -C "$WORK" rev-parse develop)" "$(git -C "$T/remote.git" rev-parse develop)" &&
  assert_eq "$(marked)" "" || return 1
  # a switch from fetch-failed to fetch-timeout is newly blocked
  ssh_stub && quiet gs_ssh sync --all --job && rm -f "$T/notify.calls" && hang_stub &&
  quiet gs_ssh sync --all --job && assert_contains "$(ncalls)" "git-sync: work|fetch-timeout:sshr" &&
  assert_eq "$(marked)" ""
}
test_fetch_timeout_kill_escalation() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && hang_stub ignore-term &&
  gs config --global sync.fetchTimeout 1 &&
  git -C "$WORK" remote set-url origin "ssh://example.invalid/x.git" || return 1
  out=$(cd "$WORK" && gs_ssh sync 2>&1)
  assert_eq "$out" "$WORK: blocked (fetch-timeout:origin)" &&
  assert_eq "$(blockers)" "fetch-timeout:origin timed out after 1" &&
  assert_eq "$(marked)" ""
}
# poll TENTHS CONDITION: re-evaluates CONDITION every 0.1s; fails after TENTHS tries.
poll() {
  local n=0
  until eval "$2"; do n=$((n + 1)); [ "$n" -lt "$1" ] || return 1; sleep 0.1; done
}
# fetches N: true once N hanging fetches (fake ssh processes) are in flight.
fetches() { [ "$(marked | grep -c .)" -ge "$1" ]; }
# leftovers: PIDs of live fake ssh, 53s sleepers, jitter sleeps (2 decimals) or workers.
leftovers() {
  marked 53; pgrep -fx 'sleep [0-9]+\.[0-9][0-9]'; pgrep -f "__sync-one.*$GIT_SYNC_HOME/run"
}
# interrupted_run READY SIG ARGS...: starts `git-sync ARGS` in the background
# (own process group, like a terminal job; sync.fetchTimeout should be 53),
# waits until the shell condition READY holds, then sends SIG: INT to the whole
# group (Ctrl-C), TERM to the run alone. Checks the run ends promptly and leaves
# no fetch, ssh, sleeper or worker behind, no lock, no temp dir, no job notice.
interrupted_run() {
  local ready=$1 sig=$2 pid rc; shift 2
  set -m; gs_ssh "$@" > "$T/int.out" 2>&1 & pid=$!; set +m
  poll 100 "$ready" || { echo "    never ready: $ready"; kill -KILL -"$pid"; return 1; }
  if [ "$sig" = INT ]; then kill -INT -"$pid"; else kill -TERM "$(cat "$GIT_SYNC_HOME/lock/pid")"; fi
  poll 50 '! kill -0 "$pid" 2>/dev/null' || { echo "    run still alive after $sig"; kill -KILL -"$pid"; return 1; }
  wait "$pid" 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || { echo "    interrupted run exited 0"; return 1; }
  poll 30 '[ -z "$(leftovers)" ]' || { echo "    leaked: $(leftovers | tr '\n' ' ')"; kill -KILL $(leftovers) 2>/dev/null; return 1; }
  [ ! -d "$GIT_SYNC_HOME/lock" ] || { echo "    lock left behind"; return 1; }
  assert_eq "$(ls "$GIT_SYNC_HOME" | grep '^fetch\.')" "" &&
  assert_not_contains "$(cat "$T/int.out")" "Terminated" &&
  assert_not_contains "$(cat "$T/int.out")" "Interrupt"
}
test_interrupt_inline_run_stops_fetch() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && hang_stub &&
  gs config --global sync.fetchTimeout 53 &&
  git -C "$WORK" remote set-url origin "ssh://example.invalid/x.git" || return 1
  for sig in TERM INT; do
    interrupted_run 'fetches 1' "$sig" sync "$WORK" || { echo "    ($sig)"; return 1; }
  done
  # the lock is free: the next run proceeds
  ssh_stub && out=$(gs_ssh sync "$WORK" 2>&1)
  assert_eq "$out" "$WORK: blocked (fetch-failed:origin)"
}
test_interrupt_parallel_run_stops_fetches() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && hang_stub &&
  git clone -q "$T/remote.git" "$T/r2" && gs install "$T/r2" >/dev/null &&
  gs config --global sync.fetchTimeout 53 && gs config --global sync.jobs 2 &&
  git -C "$WORK" remote set-url origin "ssh://example.invalid/x.git" &&
  git -C "$T/r2" remote set-url origin "ssh://example.invalid/y.git" || return 1
  for sig in TERM INT; do
    interrupted_run 'fetches 2' "$sig" sync --all || { echo "    ($sig)"; return 1; }
  done
  ssh_stub && out=$(gs_ssh sync --all 2>&1)
  assert_contains "$out" "$WORK: blocked (fetch-failed:origin)" &&
  assert_contains "$out" "$T/r2: blocked (fetch-failed:origin)"
}
test_interrupt_kills_fetch_that_ignores_term() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && hang_stub ignore-term &&
  git clone -q "$T/remote.git" "$T/r2" && gs install "$T/r2" >/dev/null &&
  gs config --global sync.fetchTimeout 53 && gs config --global sync.jobs 2 &&
  git -C "$WORK" remote set-url origin "ssh://example.invalid/x.git" &&
  git -C "$T/r2" remote set-url origin "ssh://example.invalid/y.git" || return 1
  for sig in TERM INT; do
    interrupted_run 'fetches 1' "$sig" sync "$WORK" || { echo "    (inline $sig)"; return 1; }
    interrupted_run 'fetches 2' "$sig" sync --all || { echo "    (--all $sig)"; return 1; }
  done
}
test_interrupt_during_timeout_grace_kills_fetch() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && hang_stub ignore-term &&
  gs config --global sync.fetchTimeout 1 &&
  git -C "$WORK" remote set-url origin "ssh://example.invalid/x.git" || return 1
  # the timer has fired; the fetch ignores TERM and awaits its KILL
  interrupted_run 'fetches 1 && ls "$GIT_SYNC_HOME"/fetch.*/timeout >/dev/null 2>&1' TERM sync "$WORK"
}
test_interrupt_during_jitter_is_prompt() {
  # two workers, so that the run is still sleeping even if one draws a tiny delay
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  git clone -q "$T/remote.git" "$T/r2" && gs install "$T/r2" >/dev/null &&
  gs config --global sync.jobs 2 && gs config --global sync.jitter 50 &&
  gs config --global sync.mode maintain-only || return 1
  for sig in TERM INT; do
    interrupted_run '[ -n "$(pgrep -fx "sleep [0-9]+\.[0-9][0-9]")" ]' "$sig" sync --all || { echo "    ($sig)"; return 1; }
  done
}
test_interrupt_removes_fetch_dir_of_killed_worker() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && hang_stub &&
  gs config --global sync.fetchTimeout 53 &&
  git -C "$WORK" remote set-url origin "ssh://example.invalid/x.git" || return 1
  # fetch.1 stands for the temp dir of a worker of this run that was SIGKILLed
  interrupted_run 'fetches 1 && mkdir -p "$GIT_SYNC_HOME/fetch.1"' TERM sync --all
}
test_fetch_timeout_maintenance_still_runs() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && hang_stub &&
  gs config --global sync.fetchTimeout 1 &&
  # a negative auto limit makes `maintenance run --auto` always write the commit-graph
  git -C "$WORK" config maintenance.commit-graph.auto -1 &&
  git -C "$WORK" remote set-url origin "ssh://example.invalid/x.git" &&
  assert_no_file "$WORK/.git/objects/info/commit-graphs/commit-graph-chain" || return 1
  out=$(cd "$WORK" && gs_ssh sync 2>&1)
  assert_eq "$out" "$WORK: blocked (fetch-timeout:origin)" &&
  assert_file "$WORK/.git/objects/info/commit-graphs/commit-graph-chain"
}

# down_stub [STDERR]: fake ssh that logs its args to ssh.calls, then fails with
# STDERR (default: connection refused) and exit 255. Hangs for host hang.invalid.
down_stub() {
  { echo '#!/bin/sh'
    echo 'echo "$*" >> "$STUB_DIR/ssh.calls"'
    echo 'case "$*" in *hang.invalid*) while :; do sleep 1; done ;; esac'
    printf "echo '%s' >&2; exit 255\n" "${1:-ssh: connect to host down.invalid port 22: Connection refused}"
  } > "$T/bin/ssh"
  chmod +x "$T/bin/ssh"
}
sshcalls() { cat "$T/ssh.calls" 2>/dev/null | grep -c .; }
# allof REPO FIELD: every value of a multi-valued status field.
allof() { git config -f "$(sf_of "$1")" --get-all "status.$2"; }
# run_state: directories left in the git-sync home besides status (lock, per-run state).
run_state() { find "$GIT_SYNC_HOME" -mindepth 1 -maxdepth 1 -type d ! -name status; }
# two_on_down_host: $WORK and "$T/r 2" installed with sync.branches develop; both have
# origin/develop ahead of develop, then origin moved to the fake host down.invalid.
two_on_down_host() {
  gs init >/dev/null && gs config --global sync.branches develop && make_repos &&
  git clone -q "$T/remote.git" "$T/r 2" && git -C "$T/r 2" branch -q --track develop origin/develop &&
  gs install "$WORK" >/dev/null && gs install "$T/r 2" >/dev/null && push_commit develop d2 &&
  git -C "$WORK" fetch -q origin && git -C "$T/r 2" fetch -q origin &&
  git -C "$WORK" remote set-url origin "ssh://down.invalid/x.git" &&
  git -C "$T/r 2" remote set-url origin "ssh://down.invalid/y.git"
}

test_host_skip_sequential_two_repos() {
  two_on_down_host && down_stub && gs config --global sync.jobs 1 || return 1
  old=$(git -C "$WORK" rev-parse develop)
  out=$(gs_ssh sync --all 2>&1); rc=$?
  assert_eq $rc 1 &&
  assert_eq "$(allof "$WORK" blocker; allof "$T/r 2" blocker)" \
    "fetch-failed:origin ssh: connect to host down.invalid port 22: Connection refused" &&
  assert_eq "$(allof "$WORK" note; allof "$T/r 2" note)" "origin: skipped (host down.invalid unreachable)" &&
  assert_eq "$({ sget "$WORK" result; sget "$T/r 2" result; } | sort | paste -sd' ' -)" "blocked ok" &&
  assert_eq "$(sshcalls)" 1 &&
  assert_eq "$(git -C "$WORK" rev-parse develop)" "$old" &&
  assert_eq "$(git -C "$T/r 2" rev-parse develop)" "$old" &&
  assert_eq "$(run_state)" ""
}
test_host_skip_second_remote_same_repo() {
  gs init >/dev/null && gs config --global sync.branches develop && make_repos &&
  gs install "$WORK" >/dev/null && git -C "$WORK" remote add up "$T/remote.git" &&
  git -C "$WORK" fetch -q up && git -C "$WORK" branch -q -u up/develop develop &&
  git -C "$WORK" remote set-url origin "ssh://down.invalid/x.git" &&
  git -C "$WORK" remote add second "git@down.invalid:org/z.git" &&
  push_commit develop d2 && down_stub || return 1
  out=$(cd "$WORK" && gs_ssh sync 2>&1); rc=$?
  assert_eq $rc 1 && assert_eq "$out" "$WORK: blocked (fetch-failed:origin)" &&
  assert_eq "$(notes)" "second: skipped (host down.invalid unreachable)" &&
  assert_eq "$(sshcalls)" 1 &&
  assert_eq "$(git -C "$WORK" rev-parse develop)" "$(git -C "$T/remote.git" rev-parse develop)" &&
  assert_eq "$(run_state)" ""
}
test_host_skip_not_on_auth_error() {
  two_on_down_host && down_stub 'git@down.invalid: Permission denied (publickey).' &&
  gs config --global sync.jobs 1 || return 1
  quiet gs_ssh sync --all
  assert_eq "$(allof "$WORK" blocker; allof "$T/r 2" blocker)" \
    "fetch-failed:origin git@down.invalid: Permission denied (publickey).
fetch-failed:origin git@down.invalid: Permission denied (publickey)." &&
  assert_eq "$(allof "$WORK" note; allof "$T/r 2" note)" "" &&
  assert_eq "$(sshcalls)" 2
}
test_host_skip_not_on_fetch_timeout() {
  two_on_down_host && hang_stub && gs config --global sync.jobs 1 &&
  gs config --global sync.fetchTimeout 1 || return 1
  quiet gs_ssh sync --all
  assert_eq "$(allof "$WORK" blocker; allof "$T/r 2" blocker)" \
    "fetch-timeout:origin timed out after 1
fetch-timeout:origin timed out after 1" &&
  assert_eq "$(allof "$WORK" note; allof "$T/r 2" note)" "" &&
  assert_eq "$(marked)" ""
}
test_host_skip_state_of_killed_run_removed() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && down_stub &&
  git -C "$WORK" remote set-url origin "ssh://down.invalid/x.git" &&
  git -C "$WORK" remote add second "ssh://hang.invalid/y.git" || return 1
  # killed while fetching `second`, after origin marked its host unreachable
  set -m; gs_ssh sync "$WORK" >/dev/null 2>&1 & pid=$!; set +m
  poll 100 '[ "$(sshcalls)" = 2 ]' || { kill -KILL -"$pid" $(marked); return 1; }
  kill -KILL -"$pid"; kill -KILL $(marked); wait "$pid" 2>/dev/null
  [ -n "$(run_state | grep -v '/lock$')" ] || { echo "    no host state left by the killed run"; return 1; }
  git -C "$WORK" remote remove second && rm -f "$T/ssh.calls" || return 1
  out=$(cd "$WORK" && gs_ssh sync 2>&1)
  assert_eq "$out" "$WORK: blocked (fetch-failed:origin)" &&
  assert_eq "$(sshcalls)" 1 && assert_eq "$(notes)" "" &&
  # (the killed run's fetch temp dir is a separate, older leftover)
  assert_eq "$(run_state | grep -v '/fetch\.[0-9]*$')" ""
}
test_host_identity_ignores_case() {
  two_on_down_host && down_stub && gs config --global sync.jobs 1 &&
  git -C "$T/r 2" remote set-url origin "ssh://git@DOWN.Invalid/y.git" || return 1
  quiet gs_ssh sync --all
  assert_eq "$({ allof "$WORK" blocker; allof "$T/r 2" blocker; } | sed "s/ .*//")" "fetch-failed:origin" &&
  assert_eq "$(allof "$WORK" note; allof "$T/r 2" note)" "origin: skipped (host down.invalid unreachable)" &&
  assert_eq "$(sshcalls)" 1
}
test_host_identity_explicit_port_separates() {
  two_on_down_host && down_stub && gs config --global sync.jobs 1 &&
  git -C "$T/r 2" remote set-url origin "ssh://down.invalid:22/y.git" || return 1
  quiet gs_ssh sync --all
  assert_eq "$({ allof "$WORK" blocker; allof "$T/r 2" blocker; } | sed "s/ .*//")" \
    "fetch-failed:origin
fetch-failed:origin" &&
  assert_eq "$(allof "$WORK" note; allof "$T/r 2" note)" "" &&
  assert_eq "$(sshcalls)" 2
}
test_host_identity_https() {
  two_on_down_host && gs config --global sync.jobs 1 &&
  git -C "$WORK" remote set-url origin "https://127.0.0.1:1/x.git" &&
  git -C "$T/r 2" remote set-url origin "https://user@127.0.0.1:1/y.git" || return 1
  old=$(git -C "$WORK" rev-parse develop)
  quiet gs sync --all
  assert_eq "$({ allof "$WORK" blocker; allof "$T/r 2" blocker; } | sed "s/ .*//")" "fetch-failed:origin" &&
  assert_eq "$(allof "$WORK" note; allof "$T/r 2" note)" "origin: skipped (host 127.0.0.1:1 unreachable)" &&
  assert_eq "$(git -C "$WORK" rev-parse develop)" "$old" &&
  assert_eq "$(git -C "$T/r 2" rev-parse develop)" "$old"
}
test_host_identity_insteadof_rewritten() {
  two_on_down_host && down_stub && gs config --global sync.jobs 1 &&
  git -C "$T/r 2" config url."ssh://down.invalid/".insteadOf "gh:" &&
  git -C "$T/r 2" remote set-url origin "gh:y.git" || return 1
  quiet gs_ssh sync --all
  assert_eq "$({ allof "$WORK" blocker; allof "$T/r 2" blocker; } | sed "s/ .*//")" "fetch-failed:origin" &&
  assert_eq "$(allof "$WORK" note; allof "$T/r 2" note)" "origin: skipped (host down.invalid unreachable)" &&
  assert_eq "$(sshcalls)" 1
}
test_host_identity_ipv6() {
  two_on_down_host && gs config --global sync.jobs 1 &&
  git -C "$WORK" remote set-url origin "https://[::1]:1/x.git" &&
  git -C "$T/r 2" remote set-url origin "http://[::1]:1/y.git" || return 1
  quiet gs sync --all
  assert_eq "$({ allof "$WORK" blocker; allof "$T/r 2" blocker; } | sed "s/ .*//")" "fetch-failed:origin" &&
  assert_eq "$(allof "$WORK" note; allof "$T/r 2" note)" "origin: skipped (host [::1]:1 unreachable)"
}
test_host_identity_none_for_local_and_helper() {
  two_on_down_host && gs config --global sync.jobs 1 &&
  git -C "$WORK" remote set-url origin "$T/gone:x.git" &&
  git -C "$WORK" remote add second "file://$T/gone:x.git" &&
  git -C "$T/r 2" remote set-url origin "nohelper::down.invalid:x.git" &&
  git -C "$T/r 2" remote add second "nohelper::down.invalid:x.git" || return 1
  quiet gs sync --all
  assert_eq "$({ allof "$WORK" blocker; allof "$T/r 2" blocker; } | sed "s/ .*//")" \
    "fetch-failed:origin
fetch-failed:second
fetch-failed:origin
fetch-failed:second" &&
  assert_eq "$(allof "$WORK" note; allof "$T/r 2" note)" ""
}

ffsetup() { gs init >/dev/null && make_repos "$@" && gs install "$WORK" >/dev/null; }
blockers() { git config -f "$(sf_of "$WORK")" --get-all status.blocker; }
notes() { git config -f "$(sf_of "$WORK")" --get-all status.note; }

test_ff_default_branch_not_checked_out() {
  ffsetup && git -C "$WORK" checkout -q develop && push_commit main m2 &&
  (cd "$WORK" && gs sync >/dev/null) &&
  assert_eq "$(git -C "$WORK" rev-parse main)" "$(git -C "$T/remote.git" rev-parse main)" &&
  assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" " main: "
}
test_ff_fallback_first_existing() {
  ffsetup && git -C "$WORK" checkout -q -b scratch && git -C "$WORK" remote set-head origin -d &&
  git -C "$T/remote.git" symbolic-ref HEAD refs/heads/nonexistent &&
  before_main=$(git -C "$WORK" rev-parse main) && push_commit develop d2 && push_commit main m2 &&
  quiet sh -c 'cd "$1" && "$2" sync' _ "$WORK" "$GS" &&
  assert_eq "$(git -C "$WORK" rev-parse develop)" "$(git -C "$T/remote.git" rev-parse develop)" &&
  assert_eq "$(git -C "$WORK" rev-parse main)" "$before_main"
}
test_ff_configured_branches() {
  ffsetup && git -C "$WORK" checkout -q -b scratch && (cd "$WORK" && gs config sync.branches "develop main") &&
  push_commit develop d2 && push_commit main m2 && (cd "$WORK" && gs sync >/dev/null) &&
  assert_eq "$(git -C "$WORK" rev-parse develop)" "$(git -C "$T/remote.git" rev-parse develop)" &&
  assert_eq "$(git -C "$WORK" rev-parse main)" "$(git -C "$T/remote.git" rev-parse main)"
}
test_ff_skips_missing_and_no_upstream() {
  ffsetup && git -C "$WORK" checkout -q -b scratch && git -C "$WORK" branch -q local-only &&
  (cd "$WORK" && gs config sync.branches "local-only ghost main") && push_commit main m2 &&
  (cd "$WORK" && gs sync >/dev/null) && assert_eq "$(sget "$WORK" result)" ok && assert_eq "$(blockers)" ""
}
test_ff_diverged_blocked() {
  ffsetup && git -C "$WORK" checkout -q develop && (cd "$WORK" && gs config sync.branches main) &&
  git -C "$WORK" checkout -q main && git -C "$WORK" commit -q --allow-empty -m local &&
  git -C "$WORK" checkout -q develop && push_commit main m2 &&
  { (cd "$WORK" && gs sync >/dev/null); assert_eq $? 1; } &&
  assert_contains "$(blockers)" "main:diverged ahead 1, behind 1"
}
test_ff_ahead_only_is_note() {
  ffsetup && git -C "$WORK" checkout -q develop && git -C "$WORK" commit -q --allow-empty -m local &&
  git -C "$WORK" checkout -q main && (cd "$WORK" && gs config sync.branches develop) &&
  (cd "$WORK" && gs sync >/dev/null) && assert_eq "$(sget "$WORK" result)" ok &&
  assert_eq "$(notes)" "develop: ahead 1 (not pushed)" && assert_eq "$(blockers)" ""
}
test_ff_checked_out_skipped_by_default() {
  ffsetup && push_commit main m2 && before=$(git -C "$WORK" rev-parse main) &&
  (cd "$WORK" && gs sync >/dev/null) && assert_eq "$(git -C "$WORK" rev-parse main)" "$before" &&
  assert_eq "$(sget "$WORK" result)" ok && assert_eq "$(notes)" "main: skipped (checked out)"
}
test_ff_checked_out_clean_when_enabled() {
  ffsetup && (cd "$WORK" && gs config sync.ffCheckedOut true) && push_commit main m2 &&
  echo u > "$WORK/untracked.txt" &&
  (cd "$WORK" && gs sync >/dev/null) &&
  assert_eq "$(git -C "$WORK" rev-parse HEAD)" "$(git -C "$T/remote.git" rev-parse main)"
}
test_ff_checked_out_dirty_blocked() {
  ffsetup && (cd "$WORK" && gs config sync.ffCheckedOut true) &&
  (cd "$T/pusher" && git checkout -q main && echo a > f && git add f && git commit -qm f && git push -q origin main) &&
  (cd "$WORK" && git pull -q) && echo b > "$WORK/f" && push_commit main m3 &&
  { (cd "$WORK" && gs sync >/dev/null); assert_eq $? 1; } &&
  assert_contains "$(blockers)" "main:dirty 1 tracked files changed in $WORK"
}
test_ff_checked_out_in_progress_blocked() {
  ffsetup && (cd "$WORK" && gs config sync.ffCheckedOut true) && push_commit main m2 &&
  git -C "$WORK" rev-parse HEAD > "$WORK/.git/MERGE_HEAD" &&
  { (cd "$WORK" && gs sync >/dev/null); assert_eq $? 1; } &&
  assert_contains "$(blockers)" "main:in-progress MERGE_HEAD"
}
test_ff_untracked_would_be_overwritten() {
  ffsetup && (cd "$WORK" && gs config sync.ffCheckedOut true) &&
  (cd "$T/pusher" && git checkout -q main && echo r > clash && git add clash && git commit -qm clash && git push -q origin main) &&
  echo local > "$WORK/clash" &&
  { (cd "$WORK" && gs sync >/dev/null); assert_eq $? 1; } &&
  assert_contains "$(blockers)" "main:ff-failed" && assert_eq "$(cat "$WORK/clash")" local
}
test_ff_linked_worktree_checked_out() {
  ffsetup && (cd "$WORK" && gs config sync.branches develop && gs config sync.ffCheckedOut true) &&
  git -C "$WORK" worktree add -q "$T/wt dev" develop && push_commit develop d2 &&
  (cd "$WORK" && gs sync >/dev/null) &&
  assert_eq "$(git -C "$T/wt dev" rev-parse HEAD)" "$(git -C "$T/remote.git" rev-parse develop)" &&
  assert_eq "$(git -C "$T/wt dev" status --porcelain)" ""
}
test_ff_linked_worktree_dirty() {
  ffsetup && (cd "$WORK" && gs config sync.branches develop && gs config sync.ffCheckedOut true) &&
  git -C "$WORK" worktree add -q "$T/wt" develop &&
  (cd "$T/pusher" && git checkout -q develop && echo x > tracked && git add tracked && git commit -qm t && git push -q origin develop) &&
  git -C "$T/wt" pull -q && echo y > "$T/wt/tracked" && push_commit develop d3 &&
  { (cd "$WORK" && gs sync >/dev/null); assert_eq $? 1; } &&
  assert_contains "$(blockers)" "develop:dirty 1 tracked files changed in $T/wt"
}
test_ff_mid_rebase_blocked() {
  # develop == origin/develop (no local commits), stopped mid interactive rebase via `break`.
  ffsetup && (cd "$WORK" && gs config sync.branches develop) &&
  git -C "$WORK" checkout -q develop &&
  quiet sh -c 'cd "$1" && GIT_SEQUENCE_EDITOR="printf \"break\\n\" >" git rebase -i HEAD' _ "$WORK" &&
  git -C "$WORK" status | grep -q "rebase in progress" &&
  before=$(git -C "$WORK" rev-parse refs/heads/develop) && push_commit develop d2 &&
  quiet "$GS" sync --all &&
  assert_eq "$(git -C "$WORK" rev-parse refs/heads/develop)" "$before" &&
  assert_contains "$(blockers)" "develop:ff-failed"
}
test_ff_bisect_blocked() {
  ffsetup && (cd "$WORK" && gs config sync.branches develop) &&
  git -C "$WORK" checkout -q develop && quiet git -C "$WORK" bisect start &&
  git -C "$WORK" checkout -q --detach && [ -f "$WORK/.git/BISECT_START" ] &&
  assert_eq "$(cat "$WORK/.git/BISECT_START")" develop &&
  before=$(git -C "$WORK" rev-parse refs/heads/develop) && push_commit develop d2 &&
  { (cd "$WORK" && gs sync >/dev/null); assert_eq $? 1; } &&
  assert_eq "$(git -C "$WORK" rev-parse refs/heads/develop)" "$before" &&
  assert_contains "$(blockers)" "develop:ff-failed branch is being rebased/bisected"
}
test_ff_skips_branch_of_failed_remote() {
  ffsetup && git -C "$WORK" checkout -q -b scratch &&
  git -C "$WORK" remote add dead "$T/dead.git" && git init -q --bare "$T/dead.git" &&
  (cd "$T/pusher" && git push -q "$T/dead.git" develop:develop) && git -C "$WORK" fetch -q dead &&
  git -C "$WORK" branch -q --track dd dead/develop && rm -rf "$T/dead.git" &&
  (cd "$WORK" && gs config sync.branches "dd main") && push_commit main m2 &&
  { (cd "$WORK" && gs sync >/dev/null); assert_eq $? 1; } &&
  assert_eq "$(git -C "$WORK" rev-parse main)" "$(git -C "$T/remote.git" rev-parse main)" &&
  assert_contains "$(blockers)" "fetch-failed:dead" && assert_not_contains "$(blockers)" "dd:"
}
test_ff_path_with_spaces() {
  ffsetup "space dir" && git -C "$WORK" checkout -q develop && push_commit main m2 &&
  (cd "$WORK" && gs sync >/dev/null) &&
  assert_eq "$(git -C "$WORK" rev-parse main)" "$(git -C "$T/remote.git" rev-parse main)"
}
test_ff_mode_fetch_only_does_not_ff() {
  ffsetup && git -C "$WORK" checkout -q develop && (cd "$WORK" && gs config sync.mode maintain-and-fetch) &&
  before=$(git -C "$WORK" rev-parse main) && push_commit main m2 && (cd "$WORK" && gs sync >/dev/null) &&
  assert_eq "$(git -C "$WORK" rev-parse main)" "$before"
}
test_sync_all_stdin_not_consumed() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  git clone -q "$T/remote.git" "$T/work2" && gs install "$T/work2" >/dev/null &&
  gs sync --all >/dev/null &&
  assert_file "$(sf_of "$WORK")" && assert_file "$(sf_of "$T/work2")"
}

test_start_writes_plist_and_bootstraps() {
  gs init >/dev/null && out=$(gs start) && assert_contains "$out" "Started (every 20m)" &&
  p="$GIT_SYNC_AGENTS_DIR/com.git-sync.agent.plist" && assert_file "$p" &&
  plutil -lint "$p" >/dev/null &&
  assert_eq "$(plutil -extract StartInterval raw "$p")" 1200 &&
  assert_eq "$(plutil -extract RunAtLoad raw "$p")" true &&
  assert_eq "$(plutil -extract ProgramArguments.0 raw "$p")" "$GS" &&
  assert_eq "$(plutil -extract ProgramArguments.3 raw "$p")" "--job" &&
  assert_eq "$(plutil -extract EnvironmentVariables.GIT_SYNC_HOME raw "$p")" "$GIT_SYNC_HOME" &&
  assert_contains "$(cat "$T/launchctl.calls")" "bootstrap gui/$(id -u) $p"
}
test_start_idempotent_and_stop() {
  gs init >/dev/null && gs start >/dev/null && gs start >/dev/null &&
  assert_eq "$(grep -c '^bootstrap' "$T/launchctl.calls")" 2 &&
  gs stop >/dev/null && assert_no_file "$GIT_SYNC_AGENTS_DIR/com.git-sync.agent.plist" &&
  gs stop >/dev/null
}
test_period_change_reloads_agent() {
  gs init >/dev/null && gs start >/dev/null && gs config --global sync.period 1h &&
  assert_eq "$(plutil -extract StartInterval raw "$GIT_SYNC_AGENTS_DIR/com.git-sync.agent.plist")" 3600
}
test_period_change_without_agent_does_not_start() {
  gs init >/dev/null && gs config --global sync.period 1h &&
  assert_no_file "$GIT_SYNC_AGENTS_DIR/com.git-sync.agent.plist"
}
test_status_output() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  out=$(gs status --verbose) && assert_contains "$out" "Agent:         not loaded" &&
  assert_contains "$out" "Period:        20m" && assert_contains "$out" "Notifications: disabled" &&
  assert_contains "$out" "  result:        never" &&
  push_commit main && git -C "$WORK" remote add dead "$T/nope.git" && (cd "$WORK" && gs sync >/dev/null);
  gs start >/dev/null && out=$(gs status --verbose) && assert_contains "$out" "Agent:         loaded" &&
  assert_contains "$out" "$WORK" && assert_contains "$out" "  mode:          fast-forward" &&
  assert_contains "$out" "  result:        blocked" && assert_contains "$out" "  blocker:       fetch-failed:dead" &&
  assert_contains "$out" "  note:          main: skipped (checked out)" && assert_contains "$out" "  last run:"
}
test_status_compact() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  git clone -q "$T/remote.git" "$T/other" && gs install "$T/other" >/dev/null &&
  git clone -q "$T/remote.git" "$T/gone" && gs install "$T/gone" >/dev/null && rm -rf "$T/gone" &&
  push_commit main && git -C "$WORK" remote add dead "$T/nope.git" && quiet "$GS" sync --all &&
  git clone -q "$T/remote.git" "$T/fresh" && gs install "$T/fresh" >/dev/null &&
  out=$(gs status) &&
  assert_contains "$out" "Notifications: disabled" &&
  assert_not_contains "$out" "  mode:" && assert_not_contains "$out" "last success" &&
  # result, time-ago, path in aligned columns; blockers win over notes on line 2
  assert_contains "$out" "blocked  < 1m ago       $WORK" &&
  assert_contains "$out" "
                        blocked by: fetch-failed:dead" &&
  assert_contains "$out" "ok       < 1m ago       $T/other" &&
  assert_contains "$out" "
                        note: main: skipped (checked out)" &&
  assert_contains "$out" "missing  < 1m ago       $T/gone" &&
  assert_contains "$out" "pending  never          $T/fresh" &&
  # header (3) + work (2) + other (2) + gone (1) + fresh (1)
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 9
}
test_status_time_ago() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && quiet "$GS" sync --all &&
  sf=$(sf_of "$WORK") &&
  for spec in "-30S|< 1m ago" "-1M|1 minute ago" "-5M|5 minutes ago" "-1H|1 hour ago" \
              "-23H|23 hours ago" "-1d|1 day ago" "-40d|40 days ago"; do
    git config -f "$sf" status.lastRun "$(date -v"${spec%%|*}" +%Y-%m-%dT%H:%M:%S%z)" &&
    assert_contains "$(gs status)" "ok       $(printf '%-14s' "${spec#*|}") $WORK" || return 1
  done
}
test_sync_path_argument() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  git clone -q "$T/remote.git" "$T/other" && gs install "$T/other" >/dev/null &&
  mkdir -p "$WORK/sub" && cd "$T" &&
  out=$(gs sync "$WORK/sub") && assert_eq "$out" "$WORK: ok" &&
  assert_file "$(sf_of "$WORK")" && assert_no_file "$(sf_of "$T/other")"
}
test_sync_path_unlisted_and_errors() {
  gs init >/dev/null && make_repos && cd "$T" &&
  gs sync "$WORK" >/dev/null 2>"$T/err" && assert_contains "$(cat "$T/err")" "git-sync install" &&
  assert_no_file "$(sf_of "$WORK")" &&
  mkdir "$T/plain" &&
  { gs sync "$T/plain" 2>"$T/err"; assert_eq $? 1; } &&
  assert_contains "$(cat "$T/err")" "not a git repository: $T/plain" &&
  { gs sync --all "$WORK" 2>/dev/null; assert_eq $? 2; } &&
  { gs sync "$WORK" "$WORK" 2>/dev/null; assert_eq $? 2; }
}
test_status_attention_first_default() {
  gs init >/dev/null && make_repos &&
  git clone -q "$T/remote.git" "$T/a" && gs install "$T/a" >/dev/null &&
  git clone -q "$T/remote.git" "$T/b" && gs install "$T/b" >/dev/null &&
  git clone -q "$T/remote.git" "$T/gone" && gs install "$T/gone" >/dev/null &&
  git clone -q "$T/remote.git" "$T/c" && gs install "$T/c" >/dev/null &&
  git -C "$T/c" remote add dead "$T/nope.git" && quiet "$GS" sync --all && rm -rf "$T/gone" &&
  # default: blocked, then error, then missing, then the rest in list order
  order=$(gs status | sed -En 's/^[a-z]+ +(< 1m ago|never) +(\/.*)$/\2/p' | tr '\n' ' ') &&
  assert_eq "$order" "$T/c $T/gone $T/a $T/b " &&
  # --list-order keeps the sync list order
  order=$(gs status --list-order | sed -En 's/^[a-z]+ +(< 1m ago|never) +(\/.*)$/\2/p' | tr '\n' ' ') &&
  assert_eq "$order" "$T/a $T/b $T/gone $T/c " &&
  out=$(gs status --verbose) && assert_eq "$(printf '%s\n' "$out" | sed -n '4p')" "$T/c" &&
  out=$(gs status -l -v) && assert_eq "$(printf '%s\n' "$out" | sed -n '4p')" "$T/a" &&
  { gs status --blocked-first 2>/dev/null; assert_eq $? 2; }
}
test_status_compact_tilde_and_bad_flag() {
  gs init >/dev/null && git init -q "$HOME/proj" && gs install "$HOME/proj" >/dev/null &&
  assert_contains "$(gs status)" "pending  never          ~/proj" &&
  { gs status --bogus 2>/dev/null; assert_eq $? 2; }
}
test_status_no_repos() {
  gs init >/dev/null && out=$(gs status) && assert_contains "$out" "No repos."
}

ncalls() { cat "$T/notify.calls" 2>/dev/null; }

test_notifications_command() {
  gs init >/dev/null && assert_eq "$(gs notifications)" disabled &&
  gs notifications enable >/dev/null && assert_eq "$(gs notifications)" "enabled (blocked)" &&
  gs config --global notify.events "finished blocked" && assert_eq "$(gs notifications)" "enabled (finished blocked)" &&
  { gs config --global notify.events "start finished" 2>/dev/null; [ $? -ne 0 ]; } &&
  gs notifications disable >/dev/null && assert_eq "$(gs notifications)" disabled &&
  { gs notifications maybe 2>/dev/null; assert_eq $? 2; }
}
test_notify_only_in_job_and_enabled() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && git -C "$WORK" remote add dead "$T/nope.git" &&
  quiet "$GS" sync --all --job && assert_eq "$(ncalls)" "" &&
  gs notifications enable >/dev/null && quiet "$GS" sync --all && assert_eq "$(ncalls)" "" &&
  git -C "$WORK" remote add dead2 "$T/nope2.git" &&
  quiet "$GS" sync --all --job && assert_contains "$(ncalls)" "git-sync: work|fetch-failed:dead2"
}
test_notify_blocked_dedupe() {
  gs init >/dev/null && gs notifications enable >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  git -C "$WORK" remote add dead "$T/nope.git" &&
  quiet "$GS" sync --all --job && quiet "$GS" sync --all --job &&
  assert_eq "$(ncalls | wc -l | tr -d ' ')" 1 &&
  git -C "$WORK" remote add dead2 "$T/nope2.git" && quiet "$GS" sync --all --job &&
  assert_eq "$(ncalls | tail -1)" "git-sync: work|fetch-failed:dead2"
}
test_notify_finished_summary() {
  gs init >/dev/null && gs notifications enable >/dev/null && gs config --global notify.events finished &&
  make_repos && gs install "$WORK" >/dev/null && gs sync --all --job >/dev/null 2>&1 &&
  assert_eq "$(ncalls)" "git-sync|1 repos: 1 ok, 0 blocked, 0 failed"
}
test_notify_one_per_run_combined() {
  gs init >/dev/null && gs notifications enable >/dev/null && gs config --global notify.events "blocked finished" &&
  make_repos && gs install "$WORK" >/dev/null && git -C "$WORK" remote add dead "$T/nope.git" &&
  git clone -q "$T/remote.git" "$T/other" && gs install "$T/other" >/dev/null &&
  git -C "$T/other" remote add dead "$T/nope.git" &&
  quiet "$GS" sync --all --job &&
  assert_eq "$(ncalls)" "git-sync: 2 repos newly blocked|other: fetch-failed:dead; work: fetch-failed:dead — 2 repos: 0 ok, 2 blocked, 0 failed" &&
  # next run: nothing new, only the summary
  quiet "$GS" sync --all --job &&
  assert_eq "$(ncalls | wc -l | tr -d ' ')" 2 &&
  assert_eq "$(ncalls | tail -1)" "git-sync|2 repos: 0 ok, 2 blocked, 0 failed"
}
test_notify_legacy_start_ignored() {
  gs init >/dev/null && gs notifications enable >/dev/null &&
  git config -f "$GIT_SYNC_HOME/config" notify.events "start blocked" &&
  make_repos && gs install "$WORK" >/dev/null && git -C "$WORK" remote add dead "$T/nope.git" &&
  quiet "$GS" sync --all --job &&
  assert_eq "$(ncalls)" "git-sync: work|fetch-failed:dead"
}
test_job_mode_quiet_stdout() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  out=$(gs sync --all --job 2>/dev/null) && assert_eq "$out" ""
}
test_install_recursive_depth1() {
  gs init >/dev/null && make_repos && mkdir -p "$T/projects/plain" "$T/projects/deep/inner" &&
  git clone -q "$T/remote.git" "$T/projects/a" && git clone -q "$T/remote.git" "$T/projects/b c" &&
  git clone -q "$T/remote.git" "$T/projects/deep/inner/x" &&
  gs install "$T/projects/a" >/dev/null &&
  out=$(gs install -r "$T/projects") &&
  assert_contains "$out" "Already installed: $T/projects/a" &&
  assert_contains "$out" "Installed: $T/projects/b c" &&
  assert_contains "$out" "1 installed, 1 already installed, 0 failed" &&
  assert_eq "$(gs list | wc -l | tr -d ' ')" 2 &&
  assert_not_contains "$(gs list)" "inner"
}
test_install_recursive_skips_linked_worktree_dup() {
  gs init >/dev/null && make_repos && mkdir "$T/projects" &&
  git clone -q "$T/remote.git" "$T/projects/a" &&
  git -C "$T/projects/a" worktree add -q "$T/projects/a-wt" -b feature &&
  out=$(gs install -r "$T/projects" 2>/dev/null) &&
  assert_contains "$out" "1 installed, 1 already installed, 0 failed" &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$T/projects/a"
}
test_install_recursive_no_repos_and_bad_dir() {
  gs init >/dev/null && mkdir "$T/empty" &&
  { gs install -r "$T/empty" 2>"$T/err"; assert_eq $? 1; } &&
  assert_contains "$(cat "$T/err")" "no git repositories found in $T/empty" &&
  { gs install -r "$T/nope" 2>"$T/err"; assert_eq $? 1; } &&
  assert_contains "$(cat "$T/err")" "not a directory: $T/nope" &&
  { gs install -r 2>/dev/null; assert_eq $? 2; }
}
roots() { git config -f "$GIT_SYNC_HOME/config" --get-all sync.root; }
excludes() { git config -f "$GIT_SYNC_HOME/config" --get-all sync.exclude; }
test_watch_install_adds_root() {
  gs init >/dev/null && make_repos && mkdir "$T/pro: jects" &&
  git clone -q "$T/remote.git" "$T/pro: jects/a" &&
  out=$(gs install -r "$T/pro: jects" --watch) &&
  assert_contains "$out" "Installed: $T/pro: jects/a" &&
  assert_contains "$out" "Watching: $T/pro: jects" &&
  assert_eq "$(roots)" "$T/pro: jects" &&
  assert_eq "$(gs config sync.root)" "$T/pro: jects"
}
test_watch_empty_folder_and_already_watched() {
  gs init >/dev/null && mkdir "$T/empty" && ln -s "$T/empty" "$T/link" &&
  out=$(gs install -r "$T/empty" --watch) &&
  assert_contains "$out" "Watching: $T/empty" &&
  out=$(cd "$T" && gs install -r link/ --watch) &&
  assert_eq "$out" "Already watched: $T/empty" &&
  assert_eq "$(roots)" "$T/empty" &&
  { gs install -r "$T/nope" --watch 2>/dev/null; assert_eq $? 1; } &&
  { gs install -r "$T/empty" --bogus 2>/dev/null; assert_eq $? 2; } &&
  assert_eq "$(roots)" "$T/empty"
}
test_config_root_exclude_read_only() {
  gs init >/dev/null && mkdir "$T/p" && gs install -r "$T/p" --watch >/dev/null &&
  assert_eq "$(gs config sync.root)" "$T/p" &&
  { gs config sync.exclude >/dev/null; assert_eq $? 1; } &&
  { gs config --global sync.root /x 2>"$T/err"; assert_eq $? 2; } &&
  assert_contains "$(cat "$T/err")" "sync.root is managed by 'git-sync install/uninstall'" &&
  { gs config --global --unset sync.exclude 2>"$T/err"; assert_eq $? 2; } &&
  assert_contains "$(cat "$T/err")" "sync.exclude is managed by 'git-sync install/uninstall'" &&
  assert_not_contains "$(gs config)" "sync.root" && assert_eq "$(roots)" "$T/p"
}
test_watch_scan_installs_and_syncs_new_clone() {
  gs init >/dev/null && make_repos && mkdir "$T/a: b" && gs install -r "$T/a: b" --watch >/dev/null &&
  git clone -q "$T/remote.git" "$T/a: b/new c" && push_commit main m2 &&
  out=$(gs sync --all) &&
  assert_contains "$out" "$T/a: b/new c: ok" &&
  assert_contains "$(gs list)" "$T/a: b/new c  fast-forward  ok" &&
  assert_eq "$(git -C "$T/a: b/new c" rev-parse refs/remotes/origin/main)" "$(git -C "$T/remote.git" rev-parse main)" &&
  assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "INFO installed $T/a: b/new c (watched root $T/a: b)" &&
  gs sync --all >/dev/null &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$T/a: b/new c"
}
test_watch_sync_path_does_not_scan() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && mkdir "$T/p" &&
  gs install -r "$T/p" --watch >/dev/null && git clone -q "$T/remote.git" "$T/p/x" &&
  (cd "$WORK" && gs sync >/dev/null) && gs sync "$WORK" >/dev/null &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$WORK"
}
test_watch_offline_skip_still_installs() {
  gs init >/dev/null && make_repos && mkdir "$T/p" && gs install -r "$T/p" --watch >/dev/null &&
  git clone -q "$T/remote.git" "$T/p/x" && touch "$T/offline" &&
  { gs sync --all >/dev/null 2>&1; assert_eq $? 1; } &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$T/p/x" &&
  assert_contains "$(gs list)" "$T/p/x  fast-forward  never" &&
  rm "$T/offline" && gs sync --all >/dev/null && assert_eq "$(sget "$T/p/x" result)" ok
}
test_watch_uninstall_excludes_until_install() {
  gs init >/dev/null && make_repos && mkdir "$T/p: q" && git clone -q "$T/remote.git" "$T/p: q/x y" &&
  gs install -r "$T/p: q" --watch >/dev/null &&
  out=$(gs uninstall "$T/p: q/x y") && assert_contains "$out" "Uninstalled: $T/p: q/x y" &&
  assert_eq "$(excludes)" "$T/p: q/x y" &&
  rm -rf "$T/p: q/x y" && git clone -q "$T/remote.git" "$T/p: q/x y" &&
  gs sync --all >/dev/null && assert_eq "$(gs list | sed -n 1p)" "No repos." &&
  out=$(gs install -r "$T/p: q") &&
  assert_contains "$out" "0 installed, 0 already installed, 0 failed, 1 excluded" &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "" &&
  gs install "$T/p: q/x y" >/dev/null && assert_eq "$(excludes)" "" &&
  gs uninstall "$T/p: q/x y" >/dev/null && gs install "$T/p: q/x y" >/dev/null &&
  gs uninstall "$T/p: q/x y" >/dev/null && assert_eq "$(excludes)" "$T/p: q/x y" &&
  git config -f "$GIT_SYNC_HOME/config" --add sync.repo "$T/p: q/x y" &&
  out=$(gs install "$T/p: q/x y") && assert_contains "$out" "Already installed" && assert_eq "$(excludes)" ""
}
test_watch_unwatch_keeps_repos_and_exclusions() {
  gs init >/dev/null && make_repos && mkdir "$T/p: q" && ln -s "$T/p: q" "$T/l" &&
  git clone -q "$T/remote.git" "$T/p: q/a" && git clone -q "$T/remote.git" "$T/p: q/b" &&
  gs install -r "$T/p: q" --watch >/dev/null && gs uninstall "$T/p: q/b" >/dev/null &&
  out=$(gs uninstall -r "$T/l" --watch) && assert_eq "$out" "Unwatched: $T/p: q" &&
  assert_eq "$(roots)" "" && assert_eq "$(excludes)" "$T/p: q/b" &&
  git clone -q "$T/remote.git" "$T/p: q/c" && gs sync --all >/dev/null &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$T/p: q/a" &&
  { gs uninstall -r "$T/p: q" --watch 2>"$T/err"; assert_eq $? 1; } &&
  assert_contains "$(cat "$T/err")" "not a watched root: $T/p: q" &&
  { gs uninstall -r "$T/p: q" 2>/dev/null; assert_eq $? 2; } &&
  gs install -r "$T/p: q" --watch >/dev/null && rm -rf "$T/p: q" &&
  gs uninstall -r "$T/p: q/" --watch >/dev/null && assert_eq "$(roots)" ""
}
test_watch_missing_root_warns() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && mkdir "$T/p q" &&
  gs install -r "$T/p q" --watch >/dev/null && rmdir "$T/p q" &&
  gs sync --all >/dev/null 2>"$T/err" &&
  assert_eq "$(cat "$T/err")" "git-sync: warning: watched root missing or unreadable: $T/p q" &&
  gs sync --all --job >/dev/null 2>"$T/err" && assert_eq "$(cat "$T/err")" "" &&
  assert_eq "$(grep -c "WARN watched root missing or unreadable: $T/p q" "$GIT_SYNC_HOME/git-sync.log")" 2 &&
  gs notifications enable >/dev/null && gs config --global notify.events "blocked finished" &&
  gs sync --all --job && assert_eq "$(cat "$T/notify.calls")" "git-sync|1 repos: 1 ok, 0 blocked, 0 failed"
}
test_watch_bad_child_skipped() {
  gs init >/dev/null && make_repos && mkdir -p "$T/p/bad" && echo "gitdir: $T/nope" > "$T/p/bad/.git" &&
  gs install -r "$T/p" --watch >/dev/null 2>&1; git clone -q "$T/remote.git" "$T/p/good" &&
  gs sync --all >/dev/null 2>"$T/err" && gs sync --all >/dev/null 2>&1 &&
  assert_eq "$(cat "$T/err")" "" &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$T/p/good" &&
  assert_eq "$(grep -c "WARN skipped $T/p/bad: not a usable repository (watched root $T/p)" "$GIT_SYNC_HOME/git-sync.log")" 2
}
test_watch_list_sections() {
  gs init >/dev/null && make_repos && mkdir "$T/p" "$T/q r" && git clone -q "$T/remote.git" "$T/p/a" &&
  gs install -r "$T/p" --watch >/dev/null && gs install -r "$T/q r" --watch >/dev/null &&
  assert_eq "$(gs list)" "$(printf '%s\n\n%s\n%s\n%s' "$T/p/a  fast-forward  never" "Watched roots:" "  $T/p" "  $T/q r")" &&
  gs uninstall "$T/p/a" >/dev/null &&
  assert_eq "$(gs list)" "$(printf '%s\n\n%s\n%s\n%s\n\n%s\n%s' "No repos." "Watched roots:" "  $T/p" "  $T/q r" "Excluded:" "  $T/p/a")" &&
  gs uninstall -r "$T/p" --watch >/dev/null && gs uninstall -r "$T/q r" --watch >/dev/null &&
  assert_eq "$(gs list)" "$(printf '%s\n\n%s\n%s' "No repos." "Excluded:" "  $T/p/a")"
}
test_list_watch_only_roots() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  out=$(gs list --watch) && assert_eq "$out" "" &&
  mkdir "$T/p: q" "$T/r" && gs install -r "$T/p: q" --watch >/dev/null && gs install -r "$T/r" --watch >/dev/null &&
  assert_eq "$(gs list --watch)" "$(printf '%s\n%s' "$T/p: q" "$T/r")" &&
  { gs list --bogus 2>"$T/err"; assert_eq $? 2; } &&
  assert_contains "$(cat "$T/err")" "usage: git-sync list [--watch]"
}
test_watch_new_note_24h() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null && mkdir "$T/p" &&
  gs install -r "$T/p" --watch >/dev/null && git clone -q "$T/remote.git" "$T/p/x" &&
  touch "$T/offline" && quiet "$GS" sync --all && rm "$T/offline" &&
  assert_contains "$(gs status)" "$(printf 'pending  never          %s\n%24snote: new' "$T/p/x" '')" &&
  gs sync --all >/dev/null && gs sync --all >/dev/null &&
  [ -n "$(sget "$T/p/x" watchInstalled)" ] &&
  assert_contains "$(gs status)" "$(printf 'ok       < 1m ago       %s\n%24snote: new' "$T/p/x" '')" &&
  assert_contains "$(gs status -v)" "$(printf '%s\n  mode:          fast-forward\n  result:        ok' "$T/p/x")" &&
  assert_contains "$(gs status -v)" "  note:          new" &&
  assert_eq "$(gs status | grep -c 'note: new')" 1 &&
  git config -f "$(sf_of "$T/p/x")" status.watchInstalled "$(date -v-23H +%Y-%m-%dT%H:%M:%S%z)" &&
  assert_contains "$(gs status)" "note: new" &&
  git config -f "$(sf_of "$T/p/x")" status.watchInstalled "$(date -v-25H +%Y-%m-%dT%H:%M:%S%z)" &&
  assert_not_contains "$(gs status)" "note: new" && assert_not_contains "$(gs status -v)" "new"
}
test_watch_uninstall_outside_root_no_exclusion() {
  gs init >/dev/null && make_repos && mkdir -p "$T/p/deep" && gs install -r "$T/p" --watch >/dev/null &&
  git clone -q "$T/remote.git" "$T/p/deep/x" && gs install "$T/p/deep/x" >/dev/null &&
  gs install "$WORK" >/dev/null && gs uninstall "$WORK" >/dev/null && gs uninstall "$T/p/deep/x" >/dev/null &&
  assert_eq "$(excludes)" ""
}
test_watch_linked_worktrees() {
  gs init >/dev/null && make_repos && mkdir "$T/p" "$T/q" &&
  git -C "$WORK" worktree add -q "$T/p/work-wt" -b f1 &&
  git clone -q "$T/remote.git" "$T/q/m" && git -C "$T/q/m" worktree add -q "$T/q/m-wt" -b f2 &&
  gs install -r "$T/p" --watch >/dev/null 2>&1 && gs install -r "$T/q" --watch >/dev/null 2>&1 &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo | sort)" "$(printf '%s\n%s' "$T/q/m" "$WORK" | sort)" &&
  gs uninstall "$WORK" >/dev/null && gs uninstall "$T/q/m" >/dev/null &&
  assert_eq "$(excludes)" "$T/q/m" &&
  gs sync --all >/dev/null &&
  assert_eq "$(git config -f "$GIT_SYNC_HOME/config" --get-all sync.repo)" "$WORK" &&
  assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "installed $WORK (watched root $T/p)"
}
test_config_jobs_jitter() {
  "$GS" init >/dev/null &&
  assert_eq "$(gs config sync.jobs)" 8 && assert_eq "$(gs config sync.jitter)" 5s &&
  gs config --global sync.jobs 1 && gs config --global sync.jobs 64 &&
  gs config --global sync.jitter 0 && gs config --global sync.jitter 60s && gs config --global sync.jitter 7 &&
  { gs config --global sync.jobs 0 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global sync.jobs 65 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global sync.jobs x 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global sync.jitter 61 2>/dev/null; [ $? -ne 0 ]; } &&
  { gs config --global sync.jitter 5m 2>/dev/null; [ $? -ne 0 ]; } &&
  make_repos && cd "$WORK" &&
  { gs config sync.jobs 4 2>/dev/null; assert_eq $? 2; }
}
# make_many N: N clones of remote.git installed as $T/r1..$T/rN
make_many() {
  local i=1
  while [ "$i" -le "$1" ]; do
    git clone -q "$T/remote.git" "$T/r$i" && git -C "$T/r$i" branch -q --track develop origin/develop &&
      gs install "$T/r$i" >/dev/null || return 1
    i=$((i + 1))
  done
}
test_sync_parallel_all_repos() {
  gs init >/dev/null && gs config --global sync.jobs 4 && gs config --global sync.branches develop &&
  make_repos && make_many 6 &&
  git -C "$T/r3" remote add dead "$T/nope.git" && push_commit develop d2 &&
  { gs sync --all >"$T/out" 2>&1; assert_eq $? 1; } &&
  assert_eq "$(grep -c ': ok$' "$T/out")" 5 &&
  assert_contains "$(cat "$T/out")" "$T/r3: blocked (fetch-failed:dead)" &&
  assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "run end: 5 ok, 1 blocked, 0 failed" &&
  for i in 1 2 4 5 6; do
    assert_eq "$(git -C "$T/r$i" rev-parse develop)" "$(git -C "$T/remote.git" rev-parse develop)" || return 1
    assert_eq "$(sget "$T/r$i" result)" ok || return 1
  done &&
  ! ls "$GIT_SYNC_HOME" | grep -q '^run\.' && [ ! -d "$GIT_SYNC_HOME/lock" ]
}
test_sync_parallel_jobs1_and_missing() {
  gs init >/dev/null && gs config --global sync.jobs 1 && make_repos && make_many 3 &&
  rm -rf "$T/r2" &&
  { gs sync --all >"$T/out" 2>&1; assert_eq $? 1; } &&
  assert_eq "$(cat "$T/out" | wc -l | tr -d ' ')" 3 &&
  assert_contains "$(cat "$T/out")" "$T/r2: missing" &&
  assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "run end: 2 ok, 0 blocked, 1 failed"
}
test_sync_jitter_applies_to_all_only() {
  gs init >/dev/null && gs config --global sync.jitter 3 && make_repos && gs install "$WORK" >/dev/null &&
  start=$(date +%s) && (cd "$WORK" && gs sync >/dev/null) &&
  [ $(( $(date +%s) - start )) -lt 3 ] &&
  gs config --global sync.jitter 0 && start=$(date +%s) && gs sync --all >/dev/null &&
  [ $(( $(date +%s) - start )) -lt 3 ]
}
test_status_tricky_values() {
  gs init >/dev/null && make_repos "sp ace" && gs install "$WORK" >/dev/null && quiet "$GS" sync --all &&
  sf=$(sf_of "$WORK") &&
  git config -f "$sf" status.result blocked &&
  git config -f "$sf" --add status.blocker 'main:ff-failed fatal: "x" = y; #z \ end' &&
  git config -f "$sf" --add status.blocker 'fetch-failed:origin  two  spaces' &&
  out=$(gs status -v) &&
  assert_contains "$out" '  blocker:       main:ff-failed fatal: "x" = y; #z \ end' &&
  assert_contains "$out" '  blocker:       fetch-failed:origin  two  spaces' &&
  out=$(gs status) &&
  assert_contains "$out" "blocked  < 1m ago       $WORK" &&
  assert_contains "$out" "blocked by: main:ff-failed, fetch-failed:origin" &&
  git config -f "$sf" status.lastRun garbage &&
  assert_contains "$(gs status)" "blocked  unknown        $WORK"
}
test_stale_runfile_removed() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  printf 'ok\t-\t/ghost\n' > "$GIT_SYNC_HOME/run.99999" &&
  gs sync --all >/dev/null &&
  assert_contains "$(cat "$GIT_SYNC_HOME/git-sync.log")" "run end: 1 ok, 0 blocked, 0 failed" &&
  assert_no_file "$GIT_SYNC_HOME/run.99999"
}
test_hints_commands() {
  out=$(hints) &&
  assert_eq "$(echo "$out" | cut -f1 | tr '\n' ' ')" "init install uninstall list status start stop config sync notifications help " &&
  assert_contains "$out" "$(printf 'sync\tSync the current (or given) repo, or all listed repos')" &&
  assert_not_contains "$out" "__sync-one"
}
test_hints_install() {
  assert_eq "$(hints install)" "$(printf -- '-r\tAdd every repo directly inside <dir>\n@dirs')" &&
  assert_eq "$(hints install -r)" "$(printf -- '--watch\tAlso install future clones in <dir>\n@dirs')" &&
  assert_eq "$(hints install some/dir)" "" &&
  assert_eq "$(hints install -r some/dir)" "$(printf -- '--watch\tAlso install future clones in <dir>')" &&
  assert_eq "$(hints install -r --watch)" "@dirs" &&
  assert_eq "$(hints install -r some/dir --watch)" ""
}
test_hints_uninstall_watch() {
  assert_eq "$(hints uninstall -r 2>&1)" "$(printf -- '--watch\tStop watching <dir>')" &&
  gs init >/dev/null && mkdir "$T/p: q" && gs install -r "$T/p: q" --watch >/dev/null &&
  assert_eq "$(hints uninstall -r)" "$(printf -- '--watch\tStop watching <dir>\n%s\twatched root' "$T/p: q")" &&
  assert_eq "$(hints uninstall -r --watch)" "$(printf '%s\twatched root' "$T/p: q")" &&
  assert_eq "$(hints uninstall -r "$T/p: q")" "$(printf -- '--watch\tStop watching <dir>')" &&
  assert_eq "$(hints uninstall -r --watch "$T/p: q")" ""
}
test_hints_repos() {
  assert_eq "$(hints uninstall 2>&1)" "" &&
  assert_eq "$(hints sync 2>&1 | cut -f1)" "--all" &&
  gs init >/dev/null && make_repos "sp ace" && gs install "$WORK" >/dev/null &&
  assert_eq "$(hints uninstall)" "$(printf '%s\tregistered repo' "$WORK")" &&
  out=$(hints sync) &&
  assert_contains "$out" "$(printf -- '--all\tSync every listed repo')" &&
  assert_contains "$out" "$(printf '%s\tregistered repo' "$WORK")" &&
  assert_eq "$(hints sync --all)" "" &&
  assert_eq "$(hints uninstall "$WORK")" ""
}
test_hints_status_flags() {
  assert_eq "$(hints status | cut -f1 | tr '\n' ' ')" "--verbose --list-order " &&
  assert_eq "$(hints status -v | cut -f1)" "--list-order" &&
  assert_eq "$(hints status --list-order | cut -f1)" "--verbose" &&
  assert_eq "$(hints status --verbose -l)" ""
}
test_hints_config() {
  out=$(hints config) &&
  assert_contains "$out" "$(printf -- '--global\t')" &&
  assert_contains "$out" "$(printf 'sync.mode\t')" &&
  assert_not_contains "$out" "sync.repo" &&
  assert_not_contains "$(hints config --global | cut -f1)" "--global" &&
  assert_eq "$(hints config --global sync.mode | cut -f1 | tr '\n' ' ')" "maintain-only maintain-and-fetch fast-forward " &&
  assert_eq "$(hints config notify.enabled | cut -f1 | tr '\n' ' ')" "true false " &&
  assert_eq "$(hints config sync.ffCheckedOut | cut -f1 | tr '\n' ' ')" "true false " &&
  assert_contains "$out" "$(printf 'sync.disableOfflineCheck\t')" &&
  assert_eq "$(hints config --global sync.disableOfflineCheck | cut -f1 | tr '\n' ' ')" "true false " &&
  assert_eq "$(hints config notify.events | cut -f1 | tr '\n' ' ')" "blocked finished " &&
  assert_eq "$(hints config sync.period)" "$(printf '@msg\tnumber with optional s/m/h, at least 60s (e.g. 20m)')" &&
  assert_contains "$out" "$(printf 'sync.fetchTimeout\t')" &&
  assert_eq "$(hints config --global sync.fetchTimeout)" "$(printf '@msg\tnumber with optional s/m/h, 30s to 1h (e.g. 5m)')" &&
  assert_eq "$(hints config --unset sync.mode)" "" &&
  assert_eq "$(hints config sync.mode fast-forward)" "" &&
  assert_eq "$(hints config bogus.key)" ""
}
test_hints_keys_match_cli() {
  want=$(sed -n 's/^ *\(sync\.period|.*\)) return 0 ;;$/\1/p' "$GS" | tr '|' '\n' | grep -vxF -e sync.repo -e sync.root -e sync.exclude | sort) &&
  got=$(hints config | cut -f1 | grep -v '^-' | sort) &&
  [ -n "$want" ] && assert_eq "$got" "$want"
}
test_hints_notifications() {
  assert_eq "$(hints notifications | cut -f1 | tr '\n' ' ')" "enable disable " &&
  assert_eq "$(hints notifications enable)" "" &&
  assert_eq "$(hints list)" "$(printf -- '--watch\tOnly the watched roots')" &&
  assert_eq "$(hints list --watch)" ""
}
test_hints_zsh_parity() {
  command -v zsh >/dev/null || { echo "    (skipped: no zsh)" >&2; return 0; }
  gs init >/dev/null && make_repos "sp ace" && gs install "$WORK" >/dev/null &&
  for args in "" "install" "install -r" "sync" "uninstall" "uninstall -r" "status -v" "config" "config --global sync.mode" "config sync.period" "config --global sync.disableOfflineCheck" "notifications"; do
    assert_eq "$(hints_in zsh $args)" "$(hints_in bash $args)" "args: $args" || return 1
  done
}
test_bash_completion_registers() {
  out=$(bash --norc --noprofile -c '. "$1" && complete -p git-sync' _ "$COMP" 2>&1) &&
  assert_contains "$out" "-o default" && assert_contains "$out" "-F __git_sync_bash"
}
test_bash_complete_words() {
  out=$(bash_complete git-sync st) &&
  assert_eq "$(echo "$out" | wc -l | tr -d ' ')" 3 &&
  assert_contains "$out" "status  -- Show agent state and per-repo sync status" &&
  assert_contains "$out" "start   -- Install and load the launchd agent" &&
  assert_eq "$(bash_complete git-sync sy)" "sync" &&
  assert_eq "$(bash_complete git-sync config sync.mode fa)" "fast-forward" &&
  assert_eq "$(bash_complete git-sync status -v --l)" "--list-order" &&
  assert_eq "$(bash_complete git-sync zz)" ""
}
test_bash_complete_install_dirs() {
  assert_eq "$(bash_complete git-sync install "")" "" &&
  assert_eq "$(bash_complete git-sync install -)" "-r" &&
  assert_eq "$(bash_complete git-sync install -r "")" ""
}
test_bash_complete_paths() {
  gs init >/dev/null && make_repos "a:b c" && gs install "$WORK" >/dev/null &&
  assert_eq "$(bash_complete git-sync uninstall "$T/a")" "$T/a:b\\ c" &&
  assert_eq "$(bash_complete git-sync uninstall "$T/a:b\\ ")" "b\\ c" &&
  out=$(bash_complete git-sync sync "") &&
  assert_contains "$out" "--all" && assert_contains "$out" "$T/a:b\\ c" && assert_contains "$out" "-- registered repo"
}
test_bash_complete_prefix_words() {
  gs init >/dev/null && make_repos && git clone -q "$T/remote.git" "$T/app" &&
  git clone -q "$T/remote.git" "$T/app2" &&
  gs install "$T/app" >/dev/null && gs install "$T/app2" >/dev/null &&
  out=$(bash_complete git-sync uninstall "$T/ap") &&
  assert_eq "$(echo "$out" | wc -l | tr -d ' ')" 2 &&
  assert_contains "$out" "$T/app   -- registered repo" &&
  assert_contains "$out" "$T/app2  -- registered repo"
}
test_zsh_completion_registers() {
  command -v zsh >/dev/null || { echo "    (skipped: no zsh)" >&2; return 0; }
  out=$(zsh -f -c 'autoload -Uz compinit && compinit -u -D && . "$1" && print -r -- "$_comps[git-sync]"' _ "$COMP" 2>"$T/err") &&
  assert_eq "$out" "_git_sync_zsh" && assert_eq "$(cat "$T/err")" "" &&
  { zsh -f -c '. "$1"' _ "$COMP" 2>"$T/err"; true; } &&
  assert_eq "$(cat "$T/err")" "git-sync: completion needs compinit; source it after compinit"
}
test_zsh_complete_frontend() {
  command -v zsh >/dev/null || { echo "    (skipped: no zsh)" >&2; return 0; }
  gs init >/dev/null && make_repos "a:b c" && gs install "$WORK" >/dev/null &&
  assert_contains "$(zsh_complete git-sync st)" "describe status:Show agent state and per-repo sync status" &&
  assert_eq "$(zsh_complete git-sync uninstall "")" "describe $T/a\\:b c:registered repo" &&
  out=$(zsh_complete git-sync install "") &&
  assert_contains "$out" "describe -r:Add every repo directly inside <dir>" &&
  assert_contains "$out" "files -/" &&
  assert_eq "$(zsh_complete git-sync install -r "")" "$(printf '%s\n%s' "describe --watch:Also install future clones in <dir>" "files -/")" &&
  assert_eq "$(zsh_complete git-sync config sync.period "")" "message number with optional s/m/h, at least 60s (e.g. 20m)" &&
  assert_contains "$(zsh_complete git-sync config "")" "sync.fetchTimeout:" &&
  assert_eq "$(zsh_complete git-sync config sync.fetchTimeout "")" "message number with optional s/m/h, 30s to 1h (e.g. 5m)" &&
  assert_eq "$(zsh_complete git-sync list "")" "describe --watch:Only the watched roots"
}
test_zsh_tab_inserts() {
  command -v zsh >/dev/null && command -v expect >/dev/null || { echo "    (skipped: no zsh or expect)" >&2; return 0; }
  gs init >/dev/null && make_repos "a:b c" && gs install "$WORK" >/dev/null &&
  assert_eq "$(tab_complete zsh "git-sync unin")" "uninstall" &&
  assert_eq "$(tab_complete zsh "git-sync config sync.mode fa" | tr '\n' ' ')" "config sync.mode fast-forward " &&
  assert_eq "$(tab_complete zsh "git-sync uninstall $T/a" | tail -1)" "$T/a:b c"
}
test_bash_tab_inserts() {
  command -v expect >/dev/null || { echo "    (skipped: no expect)" >&2; return 0; }
  gs init >/dev/null && make_repos "a:b c" && gs install "$WORK" >/dev/null &&
  assert_eq "$(tab_complete bash "git-sync unin")" "uninstall" &&
  assert_eq "$(tab_complete bash "git-sync uninstall $T/a" | tail -1)" "$T/a:b c" &&
  assert_eq "$(tab_complete bash "git-sync uninstall $T/a:" | tail -1)" "$T/a:b c"
}
test_bash_no_git_subcommand_clash() {
  ! bash --norc --noprofile -c '. "$1" && declare -F _git_sync' _ "$COMP" >/dev/null
}
test_install_sh_completion() {
  f="$T/share/git-sync/git-sync-completion.sh" &&
  out=$(PREFIX="$T/bin2" XDG_DATA_HOME="$T/share" sh "$ROOT/install.sh") &&
  [ -x "$T/bin2/git-sync" ] && cmp -s "$f" "$COMP" &&
  assert_contains "$out" "Installed $f" &&
  assert_contains "$out" "[ -f \"$f\" ] && . \"$f\"" &&
  assert_contains "$out" "Next: run 'git-sync init'." &&
  PREFIX="$T/bin2" XDG_DATA_HOME="$T/share" sh "$ROOT/install.sh" >/dev/null &&
  assert_eq "$(ls "$T/share/git-sync")" "git-sync-completion.sh" &&
  out=$(PREFIX="$T/bin3" sh "$ROOT/install.sh") &&
  cmp -s "$HOME/.local/share/git-sync/git-sync-completion.sh" "$COMP"
}

# --- runner ---
if [ $# -gt 0 ]; then TESTS="$*"; else
  TESTS=$(grep -E '^test_[a-z0-9_]+\(\)' "$0" | sed 's/().*//')
fi
for t in $TESTS; do
  if ( sandbox; "$t" ); then PASSES=$((PASSES+1)); echo "PASS $t"
  else FAILS=$((FAILS+1)); echo "FAIL $t"; fi
done
echo "passed: $PASSES failed: $FAILS"
[ "$FAILS" -eq 0 ]
