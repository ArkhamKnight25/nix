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

# The hook declines, so the builds fall back to the local builder. Two
# derivations in a chain, so the goals reach the hook one after the
# other: `decline-permanently` from the first must stop the second from
# starting a hook at all. (Goals that are ready at the same time take
# turns at one hook; see build-hook-shared.sh.)
# shellcheck disable=SC2016
nix-build --no-out-link -E '
  with import '"${config_nix}"';
  let a = mkDerivation { name = "configured-hook-a"; buildCommand = "echo a > $out"; };
  in mkDerivation { name = "configured-hook-b"; inherit a; buildCommand = "cat $a > $out"; }
'

# Started once: `decline-permanently` stops further attempts.
[[ $(wc -l < "$ran") -eq 1 ]]
