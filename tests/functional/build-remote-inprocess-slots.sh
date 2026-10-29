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
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox, so the
# builders can use `sleep` and $TEST_ROOT.

source common.sh

# Fail on undefined behaviour in sanitizer builds.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache" "$TEST_ROOT/sync-"*
mkdir -p "$TEST_ROOT/sync-one" "$TEST_ROOT/sync-two/inflight" "$TEST_ROOT/sync-two/done"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# One slot, so no two builders run at once.

sync="$TEST_ROOT/sync-one"

# `mkdir` fails if another builder is in flight. `sleep 1` widens the window.
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

# Two slots, so at most two builders at once, and at some point two.

sync="$TEST_ROOT/sync-two"

# Each builder waits until another is in flight (`overlap`) or all three
# others are done (`alone`), so a worker that ran one remote build at a
# time would time out. `ls | wc -l` counts, as an empty glob would not.
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
