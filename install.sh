#!/bin/sh
# Installs git-sync into ${PREFIX:-$HOME/.local/bin}.
# --hints also installs shell completion (bash, zsh) into
# ${XDG_DATA_HOME:-$HOME/.local/share}/git-sync.
set -u
HINTS=0
for arg in "$@"; do
  case $arg in
    --hints) HINTS=1 ;;
    *) echo "install.sh: unknown argument: $arg" >&2
       echo "Usage: sh install.sh [--hints]" >&2
       exit 2 ;;
  esac
done
SRC_DIR=$(cd -P "$(dirname "$0")" && pwd)
DEST_DIR=${PREFIX:-$HOME/.local/bin}
# put SRC DEST MODE: copies atomically (temp file, then rename).
put() {
  cp "$1" "$2.tmp.$$" && chmod "$3" "$2.tmp.$$" && mv "$2.tmp.$$" "$2" || exit 1
}
mkdir -p "$DEST_DIR" || exit 1
put "$SRC_DIR/git-sync" "$DEST_DIR/git-sync" 755
echo "Installed $DEST_DIR/git-sync"
if [ "$HINTS" -eq 1 ]; then
  HINTS_FILE=${XDG_DATA_HOME:-$HOME/.local/share}/git-sync/git-sync-completion.sh
  mkdir -p "$(dirname "$HINTS_FILE")" || exit 1
  put "$SRC_DIR/git-sync-completion.sh" "$HINTS_FILE" 644
  echo "Installed $HINTS_FILE"
  echo "Enable hints: add this line to ~/.bashrc, or to ~/.zshrc after compinit:"
  echo "  [ -f \"$HINTS_FILE\" ] && . \"$HINTS_FILE\""
fi
echo "Next: run 'git-sync init'."
