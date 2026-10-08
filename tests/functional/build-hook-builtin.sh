#!/usr/bin/env bash

# With no `build-hook` configured, Nix runs its own hook as a fork of
# itself rather than exec'ing `nix __build-remote`. It still speaks the
# protocol, so a build it cannot place on any builder is declined and
# falls back to the local builder.

source common.sh

needLocalStore "the build hook runs in the process that owns the build loop"
TODO_NixOS

# `builders` has to be non-empty, or the hook declines permanently
# before it reaches any machine selection. This entry is for a system
# nothing matches, so selection finds no machine and declines.
# `-vv` because the hook reports this at `lvlChatty` when the build could
# run locally anyway, which is the case here, and the default is
# `lvlInfo`.
out=$(nix-build dependencies.nix --no-out-link -vv \
    --builders "$TEST_ROOT/nosuchstore nosuchsystem - 1 1" 2>&1)

# The message comes from `serveBuildHook`, so seeing it proves the
# forked hook ran and got as far as choosing a machine.
echo "$out" | grepQuiet "Failed to find a machine for remote build"

# The hook declined rather than dying.
echo "$out" | grepQuietInverse "build hook died unexpectedly"

# And the build still succeeded, locally.
nix-build dependencies.nix --no-out-link
