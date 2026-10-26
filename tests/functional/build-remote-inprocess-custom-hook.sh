#!/usr/bin/env bash

# With `build-hook` set, the worker follows the hook's reply and does not
# pick a machine itself, though `builders` names one. The hook declines
# permanently, so the build runs locally.

source common.sh

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion
needLocalStore "the build hook is started by the process that builds"

hook="$TEST_ROOT/decline-hook.sh"
log="$TEST_ROOT/log"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Reply on stdout. `exec cat` drains the settings Nix writes to the hook,
# so that they do not hit a closed pipe.
cat > "$hook" <<HOOK
#!/bin/sh
echo "# decline-permanently"
exec cat > /dev/null
HOOK
chmod +x "$hook"

# A machine that would accept the build, were it asked.
machine="ssh-ng://localhost?remote-store=$TEST_ROOT/machine1"
rm -rf "$TEST_ROOT/machine1"

# shellcheck disable=SC2016
outPath=$(timeout 200 nix-build --no-out-link -vvv --max-jobs 1 \
  --option build-hook "$hook" --builders "$machine - - 1 1" -E '
  with import '"${config_nix}"';
  mkDerivation { name = "inprocess-custom-hook"; buildCommand = "echo local > $out"; }
' 2> "$log")

# Built locally.
grep local "$outPath"

# The hook ran and its reply was followed.
grepQuiet "starting build hook '$hook" "$log"
grepQuiet "hook reply is 'decline-permanently'" "$log"

# No in-process remote build, and the machine's store was never created.
grepQuietInverse "remote build done" "$log"
grepQuietInverse "on 'ssh-ng://localhost" "$log"
[[ ! -e "$TEST_ROOT/machine1" ]]
