#!/usr/bin/env bash
# Flow: ssh:// offload  →  LegacySSHBuilder.
# Covers: Transport=ssh://, both trust branches (depends on remote trust), Substitute=toggle.
# REQUIRES: 2nd machine reachable over SSH with nix installed; key-based SSH.
#
# Env:
#   REMOTE   e.g. user@laptop-b           (required)
#   SYSTEM   e.g. x86_64-linux            (default: currentSystem)
#   SUBST    builders-use-substitutes     (default false)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/_common.sh"

: "${REMOTE:?set REMOTE=user@host (the builder laptop)}"
SUBST="${SUBST:-false}"
SYSTEM="${SYSTEM:-$("$NIX" eval --impure --raw --expr 'builtins.currentSystem')}"
WORK="$(mktemp -d)"
SRC="local?root=$WORK/store-a"
trap 'rm -rf "$WORK"' EXIT

echo "== ssh-offload (remote=$REMOTE, system=$SYSTEM, substitutes=$SUBST) =="
DRV="$(trivial_drv "$SRC")"
echo "drv=$DRV"

# ssh:// (legacy) builder URI.
"$NIX" --extra-experimental-features 'nix-command flakes' \
  --store "$SRC" \
  --max-jobs 0 \
  --builders "ssh://$REMOTE $SYSTEM - 1 1" \
  --option builders-use-substitutes "$SUBST" \
  build "$DRV^*" --no-link --print-out-paths

echo "== done =="
record_store "$SRC" "${RECORD_PREFIX:-/dev/stdout}.src"
