#!/usr/bin/env bash

# Stopping the client stops the remote build it started. The builder on
# the machine is `sleep 1000`; the client gets SIGTERM once the builder
# is known to be running, and must exit cleanly (no abort, no crash
# report) with the builder gone shortly after.
#
# With `ssh-ng://localhost` the "ssh child" of the connection is the
# remote daemon itself (`nix-daemon --stdio`, run without ssh). The
# builder dies because the connection's destructor sends that child
# SIGTERM, which the daemon handles by stopping its build (ssh.cc,
# SSHMaster::startCommand: `setKillSignal(SIGTERM)`, SIGKILL after ten
# seconds). The waits below are bounded well above that.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox, so the
# builder can report its pid.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
started="$TEST_ROOT/started"
log="$TEST_ROOT/log"
rm -rf "$cache" "$started"
client=
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; [[ -n $client ]] && kill -KILL "$client" 2> /dev/null || true; killDaemon' EXIT

# shellcheck disable=SC2016
nix-build --store "file://$cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
    --no-out-link -vvv -E '
  with import '"${config_nix}"';
  mkDerivation {
    name = "inprocess-interrupt";
    buildCommand = "echo $$ > '"$started"'; exec sleep 1000";
  }
' 2> "$log" &
client=$!

for _ in $(seq 60); do
    [[ -s $started ]] && break
    sleep 1
done
[[ -s $started ]] || fail "the remote build did not start"
builder=$(< "$started")
kill -0 "$builder" || fail "the remote builder is not running"

# A background job ignores SIGINT; Nix treats SIGTERM the same way.
kill -TERM "$client"

for _ in $(seq 60); do
    kill -0 "$client" 2> /dev/null || break
    sleep 1
done
if kill -0 "$client" 2> /dev/null; then
    kill -KILL "$client" || true
    fail "the client is still running a minute after SIGTERM"
fi
status=0
wait "$client" || status=$?
# An orderly, non-zero exit after an interrupt: not killed by any signal
# (an abort is 134, a segfault 139, an unhandled SIGINT 130).
[[ $status -ne 0 && $status -lt 128 ]] || fail "the client ended with status $status"
grepQuietInverse "Nix crashed" "$log"
# ...and the exit was the interrupt's, not some other failure's.
grepQuiet "interrupted by the user" "$log"
# The cancellation finished the remote-build coroutine before the worker
# was destroyed (worker.cc, ~Worker). The builder check below cannot show
# this on its own: the machine's daemon also stops the build when its
# client goes away (MonitorFdHup), which the client's exit guarantees.
grepQuietInverse "still in flight when the worker went away" "$log"

# The machine's build is gone, with the ssh child that owned it.
for _ in $(seq 60); do
    kill -0 "$builder" 2> /dev/null || break
    sleep 1
done
if kill -0 "$builder" 2> /dev/null; then
    kill -KILL "$builder" || true
    fail "the remote builder is still running"
fi

# The build had been started by the in-process path, not a hook.
grepQuiet "building '.*-inprocess-interrupt.drv' on 'ssh-ng://localhost'" "$log"
grepQuietInverse "starting build hook '" "$log"
