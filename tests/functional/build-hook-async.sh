#!/usr/bin/env bash

# The worker keeps running other goals while one waits for the build
# hook's reply. The hook replies only after a local build that can start
# only once another local build has finished.

source common.sh

# Older daemons wait for the hook's reply with a blocking read.
requireDaemonIsThisVersion
TODO_NixOS

hook="$TEST_ROOT/hook.sh"
marker="$TEST_ROOT/local-built"
met="$TEST_ROOT/hook-met"
rm -f "$marker" "$met"

# `/bin/sh` because the sandbox has no `/usr/bin/env`. The reply goes to
# stderr, and `exec cat` drains the input so Nix's writes do not hit EPIPE.
cat > "$hook" <<EOF
#!/bin/sh
i=0
while [ ! -e "$marker" ]; do
  i=\$((i + 1))
  if [ "\$i" -ge 300 ]; then
    echo timeout >> "$met"
    echo "# decline-permanently" >&2
    exec cat > /dev/null
  fi
  sleep 0.1
done
echo ok >> "$met"
echo "# decline-permanently" >&2
exec cat > /dev/null
EOF
chmod +x "$hook"

echo "build-hook = $hook" >> "$test_nix_conf"
# Let the daemon, if there is one, read the new `nix.conf`.
restartDaemon

# Only `remote` goes to the hook. `dep` and `local` build locally.
# shellcheck disable=SC2016
nix-build --max-jobs 2 --no-out-link -E '
  with import '"${config_nix}"';
  let
    dep = mkDerivation {
      name = "async-hook-dep";
      preferLocalBuild = true;
      buildCommand = "sleep 1; echo > $out";
    };
  in
  [
    (mkDerivation { name = "async-hook-remote"; buildCommand = "echo > $out"; })
    (mkDerivation {
      name = "async-hook-local";
      preferLocalBuild = true;
      inherit dep;
      buildCommand = "touch '"$marker"'; echo > $out";
    })
  ]
'

[[ $(< "$met") = ok ]]
