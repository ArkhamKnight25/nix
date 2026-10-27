#!/usr/bin/env bash

# A configured `build-hook` is still a program, and it alone decides.
# With `build-hook` set, the worker does not select a machine itself even
# though `builders` names one; it starts the program and follows its
# reply. The program here replies `decline-permanently`, so the
# derivation builds locally and the machine is never contacted.
#
# Local store, local build, no machine ever reached: no sandbox needed.
# The hook is started by whichever process runs the build, so this must
# be the client.

source common.sh

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion
needLocalStore "the build hook is started by the process that builds"

hook="$TEST_ROOT/decline-hook.sh"
log="$TEST_ROOT/log"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# The reply goes to stdout (hook-instance.cc: stdout is `fromHook`, stderr
# is merged into it). `exec cat`: keep reading until Nix closes our
# input, so the settings Nix writes to us first do not hit a closed pipe.
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
outPath=$(timeout 300 nix-build --no-out-link -vvv --max-jobs 1 \
  --option build-hook "$hook" --builders "$machine - - 1 1" -E '
  with import '"${config_nix}"';
  mkDerivation { name = "inprocess-custom-hook"; buildCommand = "echo local > $out"; }
' 2> "$log")

# Built, locally.
grep local "$outPath"

# The program ran and was obeyed
# (hook-instance.cc, HookInstance::external; derivation-building-goal.cc,
# tryBuildHook: `debug("hook reply is '%1%'", reply)`).
grepQuiet "starting build hook '$hook" "$log"
grepQuiet "hook reply is 'decline-permanently'" "$log"

# The in-process path was not taken: no machine selected, none built on,
# and the machine's store was never even created by a daemon.
grepQuietInverse "remote build done" "$log"
grepQuietInverse "on 'ssh-ng://localhost" "$log"
[[ ! -e "$TEST_ROOT/machine1" ]]
