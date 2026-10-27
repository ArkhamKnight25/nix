#!/usr/bin/env bash

# `max-build-log-size` stops a remote build from inside the client. Two
# derivations go to one `ssh-ng` machine: a noisy one whose builder
# prints until it is stopped, and a held one whose builder waits for the
# test. Once the noisy build's lines pass the limit, the client cancels
# its coroutine (derivation-building-goal.cc, buildRemotely:
# `onLogLimitExceeded`), and the connection's teardown stops the
# machine's build. The noisy builder must die while the client is still
# running: the machine's daemon also stops a build when its client goes
# away (MonitorFdHup), so a builder that died only once the client had
# exited would prove nothing. The held build is not disturbed
# (`--keep-going`) and completes once released.
#
# The machine's daemon has no limit of its own: `SSHStore::setOptions`
# sends no settings, so `--max-build-log-size` stays with the client.
#
# Setup as in build-remote-inprocess-concurrent.sh: binary-cache client
# store, `-j0`, the test's own store as the machine, no sandbox, so the
# builders can use `sleep` and write to $TEST_ROOT.

source common.sh

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
rm -rf "$cache" "$sync"
mkdir -p "$sync"
# Let a held or stray builder finish whatever happens.
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; touch "$sync/release"; killDaemon' EXIT

# Each wait in a builder is bounded: 1200 polls of 0.1 s, two minutes.
# The noisy builder starts printing only once the held one is running,
# so that both remote builds are in flight together. (Quoted heredoc:
# `$out`, `$$` and `$i` are for the builder.)
cat > "$TEST_ROOT/log-limit.nix" <<'NIX'
{ configNix, sync }:
with import configNix;
let
  waitFor = file: ''
    i=0
    while [ ! -e ${file} ]; do
      i=$((i + 1))
      if [ $i -ge 1200 ]; then exit 1; fi
      sleep 0.1
    done
  '';
in
[
  (mkDerivation {
    name = "inprocess-log-limit-noisy";
    buildCommand = ''
      ${waitFor "${sync}/held-pid"}
      echo $$ > ${sync}/noisy-pid
      while true; do
        echo "noisy noisy noisy noisy noisy noisy noisy noisy noisy noisy noisy"
        sleep 0.01
      done
    '';
  })
  (mkDerivation {
    name = "inprocess-log-limit-held";
    buildCommand = ''
      echo $$ > ${sync}/held-pid
      ${waitFor "${sync}/release"}
      echo $out > ${sync}/held-out
      echo held > $out
    '';
  })
]
NIX

# Not `timeout 300` alone: the test watches the client while it runs.
# `$client` is the `timeout` process, which lives exactly as long as the
# client and exits with its status.
timeout 300 nix-build "$TEST_ROOT/log-limit.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" \
  --store "file://$cache" --builders "ssh-ng://localhost - - 2 1" -j0 \
  --keep-going --max-build-log-size 2000 \
  --no-out-link -vvv 2> "$log" &
client=$!

for _ in $(seq 120); do
    [[ -s $sync/held-pid && -s $sync/noisy-pid ]] && break
    sleep 1
done
[[ -s $sync/held-pid ]] || fail "the held build did not start"
[[ -s $sync/noisy-pid ]] || fail "the noisy build did not start"
held=$(< "$sync/held-pid")
noisy=$(< "$sync/noisy-pid")

# The noisy builder is stopped...
for _ in $(seq 60); do
    kill -0 "$noisy" 2> /dev/null || break
    sleep 1
done
if kill -0 "$noisy" 2> /dev/null; then
    kill -KILL "$noisy" || true
    fail "the noisy builder is still running a minute after it started"
fi
# ...while the client is still running, so the client stopped it, and
# without disturbing the other build.
kill -0 "$client" 2> /dev/null || fail "the client exited before the held build was released"
kill -0 "$held" 2> /dev/null || fail "the held builder died with the noisy one"

touch "$sync/release"

for _ in $(seq 120); do
    kill -0 "$client" 2> /dev/null || break
    sleep 1
done
kill -0 "$client" 2> /dev/null && fail "the client is still running two minutes after the release"
status=0
wait "$client" || status=$?

# One build failed with `LogLimitExceeded`, which sets none of the
# special exit-status flags (build-result.cc, updateFromStatus and
# failingExitStatus): exit status 1.
[[ $status -eq 1 ]] || fail "expected exit status 1, got $status"
grepQuietInverse "Nix crashed" "$log"
# derivation-building-goal.cc, logLimitExceeded: the goal's name, then the limit.
grepQuiet "building derivation '.*-inprocess-log-limit-noisy.drv' killed after writing more than 2000 bytes of log output" "$log"

# The held build completed and its output came back.
[[ -s $sync/held-out ]] || fail "the held build did not finish"
nix path-info --store "file://$cache" "$(< "$sync/held-out")"

# Both coroutines finished (the cancelled one too) before the worker
# went away (worker.cc, ~Worker), and no hook was involved.
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuietInverse "still in flight when the worker went away" "$log"
grepQuietInverse "starting build hook '" "$log"
