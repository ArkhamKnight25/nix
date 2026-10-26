#!/usr/bin/env bash

# Goals that want the build hook at the same time take turns with one
# hook instead of each starting their own.

source common.sh

# Older daemons start a hook per ready goal, or log hook starts
# differently.
requireDaemonNewerThan "2.36.0pre20261026"
TODO_NixOS

clearStore

# Only a configured `build-hook` runs as a program; with the setting at
# its default the worker picks machines itself and there is no hook
# process to count. `nix __build-remote` is that same logic as a
# program.
echo "build-hook = $(type -P nix) __build-remote" >> "$test_nix_conf"
# The daemon reads `nix.conf` at startup. A no-op without one.
restartDaemon

# The machine matches nothing, so the hook declines every derivation and
# is kept for the next one. `-vvv` logs each hook start.
# shellcheck disable=SC2016
nix-build --max-jobs 6 --no-out-link -vvv \
    --builders "$TEST_ROOT/nosuchstore nosuchsystem - 1 1" -E '
  with import '"${config_nix}"';
  map (n: mkDerivation {
    name = "shared-hook-${toString n}";
    buildCommand = "echo > $out";
  }) [ 1 2 3 4 5 6 ]
' 2> "$TEST_ROOT/log"

starts=$(grep -c "starting build hook '" "$TEST_ROOT/log")
[[ $starts -eq 1 ]] || fail "expected one hook start, got $starts"
