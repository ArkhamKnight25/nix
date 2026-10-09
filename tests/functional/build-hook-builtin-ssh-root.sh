#!/usr/bin/env bash

# `build-hook-builtin-ssh.sh` as root. On Linux, Nix running as root
# enters a private mount namespace at startup, and every process it
# starts first returns to the parent one, through descriptors the forked
# hook has to keep open. No other functional test runs Nix as root.

source common.sh

TODO_NixOS
[[ $(uname) == Linux ]] || skipTest "mount namespaces are Linux-only"
if ! command -p -v unshare; then skipTest "Need unshare"; fi
# The hook runs in the client here; a daemon started outside the namespace
# cannot be stopped from inside it.
needLocalStore "the daemon would be stopped from inside the namespace"

# shellcheck disable=SC2119
execUnshare <<EOF
  source build-hook-builtin-ssh.sh
EOF
