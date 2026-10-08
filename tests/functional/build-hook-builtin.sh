#!/usr/bin/env bash

# With no `build-hook` configured, Nix runs its own hook as a fork of
# itself rather than exec'ing `nix __build-remote`. It still speaks the
# protocol, so a build it cannot place on any builder is declined and
# falls back to the local builder.

source common.sh

# Older daemons exec the shim, which never prints the line checked below.
requireDaemonNewerThan "2.36pre"
TODO_NixOS
# Elsewhere the built-in hook runs `nix __build-remote` as a program.
[[ $(uname) =~ ^(Linux|Darwin|FreeBSD)$ ]] || skipTest "the built-in build hook does not fork on $(uname)"

# `builders` has to be non-empty, or the hook declines permanently
# before it reaches any machine selection. This entry is for a system
# nothing matches, so selection finds no machine and declines; the store
# is never opened. `-vvv`: which hook started is reported at `lvlDebug`.
# Under `set -e` this is also the check that the build still succeeds,
# locally.
out=$(nix-build dependencies.nix --no-out-link -vvv \
    --builders "$TEST_ROOT/nosuchstore nosuchsystem - 1 1" 2>&1)

# The fork was started, not a program.
echo "$out" | grepQuiet "starting the built-in build hook"
echo "$out" | grepQuietInverse "starting build hook '"

# The hook got as far as choosing a machine.
echo "$out" | grepQuiet "Failed to find a machine for remote build"

# The hook declined rather than dying.
echo "$out" | grepQuietInverse "build hook died unexpectedly"
