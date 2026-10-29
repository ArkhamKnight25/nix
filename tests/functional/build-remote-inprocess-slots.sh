#!/usr/bin/env bash

# A machine's `maxJobs` bounds the remote builds the worker runs on it,
# and the worker uses every slot it has.
#
# A slot is a lock file under the client store's `current-load`
# directory, one per machine URI and slot number, held (flock) from the
# selection until the coroutine returns (machine-selection.cc,
# acquireMachineSlot; remote-machine-build.cc, buildOnRemoteMachine).
# Two goals of one worker take two descriptors, so they exclude each
# other as two processes would. With every slot taken and no local
# builds allowed (`-j0`), the goal is postponed and asks again later
# (derivation-building-goal.cc, selectRemoteMachine).
#
# 1. One slot, three independent derivations: no two builders ever run
#    at the same time, and all three are built.
# 2. Two slots, four derivations: never more than two builders at once,
#    and at least two at once; each builder waits until it has company
#    or every other one has finished, so a worker that ran one remote
#    build at a time would leave the first builder waiting until its
#    bounded wait ran out.
# 3. One slot, two derivations, the first held until released: the
#    second is turned away (postponed) again and again while the first
#    runs, and starts only once it is done. A waiting goal asks again
#    only every `build-poll-interval` (5 s by default), so case 1 would
#    not notice a slot given back before its build ends; here the
#    interval is 1 s and the first build runs until the test has seen
#    the second turned away twice.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox, so the
# builders can use `sleep` and $TEST_ROOT.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache" "$TEST_ROOT/sync-"*
mkdir -p "$TEST_ROOT/sync-one" "$TEST_ROOT/sync-two/inflight" "$TEST_ROOT/sync-two/done" "$TEST_ROOT/sync-three"
client=
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; touch "$TEST_ROOT/sync-three/release"; [[ -n $client ]] && kill -KILL -- -"$client" 2> /dev/null; killDaemon' EXIT

# --- 1. one slot ------------------------------------------------------

sync="$TEST_ROOT/sync-one"

# `mkdir` either creates the directory or fails because another builder
# holds it; `sleep 1` widens the window. (Quoted heredoc: `$out` is for
# the builder.)
cat > "$TEST_ROOT/slots-one.nix" <<'NIX'
{ configNix, sync }:
with import configNix;
map (k: mkDerivation {
  name = "inprocess-slots-one-${k}";
  buildCommand = ''
    mkdir ${sync}/inflight 2> /dev/null || echo "overlap ${k}" >> ${sync}/bad
    sleep 1
    rmdir ${sync}/inflight 2> /dev/null || echo "overlap ${k}" >> ${sync}/bad
    echo ${k} > $out
  '';
}) [ "a" "b" "c" ]
NIX

outPaths=$(timeout 200 nix-build "$TEST_ROOT/slots-one.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" \
  --store "file://$cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
  --no-out-link -vvv 2> "$log")

[[ $(echo "$outPaths" | wc -l) -eq 3 ]]
for outPath in $outPaths; do
    nix path-info --store "file://$cache" "$outPath"
done
[[ ! -e $sync/bad ]] || fail "builders overlapped on a one-slot machine: $(< "$sync/bad")"
[[ $(grep -c "remote build done" "$log") -eq 3 ]]
grepQuietInverse "starting build hook '" "$log"

# --- 2. two slots -----------------------------------------------------

sync="$TEST_ROOT/sync-two"

# A builder is in flight while its file is in `inflight`. It counts
# those once it is there itself; then it waits, bounded at 600 polls of
# 0.1 s (one minute), until it sees another in flight (`overlap`) or
# all three others done (`alone`, the last one may be). `ls | wc -l`
# counts, as an empty glob would not. (Quoted heredoc: `$out`, `$i` and
# `$n` are for the builder.)
cat > "$TEST_ROOT/slots-two.nix" <<'NIX'
{ configNix, sync }:
with import configNix;
map (k: mkDerivation {
  name = "inprocess-slots-two-${k}";
  buildCommand = ''
    touch ${sync}/inflight/${k}
    n=$(ls ${sync}/inflight | wc -l)
    if [ $n -gt 2 ]; then echo "${k} saw $n in flight" >> ${sync}/bad; fi
    i=0
    while true; do
      if [ $(ls ${sync}/inflight | wc -l) -ge 2 ]; then echo overlap >> ${sync}/met; break; fi
      if [ $(ls ${sync}/done | wc -l) -ge 3 ]; then echo alone >> ${sync}/met; break; fi
      i=$((i + 1))
      if [ $i -ge 600 ]; then echo "${k} timed out" >> ${sync}/bad; exit 1; fi
      sleep 0.1
    done
    rm ${sync}/inflight/${k}
    touch ${sync}/done/${k}
    echo ${k} > $out
  '';
}) [ "a" "b" "c" "d" ]
NIX

outPaths=$(timeout 200 nix-build "$TEST_ROOT/slots-two.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" \
  --store "file://$cache" --builders "ssh-ng://localhost - - 2 1" -j0 \
  --no-out-link -vvv 2> "$log")

[[ $(echo "$outPaths" | wc -l) -eq 4 ]]
for outPath in $outPaths; do
    nix path-info --store "file://$cache" "$outPath"
done
[[ ! -e $sync/bad ]] || fail "$(< "$sync/bad")"
[[ $(wc -l < "$sync/met") -eq 4 ]]
# The first two selected start together and the first of them to look
# finds the other still in flight.
[[ $(grep -c '^overlap$' "$sync/met") -ge 1 ]] || fail "no two builders ran at once on a two-slot machine"
[[ $(grep -c "remote build done" "$log") -eq 4 ]]
grepQuietInverse "starting build hook '" "$log"

# --- 3. a slot stays taken while its build runs -----------------------

sync="$TEST_ROOT/sync-three"

# Each builder says it started, then waits for `release`, bounded at
# 1200 polls of 0.1 s (two minutes). (Quoted heredoc: `$out` and `$i`
# are for the builder.)
cat > "$TEST_ROOT/slots-three.nix" <<'NIX'
{ configNix, sync }:
with import configNix;
map (k: mkDerivation {
  name = "inprocess-slots-three-${k}";
  buildCommand = ''
    touch ${sync}/started-${k}
    i=0
    while [ ! -e ${sync}/release ]; do
      i=$((i + 1))
      if [ $i -ge 1200 ]; then exit 1; fi
      sleep 0.1
    done
    echo ${k} > $out
  '';
}) [ "a" "b" ]
NIX

timeout 200 nix-build "$TEST_ROOT/slots-three.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" \
  --store "file://$cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
  --option build-poll-interval 1 --no-out-link -vvv 2> "$log" &
client=$!

for _ in $(seq 120); do
    [[ -e $sync/started-a || -e $sync/started-b ]] && break
    sleep 1
done
if [[ -e $sync/started-a ]]; then
    other=b
elif [[ -e $sync/started-b ]]; then
    other=a
else
    fail "neither build started"
fi

# Each time the waiting goal is turned away it waits for a while
# (worker.cc, waitForAWhile, traced at `-vvv`).
turnedAway() {
    grep -c "building derivation '.*-inprocess-slots-three-$other.drv': wait for a while" "$log" || true
}
before=$(turnedAway)
for _ in $(seq 120); do
    [[ -e $sync/started-$other ]] && break
    (( $(turnedAway) >= before + 2 )) && break
    sleep 0.5
done
[[ ! -e $sync/started-$other ]] || fail "the second build started on a one-slot machine while the first was running"
(( $(turnedAway) >= before + 2 )) || fail "the waiting build was never turned away again"

touch "$sync/release"
status=0
wait "$client" || status=$?
client=
[[ $status -eq 0 ]] || fail "nix-build failed with status $status"
[[ -e $sync/started-$other ]]
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuietInverse "starting build hook '" "$log"
