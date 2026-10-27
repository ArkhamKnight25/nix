#!/usr/bin/env bash

# The machine goes away in the middle of a remote build. The machine's
# end of the connection (`nix-daemon --stdio`, run directly for
# `localhost`; ssh.cc, fakeSSH) is killed with SIGKILL while its builder
# runs. The client's pending read then sees end-of-file
# (serialise-async.hh, AsyncFdSource; ssh-store.cc sets its message), the
# coroutine fails, and the build fails with that message
# (derivation-building-goal.cc, buildRemotely: "Cannot build '%s' on
# '%s': %s"). The client must exit promptly, with an ordinary build
# failure: not hang, abort or crash.
#
# The daemon's pid comes from a wrapper given as `remote-program`, which
# records its own pid and execs `nix-daemon`. With a test daemon running,
# that `nix-daemon --stdio` forwards to it, and killing it ends the
# connection all the same.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox.

source common.sh

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
wrapper="$TEST_ROOT/machine-daemon"
rm -rf "$cache" "$sync"
mkdir -p "$sync"
# The builder outlives its daemon; let it finish.
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; touch "$sync/release"; killDaemon' EXIT

# One line per connection opened, should there be more than one.
cat > "$wrapper" <<EOF
#!/bin/sh
echo \$\$ >> "$sync/machine-pids"
exec nix-daemon "\$@"
EOF
chmod +x "$wrapper"

# Bounded: 1200 polls of 0.1 s, two minutes.
# shellcheck disable=SC2016
timeout 300 nix-build --store "file://$cache" -j0 --no-out-link -vvv \
    --builders "ssh-ng://localhost?remote-program=$wrapper - - 1 1" -E '
  with import '"${config_nix}"';
  mkDerivation {
    name = "inprocess-machine-dies";
    buildCommand = "
      echo $$ > '"$sync"'/builder-pid
      i=0
      while [ ! -e '"$sync"'/release ]; do
        i=$((i + 1))
        if [ $i -ge 1200 ]; then exit 1; fi
        sleep 0.1
      done
      echo done > $out
    ";
  }
' 2> "$log" &
# The `timeout` process: it lives as long as the client and exits with
# its status.
client=$!

for _ in $(seq 120); do
    [[ -s $sync/builder-pid ]] && break
    sleep 1
done
[[ -s $sync/builder-pid ]] || fail "the remote build did not start"
[[ -s $sync/machine-pids ]] || fail "the machine's daemon was not started through the wrapper"

# The builder runs, so the client is waiting on the machine for the
# result. Take the machine away.
while read -r pid; do
    kill -KILL "$pid" 2> /dev/null || true
done < "$sync/machine-pids"

for _ in $(seq 60); do
    kill -0 "$client" 2> /dev/null || break
    sleep 1
done
if kill -0 "$client" 2> /dev/null; then
    kill -TERM "$client" || true
    fail "the client is still running a minute after the machine went away"
fi
status=0
wait "$client" || status=$?

# An ordinary failure: `MiscFailure` sets none of the special exit-status
# flags (build-result.cc, failingExitStatus), so 1; not an abort, a
# segfault or the `timeout`.
[[ $status -eq 1 ]] || fail "expected exit status 1, got $status"
grepQuietInverse "Nix crashed" "$log"

# The failure names the derivation, the machine and the cause.
grepQuiet "Cannot build '.*-inprocess-machine-dies.drv' on 'ssh-ng://localhost" "$log"
grepQuiet "Nix daemon disconnected unexpectedly" "$log"

# On the in-process path, and the coroutine finished.
grepQuiet "remote build done" "$log"
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "still in flight when the worker went away" "$log"
