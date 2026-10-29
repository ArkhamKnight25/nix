#!/usr/bin/env bash

# Failing over from one `ssh-ng` machine to another, inside the
# coroutine. The preferred machine (higher speed factor) cannot be
# started: its `remote-program` does not exist. The coroutine reports it,
# passes it over for this build only, selects the next machine, and
# builds there (remote-machine-build.cc, buildOnRemoteMachine). The goal
# announced the first machine; the coroutine says where the build went
# instead, and the goal names that machine from then on.
#
# A second build in the same invocation tries the dead machine again:
# it is not disabled for the worker's life, as the hook disabled it for
# the life of a hook process, which built one derivation.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Separate URIs, so separate slot locks (machine-selection.cc, openSlotLock).
unreachable="ssh-ng://localhost?remote-program=$TEST_ROOT/no-such-program - - 1 2"
reachable="ssh-ng://localhost - - 1 1"

# The second build depends on the first, so the two are selected one
# after the other, each on a tie at load 0 that the speed factor
# decides. Selected in one pass, the second would see the first holding
# the preferred machine's slot (load 1/2 against 0/1) and go to the
# other machine straight away (machine-selection.cc, machineIsBetter).
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

# Each build announced the preferred machine, could not reach it, said
# so once, and went to the other one. Two builds, so twice each.
[[ $(grep -c "building '.*-inprocess-failover-ssh-ng-[ab].drv' on 'ssh-ng://localhost?remote-program" "$log") -eq 2 ]]
[[ $(grep -c "cannot build on 'ssh-ng://localhost?remote-program=.*no-such-program" "$log") -eq 2 ]]
[[ $(grep -c "building '.*-inprocess-failover-ssh-ng-[ab].drv' on 'ssh-ng://localhost' instead" "$log") -eq 2 ]]
[[ $(grep -c "remote build done" "$log") -eq 2 ]]

# In-process throughout: no hook, no blocking fallback.
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "is not an ssh-ng store" "$log"
grepQuietInverse "still in flight when the worker went away" "$log"
grepQuietInverse "Nix crashed" "$log"
