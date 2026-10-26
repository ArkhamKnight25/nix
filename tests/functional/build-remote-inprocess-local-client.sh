#!/usr/bin/env bash

# The in-process remote build copies back into a local client store while
# the goal holds the outputs' path locks. `flock` locks conflict within one
# process, so this hangs unless the copy-back skips locks in `locksHeld`.
# A chroot-only client store with `-j0`, so no sandbox is needed anywhere.

source common.sh

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion

client="$TEST_ROOT/client"
log="$TEST_ROOT/log"
chmod -R +w "$client" 2> /dev/null || true
rm -rf "$client"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

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

# The client wrote both build logs into its own store, not the machine's.
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
