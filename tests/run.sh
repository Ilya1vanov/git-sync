#!/bin/sh
# Test runner for git-sync. Usage: tests/run.sh [test_name ...]
set -u
ROOT=$(cd -P "$(dirname "$0")/.." && pwd)
GS="$ROOT/git-sync"
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
  chmod +x "$T/bin/launchctl" "$T/bin/notify"
  export STUB_DIR="$T" GIT_SYNC_LAUNCHCTL="$T/bin/launchctl" GIT_SYNC_NOTIFY_CMD="$T/bin/notify"
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

gs() { "$GS" "$@"; }
# quiet CMD...: run, discard output, always succeed (for steps whose exit code is not under test).
quiet() { "$@" >/dev/null 2>&1; return 0; }

# --- tests ---
test_help() {
  out=$(gs help) && assert_contains "$out" "Usage: git-sync" && assert_contains "$out" "notifications"
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
  gs config --global notify.events "start finished blocked" &&
  gs config --global log.maxSize 512K && gs config --global sync.period 90 &&
  assert_eq "$(gs config sync.period)" 90
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
  sleep 30 & pid=$! ; mkdir "$GIT_SYNC_HOME/lock" && echo $pid > "$GIT_SYNC_HOME/lock/pid" &&
  out=$(gs sync --all) ; rc=$? ; kill $pid ;
  assert_eq $rc 0 && assert_contains "$out" "another run in progress" && assert_no_file "$(sf_of "$WORK")"
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
test_ssh_batchmode_env() {
  gs init >/dev/null && make_repos && gs install "$WORK" >/dev/null &&
  cat > "$T/bin/fakessh" <<'EOF'
#!/bin/sh
echo "GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-}" >> "$STUB_DIR/ssh.env"; exit 1
EOF
  chmod +x "$T/bin/fakessh" &&
  git -C "$WORK" remote add sshr "ssh://example.invalid/x.git" &&
  ( PATH="$T/bin:$PATH" GIT_SSH="$T/bin/fakessh"; export GIT_SSH; cd "$WORK" && gs sync >/dev/null 2>&1 );
  assert_eq "$(sget "$WORK" result)" blocked &&
  assert_contains "$(git config -f "$(sf_of "$WORK")" --get-all status.blocker)" "fetch-failed:sshr"
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
  out=$(gs status) && assert_contains "$out" "Agent:         not loaded" &&
  assert_contains "$out" "Period:        20m" && assert_contains "$out" "Notifications: disabled" &&
  assert_contains "$out" "  result:        never" &&
  push_commit main && git -C "$WORK" remote add dead "$T/nope.git" && (cd "$WORK" && gs sync >/dev/null);
  gs start >/dev/null && out=$(gs status) && assert_contains "$out" "Agent:         loaded" &&
  assert_contains "$out" "$WORK" && assert_contains "$out" "  mode:          fast-forward" &&
  assert_contains "$out" "  result:        blocked" && assert_contains "$out" "  blocker:       fetch-failed:dead" &&
  assert_contains "$out" "  note:          main: skipped (checked out)" && assert_contains "$out" "  last run:"
}
test_status_no_repos() {
  gs init >/dev/null && out=$(gs status) && assert_contains "$out" "No repos."
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
