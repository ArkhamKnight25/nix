#!/usr/bin/env bash

# The in-process remote build copying back into a local store, without
# a sandbox anywhere.
#
# The client's store is a local store under $TEST_ROOT/client with the
# test's store directory (`--store <path>`, i.e. `local?root=<path>`):
# it could only build in a chroot, and `-j0` keeps it from trying. The
# machine is `ssh-ng://localhost`, the test's own plain store, which
# builds unsandboxed. So this runs wherever the suite runs.
#
# The goal holds its outputs' path locks while the machine builds and
# while the outputs are copied back (derivation-building-goal.cc,
# acquireResources). `LocalStore::addToStore` locks each path it adds
# unless it is in `locksHeld` (local-store.cc), and the copy-back runs
# in the goal's own process, on the worker's thread
# (remote-machine-build.cc, buildOnRemoteMachine). `flock` locks
# conflict between two descriptors of one process, so without
# `locksHeld` the copy-back would wait for a lock its own process holds,
# forever, and the `timeout` below would end the test.
#
# A derivation with four outputs, all copied back in one go, and one
# that depends on two of them, so that its build needs them back first.

source common.sh

# Undefined behaviour found by a sanitizer build fails the test instead
# of being printed and passed over.
export UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion

client="$TEST_ROOT/client"
log="$TEST_ROOT/log"
chmod -R +w "$client" 2> /dev/null || true
rm -rf "$client"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# (Quoted heredoc: `$out`, `$dev`, `$doc` and `$man` are for the builder.)
cat > "$TEST_ROOT/local-client.nix" <<'NIX'
{ configNix }:
with import configNix;
rec {
  multi = mkDerivation {
    name = "inprocess-local-client-multi";
    outputs = [ "out" "dev" "doc" "man" ];
    buildCommand = ''
      echo inprocess-local-client-multi-was-here
      mkdir $out $dev $doc $man
      echo out > $out/f
      echo dev > $dev/f
      echo doc > $doc/f
      echo man > $man/f
    '';
  };
  top = mkDerivation {
    name = "inprocess-local-client-top";
    buildCommand = ''
      echo inprocess-local-client-top-was-here
      cat ${multi.dev}/f ${multi.man}/f > $out
    '';
  };
  all = multi.all ++ [ top ];
}
NIX

outPaths=$(timeout 200 nix-build "$TEST_ROOT/local-client.nix" -A all \
  --argstr configNix "$config_nix" \
  --store "$client" --builders "ssh-ng://localhost - - 1 1" -j0 \
  --no-out-link -vvv 2> "$log")

# Five outputs, each valid in the client's store.
[[ $(wc -l <<< "$outPaths") -eq 5 ]] || fail "expected five output paths, got: $outPaths"
for outPath in $outPaths; do
    nix path-info --store "$client" "$outPath"
done
topOut=$(nix-build "$TEST_ROOT/local-client.nix" -A top --argstr configNix "$config_nix" \
  --store "$client" -j0 --no-out-link)
[[ $(nix store cat --store "$client" "$topOut") == $'dev\nman' ]]

# The client wrote both build logs from the machine's output, into its
# own store's log directory, not the machine's.
for name in multi top; do
    drvPath=$(nix-instantiate "$TEST_ROOT/local-client.nix" -A "$name" \
      --argstr configNix "$config_nix" --store "$client")
    nix log --store "$client" "$drvPath" | grepQuiet "inprocess-local-client-$name-was-here"
done

# Both built by the in-process path, no hook.
grepQuiet "building '.*-inprocess-local-client-multi.drv' on 'ssh-ng://localhost'" "$log"
grepQuiet "building '.*-inprocess-local-client-top.drv' on 'ssh-ng://localhost'" "$log"
[[ $(grep -c "remote build done" "$log") -eq 2 ]]
grepQuietInverse "starting build hook '" "$log"
