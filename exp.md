# exp: remote builds from inside the worker, without a hook process

Working notes for this branch. Written with Claude Code. Not for upstream:
drop this file, and rewrite every commit message by hand, before any PR.

## Goal

Today the worker forks a build hook per remote-build decision and blocks
on its reply. The goal is to remove that process:

1. The worker never blocks on a remote machine. It waits on the remote
   store's connection descriptor in its own event loop, next to local
   builds.
2. The default hook's work (pick a machine, open the `ssh-ng` store, copy
   inputs, build, copy outputs back) runs inside the worker as a coroutine
   over `AsyncFdSource` / `AsyncFdSink`, so many remote builds can be in
   flight from one worker.
3. A configured `build-hook` program keeps working as before, and is
   awaited without blocking. Legacy `ssh://` machines take the existing
   blocking path.

## Base

- Upstream `master` at 570246c9c (2026-10-26).
- The six commits of NixOS/nix#16587 (`hook-fold`), rebased onto it.
  `hook-fold` itself is unchanged; this branch is separate.
- Sergei Zimmerman's `AsyncFdSource`/`AsyncFdSink` (xokdvium/nix
  `async-fd-source-sink`, 1300d3908), same patch.

## What is done

- Worker protocol connections take any buffered stream, so the same code
  runs over blocking `FdSink`/`FdSource` or the async streams.
- The worker has a Boost.Asio event loop and waits through it; an
  interrupt wakes it.
- An `ssh-ng` store can be opened from inside a coroutine; ssh runs in
  batch mode, and is stopped with SIGTERM and a grace period instead of
  SIGKILL (this also fixes the macOS orphaned-build bug, below).
- Remote builds run from the worker on a protected 8 MiB coroutine stack:
  machine selection, input copy, build, output copy, log file, max-log-size,
  retry when a build came back empty, bounded wait for cancelled builds in
  `~Worker`.
- A configured `build-hook` is awaited without blocking, one goal at a time.
- Tests on this branch: functional tests for a multi-output remote build,
  configured and program hooks, a hook awaited and shared, and interrupts
  while waiting; unit tests for the async streams (including cancellation
  of a suspended read); a handshake over async streams, as a skeleton only.
  Release note and manual text.
- Eight more in-process functional tests (two remote builds at once, local
  builds progressing meanwhile, stopping the client, failures reported,
  `ssh://` through the blocking path) exist on a local branch based on an
  earlier version of this one; not yet carried over.

## macOS bug this also fixes

On macOS, interrupting a remote build on `ssh-ng://localhost` can leave the
build running, orphaned to PID 1. The ssh child (with `localhost`, the
daemon itself) is SIGKILLed while the connection unwinds, before the daemon
can stop its build; Linux hides it with `PR_SET_PDEATHSIG`. With
`hook-fold` it fails 6/20 on macOS CI, upstream passes 20/20, and the
SIGTERM-plus-grace-period change passes 20/20. By code reading, plain
upstream `nix build --store ssh-ng://localhost` plus SIGTERM to the client
should leak the same way; not yet run. Evidence: branch
`evidence/hook-interrupt-2026-10-25`.

## Verified so far (2026-10-27)

- libutil and libstore compile on macOS 26, Apple clang 21, Homebrew
  dependencies (Boost 1.92), with Nix's own warning flags.
- That needed five fixes, each a `fixup!` commit for the commit that
  caused it (`git rebase -i --autosquash upstream/master`):
  - an ambiguous `Logger::result` call (span vs JSON);
  - `RemoteBuildLogger` given internal linkage (`-Werror=weak-vtables`);
  - `FdSink::written` still reset through the type-erased sink;
  - a missing `nix/store/build.hh` include;
  - out-of-line destructors for `AsyncFdSource`/`AsyncFdSink`
    (`-Werror=weak-vtables`; a weak vtable also breaks `dynamic_cast`
    across shared libraries on Darwin).

## CI on the fork

- Run 40444716203 (8539269d8): only clang-format failed; fixed with the
  exact diff CI's clang-format 21 printed ("Apply clang-format").
- Run 40445052233 (224ad2244): build, clang-tidy, Windows unit tests,
  unit tests on Linux and macOS, and sanitizer unit tests pass. Functional
  tests: 203 of 204 pass on macOS. Failures, both fixed since:
  - `binary-cache-build-remote` (Linux, macOS, sanitizers): a client run
    with `-j0` and `--builders 'auto ...'` could not build on that machine.
    The hook process had set `max-jobs` to 1 before opening the machine's
    store; in-process the client's 0 applied. Now raised to 1 only around
    the non-yielding calls on a store that is not `ssh-ng`, and restored.
    `ssh-ng` machines are unaffected: `SSHStore::setOptions` sends nothing.
  - docs link check: the release note named `max-log-size`; the setting
    is `max-build-log-size`.

- Run 40448795410 (ff684945e): every job passes. That is build,
  clang-tidy, Windows unit tests, unit and functional tests on Linux,
  macOS and with sanitizers, the docs link check, flake regressions, and
  the installer tests on Linux and macOS. The remote-build VM tests
  (`remoteBuilds`, `remoteBuildsSshNg`) are not part of this workflow and
  have not run on this branch.

## Not verified yet

- Nothing beyond libutil and libstore has been compiled: not libexpr,
  the `nix` binary, or Linux / Windows cross builds.
- No local test run: this Mac has no Nix, and the unit tests need rapidcheck.
- Linux behaviour, sandboxed builds, `ssh://` legacy path, real remote
  machines over a network.

## Open questions

- Is the in-process coroutine the shape the Nix team wants, given review
  on #16587 asked for no fork-without-exec? This branch removes the fork
  for the default hook entirely, which may answer that review.
- Should the async streams land as their own PR first?
- Commit messages and `Assisted-by:` trailers: not final.
