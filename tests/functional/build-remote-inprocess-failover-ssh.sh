#!/usr/bin/env bash

# An unreachable `ssh-ng` machine fails over to an `ssh://` one, which the
# build hook builds on, and `--max-build-log-size` holds for that hook.
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

# The `ssh-ng` machine is unreachable, and the `ssh://` one takes the build.

# Separate URIs, so separate slot locks.
unreachable="ssh-ng://localhost?remote-program=$TEST_ROOT/no-such-program - - 1 2"
legacy="ssh://localhost - - 1 1"

# shellcheck disable=SC2016
outPath=$(timeout 200 nix-build --store "file://$cache" -j0 --no-out-link -vvv \
  --builders "$unreachable ; $legacy" -E '
  with import '"${config_nix}"';
  mkDerivation { name = "inprocess-failover-ssh"; buildCommand = "echo failover-ssh-was-here; echo f > $out"; }
' 2> "$log")

nix path-info --store "file://$cache" "$outPath"

# Reported by the coroutine, then by the hook, which parses the machine
# list itself and tries the `ssh-ng` machine first.
[[ $(grep -c "cannot build on 'ssh-ng://localhost.*no-such-program" "$log") -eq 2 ]]
# One coroutine, which hands the `ssh://` machine to the hook rather than
# trying it itself.
[[ $(grep -c "inprocess-failover-ssh.drv': remote build done" "$log") -eq 1 ]]
grepQuiet "starting build hook '" "$log"
grepQuiet "building '.*-inprocess-failover-ssh.drv' on 'ssh://localhost'" "$log"
grepQuietInverse "is not an ssh-ng store" "$log"
grepQuietInverse "still in flight when the worker went away" "$log"
grepQuietInverse "Nix crashed" "$log"

# The log limit on the `ssh://` machine, which only the hook builds on.

# Some 12 kB of output against a limit of 100 bytes. Neither a hook
# failure nor a log limit sets an exit-status flag, so the status is 1.
status=0
# shellcheck disable=SC2016
timeout 200 nix-build --store "file://$cache" -j0 --no-out-link -vvv \
  --builders "$legacy" --max-build-log-size 100 -E '
  with import '"${config_nix}"';
  mkDerivation {
    name = "inprocess-failover-ssh-noisy";
    buildCommand = "for i in $(seq 200); do echo noisy noisy noisy noisy noisy noisy noisy noisy noisy noisy; done; echo n > $out";
  }
' 2> "$log" || status=$?

[[ $status -eq 1 ]] || fail "expected exit status 1, got $status"
grepQuiet "killed after writing more than 100 bytes of log output" "$log"
grepQuiet "starting build hook '" "$log"
grepQuietInverse "remote build done" "$log"
grepQuietInverse "Nix crashed" "$log"
