#!/usr/bin/env bash

# A remote build that fails, next to one still in flight on the same
# `ssh-ng` machine.
#
# - With `--keep-going`, the sibling is left alone: it is still running
#   after the client has taken in the failure, and it completes.
# - Without it, the worker drops its other goals (worker.cc, removeGoal),
#   which cancels the sibling's coroutine (derivation-building-goal.cc,
#   buildRemotely: `CancelOnExit`), and the sibling's builder is stopped.
#
# Either way the machine's own verdict comes through: its builder exited
# non-zero, which the machine reports as `PermanentFailure` for an
# input-addressed derivation (derivation-building-goal.cc, buildLocally),
# and buildRemotely passes that status on unchanged. `PermanentFailure`
# sets `permanentFailure`, hence exit status 100 (build-result.cc,
# updateFromStatus and failingExitStatus).
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox.

source common.sh

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache" "$TEST_ROOT/sync-"*
mkdir -p "$TEST_ROOT/sync-kg" "$TEST_ROOT/sync-stop"
# Let a held or stray builder finish whatever happens.
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; touch "$TEST_ROOT/sync-kg/release" "$TEST_ROOT/sync-stop/release"; [[ -n ${client-} ]] && kill -KILL "$client" 2> /dev/null; killDaemon' EXIT

# `tag` keeps the two runs' derivations apart. The failing builder waits
# until its sibling is running, so both are in flight when it fails.
# Waits are bounded: 1200 polls of 0.1 s, two minutes. (Quoted heredoc:
# `$out`, `$$` and `$i` are for the builder.)
cat > "$TEST_ROOT/failure.nix" <<'NIX'
{ configNix, sync, tag }:
with import configNix;
let
  waitFor = file: ''
    i=0
    while [ ! -e ${file} ]; do
      i=$((i + 1))
      if [ $i -ge 1200 ]; then exit 2; fi
      sleep 0.1
    done
  '';
in
[
  (mkDerivation {
    name = "inprocess-failure-${tag}-fail";
    buildCommand = ''
      ${waitFor "${sync}/held-pid"}
      echo failing on purpose
      exit 1
    '';
  })
  (mkDerivation {
    name = "inprocess-failure-${tag}-held";
    buildCommand = ''
      echo $$ > ${sync}/held-pid
      ${waitFor "${sync}/release"}
      echo $out > ${sync}/held-out
      echo held > $out
    '';
  })
]
NIX

# Starts the client in the background; `$client` is the `timeout`
# process, which lives as long as the client and exits with its status.
startClient() {
    local tag=$1
    shift
    timeout 200 nix-build "$TEST_ROOT/failure.nix" \
      --argstr configNix "$config_nix" --argstr sync "$TEST_ROOT/sync-$tag" --argstr tag "$tag" \
      --store "file://$cache" --builders "ssh-ng://localhost - - 2 1" -j0 \
      --no-out-link -vvv "$@" 2> "$log" &
    client=$!
}

waitForClient() {
    for _ in $(seq 120); do
        kill -0 "$client" 2> /dev/null || break
        sleep 1
    done
    kill -0 "$client" 2> /dev/null && fail "the client is still running after two minutes"
    status=0
    wait "$client" || status=$?
}

# --- 1. --keep-going: the sibling survives --------------------------

sync="$TEST_ROOT/sync-kg"
startClient kg --keep-going

for _ in $(seq 120); do
    [[ -s $sync/held-pid ]] && break
    sleep 1
done
[[ -s $sync/held-pid ]] || fail "the held build did not start"
held=$(< "$sync/held-pid")

# Wait until the client has the failing build's result: the goal traces
# this when its coroutine has returned, and takes the failure in the same
# turn of the loop (derivation-building-goal.cc, buildRemotely).
for _ in $(seq 120); do
    grepQuiet "inprocess-failure-kg-fail.drv': remote build done" "$log" && break
    sleep 1
done
grepQuiet "inprocess-failure-kg-fail.drv': remote build done" "$log" \
    || fail "the failing build did not finish"

# The sibling is still running, then completes.
kill -0 "$held" 2> /dev/null || fail "the held builder died with the failing one"
kill -0 "$client" 2> /dev/null || fail "the client exited before the held build was released"
touch "$sync/release"
waitForClient

[[ $status -eq 100 ]] || fail "expected exit status 100, got $status"
grepQuietInverse "Nix crashed" "$log"
# The machine's message (derivation-building-goal.cc,
# fixupBuilderFailureErrorMessage), not a reworded one.
grepQuiet "builder failed with exit code 1" "$log"
[[ -s $sync/held-out ]] || fail "the held build did not finish"
nix path-info --store "file://$cache" "$(< "$sync/held-out")"
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuietInverse "still in flight when the worker went away" "$log"
grepQuietInverse "starting build hook '" "$log"

# --- 2. without --keep-going: the sibling is stopped ----------------

sync="$TEST_ROOT/sync-stop"
startClient stop

for _ in $(seq 120); do
    [[ -s $sync/held-pid ]] && break
    sleep 1
done
[[ -s $sync/held-pid ]] || fail "the held build did not start"
held=$(< "$sync/held-pid")

# Nothing releases the held build: the client must finish without it.
waitForClient

# The failure decides the status; the cancelled sibling adds no flag of
# its own (entry-points.cc, Worker::buildPaths).
[[ $status -eq 100 ]] || fail "expected exit status 100, got $status"
grepQuietInverse "Nix crashed" "$log"
grepQuiet "builder failed with exit code 1" "$log"

# The sibling's builder is gone, without ever having finished.
for _ in $(seq 60); do
    kill -0 "$held" 2> /dev/null || break
    sleep 1
done
if kill -0 "$held" 2> /dev/null; then
    kill -KILL "$held" || true
    fail "the held builder is still running a minute after the client exited"
fi
[[ ! -e $sync/held-out ]] || fail "the held build finished although it was never released"

# Its coroutine was cancelled and finished before the worker went away
# (worker.cc, ~Worker).
grepQuietInverse "still in flight when the worker went away" "$log"
grepQuietInverse "starting build hook '" "$log"
