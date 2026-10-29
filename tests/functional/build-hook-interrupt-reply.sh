#!/usr/bin/env bash

# Stopping the client while a goal waits for the build hook's reply
# destroys the goal with its coroutine still suspended. That must end in
# an ordinary interrupt, not a crash, and the hook must be killed.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
requireDaemonIsThisVersion

hook="$TEST_ROOT/hook.sh"
pidFile="$TEST_ROOT/hook-pid"
rm -f "$pidFile"

# Never reply.
cat > "$hook" <<EOF
#!/bin/sh
echo \$\$ > "$pidFile"
exec sleep 1000
EOF
chmod +x "$hook"

echo "build-hook = $hook" >> "$test_nix_conf"
# The daemon reads `nix.conf` at startup. A no-op without one.
restartDaemon

# shellcheck disable=SC2016
nix-build --no-out-link -E '
  with import '"${config_nix}"';
  mkDerivation { name = "interrupt-reply"; buildCommand = "echo a > $out"; }
' 2> "$TEST_ROOT/log" &
client=$!

# Do not leave the client and the hook running if a check fails.
stop() {
    kill -KILL "$client" 2> /dev/null || true
    xargs kill -KILL < "$pidFile" 2> /dev/null || true
}
trap '[[ $? -eq 0 ]] || stop; killDaemon' EXIT

for _ in $(seq 60); do
    [[ -s $pidFile ]] && break
    sleep 0.5
done
[[ -s $pidFile ]] || { stop; fail "the hook did not start"; }
hookPid=$(< "$pidFile")

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
