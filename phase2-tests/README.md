# amrit-tests — Phase 2 Builder Refactor verification (SCRATCH, NEVER STAGED)

> Excluded via `.git/info/exclude`. These are private verification artifacts.
> The *shipping* tests get moved to `src/libstore-tests/` etc. later.

## What changed (ground truth, read from the diff — not the design doc)

New `Builder` virtual overloads (in `src/libstore/include/nix/store/build.hh`):

```cpp
BuildResult buildDerivation(drvPath, drv, const StorePathSet & inputs, buildMode);
std::vector<KeyedBuildResult> buildPathsWithResults(reqs, const StorePathSet & inputs, buildMode);
```

Every impl follows the **same pattern**: pick substitute flag → `copyPaths(src, store, inputs)` → delegate to the no-input overload.

| Builder            | src store for copy | inputs handling                                  |
|--------------------|--------------------|--------------------------------------------------|
| `Worker`           | `evalStore`        | `copyPaths(evalStore, store, inputs)`            |
| `RemoteBuilder`    | `openStore()`      | `copyPaths(*srcStore, *store, inputs)`           |
| `LegacySSHBuilder` | `openStore()`      | `copyPaths(*srcStore, *store, inputs)`           |
| `RestrictedBuilder`| —                  | `throw Unsupported(...)` (both overloads)        |

Substitute flag everywhere: `buildersUseSubstitutes ? Substitute : NoSubstitute`.

## Flow map — three axes

**Axis 1 — Transport (builder class):**
- `local?root=…` → `Worker`
- `ssh://`        → `LegacySSHBuilder`
- `ssh-ng://`     → `RemoteBuilder`

**Axis 2 — Trust branch (`build-remote.cc`):**
- trusted OR CA derivation (`build-remote.cc:326`) → `buildDerivation(…, inputs)` overload
  - also: if `drv.inputDrvs` non-empty, `drv.inputSrcs = inputPaths` BEFORE the call
- untrusted non-CA (`build-remote.cc:352`) → `buildPathsWithResults(reqs, inputs)` overload
  - inputs = `inputPaths` + `computeFSClosure(*drvPath, …)` (drv closure folded in) **← highest-risk path**

**Axis 3 — `builders-use-substitutes`:** `true` | `false`

## The Issue-1 behavior question (untrusted branch)

OLD: standalone `copyPaths`/`copyClosure(local → remote, drv closure)`, then build-by-path.
NEW: `copyPaths` is folded *inside* the overload; `build-remote.cc` computes
`inputPathsWithDrv = inputPaths` then `computeFSClosure(*drvPath, inputPathsWithDrv)`
and ships that set via the overload.

**Claim to verify:** the same set of paths reaches the builder, and the drv builds.
`computeFSClosure(drvPath, set)` adds drvPath's closure *into* `set`, so drvPath is included.
The differential test below proves this empirically.

## Test layers

1. **unit/** — draft gtest: dispatch / trust-split / inputs-forwarded / empty-set.
   (RestrictedBuilder-throws can't be pure-unit — ctor needs live `Worker&`; see edge/recursive-nix.sh.)
2. **flows/** — one runnable script per transport (local, ssh, ssh-ng), substitute on/off.
   Trusted vs untrusted on ssh-ng depends on remote `trusted-users` config (see below).
3. **differential/** — before(HEAD~1) vs after(HEAD) capture + diff. The proof we broke nothing.
4. **edge/** — CA derivation (forces buildDerivation overload), multi-input drv (inputSrcs
   hijack, build-remote.cc:336), recursive-nix (RestrictedBuilder throw path).

### Trusted vs untrusted on ssh-ng (the high-risk branch)

`ssh-ng-offload.sh` hits `RemoteBuilder`. Which trust branch fires depends on whether THIS
client is in the remote daemon's `trusted-users`:
- you ARE trusted-user  → `buildDerivation(…, inputs)`        overload
- you are NOT            → `buildPathsWithResults(…, inputs)`  overload ← **must-test**

To force untrusted: on the builder laptop, ensure your user is NOT in `trusted-users`
(`/etc/nix/nix.conf`), restart nix-daemon, then run `ssh-ng-offload.sh`. Confirm via the
build log mentioning the unprivileged/untrusted path.

## Coverage matrix (3 transports × 2 trust × 2 substitute = 12; run the prioritized subset)

| Transport      | Trusted/CA | Untrusted | subst=on | subst=off | Reachable here |
|----------------|-----------|-----------|----------|-----------|----------------|
| local?root=    | ✅         | hard*     | ✅        | ✅         | 1 laptop       |
| ssh://         | ✅         | ✅         | ✅        | ✅         | 2 laptops      |
| ssh-ng://      | ✅         | ✅         | ✅        | ✅         | 2 laptops      |

\* untrusted on `local?root=` needs an untrusted-client config; trusted is the default.

## How to run

```bash
# baseline (stash your change → run → record), then after (pop → run → record)
bash amrit-tests/differential/run.sh
```

**Two-laptop note:** the *offloading* laptop runs `build-remote.cc` — that's where the
change matters; it needs YOUR built nix. The builder laptop can be stock. Toggle the
change only on the offloading side; keep the builder constant, else the diff is contaminated.

**Pass = `differential/before/` and `differential/after/` are identical** (modulo timestamps).
