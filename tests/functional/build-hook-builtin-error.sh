#!/usr/bin/env bash

# A builder the default hook cannot reach is reported, and the build
# fails. Same setup as `build-hook-builtin-ssh.sh`.

source common.sh

TODO_NixOS
# Elsewhere the built-in hook runs `nix __build-remote` as a program.
[[ $(uname) =~ ^(Linux|Darwin|FreeBSD)$ ]] || skipTest "the built-in build hook does not fork on $(uname)"

missing="$TEST_ROOT/no-such-program"

(! nix-build --store "file://$TEST_ROOT/cache" -j0 dependencies.nix --no-out-link -vvv \
    --builders "ssh-ng://localhost?remote-program=$missing - - 1 1" 2> "$TEST_ROOT/log")

grepQuiet "starting the built-in build hook" "$TEST_ROOT/log"
grepQuiet "cannot build on 'ssh-ng://localhost" "$TEST_ROOT/log"
grepQuiet "$missing" "$TEST_ROOT/log"
grepQuietInverse "build hook died unexpectedly" "$TEST_ROOT/log"
