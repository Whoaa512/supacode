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

### RED→GREEN (cycle 3, slice 1 — queue hygiene, no async yet)

- New suite `SurfaceTeardownQueueTests`
  (`supacodeTests/WorktreeTerminalManagerSurfaceTeardownTests.swift`, routes to
  supacodeTerminalTests). RED first: 2 of 4 tests failed for the right reasons —
  `queue.pendingCount → 1) == 2` (two DIFFERENT view instances sharing one
  surface UUID collapsed to one entry) and `view.passwordInput → true) == false`.
- Fixes (bindings 7, 9, 10):
  - `@MainActor` on `SurfaceTeardownQueue` (landed before any async — binding 9).
  - `pending` re-keyed by `ObjectIdentifier(view)`; `pendingSurfaceIDs` now
    derived from the values. Surface UUIDs are reused on wake, so UUID keying
    would have skipped the hand-off of the woken generation → inline free →
    deadlock returns.
  - `prepareForDeferredTeardown()` also removes the NSEvent local monitor (nils
    it so `deinit` can't double-remove) and sets `passwordInput = false`. Both
    are APP-WIDE state: a pending view would otherwise keep intercepting
    Cmd-keyUp for live surfaces and keep SecureInput enabled everywhere.
    Pinned by tests via a new read-only `hasLocalEventMonitor` seam +
    `passwordInput`.
- `-only-testing:supacodeTerminalTests/SurfaceTeardownQueueTests` +
  `HibernationTeardownTests` → exit 0, totalTestCount 5, passed 5, failed 0.

### RED→GREEN (cycle 3, slice 2 — kill the attach client at hand-off)

- `SurfaceTeardownQueue.init(shell:)` takes a new one-closure
  `SurfaceTeardownShell` (`run: (URL, [String]) async -> String?`, nil = failed /
  non-zero, since `pgrep` exits 1 on no match). Narrower than `ShellClient` so a
  test double is one closure. `GhosttyRuntime.init` resolves
  `@Dependency(\.shellClient)` AT CONSTRUCTION and passes `.live(shellClient)`
  (binding 13) — the queue's Tasks escape the caller's dependency scope, so
  resolving inside them would grab the live shell in tests.
- `handOff` now spawns ONE Task per view (binding 13, no central driver) that
  kills that surface's `zmx attach` client: `pgrep -f "zmx attach <sessionID>"` →
  `kill -TERM <pids>`; single `pkill -f "zmx attach <sessionID>"` only when pgrep
  finds nothing (logged). Session ID from `ZmxSessionID.make(surfaceID:)`. Never
  re-killed later (binding 8) — the pattern matches any FUTURE client of the
  surviving session, so a retry kill would murder a freshly woken terminal.
  Tasks retained in `teardownTasks` keyed by view identity; `teardownTask(for:)`
  lets tests await completion without `Task.sleep` (and cycle 7 can abandon them).
- RED first: 3 new tests failed on `spy.commands`/`killCommands` while the queue
  only did bookkeeping; 4 slice-1 tests stayed green.
- 4 new tests: kill-by-PID with exact argv, pkill fallback (exactly one kill
  command), each hand-off of a REUSED surface UUID kills its own client (2 kills),
  and no commands at all without a hand-off. Slice-1 tests now use the spy shell
  too, so the suite runs no real processes.
- `-only-testing:supacodeTerminalTests/SurfaceTeardownQueueTests` +
  `HibernationTeardownTests` → exit 0, totalTestCount 9, passed 9, failed 0.
- Full bundle `-only-testing:supacodeTerminalTests` → 414 tests, 412 passed,
  2 failed: the same known pre-existing `GhosttyRuntimeBundledOverridesTests`
  failures as cycles 1–2.
- `make check` exit 0 (same 6 unrelated swift-format drift files reverted).
  `make build-app` succeeded.
- **Still pending after slice 2:** the client is killed but the surface is NEVER
  freed — no `ghostty_surface_process_exited` poll, no free, no leak bucket. That
  is slices 3–5 (poll → free-or-leak → counters).


### RED→GREEN (cycle 3, slice 3 — poll `process_exited`, then free)

- RED: new test `pollingFreesTheSurfaceOnceTheProcessHasExited()` referenced
  `SurfaceTeardownQueue(shell:clock:hasProcessExited:free:)` and
  `GhosttySurfaceView.performDeferredFree()` — compile failure (`no member
  performDeferredFree`, `extra arguments at positions #2, #3, #4`).
- Queue now takes an injected `clock: any Clock<Duration>` (default
  `ContinuousClock()`) plus two main-actor closures — `hasProcessExited`
  (production: `view.hasSurfaceProcessExited` → `ghostty_surface_process_exited`)
  and `free` (production: `view.performDeferredFree()`). Closures take the VIEW,
  so `GhosttySurfaceView` needs no test seam of its own.
- `pending` values became `Entry(view:stage:)` with the binding-13 state machine
  (`.killRequested` → `.awaitingExit(attempt:)` → `.freed`), readable via
  `stage(for:)`. The per-view Task now runs kill → `awaitExitThenFree`: poll the
  probe, `clock.sleep(50ms)` between attempts, max 40 attempts (2s bound —
  generous for a normal `zmx attach` exit, short enough that a wedged pty doesn't
  pile up pending surfaces). On probe true → `free(view)` → drop the pending entry
  and the Task, which releases the queue's last strong reference.
- `GhosttySurfaceView.performDeferredFree()` is the only real free for a deferred
  view (binding 11): `ghostty_surface_free` + nils `surface`, `bridge.surface`,
  `lastOcclusion`, `lastSurfaceFocus`.
- Test drives a `TestClock` (never `Task.sleep`): asserts nothing is freed while
  the probe says the child lives (5 ticks), then flips the probe, advances, and
  asserts freed exactly once (by surface ID), `pendingCount == 0`, and the view
  DEALLOCATED (weak ref nil, hand-off inside an `autoreleasepool`).
- `-only-testing:supacodeTerminalTests/SurfaceTeardownQueueTests` +
  `HibernationTeardownTests` → exit 0, totalTestCount 10, passed 10, failed 0.
- Still pending after slice 3: probe never true → the entry stays pending forever
  (no leak bucket, no counter). Slice 4.

### RED→GREEN (cycle 3, slice 4 — leak over hang)

- RED: `abandonedTeardownRetainsTheViewInsteadOfFreeingIt()` referenced
  `queue.leakedCount` and an `analytics:` constructor param — compile failure.
- Poll bound exhausted → `leak(key)`: entry removed from `pending`, Task dropped,
  view APPENDED to a retained `leaked` array (binding 6). The view is never
  released while its surface lives — ghostty holds the bridge as userdata with no
  liveness registry, so dropping it would be a use-after-free on the next
  callback. `leakedCount` exposes it.
- Cap choice: `leakedWarningCap = 32` only escalates SupaLogger `warning` → `error`;
  it never drops a view (retention is a correctness requirement, not a budget). 32
  because a wedged pty is rare — 32 of them means every hibernate is wedging, i.e.
  systemic, not incidental.
- Analytics counter: `analyticsClient.capture("surface_teardown_leaked",
  ["leaked_count": n])`, following the existing `AnalyticsClient` convention.
  Injected as a queue constructor param resolved in `GhosttyRuntime.init`
  (binding 13, same reason as the shell).
- Test asserts: nothing freed, `pendingCount == 0`, `leakedCount == 1`, analytics
  event `surface_teardown_leaked`, and the weak ref STILL non-nil.
- `SurfaceTeardownQueueTests` + `HibernationTeardownTests` → exit 0,
  totalTestCount 11, passed 11, failed 0.

### GREEN (cycle 3, slice 5 — instrumentation + test hardening)

- Free duration measured around `free(view)` and logged via SupaLogger when
  > 250ms (binding 12). Measured on a REAL `ContinuousClock`, not the injected
  one: the injected clock exists to schedule polls, and `Surface.deinit` also joins
  the RENDERER thread (which `process_exited` does not bound), so only wall time
  describes the residual main-actor stall. TestClock would always report zero.
- `closeSurface()` on a deferred view now logs a SupaLogger warning before its
  early return (binding 11) — a caller reaching there believes the surface is gone
  and it isn't yet.
- `HibernationTeardownTests` hardened: `refs.count > 0` (an empty `allSatisfy` is
  vacuously true), and each pending view is parked at stage `.killRequested`.
  `handOffCount` REMOVED from queue + test: `pendingCount == leafIDs.count` covers
  "nothing skipped", and double hand-off idempotence is pinned directly in
  `SurfaceTeardownQueueTests`.
- Attempted and dropped: `view.surface != nil` while pending. `createSurface()`
  needs `runtime.app`, which a headless test process never gets, so `view.surface`
  is nil from birth in unit tests (the assert failed for that reason, not a
  regression). Real surface liveness is pinned in `SurfaceTeardownQueueTests` via
  the injected free/probe instead.
- `SurfaceTeardownQueueTests` + `HibernationTeardownTests` → exit 0,
  totalTestCount 11, passed 11, failed 0.
- Full bundle `-only-testing:supacodeTerminalTests` → 416 tests, 414 passed,
  2 failed: the same known pre-existing `GhosttyRuntimeBundledOverridesTests`
  failures as cycles 1–2.
- `make check` exit 0 (same 6 unrelated swift-format drift files reverted).
  `make build-app` succeeded.
- **End-to-end production semantics after cycle 3:** hibernating a tab (or any
  path through `handOff`) returns immediately; per surface, the queue kills the
  `zmx attach` client once, polls `ghostty_surface_process_exited` up to 40x50ms on
  the real clock, then frees on the main actor via `performDeferredFree()`. If the
  child never exits, the surface is deliberately leaked (retained, logged,
  counted). No path frees a surface whose pty child is still alive, so the
  spindump deadlock cannot recur.
- Remaining (cycles 4–7): wake-while-pending, the 9 other `closeSurface()` call
  sites, happy-path no-leak proof across a whole tab, quit abandoning pending.

### GREEN (cycle 4 — wake while teardown pending) — behavior already correct, now pinned

- New suite `WakeWhileTeardownPendingTests`
  (`supacodeTests/WorktreeTerminalManagerWakeTeardownTests.swift`, routes to
  supacodeTerminalTests). **Zero production changes** — cycles 2–3 already got this
  right (view-identity keying + the `surfaces[view.id] === view` guards), so this
  cycle is a regression fence, not a fix. All 3 tests passed on first run.
- Because "passed first run" is not evidence a test bites, both invariants were
  MUTATION-VERIFIED (mutation applied, suite run, mutation reverted):
  - Surface-id dedupe in `handOff` (`guard !pendingSurfaceIDs.contains(view.id)`,
    i.e. binding 7 undone) → `reHibernatingQueuesBothGenerationsOfTheSameSurfaceID`
    FAILS. This is the deadlock-returns case: the woken generation's hand-off is
    skipped, so its free runs inline.
  - Identity guards weakened to key presence (`surfaces[view.id] != nil` at :3255,
    :3282 and in `isLiveSurface`) → `staleCallbacksFromThePendingViewCannotMutateTheWokenTab`
    FAILS. Confirms the guards are load-bearing, not decorative.
- Slice 1 (`wakeMintsANewGenerationWhileTheOldViewStaysPending`): real
  `hibernateTab` → `wakeTab` on a zmx-eligible tab. Wake mints a NEW view per
  frozen leaf under the ORIGINAL surface id; asserts new ids == old ids, every new
  view `!==` its old view, tab awake (`dormantTabLayouts[tab] == nil`,
  `!isTabDormant`), old views STILL pending at stage `.killRequested`,
  `pendingSurfaceIDs == ids`, and — the important negative — the LIVE views have no
  queue entry (`stage(for:) == nil`), since freeing a surface that is back in the
  tree would tear down a working terminal. No zmx kills.
- Slice 2 (`reHibernatingQueuesBothGenerationsOfTheSameSurfaceID`): hibernate →
  wake → hibernate with generation 1 still pending. `pendingCount == 2 * leaves`
  under ONE reused surface id, both generations at `.killRequested`, generation 2
  has its own teardown Task (its own attach-client kill — no dedupe skip),
  `leakedCount == 0`.
- Slice 3 (`staleCallbacksFromThePendingViewCannotMutateTheWokenTab`): the pending
  view KEEPS its ghostty bridge closures (`prepareForDeferredTeardown` clears
  notification observers and the NSEvent monitor, not the bridge callbacks), and
  its surface id now resolves to the woken view — so a runtime callback landing
  late is a real crossover risk, guarded only by identity. Drives every reachable
  closure on the OLD view (`onCloseRequest`, `onTitleChange`,
  `onDesktopNotification`, `onSplitAction`, `onNewTab`, `onCloseTab`) and asserts
  all are inert: the action closures return false, no `onSurfacesClosed`, no
  `onTabRemoved`, no zmx kill, tab count / leaf identity / custom title / unseen
  dot / `pendingCloseConfirmation` all unchanged. So no code-audit-only gap — the
  bridge closures were a cheap enough seam to test directly.
- Test-design note (why no TestClock here): the queue's per-view Tasks only run at
  a suspension point, so a fully SYNCHRONOUS test keeps every entry pending for its
  whole duration. That IS the wedged-pty case ("probe never resolves") and needs no
  clock, no probe double, and no new injection seam on `GhosttyRuntime`. Deliberately
  did NOT add a queue-injection parameter to `GhosttyRuntime.init` for this.
- Cycle-3's headless caveat still holds: `createSurface()` needs `runtime.app`, so
  `view.surface` is nil in unit tests. Surface liveness/free remains pinned in
  `SurfaceTeardownQueueTests` via the injected probe/free; this suite pins the
  bookkeeping and callback routing around it.
- `WakeWhileTeardownPendingTests` + `HibernationTeardownTests` +
  `SurfaceTeardownQueueTests` → exit 0, totalTestCount 14, passed 14, failed 0.
- Full bundle `-only-testing:supacodeTerminalTests` → 419 tests, 417 passed,
  2 failed: the same known pre-existing `GhosttyRuntimeBundledOverridesTests`
  failures as cycles 1–3.
- `make check` exit 0 (same 6 unrelated swift-format drift files reverted). No
  `make build-app` needed — no production code changed this cycle.

### GREEN (cycle 5 — behavior C: every close goes through the queue)

- **Placement fix, not per-site conversion.** `GhosttySurfaceView.closeSurface()`
  itself now hands off (`runtime.surfaceTeardownQueue.handOff(self)`) and does no
  freeing at all, so all 9 remaining `WorktreeTerminalState` call sites plus any
  future one are safe by default (decision 3). `performDeferredFree()` is the only
  real free; `rg ghostty_surface_free supacode/` shows exactly two callers —
  `performDeferredFree()` and the deinit-only `freeSurfaceInline()`.
- **Per-call-site table** (all in `WorktreeTerminalState`; all converted *by
  placement*, i.e. the line is unchanged and now defers):

  | site | path | semantics preserved |
  | --- | --- | --- |
  | :1335 | `performSplitAction` insert failure | `discardSurfaceBookkeeping` still runs; no session kill (never had one) |
  | :1403 | `closeAllSurfaces` | bookkeeping + `onSurfacesClosed` (incl. dormant ids) unchanged; kills done by callers off `allSurfaceIDs`, untouched |
  | :1990 | `createRestorationSplit` failure | `discardSurfaceBookkeeping` unchanged; no session kill |
  | :2946 | `removeTree` (tab close) | `cleanupSurfaceState` per leaf, then `killZmxSessions(includeRemote: true)` — still fires (pinned by test) |
  | :3364 | `replaceUnexpectedZmxSurface` success | **only exception**: `closeSurface(killAttachClient: false)` — see below |
  | :3375 / :3396 / :3404 | reattach failure / `closeSurfaceAndUpdateTabs` early-outs | bookkeeping + conditional `killZmxSessions(killZmxSession:)` unchanged |
  | :3416 | `closeSurfaceAndUpdateTabs` main path | focus target, tree removal, `cleanupSurfaceState`, conditional session kill — all unchanged and still ordered before/after exactly as before |
  | :3731 | `performHibernation` | already `handOff` since cycle 2; left explicit |

- **Session-kill semantics are untouched everywhere.** The queue only ever kills
  the attach CLIENT; `killZmxSessions` still owns the SESSION. They are
  orthogonal, so no call site needed reordering — verified by reading each site and
  pinned for tab close via the `terminal_persistence_session_killed` analytics
  event.
- **The one real hazard found by the audit:** `replaceUnexpectedZmxSurface` creates
  the replacement surface *under the same surface id* (same zmx session) BEFORE
  closing the old view. A hand-off there would `pgrep -f "zmx attach <session>"`
  and kill the REPLACEMENT's freshly spawned client — binding 8's hazard reached by
  ordering instead of by retry. Fix: `handOff(_:killAttachClient:)` /
  `closeSurface(killAttachClient:)`, default `true`, `false` at that one site (the
  old child already exited, so there is nothing to unblock). Rejected alternative:
  auto-skip the kill when `hasProcessExited` is already true — it silently couples
  the kill to a probe that returns `true` for every headless test view, and would
  have made the existing kill tests vacuous.
- **deinit decision (documented, deliberate):** `isolated deinit` must NOT hand
  off — the queue retains the view, and retaining `self` inside `deinit` is
  resurrection. So `deinit` calls a new private `freeSurfaceInline()`: the old
  inline-free body, plus a SupaLogger **error** when `surface != nil`, because
  reaching there with a live surface now means an owner released the view without
  ever calling `closeSurface()` (a bug, and the only path that can still block the
  main actor). In the normal flow the queue is the last owner and frees via
  `performDeferredFree()`, so `deinit` sees `surface == nil` and does nothing. No
  test: the only observable is a log line, and the "owners hand off first" premise
  is already pinned by the weak-ref ownership assertions in all four suites.
- Re-entrancy checked: `handOff` → `prepareForDeferredTeardown()` never calls
  `closeSurface()`; a second `closeSurface()` hits the `isTeardownDeferred` warning
  guard, and `handOff` is idempotent by view identity anyway. `unregisterSurface`
  still happens at hand-off (decision 4), now for close as well as hibernation.
- New suite `CloseTeardownTests`
  (`supacodeTests/WorktreeTerminalManagerCloseTeardownTests.swift`), 3 tests:
  - `closingATabHandsEveryLeafToTheTeardownQueue` — RED first
    (`queue.pendingCount → 0) == 2`, i.e. `closeTab` freed both leaves inline).
    Split tab → `closeTab`: both leaves alive (weak refs, checked after the
    `autoreleasepool` drains), pending at `.killRequested`, `pendingSurfaceIDs`
    matches, tab gone, `onTabClosed` fired once, session kill still requested.
    Trap hit on the first run: holding the views in a local array made the weak
    assertion vacuous — the stage check moved inside the pool, ownership check
    outside it.
  - `closingAllSurfacesHandsEveryLiveSurfaceToTheTeardownQueue` — the quit /
    worktree-teardown path, two tabs, same ownership assertions.
  - `reattachingAnExitedZmxSurfaceNeverKillsTheAttachClient` — drives the real
    reattach (`bridge.closeSurface(processAlive: false)` + an idle session in the
    injected listing), then asserts NO shell command so much as mentions the
    session id. Needs a runtime built inside `withDependencies` with a spying
    `shellClient.run` (the queue resolves the shell at construction, binding 13),
    and must DRAIN the view's teardown Task first — without that drain the test
    passed under the mutation, i.e. it was vacuous.
- **Mutation-verified:** `killAttachClient: false` → `true` at :3364 →
  `reattachingAnExitedZmxSurfaceNeverKillsTheAttachClient` FAILS (`commands`
  contains the session pattern). Reverted. The centralization itself was verified
  by its RED run.
- `CloseTeardownTests` + `HibernationTeardownTests` + `SurfaceTeardownQueueTests`
  + `WakeWhileTeardownPendingTests` → exit 0, totalTestCount 17, passed 17,
  failed 0.
- Full bundle `-only-testing:supacodeTerminalTests` → 422 tests, 420 passed,
  2 failed: the same known pre-existing `GhosttyRuntimeBundledOverridesTests`
  failures as cycles 1–4.
- `make check` exit 0 (same 6 unrelated swift-format drift files reverted).
  `make build-app` succeeded.
- Remaining (cycles 6–7): happy-path no-leak proof across a whole tab, and app
  quit abandoning pending teardowns (the `view → runtime → queue → view` cycle
  from cycle 2 now also keeps closed tabs' surfaces alive until they resolve).
### Cycle 6 (behavior D — happy-path no-leak) — green

- New suite `HappyPathTeardownTests`
  (`supacodeTests/WorktreeTerminalManagerHappyPathTeardownTests.swift`), 3 tests
  driving the REAL close/hibernate paths with only the queue's edges doubled
  (ShellSpy / ProbeSpy / FreeSpy / TestClock; `GhosttyRuntime.init` gained an
  optional `surfaceTeardownQueue` injection param for exactly this):
  - close multi-leaf tab, healthy probe → every surface freed EXACTLY once,
    pending/leaked/teardownTasks all empty, views deallocated (weak refs nil).
  - same proof for hibernation, plus dormant entry + layout intact after frees.
  - `dormantLayoutIsCapturedBeforeSurfaceHandOff` — wedged probe; agents source
    derived from the LIVE tree pins that `captureLayoutNode` runs while the tree
    still exists. MUTATION-VERIFIED: moving capture after `trees.removeValue`
    fails the test (`agents.keys → []`); reverted.
- Production fix found by the dealloc assertions: `GhosttySurfaceView.moveFocus`
  retry Tasks captured the view STRONGLY through real-clock delays (~0.75s),
  extending surface lifetime past teardown. Now `[weak view, weak previous]` —
  a delayed focus retry can no longer resurrect/retain a torn-down surface.
- `SurfaceTeardownQueue.teardownTaskCount` added: resolved surfaces must drop
  their Task (asserted 0 after drain — no accumulation over a long session).
- Full bundle: 425 tests, 423 passed, 2 failed = the known pre-existing
  `GhosttyRuntimeBundledOverridesTests` pair. `make check` clean (6 known drift
  files reverted). `make build-app` succeeded.

### Cycle 7 (behavior E — quit abandons pending) — audit, no code

- `applicationWillTerminate` (supacode/App/supacodeApp.swift:55) does layout
  saves only: `cancelPendingLayoutSaves` → `saveAllLayoutSnapshots` →
  `rememberSelectedWorktreeZoomOnQuit`. It never calls `closeAllSurfaces`,
  never touches `SurfaceTeardownQueue`, never frees a surface — quit already
  abandons pending teardowns (decision 5). Nothing to change.
- Pending teardown Tasks are ordinary Tasks; process exit discards them. No
  atexit/deinit hook awaits them, so they can neither keep the app alive nor
  crash at exit.
- The quit-adjacent teardown path that DOES run in-process
  (`closeAllSurfaces`, used by worktree removal) is already pinned by
  `CloseTeardownTests/closingAllSurfacesHandsEveryLiveSurfaceToTheTeardownQueue`:
  with a never-resolving teardown it returns synchronously, all views pending,
  none freed — i.e. no path drains the queue on the caller's turn.
- No test added: pinning "AppDelegate doesn't call X" would need NSApplication
  scaffolding for a tautology; the reachable behavior is covered above.

## Final review synthesis (code-critic + grug-architect + product-owner)

Consensus: deadlock fix correct; ONE regression blocker + majors. Fix round:

- **F (new behavior, blocker):** surfaces with NO zmx attach client (usesZmx
  false / bypassZmx script tabs) must still have their child terminated and
  their surface freed. Policy: no kill mechanism ⇒ after the poll bound, FREE
  anyway (restores pre-branch semantics: pty close SIGHUPs the child; freeing
  a healthy live child is fine — only a WEDGED reader hangs, and leak-on-
  timeout is only earned when a kill was actually attempted). Leak stays
  zmx-only. Test: non-zmx close → freed, leakedCount 0, no pgrep/pkill run.
- **M1:** thread processAlive through to shouldHandleAsUnexpectedZmxClose;
  guard !processAlive before the reattach branch.
- **M2:** DELETE the pkill -f fallback (no client found ⇒ nothing to EOF;
  fallback is pure wake-race risk).
- **M3:** passwordInput.didSet and updateScreenObservers become inert when
  isTeardownDeferred (leaked view must never re-enable SecureInput / re-add
  observers).
- **Cancellation limbo:** awaitExitThenFree catch → leak(key), not return.
- **Simplify:** delete Stage/Entry — pending: [ObjectIdentifier:
  GhosttySurfaceView]; stage asserts become isPending. Rename leakedWarningCap
  → leakedLogEscalationThreshold. freeSurfaceInline = log + unregister +
  performDeferredFree (single free body). Strip "(binding N)" citations,
  keep the prose reasons. Fix stale teardownTasks comment. Dead write in
  performFree.
- **Observability:** surface_teardown_freed event (denominator); leak event
  gains reason ("wedged" vs "no_client") + used_zmx + trigger; counter/event
  when freeSurfaceInline runs with a live surface (the residual deadlock
  path); slow-free becomes analytics event. Poll bound 2s → 10s.
- **Deferred (follow-ups, not this branch):** leak-threshold user notice;
  deinit adopt(surface:bridge:) hand-off; extract shared test spies; focus-
  lands-after-late-window-attach test.
- **Ship gate (manual, cj):** dogfood hibernate → wake → re-hibernate → close
  + stop-script on a real repo; deliberately wedged pty. Confirms SIGTERM'd
  attach client leaves session cleanly re-attachable.

### Fix round items 6-7 (simplification + observability)

- **Stale tests (found while verifying, `797879d1`):** three
  `WorktreeTerminalManagerTests` unexpected-close tests still sent ghostty's
  payload as `processAlive: true` and waited on a zmx probe that M1's gate no
  longer runs (`Timed out waiting for zmx list probe call`). They model a dead
  attach client under a surviving session, so the payload is child-gone. These
  failed at HEAD before item 6 — confirmed by stashing.
- **Item 6 (`53ee292d`):** `Stage`/`Entry` deleted (nothing branched on the
  stage; `.freed` was written to a slot cleared on the next line) — `pending` is
  now `[ObjectIdentifier: GhosttySurfaceView]` and tests use `isPending(_:)`.
  `leakedWarningCap` → `leakedLogEscalationThreshold`. `freeSurfaceInline` is
  log + unregister + `performDeferredFree()` (one free body). `teardownTasks`
  comment no longer claims quit abandons them. Plan citations
  ("(binding N)", "(decision N)", "(constraint N)") stripped from the queue, the
  view, `GhosttyRuntime`, and the teardown tests; prose reasons kept.
- **Item 7:** `surface_teardown_freed` (`used_zmx`) on every deferred free — the
  leak-rate denominator, asserted in
  `pollingFreesTheSurfaceOnceTheProcessHasExited`. Slow free (>250ms) now emits
  `surface_teardown_slow_free` (`stall_ms`, `used_zmx`) alongside the warning.
  No `no_client_kill_possible` leak reason exists BY DESIGN: item 1 frees a
  non-zmx surface on poll expiry, so only `wedged` / `cancelled` can leak —
  documented on `leak(_:reason:)`. `freeSurfaceInline` reports
  `surface_freed_inline_at_deinit` through
  `SurfaceTeardownQueue.recordInlineFreeAtDeinit(surfaceID:)` (+ a counter):
  `deinit` cannot resolve a `@Dependency` without resurrecting `self`, and the
  queue already owns the analytics client for this path. Poll bound 2s → 10s
  (200 × 50ms): a busy shell can take seconds to unwind, and the outcomes are
  asymmetric — waiting costs one Task, giving up costs a retained surface. Test
  helper `advance` bound raised 200 → 400 ticks to stay above the poll bound.
- **Verified:** `make test -only-testing:supacodeTerminalTests` →
  `totalTestCount: 429, passed: 427, failed: 2` (the two known pre-existing
  `GhosttyRuntimeBundledOverridesTests` color failures). `make check`,
  `make build-app` green.
