#!/usr/bin/env bash

# Interrupting the client stops a build the built-in hook is running on a
# remote machine, promptly. `build-hook-kill-timeout` is raised so that a
# hook ignoring SIGTERM would hold the client for a minute instead of
# being killed after half a second. Same setup as
# `build-hook-builtin-ssh.sh`.

source common.sh

TODO_NixOS
# Elsewhere the built-in hook runs `nix __build-remote` as a program.
[[ $(uname) =~ ^(Linux|Darwin|FreeBSD)$ ]] || skipTest "the built-in build hook does not fork on $(uname)"

started="$TEST_ROOT/started"

# shellcheck disable=SC2016
nix-build --store "file://$TEST_ROOT/cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
    --option build-hook-kill-timeout 60000 --no-out-link -vvv -E '
  with import '"${config_nix}"';
  mkDerivation {
    name = "slow";
    buildCommand = "echo $$ > '"$started"'; exec sleep 1000";
  }
' 2> "$TEST_ROOT/log" &
client=$!

for _ in $(seq 60); do
    [[ -s $started ]] && break
    sleep 1
done
[[ -s $started ]] || fail "the remote build did not start"
builder=$(< "$started")

# A background job ignores SIGINT; Nix treats SIGTERM the same way.
kill -TERM "$client"

for _ in $(seq 20); do
    kill -0 "$client" 2> /dev/null || break
    sleep 1
done
if kill -0 "$client" 2> /dev/null; then fail "the client is still running"; fi
wait "$client" || true

for _ in $(seq 20); do
    kill -0 "$builder" 2> /dev/null || break
    sleep 1
done
if kill -0 "$builder" 2> /dev/null; then fail "the remote build is still running"; fi

grepQuiet "starting the built-in build hook" "$TEST_ROOT/log"
grepQuiet "on 'ssh-ng://localhost'" "$TEST_ROOT/log"
