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
