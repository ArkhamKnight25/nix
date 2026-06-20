#!/usr/bin/env bash
# Differential test: prove the Phase 2 change preserves behavior.
#
# Strategy: run the reachable flow(s) on UNMODIFIED code (baseline), record;
# run on MODIFIED code, record; diff. Identical = pass.
#
# IMPORTANT: this rebuilds nix twice. Both sides must be the SAME nix, differing
# ONLY by the six source files. We use `git stash` to toggle the change.
#
# Env:
#   FLOW     which flow script to run (default: local-offload.sh)
#   REMOTE   passed through for ssh flows
#   SUBST    builders-use-substitutes (run once each value for full coverage)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FLOW="${FLOW:-local-offload.sh}"
FLOW_SCRIPT="$ROOT/phase2-tests/flows/$FLOW"

BEFORE="$HERE/before"
AFTER="$HERE/after"
mkdir -p "$BEFORE" "$AFTER"

build_nix() {
  echo ">> building nix ..."
  ( cd "$ROOT" && nix develop --command ninja -C build ) >/dev/null
}

run_flow() {
  local prefix="$1"
  RECORD_PREFIX="$prefix/store" bash "$FLOW_SCRIPT" 2>&1 | tee "$prefix/log.txt"
}

# The change is COMMITTED (afb5bfb1d). Toggle the six files between HEAD~1
# (baseline) and HEAD (modified) via checkout. Working tree must be clean on
# these files before starting.
FILES=(
  src/libstore/build/entry-points.cc
  src/libstore/include/nix/store/build.hh
  src/libstore/include/nix/store/build/worker.hh
  src/libstore/legacy-ssh-store.cc
  src/libstore/remote-store.cc
  src/libstore/restricted-store.cc
  src/nix/build-remote/build-remote.cc
)

restore_head() { ( cd "$ROOT" && git checkout HEAD -- "${FILES[@]}" ); }
trap restore_head EXIT   # always leave the tree on the committed (modified) version

echo "### DIFFERENTIAL: flow=$FLOW subst=${SUBST:-false}"

echo "### 1/4 baseline: checkout HEAD~1 of the six files"
( cd "$ROOT" && git checkout HEAD~1 -- "${FILES[@]}" )
build_nix
echo "### 2/4 baseline run"
run_flow "$BEFORE"

echo "### 3/4 restoring committed change (HEAD)"
restore_head
build_nix
echo "### 4/4 modified run"
run_flow "$AFTER"

echo "### DIFF"
if diff -ru "$BEFORE" "$AFTER" \
     --exclude=log.txt; then   # logs carry timestamps; compare store records only
  echo "PASS: before == after (store records identical)"
else
  echo "FAIL: store records differ — investigate above"
  exit 1
fi

# ------------------------------------------------------------------
# NOTE: if the change is COMMITTED (as commit afb5bfb1d) rather than in
# the working tree, replace the stash dance with:
#   git checkout HEAD~1 -- <the 6 files>   # baseline
#   ...build, run into before...
#   git checkout HEAD   -- <the 6 files>   # restore
#   ...build, run into after...
# ------------------------------------------------------------------
