#!/usr/bin/env bash

# A `build-hook` set in the system `nix.conf` runs as a program, and its
# `decline-permanently` stops later goals from starting it again.

source common.sh

# Fail on undefined behaviour in sanitizer builds.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS

hook="$TEST_ROOT/hook.sh"
ran="$TEST_ROOT/hook-ran"

# `/bin/sh` because the sandbox has no `/usr/bin/env`. `exec cat` drains
# the input, as an early exit can fail Nix's write with EPIPE, and Nix
# then starts the hook again.
cat > "$hook" <<EOF
#!/bin/sh
echo ran >> "$ran"
echo "# decline-permanently" >&2
exec cat > /dev/null
EOF
chmod +x "$hook"

echo "build-hook = $hook" >> "$test_nix_conf"
# Let the daemon, if there is one, read the new `nix.conf`.
restartDaemon

# A chain, so that the goals reach the hook one after the other.
# shellcheck disable=SC2016
nix-build --no-out-link -E '
  with import '"${config_nix}"';
  let a = mkDerivation { name = "configured-hook-a"; buildCommand = "echo a > $out"; };
  in mkDerivation { name = "configured-hook-b"; inherit a; buildCommand = "cat $a > $out"; }
'

[[ $(wc -l < "$ran") -eq 1 ]]
