#!/usr/bin/env bash
#
# clean - delete local branches whose upstream remote branch is gone.
#
# Use case: after a PR is merged and its remote feature branch is deleted,
# the local copy lingers. This prunes remote-tracking refs, finds local
# branches whose upstream is gone, lists them, and (on confirmation)
# force-deletes them.
#
# Usage:
#   clean
#
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "clean: not inside a git repository" >&2
  exit 1
fi

echo "Fetching and pruning remote-tracking branches..."
git fetch --prune >/dev/null 2>&1

current="$(git branch --show-current)"

# Collect local branches whose upstream is marked [gone].
gone=()
while IFS= read -r branch; do
  [[ -z "$branch" ]] && continue
  if [[ "$branch" == "$current" ]]; then
    echo "Skipping current branch (cannot delete checked-out branch): $branch" >&2
    continue
  fi
  gone+=("$branch")
done < <(
  git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads \
    | awk '$2 == "[gone]" { print $1 }'
)

if [[ ${#gone[@]} -eq 0 ]]; then
  echo "No dead local branches found. Nothing to clean."
  exit 0
fi

echo
echo "The following local branches have a deleted upstream:"
for b in "${gone[@]}"; do
  echo "  - $b"
done
echo

read -r -p "Force-delete these ${#gone[@]} branch(es)? [y/N] " reply
case "$reply" in
  [yY] | [yY][eE][sS])
    git branch -D "${gone[@]}"
    echo "Done."
    ;;
  *)
    echo "Aborted. No branches deleted."
    ;;
esac
