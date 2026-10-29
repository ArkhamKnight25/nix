#!/usr/bin/env bash

# Two remote builds on an `ssh://` machine proceed at the same time
# through the hook process. The worker awaits the hook's reply without
# blocking, and once a hook has accepted a build it belongs to that goal:
# the next goal starts a hook of its own instead of waiting for the
# first build to finish. Same rendezvous as build-remote-inprocess-
# concurrent.sh: each builder waits for the other's marker, so the two
# builds can only finish if they overlap.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
rm -rf "$cache" "$sync"
mkdir -p "$sync"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Bounded: 1200 polls of 0.1 s, two minutes. (Quoted heredoc: `$out` and
# `$i` are for the builder.)
cat > "$TEST_ROOT/hook-concurrent.nix" <<'NIX'
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
  (mkDerivation { name = "hook-concurrent-a"; buildCommand = meet "a" "b"; })
  (mkDerivation { name = "hook-concurrent-b"; buildCommand = meet "b" "a"; })
]
NIX

outPaths=$(timeout 200 nix-build "$TEST_ROOT/hook-concurrent.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" \
  --store "file://$cache" --builders "ssh://localhost - - 2 1" -j0 \
  --no-out-link -vvv 2> "$log")

# Both finished, and each saw the other while it was itself running.
[[ $(echo "$outPaths" | wc -l) -eq 2 ]]
for outPath in $outPaths; do
    nix path-info --store "file://$cache" "$outPath"
done
[[ -e "$sync/a" && -e "$sync/b" ]]
[[ $(grep -c '^ok$' "$sync/met") -eq 2 ]]
grepQuietInverse timeout "$sync/met"

# Both went through the hook process (one hook per accepted build), and
# neither through the in-process path.
grepQuiet "building '.*-hook-concurrent-a.drv' on 'ssh://localhost'" "$log"
grepQuiet "building '.*-hook-concurrent-b.drv' on 'ssh://localhost'" "$log"
[[ $(grep -c "starting build hook '" "$log") -eq 2 ]]
[[ $(grep -c "hook build done" "$log") -eq 2 ]]
grepQuietInverse "remote build done" "$log"
