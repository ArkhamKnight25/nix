#!/usr/bin/env bash

# An `ssh-ng` machine that cannot be started is passed over inside the
# coroutine for the next one, per build rather than for the whole run,
# and errors name the machine that ran the build.
# Binary-cache client store and `-j0`, so nothing builds locally.

source common.sh

# Fail on undefined behaviour in sanitizer builds.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Separate URIs, so separate slot locks.
unreachable="ssh-ng://localhost?remote-program=$TEST_ROOT/no-such-program - - 1 2"
reachable="ssh-ng://localhost - - 1 1"

# A chain, so that each build is selected at load 0 and the speed factor
# picks the unreachable machine. Selected together, the second would take
# the other machine straight away.
# shellcheck disable=SC2016
outPaths=$(timeout 200 nix-build --store "file://$cache" -j0 --no-out-link -vvv \
  --builders "$unreachable ; $reachable" -E '
  with import '"${config_nix}"';
  let a = mkDerivation { name = "inprocess-failover-ssh-ng-a"; buildCommand = "echo a > $out"; };
  in [ a (mkDerivation { name = "inprocess-failover-ssh-ng-b"; buildCommand = "cat ${a} > $out; echo b >> $out"; }) ]
' 2> "$log")

[[ $(echo "$outPaths" | wc -l) -eq 2 ]]
for outPath in $outPaths; do
    nix path-info --store "file://$cache" "$outPath"
done

# Each build announced the preferred machine, failed on it and moved on.
[[ $(grep -c "building '.*-inprocess-failover-ssh-ng-[ab].drv' on 'ssh-ng://localhost?remote-program" "$log") -eq 2 ]]
[[ $(grep -c "cannot build on 'ssh-ng://localhost?remote-program=.*no-such-program" "$log") -eq 2 ]]
[[ $(grep -c "building '.*-inprocess-failover-ssh-ng-[ab].drv' on 'ssh-ng://localhost' instead" "$log") -eq 2 ]]
[[ $(grep -c "remote build done" "$log") -eq 2 ]]

# In-process throughout, with no hook and no blocking fallback.
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "is not an ssh-ng store" "$log"
grepQuietInverse "still in flight when the worker went away" "$log"
grepQuietInverse "Nix crashed" "$log"
