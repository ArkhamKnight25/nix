#!/usr/bin/env bash

# Sixteen remote builds from one worker, all in flight at once. Each
# builder leaves a marker and then waits until all sixteen markers are
# there, so no builder can finish before every one has started: sixteen
# coroutines, sixteen connections and sixteen builds on the machine at
# the same time. A worker that could not keep that many going would
# leave some builders waiting until their bounded wait ran out, and the
# build would fail.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox. One
# machine with sixteen slots.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

n=16
cache="$TEST_ROOT/cache"
sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
rm -rf "$cache" "$sync"
mkdir -p "$sync"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Bounded: 1800 polls of 0.1 s, three minutes, which leaves room for the
# connections being set up one upload lock at a time. Shell globbing only
# counts the markers. `met` records what each builder saw. (Quoted
# heredoc: `$out`, `$i` and `$#` are for the builder.)
cat > "$TEST_ROOT/many.nix" <<'NIX'
{ configNix, sync, n }:
with import configNix;
builtins.genList (k: mkDerivation {
  name = "inprocess-many-${toString k}";
  buildCommand = ''
    echo started > ${sync}/marker-${toString k}
    i=0
    while true; do
      set -- ${sync}/marker-*
      if [ $# -ge ${toString n} ]; then break; fi
      i=$((i + 1))
      if [ $i -ge 1800 ]; then echo timeout >> ${sync}/met; exit 1; fi
      sleep 0.1
    done
    echo ok >> ${sync}/met
    echo ${toString k} > $out
  '';
}) n
NIX

outPaths=$(timeout 200 nix-build "$TEST_ROOT/many.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" --arg n "$n" \
  --store "file://$cache" --builders "ssh-ng://localhost - - $n 1" -j0 \
  --no-out-link -vvv 2> "$log")

# All finished, and each saw all the others started while it was itself
# still running.
[[ $(echo "$outPaths" | wc -l) -eq $n ]]
for outPath in $outPaths; do
    nix path-info --store "file://$cache" "$outPath"
done
[[ $(grep -c '^ok$' "$sync/met") -eq $n ]]
grepQuietInverse timeout "$sync/met"

# All on the in-process path.
[[ $(grep -c "remote build done" "$log") -eq $n ]]
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "still in flight when the worker went away" "$log"
