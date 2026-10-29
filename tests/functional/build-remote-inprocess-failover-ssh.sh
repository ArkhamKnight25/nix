#!/usr/bin/env bash

# Failing over from an `ssh-ng` machine to an `ssh://` one, and the log
# limit on the `ssh://` machine's hook.
#
# 1. Two machines: an `ssh-ng` one that cannot be started (its
#    `remote-program` does not exist; preferred, with the higher speed
#    factor, machine-selection.cc, machineIsBetter) and an `ssh://` one.
#    The in-process coroutine fails to connect, disables the `ssh-ng`
#    machine, selects the next, finds it is not one it builds on, and
#    hands the build back (remote-machine-build.cc, buildOnRemoteMachine).
#    The goal asks again at once and sends the `ssh://` machine to the
#    hook process (derivation-building-goal.cc, tryRemoteBuilder). The
#    hook parses the machine list itself (build-remote.cc,
#    serveBuildHook), so it also tries the `ssh-ng` machine first and
#    reports it in the same words before it moves on: the message
#    appears twice, once from each. A coroutine that tried the `ssh://`
#    machine itself would open it on the blocking fallback
#    (remote-machine-build.cc, openMachineStore) and say so.
# 2. `--max-build-log-size` on an `ssh://` machine, which only the hook
#    builds on. The hook's parent counts what arrives on the hook's log
#    descriptor and kills the hook past the limit (buildWithHook); the
#    legacy protocol also passes the limit to the machine, whose own
#    build stops there (legacy-ssh-store.cc, buildSettings; nix-store
#    --serve). Whichever comes first, the client reports the limit in
#    the words of derivation-building-goal.cc, logLimitExceeded, and
#    exits with 1 (the hook's failure is a `MiscFailure`, the limit a
#    `LogLimitExceeded`; neither sets an exit-status flag, build-result.cc).
#    The noisy builder stops on its own well past the limit, so a limit
#    that was not enforced would show as a successful build.
#
# Setup as in build-remote-inprocess-legacy-ssh.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox.

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
