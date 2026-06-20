#!/usr/bin/env bash
# EDGE: multi-input derivation (non-empty inputDrvs).
# Exercises build-remote.cc:336 — `if (!drv.inputDrvs.map.empty()) drv.inputSrcs = inputPaths;`
# i.e. the inputSrcs hijack only happens when the drv depends on other drvs.
# This verifies inputs of dependency outputs get shipped correctly.
#
# Reachable: local?root= (1 laptop).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../flows/_common.sh"

SUBST="${SUBST:-false}"
WORK="$(mktemp -d)"
SRC="local?root=$WORK/store-a"
DST="local?root=$WORK/store-b"
trap 'rm -rf "$WORK"' EXIT
SYS="$("$NIX" eval --impure --raw --expr 'builtins.currentSystem')"

echo "== multi-input-drv (substitutes=$SUBST) =="

# top depends on dep → top.drvPath has non-empty inputDrvs.
DRV="$("$NIX" --extra-experimental-features 'nix-command flakes' --store "$SRC" \
  eval --impure --raw --expr '
   let
     dep = derivation {
       name = "amrit-dep"; system = builtins.currentSystem;
       builder = "/bin/sh"; args = ["-c" "echo dep > $out"];
     };
     top = derivation {
       name = "amrit-top"; system = builtins.currentSystem;
       builder = "/bin/sh"; args = ["-c" "cat ${dep} > $out; echo top >> $out"];
     };
   in builtins.unsafeDiscardStringContext top.drvPath')"
echo "top-drv=$DRV"

"$NIX" --extra-experimental-features 'nix-command flakes' \
  --store "$SRC" --max-jobs 0 \
  --builders "$DST $SYS - 1 1" \
  --option builders-use-substitutes "$SUBST" \
  build "$DRV^*" --no-link --print-out-paths

echo "== done (expected: inputSrcs hijack shipped dep output to builder) =="
record_store "$DST" "${RECORD_PREFIX:-/dev/stdout}.dst"
