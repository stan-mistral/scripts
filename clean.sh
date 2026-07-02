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
# Selection is interactive: in a terminal you get a checkbox TUI (arrow keys
# or j/k to move, space to toggle, 'a' to toggle all, enter to confirm, q or
# esc to abort). When stdin/stdout is not a terminal it falls back to a
# numbered prompt (numbers, 'a'/'all', or 'q'/empty to abort).
#
# Usage:
#   clean
#
set -euo pipefail

# Always restore cursor visibility, even if the TUI is interrupted (Ctrl-C).
trap 'printf "\e[?25h" 2>/dev/null || true' EXIT

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

# --- Interactive selection -------------------------------------------------
# Pure-bash checkbox TUI (no external dependencies). Renders the given items
# with [x]/[ ] checkboxes and stores the chosen ones in the global `selected`
# array. Returns 0 on confirm, 1 on abort.
select_branches_tui() {
  local items=("$@")
  local n=${#items[@]}
  local checked=()
  local i
  for ((i = 0; i < n; i++)); do checked[i]=0; done
  local cursor=0 key rest first=1

  printf '\e[?25l'  # hide cursor while drawing
  while true; do
    if [[ $first -eq 1 ]]; then
      first=0
    else
      printf '\e[%dA' "$n"  # move back up to the first item line
    fi
    for ((i = 0; i < n; i++)); do
      local pointer="  " mark=" "
      [[ $i -eq $cursor ]] && pointer="> "
      [[ ${checked[i]} -eq 1 ]] && mark="x"
      printf '\e[2K%s[%s] %s\n' "$pointer" "$mark" "${items[i]}"
    done

    if ! IFS= read -rsn1 key; then
      printf '\e[?25h'; return 1  # EOF -> abort
    fi
    case "$key" in
      '')  # enter -> confirm
        break ;;
      $'\e')  # escape sequence (arrow keys) or a bare esc
        read -rsn2 -t 1 rest || rest=""
        case "$rest" in
          '[A') if ((cursor > 0)); then ((cursor--)) || true; fi ;;
          '[B') if ((cursor < n - 1)); then ((cursor++)) || true; fi ;;
          '')   printf '\e[?25h'; return 1 ;;  # bare esc -> abort
        esac ;;
      k|K) if ((cursor > 0)); then ((cursor--)) || true; fi ;;
      j|J) if ((cursor < n - 1)); then ((cursor++)) || true; fi ;;
      ' ') checked[cursor]=$((1 - checked[cursor])) ;;
      a|A)  # toggle all: clear if everything is checked, else check everything
        local allon=1
        for ((i = 0; i < n; i++)); do
          [[ ${checked[i]} -eq 0 ]] && { allon=0; break; }
        done
        for ((i = 0; i < n; i++)); do
          checked[i]=$((allon == 1 ? 0 : 1))
        done ;;
      q|Q) printf '\e[?25h'; return 1 ;;
    esac
  done

  printf '\e[?25h'  # restore cursor
  selected=()
  for ((i = 0; i < n; i++)); do
    [[ ${checked[i]} -eq 1 ]] && selected+=("${items[i]}")
  done
  return 0
}

selected=()
if [[ -t 0 && -t 1 ]]; then
  echo
  echo "Dead local branches (upstream gone or never pushed):"
  echo "  up/down or j/k = move, space = toggle, a = toggle all, enter = confirm, q = abort"
  echo
  if ! select_branches_tui "${gone[@]}"; then
    echo "Aborted. No branches deleted."
    exit 0
  fi
else
  # Non-interactive fallback: numbered prompt.
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
  read -r reply || reply=""

  # Normalize: lowercase, replace commas with spaces.
  reply="$(printf '%s' "$reply" | tr '[:upper:],' '[:lower:] ')"
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
fi

# Deduplicate while preserving order (numbered input may repeat a branch).
# Guard array expansions: bash 3.2 (macOS) errors on ${arr[@]} for an empty
# array under `set -u`.
unique=()
if [[ ${#selected[@]} -gt 0 ]]; then
  for b in "${selected[@]}"; do
    seen=""
    if [[ ${#unique[@]} -gt 0 ]]; then
      for u in "${unique[@]}"; do
        [[ "$u" == "$b" ]] && { seen=1; break; }
      done
    fi
    [[ -z "$seen" ]] && unique+=("$b")
  done
fi
selected=()
[[ ${#unique[@]} -gt 0 ]] && selected=("${unique[@]}")

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
