#!/usr/bin/env bash
#
# clean - delete dead local branches.
#
# Use case: after a PR is merged and its remote feature branch is deleted,
# the local copy lingers. This switches to the default branch, pulls, prunes
# remote-tracking refs, then collects dead local branches -- those whose
# upstream is gone, plus those that never had an upstream (never pushed) --
# lists them, and force-deletes the ones you select. Switching to the
# default branch first means the branch you were on can be deleted too.
#
# Selection is interactive: dead branches are shown with numbers, and you
# pick which to delete (specific numbers, 'a'/'all' for everything, or
# 'q'/empty to abort).
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
# Keep stderr visible: an SSH host-key/passphrase prompt or network stall here
# would otherwise look like a silent hang. A connect timeout turns an
# unreachable remote into a fast failure instead of an indefinite wait.
#
# Treat a non-zero fetch as a warning, not a fatal error. On a case-insensitive
# filesystem, a single pair of upstream branches differing only in case (e.g.
# gaspardBT/x vs gaspardbt/x) makes git fail with "cannot lock ref" even though
# it has already pruned and updated every other ref. Dead-branch detection below
# reads local tracking state, so cleanup can still proceed.
if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=10}" \
  git fetch --prune >/dev/null; then
  echo "clean: fetch reported errors (continuing with cleanup anyway)" >&2
fi

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
for i in "${!gone[@]}"; do
  printf "  %2d) %s\n" "$((i + 1))" "${gone[$i]}"
done
echo

echo "Select branches to delete:"
echo "  - numbers separated by spaces or commas (e.g. 1 3 4)"
echo "  - 'a' or 'all' to delete all"
echo "  - empty or 'q' to abort"
read -r -p "> " reply

# Normalize: lowercase, replace commas with spaces.
reply="$(printf '%s' "$reply" | tr '[:upper:],' '[:lower:] ')"

selected=()
case "$reply" in
  "" | q | quit)
    echo "Aborted. No branches deleted."
    exit 0
    ;;
  a | all)
    selected=("${gone[@]}")
    ;;
  *)
    for token in $reply; do
      if ! [[ "$token" =~ ^[0-9]+$ ]]; then
        echo "clean: invalid selection '$token' (expected a number, 'a', or 'q')" >&2
        exit 1
      fi
      if (( token < 1 || token > ${#gone[@]} )); then
        echo "clean: selection '$token' out of range (1-${#gone[@]})" >&2
        exit 1
      fi
      selected+=("${gone[$((token - 1))]}")
    done
    ;;
esac

# Deduplicate while preserving order (a branch listed twice shouldn't error).
# Guard array expansions: bash 3.2 (macOS) errors on ${arr[@]} for an empty
# array under `set -u`.
unique=()
for b in "${selected[@]}"; do
  seen=""
  if [[ ${#unique[@]} -gt 0 ]]; then
    for u in "${unique[@]}"; do
      [[ "$u" == "$b" ]] && { seen=1; break; }
    done
  fi
  [[ -z "$seen" ]] && unique+=("$b")
done
selected=("${unique[@]}")

if [[ ${#selected[@]} -eq 0 ]]; then
  echo "Aborted. No branches deleted."
  exit 0
fi

echo
echo "Deleting ${#selected[@]} branch(es):"
for b in "${selected[@]}"; do
  echo "  - $b"
done

if git branch -D "${selected[@]}"; then
  echo "Done."
  echo
  "$SCRIPT_DIR/gpom.sh" \
    || echo "clean: branches deleted, but updating $default failed" >&2
else
  echo "clean: branch deletion failed" >&2
  exit 1
fi
