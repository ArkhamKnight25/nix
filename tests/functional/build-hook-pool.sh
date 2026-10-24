#!/usr/bin/env bash

# At most `max-build-hooks` build hooks run at once, and a hook that
# declined is kept for the next goal instead of a new one being started.

source common.sh

# Older daemons log hook starts differently.
requireDaemonNewerThan "2.36pre"
TODO_NixOS

echo "max-build-hooks = 2" >> "$test_nix_conf"
# The daemon reads `nix.conf` at startup. A no-op without one.
restartDaemon

clearStore

# The machine matches nothing, so the hooks decline every derivation and
# are kept for the next ones. `-vvv` logs each hook start.
# shellcheck disable=SC2016
nix-build --max-jobs 6 --no-out-link -vvv \
    --builders "$TEST_ROOT/nosuchstore nosuchsystem - 1 1" -E '
  with import '"${config_nix}"';
  map (n: mkDerivation {
    name = "pool-hook-${toString n}";
    buildCommand = "echo > $out";
  }) [ 1 2 3 4 5 6 ]
' 2> "$TEST_ROOT/log"

starts=$(grep -c -E "starting (the built-in )?build hook" "$TEST_ROOT/log")
[[ $starts -eq 2 ]] || fail "expected two hook starts, got $starts"
