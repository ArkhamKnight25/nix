#!/usr/bin/env bash

# A remote build in flight does not hold up the worker. The remote builder
# blocks until a local chain has finished, and the chain's first builder
# waits for the remote build to start. The remote build does not count
# against `--max-jobs 1`.
# Stores as in build-remote.sh, so this needs sandbox support and busybox.

source common.sh

TODO_NixOS
# No released daemon builds remotely in-process.
requireDaemonIsThisVersion
requireSandboxSupport
requiresUnprivilegedUserNamespaces
[[ "${busybox-}" =~ busybox ]] || skipTest "no busybox"

# Avoid store dir being inside sandbox build-dir.
unset NIX_STORE_DIR

chmod -R +w "$TEST_ROOT/machine"* 2> /dev/null || true
rm -rf "$TEST_ROOT/machine"*

sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
rm -rf "$sync"
mkdir -p "$sync"
# Named pipes let each step wait for the previous one without polling.
mkfifo "$sync/remote-started" "$sync/local-done"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Bind-mount the pipes into each chroot at the same path.
echo "extra-sandbox-paths = $sync" >> "$test_nix_conf"

# Only shell builtins, as the sandbox shell has no other applets.
cat > "$TEST_ROOT/local-progress.nix" <<'NIX'
{ configNix, sync, busybox }:
let
  system = (import configNix).system;
  mk = name: attrs: derivation ({
    inherit name system;
    builder = busybox;
    args = [ "sh" "-e" "-c" attrs.script ];
  } // removeAttrs attrs [ "script" ]);
  remote = mk "inprocess-remote-blocked" {
    requiredSystemFeatures = [ "remote-only" ];
    script = ''
      echo started > ${sync}/remote-started
      read d < ${sync}/local-done
      echo R > $out
    '';
  };
  local1 = mk "inprocess-local-1" {
    preferLocalBuild = true;
    script = ''
      read started < ${sync}/remote-started
      echo L1 > $out
    '';
  };
  local2 = mk "inprocess-local-2" {
    preferLocalBuild = true;
    script = ''
      read x < ${local1}
      echo done > ${sync}/local-done
      echo $x-L2 > $out
    '';
  };
in
mk "inprocess-top" {
  preferLocalBuild = true;
  script = ''
    read r < ${remote}
    read l < ${local2}
    echo $r $l > $out
  '';
}
NIX

# Both the entry and the machine's own store advertise `remote-only`.
machine="ssh-ng://localhost?remote-store=$TEST_ROOT/machine1?system-features=remote-only - - 1 1 remote-only"

# A worker that blocked would leave the pipes waiting forever.
outPath=$(timeout 240 nix-build "$TEST_ROOT/local-progress.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" --argstr busybox "$busybox" \
  --store "$TEST_ROOT/machine0" --builders "$machine" --max-jobs 1 \
  --no-out-link -vvv 2> "$log")

# Everything finished, in the order the markers enforce.
grep 'R L1-L2' "$TEST_ROOT/machine0/$outPath"

# Only the blocked derivation went to the machine.
output=$(nix path-info --store "$TEST_ROOT/machine1" --all)
echo "$output" | grepQuiet 'inprocess-remote-blocked'
echo "$output" | grepQuietInverse 'inprocess-local-'
echo "$output" | grepQuietInverse 'inprocess-top'

# Through the in-process path, without a hook.
grepQuiet "building '.*-inprocess-remote-blocked.drv' on 'ssh-ng://localhost" "$log"
grepQuiet "remote build done" "$log"
grepQuietInverse "starting build hook '" "$log"
