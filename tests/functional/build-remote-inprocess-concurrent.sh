#!/usr/bin/env bash

# Two remote builds from one worker run at the same time. Each builder
# waits for the other to start, so both time out unless they overlap.
# Binary-cache client store and `-j0`, so nothing builds locally. One
# machine with two slots, since two entries with one URI share slot locks.

source common.sh

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
rm -rf "$cache" "$sync"
mkdir -p "$sync"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

cat > "$TEST_ROOT/concurrent.nix" <<'NIX'
{ configNix, sync }:
with import configNix;
let
  meet = me: other: ''
    echo started > ${sync}/${me}
    i=0
    while [ ! -e ${sync}/${other} ]; do
      i=$((i + 1))
      if [ $i -ge 1200 ]; then echo timeout >> ${sync}/met; exit 1; fi
      sleep 0.1
    done
    echo ok >> ${sync}/met
    echo ${me} > $out
  '';
in
[
  (mkDerivation { name = "inprocess-concurrent-a"; buildCommand = meet "a" "b"; })
  (mkDerivation { name = "inprocess-concurrent-b"; buildCommand = meet "b" "a"; })
]
NIX

outPaths=$(timeout 200 nix-build "$TEST_ROOT/concurrent.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" \
  --store "file://$cache" --builders "ssh-ng://localhost - - 2 1" -j0 \
  --no-out-link -vvv 2> "$log")

# Both finished, and each saw the other running.
[[ $(echo "$outPaths" | wc -l) -eq 2 ]]
for outPath in $outPaths; do
    nix path-info --store "file://$cache" "$outPath"
done
[[ -e "$sync/a" && -e "$sync/b" ]]
[[ $(grep -c '^ok$' "$sync/met") -eq 2 ]]
grepQuietInverse timeout "$sync/met"

# Both went to the machine in-process, not through a hook.
grepQuiet "building '.*-inprocess-concurrent-a.drv' on 'ssh-ng://localhost'" "$log"
grepQuiet "building '.*-inprocess-concurrent-b.drv' on 'ssh-ng://localhost'" "$log"
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "hook build done" "$log"
