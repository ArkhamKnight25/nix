#!/usr/bin/env bash

# The worker is not held up by a remote build in flight. One derivation
# goes to the machine and its builder blocks until a local chain of two
# derivations has finished; the chain's first builder in turn waits
# until the remote build has started. With a worker that blocked while
# a remote build ran, the chain would never start, the remote builder
# would hit its bounded wait, and the build would fail.
#
# Setup as in build-remote.sh (client store `machine0`, machine store
# `machine1`, both diverted and so built in a chroot: sandbox support,
# user namespaces and busybox needed). The three builders meet in one
# host directory that `extra-sandbox-paths` bind-mounts into every
# chroot; the client and the machine's daemon read the same nix.conf.
# `--max-jobs 1`: one local build at a time, and the remote one does not
# count against it.

source common.sh

TODO_NixOS
# The in-process remote build is in no released daemon, whatever its
# version number; a released daemon builds through its own hook.
requireDaemonIsThisVersion
requireSandboxSupport
requiresUnprivilegedUserNamespaces
[[ "${busybox-}" =~ busybox ]] || skipTest "no busybox"

# Avoid store dir being inside sandbox build-dir (see build-remote.sh).
unset NIX_STORE_DIR

chmod -R +w "$TEST_ROOT/machine"* 2> /dev/null || true
rm -rf "$TEST_ROOT/machine"*

sync="$TEST_ROOT/sync"
log="$TEST_ROOT/log"
rm -rf "$sync"
mkdir -p "$sync"
# Named pipes: opening one blocks until the other side opens it, so each
# step waits for the previous one without polling. The sandbox shell has
# no `sleep`.
mkfifo "$sync/remote-started" "$sync/local-done"
trap '[[ $? -eq 0 ]] || { echo "--- client log ---" >&2; cat "$log" >&2; }; killDaemon' EXIT

# Visible, writable, under the same path inside each chroot.
echo "extra-sandbox-paths = $sync" >> "$test_nix_conf"

# Only shell builtins: the sandbox shell has no other applets.
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

# The machine's own store must advertise the feature the remote
# derivation requires, as the outer entry does for the selection.
machine="ssh-ng://localhost?remote-store=$TEST_ROOT/machine1?system-features=remote-only - - 1 1 remote-only"

# A worker that blocks on the remote build never starts the local chain,
# so the pipes would wait forever: bound it.
outPath=$(timeout 240 nix-build "$TEST_ROOT/local-progress.nix" \
  --argstr configNix "$config_nix" --argstr sync "$sync" --argstr busybox "$busybox" \
  --store "$TEST_ROOT/machine0" --builders "$machine" --max-jobs 1 \
  --no-out-link -vvv 2> "$log")

# Everything finished, in the order the markers enforce.
grep 'R L1-L2' "$TEST_ROOT/machine0/$outPath"

# Only the blocked derivation went to the machine; the chain stayed local.
output=$(nix path-info --store "$TEST_ROOT/machine1" --all)
echo "$output" | grepQuiet 'inprocess-remote-blocked'
echo "$output" | grepQuietInverse 'inprocess-local-'
echo "$output" | grepQuietInverse 'inprocess-top'

# Through the in-process path, without a hook
# (derivation-building-goal.cc, buildRemotely; hook-instance.cc).
grepQuiet "building '.*-inprocess-remote-blocked.drv' on 'ssh-ng://localhost" "$log"
grepQuiet "remote build done" "$log"
grepQuietInverse "starting build hook '" "$log"
