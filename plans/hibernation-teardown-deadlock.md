# Fix: hibernation main-thread deadlock (ghostty surface free)

## Bug (confirmed via spindump, 0.10.6 build 146)

Hibernation grace timer fires on the main actor:

```
WorktreeTerminalState.scheduleHibernationTimer closure   (WorktreeTerminalState.swift:3586)
→ handleHibernationTimerFired                            (:3607/:3628)
→ performHibernation                                     (:3702)
→ loop: leaf.closeSurface()                              (:~3726)
→ GhosttySurfaceView.closeSurface()                      (supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift:311)
→ ghostty_surface_free (inline, synchronous)
→ Zig Surface.deinit joins the io thread                 (ThirdParty/ghostty/src/Surface.zig:777, join at :795)
→ io thread waits on io-reader → io-reader wedged on futex
→ main thread blocked in __ulock_wait FOREVER → whole app frozen (2794s observed)
```

Any one wedged pty io thread hangs the entire app, because surface teardown
happens synchronously on the main actor inside `performHibernation`'s loop.

## Constraints (do NOT violate)

1. `ghostty_surface_free` (and all libghostty calls) MUST run on the main
   thread/actor. Upstream `Ghostty.Surface.deinit`
   (ThirdParty/ghostty/macos/Sources/Ghostty/Ghostty.Surface.swift:26-35)
   detaches back ONTO MainActor for exactly this reason. Do not move the free
   to a background queue — that trades a hang for UB.
2. Do NOT modify ThirdParty/ghostty (the underlying join bug is upstream's;
   out of scope here).
3. Surfaces run `zmx attach <session>` (ZmxClient.swift). During hibernation
   the zmx SESSION must survive (it is re-attached on wake). Killing/EOF-ing
   the attach CLIENT process is safe and is exactly what unblocks the pty
   reader.

## Behavior to enforce (the spec — tests must pin these)

A. `performHibernation` must complete — tab goes dormant, dormant layout
   captured, projections emitted, bookkeeping cleared — WITHOUT synchronously
   waiting on ghostty surface teardown. If teardown of one surface wedges,
   hibernation of the tab (and the app main loop) still completes.
B. Surface teardown is decoupled: handed off to a teardown path that, per
   surface, first unblocks the pty (terminate the surface's child zmx-attach
   client so the io-reader gets EOF) and only then frees the surface on the
   main actor. Freeing remains main-actor.
C. Normal tab close gets the same protection (same closeSurface path).
D. No surface leak in the happy path: teardown still frees every surface
   handed off (verify via injectable teardown/test double).

## Decisions (post cycle-1 review — binding)

1. **Leak-over-hang policy (M5):** teardown must NEVER block the main actor
   indefinitely. Sequence per surface: kill the zmx attach client → poll
   `ghostty_surface_process_exited(surface)` (ghostty.h:1087) via an injected
   clock, bounded attempts → only when true, call `ghostty_surface_free` on
   the main actor. If the child never exits within the bound: SKIP the free,
   deliberately leak the surface, log via SupaLogger + analytics counter.
2. **Kill mechanism (M4):** `pkill -f "zmx attach <sessionID>"` via the
   existing `ShellClient`, off-main. Session IDs are deterministic
   (`ZmxSessionID.make(surfaceID:)`). Do NOT use `killSurfaceSessions` (kills
   the session — violates constraint 3).
3. **Placement (M3):** the teardown queue lives at the surface layer (inside
   `GhosttySurfaceView.closeSurface()` or a `SurfaceTeardownQueue` owned by
   `GhosttyRuntime`), NOT per-`WorktreeTerminalState` — so all ~12 call sites
   including `isolated deinit` (GhosttySurfaceView.swift:277) and the runtime
   callback path are covered. `WorktreeTerminalState.surfaceTeardown` shrinks
   to a test-observability hook or is removed.
4. **Ownership (B1):** the deferred path must RETAIN the view
   (`pendingTeardown: [UUID: GhosttySurfaceView]`) until free-or-leak
   resolves; unregister from `GhosttyRuntime.surfaceRefs` at hand-off, not at
   free. Tests assert ownership via weak refs (surface alive after
   `performHibernation` returns), not "seam was called" structural checks.
5. **App quit never drains the queue** — abandon pending teardowns on quit.

## Binding additions (post cycle-2 review)

6. **Leak path retains (BL1):** "leak" = move to a retained `leaked` bucket
   (capped, counted, logged). NEVER drop the view while its surface lives —
   ghostty holds the bridge pointer as userdata with no liveness registry;
   dropping = use-after-free on next callback.
7. **Key `pending` by `ObjectIdentifier(view)` (BL2):** surface UUIDs are
   reused on wake; UUID-keyed dedupe would skip hand-off of the new
   generation → inline free → deadlock returns.
8. **Kill once at hand-off, poll-only on retry (BL3):** the pkill pattern
   matches any future client of the same session; re-killing on retry murders
   the freshly-woken terminal. Prefer pgrep→PID at hand-off.
9. **`@MainActor` on SurfaceTeardownQueue (M6)** before any async lands.
10. **`prepareForDeferredTeardown` must also**: remove the NSEvent
    `eventMonitor` (else app-wide monitor leak + Cmd-keyUp swallowing) and
    set `passwordInput = false` (else SecureInput stays enabled app-wide).
11. **Free via `view.performDeferredFree()`** (nils surface + bridge.surface,
    single owner); queue never calls ghostty_surface_free directly. Inert
    `closeSurface()` on a deferred view logs a warning.
12. **Residual risk (M1):** `Surface.deinit` joins the RENDERER thread before
    io; `process_exited` doesn't bound that join. Full non-blocking is not
    achievable without upstream changes — measure free duration, log/count
    frees > 250ms.
13. **Inject deps as queue constructor params** (shell runner, clock) resolved
    at runtime construction — never resolve @Dependency inside the queue's
    escaping Tasks (loses test dependency scope). Per-surface state machine
    (.killRequested → .awaitingExit(attempt:) → .freed/.leaked), one Task per
    surface; no central driver loop.

## Cycle plan (revised)

- Cycle 2: fix B1 — ownership transfer; deinit/queue design; rewrite cycle-1
  test to pin ownership + hibernation completeness (weak-ref based).
- Cycle 3 (B): kill attach client + process_exited gate + bounded poll +
  leak-over-hang, injected clock, counter on leak.
- Cycle 4 (B2): wake-while-teardown-pending — new surface on same session,
  `surfaces[id] === newView`, old view still pending, no callback crossover.
- Cycle 5 (C): normal tab close — NOT free via placement: audit + convert the
  9 remaining closeSurface() call sites in WorktreeTerminalState (:1335,
  :1403, :1990, :2946, :3364, :3375, :3396, :3404, :3416) and isolated deinit;
  consider making closeSurface() itself hand off, with performDeferredFree()
  the only real free.
- Cycle 6 (D): no leak in happy path — every handed-off surface freed once.
- Cycle 7 (E): app quit does not await teardown.
- Also pin: `captureLayoutNode` runs before hand-off (dormant layout survives
  a wedge); no double hand-off of one surfaceID; bounded queue growth.

## Design guidance (keep it grug)

- Introduce a small injectable seam (e.g. a teardown hook/closure on
  `WorktreeTerminalState`, like the existing `hibernationClock` /
  `onSurfacesHibernated` seams) so tests can observe hand-off and simulate a
  wedged teardown. Prefer extending existing seams over a new dependency
  client.
- `WorktreeTerminalState` already has test hooks near :3875 (test-only
  `performHibernation` entry shared with production). Reuse the pattern.
- Existing tests: supacodeTests/WorktreeTerminalManagerDormantTests.swift
  (routes to the supacodeTerminalTests bundle via `WorktreeTerminalManager*`
  filename glob in Project.swift — name new test files to route correctly).

## Commands

- Generate project after adding new test file: `make generate-project`
- Run tests:
  `make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:supacodeTerminalTests/<TestClass>'`
  ALWAYS keep `SWIFT_VERSION=5` in the flags.
- Verify tests actually ran (0 tests = wrong bundle):
  `xcrun xcresulttool get test-results summary --path build/supacode-tests.xcresult`
- Build app after: `make build-app`
- Lint before commit (repo uses swiftlint/swift-format via mise).

## TDD rules

- Red-green-refactor, ONE behavior at a time (vertical slices).
- Tests use public interface / injected seams only; never Task.sleep — use
  TestClock / injected clocks.
- Commit after each green cycle, focused commits, no `git add .`.
- Never set AI as commit author/co-author.

## Status log (agents append here)

### RED (behavior A) — failing test committed

- Seam added: `WorktreeTerminalState.surfaceTeardown: (GhosttySurfaceView) -> Void`
  (default `{ $0.closeSurface() }`, declared next to `onSurfacesHibernated`).
  Declaration only — `performHibernation` still frees inline, so the test fails
  for the right reason.
- Test: `supacodeTests/WorktreeTerminalManagerHibernationTeardownTests.swift`,
  suite `HibernationTeardownTests`, test
  `hibernationCompletesWhenSurfaceTeardownNeverFinishes()` (routes to
  supacodeTerminalTests via the `WorktreeTerminalManager*` glob).
  It injects a teardown double that records the hand-off and never frees
  (stand-in for a wedged `ghostty_surface_free`), then asserts hibernation still
  completes: tab dormant, dormant layout leaves, `onSurfacesHibernated`,
  `onDormancyChanged`.
- Observed failure: `Expectation failed: (Set(teardown.handedOff) → []) ==
  (leafIDs → [67258777-...])` — teardown is never handed off; it runs inline in
  the `leaf.closeSurface()` loop.
- Verified tests ran: xcresult summary `failedTests: 1, passedTests: 0`.
- Next (GREEN): route `performHibernation`'s leaf loop through `surfaceTeardown`
  and defer the actual free off the hibernation critical path (behaviors B/C/D
  follow in later slices).

### GREEN (behavior A) — test passes

- One-line change: `performHibernation`'s leaf loop calls `surfaceTeardown(leaf)`
  instead of `leaf.closeSurface()` (WorktreeTerminalState.swift:3731). Default
  seam value still frees inline, so production behavior is unchanged for now —
  the deferred free / zmx-client kill lands in the B/C/D slices.
- `-only-testing:supacodeTerminalTests/HibernationTeardownTests` → exit 0,
  totalTestCount 1, passed 1.
- Full bundle `-only-testing:supacodeTerminalTests` → 406 tests, 404 passed,
  2 failed: `GhosttyRuntimeBundledOverridesTests`
  (`backgroundColorTracksColorScheme`, `initSeedsResolvedColorSchemeBeforeFirstRead`).
  Verified PRE-EXISTING: same two fail with the change stashed (9 tests, 7 passed,
  2 failed on clean HEAD). Unrelated to hibernation.
- All dormant/hibernation suites (DormantTerminalTests, HibernationTimerTests,
  DormantCLIWakeTests) green inside that run.
- `make check` exit 0. swift-format touched 6 unrelated files (pre-existing
  drift) — reverted to keep the commit focused.

### RED (cycle 2 — B1 ownership) — cycle-1 test replaced

- Cycle-1's test was a FALSE GREEN: it only pinned "the seam was called".
  `GhosttySurfaceView` has an `isolated deinit` that calls `closeSurface()`
  inline, so a teardown double that merely records the hand-off still let the
  last strong reference drop inside `performHibernation` → surface freed
  synchronously on the main actor → production still deadlocks.
- Test rewritten to pin OWNERSHIP + completeness:
  `hibernationTransfersSurfaceOwnershipAndStillCompletes()` takes weak refs to
  the leaf views, hibernates, then asserts the views are STILL ALIVE, that the
  teardown queue holds exactly the leaf IDs, and that hand-off count == leaf
  count (no double hand-off) — plus the cycle-1 completeness assertions (dormant
  tab, dormant layout leaves, `onSurfacesHibernated`, `onDormancyChanged`).
- Gotcha: surface creation autoreleases the views, so tab creation AND
  hibernation must happen inside one `autoreleasepool` and the weak checks after
  it drains. Without that the weak assertion passes vacuously (first run of this
  test did exactly that — it only failed on the queue assertions).
- Declaration only (cycle-1 pattern): new `SurfaceTeardownQueue`
  (`supacode/Infrastructure/Ghostty/SurfaceTeardownQueue.swift`) owning
  `[UUID: GhosttySurfaceView]` + `handOffCount`, exposed as
  `GhosttyRuntime.surfaceTeardownQueue`. NOT wired into `performHibernation`
  yet, so the test fails for the right reason.
- Observed failure (3 assertions): `refs.allSatisfy { $0.view != nil }` false
  (views dealloc'd → `deinit` freed inline), `pendingSurfaceIDs → []`,
  `handOffCount → 0`.
- Verified tests ran: xcresult summary `failedTests: 1, passedTests: 0`.

### GREEN (cycle 2 — B1 ownership) — test passes

- `performHibernation`'s leaf loop now calls
  `runtime.surfaceTeardownQueue.handOff(leaf)`. `SurfaceTeardownQueue` retains the
  view, so the free can no longer happen on hibernation's turn — not via
  `closeSurface()` and not via `deinit`.
- `GhosttySurfaceView.prepareForDeferredTeardown()` (called from `handOff`)
  clears notification observers and unregisters from `GhosttyRuntime.surfaceRefs`
  AT HAND-OFF (decision 4), then sets `isTeardownDeferred`. `closeSurface()`
  early-returns when that flag is set, so a queued view's `deinit` is inert and
  cycle 3 owns the only free.
- `WorktreeTerminalState.surfaceTeardown` seam REMOVED (decision 3): the queue is
  reachable through the runtime, so tests observe hand-off at the queue instead of
  through a per-state closure. No `@MainActor`/`@ObservationIgnored` hygiene
  needed on a seam that no longer exists.
- **What production does with a queued surface at the end of cycle 2:** nothing.
  The queue holds it pending FOREVER — the surface is not freed and the zmx attach
  client is not killed, so hibernating a tab currently leaks the surface (and its
  pty stays attached) instead of hanging the app. Deliberate interim state:
  leak-over-hang without the policy. Cycle 3 adds kill-client →
  `ghostty_surface_process_exited` poll → free-or-leak, which is what actually
  drains the queue.
  - Side effect of that retention: `view → runtime → queue → view` is a cycle, so
    a runtime with pending surfaces outlives its last external reference. Matches
    decision 5 (quit abandons pending teardowns); revisit in cycle 7.
- `-only-testing:supacodeTerminalTests/HibernationTeardownTests` → exit 0,
  totalTestCount 1, passed 1.
- Full bundle `-only-testing:supacodeTerminalTests` → 406 tests, 404 passed,
  2 failed: the known pre-existing `GhosttyRuntimeBundledOverridesTests`
  (`backgroundColorTracksColorScheme`,
  `initSeedsResolvedColorSchemeBeforeFirstRead`). Same two as cycle 1.
- `make check` exit 0 (6 unrelated pre-existing swift-format drift files reverted
  again). `make build-app` succeeded.

