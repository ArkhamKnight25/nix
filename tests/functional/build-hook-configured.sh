#!/usr/bin/env bash

# A `build-hook` set in the system `nix.conf` runs as a program.

source common.sh

TODO_NixOS

hook="$TEST_ROOT/hook.sh"
ran="$TEST_ROOT/hook-ran"

# `/bin/sh`: the sandbox has no `/usr/bin/env`. `exec cat`: read until
# Nix closes our input; exiting early can fail Nix's write with EPIPE,
# and Nix then starts the hook again.
cat > "$hook" <<EOF
#!/bin/sh
echo ran >> "$ran"
echo "# decline-permanently" >&2
exec cat > /dev/null
EOF
chmod +x "$hook"

echo "build-hook = $hook" >> "$test_nix_conf"
# The daemon reads `nix.conf` at startup. A no-op without one.
restartDaemon

# The hook declines, so the build falls back to the local builder.
nix-build dependencies.nix --no-out-link

# Started once: `decline-permanently` stops further attempts.
[[ $(wc -l < "$ran") -eq 1 ]]
