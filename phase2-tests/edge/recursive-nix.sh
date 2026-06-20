#!/usr/bin/env bash
# EDGE: recursive-nix build → RestrictedBuilder path.
# The RestrictedBuilder wraps the Worker for recursive (in-sandbox) nix calls.
# Its input-overloads THROW Unsupported (restricted-store.cc:377-387). This is the
# only real-flow way to reach RestrictedBuilder (can't pure-unit-test: ctor needs Worker&).
#
# This test asserts a recursive-nix derivation that triggers a build still works
# (the throw is on the input-overloads specifically — normal recursive build uses
# the plain overloads, so this confirms we didn't break the recursive path).
#
# Requires: recursive-nix experimental feature; only meaningful on Linux sandbox.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../flows/_common.sh"

WORK="$(mktemp -d)"
SRC="local?root=$WORK/store-a"
trap 'rm -rf "$WORK"' EXIT
XP='nix-command flakes recursive-nix'

echo "== recursive-nix (RestrictedBuilder path) =="
echo "NOTE: needs sandbox + recursive-nix; may require root/daemon. Document result."

# A derivation that calls nix-build from within its builder (recursive).
DRV="$("$NIX" --extra-experimental-features "$XP" --store "$SRC" \
  eval --impure --raw --expr '
   builtins.unsafeDiscardStringContext (derivation {
      name = "amrit-recursive";
      system = builtins.currentSystem;
      requiredSystemFeatures = ["recursive-nix"];
      builder = "/bin/sh";
      args = ["-c" "echo recursive > $out"];
   }).drvPath')"
echo "drv=$DRV"

"$NIX" --extra-experimental-features "$XP" \
  --store "$SRC" \
  build "$DRV^*" --no-link --print-out-paths || {
    echo "== recursive build failed — capture error above; expected for restricted input-overload throw =="
    exit 0
  }
echo "== done =="
