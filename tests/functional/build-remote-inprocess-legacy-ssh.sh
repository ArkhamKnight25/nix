#!/usr/bin/env bash

# An `ssh://` machine builds through the hook process, not in-process,
# because only `ssh-ng` stores can suspend instead of blocking the worker.
# Binary-cache client store and `-j0`, so nothing builds locally.

source common.sh

# Fail on undefined behaviour in sanitizer builds.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

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

# The result was copied back to the client's store.
nix path-info --store "file://$cache" "$outPath"

# Built on the machine by the hook, not in-process. Both paths print the
# "building ... on" line.
grepQuiet "building '.*-inprocess-legacy-ssh.drv' on 'ssh://localhost'" "$log"
grepQuiet "starting build hook '" "$log"
grepQuietInverse "remote build done" "$log"
