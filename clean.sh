#!/usr/bin/env bash
#
# clean - delete dead local branches.
#
# Use case: after a PR is merged and its remote feature branch is deleted,
# the local copy lingers. This switches to the default branch, pulls, prunes
# remote-tracking refs, then collects dead local branches -- those whose
# upstream is gone, plus those that never had an upstream (never pushed) --
# lists them, and (on confirmation) force-deletes them. Switching to the
# default branch first means the branch you were on can be deleted too.
#
# Usage:
#   clean
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "clean: not inside a git repository" >&2
  exit 1
fi

# Determine the default branch (origin/HEAD), falling back to main/master.
default=""
if ref="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; then
  default="${ref#refs/remotes/origin/}"
fi
if [[ -z "$default" ]]; then
  for candidate in main master; do
    if git show-ref --verify --quiet "refs/heads/$candidate"; then
      default="$candidate"
      break
    fi
  done
fi
if [[ -z "$default" ]]; then
  echo "clean: could not determine the default branch (no origin/HEAD, main, or master)" >&2
  exit 1
fi

if [[ "$(git branch --show-current)" != "$default" ]]; then
  echo "Switching to default branch: $default"
  if ! git checkout "$default"; then
    echo "clean: could not switch to $default (uncommitted changes?)" >&2
    exit 1
  fi
fi

echo "Fetching and pruning remote-tracking branches..."
git fetch --prune >/dev/null 2>&1

current="$(git branch --show-current)"

# Collect dead local branches: upstream gone ([gone]) OR no upstream at all
# (never pushed). The default branch is excluded because it is the current
# branch at this point and gets skipped below.
gone=()
while IFS= read -r branch; do
  [[ -z "$branch" ]] && continue
  if [[ "$branch" == "$current" ]]; then
    echo "Skipping current branch (cannot delete checked-out branch): $branch" >&2
    continue
  fi
  gone+=("$branch")
done < <(
  git for-each-ref --format='%(refname:short)|%(upstream)|%(upstream:track)' refs/heads \
    | awk -F'|' '$2 == "" || $3 == "[gone]" { print $1 }'
)

if [[ ${#gone[@]} -eq 0 ]]; then
  echo "No dead local branches found. Nothing to clean."
  exit 0
fi

echo
echo "The following local branches are dead (upstream gone or never pushed):"
for b in "${gone[@]}"; do
  echo "  - $b"
done
echo

read -r -p "Force-delete these ${#gone[@]} branch(es)? [y/N] " reply
case "$reply" in
  [yY] | [yY][eE][sS])
    if git branch -D "${gone[@]}"; then
      echo "Done."
      echo
      "$SCRIPT_DIR/gpom.sh" \
        || echo "clean: branches deleted, but updating $default failed" >&2
    else
      echo "clean: branch deletion failed" >&2
      exit 1
    fi
    ;;
  *)
    echo "Aborted. No branches deleted."
    ;;
esac
