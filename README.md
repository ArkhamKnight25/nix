# Logs: the hook-fold macOS interrupt bug and the async-hook tests (2026-10-25)

This branch only holds logs. They are the outputs behind the macOS interrupt bug
I found in `hook-fold` (the branch of NixOS/nix#16587) and the local test runs of
my async build hook branches. GitHub only shows job logs to signed-in users, so I
copied the macOS logs here.

## macOS runs (GitHub Actions, macos-14)

Each run repeats the interrupt test 20 times. A log has the build output, one
`round N: OK|FAIL` line per round and a final `RESULT pass=.. fail=..` line. The
trace runs also print the kill and signal traces of the first 3 passing and the
first 3 failing rounds. GitHub shows every run as "success", because the loop
counts the failures instead of failing the job.

| File | Run | Branch @ commit | Code under test | RESULT |
|---|---|---|---|---|
| `macos-job-logs/repeat-baseline.log` | 40155100912 | ci/macos-repeat-baseline @ 8f23aea0b | hook-fold + tests (12a70deb2) | pass 6 / fail 14 |
| `macos-job-logs/repeat-async-hook.log` | 40155101090 | ci/macos-repeat-async-hook @ 566119f09 | async-hook (f37c8b010) | pass 9 / fail 11 |
| `macos-job-logs/repeat-queue.log` | 40155101108 | ci/macos-repeat-queue @ 1783c35f2 | async-hook-queue (a7f96e94f) | pass 7 / fail 13 |
| `macos-job-logs/repeat-pool.log` | 40155101097 | ci/macos-repeat-pool @ 1e713d501 | async-hook-pool (33a20a8e3) | pass 10 / fail 10 |
| `macos-job-logs/repeat-upstream.log` | 40156486557 | ci/macos-repeat-upstream @ f7ceb793e | upstream 64d3a126e + the test | pass 20 / fail 0 |
| `macos-job-logs/repeat-diag.log` | 40157532757 | ci/macos-repeat-diag @ e39ee38e2 | hook-fold + tests, dumps `ps` when the build survives | pass 8 / fail 12 |
| `macos-job-logs/proof-fork-trace.log` | 40183712395 | ci/macos-proof-fork-trace @ 79ee3baa9 | hook-fold + tests + trace | pass 4 / fail 16 |
| `macos-job-logs/proof-upstream-trace.log` | 40183712494 | ci/macos-proof-upstream-trace @ 8b4ed4da3 | upstream + trace | pass 20 / fail 0 |
| `macos-job-logs/proof-fork-fix.log` | 40183712556 | ci/macos-proof-fork-fix @ 6acdf86a1 | hook-fold + tests + ssh.cc fix | pass 20 / fail 0 |
| `macos-job-logs/proof-fork-fix-trace.log` | 40183712444 | ci/macos-proof-fork-fix-trace @ d8d99313a | same + trace | pass 20 / fail 0 |
| `macos-job-logs/proof-realssh.log` | 40183712596 | ci/macos-proof-realssh @ 616cf10c6 | hook-fold + tests, real sshd on 127.0.0.1 | pass 20 / fail 0 |

Each run is at `https://github.com/ArkhamKnight25/nix/actions/runs/<run>`. The
branches are on this fork, and `git show <branch>` shows the patch, test and
workflow that each run used.

In the trace logs, search for `=== TRACE (`:
- `proof-fork-trace.log`, failing rounds: 2 ms after SIGTERM, the hook sends
  `kill pid=<daemon> sig=9`. The daemon is reaped with `status=9`, and the build
  is `STILL RUNNING` with parent PID 1.
- `proof-upstream-trace.log`: the client reaps the hook with `status=15`, so the
  hook died of SIGTERM without unwinding. Nothing kills the daemon; it gets
  signal 13 and cleans up.
- `proof-fork-fix-trace.log`: the hook sends
  `kill pid=<daemon> sig=15 timeout_ms=10000`, the daemon exits normally
  (`status=256`), and the build is gone.
- `proof-realssh.log`: the hook SIGKILLs the local `ssh` client, the remote
  `nix-daemon --stdio` under `sshd-session` survives, and the build is gone.
- `repeat-diag.log`: each surviving build is `sleep 1000` with parent PID 1, and
  they pile up from round to round.

One gap: the daemon kills its build with a direct `::kill` (`killChild`), and the
trace doesn't record that call. So in the passing rounds, "the daemon killed its
build" is inferred, because nothing else did.

## Local runs (Linux, WSL)

These are from my async build hook branches, `async-hook-queue` and
`async-hook-pool`.

| What it shows | File(s) |
|---|---|
| The full meson suite passes on both branches: 311 OK, 0 failed, 7 skipped | `local/full-suite-queue.txt`, `local/full-suite-pool.txt`, `local/final-local-summary.txt` |
| The unfixed async hook starts 18 hooks for 5 builds, because the queued goal doesn't wait | `local/unfixed-async-hook-churn/` (`accepts=5 postpones=23 starts=18`), `local/unfixed-async-hook-churn-summary.txt` |
| The postpone, queued-interrupt and interrupt-reply tests, plus mutation checks, each failing for the stated reason | `local/extra-tests-and-mutations-{queue,pool}/` |
| Stress: 20 rounds of 5 tests under CPU load, 100 of 100 on each branch | `local/stress-{queue,pool}/`, `local/stress-summary.txt` |
| The whole functional suite against Nix 2.35.2 and 2.34.8 daemons: no failures | `local/old-daemon-*.out`, `local/old-daemon-summary.txt` |

The commit each local output came from is below. I rebased the branches as fixes
landed under them; the later rebases changed only build files, the clang-tidy
throw and one test guard.

| Output | queue | pool |
|---|---|---|
| full suite 311/0/7 | 04bf0adb0 | a0c8f6d4a |
| stress | 35a10da78 | fd5af49c8 |
| extra tests + mutations | f748b4aeb + the test files (committed as 35a10da78) | 38e732a91 + the test files (committed as fd5af49c8) |
| old daemons | a7f96e94f (final) | 33a20a8e3 (final) |
| unfixed churn | async-hook @ d0aa0c58d | |

The final commits are a7f96e94f (async-hook-queue) and 33a20a8e3
(async-hook-pool). Both also ran through GitHub CI: run 40151686784 (queue: green
apart from the flaky macOS interrupt test) and run 40151688325 (pool: fully
green).
