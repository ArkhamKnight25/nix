#!/usr/bin/env bash

# While the only builder slot is taken, the other goals get `postpone`
# and retry every `build-poll-interval`. The retries reuse the waiting
# hook instead of starting new ones: besides the hook each accepted
# build takes along, at most one more is ever started.

source common.sh

# Older daemons log hook starts differently.
requireDaemonNewerThan "2.36pre"
TODO_NixOS
# Elsewhere the built-in hook runs `nix __build-remote` as a program.
[[ $(uname) =~ ^(Linux|Darwin|FreeBSD)$ ]] || skipTest "the built-in build hook does not fork on $(uname)"

echo "build-poll-interval = 1" >> "$test_nix_conf"
# The daemon reads `nix.conf` at startup. A no-op without one.
restartDaemon

clearStore
cache="$TEST_ROOT/cache"
rm -rf "$cache"

# One builder slot and `-j0`: the derivations build remotely one at a
# time, and each build takes long enough for the others to retry.
# shellcheck disable=SC2016
nix-build --store "file://$cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
    --no-out-link -vvv -E '
  with import '"${config_nix}"';
  map (n: mkDerivation {
    name = "postpone-${toString n}";
    buildCommand = "sleep 2; echo ${toString n} > $out";
  }) [ 1 2 3 4 5 ]
' 2> "$TEST_ROOT/log"

accepts=$(grep -c "hook reply is 'accept'" "$TEST_ROOT/log")
postpones=$(grep -c "hook reply is 'postpone'" "$TEST_ROOT/log")
starts=$(grep -c "starting the built-in build hook" "$TEST_ROOT/log")
echo "accepts=$accepts postpones=$postpones starts=$starts"

(( accepts == 5 )) || fail "expected 5 remote builds, got $accepts"
(( postpones >= 8 )) || fail "expected the goals to be postponed repeatedly, got $postpones"
(( starts <= accepts + 1 )) || fail "started $starts hooks for $accepts builds"
