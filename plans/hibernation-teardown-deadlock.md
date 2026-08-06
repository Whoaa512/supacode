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

