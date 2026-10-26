#!/usr/bin/env bash

# An `ssh://` machine (the legacy protocol, served by `nix-store
# --serve`) is still built on from inside the process, but through the
# blocking path: only `ssh-ng` stores know how to suspend, so the worker
# warns that talking to this machine will hold up other builds, and then
# does so. The build itself succeeds and its output comes back.
#
# Known gap, not asserted here: `nix log` for a derivation built this
# way. The hook had the legacy store write the log to its descriptor 4;
# inside the worker that descriptor means nothing, so the `log-fd`
# parameter is dropped and the machine's log lines are not collected
# (remote-machine-build.cc, openMachineStore).
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox.

source common.sh

TODO_NixOS

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }' EXIT

# shellcheck disable=SC2016
outPath=$(nix-build --store "file://$cache" --builders "ssh://localhost - - 1 1" -j0 \
    --no-out-link -vv -E '
  with import '"${config_nix}"';
  mkDerivation { name = "inprocess-legacy-ssh"; buildCommand = "echo legacy > $out"; }
' 2> "$log")

# The result was copied back to the client's store.
nix path-info --store "file://$cache" "$outPath"

# Built on the machine by the in-process path, not by a hook
# (derivation-building-goal.cc, buildRemotely).
grepQuiet "building '.*-inprocess-legacy-ssh.drv' on 'ssh://localhost'" "$log"
grepQuiet "remote build done" "$log"
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "starting the built-in build hook" "$log"

# Through the blocking path, announced as such. This is printed each
# time the machine's store is opened, i.e. once per build on it
# (remote-machine-build.cc, openMachineStore).
grepQuiet "remote builder 'ssh://localhost' is not an ssh-ng store; talking to it will hold up other builds" "$log"
