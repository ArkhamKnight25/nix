#!/usr/bin/env bash

# An unreachable machine is skipped, and stays skipped. Two `ssh-ng`
# machines: the first cannot be started (its `remote-program` does not
# exist), the second is the test's own store. Two derivations, one
# depending on the other, so they are built one after the other.
#
# The first is offered the unreachable machine: the first selection
# prefers it (machine-selection.cc, machineIsBetter: equal load, higher
# speed factor). Its coroutine reports the failure, disables the machine
# and moves on to the next one itself (remote-machine-build.cc,
# buildOnRemoteMachine), so one coroutine builds it. The second
# derivation is never offered the disabled machine: the error is printed
# once, and two coroutines run in all. A coroutine that gave up after the
# first machine would make the goal ask again and run a third; a machine
# list that forgot the failure would print the error twice.
#
# The "building ... on" line is not checked: it names the machine first
# selected, not the one that built.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox.

source common.sh

# Fail on undefined behaviour in sanitizer builds.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Separate URIs, so separate slot locks.
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

# Both were built and copied back.
nix path-info --store "file://$cache" "$outPath"
nix path-info --store "file://$cache" --recursive "$outPath" | grepQuiet inprocess-fallback-first

# The unreachable machine was tried once, named with what made it so
# (remote-machine-build.cc: "cannot build on '%s': %s").
[[ $(grep -c "cannot build on 'ssh-ng://localhost.*no-such-program" "$log") -eq 1 ]]

# One coroutine per derivation, the fallback included.
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuiet "inprocess-fallback-first.drv': remote build done" "$log"
grepQuiet "inprocess-fallback-second.drv': remote build done" "$log"

grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "Nix crashed" "$log"
