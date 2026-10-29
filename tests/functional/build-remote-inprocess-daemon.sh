#!/usr/bin/env bash

# In-process remote builds work inside `nix daemon`. Two that wait for each
# other both complete, and stopping the client stops the machine's build.
# The daemon serves its own store, `local?root=$dstore`. It runs with
# `NIX_REMOTE=` so that the machine's `nix-daemon --stdio` opens the test
# store itself.

source common.sh

# Fail on undefined behaviour in sanitizer builds.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

dstore="$TEST_ROOT/dstore"
sock="$TEST_ROOT/dSocket2"
sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
dlog="$TEST_ROOT/daemon-log"
chmod -R +w "$dstore" 2> /dev/null || true
rm -rf "$dstore" "$sync" "$sock"
mkdir -p "$sync"
daemon=
client=
# Kill the client, the stuck builder and our daemon if they are left.
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2 || true; echo "--- daemon log ---" >&2; cat "$dlog" >&2 || true; }; [[ -z $client ]] || kill -KILL "$client" 2> /dev/null || true; [[ ! -s $sync/stuck-pid ]] || kill -KILL "$(< "$sync/stuck-pid")" 2> /dev/null || true; [[ -z $daemon ]] || kill -KILL "$daemon" 2> /dev/null || true; killDaemon' EXIT

NIX_REMOTE='' nix --extra-experimental-features nix-command daemon \
    --store "local?root=$dstore" --socket-path "$sock" 2> "$dlog" &
daemon=$!
for _ in $(seq 100); do
    [[ -S $sock ]] && break
    kill -0 "$daemon" 2> /dev/null || fail "the daemon died"
    sleep 0.1
done
[[ -S $sock ]] || fail "the daemon did not start"

# Two remote builds at once, through the daemon.

# Each builder waits up to a minute for the other to start.
cat > "$TEST_ROOT/daemon.nix" <<'NIX'
{ configNix, sync }:
with import configNix;
let
  meet = me: other: ''
    echo inprocess-daemon-${me}-says-hello
    echo started > ${sync}/${me}
    i=0
    while [ ! -e ${sync}/${other} ]; do
      i=$((i + 1))
      if [ $i -ge 600 ]; then echo timeout >> ${sync}/met; exit 1; fi
      sleep 0.1
    done
    echo ok >> ${sync}/met
    echo ${me} > $out
  '';
in
{
  a = mkDerivation { name = "inprocess-daemon-a"; buildCommand = meet "a" "b"; };
  b = mkDerivation { name = "inprocess-daemon-b"; buildCommand = meet "b" "a"; };
}
NIX

# Not `nix-build`, which reads the `.drv` files from the store directory to
# print the outputs, and the client cannot see the daemon's chroot store.
outPaths=$(timeout 200 nix build -f "$TEST_ROOT/daemon.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" \
  --store "unix://$sock" --builders "ssh-ng://localhost - - 2 1" -j0 \
  --no-link --print-out-paths -vvv 2> "$log")

[[ $(echo "$outPaths" | wc -l) -eq 2 ]]
[[ $(grep -c '^ok$' "$sync/met") -eq 2 ]]
grepQuietInverse timeout "$sync/met"

# The outputs were copied back into the daemon's store.
for outPath in $outPaths; do
    nix path-info --store "local?root=$dstore" "$outPath"
done

# The daemon's worker wrote the log into its own store. `--store unix://`
# would read the test store's logs, which are the machine's.
drvPath=$(nix-instantiate "$TEST_ROOT/daemon.nix" -A a \
  --argstr configNix "$config_nix" --argstr sync "$sync" --store "unix://$sock")
nix log --store "local?root=$dstore" "$drvPath" | grepQuiet inprocess-daemon-a-says-hello

# Both built in-process in the daemon, with no hook.
grepQuiet "building '.*-inprocess-daemon-a.drv' on 'ssh-ng://localhost'" "$log"
grepQuiet "building '.*-inprocess-daemon-b.drv' on 'ssh-ng://localhost'" "$log"
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "still in flight when the worker went away" "$log"

# The client goes away mid-build.

# No `timeout`: the test stops the client itself, or the trap kills it.
# shellcheck disable=SC2016
nix-build --store "unix://$sock" --builders "ssh-ng://localhost - - 1 1" -j0 \
    --no-out-link -vvv -E '
  with import '"${config_nix}"';
  mkDerivation {
    name = "inprocess-daemon-stuck";
    buildCommand = "echo $$ > '"$sync"'/stuck-pid; exec sleep 1000";
  }
' 2> "$log" &
client=$!

for _ in $(seq 60); do
    [[ -s $sync/stuck-pid ]] && break
    sleep 1
done
[[ -s $sync/stuck-pid ]] || fail "the remote build did not start"
builder=$(< "$sync/stuck-pid")
kill -0 "$builder" || fail "the remote builder is not running"

kill -TERM "$client"
for _ in $(seq 60); do
    kill -0 "$client" 2> /dev/null || break
    sleep 1
done
kill -0 "$client" 2> /dev/null && fail "the client is still running a minute after SIGTERM"
status=0
wait "$client" || status=$?
client=
[[ $status -ne 0 && $status -lt 128 ]] || fail "the client ended with status $status"

# Only the daemon's connection process holds the machine's connection, so
# the builder stops once that process gives up the build.
for _ in $(seq 60); do
    kill -0 "$builder" 2> /dev/null || break
    sleep 1
done
kill -0 "$builder" 2> /dev/null && fail "the remote builder is still running a minute after the client went away"

# The daemon logs "crashed" if a connection process dies of a signal.
grepQuietInverse "crashed" "$dlog"
grepQuiet "building '.*-inprocess-daemon-stuck.drv' on 'ssh-ng://localhost'" "$log"
grepQuietInverse "starting build hook '" "$log"
