#!/usr/bin/env bash

# A remote build fails while its sibling is in flight on the same machine.
# With `--keep-going` the sibling completes, without it the sibling's
# builder is stopped. Either way the exit status is 100.
# Binary-cache client store and `-j0`, so nothing builds locally.

source common.sh

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache" "$TEST_ROOT/sync-"*
mkdir -p "$TEST_ROOT/sync-kg" "$TEST_ROOT/sync-stop"
# Let a held or stray builder finish whatever happens.
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; touch "$TEST_ROOT/sync-kg/release" "$TEST_ROOT/sync-stop/release"; [[ -n ${client-} ]] && kill -KILL "$client" 2> /dev/null || true; killDaemon' EXIT

# `tag` keeps the two runs' derivations apart. The failing builder waits
# until its sibling is running, so both are in flight when it fails.
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

# `$client` is the `timeout` process, which exits with the client's status.
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

# With `--keep-going` the sibling survives.

sync="$TEST_ROOT/sync-kg"
startClient kg --keep-going

for _ in $(seq 120); do
    [[ -s $sync/held-pid ]] && break
    sleep 1
done
[[ -s $sync/held-pid ]] || fail "the held build did not start"
held=$(< "$sync/held-pid")

# Wait for the failing build's result. The goal traces this in the same
# turn of the event loop as it takes in the failure.
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
# The machine's own message, not a reworded one.
grepQuiet "builder failed with exit code 1" "$log"
[[ -s $sync/held-out ]] || fail "the held build did not finish"
nix path-info --store "file://$cache" "$(< "$sync/held-out")"
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuietInverse "still in flight when the worker went away" "$log"
grepQuietInverse "starting build hook '" "$log"

# Without `--keep-going` the sibling is stopped.

sync="$TEST_ROOT/sync-stop"
startClient stop

for _ in $(seq 120); do
    [[ -s $sync/held-pid ]] && break
    sleep 1
done
[[ -s $sync/held-pid ]] || fail "the held build did not start"
held=$(< "$sync/held-pid")

# Nothing releases the held build, so the client must finish without it.
waitForClient

# The cancelled sibling adds no exit-status flag of its own.
[[ $status -eq 100 ]] || fail "expected exit status 100, got $status"
grepQuietInverse "Nix crashed" "$log"
grepQuiet "builder failed with exit code 1" "$log"

# The sibling's builder is gone and never finished.
for _ in $(seq 60); do
    kill -0 "$held" 2> /dev/null || break
    sleep 1
done
if kill -0 "$held" 2> /dev/null; then
    kill -KILL "$held" || true
    fail "the held builder is still running a minute after the client exited"
fi
[[ ! -e $sync/held-out ]] || fail "the held build finished although it was never released"

# Its coroutine was cancelled and finished before the worker went away.
grepQuietInverse "still in flight when the worker went away" "$log"
grepQuietInverse "starting build hook '" "$log"
