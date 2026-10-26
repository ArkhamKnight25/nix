#!/usr/bin/env bash

# With the default `build-hook`, a remote build runs inside the building
# process: the worker picks the machine, talks to it over `ssh-ng` from a
# coroutine on its own event loop, and writes the build log itself. No
# hook process is started. This test builds one derivation on one
# `ssh-ng://localhost` machine and checks all of that from the outside.
#
# Setup as in build-remote.sh: the client's store and the machine's store
# are both local stores rooted under $TEST_ROOT. A store whose physical
# location differs from its store directory can only build in a chroot,
# which is why this needs sandbox support and busybox even though the
# `ssh-ng` connection itself does not. NIX_REMOTE is irrelevant: the
# client store is given with `--store`.

source common.sh

TODO_NixOS
requireSandboxSupport
requiresUnprivilegedUserNamespaces
[[ "${busybox-}" =~ busybox ]] || skipTest "no busybox"

# Avoid store dir being inside sandbox build-dir (see build-remote.sh).
unset NIX_STORE_DIR

chmod -R +w "$TEST_ROOT/machine"* 2> /dev/null || true
rm -rf "$TEST_ROOT/machine"*

log="$TEST_ROOT/log"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }' EXIT

# One builder script, one line of build output that `nix log` must
# reproduce. Busybox is the builder because it is the only program the
# chroot is guaranteed to contain.
expr='
  let system = (import '"${config_nix}"').system; in
  derivation {
    name = "build-remote-inprocess";
    inherit system;
    builder = "'"$busybox"'";
    args = [ "sh" "-e" "-c" "echo hi-inprocess; echo FOO > $out" ];
  }
'

machine="ssh-ng://localhost?remote-store=$TEST_ROOT/machine1"

# `-j0`: the build may not run locally, so it ran on the machine or not
# at all. `-vv` reaches the debug level, where both the hook's and the
# in-process path's trace lines are printed.
outPath=$(nix-build -E "$expr" --no-out-link -vv --max-jobs 0 \
  --store "$TEST_ROOT/machine0" \
  --builders "$machine - - 1 1" \
  2> "$log")

# Built remotely: the output is in the client's store and in the machine's.
grep FOO "$TEST_ROOT/machine0/$outPath"
nix path-info --store "$TEST_ROOT/machine1" "$outPath"

# The build was announced on the machine...
# (derivation-building-goal.cc, buildRemotely: `fmt(" on '%s'", machineName)`)
grepQuiet "building '.*' on 'ssh-ng://localhost" "$log"
# ...and finished on the in-process path
# (derivation-building-goal.cc, buildRemotely: `trace("remote build done")`).
grepQuiet "remote build done" "$log"
# It went over `ssh-ng`, not the blocking fallback for other store kinds
# (remote-machine-build.cc, openMachineStore).
grepQuietInverse "is not an ssh-ng store" "$log"

# No hook process was involved: neither the external program
# (hook-instance.cc, HookInstance::external) nor its half of the build
# (derivation-building-goal.cc, buildWithHook: `trace("hook build done")`),
# nor the program's own first words (build-remote.cc, serveBuildHook).
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "starting the built-in build hook" "$log"
grepQuietInverse "hook build done" "$log"
grepQuietInverse "got .* remote builders" "$log"
grepQuietInverse "build hook died unexpectedly" "$log"

# The machine's build output reached the local log file: `RemoteBuildLogger`
# turned the machine's `resBuildLogLine` results into the file `nix log`
# reads from the client store's log directory.
drvPath=$(nix-instantiate -E "$expr" --store "$TEST_ROOT/machine0")
nix log --store "$TEST_ROOT/machine0" "$drvPath" | grepQuiet hi-inprocess
