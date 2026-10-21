#!/bin/sh
# Sets up (or updates) git-sync in ${PREFIX:-$HOME/.local/bin} and its shell
# completion (bash, zsh) in ${XDG_DATA_HOME:-$HOME/.local/share}/git-sync.
#
# Dev mode, when run as a file named install.sh with git-sync beside it
# (`sh install.sh` in a clone): sets up those files, stamped with the clone's
# HEAD and its date (plus -dirty with uncommitted changes).
# One-liner mode, otherwise (`curl ... | sh`, `sh < install.sh`): downloads the
# GitHub archive of ${GIT_SYNC_REF:-main}, stamped by export-subst;
# GIT_SYNC_ARCHIVE_URL replaces the archive URL (for tests).
#
# Everything is downloaded and staged before any file is replaced. A loaded
# agent is restarted onto the new copy; an unloaded one is not started.
# The whole script is one function, so a truncated download runs nothing.
set -u

main() {
  local mode src bin hints commit date new old loaded=0 old_agent= self
  bin=${PREFIX:-$HOME/.local/bin}/git-sync
  hints=${XDG_DATA_HOME:-$HOME/.local/share}/git-sync/git-sync-completion.sh
  TMP=
  STAGED_BIN=$bin.tmp.$$ STAGED_HINTS=$hints.tmp.$$
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM

  case "$0" in
    install.sh|*/install.sh)
      if [ -r "$0" ] && [ -f "$(dirname "$0")/git-sync" ]; then mode=dev; else mode=oneliner; fi ;;
    *) mode=oneliner ;;
  esac
  if [ "$mode" = dev ]; then
    src=$(cd -P "$(dirname "$0")" && pwd) || die "cannot resolve $(dirname "$0")"
  else
    download "${GIT_SYNC_ARCHIVE_URL:-https://github.com/Ilya1vanov/git-sync/archive/refs/heads/${GIT_SYNC_REF:-main}.tar.gz}"
    src=$TMP/src
  fi
  [ -f "$src/git-sync" ] && [ -f "$src/git-sync-completion.sh" ] ||
    die "git-sync or git-sync-completion.sh missing in $src"

  mkdir -p "$(dirname "$bin")" "$(dirname "$hints")" || die "cannot create the setup directories"
  if [ "$mode" = dev ] && commit=$(git -C "$src" rev-parse HEAD 2>/dev/null); then
    date=$(git -C "$src" log -1 --format=%cs HEAD) || die "cannot read the date of HEAD in $src"
    [ -z "$(git -C "$src" status --porcelain 2>/dev/null)" ] || commit="$commit-dirty"
    sed -e "s/^GS_COMMIT=.*/GS_COMMIT='$commit'/" -e "s/^GS_DATE=.*/GS_DATE='$date'/" \
      "$src/git-sync" > "$bin.tmp.$$" || die "cannot write $bin"
  else
    cp "$src/git-sync" "$bin.tmp.$$" || die "cannot write $bin"
  fi
  chmod 755 "$bin.tmp.$$" || die "cannot write $bin"
  cp "$src/git-sync-completion.sh" "$hints.tmp.$$" && chmod 644 "$hints.tmp.$$" || die "cannot write $hints"
  new=$("$bin.tmp.$$" --version) || die "cannot run the downloaded git-sync"
  new=${new#git-sync }

  # The previous setup: its version, and whether the agent runs (and from where).
  if [ -f "$bin" ]; then
    old=$("$bin" --version 2>/dev/null) || old=
    case "$old" in "git-sync "*) old=${old#git-sync } ;; *) old=unknown ;; esac
  else
    old=
  fi
  if "${GIT_SYNC_LAUNCHCTL:-launchctl}" print "gui/$(id -u)/com.git-sync.agent" >/dev/null 2>&1; then
    loaded=1
    old_agent=$(plutil -extract ProgramArguments.0 raw \
      "${GIT_SYNC_AGENTS_DIR:-$HOME/Library/LaunchAgents}/com.git-sync.agent.plist" 2>/dev/null) || old_agent=
  fi

  mv -f "$bin.tmp.$$" "$bin" && mv -f "$hints.tmp.$$" "$hints" || die "cannot replace $bin or $hints"
  if [ -z "$old" ]; then
    echo "Set up git-sync $new in $bin and $hints"
  elif [ "$old" = "$new" ]; then
    echo "git-sync ${new%% *} is up to date (reinstalled)"
  elif [ "$mode" = oneliner ] && [ -z "${GIT_SYNC_REF:-}" ]; then
    echo "git-sync updated $old → $new"
  else
    echo "git-sync changed $old → $new"
  fi

  if [ "$loaded" = 1 ]; then
    self=$(cd -P "$(dirname "$bin")" && pwd)/git-sync
    echo "Reloading the agent onto $self"
    "$bin" start || die "cannot reload the agent; run 'git-sync start'"
    if [ -n "$old_agent" ] && [ "$old_agent" != "$self" ] && [ -e "$old_agent" ]; then
      echo "Note: the agent ran $old_agent before; that copy still exists. Delete it if you no longer need it."
    fi
  fi
  case ":${PATH-}:" in
    *":$(dirname "$bin"):"*) ;;
    *)
      echo "$(dirname "$bin") is not in your PATH. Add this line to ~/.zprofile, then open a new terminal:"
      echo "  export PATH=\"$(dirname "$bin"):\$PATH\"" ;;
  esac
  echo "Optional completion: add this line to ~/.bashrc, or to ~/.zshrc after compinit:"
  echo "  [ -f \"$hints\" ] && . \"$hints\""
  echo "Next: run 'git-sync install' inside a repo, then 'git-sync start'."
}

die() { echo "install.sh: $*" >&2; exit 1; }

# Removes staged files that were not moved into place, and the download dir.
cleanup() {
  rm -f "$STAGED_BIN" "$STAGED_HINTS"
  [ -z "$TMP" ] || rm -rf "$TMP"
}

# download URL: fetches and extracts the archive into $TMP/src. Fails before
# anything is changed.
download() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/git-sync-setup.XXXXXX") || die "cannot create a temp dir"
  echo "Downloading $1"
  curl -fsSL "$1" -o "$TMP/archive.tar.gz" || die "download failed: $1 (nothing changed)"
  mkdir "$TMP/src" && tar -xzf "$TMP/archive.tar.gz" -C "$TMP/src" --strip-components 1 ||
    die "cannot extract $1 (nothing changed)"
}

main "$@"
