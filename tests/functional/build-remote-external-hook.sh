#!/usr/bin/env bash

source common.sh

# Nix's own build hook is a fork of the calling process. A `build-hook` the
# user configured is run as a separate program instead, which is the path
# third-party hooks take. Point the setting at Nix's own hook so the same
# scenario covers that path too.
echo "build-hook = $(type -p nix) __build-remote" >> "$test_nix_conf"

file=build-hook.nix

source build-remote.sh
