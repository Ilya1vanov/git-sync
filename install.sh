#!/bin/sh
# Installs git-sync into ${PREFIX:-$HOME/.local/bin}.
set -u
SRC=$(cd -P "$(dirname "$0")" && pwd)/git-sync
DEST_DIR=${PREFIX:-$HOME/.local/bin}
mkdir -p "$DEST_DIR" || exit 1
cp "$SRC" "$DEST_DIR/git-sync.tmp.$$" && chmod 755 "$DEST_DIR/git-sync.tmp.$$" \
  && mv "$DEST_DIR/git-sync.tmp.$$" "$DEST_DIR/git-sync" || exit 1
echo "Installed $DEST_DIR/git-sync"
echo "Next: run 'git-sync init'."
