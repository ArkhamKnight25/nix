#!/usr/bin/env bash

# The default build hook is a fork, not `nix __build-remote`. With no
# matching machine it declines and the build runs locally.

source common.sh

# Older daemons exec the shim, which never prints the line checked below.
requireDaemonNewerThan "2.36pre"
TODO_NixOS
# Elsewhere the built-in hook runs `nix __build-remote` as a program.
[[ $(uname) =~ ^(Linux|Darwin|FreeBSD)$ ]] || skipTest "the built-in build hook does not fork on $(uname)"

# A machine for a system nothing matches: the hook starts and declines.
# `-vvv` logs which hook started.
out=$(nix-build dependencies.nix --no-out-link -vvv \
    --builders "$TEST_ROOT/nosuchstore nosuchsystem - 1 1" 2>&1)

# The fork was started, not a program.
echo "$out" | grepQuiet "starting the built-in build hook"
echo "$out" | grepQuietInverse "starting build hook '"

# The hook got as far as choosing a machine.
echo "$out" | grepQuiet "Failed to find a machine for remote build"

# The hook declined rather than dying.
echo "$out" | grepQuietInverse "build hook died unexpectedly"
