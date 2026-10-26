#!/usr/bin/env bash

# A derivation with several outputs, built on an `ssh-ng://` machine by
# the in-process remote builder: every output must be copied back and
# be valid locally, not only the first. The copy-back runs on the
# coroutine's own thread; a copy that fanned out to a thread pool once
# came back with outputs missing.

source common.sh

TODO_NixOS

clearStore
cache="$TEST_ROOT/cache"
rm -rf "$cache"

# The local store is a binary cache and cannot build, so `-j0` sends the
# build to the machine. `ssh-ng://localhost` is this machine's own store,
# reached without ssh (see build-remote.sh). `build-hook` is at its
# default, so no hook process runs: the worker drives the build itself.
# The client builds for `file://`, daemon or not, so this needs no
# `needLocalStore`.
#
# `.all` lists one derivation per output, so nix-build prints them all.
# shellcheck disable=SC2016
outPaths=$(nix-build --store "file://$cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
    --no-out-link -vvv -E '
  with import '"${config_nix}"';
  (mkDerivation {
    name = "inprocess-multi-output";
    outputs = [ "out" "dev" "doc" "man" ];
    buildCommand = "mkdir $out $dev $doc $man; echo out > $out/f; echo dev > $dev/f; echo doc > $doc/f; echo man > $man/f";
  }).all
' 2> "$TEST_ROOT/log")

[[ $(wc -l <<< "$outPaths") -eq 4 ]] || fail "expected four output paths, got: $outPaths"

grepQuiet "on 'ssh-ng://localhost'" "$TEST_ROOT/log"
grepQuietInverse "starting build hook" "$TEST_ROOT/log"

# Every output is valid in the local store, not only `out`.
for p in $outPaths; do
    nix path-info --store "file://$cache" "$p"
done
