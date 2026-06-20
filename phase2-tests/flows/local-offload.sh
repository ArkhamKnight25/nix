#!/usr/bin/env bash
# Flow: local?root= offload  →  Worker builder, trusted branch, both substitute settings.
# Covers: Transport=local, Trust=trusted (default), Substitute=toggle via $SUBST.
# Does NOT cover: untrusted branch (needs untrusted-client config), ssh transports.
#
# Forces offload with --max-jobs 0 so the build goes through build-remote → Worker.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/_common.sh"

SUBST="${SUBST:-false}"          # builders-use-substitutes
WORK="$(mktemp -d)"
SRC="local?root=$WORK/store-a"
DST="local?root=$WORK/store-b"
trap 'rm -rf "$WORK"' EXIT

echo "== local-offload (substitutes=$SUBST) =="
echo "src=$SRC"
echo "dst=$DST"

DRV="$(trivial_drv "$SRC")"
echo "drv=$DRV"

# Offload: max-jobs 0 forces the local builder to refuse, build-remote picks DST.
"$NIX" --extra-experimental-features 'nix-command flakes' \
  --store "$SRC" \
  --max-jobs 0 \
  --builders "$DST x86_64-linux,i686-linux - 1 1" \
  --option builders-use-substitutes "$SUBST" \
  build "$DRV^*" --no-link --print-out-paths

echo "== done =="
record_store "$SRC" "${RECORD_PREFIX:-/dev/stdout}.src"
record_store "$DST" "${RECORD_PREFIX:-/dev/stdout}.dst"
