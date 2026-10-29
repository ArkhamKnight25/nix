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
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
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

# --- 1. unreachable remote-program ----------------------------------

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

# The machine is named, with the parameter that made it unreachable.
grepQuiet "cannot build on 'ssh-ng://localhost.*no-such-program" "$log"
# No machine was left, and the client store cannot build
# (derivation-building-goal.cc, reject: NoLocalStore).
grepQuiet "Unable to build with a primary store that isn't a local store" "$log"
# Nothing was sent to a machine, and no hook was started. ("remote build
# done" is traced whenever the remote-build coroutine returns, including
# when no machine could be reached, so it is not a marker here.)
grepQuietInverse "copying dependencies to" "$log"
grepQuietInverse "starting build hook '" "$log"

# --- 2. unparsable `builders` ---------------------------------------

# Column 3 is `maxJobs`, an unsigned int (machines.cc, parseBuilderLine).
badBuilders="ssh-ng://localhost - - notanumber 1"
parseError="bad machine specification: failed to convert column #3 in a row"

# 2a. Nowhere to build: the build fails with the parse error, as it did
# when the hook died on it, and the client does not crash.
status=0
timeout 200 nix-build -E "$expr" --store "file://$cache" -j0 --no-out-link -vvv \
  --builders "$badBuilders" 2> "$log" || status=$?
[[ $status -ne 0 && $status -lt 128 ]] || fail "expected an orderly failure for an unparsable machine list, got status $status"
grepQuiet "$parseError" "$log"
grepQuietInverse "Nix crashed" "$log"

# 2b. Local builds allowed: still an error. A machine list that does not
# parse is a misconfiguration, not an empty list; the builds are not
# quietly done locally (worker.cc, Worker::remoteMachines).
# shellcheck disable=SC2016
expr2='
  with import '"${config_nix}"';
  [ (mkDerivation { name = "inprocess-error-local-a"; buildCommand = "echo a > $out"; })
    (mkDerivation { name = "inprocess-error-local-b"; buildCommand = "echo b > $out"; }) ]
'
status=0
timeout 200 nix-build --no-out-link -vvv -j2 --builders "$badBuilders" -E "$expr2" 2> "$log" || status=$?
[[ $status -ne 0 && $status -lt 128 ]] || fail "expected an orderly failure for an unparsable machine list, got status $status"
grepQuiet "$parseError" "$log"
for drvPath in $(nix-instantiate -E "$expr2"); do
    for outPath in $(nix-store -q --outputs "$drvPath"); do
        [[ ! -e $outPath ]] || fail "$outPath was built with an unparsable machine list"
    done
done
grepQuietInverse "remote build done" "$log"
grepQuietInverse "starting build hook '" "$log"
