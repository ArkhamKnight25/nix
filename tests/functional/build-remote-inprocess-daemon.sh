#!/usr/bin/env bash

# The in-process remote build inside `nix daemon`, the multi-user setup:
# the client only asks, the daemon's worker picks the machine and runs
# the remote build as a coroutine in the daemon's connection process.
#
# The daemon serves a store of its own, `local?root=$dstore` (same store
# directory, other location), so that what it copies back is told apart
# from the machine's copy. The machine is `ssh-ng://localhost`, i.e. the
# test's own plain store, served by a `nix-daemon --stdio` that the
# daemon's connection process starts (ssh.cc, fakeSSH). The daemon runs
# with `NIX_REMOTE=` so that this `nix-daemon --stdio` opens that store
# itself. A test daemon of the suite's daemon variant, if any, is left
# alone: this one has its own socket.
#
# The client sends `--builders`, `-j0` and `-vvv` to the daemon
# (remote-store.cc, RemoteStore::setOptions); a trusted client may set
# `builders` (daemon.cc), and the test nix.conf trusts the test user.
# With `-vvv` the daemon's debug messages, the goals' traces among them,
# reach the client's stderr (daemon.cc, TunnelLogger::log).
#
# 1. Two remote builds that wait for each other both complete, so the
#    daemon's worker had both in flight; their outputs and their logs
#    are in the daemon's store.
# 2. A client stopped while its remote build runs: the daemon's
#    connection process notices (MonitorFdHup), its worker goes away,
#    and the machine's builder is stopped with it.

source common.sh

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
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
# Whatever is left: the client, the stuck builder, our daemon.
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

# --- 1. two remote builds at once, through the daemon ----------------

# Each builder writes a marker and waits for the other's, bounded at 600
# polls of 0.1 s, one minute. (Quoted heredoc: `$out` and `$i` are for
# the builder.)
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

# `root=`: a `unix://` client reads `.drv` files from the physical store
# directory itself (nix-build looks the outputs up locally after the
# build), so it must see the daemon's chroot store the way the daemon does.
outPaths=$(timeout 200 nix-build "$TEST_ROOT/daemon.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" \
  --store "unix://$sock?root=$dstore" --builders "ssh-ng://localhost - - 2 1" -j0 \
  --no-out-link -vvv 2> "$log")

[[ $(echo "$outPaths" | wc -l) -eq 2 ]]
[[ $(grep -c '^ok$' "$sync/met") -eq 2 ]]
grepQuietInverse timeout "$sync/met"

# The outputs were copied back into the daemon's own store, which is
# not the machine's.
for outPath in $outPaths; do
    nix path-info --store "local?root=$dstore" "$outPath"
done

# The daemon's worker wrote the log, into its store's log directory
# (local-fs-store.cc, getBuildLogExact under `root`). Not through
# `--store unix://`: that store reads the log directory of the test's
# own store, which is the machine's, and has the machine's log.
drvPath=$(nix-instantiate "$TEST_ROOT/daemon.nix" -A a \
  --argstr configNix "$config_nix" --argstr sync "$sync" --store "unix://$sock")
nix log --store "local?root=$dstore" "$drvPath" | grepQuiet inprocess-daemon-a-says-hello

# Both on the in-process path in the daemon, no hook
# (derivation-building-goal.cc, buildRemotely; hook-instance.cc).
grepQuiet "building '.*-inprocess-daemon-a.drv' on 'ssh-ng://localhost'" "$log"
grepQuiet "building '.*-inprocess-daemon-b.drv' on 'ssh-ng://localhost'" "$log"
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "still in flight when the worker went away" "$log"

# --- 2. the client goes away mid-build -------------------------------

# Not under `timeout`: the test stops it, and the trap kills it should
# that fail.
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
[[ $status -ne $((128 + 6)) && $status -ne $((128 + 11)) ]] || fail "the client died with status $status"

# Only the daemon's connection process holds the machine's connection;
# the builder stops once that process has given up the build.
for _ in $(seq 60); do
    kill -0 "$builder" 2> /dev/null || break
    sleep 1
done
kill -0 "$builder" 2> /dev/null && fail "the remote builder is still running a minute after the client went away"

# The connection process did not die of a signal (nix/unix/daemon.cc:
# "daemon worker %1% crashed" for SIGABRT, SIGSEGV and the like).
grepQuietInverse "crashed" "$dlog"
grepQuiet "building '.*-inprocess-daemon-stuck.drv' on 'ssh-ng://localhost'" "$log"
grepQuietInverse "starting build hook '" "$log"
