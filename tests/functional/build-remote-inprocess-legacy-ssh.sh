#!/usr/bin/env bash

# An `ssh://` machine (the legacy protocol, served by `nix-store
# --serve`) is not built on from inside the process. Only `ssh-ng`
# stores can suspend instead of blocking the worker, so for any other
# kind of machine the worker gives the selected slot back and starts the
# hook process (`nix __build-remote`), as upstream does
# (derivation-building-goal.cc, tryRemoteBuilder; remote-machine-build.cc,
# machineRunsInProcess). The build itself succeeds and its output comes
# back.
#
# `nix log` for a derivation built this way is not asserted here;
# build-remote.sh checks it for its `ssh://` machine.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox.

source common.sh

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# shellcheck disable=SC2016
outPath=$(timeout 300 nix-build --store "file://$cache" --builders "ssh://localhost - - 1 1" -j0 \
    --no-out-link -vvv -E '
  with import '"${config_nix}"';
  mkDerivation { name = "inprocess-legacy-ssh"; buildCommand = "echo legacy > $out"; }
' 2> "$log")

# The result was copied back to the client's store.
nix path-info --store "file://$cache" "$outPath"

# Built on the machine, by the hook process (hook-instance.cc,
# HookInstance::external), not by the in-process path
# (derivation-building-goal.cc, buildRemotely: `trace("remote build done")`).
# "building ... on" is printed by both.
grepQuiet "building '.*-inprocess-legacy-ssh.drv' on 'ssh://localhost'" "$log"
grepQuiet "starting build hook '" "$log"
grepQuietInverse "remote build done" "$log"

# Nor did the in-process path open the machine's store on its blocking
# fallback (remote-machine-build.cc, openMachineStore).
grepQuietInverse "is not an ssh-ng store" "$log"
