#!/usr/bin/env bash

# The built-in hook accepts a build and runs it over `ssh://` and
# `ssh-ng://`. The `build-remote-*` tests need Linux; this does not.
# The client store is a binary cache, which cannot build, and `-j0`
# forbids building locally, so the hook has to take every derivation.
# For `localhost` Nix runs the remote command itself, without ssh.

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

    # It went through the fork, which accepted and built on the machine.
    grepQuiet "starting the built-in build hook" "$TEST_ROOT/log"
    grepQuietInverse "starting build hook '" "$TEST_ROOT/log"
    grepQuiet "on '$builder'" "$TEST_ROOT/log"
    # Its messages after accepting reach the user too; the parent takes
    # only JSON from it by then.
    grepQuiet "copying outputs from '$builder'" "$TEST_ROOT/log"
    grepQuietInverse "build hook died unexpectedly" "$TEST_ROOT/log"
done
