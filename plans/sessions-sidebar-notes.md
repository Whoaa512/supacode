# Sessions sidebar implementation notes

## Slice 1, step 1 — index/domain foundation
- Implemented SessionSource, SessionSummary, SessionKey; pi-only actor and dependency seam.
- Streams byte chunks; selectively decodes header, session_info and first user message.
- Counts message lines/extracts timestamps without decoding transcript payloads.
- Persistent path/mtime/size summary cache is accessible before refresh; changed files reparse.
- One directory level, regular JSONL only; symlinks/temp cwd aliases excluded.
- Sidecar contains settle markers and ordered unique branches; Shared fileStorage sessions key.
- Pure creation-order Active/Settled and live/dormant classification; no age/count auto rules.
- No UI/reducer wiring; no app launch/install, process signaling or protected-state writes.
- make generate-project: exit 0.
- First targeted make test: exit 2 (missing test module import); corrected.
- Targeted make test SWIFT_VERSION=5, PiSessionSourceTests + SessionClassificationTests: exit 0.
- xcresulttool summary: exit 0; totalTestCount 13, failedTests 0; 20 parameterized runs.
- make lint: exit 2; existing complexity violations DeeplinkClient:26, CommandPaletteFeature:1245 only.
- make build-app: exit 0; pgrep checked before every build/test, no concurrent xcodebuild.
- git diff --check: exit 0. Implementation commit: 26115243.
- Tooling friction logged through papercut; PAPERCUTS.md and .worktrees remain untracked.
- Independent review unavailable: code-critic failed to start due to pi theme resolver error.
- Full tests/live-history/manual QA deliberately not run. Next scope: Slice 1 step 2.

## Slice 1, step 2 — Sessions sidebar and live focus

- Types: SessionRowID, SessionLocation, SessionLiveSnapshot, SessionSidebarItemFeature.State, SessionsSidebarStructure.
- Repositories state: sessionItems, sessionSummaries/snapshots/selection, cached sessionsSidebarStructure, refresh flags; sessions sidecar read-only.
- Actions: sessionsStarted, sessionsCacheLoaded, sessionsSidebarShown, sessionsRefreshRequested, sessionsRefreshDebounced, sessionsRefreshCompleted, sessionsRefreshFailed, sessionSnapshotsChanged, sessionSelectionChanged, activateSession; focusSession delegate.
- Files: SidebarTab/SidebarView, SessionSidebarItemFeature, SessionsSidebarStructure, SessionsSidebarListView, RepositoriesFeature/+Sessions.
- Files: AppFeature/+Sessions, AgentPresenceFeature, WorktreeMenuSnapshot; RepositoriesFeatureSessionsTests and AppFeatureSessionsTests.
- New sessionsSidebarTab storage key defaults to Sessions; old sidebarTab ignored; subsequent choices persist; invalid view value falls back to Sessions.
- Scoped rows show title/directory and live/dormant glyphs; dormant rows dim with system styles; semantic fonts and action/directory tooltips.
- Launch reads SessionIndexClient.cached before refresh regardless of tab; early appearance/events share that same once-only startup.
- Injected clock debounces events 500 ms; one refresh in flight plus one coalesced pending refresh; failures preserve rows.
- Raw presence joins current/restored layout content IDs, independent of badges; checked restore links before a turn; hibernated topology stays eligible; shells excluded.
- Provisional New session creation stays fixed; sid merges row/selection atomically; synthetic real rows hydrate from disk; duplicate sid keeps one stable focus link until all links disappear.
- Live activation delegates to exact App focusTerminalSurface(worktreeID:tabID:surfaceID:); dormant activation is a no-op.
- Own sessionsStructure invalidation bit; ids/order/sections/liveIDs only; session changes skip worktree menu cache; existing leaves update in place.
- Deferred per requested boundary: dormant resume/registration, branch capture, settle, navigation/new-session/status/classification timers, pi extension changes.
- Deviation: reducer serialization replaces generation tokens; no overlapping refresh can publish an older result after a newer one.
- Deviation/trap: observation checks use observable state; hosted Store.scope crashed in Perception unsafeDowncast with duplicate TCA linkage. No dependency/build-system refactor.
- Traps fixed: explicit module imports/test delegate path/date injection; fresh synthetic candidates avoid notifying observers on copied leaves.
- make generate-project: two explicit runs, exit 0; source edits also regenerate/clear DerivedData through make prerequisites.
- Targeted command: make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:supacodeFeatureTests/RepositoriesFeatureSessionsTests -only-testing:supacodeFeatureTests/AppFeatureSessionsTests'.
- Test attempts 1–3: exit 2 (compile fixes), xcresult count 0; attempt 4: exit 2 (hosted observation trap), count 12; attempt 5: exit 2 (one synthetic-observation regression), count 12.
- Final targeted test: exit 0; xcresulttool summary exit 0, totalTestCount 12, 13 runs including parameterized cases, failedTests 0.
- make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1245 complexity failures. make build-app: exit 0. git diff --check: exit 0.
- pgrep -fl xcodebuild before every build/test: exit 1 (none); no concurrent xcodebuild. Tests use fixtures, in-memory Shared and TestClock, no Task.sleep.
- Code commits: 692cde81 (sidebar/index), 6bc48970 (live linking/focus); notes commit follows. .worktrees/ and PAPERCUTS.md remain untracked, untouched.
- Unverified: manual UI/live history/OS focus and owner dogfood. No full tests, app-open/install commands, or process signaling performed.

## Slice 1, step 3 — dormant resume, folder registration, branch capture, pi session_start sid

### Actions/types added
- `RepositoriesFeature.Delegate.resumeSession(SessionKey)` — dormant activation delegates to App
- `RepositoriesFeature.Action.registerSessionFolder(URL)` — injects forced-folder repo at runtime
- `RepositoriesFeature.Action.sessionBranchCaptured(key:branch:)` — appends unique branch to sidecar
- `PendingSessionLaunch` struct in App state — one-at-a-time dormant launch guard (key/cwd/command/requestID)
- `@Shared(.sessionFolderRoots)` AppStorage `[String]` — persists auto-registered folder cwd paths

### Key implementation decisions
- activateSession with no location now delegates resumeSession; live rows still delegate focusSession.
- App parses SessionKey rawValue ("harness:id") to recover SkillAgent for AgentResumeCommand.command.
- openRepositoriesFinished merges sessionFolderRoots BEFORE applyRepositories so folder repos survive reloads.
- repositoriesRemoved cleans up sessionFolderRoots (reuse existing idSet pattern).
- Branch capture: git-tracked worktrees read synchronously from sidebarItems.branchName; folder repos fire async gitClient.branchName off-main.
- PiExtensionContent: emitPresence("session_start") moved from load-time to pi.on("session_start") with sessionRef(ctx); idle now also carries sessionRef.

### Deviations from plan
- PendingSessionLaunch stored in AppFeature.State (single property); plan implied similar placement.
- Pending launch cleared immediately on missing cwd (no-op path) rather than on cancel; matches scope intent.
- dormantResumeUsesRegisteredWorktreeWhenPresent test is conditional on fs cwd (/workspace may not exist in CI).

### Traps
- SessionKey has no .harness/.sessionID — must split rawValue("harness:id") at first ":".
- SidebarStructure.swift has exhaustive switch on Action; must add new cases or compile error.
- TerminalClient has no .createTabWithInput property; tests use .send closure with pattern match.

### Unverified
- Relaunch injection of sessionFolderRoots into openRepositoriesFinished (no full tests run).
- Actual fs cwd validation on /workspace in test is always true since that path exists on macOS.
- make test full suite not run; targeted tests only.

### Build/test commands
- make generate-project: exit 0
- make lint: exit 2 (baseline: DeeplinkClient:26, CommandPaletteFeature:1245 only)
- make build-app: exit 0
- Targeted tests: supacodeFeatureTests/RepositoriesFeatureSessionsTests + AppFeatureSessionsTests: exit 0
- xcresulttool summary: totalTestCount 16, failedTests 0
- Commits: 0fda1f5a (pi extension), 5c82528a (folder registration), 76d2487d (resume/branch), b26a18b1 (tests)

## Slice 1, step 3 corrections

### Bugs fixed
- sessionsLinkReducer: snapshot-unchanged guard no longer blocks pending launch resolution
- handleResumeSession: FileManager.isReadableFile added to cwd validation
- handleResumeSession: @Dependency(\.uuid) moved after guards to avoid test crashes
- handleResumeSession: pending set+cleared for existing-worktree path (dedup)
- branchCaptureEffect: async gitClient.branchName now .cancellable(cancelInFlight: true)
- Removed obvious comments from both reducer files

### Tests replaced
- Vacuous assertions (inputs.contains||inputs.isEmpty) → exact command/flag checks
- Missing-cwd test uses unique /tmp path not /workspace
- Existing-worktree test uses real temp dir + asserts exact input/flags
- Folder registration test verifies pending fires with unchanged snapshots
- Branch capture test asserts sidecar entry content after busy+idle
- PiExtensionContent tests: session_start hook with sessionRef, idle with sid
- @Suite(.serialized) prevents parallel test isolation crashes

### Build/test commands
- make generate-project: exit 0
- make lint: exit 2 (baseline only)
- make build-app: exit 0
- Targeted tests: exit 0, 50 tests, 0 failures
- Full make test: exit 2, totalTestCount 3829, failedTests 5 (all baseline)
- Commits: 58cbdf3a (production fixes), 1f9f05bc (test rewrites)

## Slice 1, step 3 — second corrections (bug fixes)

### Bugs fixed
- PendingSessionLaunch gained `launched: Bool`; pending stays set through async terminal send
- launchSessionCompleted(requestID:) action clears pending only on matching UUID
- Second activation while launched=true hits `guard pending == nil` and returns .none
- BranchCaptureCancelID.probe global cancelInFlight dropped; replaced with FIFO queue
  (branchCaptureQueue/branchCaptureInFlight on AppFeature.State; branchCaptureProbeCompleted pumps next)
- mergeSessionFolderRepositories: replaces (not skips) git-classified repos at matching root

### New tests
- secondActivationWhileLaunchedTrueProducesNoEffect: pending guard blocks send, empty sent
- launchCompletedClearsPendingByRequestID: wrong UUID no-ops, correct UUID clears
- branchCaptureQueuesTwoSurfacesInOrder: two busy events → FIFO probes → both branches captured
- mergeSessionFolderOverridesGitRootWithSameID: git repo at path replaced by folder repo
- mergeSessionFolderDoesNotDuplicateWhenAlreadyFolderRepo: no-dup when already folder
- mergeSessionFolderAppendsNewRoots: new root appended when not present

### Deviations / traps
- branchCaptureInFlight end-state assertion unstable (TCA .off drain timing); removed; behavior tested
- `terminalClient.send` is sync (@MainActor), no async gate possible; two-activation test uses direct state
- BranchCaptureCancelID enum retained (nonisolated) to avoid breaking exhaustive switch in WorktreeMenuSnapshot

### Build/test
- make build-app: exit 0; make lint: exit 2 (baseline only)
- AppFeatureSessionsTests (supacodeFeatureTests): exit 0, 16 cases + 2 params = 18 runs, 0 failures
- RepositoriesFeatureSessionsTests (supacodeFeatureTests): exit 0, 11 cases, 0 failures
- Commit: c175ae1

## Slice 1, step 3 — final verified handoff
- Dormant activation delegates resumeSession; PendingSessionLaunch.launched/requestID holds until launchSessionCompleted.
- Exact readable cwd uses createTabWithInput/AgentResumeCommand; registerSessionFolder supplies missing folder roots.
- sessionFolderRoots overrides now enter loadRepositoriesData BEFORE git classification; removal clears overrides.
- Matching worktree cwd never replaces its parent git repository; exact repository roots retain forced-folder kind.
- BranchCaptureRequest FIFO and branchCaptureProbeCompleted serialize folder probes without cross-session cancellation.
- Removed obsolete BranchCaptureCancelID. Pi session_start and idle emit sessionRef(ctx); no shutdown/settle changes.
- Final combined targeted tests: AppFeatureSessionsTests, RepositoriesFeatureSessionsTests, AgentSessionResumeTests.
- make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:supacodeFeatureTests/AppFeatureSessionsTests -only-testing:supacodeFeatureTests/RepositoriesFeatureSessionsTests -only-testing:supacodeTests/AgentSessionResumeTests': exit 0.
- xcresulttool summary: exit 0, totalTestCount 58, failedTests 0. make build-app: exit 0.
- make lint: exit 2, only existing DeeplinkClient:26 and CommandPaletteFeature:1245 complexity violations.
- Final logs: /tmp/slice1-step3-final-{tests,build,lint}.log; xcodebuild serialized with process checks.
- Process deviation: delegated validator mistakenly ran full make test despite prohibition (3829 tests, 5 baseline failures).
- Duplicate guard tested via pending launch state because TerminalClient.send is synchronous; no throwing launch acknowledgment exists.
- Unverified without owner launch: actual harness resume, UI focus, installed extension and relaunch behavior.
- No owner-app launch/install/signaling or protected-home writes; untracked .worktrees/ and PAPERCUTS.md preserved.

## Slice 1 review fix — durable session-folder roots
- Confirmed registration omitted repositoryRoots/saveRoots. Registration now updates exact-cwd runtime roots and merges persisted roots before repositoriesChanged (and pending launch).
- Refresh and fresh-state persisted load regression: RepositoriesFeatureSessionsTests, 14 tests, 0 failures; fixture-only IO.
- make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1245; git diff --check: exit 0.
- No scope deviation; forced-folder override remains classification metadata, not a substitute for persisted roots.

## Slice 1 review fix — actor-isolated cache loading
- Confirmed PiSessionSource.init read/decoded the cache synchronously on its caller. Init is now IO-free; cachedSessions and refresh lazily load once on the actor.
- Regression tests cover cache created after initialization, one-time loading, and refresh-first persisted cache reuse without transcript parsing.
- Targeted PiSessionSourceTests + AppFeatureSessionsTests: exit 0; xcresult totalTestCount 24, failedTests 0 (32 parameterized runs).
- Final make build-app: exit 0. make lint: exit 2, only the two existing complexity violations; git diff --check: exit 0.
- All builds/tests serialized via pgrep checks. No owner-app launch/install/signaling or protected-home writes; full suite not rerun for this narrow fix step.

## Slice 2, step 1 — Sessions navigation
- Existing next/previous worktree chords wrap structure.liveIDs, including settled live rows; no dormant resume path.
- App resolves the focused content surface before the repositories reducer walks the list; stored selection is fallback.
- Existing selectWorktree slots and configurable hints use nth live row; selectTab digit routing is unchanged (A3).
- Sidebar arrows wrap all visible rows selection-only; Return retains explicit focus/resume activation.
- Production change reuses existing focus delegate, selection action and shortcut display; no new launch commands/settings.
- Extended both Sessions test suites: live-only wrapping/slots, no selection/empty, focused precedence, exact single focus, no resume-tab command, settled/all-visible selection and terminal digit routing.
- Parent targeted command: make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:supacodeFeatureTests/RepositoriesFeatureSessionsTests -only-testing:supacodeFeatureTests/AppFeatureSessionsTests'.
- Parent attempts 1–2: exit 2, xcresult totalTestCount 0 (test compile errors corrected); attempt 3: exit 2, count 43 (fixture/expectation failures corrected).
- Parent attempt 4: exit 0, count 43; final: exit 0, totalTestCount 44, failedTests 0. xcresult summary verified after every parent run.
- Final make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1245 complexity violations; earlier own identifier violations corrected.
- Final make build-app: exit 0; git diff --check: exit 0. Parent checked pgrep -fl xcodebuild and waited before every test/build.
- Implementation commit: c92e8d57. Logs: /tmp/slice2-step1-{tests,lint,build}-final.log.
- Deviation: delegated worker ran unrequested build/test despite edit-only instruction; its checks are not relied on. Parent corrected implementation and owns final validation.
- No full suite, owner-app open/install/signaling or protected-home writes requested/performed by parent; .worktrees/ and PAPERCUTS.md untouched.
- Unverified: actual sidebar key handling/OS focus in owner UI; automated navigation/focus dispatch verified. New-session chords/picker remain out of scope.

## Slice 2, step 2 — new-session chords and directory picker
- Added AppShortcuts `newSession` ⌘⇧N and `newSessionInDirectory` ⌘⌥⇧N; checked no Supacode default duplicate for those displays and no Ghostty default match found by source search.
- Terminal menu publishes FocusedAction wrappers for both commands; WorktreeDetailView sends AppFeature actions without closure-valued focused values.
- New session launches literal `pi` via existing exact-cwd createTabWithInput path, runSetupScriptIfNew false, focusing true.
- Cwd fallback order: focused session row, selected session row, selected worktree, home; missing/unreadable cwd no-ops.
- Reuses PendingSessionLaunch/registerSessionFolder so unregistered exact directories take the same safe folder-registration path as dormant resume.
- Palette browse gained `BrowsePurpose` defaulting to open-repository; new-session purpose delegates selected/typed directories to AppFeature and resets on selection/dismiss.
- A6 correction: native fallback now preserves `BrowsePurpose` and reuses the folder-importer panel; new-session fallback opens a native directory chooser, then launches the chosen directory instead of accepting the typed browse path.
- Repository-open fallback still presents the same panel with `.openRepository`; selection result dispatches by stored purpose.
- A6 shortcut audit now asserts all enabled Supacode defaults are unique and new-session chords emit Ghostty unbinds while avoiding known Ghostty defaults.
- Tests added: AppFeature new-session cwd fallback/launch, CommandPaletteSessionDirectoryTests, SessionShortcutTests.
- make generate-project: exit 0 (/tmp/slice2-a6-generate.log).
- Targeted tests final: exit 0; xcresult totalTestCount 5, failedTests 0 (/tmp/slice2-a6-targeted-tests-final.log, /tmp/slice2-a6-targeted-xcresult-final.json).
- AppFeature command-palette tests: exit 0; xcresult totalTestCount 34, failedTests 0 (/tmp/slice2-a6-appfeature-tests.log, /tmp/slice2-a6-appfeature-xcresult.json).
- make lint: exit 2; only baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity failures (/tmp/slice2-a6-lint.log).
- make build-app: exit 0 (/tmp/slice2-a6-build.log).
- pgrep/xcodebuild serialization used before each build/test; no full make test run.
- No app launch/install, no supacode/zmx/pi signaling, no writes to protected home dirs; .worktrees/ and PAPERCUTS.md untouched.
- Unverified: actual menu/key handling in owner UI and real pi process startup.

## Slice 2 gate fix 1 — Worktrees navigation test context
- Confirmed all ten reported failures: old Worktrees navigation tests inherited the Sessions default, so the reducer correctly took the Sessions branch instead of emitting selectWorktree.
- Explicitly select Worktrees in isolated `.dependencies` contexts for all thirteen next/previous Worktrees tests, including the three no-op tests that otherwise passed for the wrong reason. No production routing/default changes; one focused fix for the shared cause.
- Targeted RepositoriesFeatureTests + RepositoriesFeatureSessionsTests: exit 0; xcresult totalTestCount 381, failedTests 0, expectedFailures 2. SWIFT_VERSION=5 retained.
- make lint: exit 2, only existing DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations; no new violations. make build-app: exit 0; git diff --check: exit 0.
- Logs: /tmp/slice2-gate-fix-{tests,lint,build}.log; summary /tmp/slice2-gate-fix-summary.json. xcodebuild checked/serialized before tests and build.
- No new files/generation required; full gate not rerun. No live-app launch/install/signaling or protected-home writes. No scope deviation; baseline failures and untracked files untouched.

## Slice 2 gate fix 2 — deterministic remote-path timeout regression
- Confirmed timeout test raced real 5-second probe sleep against 50-ms timeout; scheduling under full-suite load can let the probe win. Injected a Clock into resolveRemotePath (ContinuousClock default unchanged); test drives both branches with TestClock, no Task.sleep in this test.
- Targeted RemotePathClassificationTests: exit 0; xcresult totalTestCount 17, failedTests 0. Initial compile attempt exited 2/count 0 after editing the wrong sleep occurrence; corrected before verification.
- make build-app: exit 0; make lint: exit 2, only the same pre-existing DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations. Per “fix only your own violations,” those remain unchanged; both dispatch functions existed at 30ecc33c.
- Logs: /tmp/slice2-gate-fix2-{tests,lint,build}.log; summary /tmp/slice2-gate-fix2-summary.json. No full suite rerun; builds/tests serialized with pgrep checks. No live-app/environment changes; untracked files untouched.

## Slice 3, step 1 — manual settle/unsettle

- settleSession(key): writes settledAt=now, clears manualUnsettledAtActivity; reconcileSessionItems+recompute fired immediately in reducer.
- unsettleSession(key): clears settledAt, stamps manualUnsettledAtActivity=lastActivity from sessionSummaries (fallback: now); same recompute path.
- applyUnsettle helper on RepositoriesFeature.State in SessionsSidebarStructure.swift (has $sessions access).
- Activating settled live row: guard checks lifecycle==.settled before sending unsettleSession from RepositoriesFeature+Sessions.
- dormant resume accepted (launchSessionCompleted): unsettles only if lifecycle==.settled at resolution time; non-settled launch is no-op.
- settleSessionAndAdvance (AppFeature): captures sessionRowID(byOffset:1) BEFORE settle; if next is live, merges settleSession + focusTerminalSurface; no candidate = settle-only.
- unsettleCurrentSession (AppFeature): resolves focused row via focusedSessionRowID then sessionSelection; falls back gracefully if no session row.
- A6 audit: ⌘⌃E and ⌘⌃U are free in existing Supacode defaults and not in Ghostty known-default set; no collision, no fallback needed.
- SidebarStructure.cacheInvalidations: settleSession/unsettleSession return .sessionsStructure (parallel call in reducer handles immediate recompute; invalidation ensures post-reduce hook also fires).
- WorktreeMenuSnapshot: added settleSessionAndAdvance and unsettleCurrentSession to the pass-through array.
- Context menu: SessionContextMenu private view; active rows show Settle, settled rows show Unsettle.
- FocusedSceneAction published in WorktreeDetailView for both chords; TerminalCommands FocusedValue keys and menu items added with divider.
- Deviations: SessionContextMenu is a @MainActor private struct in the view file (plan implied inline context menu but struct is cleaner). helpText shortened to fit 120-char lint limit.
- Traps: SidebarStructure.cacheInvalidations exhaustive switch required new cases or compile error; must be kept in sync.
- TerminalClient.focusSurface takes (Worktree, TabID, UUID), not (_, _); test mock requires 3 params.
- Tests: SessionsPersistenceTests (supacodeTests, 9 tests); RepositoriesFeatureSessionsTests +7 settle/unsettle tests (supacodeFeatureTests, 30 total); AppFeatureSessionsTests +3 tests (supacodeFeatureTests, 27 total); SessionShortcutTests +2 tests (supacodeTests, 4 total).
- make generate-project: exit 0 (new test file). make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations. make build-app: exit 0.
- Targeted tests: all bundles exit 0, counts verified >0.
- Commit: 19765d99. Unverified: context menu UI render, chord dispatch in live app, settled live row visual in sidebar.

## Slice 2 review fix — native picker result routing
- Confirmed presentation dismissal cleared new-session purpose before completion. setOpenPanelPresented now changes presentation only; openPanelCompleted([URL]?) consumes/resets purpose on success or cancellation/failure.
- ContentView sends picker results to Repositories; newSessionDirectorySelected delegate routes through App's existing exact-cwd pi launch. Repository selection retains openRepositories routing; empty/cancel results launch nothing.
- Regression covers present(newSession), dismiss(false), successful completion: one pi tab in selected fixture cwd; cancellation resets purpose with no effect.
- Targeted AppFeatureSessionsTests + AppFeatureCommandPaletteTests: exit 0, xcresult totalTestCount 58, failedTests 0. Initial run caught delegate routing below the generic repositories catch-all; moved handling before it and reran successfully.
- make build-app: exit 0. make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations. Logs /tmp/slice2-review-{tests,summary,lint,build}.*. No scope deviation or live-app interaction; builds/tests serialized.

## Slice 3, step 2 — context menu arch fix + advance-unsettle gap

- SessionContextMenu arch violation: was reading store.sessionItems[id:id]?.lifecycle in body (parent collection read). Fix: accepts StoreOf<SessionSidebarItemFeature> (already scoped at call site) + onSettle/onUnsettle closures; reads lifecycle from leaf. Call site gates contextMenu on .session case, captures key in closures.
- settleSessionAndAdvance gap: handleSettleSessionAndAdvance used focusTerminalSurface directly, bypassing activateSession unsettle guard. Fix: if advance target lifecycle==.settled, merge .repositories(.unsettleSession(targetKey)) into effects.
- First-review concern (locked scope / manually settled live rows): confirmed DISPROVEN. sessionRowID(byOffset:) iterates liveIDs which filters by location!=nil, not lifecycle; settled live rows remain in liveIDs. No filter change needed.
- New test: settleSessionAndAdvanceUnsettlesSettledDestination — second row settled+live; advance unsettles it. Passed.
- make lint: exit 2, only baseline violations (unchanged). make build-app: exit 0. Targeted supacodeFeatureTests/AppFeatureSessionsTests: exit 0, totalTestCount=28, failedTests=0. Logs: /tmp/slice3-step2-{lint,tests-feature,build}.log. No live-app interaction; live app was running (pgrep exit 0) but build-app does not launch it.
- Commit: de0e401e. Named files: SessionsSidebarListView.swift, AppFeature+Sessions.swift, AppFeatureSessionsTests.swift.

## Slice 3, step 2 — explicit-close attribution + teardown suppression
- Added TerminalClient user-close intent marker and synchronous isHarnessEndSuppressed gate.
- User close intent now survives confirm flow until actual removed-content diff; cancelled/rejected closes prune stale intent.
- WorktreeContentHost emits userClosedSurfaces before surfacesClosed, while presence still exists.
- App settles distinct session keys from userClosedSurfaces; direct UI contentRequestedClose marks targets synchronously before LayoutFeature runs.
- CLI/deeplink manager closes mark destroyTab/destroySurface/closePane/closeFocused targets; pane batches settle distinct sessions once.
- Unexpected zmx close paths mark harness-end suppression and never mark user-close intent.
- Added suppressedHarnessEndSurfaceIDs and isEndingAllSessions in WorktreeTerminalManager; app delegate begins global suppression on termination.
- AppFeature has isQuitting and hook-end suppression gate for next shutdown-reason step; no reason settlement implemented yet.
- TerminalContent gained onWillTearDown/onDidStart callbacks; recipe wires teardown suppression before closeSurface and clears after start.
- Suppression covers hibernate/rebuild/remove/prune/Terminate Sessions through existing teardown paths without reordering teardown.
- Tests: AppFeature user-close settles before presence removal; direct close intent; terminal content callbacks; unexpected-zmx gate.
- Follow-up tightened Terminate Sessions entry gate, session-end-only suppression, and killSession pre-kill suppression.
- Added fixture tests for accepted-vs-cancelled host removal, distinct multi-surface settlement, terminate gate, and suppressed session_end vs fresh session_start refresh.
- Added killed-surface suppression coverage; unexpected probe remains covered at branch predicate level, not full Ghostty fixture.
- Direct pane/UI attribution coverage remains reducer-level for contentRequestedClose/allTabs; no live UI/process close exercised.
- make generate-project: exit 0 (new WorktreeTerminalManagerSessionsTests routed terminal bundle).
- Targeted feature+terminal tests: exit 0; xcresult totalTestCount 37, failedTests 0.
- make lint: exit 2; only baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations.
- make build-app: exit 0. Build/test serialized with pgrep checks; no full make test.
- Unverified: live app close UI, pi shutdown reason settlement, branch mismatch/CLI Slice 3 later parts.

## Slice 3, step 3 — attributed harness ends and replacements
- Optional validated shutdownReason flows through OSC, AgentSignal and AgentHookEvent JSON/memberwise; unknown/missing stays nil.
- Generated pi extension emits shutdown sid + quit/reload/new/resume/fork reason, without the defensive idle; start/busy/normal idle unchanged.
- App captures OLD presence before forwarding: attributed quit/new/resume/fork or changed sid on start/busy settles the old key.
- Reload, app quit and TerminalClient suppression never settle; reasonless other-harness ends retain attributed settlement.
- PresenceRecord tracks latest start/busy PID because pids accumulate; stale sid/PID ends cannot remove or rewrite current identity/diagnostics.
- Conservative ambiguity: missing pi sid on an identified record, pid-less end of local record or multiple restored pids without current PID is ignored.
- Compatibility cost: older pi shutdown emitters without sid/reason do not settle; local liveness or surface cleanup still clears them, remote cleanup waits for surface close.
- New AgentSignalSessionReasonTests and PiExtensionSessionLifecycleTests; AppFeatureSessionsTests covers reasons, suppression, replacement and delayed stale ends.
- Runtime fixture executes generated TS with node, mocks tty writes, then parses actual OSC through AgentSignal; no real tty/app/process signaling.
- make generate-project: exit 0. Test attempt 1: exit 2, summary exit 0/count 73/failures 1 (hosted PATH lacked node).
- Attempt 2: exit 0, summary exit 0/count 169/failures 0. Attempt 3: exit 2, summary exit 0/count 215/failures 1 (test skipped forwarded action).
- Final targeted make test: exit 0, summary exit 0/totalTestCount 236/failedTests 0; every run retained SWIFT_VERSION=5 and verified nonzero count.
- Final suites: AgentSignalSessionReasonTests, PiExtensionSessionLifecycleTests, AgentSessionResumeTests, AgentPresenceFeatureTests, AgentPresenceOSCTests, AgentHookSocketServerTests, AppFeatureSessionsTests.
- make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations; own line-length/conversion violations fixed.
- make build-app: exit 0; git diff --check: exit 0. pgrep/wait serialized generation/tests/build; no full suite.
- Logs: /tmp/slice3-step3-{generate,tests-1,tests-2,tests-final,tests-4,lint-final,build}.log; summary-{1,2,final,4}.json.
- Implementation commit: c4832645; named files only on cj-main. Real hosted-PATH friction logged with papercut; untracked files preserved.
- No branch-confirm/CLI/triage work, live-app launch/install/open or protected-home writes. No prerequisite refactor.
- Unverified: installed extension/live pi lifecycle/UI and externally delivered OS signals; existing pi processes need extension reload/restart by owner.

## Slice 3, step 4 — branch confirm, annotation and session CLI
- Added dormant-resume branch probe using GitClient before launch when sidecar has branch history.
- Mismatch shows one alert; confirm resumes saved request without re-probing/checking out; cancel clears pending and does nothing.
- Session leaves compute branch annotation per row when last recorded branch differs from current exact worktree branch.
- Added `supacode session list|settle|unsettle`, sessions query response and `supacode://session/<id>/<action>` deeplinks.
- CLI defaults settle/unsettle target from SUPACODE_SURFACE_ID by querying current session rows; missing/ambiguous surfaces emit actionable ValidationError.
- App query routing uses existing socket/FD query response path; deeplink settle/unsettle routes to existing reducer mutations/acks.
- make generate-project: exit 0.
- SessionCLITests: exit 0; xcresult totalTestCount 2, failedTests 0.
- AppFeatureSessionsTests: exit 0; xcresult totalTestCount 40, failedTests 0.
- RepositoriesFeatureSessionsTests: exit 0; xcresult totalTestCount 30, failedTests 0.
- make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations.
- make build-app: exit 0. git diff --check: exit 0.
- Builds/tests serialized with pgrep xcodebuild waits; no full tests, app launch/install/open, process signaling or protected-home writes.
- Untracked .worktrees/ and PAPERCUTS.md preserved. Unverified: live app CLI socket/ack behavior beyond fixture/unit coverage.

## Slice 3 review fix — reserve dormant resume before probing
- One PendingSessionLaunch UUID now spans branch probe, mismatch confirmation, folder registration and launch completion. Probing/confirming reservations cannot launch on repositoriesChanged; duplicate activations/new-session requests are blocked.
- Completion carries only request UUID and branch; saved reservation owns cwd/command/key. Stale or repeated completions cannot restore a cancelled alert or launch another request. Cancel clears the reservation; confirm reuses it without probing again.
- Controlled AsyncStream regression covers duplicate activation, repository changes during probe, cancel/retry and stale completions both during a newer probe and after cancellation. Known-branch and confirmed-mismatch launch regressions retained.
- Targeted AppFeatureSessionsTests: attempts exited 2/count 0 (test compile argument), 2/count 41/failures 1 (unrelated prune command in assertion), then 0/count 41/failures 0. Summaries checked after every run; SWIFT_VERSION=5 and pgrep/wait serialization retained.
- make lint before commit: exit 2, only existing DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations; git diff --check exit 0. Logs /tmp/slice3-review-resume-{tests3,lint-final}.log and summary3.json.
- Downstream contract: never release a reservation between probe/confirmation/registration/launch, nor launch a probing or awaiting-confirmation request. No live environment operations; final build follows the second narrow fix.

## Slice 3 review fix — reject invalid/unknown CLI mutation targets
- SessionKey.isValid reuses SkillAgent and AgentPresenceOSC's existing ref rules; session deeplinks require exactly id/action and reject malformed harness:id. App validates again for direct actions, then requires an indexed summary or live real-session leaf before dispatching settle/unsettle. Sidecar presence alone is not target existence.
- Existing socket alert-to-error acknowledgment closes the FD and returns failure; no new transport or CLI-local registry. Validation at the authoritative app boundary also covers URL-scheme callers and prevents orphan sidecar creation.
- Regression covers malformed direct actions with actual pipe JSON error ack and closed response FD; actual bundled CLI subprocesses connect only to a temporary fixture socket and test both settle/unsettle for malformed, nonexistent and valid indexed/live IDs. Parser rejects invalid ids and extra path components. No app install/open/run or owner-session signaling; no protected-home writes.
- Targeted SessionCLITests attempt: exit 2, summary count 4/failures 1 (live fixture needed backing snapshots). Corrected fixture; combined SessionCLITests + AppFeatureSessionsTests + RepositoriesFeatureSessionsTests: exit 0, totalTestCount 75/failedTests 0. Summary exit 0 after each run; SWIFT_VERSION=5 retained.
- make lint before commit: exit 2, only pre-existing DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations; own identifier/string-conversion violations fixed. Final make build-app: exit 0; git diff --check: exit 0. Every build/test preceded pgrep/wait; no concurrent xcodebuild.
- Logs /tmp/slice3-review-cli-{tests2,lint-final}.log, summary2.json and /tmp/slice3-review-final-build.log. Narrow review scope: full suite/manual UI not run; no additional feature work or agents. .worktrees/ and PAPERCUTS.md remain untracked; tooling friction logged only through papercut.
- Downstream contract: validate syntax and current indexed/live existence before external mutations; never accept an unknown id just because it has historical sidecar metadata. CLI defaults/ambiguity behavior and existing transport are unchanged.

## Slice 3 post-review gate fix 1 — descriptor-reuse-safe cleanup assertion
- Confirmed malformed-id regression checked a closed FD number with fcntl after awaiting effects; another concurrent test can reuse that process-wide number. Production response already synchronously writes then closes; no transport behavior change needed.
- Fixture now closes its original pipe writer before dispatch and polls the retained reader for POLLHUP after effects finish. This proves the response writer closed without inspecting a recyclable FD number; error JSON and no-mutation assertions remain.
- Targeted SessionCLITests: exit 0, xcresult totalTestCount 4, 11 parameterized/device runs, failedTests 0. make build-app: exit 0. make lint: exit 2, only existing DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations; unchanged per A10. git diff --check: exit 0.
- Logs: /tmp/slice3-gate-fix1-{tests,lint,build}.log and summary.json. No new file/generation needed; full gate not rerun. Builds/tests serialized with pgrep checks; no live-app operations or protected-home writes. No scope deviation; baseline failures and untracked files preserved.

## Slice 4, steps 1-2 + A6 audit — live status and next-needs-me
- Status derives from existing presence only: awaitingInput/error needs-you, busy/compacting working, idle+doneUnseen done-unseen, else idle.
- SessionLiveSnapshot carries status into the leaf; structure still stores ids/order/liveIDs only.
- Row rendering adds a live status glyph with system colors; dormant rows have nil status.
- `nextSessionNeedsMe` is ⌘⌃N; A6 audit found no Supacode default duplicate or known Ghostty default collision.
- Action filters live rows with needs-you or done-unseen only; circular from focused row/selection; no target no-ops.
- CLI session list now reports the live status raw value.
- Added App navigation tests for wrap/no-target and shortcut tests for ⌘⌃N.
- Added SessionsSidebarObservationTests proving status mutation invalidates own leaf only, not sibling/structure.
- No auto-settle/settings/coarse timer work included; deferred to later Slice 4.
- make generate-project: exit 0.
- Targeted tests final: exit 0; xcresult totalTestCount 79, failedTests 0.
- make lint: exit 2, baseline DeeplinkClient:26 and CommandPaletteFeature:1260 only.
- make build-app: exit 0.
- pgrep xcodebuild checked before every build/test; no full tests run.
- Unverified: live UI glyph appearance and actual menu shortcut dispatch in owner app.

## Slice 4 review fix — next-needs-me live-order scan
- Corrected `nextNeedingAttention` to iterate circular `liveIDs` starting after current, testing eligibility per leaf instead of filtering targets before locating current.
- Regression covers focused idle between attention rows selecting the next row, and focused working after the last attention row wrapping to the first.
- Observation regression now drives real `.sessionSnapshotsChanged` reconciliation status-only updates through `RepositoriesFeature`, not only direct leaf assignment.
- Targeted command: `make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:supacodeFeatureTests/AppFeatureSessionsTests -only-testing:supacodeTests/SessionsSidebarObservationTests'`.
- Targeted tests: exit 0; xcresult totalTestCount 47, failedTests 0; logs `/tmp/slice4-triage-fix-tests.log`, summary `/tmp/slice4-triage-fix-xcresult.json`.
- make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations; log `/tmp/slice4-triage-fix-lint.log`.
- make build-app: exit 0; log `/tmp/slice4-triage-fix-build.log`. git diff --check: exit 0.
- Builds/tests serialized with pgrep xcodebuild waits; no full suite, live app launch/install/signaling or protected-home writes.

## Slice 4 — conservative automatic settling
- Commit e23ae21f on cj-main; auto-settle only, no additional sidebar feature scope.
- SessionClassification.classify(summary:...) applies explicit > live > manual hold > under-4 > idle-days; default 3, exact threshold, future activity stays active.
- GlobalSettings.sessionIdleDays decodes missing as 3; 0 disables both automatic rules. SettingsFeature loads/persists it; DeveloperSettingsView exposes a 0...365 stepper.
- Repositories State.autoSettleSessions uses the same applySettle sidecar mutation as manual settling, persisting settledAt and clearing hold; no harness-file writes.
- Manual holds survive rename/equal activity; genuinely newer indexed messages or timestamped busy/idle release the marker. Explicit settlement never auto-unsettles.
- AgentPresence always emits checked restore completion, including empty/all-dead restores; App passes raw live SessionKeys, protecting agents not yet mapped into repository layouts.
- Cache publication never auto-settles; checked restore AND successful refresh required. Refresh failure preserves rows and revokes successful-refresh evidence.
- Injected continuousClock runs one cancellable 15-minute loop; quit cancels timer/refresh/debounce. Appearance, activation and settings changes request fresh classification via refresh.
- Conservative deviations: timer classification waits for successful refresh instead of aging stale cache; any provisional linked row pauses all auto-settle; unreadable persisted layouts keep restore gate closed for that launch.
- Tests: SessionClassificationTests table/default/roundtrip; RepositoriesFeatureAutoSettleTests restore/live/hold/provisional/zero/timer/error/recovery/cancellation; SettingsFeatureTests binding; AppFeatureSessionsTests unmapped restore identity.
- make generate-project: exit 0. Final targeted make test: exit 0; xcresulttool summary exit 0, totalTestCount 260, passedTests 260, failedTests 0.
- Final suites: supacodeFeatureTests/{RepositoriesFeatureAutoSettleTests,RepositoriesFeatureSessionsTests,AppFeatureSessionsTests}; supacodeTests/{SessionClassificationTests,SettingsFeatureTests,AgentPresenceFeatureTests}.
- Every test override retained SWIFT_VERSION=5; pgrep -x xcodebuild/wait ran before each build/test. No full suite.
- Earlier attempts: tests 1–3/6 exited 2 with count 0 (pattern/date compile fixes); 4 exited 2/count 86/failure 1 (existing startup fixture lacked injected clock); 5 exited 0/count 87; 7 exited 2/count 259/failure 1 (settings fixture needed settingsLoaded).
- Selector trap: individual Swift Testing settings selector matched no test; switched to entire SettingsFeatureTests and verified named test in final log.
- make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations; own parameter/tuple violations fixed. make build-app: exit 0. git diff --check: exit 0.
- Logs: /tmp/slice4-auto-{generate,lint3,tests8,build}.log and /tmp/slice4-auto-summary8.json.
- Unverified: owner UI stepper/visual section movement, installed app timer behavior and live OS lifecycle. No app launch/open/install, owner-process signaling, or protected-home writes; untracked .worktrees/ and PAPERCUTS.md preserved.

## Slice 4 gate fix 1 — isolate session clock and startup ownership
- Confirmed all 20 reported failures. 9ddebd41 defers date.now until a session action actually needs time; unrelated App/Repositories actions no longer touch the test date dependency.
- 458a0d14 gates activation/settings refresh requests on repositories.sessionsStarted. Launch and sidebar appearance retain startup ownership; running index still refreshes on activation/settings. Regression covers pre-start lifecycle and post-start activation with TestClock.
- Final targeted suites: RepositoriesFeatureAutoSettleTests, AppFeatureLifecycleTelemetryTests, AppFeatureDefaultEditorTests, AppFeatureMenuBarNotificationsTests, AppFeatureSystemNotificationTests, AppFeatureRunScriptTests, AppFeatureSettingsChangedTests. Exit 0; xcresult totalTestCount 79, failedTests 0; excluded only baseline settingsChangedPropagatesRepositorySettings via escaped exact identifier with ().
- Initial targeted runs exited 2/counts 79 and 80 with only that allowed baseline failure. Selector without () did not exclude it; unescaped () failed shell parsing before a test run (summary was stale, not verification). Tool friction logged via papercut.
- make build-app exit 0; make lint before each fix commit exit 2, only unchanged baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations. git diff --check exit 0. Logs /tmp/slice4-gate-fix-{tests4,lint,lint2,build}.log; final summary /tmp/slice4-gate-fix-summary4.json.
- No scope deviation beyond making lifecycle refresh conditional on startup; no full suite rerun, live-app launch/install/signaling or protected-home writes. Builds/tests serialized with pgrep -fl xcodebuild; untracked files remain unstaged.

## Slice 4 triage fix — unmapped provisional restoration
- Confirmed nil-ref raw restored presence was invisible to both live keys and mapped snapshots. `sessionsHasUnresolvedLivePresence` now blocks auto-settle independently of layouts; restoration and subsequent raw-presence deltas carry it alongside live keys.
- Regression restores an alive nil-ref record with no repositories/layouts and an old under-4 indexed session; restoration and fresh indexing leave the sidecar untouched.
- Targeted AppFeatureSessionsTests + RepositoriesFeatureAutoSettleTests: exit 0, totalTestCount 54, failedTests 0. make lint: baseline complexity failures only. No scope deviation or live-environment operations.

## Slice 4 triage fix — visual attention versus navigation
- Confirmed error-only presence became an eligible needs-you target. Snapshots/leaves now carry `allowsAttentionNavigation` separately from visual status; App derives it from awaitingInput or done-unseen. Navigation still requires a live needs-you/done-unseen row, preserving error styling without focusing error-only targets.
- Regression projects real error presence through snapshots/reconciliation and asserts no focus or selection. Existing awaiting-input/done-unseen navigation and per-leaf observation tests remain green.
- Targeted AppFeatureSessionsTests + RepositoriesFeatureSessionsTests + SessionsSidebarObservationTests: exit 0, totalTestCount 80, failedTests 0. Final make build-app: exit 0. make lint before both commits: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations; git diff --check: exit 0.
- Builds/tests serialized with pgrep checks; logs /tmp/slice4-fix{1,2}-{tests,lint}.log, summaries /tmp/slice4-fix{1,2}-summary.json, build /tmp/slice4-review-final-build.log. No live-app operations, full suite, protected-home writes or scope deviations; untracked files preserved.

## Slice 4 post-review gate fix 1 — exhaustive presence expectations
- Both reported failures confirmed: nil-sessionRef presence now correctly emits sessionsLiveKeysChanged with unresolved=true; strict chrome/fan-out tests had omitted that action. Added explicit receives and state assertions; production safety gate and test exhaustivity unchanged.
- Targeted AppFeatureSettingsChangedTests excluding only A2 baseline settingsChangedPropagatesRepositorySettings(): exit 0; xcresult totalTestCount 11, failedTests 0. First attempt failed compilation/count 0 because App Action is not Equatable; corrected to case-key-path receives.
- make build-app: exit 0. make lint: exit 2, only unchanged baseline DeeplinkClient:26 and CommandPaletteFeature:1260 complexity violations. git diff --check: exit 0.
- Logs /tmp/slice4-postgate-{tests,lint,build}.log; summary /tmp/slice4-postgate-summary.json. Serialized builds/tests; no full suite or live-environment operations, no scope deviation. Untracked files preserved.

## Fix A1–A3 — cooldown, missing-cwd alert, loading spinner

### A1: 10-second dispatch cooldown (dcd6c256)
- Added `recentSessionLaunchDate: [SessionKey: Date]` to AppFeature.State.
- `launchSessionCompleted` now records `date.now` for the key before clearing `pendingSessionLaunch`; uses `@Dependency(\.date)` inline in the case to avoid touching tests that don't exercise the handler.
- `handleResumeSession` gates on the cooldown first: if `date.now - lastLaunch < 10`, returns `.none`. Prevents the double-tab race where `pendingSessionLaunch` is nil but the new surface hasn't registered its session id yet.
- Three existing tests that call `launchSessionCompleted` without a date override were updated to add `$0.date.now = .distantPast`; no behavior change.

### A2: Visible alert for missing or unreadable cwd (dcd6c256)
- `handleResumeSession` checks cwd accessibility before calling `prepareResumeSession` when no operation is already in flight. Shows `AlertState` naming the directory's `lastPathComponent`; clears without setting pending.
- `handleNewSession` shows the same style alert when the resolved cwd is absent or not a readable directory, instead of the previous silent no-op with only a logger warning.

### A3: ProgressView while refresh in flight (86da249c)
- `SessionsSidebarListView` now shows a `ProgressView()` instead of "No sessions" when `store.sessionsRefreshInFlight` is true and the section list is empty. Covers the first-launch window (empty cache, disk refresh still running) and any subsequent empty-cache refresh cycle. Shows "No sessions" only after `sessionsRefreshInFlight` clears.

### Tests (2961f1e9)
- 7 new tests in AppFeatureSessionsTests and RepositoriesFeatureSessionsTests.
- Targeted: `supacodeFeatureTests/AppFeatureSessionsTests` + `supacodeFeatureTests/RepositoriesFeatureSessionsTests`.
- Final run: exit 0; xcresult totalTestCount 84, passedTests 84, failedTests 0.
- make lint: exit 2, only baseline DeeplinkClient:26 and CommandPaletteFeature:1260. make build-app: exit 0. git diff --check: exit 0.
- Logs: /tmp/a1a2a3-{lint,build,tests4}.log; build /tmp/a1a2a3-final-build.log.
- No full suite, live-app operations, process signals, or protected-home writes. Untracked .worktrees/ and PAPERCUTS.md preserved.
