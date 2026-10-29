#!/usr/bin/env bash

# `build-hook` naming `nix __build-remote` by path runs that program, and
# it builds; the worker does not build on the machine itself. Same setup
# as `build-remote-inprocess-multi-output.sh`: binary-cache client store,
# `-j0`, the test's own store as an `ssh-ng://localhost` machine.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

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
