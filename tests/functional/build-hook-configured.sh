#!/usr/bin/env bash

# A `build-hook` the user configured has to be run as a program, even
# though Nix runs its own hook in-process. The setting is read from the
# system `nix.conf` here, which is the only configuration a daemon sees
# and the one `loadConfFile` strips the overridden flag from, so this
# fails if the choice is made on `isOverridden()`.

source common.sh

needLocalStore "the build hook runs in the process that owns the build loop"
TODO_NixOS

hook="$TEST_ROOT/hook.sh"
ran="$TEST_ROOT/hook-ran"

rm -f "$ran"

# `decline-permanently` so the parent drops the hook instead of reusing
# it for the next derivation: `dependencies.nix` has five, and a hook
# that answered only the first probe would leave the second unanswered.
#
# `/bin/sh`, not `/usr/bin/env`: on CI this runs inside the Nix build
# sandbox, which provides `/bin/sh` and nothing under `/usr/bin`.
cat > "$hook" <<EOF
#!/bin/sh
echo ran >> "$ran"
echo "# decline-permanently" >&2
EOF
chmod +x "$hook"

echo "build-hook = $hook" >> "$test_nix_conf"

# The hook declines, so the build falls back to the local builder.
nix-build dependencies.nix --no-out-link

# ... but the configured program must have been started.
test -s "$ran"
