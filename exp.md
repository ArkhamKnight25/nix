# exp: the build hook's reply, awaited without blocking the worker

Working notes for this branch (step 1 of the asynchronous build hook).
Written with Claude Code. Not for upstream: drop this file, and rewrite
every commit message by hand, before any PR.

This branch: **A, `async-hook-queue`** (one shared hook, goals queue). Sibling: B, `async-hook-pool`.

## Goal

Upstream, a goal that may build remotely starts a build hook and then
blocks the whole worker on a `readLine` until the hook replies (accept,
decline, postpone). While one hook decides, no local build makes progress.
Step 1 removes that block: the worker waits for the reply in its own poll
loop, like any child's output, and keeps running other goals meanwhile.

Step 2 (no hook process at all for `ssh-ng` machines, in-process
coroutines) is on branch `exp-async-inprocess-hook`, which supersedes this
one; it was the mentor's suggested direction.

## Base

- `hook-fold` (cf0945c38) = NixOS/nix#16587, unchanged; this branch is on
  top of it.
- Sergei Zimmerman's `AsyncFdSource`/`AsyncFdSink` (0c3ff99e5): same patch
  as xokdvium/nix `async-fd-source-sink` 1300d3908, but with a message and
  author date that are not his (to be restored). It is not used by step 1.

## What is done

- `tryBuildHook` is a coroutine that awaits the hook's reply through
  `Worker::waitForInput` (d594e8866).
- Crash fix: SIGTERM while a goal awaited the reply aborted with "pure
  virtual method called" (the kill callback called a virtual method from
  `~Goal`); the job category is now passed explicitly (44e33596a), with a
  regression test (build-hook-interrupt-reply.sh).
- Bounded hooks. Without a bound, every waiting goal started its own hook
  (18 hook starts for 5 builds with one builder slot):
  - A, `async-hook-queue` (f9ebcedaf): one shared hook; goals wait their
    turn without blocking. Same process count as upstream, no new setting.
  - B, `async-hook-pool` (9b8a5ab4c): up to `max-build-hooks` (default 4,
    not justified by measurement) hooks, idle ones reused.
- Tests (12 hook tests): the built-in and configured hooks, ssh and ssh-ng,
  errors, interrupts while waiting and while queued, postpones, a hook that
  is awaited while a local build progresses (build-hook-async.sh), and for
  A one shared hook (build-hook-shared.sh), for B exactly two hooks with
  `max-build-hooks = 2` (build-hook-pool.sh).
- Mutation checks: removing each fix made its test fail (queue removed: 18
  hooks for 5 builds; pool cap removed: 6 hooks instead of 2; reuse
  removed: 25 hooks for 5 builds; blocking read restored: build-hook-async
  fails; crash fix reverted: the interrupt test aborts).
- Stress: 20 rounds of 5 timing-sensitive tests under CPU load, all pass.

## CI on the fork (run IDs; commit IDs changed in the 2026-10-28 rewrite)

- B: run 40151688325, every job green (Linux, sanitizers, macOS, Windows,
  clang-tidy, remote-build VM tests, daemon compatibility, installer).
- A: run 40151686784, green except "tests on macos", which failed on
  build-hook-builtin-interrupt: the macOS bug in `hook-fold` below, not A.
- macOS 20-round loops of that test: async-hook 9/20, A 7/20, B 10/20,
  `hook-fold` 6/20, upstream 20/20, `hook-fold` + fix 20/20.

## Known problems (from a line-by-line review, 2026-10-28)

- Inherited from `hook-fold`: the default hook is a fork of the worker
  without exec. It inherits the parent's signal callbacks (verified) and
  possibly locks held by other threads (SQLite, library mutexes;
  inferred), which is the substance of the review objection on #16587.
- The macOS bug: interrupting a remote build on `ssh-ng://localhost` can
  orphan the build (the forked hook SIGKILLs the local daemon while
  unwinding). Fixed on `exp-async-inprocess-hook`, not here.
- No reply timeout: a hook that never answers blocks all remote decisions
  (A) or one pool slot (B).
- Waiting goals are woken all at once, in address order, not first come
  first served.
- A hook that answered after another goal got `decline-permanently` is
  still kept idle until the worker exits.
- The `AsyncFdSource`/`AsyncFdSink` header is installed but unused here.

## Status

Superseded by `exp-async-inprocess-hook` (two fully green CI runs, VM
tests included). Kept for the record and as a smaller fallback design.
