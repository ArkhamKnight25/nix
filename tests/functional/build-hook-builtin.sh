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
# `-vvv`: which hook was started is only reported at `lvlDebug`, and the
# hook reports the failed selection at `lvlChatty` when the build could
# run locally anyway, which is the case here.
out=$(nix-build dependencies.nix --no-out-link -vvv \
    --builders "$TEST_ROOT/nosuchstore nosuchsystem - 1 1" 2>&1)

# `HookInstance::builtin` was started, not `HookInstance::external`.
# The `nix __build-remote` shim prints the same selection failure as the
# fork, so the message checked below cannot tell the two apart by itself.
echo "$out" | grepQuiet "starting the built-in build hook"
echo "$out" | grepQuietInverse "starting build hook '"

# The message comes from `serveBuildHook`, so seeing it proves the hook
# got as far as choosing a machine.
echo "$out" | grepQuiet "Failed to find a machine for remote build"

# The hook declined rather than dying.
echo "$out" | grepQuietInverse "build hook died unexpectedly"

# And the build still succeeded, locally.
nix-build dependencies.nix --no-out-link
