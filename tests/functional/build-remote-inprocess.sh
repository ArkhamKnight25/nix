#!/usr/bin/env bash

# With the default `build-hook`, a remote build on an `ssh-ng://localhost`
# machine runs inside the building process. No hook process starts, and
# the worker writes the build log itself.
# Stores as in build-remote.sh, so this needs sandbox support and busybox.

source common.sh

# Fail on undefined behaviour in sanitizer builds.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion
requireSandboxSupport
requiresUnprivilegedUserNamespaces
[[ "${busybox-}" =~ busybox ]] || skipTest "no busybox"

# Avoid store dir being inside sandbox build-dir.
unset NIX_STORE_DIR

chmod -R +w "$TEST_ROOT/machine"* 2> /dev/null || true
rm -rf "$TEST_ROOT/machine"*

log="$TEST_ROOT/log"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Busybox is the only program the chroot is sure to contain.
# shellcheck disable=SC2016
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

# `-j0` so that the build cannot run locally. `-vvv` prints the traces
# checked below.
outPath=$(timeout 200 nix-build -E "$expr" --no-out-link -vvv --max-jobs 0 \
  --store "$TEST_ROOT/machine0" \
  --builders "$machine - - 1 1" \
  2> "$log")

# The output is in both the client's store and the machine's.
grep FOO "$TEST_ROOT/machine0/$outPath"
nix path-info --store "$TEST_ROOT/machine1" "$outPath"

# Built on the machine by the in-process path...
grepQuiet "building '.*' on 'ssh-ng://localhost" "$log"
grepQuiet "remote build done" "$log"

# ...and not through a hook.
grepQuietInverse "starting build hook '" "$log"
grepQuietInverse "hook build done" "$log"
grepQuietInverse "got .* remote builders" "$log"
grepQuietInverse "build hook died unexpectedly" "$log"

# The worker wrote the machine's build output to the client's log.
drvPath=$(nix-instantiate -E "$expr" --store "$TEST_ROOT/machine0")
nix log --store "$TEST_ROOT/machine0" "$drvPath" | grepQuiet hi-inprocess
