#!/usr/bin/env bash
#
# new - create a new git branch named schan/<name>, based on the latest
# default branch.
#
# Usage:
#   new            Generate a science-themed branch: schan/<adjective>-<noun>
#   new <name>     Create branch schan/<name> verbatim
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="schan"

adjectives=(
  atomic quantum cosmic thermal kinetic ionic magnetic optical nuclear
  organic seismic stellar lunar solar tidal viral genetic neural
  fractal entropic relativistic radiant electric covalent crystalline
  gaseous molecular volcanic primordial galactic photonic plasmic
)

nouns=(
  electron neutron proton photon quark neutrino isotope molecule
  enzyme cell nucleus genome protein catalyst comet nebula pulsar
  quasar galaxy meteor asteroid mitochondria chromosome vector entropy
  alloy crystal magma fossil organism plasma helix synapse spectrum
)

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "new: not inside a git repository" >&2
  exit 1
fi

if [[ $# -gt 0 ]]; then
  name="$1"
else
  adj="${adjectives[RANDOM % ${#adjectives[@]}]}"
  noun="${nouns[RANDOM % ${#nouns[@]}]}"
  name="${adj}-${noun}"
fi

branch="${PREFIX}/${name}"

# Base the new branch on the latest default branch.
"$SCRIPT_DIR/gpom.sh" --checkout \
  || echo "new: could not update the default branch; branching from current HEAD" >&2

git checkout -b "$branch"
echo "Created and switched to branch: $branch"
