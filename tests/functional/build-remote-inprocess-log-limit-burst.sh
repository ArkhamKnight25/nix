#!/usr/bin/env bash

# `max-build-log-size` on an in-process remote build when the log
# arrives in one burst: many lines already read when the limit is
# crossed, and more waiting in the pipe.
#
# The client is stopped (SIGSTOP) while the builder prints as fast as it
# can, until the pipes fill and the builder blocks; then it is resumed.
# Its next read takes a whole buffer of log lines at once, and the limit
# is crossed part-way through it. The lines after the limit must not be
# shown (RemoteBuildLogger drops them), and the cancellation posted when
# the limit is crossed must stop the build although the next read has
# already completed by then (`throw_if_cancelled` in
# buildOnRemoteMachine): the noisy builder must die.
#
# Each line is 66 bytes with its newline; 30 fit in 2000 bytes and the
# 31st crosses the limit.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
rm -rf "$cache" "$sync"
mkdir -p "$sync"
client=
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; [[ -n $client ]] && { kill -CONT "$client"; kill -KILL "$client"; } 2> /dev/null; [[ -s $sync/noisy-pid ]] && kill -KILL "$(< "$sync/noisy-pid")" 2> /dev/null; killDaemon' EXIT

# The builder waits for `go`, bounded at 1200 polls of 0.1 s, then
# prints without end. (Quoted heredoc: `$$`, `$i` and `$out` are for the
# builder.)
cat > "$TEST_ROOT/burst.nix" <<'NIX'
{ configNix, sync }:
with import configNix;
mkDerivation {
  name = "inprocess-log-limit-burst";
  buildCommand = ''
    echo $$ > ${sync}/noisy-pid
    i=0
    while [ ! -e ${sync}/go ]; do
      i=$((i + 1))
      if [ $i -ge 1200 ]; then exit 1; fi
      sleep 0.1
    done
    i=0
    while true; do
      echo "noisy noisy noisy noisy noisy noisy noisy noisy noisy noisy noisy"
      i=$((i + 1))
      echo $i > ${sync}/count
    done
  '';
}
NIX

nix-build "$TEST_ROOT/burst.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" \
  --store "file://$cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
  --max-build-log-size 2000 --no-out-link -vvv 2> "$log" &
client=$!

for _ in $(seq 120); do
    [[ -s $sync/noisy-pid ]] && break
    sleep 1
done
[[ -s $sync/noisy-pid ]] || fail "the build did not start"
noisy=$(< "$sync/noisy-pid")

# A stopped client reads nothing: the machine's daemon blocks writing to
# it, and the builder behind the daemon. Wait until its count stops.
kill -STOP "$client"
touch "$sync/go"
prev=
cur=
for _ in $(seq 60); do
    sleep 2
    cur=$(cat "$sync/count" 2> /dev/null || true)
    [[ -n $cur && $cur == "$prev" ]] && break
    prev=$cur
done
[[ -n $cur && $cur == "$prev" ]] || fail "the builder never blocked"
kill -CONT "$client"

for _ in $(seq 60); do
    kill -0 "$noisy" 2> /dev/null || break
    sleep 1
done
kill -0 "$noisy" 2> /dev/null && fail "the noisy builder is still running a minute after the client resumed"

for _ in $(seq 60); do
    kill -0 "$client" 2> /dev/null || break
    sleep 1
done
status=0
wait "$client" || status=$?
client=
[[ $status -eq 1 ]] || fail "expected exit status 1, got $status"
grepQuiet "killed after writing more than 2000 bytes of log output" "$log"

# Up to the limit and no further: a burst of hundreds of lines would get
# through if the lines after the limit were not dropped.
n=$(grep -c '^noisy noisy' "$log" || true)
(( n >= 1 && n <= 40 )) || fail "expected the lines up to the limit (31), got $n"

grepQuietInverse "still in flight when the worker went away" "$log"
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "Nix crashed" "$log"
