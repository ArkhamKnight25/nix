#!/usr/bin/env bash

# Stopping the client while one goal waits for the build hook's reply
# and another waits for its turn at the hook ends in an ordinary
# interrupt, and the hook is killed.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
requireDaemonIsThisVersion

hook="$TEST_ROOT/hook.sh"
pids="$TEST_ROOT/hook-pids"
rm -f "$pids"

# Never reply.
cat > "$hook" <<EOF
#!/bin/sh
echo \$\$ >> "$pids"
exec sleep 1000
EOF
chmod +x "$hook"

echo "build-hook = $hook" >> "$test_nix_conf"
# The daemon reads `nix.conf` at startup. A no-op without one.
restartDaemon

# shellcheck disable=SC2016
nix-build --no-out-link -E '
  with import '"${config_nix}"';
  [
    (mkDerivation { name = "queued-a"; buildCommand = "echo a > $out"; })
    (mkDerivation { name = "queued-b"; buildCommand = "echo b > $out"; })
  ]
' 2> "$TEST_ROOT/log" &
client=$!

# Do not leave the client and the hooks running if a check fails.
stop() {
    kill -KILL "$client" 2> /dev/null || true
    xargs kill -KILL < "$pids" 2> /dev/null || true
}
trap '[[ $? -eq 0 ]] || stop; killDaemon' EXIT

for _ in $(seq 60); do
    [[ -s $pids ]] && break
    sleep 0.5
done
[[ -s $pids ]] || { stop; fail "the hook did not start"; }
# Long enough for the second goal to start a hook, were it going to.
sleep 2
[[ $(wc -l < "$pids") -eq 1 ]] || { stop; fail "the second goal did not wait for the hook"; }
hookPid=$(< "$pids")

# A background job ignores SIGINT; Nix treats SIGTERM the same way.
kill -TERM "$client"

for _ in $(seq 20); do
    kill -0 "$client" 2> /dev/null || break
    sleep 1
done
if kill -0 "$client" 2> /dev/null; then stop; fail "the client is still running"; fi
status=0
wait "$client" || status=$?

# An orderly, non-zero exit: not killed by any signal (134 is SIGABRT, 139 a segfault).
(( status != 0 && status < 128 )) || fail "the client ended with status $status: $(< "$TEST_ROOT/log")"
grepQuietInverse "Nix crashed" "$TEST_ROOT/log"

for _ in $(seq 20); do
    kill -0 "$hookPid" 2> /dev/null || break
    sleep 1
done
if kill -0 "$hookPid" 2> /dev/null; then stop; fail "the hook is still running"; fi
