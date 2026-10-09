#!/usr/bin/env bash

# The default hook builds over `ssh://` and `ssh-ng://`. The client store
# is a binary cache and `-j0` is set, so every derivation goes remote.
# For `localhost` Nix runs the remote command without ssh.

source common.sh

TODO_NixOS
# Elsewhere the built-in hook runs `nix __build-remote` as a program.
[[ $(uname) =~ ^(Linux|Darwin|FreeBSD)$ ]] || skipTest "the built-in build hook does not fork on $(uname)"

for builder in ssh://localhost ssh-ng://localhost; do
    clearStore
    cache="$TEST_ROOT/cache-${builder%%:*}"
    rm -rf "$cache"

    outPath=$(nix-build --store "file://$cache" --builders "$builder - - 1 1" -j0 \
        dependencies.nix --no-out-link -vvv 2> "$TEST_ROOT/log")

    # The result was copied back to the client's store.
    nix path-info --store "file://$cache" "$outPath"

    # Built remotely, by the fork.
    grepQuiet "starting the built-in build hook" "$TEST_ROOT/log"
    grepQuietInverse "starting build hook '" "$TEST_ROOT/log"
    grepQuiet "on '$builder'" "$TEST_ROOT/log"
    # Its log after accepting reaches the user.
    grepQuiet "copying outputs from '$builder'" "$TEST_ROOT/log"
    grepQuietInverse "build hook died unexpectedly" "$TEST_ROOT/log"
done
