#!/usr/bin/env bash

# Failures on the in-process path are reported, named, and do not crash.
#
# 1. A machine whose `remote-program` cannot be started: the error names
#    the machine, the machine is given up on, and with `-j0` (and a
#    binary-cache client store, so nothing can run locally) the build
#    fails with the usual explanation.
# 2. A `builders` line that does not parse: the error is reported once
#    per worker, the machine list is treated as empty, and the build
#    runs locally where that is allowed (`-j1`, local store) or fails
#    where it is not (`-j0`, binary-cache store).
#
# No sandbox: nothing is ever built on a machine here.

source common.sh

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# shellcheck disable=SC2016
expr='
  with import '"${config_nix}"';
  mkDerivation { name = "inprocess-error"; buildCommand = "echo e > $out"; }
'

# A `remote-program` that cannot be started.

# With `localhost` the program is run directly (ssh.cc, fakeSSH), so a
# missing program is an exec failure in the child: the connection sees
# end-of-file in the handshake, `buildOnRemoteMachine` reports it
# (remote-machine-build.cc: "cannot build on '%s': %s"), disables the
# machine, finds no other, and hands the build back for a local attempt.
status=0
timeout 200 nix-build -E "$expr" --store "file://$cache" -j0 --no-out-link -vvv \
  --builders "ssh-ng://localhost?remote-program=$TEST_ROOT/no-such-program - - 1 1" \
  2> "$log" || status=$?
[[ $status -ne 0 ]] || fail "the build succeeded with no machine and no local builds"
[[ $status -ne $((128 + 6)) && $status -ne $((128 + 11)) ]] || fail "the client died with status $status"
grepQuietInverse "Nix crashed" "$log"

# The error names the machine and the bad parameter.
grepQuiet "cannot build on 'ssh-ng://localhost.*no-such-program" "$log"
# No machine is left, and the binary-cache store cannot build locally.
grepQuiet "Unable to build with a primary store that isn't a local store" "$log"
# Nothing was copied to a machine and no hook started. "remote build done"
# is traced even when no machine is reached, so it is no marker here.
grepQuietInverse "copying dependencies to" "$log"
grepQuietInverse "starting build hook '" "$log"

# A `builders` line that does not parse.

# Column 3 is `maxJobs`, an unsigned int.
badBuilders="ssh-ng://localhost - - notanumber 1"
parseError="bad machine specification: failed to convert column #3 in a row"

# 2a. Nowhere to build: the parse error is reported, then the usual failure.
status=0
timeout 200 nix-build -E "$expr" --store "file://$cache" -j0 --no-out-link -vvv \
  --builders "$badBuilders" 2> "$log" || status=$?
[[ $status -ne 0 ]] || fail "the build succeeded with an unparsable machine list and no local builds"
[[ $status -ne $((128 + 6)) && $status -ne $((128 + 11)) ]] || fail "the client died with status $status"
grepQuiet "$parseError" "$log"
grepQuiet "Unable to build with a primary store that isn't a local store" "$log"
grepQuietInverse "Nix crashed" "$log"

# 2b. Local builds allowed: both derivations build locally, and the
# parse error is reported once, not once per derivation. The first goal
# to ask parses the list (worker.cc, Worker::remoteMachines), finds it
# empty and clears `worker.tryBuildHook`; the second is then declined by
# that guard at the top of selectRemoteMachine
# (derivation-building-goal.cc) without looking at the list again.
# shellcheck disable=SC2016
outPaths=$(timeout 200 nix-build --no-out-link -vvv -j2 --builders "$badBuilders" -E '
  with import '"${config_nix}"';
  [ (mkDerivation { name = "inprocess-error-local-a"; buildCommand = "echo a > $out"; })
    (mkDerivation { name = "inprocess-error-local-b"; buildCommand = "echo b > $out"; }) ]
' 2> "$log")
[[ $(echo "$outPaths" | wc -l) -eq 2 ]]
for outPath in $outPaths; do
    [[ -s $outPath ]]
done
[[ $(grep -c "$parseError" "$log") -eq 1 ]]
grepQuietInverse "remote build done" "$log"
grepQuietInverse "starting build hook '" "$log"
