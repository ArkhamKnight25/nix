#!/usr/bin/env bash

# Failures on the in-process path are reported and do not crash. An
# unreachable machine is named and given up on, and a `builders` line that
# does not parse fails the build with exit status 1.

source common.sh

# Fail on undefined behaviour in sanitizer builds.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

cache="$TEST_ROOT/cache"
log="$TEST_ROOT/log"
rm -rf "$cache"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# shellcheck disable=SC2016
expr='
  with import '"${config_nix}"';
  mkDerivation { name = "inprocess-error"; buildCommand = "echo e > $out"; }
'

# A `remote-program` that cannot be started.

# With `localhost` the program runs without ssh, so the handshake fails.
status=0
timeout 200 nix-build -E "$expr" --store "file://$cache" -j0 --no-out-link -vvv \
  --builders "ssh-ng://localhost?remote-program=$TEST_ROOT/no-such-program - - 1 1" \
  2> "$log" || status=$?
# Status 100 is a failed build, not an error (1), timeout (124) or crash.
[[ $status -eq 100 ]] || fail "expected exit status 100 with no machine and no local builds, got $status"
[[ $status -ne $((128 + 6)) && $status -ne $((128 + 11)) ]] || fail "the client died with status $status"
grepQuietInverse "Nix crashed" "$log"

# The error names the machine and the bad parameter.
grepQuiet "cannot build on 'ssh-ng://localhost.*no-such-program" "$log"
# No machine is left, and the binary-cache store cannot build locally.
grepQuiet "Unable to build with a primary store that isn't a local store" "$log"
# Nothing was copied to a machine and no hook started. "remote build done"
# is traced even when no machine is reached, so it is no marker here.
grepQuietInverse "copying dependencies to" "$log"
grepQuietInverse "starting build hook '" "$log"

# A `builders` line that does not parse.

# Column 3 is `maxJobs`, an unsigned int.
badBuilders="ssh-ng://localhost - - notanumber 1"
parseError="bad machine specification: failed to convert column #3 in a row"

# With nowhere to build, the build fails with the parse error.
status=0
timeout 200 nix-build -E "$expr" --store "file://$cache" -j0 --no-out-link -vvv \
  --builders "$badBuilders" 2> "$log" || status=$?
[[ $status -eq 1 ]] || fail "expected exit status 1 for an unparsable machine list, got $status"
grepQuiet "$parseError" "$log"
grepQuietInverse "Nix crashed" "$log"

# Still an error with local builds allowed. A list that does not parse is
# a misconfiguration, so nothing is quietly built locally.
# shellcheck disable=SC2016
expr2='
  with import '"${config_nix}"';
  [ (mkDerivation { name = "inprocess-error-local-a"; buildCommand = "echo a > $out"; })
    (mkDerivation { name = "inprocess-error-local-b"; buildCommand = "echo b > $out"; }) ]
'
status=0
timeout 200 nix-build --no-out-link -vvv -j2 --builders "$badBuilders" -E "$expr2" 2> "$log" || status=$?
[[ $status -eq 1 ]] || fail "expected exit status 1 for an unparsable machine list, got $status"
grepQuiet "$parseError" "$log"
for drvPath in $(nix-instantiate -E "$expr2"); do
    for outPath in $(nix-store -q --outputs "$drvPath"); do
        [[ ! -e $outPath ]] || fail "$outPath was built with an unparsable machine list"
    done
done
grepQuietInverse "remote build done" "$log"
grepQuietInverse "starting build hook '" "$log"
