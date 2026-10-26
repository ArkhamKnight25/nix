# Evidence for the async-hook and hook-fold macOS claims (2026-10-25)

Raw outputs behind every number in the handoffs. GitHub job logs need a signed-in
account, so the macOS logs are copied here; you need no credentials to check them.

## macOS (GitHub Actions, macos-14, 20 rounds of the interrupt test each)

Each log contains the build, the per-round `round N: OK|FAIL` lines, the
`RESULT pass=.. fail=..` line, and for trace runs the kill/signal traces of
the first 3 passing and first 3 failing rounds. Every run shows "success" on
GitHub because the loop counts failures instead of failing the job.

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

Runs: `https://github.com/ArkhamKnight25/nix/actions/runs/<run>`. The branches are on
the fork; `git show <branch>` shows the exact patch, test and workflow each run used.

What to look for in the trace logs (search for `=== TRACE (`):
- `proof-fork-trace.log`, failing rounds: the hook sends `kill pid=<daemon> sig=9`
  2 ms after SIGTERM, the daemon is reaped with `status=9`, and the build is
  `STILL RUNNING` with parent PID 1.
- `proof-upstream-trace.log`: the client reaps the hook with `status=15` (it died of
  SIGTERM without unwinding). There is no kill of the daemon, which gets signal 13
  and cleans up.
- `proof-fork-fix-trace.log`: the hook sends `kill pid=<daemon> sig=15 timeout_ms=10000`,
  the daemon is reaped with `status=256` (a normal exit), and the build is gone.
- `proof-realssh.log`: the hook SIGKILLs the local `ssh` client, while the remote
  `nix-daemon --stdio` under `sshd-session` survives and the build is gone.
- `repeat-diag.log`: each surviving build is `sleep 1000` with parent PID 1, and
  they accumulate across rounds.

Limit: the daemon kills its build with a direct `::kill` (`killChild`), which the
trace does not record. "The daemon killed its build in passing rounds" is
therefore by elimination.

## Local (Linux, WSL, ~/nix-gsoc)

| Claim | File(s) |
|---|---|
| Full meson suite: 311 OK / 0 Fail / 7 Skipped on both branches | `local/full-suite-queue.txt`, `local/full-suite-pool.txt`, `local/final-local-summary.txt` |
| Unfixed async-hook starts 18 hooks for 5 builds; the queued goal does not wait | `local/unfixed-async-hook-churn/` (`accepts=5 postpones=23 starts=18`), `local/unfixed-async-hook-churn-summary.txt` |
| Postpone, queued-interrupt and interrupt-reply tests, plus mutation checks (each fails for the stated reason) | `local/extra-tests-and-mutations-{queue,pool}/` |
| Stress: 20 rounds × 5 tests under CPU load, 100/100 per branch | `local/stress-{queue,pool}/`, `local/stress-summary.txt` |
| Whole functional suite against Nix 2.35.2 and 2.34.8 daemons: 0 failures | `local/old-daemon-*.out`, `local/old-daemon-summary.txt` |

Which commit each local output came from. The branches were rebased as fixes
landed underneath them; the later rebases changed only build files, the clang-tidy
throw, and one test guard:

| Output | queue | pool |
|---|---|---|
| full suite 311/0/7 | 04bf0adb0 | a0c8f6d4a |
| stress | 35a10da78 | fd5af49c8 |
| extra tests + mutations | f748b4aeb + the test files (committed as 35a10da78) | 38e732a91 + the test files (committed as fd5af49c8) |
| old daemons | a7f96e94f (final) | 33a20a8e3 (final) |
| unfixed churn | async-hook @ d0aa0c58d | |

Final tips: async-hook-queue a7f96e94f, async-hook-pool 33a20a8e3. The final tips
were also run through GitHub CI: runs 40151686784 (queue: green except the macOS
interrupt flake) and 40151688325 (pool: fully green).
