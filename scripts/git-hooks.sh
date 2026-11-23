#!/bin/sh
# Usage: sh scripts/git-hooks.sh install|uninstall
# Points git at the repo's committed hooks in .githooks/.
set -e
HOOKS=.githooks
current=$(git config --local --get core.hooksPath || true)

case "$1" in
  install)
    effective=$(git config --get core.hooksPath || true)
    if [ -n "$effective" ] && [ "$effective" != "$HOOKS" ]; then
      echo "core.hooksPath is already set to '$effective'; not overwriting." >&2
      exit 1
    fi
    git config --local core.hooksPath "$HOOKS"
    echo "Hooks installed (core.hooksPath=$HOOKS)."
    command -v gitleaks >/dev/null 2>&1 ||
      echo "Warning: gitleaks not found; commits will be blocked. Install: brew install gitleaks" >&2
    ;;
  uninstall)
    if [ "$current" = "$HOOKS" ]; then
      git config --local --unset core.hooksPath
      echo "Hooks uninstalled."
    elif [ -n "$current" ]; then
      echo "core.hooksPath is '$current', not '$HOOKS'; leaving it." >&2
    else
      echo "Hooks not installed."
    fi
    ;;
  *)
    echo "Usage: $0 install|uninstall" >&2
    exit 2
    ;;
esac
