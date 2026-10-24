#!/usr/bin/env bash

# Goals that want the build hook at the same time take turns with one
# hook instead of each starting their own.

source common.sh

# Older daemons log hook starts differently.
requireDaemonNewerThan "2.36pre"
TODO_NixOS

clearStore

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

starts=$(grep -c -E "starting (the built-in )?build hook" "$TEST_ROOT/log")
[[ $starts -eq 1 ]] || fail "expected one hook start, got $starts"
