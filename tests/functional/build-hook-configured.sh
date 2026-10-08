#!/usr/bin/env bash

# A `build-hook` the user configured has to be run as a program, even
# though Nix runs its own hook in-process. It is set in the system
# `nix.conf`, whose values are not `isOverridden()` after `loadConfFile`,
# so this fails if the choice is made on that flag.

source common.sh

TODO_NixOS

hook="$TEST_ROOT/hook.sh"
ran="$TEST_ROOT/hook-ran"

# `decline-permanently` so the parent drops the hook instead of reusing
# it for the next derivation: `dependencies.nix` has five, and a hook
# that answered only the first probe would leave the second unanswered.
# `/bin/sh`: the sandbox has no `/usr/bin/env`.
# `exec cat`: keep reading until Nix closes our input. Exiting first can
# fail Nix's write of the request with EPIPE, which Nix treats as the
# hook dying rather than declining, so it would start the hook again.
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

# The configured program was started, and once: declining permanently
# drops the hook instead of starting it again for the next derivation.
[[ $(wc -l < "$ran") -eq 1 ]]
