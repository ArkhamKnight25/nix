#!/usr/bin/env bash

# An `ssh://` machine builds through the hook: only `ssh-ng` stores can suspend.

source common.sh

TODO_NixOS
requireDaemonNewerThan "2.36pre"

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# shellcheck disable=SC2016
outPath=$(timeout 200 nix-build --store "file://$cache" --builders "ssh://localhost - - 1 1" -j0 \
    --no-out-link -vvv -E '
  with import '"${config_nix}"';
  mkDerivation { name = "inprocess-legacy-ssh"; buildCommand = "echo legacy > $out"; }
' 2> "$log")

nix path-info --store "file://$cache" "$outPath"

# Both paths print the "building ... on" line.
grepQuiet "building '.*-inprocess-legacy-ssh.drv' on 'ssh://localhost'" "$log"
grepQuiet "starting build hook '" "$log"
grepQuietInverse "remote build done" "$log"
