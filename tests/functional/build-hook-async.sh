#!/usr/bin/env bash

# While a goal waits for the build hook's reply, the worker keeps running
# other goals. The hook replies only once a local build has run that the
# worker can start only after seeing another local build finish. With a
# blocking wait the worker would never get that far.

source common.sh

# Older daemons wait for the hook's reply with a blocking read.
requireDaemonNewerThan "2.36.0pre20261026"
TODO_NixOS

hook="$TEST_ROOT/hook.sh"
marker="$TEST_ROOT/local-built"
met="$TEST_ROOT/hook-met"
rm -f "$marker" "$met"

# `/bin/sh`: the sandbox has no `/usr/bin/env`. The reply goes to fd 2.
# `exec cat`: read until Nix closes our input (see build-hook-configured.sh).
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
# The daemon reads `nix.conf` at startup. A no-op without one.
restartDaemon

# `remote` goes to the hook. `dep` and `local` prefer a local build, so
# they do not, and `local` starts only after `dep` has finished.
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
