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
