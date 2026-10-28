# exp: remote builds from inside the worker, without a hook process

Working notes for this branch. Written with Claude Code. Not for upstream:
drop this file, and rewrite every commit message by hand, before any PR.

## Status (2026-10-29)

- Last fully green CI: run 40747310573 (branch exp-async-inprocess-hook-vm6
  = c8826152b plus the VM-test CI commit). Everything after c8826152b is
  being tested in run 40751794388 (7f06ac58d) and the run after it.
- Line-by-line reviews of every hunk of this branch against upstream were
  done on 2026-10-29 (tables under ~/nix-gsoc-notes/review-20261029/, not
  in this repo). Fixed since 7f06ac58d, each its own commit:
  - the worker's wait closed the children's descriptors if anything threw
    before the asio wrappers were released (real bug; now released from a
    destructor); the handlers run per wait are bounded;
  - after a postpone, the "waiting for a machine" activity stayed open for
    the whole remote build; the running-builds count was not dropped when
    the machine could not be reached;
  - a machine that hands the build back (unreachable, or one for the hook
    process) is asked about again at once instead of after a
    poll-interval sleep;
  - the default hook's `nix` is found as `getNixBin` does (NIX_BIN_DIR,
    next to the program, PATH), so non-ssh-ng machines do not depend on
    PATH;
  - an operation cancelled before it started is reported as a
    `SystemError` and marks the stream bad;
  - the handshake-mismatch drain runs outside the catch handler;
    `BasicServerConnection` cannot be copied or moved; the logger is not
    paused while ssh connects in batch mode;
  - dead code removed: the coroutine's blocking path, the raw-log drain
    and the max-jobs workaround could no longer run once non-ssh-ng
    machines went to the hook process;
  - tests: background clients killed on failure, the hook interrupt tests
    trapped, the async handshake unit test with both sides on one loop,
    inner timeouts below meson's; docs and setting text made true.
- Fork without exec: none on this branch. ssh-ng machines are built on
  in-process (no hook process); every other process start is
  `spawnProgram` (fork and exec; on macOS upstream's spawnProgram runs
  some C++ between fork and exec, which is upstream's doing).
- Still blocking the worker briefly, by design or bounded: the machines
  `main-lock`, `ssh -O check` on each connect, SQLite and local-store
  work, the 10 s grace for a `localhost` daemon on teardown, the
  post-build hook's wait.

## Relation to step 1

Step 1 (branches `async-hook-queue` = A and `async-hook-pool` = B, each
with its own exp.md) kept the hook process and only stopped the worker
from blocking on its reply. This branch is step 2: no hook process for
`ssh-ng` machines at all; other machines still use the hook process, now
awaited without blocking as in step 1. It supersedes A and B.

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
- Seven more in-process functional tests, carried over on 2026-10-28; see
  "Concurrency tests" below.

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

## First local compile (2026-10-27)

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

- Run 40570429865 on `exp-async-inprocess-hook-vmtests` (this branch plus
  the CI change that adds the VM tests), 2026-10-28:
  - pass: build, pre-commit, clang-tidy, Windows unit tests, unit tests.
  - pass: `build-remote-inprocess-concurrent` on Linux, macOS and with
    sanitizers. This is the test that proves concurrency.
  - FAIL: `build-remote-inprocess-error` on Linux, macOS and sanitizers.
  - FAIL: `build-remote-inprocess-local-progress` on Linux and sanitizers,
    after 0.2 s (exit status 100), so likely its setup, not the worker.
    On macOS it is skipped (needs a sandbox).
  - Not reached: the VM tests and the installer tests, which run after
    the functional tests.
  - Neither failure is diagnosed yet.

Commit IDs above are from before 2026-10-28; see "History" below.

## Does the worker really never block? (code audit, 2026-10-28)

An independent read of the code, item by item, found the claim true with
exceptions. Fixed since:
- `ssh-ng://host?max-connections=N` with N > 1 started an ssh control
  master and waited for it with a blocking read on the worker thread,
  unbounded on a stalled host. A store opened from a coroutine no longer
  uses the master.
- An untrusted client building a non-CA derivation on a daemon older than
  protocol 1.32 copied the closure through the threaded
  `addMultipleToStore`, using the coroutine's streams from pool threads
  (the owner assert aborts). It now goes through the same one-path-at-a-time
  copy as the inputs.

Still blocking, by design or bounded:
- Machines that are not `ssh-ng` (`ssh://`, `mounted-ssh-ng`, local
  stores) go to the hook process, whose reply is awaited without
  blocking (since 13d2f1b7d).
- Each ssh connection's teardown waits for ssh to exit (SIGTERM, up to
  10 s before SIGKILL).
- Local work: `ssh -O check`, the machines `main-lock`, SQLite (busy
  timeout), hashing and registering a downloaded output, log-file writes.

## Concurrency tests (added 2026-10-28)

- `build-remote-inprocess-concurrent.sh`: two remote builds on one machine
  each wait for the other's marker, so both must run at once from one
  worker. A blocking or serialising worker times out.
- `build-remote-inprocess-local-progress.sh`: a remote build waits for a
  marker that only a chain of two local builds can write, so the worker
  must reap and start local builds while the remote build is in flight.
  Needs a sandbox: Linux only, skipped on macOS.
- Five more: in-process build and its log, interrupting the client,
  failures reported, a configured `build-hook` still decides alone, and
  `ssh://` through the blocking path. All seven needed `-vvv`: the lines
  they assert are logged at debug level.

## Test fixes (2026-10-28)

Both failures in run 40570429865 were bugs in the tests, not in Nix:
- `build-remote-inprocess-local-progress`: its helper builds called
  `busybox sleep`, but the sandbox shell has no `sleep` ("sleep: applet not
  found", exit 127), so it never tested anything. Now the steps block on
  named pipes made with `mkfifo` (each step waits for the previous one, no
  polling), and `nix-build` runs under `timeout 240`, so a worker that
  blocks fails the test instead of hanging it.
- `build-remote-inprocess-error`: it asserted that "remote build done" never
  appears, but that trace is logged whenever the remote-build coroutine
  returns, also when no machine could be reached. It now asserts that
  nothing was copied to a machine ("copying dependencies to" never
  appears), which only happens after a machine accepted the connection.

## Known problems

Fixed on 2026-10-28 after line-by-line reviews (each its own commit):
- Cancellation now fails every later async operation
  (`throw_if_cancelled`): before, Ctrl-C during a stalled upload could
  abort Nix (reproduced outside Nix), and the log limit could fail to stop
  a flooding build.
- Lines past `max-build-log-size` are all dropped, not only the first.
- Machines other than `ssh-ng` go to the hook process, so they no longer
  hold up the worker (`machineRunsInProcess`).
- `timesBuilt` is counted only when a remote build ran.
- The ssh child gets SIGTERM plus a grace period only for `localhost`;
  real ssh is killed as upstream does.
- The async streams report a broken connection through `good()`.

Still open (from the reviews):
- The thread's current activity can leak between coroutines across a
  suspension (progress-bar parentage, cosmetic).
- Exception state (`std::uncaught_exceptions`) is per thread, not per
  coroutine; I/O inside a catch block on the async path can confuse
  another coroutine.
- When the first machine is unreachable, the "building ... on" line names
  it although the build ran on the next one.
- `~Worker` waits only 5 s for in-flight remote builds.
- Each ssh-ng connect runs `ssh -O check` synchronously.
- Explicitly setting `build-hook = nix __build-remote` equals the default
  (compared by value); the setting's text says so now.
- History: two `fixup!` commits target the wrong commit and must be
  retargeted before squashing; Sergei Zimmerman's commit carries a message
  and date that are not his.

## Not verified yet

- Real remote machines over a network: the VM tests use VMs on one host,
  and the functional tests use `ssh-ng://localhost`.
- A worker running inside `nix-daemon` building remotely in-process (the
  multi-user setup): no test yet; every in-process test builds in the
  client.
- Many remote builds over real ssh, and `max-connections > 1` on ssh-ng.
- No local test run: this Mac has no Nix, and the unit tests need
  rapidcheck. All test results above come from the fork's CI.

## History

- 2026-10-28: author and committer of every commit by the branch owner set
  to `ArkhamKnight25 <amritamber3112@gmail.com>` (some had a machine-local
  address), and `Co-Authored-By:` / `Assisted-by:` lines naming Claude
  removed from the messages, on all fork branches except `hook-fold`
  (unchanged). Commit order, messages, dates and trees are unchanged; the
  commit IDs changed, so IDs quoted above from before that date no longer
  exist on the fork. Commits by other people keep their authors.
- Nix's contribution policy requires an `Assisted-by:` trailer on
  AI-assisted commits, so the disclosure has to be added back, in the
  owner's words, before any upstream PR.

## Open questions

- Is the in-process coroutine the shape the Nix team wants, given review
  on #16587 asked for no fork-without-exec? This branch removes the fork
  for the default hook entirely, which may answer that review.
- Should the async streams land as their own PR first?
- Commit messages and `Assisted-by:` trailers: not final.
