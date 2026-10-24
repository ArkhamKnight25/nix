#!/usr/bin/env bash

# While a goal waits for the build hook's reply, the worker keeps running
# other goals. Two derivations are ready at once, so two hooks run at
# once; each waits for the other before replying. With a blocking wait
# the second hook would start only after the first had replied, and the
# first would wait in vain.

source common.sh

TODO_NixOS

hook="$TEST_ROOT/hook.sh"
ran="$TEST_ROOT/hook-ran"
met="$TEST_ROOT/hook-met"
rm -f "$ran" "$met"

# `/bin/sh`: the sandbox has no `/usr/bin/env`. The reply goes to fd 2.
# `exec cat`: read until Nix closes our input (see build-hook-configured.sh).
cat > "$hook" <<EOF
#!/bin/sh
echo \$\$ >> "$ran"
i=0
while [ "\$(wc -l < "$ran")" -lt 2 ]; do
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

# Two independent derivations, so both goals are ready at the same time.
# shellcheck disable=SC2016
nix-build --max-jobs 2 --no-out-link -E '
  with import '"${config_nix}"';
  [ (mkDerivation { name = "async-hook-a"; buildCommand = "echo a > $out"; })
    (mkDerivation { name = "async-hook-b"; buildCommand = "echo b > $out"; }) ]
'

# Both hooks ran, and each saw the other.
[[ $(wc -l < "$ran") -eq 2 ]]
[[ $(grep -c '^ok$' "$met") -eq 2 ]]
grepQuietInverse timeout "$met"
