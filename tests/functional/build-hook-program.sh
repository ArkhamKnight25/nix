#!/usr/bin/env bash

# A `build-hook` of `nix __build-remote` runs that program, and the
# program, not the worker, builds on the machine.
# Binary-cache client store and `-j0`, so nothing builds locally.

source common.sh

TODO_NixOS

cache="$TEST_ROOT/cache"

outPath=$(nix-build --store "file://$cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
    --option build-hook "$(type -P nix) __build-remote" \
    dependencies.nix --no-out-link -vvv 2> "$TEST_ROOT/log")

nix path-info --store "file://$cache" "$outPath"

grepQuiet "starting build hook '" "$TEST_ROOT/log"
grepQuietInverse "remote build done" "$TEST_ROOT/log"
grepQuiet "on 'ssh-ng://localhost'" "$TEST_ROOT/log"
grepQuietInverse "build hook died unexpectedly" "$TEST_ROOT/log"
