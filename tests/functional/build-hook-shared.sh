#!/usr/bin/env bash

# Goals that want the build hook at the same time take turns with one
# hook instead of each starting their own.

source common.sh

# Older daemons start a hook per ready goal, or log hook starts
# differently.
requireDaemonIsThisVersion
TODO_NixOS

clearStore

# With `build-hook` at its default there is no hook process to count, so
# configure `nix __build-remote`, the same logic as a program.
echo "build-hook = $(type -P nix) __build-remote" >> "$test_nix_conf"
# Let the daemon, if there is one, read the new `nix.conf`.
restartDaemon

# The machine matches no derivation, so the hook declines each one and is
# kept for the next. `-vvv` logs each hook start.
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
