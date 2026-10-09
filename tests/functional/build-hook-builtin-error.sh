#!/usr/bin/env bash

# An error in the built-in hook reaches the user: a machine it cannot
# connect to is reported with the reason, and the build fails instead of
# hanging. Same setup as `build-hook-builtin-ssh.sh`.

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
