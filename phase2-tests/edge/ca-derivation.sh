#!/usr/bin/env bash
# EDGE: CA derivation offload.
# Forces the buildDerivation(…, inputs) overload EVEN when the client is untrusted,
# because build-remote.cc:326 condition is `trustedOrLegacy || drv.type().isCA()`.
# So a CA drv → buildDerivation overload regardless of trust.
#
# Requires: ca-derivations experimental feature.
# Reachable: local?root= (1 laptop) for the dispatch; real untrusted CA needs ssh-ng.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../flows/_common.sh"

SUBST="${SUBST:-false}"
WORK="$(mktemp -d)"
SRC="local?root=$WORK/store-a"
DST="local?root=$WORK/store-b"
trap 'rm -rf "$WORK"' EXIT
XP='nix-command flakes ca-derivations'

echo "== ca-derivation (substitutes=$SUBST) =="

# A content-addressed derivation (__contentAddressed = true).
DRV="$("$NIX" --extra-experimental-features "$XP" --store "$SRC" \
  eval --impure --raw --expr \
  'builtins.unsafeDiscardStringContext (derivation {
      name = "amrit-ca-test";
      system = builtins.currentSystem;
      builder = "/bin/sh";
      args = ["-c" "echo ca > $out"];
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
   }).drvPath')"
echo "ca-drv=$DRV"

"$NIX" --extra-experimental-features "$XP" \
  --store "$SRC" --max-jobs 0 \
  --builders "$DST $("$NIX" eval --impure --raw --expr 'builtins.currentSystem') - 1 1" \
  --option builders-use-substitutes "$SUBST" \
  build "$DRV^*" --no-link --print-out-paths

echo "== done (expected: built via buildDerivation overload, CA branch) =="
record_store "$DST" "${RECORD_PREFIX:-/dev/stdout}.dst"
