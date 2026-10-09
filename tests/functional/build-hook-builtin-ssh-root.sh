#!/usr/bin/env bash

# `build-hook-builtin-ssh.sh` as root. Nix then runs in a private mount
# namespace, and the fork must keep the descriptors that lead back out.

source common.sh

TODO_NixOS
[[ $(uname) == Linux ]] || skipTest "mount namespaces are Linux-only"
if ! command -p -v unshare; then skipTest "Need unshare"; fi
# The hook runs in the client, and a daemon started outside the namespace
# cannot be stopped from inside.
needLocalStore "the daemon would be stopped from inside the namespace"

# shellcheck disable=SC2119
execUnshare <<EOF
  source build-hook-builtin-ssh.sh
EOF
