#!/usr/bin/env bash

# A `build-hook` naming `nix __build-remote` by path runs that program,
# not the fork, and it still accepts and builds. Only the default value
# selects the fork. Same setup as `build-hook-builtin-ssh.sh`.

source common.sh

TODO_NixOS

cache="$TEST_ROOT/cache"

outPath=$(nix-build --store "file://$cache" --builders "ssh-ng://localhost - - 1 1" -j0 \
    --option build-hook "$(type -P nix) __build-remote" \
    dependencies.nix --no-out-link -vvv 2> "$TEST_ROOT/log")

nix path-info --store "file://$cache" "$outPath"

grepQuiet "starting build hook '" "$TEST_ROOT/log"
grepQuietInverse "starting the built-in build hook" "$TEST_ROOT/log"
grepQuiet "on 'ssh-ng://localhost'" "$TEST_ROOT/log"
grepQuietInverse "build hook died unexpectedly" "$TEST_ROOT/log"
