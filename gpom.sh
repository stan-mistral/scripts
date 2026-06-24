#!/usr/bin/env bash
#
# gpom - git pull origin main (or master).
#
# Pulls the remote default branch from origin into the current branch.
# Detects the default branch from origin/HEAD, falling back to main/master.
#
# Usage:
#   gpom
#
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "gpom: not inside a git repository" >&2
  exit 1
fi

default=""
if ref="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; then
  default="${ref#refs/remotes/origin/}"
fi
if [[ -z "$default" ]]; then
  for candidate in main master; do
    if git ls-remote --exit-code --heads origin "$candidate" >/dev/null 2>&1; then
      default="$candidate"
      break
    fi
  done
fi
if [[ -z "$default" ]]; then
  echo "gpom: could not determine the default branch on origin (no origin/HEAD, main, or master)" >&2
  exit 1
fi

echo "Pulling origin/$default into $(git branch --show-current)..."
git pull origin "$default"
