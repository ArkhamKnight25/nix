#!/usr/bin/env bash

# An unreachable machine is skipped for the build that could not reach
# it. Two `ssh-ng` machines: the first cannot be started (its
# `remote-program` does not exist), the second is the test's own store.
# Two derivations, one depending on the other, so they are built one
# after the other.
#
# Each is offered the unreachable machine: the selection prefers it
# (machine-selection.cc, machineIsBetter: equal load, higher speed
# factor). Its coroutine reports the failure, passes the machine over
# for this build and moves on to the next one itself
# (remote-machine-build.cc, buildOnRemoteMachine), so one coroutine
# builds each: the error is printed twice, and two coroutines run in all.
# A coroutine that gave up after the first machine would make the goal
# ask again and run more; a machine disabled for the whole invocation
# would print the error once.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Separate URIs, so separate slot locks (machine-selection.cc, openSlotLock).
unreachable="ssh-ng://localhost?remote-program=$TEST_ROOT/no-such-program - - 1 2"
reachable="ssh-ng://localhost - - 1 1"

# shellcheck disable=SC2016
outPath=$(timeout 200 nix-build --store "file://$cache" -j0 --no-out-link -vvv \
  --builders "$unreachable ; $reachable" -E '
  with import '"${config_nix}"';
  let
    first = mkDerivation { name = "inprocess-fallback-first"; buildCommand = "echo first > $out"; };
  in
  mkDerivation { name = "inprocess-fallback-second"; buildCommand = "echo ${first} > $out"; }
' 2> "$log")

# Both were built, and came back. The second refers to the first.
nix path-info --store "file://$cache" "$outPath"
nix path-info --store "file://$cache" --recursive "$outPath" | grepQuiet inprocess-fallback-first

# Each build tried the unreachable machine once, and named what made it
# so (remote-machine-build.cc: "cannot build on '%s': %s"). Once per
# build, not once per invocation: a machine is passed over for the build
# that could not reach it, as the hook disabled it for the life of a hook
# process, which built one derivation.
[[ $(grep -c "cannot build on 'ssh-ng://localhost.*no-such-program" "$log") -eq 2 ]]

# One coroutine per derivation, the fallback included.
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuiet "inprocess-fallback-first.drv': remote build done" "$log"
grepQuiet "inprocess-fallback-second.drv': remote build done" "$log"

grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "Nix crashed" "$log"
