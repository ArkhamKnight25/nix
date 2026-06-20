#!/usr/bin/env bash
# Shared helpers for flow scripts. Source this.
set -euo pipefail

NIX_BUILD_DIR="${NIX_BUILD_DIR:-$HOME/nix-gsoc/build}"
NIX="$NIX_BUILD_DIR/src/nix/nix"

if [[ ! -x "$NIX" ]]; then
  echo "ERROR: built nix not found at $NIX" >&2
  echo "Build first: nix develop --command ninja -C build" >&2
  exit 1
fi

# A trivial derivation that always builds (no fetch, deterministic).
# Writes the .drv into the given store and echoes its drv path.
trivial_drv() {
  local store="$1"
  "$NIX" --extra-experimental-features 'nix-command flakes' \
    --store "$store" \
    eval --impure --raw --expr \
    'builtins.unsafeDiscardStringContext (derivation {
        name = "amrit-test";
        system = builtins.currentSystem;
        builder = "/bin/sh";
        args = ["-c" "echo hi > $out"];
     }).drvPath'
}

record_store() {
  # $1 = store URI, $2 = output file. Records valid paths (sorted).
  # If $2 looks like /dev/stdout.*, print to stdout instead of writing a file.
  local store="$1" out="$2"
  if [[ "$out" == /dev/stdout* ]]; then
    "$NIX" --store "$store" path-info --all 2>/dev/null | sort || true
  else
    "$NIX" --store "$store" path-info --all 2>/dev/null | sort > "$out" || true
  fi
}
