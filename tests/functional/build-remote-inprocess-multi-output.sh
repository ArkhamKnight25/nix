#!/usr/bin/env bash

# A multi-output derivation built in-process on an `ssh-ng://` machine has
# every output copied back and valid locally, not only the first. This
# once failed when the copy-back fanned out to a thread pool.

source common.sh

# Fail on undefined behaviour in sanitizer builds.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

clearStore
cache="$TEST_ROOT/cache"
rm -rf "$cache"

# The binary-cache store cannot build, so `-j0` sends the build to the
# machine. `.all` lists one derivation per output, so nix-build prints all.
# shellcheck disable=SC2016
outPaths=$(timeout 200 nix-build --store "file://$cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
    --no-out-link -vvv -E '
  with import '"${config_nix}"';
  (mkDerivation {
    name = "inprocess-multi-output";
    outputs = [ "out" "dev" "doc" "man" ];
    buildCommand = "mkdir $out $dev $doc $man; echo out > $out/f; echo dev > $dev/f; echo doc > $doc/f; echo man > $man/f";
  }).all
' 2> "$TEST_ROOT/log")

[[ $(wc -l <<< "$outPaths") -eq 4 ]] || fail "expected four output paths, got: $outPaths"

# Only the in-process path traces "remote build done".
grepQuiet "on 'ssh-ng://localhost'" "$TEST_ROOT/log"
grepQuiet "remote build done" "$TEST_ROOT/log"
grepQuietInverse "starting build hook" "$TEST_ROOT/log"

# Every output is valid in the local store, not only `out`.
for p in $outPaths; do
    nix path-info --store "file://$cache" "$p"
done
