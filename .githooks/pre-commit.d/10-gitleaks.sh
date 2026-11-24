#!/bin/sh
# Block commits that add secrets. Runs as a Hook extension of the pre-commit hook that `/iivanou-git-standards:setup` generates.
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "pre-commit: gitleaks not found. Install: brew install gitleaks" >&2
  exit 1
fi
exec gitleaks git --pre-commit --staged --redact --verbose
