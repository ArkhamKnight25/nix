#!/usr/bin/env bash

# Two remote builds from one worker proceed at the same time. Each
# builder writes a marker and then waits for the other's marker before
# it finishes; if the worker ran remote builds one after the other (or
# blocked on the first connection), neither marker would ever be seen
# and both builds would hit their bounded wait and fail.
#
# Setup as in the async-hook tests rather than build-remote.sh: the
# client's store is a binary cache, so with `-j0` every build must go
# remote, and the machine is `ssh-ng://localhost` with no `remote-store`,
# i.e. the test's own plain local store served by `nix-daemon --stdio`.
# Nothing is diverted, so no sandbox is needed and the builders can
# write to $TEST_ROOT directly (`sandbox = false` in the test nix.conf).
# One machine with two slots: two entries with the same URI would share
# their slot lock files (machine-selection.cc, openSlotLock).

source common.sh

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
rm -rf "$cache" "$sync"
mkdir -p "$sync"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Bounded: 1200 polls of 0.1 s, two minutes. `met` records what each
# builder saw. (Quoted heredoc: `$out` and `$i` are for the builder.)
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

# Both finished, and each saw the other while it was itself running.
[[ $(echo "$outPaths" | wc -l) -eq 2 ]]
for outPath in $outPaths; do
    nix path-info --store "file://$cache" "$outPath"
done
[[ -e "$sync/a" && -e "$sync/b" ]]
[[ $(grep -c '^ok$' "$sync/met") -eq 2 ]]
grepQuietInverse timeout "$sync/met"

# Both were sent to the machine by the in-process path
# (derivation-building-goal.cc, buildRemotely), not by a hook.
grepQuiet "building '.*-inprocess-concurrent-a.drv' on 'ssh-ng://localhost'" "$log"
grepQuiet "building '.*-inprocess-concurrent-b.drv' on 'ssh-ng://localhost'" "$log"
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "hook build done" "$log"
