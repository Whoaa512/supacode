# Sessions sidebar implementation plan
Scope: `plans/sessions-sidebar-scope.md` is locked. Execute all four slices,
serially on `cj-main`; finish with a dogfoodable daily build, not a feature branch.
Do not resurrect Task Inbox entities, event logs, workflows, or archived code.
Read-only planning; no builds/tests. Line references are discovery anchors.

## 0. Orchestrator amendments (these override anything below)
- **A1. Never touch the owner's live environment.** His app is running with
  live sessions. Do not run `make run-app`, `make install-dev-build`,
  `make compare-apps` or `open` on any app bundle. Do not kill or signal any
  supacode, zmx or pi process. Do not write to `~/.pi`, `~/.supacode` or
  `/Applications`. Reading `~/.pi/agent/sessions` to confirm the format is
  fine. The "Manual QA" lists below are for the owner; your proof is automated
  tests. This replaces every "launch/install the daily build" instruction.
- **A2. Baseline.** Before any change, `make build-app` passed and `make test`
  ran 3,796 tests with exactly these 5 failures, which are not yours to fix:
  `GhosttyRuntimeBundledOverridesTests/backgroundColorTracksColorScheme`,
  `GhosttyRuntimeBundledOverridesTests/initSeedsResolvedColorSchemeBeforeFirstRead`,
  `PaneWindowShortcutTests/relativeTabCyclingShortcutsUseBracketChords`,
  `AppFeatureSettingsChangedTests/settingsChangedPropagatesRepositorySettings`,
  `AppFeatureCommandAckTests/deleteSocketDeeplinkFailsOnScriptCancellation`.
  A slice is done when the full `make test` shows no failure outside this list
  and the total test count went up.
- **A3. Numbered jumps use the existing `selectWorktree1…9` chords (⌃1–9).**
  Make those tab-aware for Sessions. Do NOT reroute `selectTab1…9` (⌘1–9);
  terminal tab selection stays exactly as it is. This replaces the ⌘-digit
  routing in §6.
- **A4. Default tab.** Store the Sessions-era tab selection under a new storage
  key whose default is `.sessions`, so the first launch of this build lands on
  Sessions and later choices persist. No migration flag.
- **A5. Index cost.** Scan lines as bytes and JSON-decode only the header, the
  `session_info` lines and the first user message; count messages with a cheap
  prefix/substring check. Persist the per-file cache (path, mtime, size,
  summary) to one JSON file in the state directory so relaunch does not re-read
  755 MB. Publish the list as soon as the cache is loaded, then refresh.
- **A6. Default chords.** Keep them near the existing ⌘⌃↑/↓ navigation:
  `settleSessionAndAdvance` ⌘⌃E, `unsettleSession` ⌘⌃U, `nextSessionNeedsMe`
  ⌘⌃N, `newSession` ⌘⇧N, `newSessionInDirectory` ⌘⌥⇧N. Verify each against
  `AppShortcuts` defaults and Ghostty's default keybinds; on a collision fall
  back to the chord named in §6.
- **A7. Terminal teardown is fragile** (see `plans/hibernation-teardown-deadlock.md`).
  Slice 3 may only ADD bookkeeping there. Do not reorder, delay or make async
  any existing teardown, hibernate, kill or probe step. Wherever attribution
  is uncertain the answer is "do not settle": a row wrongly left Active is
  fine, a row wrongly settled or a wedged teardown is not.
- **A8. Size.** The previous attempt died at 61k lines. If a slice heads past
  roughly 1,500 lines of production code, stop and simplify. Fewer,
  higher-value tests over exhaustive ones.
- **A9. Builds.** One xcodebuild at a time. Use `-only-testing` (always with
  `SWIFT_VERSION=5`) while working; run the full `make test` once at the end
  of the slice.
- **A10. Commits.** Small and focused, straight to `cj-main`. Stage named
  files only; never `git add .` or `-A` (`.worktrees/` and `PAPERCUTS.md` are
  untracked and must stay untouched). Run `make lint` and fix only your own
  violations. Messages say why. No co-author or generated-by lines.

## 1. Architecture: one page
- `supacode/Domain/SessionSource.swift` (new): `nonisolated` Sendable protocol,
  `sessions() async throws -> [SessionSummary]` and
  `resumeCommand(sessionID:) -> String?`. One seam, pi implementation only.
  `SessionSummary` carries harness (`SkillAgent`), id, createdAt, cwd, title,
  messageCount and lastActivity; `SessionKey` encodes `harness:sessionId`.
  Validate ids with existing `AgentPresenceOSC.sanitizedSessionRef` before resume
  (`SupacodeSettingsShared/BusinessLogic/AgentPresenceOSC.swift:88`).
- `supacode/Clients/Sessions/PiSessionSource.swift` (new): non-main actor owning
  disk enumeration, streaming JSONL parsing and `(mtime, size)` cache by URL.
  Builds commands with `AgentResumeCommand.command(agent:sessionRef:)`
  (`supacode/Domain/AgentResumeCommand.swift:11`), not shell interpolation of titles.
- `supacode/Clients/Sessions/SessionIndexClient.swift` (new): one dependency
  wrapping that actor; injected `refresh` closure returning summaries.
  No client wrapping shared settings/sidecar, no source registry or plugin framework.
- `supacode/Domain/SessionSidecar.swift` (new): dictionary keyed by SessionKey;
  entry contains ONLY `settledAt: Date?`, `manualUnsettledAtActivity: Date?`,
  `branches: [String]` (ordered unique). Marker is the activity watermark when
  manually unsettled, not a timer; fresh activity clears it.
- `supacode/Features/Repositories/BusinessLogic/SessionsPersistenceKey.swift`
  (new): `@Shared(.sessions)` backed by `.fileStorage(...sessions.json)`.
  Add `SupacodePaths.sessionsURL` under `baseDirectory`; DEBUG state override
  already exists at `SupacodeSettingsShared/Support/SupacodePaths.swift:4–14`.
  Actual sidebar persistence is NOW UserDefaults, not fileStorage:
  `SidebarPersistenceKey.swift:11–19`; layouts likewise `LayoutsPersistenceKey.swift:11–25`
  (both paths relative to `supacode/Features/.../BusinessLogic`). Do not copy their
  migration machinery. The scope explicitly requires a new JSON sidecar.
- `supacode/Domain/SessionClassification.swift` (new): caseless nonisolated enum;
  pure static classification, ordering, next-live and branch-mismatch helpers.
  Foundation/domain only, no TCA/SwiftUI. Lifecycle and runtime are independent.
- `supacode/Features/Repositories/Reducer/SessionSidebarItemFeature.swift` (new):
  minimal `@ObservableState` leaf (id, title, cwd, lifecycle, location, status,
  branch annotation); actions only activate/settle/unsettle with parent delegates.
  No per-row IO, clocks, file watchers or persistence. Store leaves in
  `RepositoriesFeature.State.sessionItems: IdentifiedArrayOf<...State>`.
- `supacode/Features/Repositories/BusinessLogic/SessionsSidebarStructure.swift`
  (new): Equatable cached section ids/order, live ids, hotkey slots ONLY.
  Derive from leaves inside post-reduce; publish only on equality change.
  `SidebarStructure.swift:658–669` owns `applyCacheRecomputes`; extend its
  invalidation switch explicitly rather than recomputing every app action.
- `supacode/Features/Repositories/Views/SessionsSidebarListView.swift` (new):
  List of ids, scoped leaf stores; row appearance reads only its own store.
  Add `.sessions` in `BusinessLogic/SidebarTab.swift:5` and render in
  `Views/SidebarView.swift:48`. Set missing/invalid tab default to Sessions;
  preserve an explicitly persisted Worktrees/Agents preference.
- `supacode/Features/App/Reducer/AppFeature+SessionCommands.swift` (new):
  focus/resume/new-session orchestration and close/end attribution.
  Session state is NOT added to LayoutFeature or TabChrome. App owns effects,
  Repositories owns sidebar leaves, existing AgentPresence owns agent records.
Repositories references are under `supacode/Features/Repositories/`.
A few models, one actor, one shallow leaf reducer; no prerequisite refactor.

## 2. Index and refresh
Pi root is ONLY `~/.pi/agent/sessions`; never traverse `subagent-sessions`.
Enumerate one cwd-directory level, regular `.jsonl` files only; do not follow
symlinks out of the root. Parse header's cwd as authoritative (encoded directory
names are lossy); skip component-prefix temp paths `/tmp`, `/private/tmp`,
`/var/folders`, `/private/var/folders`, including standardized/resolved aliases.
Do not exclude `/tmp-project` or every descendant of `/private`.
Stream fixed-size chunks via FileHandle on the index actor, not Data(contentsOf:)
on the main actor. Header gives identity, cwd and createdAt. Last session_info
wins (including a cleared/empty name); title falls back to first user text,
then "Untitled session". Sanitize controls and cap displayed fallback text.
Count lines whose parsed type is message, regardless of message role; use latest
message timestamp for lastActivity, falling back to creation (not rename/mtime).
Tool-result messages count too; do not reconstruct the active conversation tree.
Pi format references: `~/code/pi-mono/packages/coding-agent/src/core/session-manager.ts:54`,
`:119`, `:699–770`, `:1175–1183`. Header timestamps, not filename sort, order rows.
Malformed trailing partial line is ignored until the next refresh; a broken file
must not hide its siblings. Log bounded diagnostics with SupaLogger.
Important scope cost: exact messageCount, fallback title and activity CANNOT be
obtained from header + last session_info alone. Cold indexing needs one streaming
pass through valid files (~755 MB today); hot refresh stats files and reads ONLY
changed ones. Cache metadata plus summary, not transcripts. Re-stat after parsing;
if changed during read, retry on next refresh, don't mark that version final.
Serial parsing bounds memory/open FDs; yield intermediate batches (e.g. 100 files)
through an optional client callback if first-launch visibility otherwise stalls.
Start with one final response; add batches only after measuring an actual delay.
Add Repositories actions `sessionsRefreshRequested`, `sessionsRefreshCompleted`,
`sessionsRefreshFailed`, `sessionsSidebarShown`, `sessionsCoarseClockFired`,
`sessionSnapshotsChanged` and one `CancelID.sessionsRefresh`.
Start launch refresh beside snapshot restoration at
`supacode/Features/App/Reducer/AppFeature.swift:449–455`, independent of tab choice.
Refresh on Sessions tab appearance and presence identity/turn-end changes;
use injected continuousClock, 500 ms debounce for event storms, one refresh at a
time. Single-flight actor returns cached results; generation token prevents
older responses from replacing newer results. Keep rows on refresh error.
While app runs, a cancellable 15-minute coarse loop requests refresh plus
classification; evaluate immediately on launch, tab appearance, wake/activation
and refresh completion too. No per-second reducer tick, no per-file observers.
Presence status deltas update leaves immediately; they never wait for disk IO.
Test debounce/coarse timing with TestClock, never Task.sleep.

## 3. Identity, leaves and live linking
Presence keys are `(agent, surfaceID)`; records carry sessionRef at
`supacode/Features/AgentPresence/Reducer/AgentPresenceFeature.swift:93`.
At the App hook receipt (`AppFeature.swift:2247–2248`), inspect the old record
BEFORE forwarding `.agentPresence(.hookEventReceived(event))`; the child later
runs at `:2264`. Use old id for end/replacement attribution, not the new id.
Fan out dirty surface deltas from `.delegate(.surfacesChanged)` at `:472–487`.
Read raw records regardless of `agentPresenceBadgesEnabled` (UI toggle is not
session existence); do not reuse the worktree rollup as session identity.
For pi records with an id: match SessionKey, attach location
(worktreeID, tabID, surfaceID) from terminal layout. For a running agent with no
id: provisional key `provisional:<harness>:<surfaceID>`, "New session", immutable
first-observed creation time and cwd from its worktree. Never persist provisional
keys. When sid arrives, atomically replace provisional leaf/selection with real
key; disk row and surface row become ONE. Create synthetic real summary if file
is not yet indexed, then reconcile with authoritative header creation time.
Only this hydration may correct a provisional position; messages never reorder.
Never infer ids from cwd/title/argv. Duplicate sid => one row; focus current match or stable UUID order; live until all links disappear.
Persisted `SurfaceAgentRecord.sessionRef` restores identity through
`supacode/Features/Terminal/Models/TerminalLayoutSnapshot.swift:94–105` and
`AgentPresenceFeature.stageRestore:610–653`;
`restoreFromSnapshotChecked:277` must trigger leaf linking even before any turn.
A hibernated rendering surface with a running zmx agent still counts as live;
focus wakes it. A plain shell has no agent record, hence no Sessions row.
Structure MUST NOT embed status/title/branch/leaves (unlike `AgentDashboardStructure.swift:187`).
Copy nav/caching, not invalidation breadth: sessions-only bit; status changes touch leaves only.
List row scoping is lazy by id; no parent-body `sessionItems[id:]` reads.
All navigation/slot hints share structure.liveIDs; arrow selection has a separate
all-visible id list including dormant and Settled rows.

## 4. Activation, launch and branches
Add Repositories actions `sessionSelectionChanged(SessionRowID?)`,
`activateSession(SessionRowID)`, `settleSession(SessionKey)`,
`unsettleSession(SessionKey)`; parent delegates `focusSession(location)`,
`resumeSession(SessionKey)` and `newSession(directory:)`.
Live activation uses App `.focusTerminalSurface(worktreeID:tabID:surfaceID:)`
(`AppFeature.swift:1235–1243`) and TerminalClient focusSurface, not Agents'
`.activateAgentDashboardEntry` (`RepositoriesFeature.swift:4120–4122`), which
only selects a WORKTREE, not a particular surface. Successful live activation of
a settled row also unsettles it; selecting with arrows alone does not.
Dormant activation validates cwd exists/readable, resolves exact local worktree
workingDirectory (not repository root or name), then runs
TerminalClient `.createTabWithInput(worktree,input:...,runSetupScriptIfNew:false,
id:...,title:nil,focusing:true,anchor:nil)` (`TerminalClient.swift:74`;
`WorktreeTerminalManager.swift:356–361`, `:965–1003`). Existing launch-input
terminator submits the command; don't add extra newline or send text before
surface creation. Resume candidates in `AppFeature+AgentCommands.swift:78–112`
only type into an existing dead surface; don't consume those for this new-tab flow.
If cwd isn't registered, add narrow Repositories `.registerSessionFolder(URL)`:
construct `Repository(location:.local(cwd),kind:.folder,...)` with single synthetic
`Worktree(kind:.folder, workingDirectory:cwd,...)` using
`Repository.folderWorktreeID(for:)` (`supacode/Domain/Repository.swift:128`).
Reuse root persistence/merge and `.delegate(.repositoriesChanged)` from
`RepositoriesFeature.swift:3871–3973`; wait for registration before launch.
DO NOT blindly call `.openRepositories`: it calls git.repoRoot at `:3881` and may
silently change cwd; loading reclassifies kind at `:5352–5382` on relaunch.
Keep a minimal `@Shared(.sessionFolderRoots)` string-array AppStorage override
of exact auto-registered roots; load those as folders before git classification.
Reuse removal cleanup to remove overrides when roots are removed. This is repo
registration metadata, NOT an extra sessions.json field. Existing registered git
worktrees need no override. No checkout/new worktree, no duplicate root entry.
Use one pending launch value (key/cwd/command/request id) while registering or
confirming, disable duplicate activation until completion; clear on failure.
Unsettle only when launch is accepted, preserve settled state on cancel/missing cwd.
Allow retry after launch failure; never silently launch in another cwd.
Capture branch on raw busy AND idle receipt before presence mutation; resolve
surface's worktree and its current branchName (sidebar leaf carries watcher
updates). Append branch only if nonempty and not already in sidecar branches.
Watcher entry: `WorktreeInfoWatcherClient.swift:27`; reducer handler
`RepositoriesFeature.swift:3467`. Busy/idle capture starts in Slice 1.
Folder-kind isn't evidence of no git: for forced folder roots that are inside git,
fetch branch via `GitClientDependency.branchName` (off-main, definition in
`supacode/Clients/Repositories/GitClientDependency.swift:85`, live `:280`)
on turn boundaries and before resume. Serialize samples; no new watcher.
For genuine non-git folders record no branch. Existing historical files never
receive guessed branches retroactively.
At resume in Slice 3, refresh current branch via GitClient (watcher may lag).
If nonempty branches and nonempty current branch not in set: show ONE alert
naming last recorded branch and current branch. Confirm continues the saved
request WITHOUT recursively checking again; Cancel does nothing. Never checkout.
Absent branch history/no git => silent resume. Render last recorded branch only
when it differs from currently known cwd branch, in the leaf, not structure.

## 5. End attribution and teardown (Slice 3)
Do not equate `.closeTab` with user intent. Unexpected probe paths send it at
`WorktreeTerminalManager.swift:930`, `:938`, `:958`; script cleanup also sends it.
Do not settle on confirm REQUEST: cancel must leave lifecycle untouched.
Use content-host `pendingUserCloseSurfaceIDs` (NEW) distinct from existing
`pendingExplicitSurfaceCloseIDs`. In
`LayoutSurfaceConduit.swift:123–129`, consume bypass/explicit markers as today,
then retain the observed user intent in the NEW set until actual removal.
For bypass, mark the owning surface too (CLI/deeplink is explicitly user-ended).
Emit no session mutation from the conduit or LayoutFeature.
Cover other paths that DO NOT visit the conduit:
- Manager `.closeFocusedTab/.closeFocusedSurface` (`:384–390`), `.destroyTab`
  (`:427–437`), `.destroySurface` (`:439–454`), `.closePane` (`:1430–1435`):
  mark every targeted content id before dispatching the existing layout action.
- Direct strip/window `.contentRequestedClose` calls in
  `supacode/Features/Terminal/Views/PaneTabStripView.swift:645–660` and
  `PaneWindowManager.swift:308`, `:392`, `:681`: capture targets in App's core
  handler for `.terminals(.layouts(.element(...)))` BEFORE child scope
  (`AppFeature.swift:2261`) via a synchronous TerminalClient content-host method.
  Targets follow existing CloseScope computation (`LayoutFeature.swift:418–434`).
  A conduit non-explicit automatic close must be marked as automatic at its
  entry point so this bridge does not reinterpret it as a UI user request.
- Confirm cancellation/replacement clears pending targets; observe `.alert`
  actions at the same bridge, retaining only currently pending alert targets.
  Existing confirm commit is `LayoutFeature.swift:345–347`. No session fields,
  session-specific actions or status enter LayoutFeature.
On actual removed-content diff, BEFORE discardSurfaceBookkeeping in
`WorktreeContentHost.cleanupSurfaceState:1120–1129`, consume NEW user-close ids.
Callback `onUserClosedSurfaces` (new) emits TerminalClient.Event
`.userClosedSurfaces(worktreeID:surfaceIDs:)` BEFORE existing `.surfacesClosed`.
Manager wiring precedent: `WorktreeTerminalManager.swift:771–790`; App cleanup
currently removes presence at `AppFeature.swift:2233–2244`. Attribute ids while
presence still exists, settle in Repositories, then allow normal cleanup.
A canceled/rejected locked-tab close must discard its intent; use the post-layout
observer (`TerminalsFeature.swift:127–138`, manager `:846–848`) to prune intents
not removed and not covered by a pending confirm. Do not retain stale intent for
some future probe close. Batch/pane closes settle each distinct session once.
Pi generation changes in `SupacodeSettingsShared/BusinessLogic/PiExtensionContent.swift`:
replace load-time `emitPresence("session_start")` (`:190`) with
`pi.on("session_start", (_event,ctx) => ...)` emitting sid via sessionRef(ctx).
Emit sid on idle as well as busy; shutdown handler (`:203–205`) emits sid and
`reason=quit|reload|new|resume|fork`. Drop the defensive idle AFTER end (it can
resurrect a removed presence record); normal turn end still emits idle.
Pi definitions: `~/code/pi-mono/packages/coding-agent/src/core/extensions/types.ts:567`,
`:636–638`; signals report quit at `src/modes/interactive/interactive-mode.ts:4082`.
`SupacodeSettingsShared/BusinessLogic/PiSettingsInstaller.swift:33–57` remains
installer; verify regenerated installation (older running processes need restart).
Add optional validated shutdownReason to AgentPresenceOSC.Signal (`:57–70`),
parser (`:101–112`), AgentHookEvent (`AgentHookSocketServer.swift:450–560`),
and AgentSignal.presenceEvent (`AgentSignal.swift:54–60`). Unknown reason => nil,
never fabricate quit. Existing other harness reasonless session_end means user
end only when not suppressed. Pi reload explicitly NEVER settles; new/resume/fork
and genuine quit settle old id. sid replacement on session_start/busy settles old
id before overwrite (`AgentPresenceFeature.swift:313`); reload same id doesn't.
Existing flags are NOT a sufficient harness-end guard:
`sessionsToSpare`/`sessionsToKillLocalOnly` (`WorktreeTerminalManager.swift:26–29`)
only encode probe decisions; explicit/bypass sets only encode close origin.
Content runtime removal and host.tearDown are cleanup, not user-intent signals.
Add manager `suppressedHarnessEndSurfaceIDs` and process-wide `isEndingAllSessions`;
add App `isQuitting` set synchronously at entry to `quitEffect` (`:3743`).
- Before app-owned kill/detach/rebuild/hibernate of a surface, insert suppression
  before any asynchronous operation (killSession `:881`, runtime removal
  `:1504`, `:1556`; hibernate content path must be located before detach).
- Before Terminate Sessions (`AppFeature.swift:1085–1088`) start global suppression,
  and before terminateAllSessions host teardown (`manager:1880–1904`) too.
- Add `onWillTearDown`/`onDidStart` closures to TerminalContent; call before
  closeSurface at `supacode/Features/Terminal/Content/TabContent.swift:187–200`
  and after successful start at `:177–184`. Inject from
  `supacode/Features/Terminal/Content/TerminalSurfaceRecipe.swift:318–332`.
  This precedes hibernate detach; host's `onSurfacesHibernated:1148` is too late.
- Expose synchronous `TerminalClient.isHarnessEndSuppressed(surfaceID)` reading
  manager's gate. App checks BEFORE settlement at hook receipt; manager's
  `dispatchHookEvent:245` still forwards normal events for presence cleanup.
  Suppression must not suppress explicit-user-close callbacks.
- Keep per-id suppression until surface is removed or a fresh session_start /
  successful wake begins; global termination flag clears after completion.
  Ignore late end from prior pid when new record's pid/session identity differs.
- Quit without terminate leaves running sessions intact; snapshot before teardown
  and don't settle. System-induced app termination should set the same gate in
  app delegate (`supacode/App/supacodeApp.swift:44–65`) before cleanup.
A machine-wide unannounced SIGKILL has no app signal; do not invent a heuristic
that settles all missing agents. Restart/recovery remains active and dormant.

## 6. Keyboard and directory picker (Slice 2, finish in 3/4)
Existing precedent is commit `35232fd7` (tab-aware Agents navigation), present
on cj-main. Extend Sessions branches at `.selectWorktreeAtHotkeySlot`, `.selectNextWorktree`,
`.selectPreviousWorktree` (`RepositoriesFeature.swift:4068–4108`), before Agents
and Worktrees branches. Offset wraps over structure.liveIDs; no selection enters
first/last, empty beeps/no-op. Resolve current focused surface to row before
falling back to stored sidebar selection. Every move immediately activates/focuses;
never invokes resume/new-tab. Active AND manually settled live rows remain eligible.
Arrow keys in sidebar move selection through all rows; Enter activates selected.
Collision found: defaults are CONTROL digits for selectWorktree (`AppShortcuts.swift:523`)
and COMMAND digits for selectTab (`:533`). Scope asks COMMAND digits for Sessions.
Keep defaults/settings intact: when Sessions is visible, route existing selectTab
1–9 command to nth Sessions live row; otherwise retain terminal tabs. Existing
control digits may also use tab-aware slot action. Update menu labels/hint badges
for both routes; only live rows show numbered hints. Dispatch precedence test
must prove one key press produces ONE focus, not both a tab and row selection.
Commands hooks: `supacode/Commands/WorktreeCommands.swift:178`,
`supacode/Commands/TerminalCommands.swift:165`; route App
`.selectTerminalTabAtIndex` at `AppFeature.swift:1117` when Sessions is active.
Follow FocusedAction publication
from `supacode/App/ContentView.swift:142–147`, not closure-valued focused values.
Add AppShortcutID + AppShortcuts entries, string maps, titles, category and all
registration arrays in `SupacodeSettingsShared/App/AppShortcuts.swift`:
- `newSession`: ⌘⇧N; `newSessionInDirectory`: ⌘⌥⇧N.
- `settleSessionAndAdvance`: ⌘⌥⇧S; `unsettleSession`: ⌘⌥⇧U.
- `nextSessionNeedsMe`: ⌘⌥⇧J (Slice 4).
No exact default collision in current shortcut table (`:471–617`); add automated
unique-default test, including numeric remapping exception. Honor overrides.
Keep toggleAgentsSidebarTab's Worktrees/Agents toggle behavior; Sessions is
selectable in the three-way picker, not silently removed from the enum cycle.
New App actions `newSession`, `newSessionInDirectory`, `settleSessionAndAdvance`,
`unsettleCurrentSession`, `nextSessionNeedsMe`. Harness is deliberately `.pi`,
per locked scope, not inferred from current agent and not a new preference.
No default-harness setting exists: input "pi" via createTabWithInput, no prompt.
Cwd: focused session, selected session, selected worktree workingDirectory, home.
Cheapest picker is existing palette `.browse`, not a new fuzzy UI:
`CommandPaletteFeature.swift:21`, `:271–315`, `:355–414`; browse already lists
and searches directories. Add `BrowsePurpose.newSession` to palette state
(default existing open-repository purpose); selection delegates
`.newSessionDirectorySelected(URL)` for that purpose. App handles it with the
same exact-cwd registration/launch function. Browse supports typed arbitrary
paths plus native-panel fallback; do not restrict choices to registered worktrees.
Existing app open handling is `AppFeature.swift:1906`; retain it unchanged for
normal browse. Reset purpose on dismiss/selection so it never leaks between uses.

## 7. Settle, classification and CLI
Manual settle writes settledAt=now, clears manual marker; doesn't kill anything.
Unsettle clears settledAt, sets marker=effective lastActivity; resuming also
unsettles. Clear marker when fresh busy/idle/message activity exceeds watermark,
not on rename. Live always wins age classification, even after marker clears;
a dormant manual-unsettle with no new activity holds indefinitely.
User-end/manual settle always overrides marker. Sidecar explicit settle persists
until explicit activation/unsettle; don't auto-unsettle a running manually settled
session on ordinary status changes. No new activity-based ordering.
Triage classification: explicit settledAt => Settled; else live => Active;
else manual hold => Active; else messageCount<4 => Settled; else idle for configured
N days (default 3) => Settled; else Active. Auto rules persist settledAt through
same mutation path. Only classify after launch restoration finishes, so initial
index response cannot auto-settle agents whose restore is still checking pids.
Never age auto-settle provisional/unknown summaries; refresh failure is not proof
of dormancy. Sort each section createdAt descending, ties stable SessionKey.
Status derives raw existing activity and doneUnseen: awaitingInput => needs you,
busy/compacting => working, otherwise doneUnseen => done-unseen, otherwise idle.
Error presents needs-you rather than adding a fifth status; dormant has no live
status. Next-needs-me filters LIVE awaitingInput OR doneUnseen only (VC10).
Settle-and-advance captures next live id BEFORE mutation, excluding current; no
candidate => stay/no-op, never resume a dormant row or refocus sole current row.
Add `supacode-cli/Commands/SessionCommand.swift`, register in
`supacode-cli/SupacodeCLI.swift:8`. `session list` uses QueryDispatcher query
`sessions`; returns id (harness:id), title, cwd, lifecycle, live, status, branch
and surfaceID when available. Reuse AgentCommand list formatting/options.
App query routing lives in `supacode/App/supacodeApp.swift:531`, `:567–592`,
NOT AppFeature; new `supacode/App/SessionQueryResponse.swift` builds rows.
`session settle|unsettle [harness:id]` defaults to `SUPACODE_SURFACE_ID` through
`supacode-cli/Helpers/EnvironmentDefaults.swift:18–19`; require explicit id if multiple
agents on calling surface. Missing/ambiguous/no-session => actionable error.
Commands use existing Dispatcher/deeplink transport; add `.session` action in
`supacode/Domain/Deeplink.swift:24` and parser in
`supacode/Clients/Deeplink/DeeplinkClient.swift:57`, following agent parser `:114`,
App reducer routes to same settle/unsettle logic and writes existing ack response.
FD lifecycle precedent: `AgentHookSocketServer.swift:289–318`, `:608–623`.
No new socket, custom daemon or CLI filesystem writes. Query uses current index;
launch refresh populates it, loading state should be explicit rather than claiming
empty history. Id validation and URL encoding required. No pi /settle wrapper V1.

## 8. Serial slices and validation contract
For ALL slices: re-read AGENTS.md + locked scope + this plan; keep current cj-main.
After adding source/test files run `make generate-project`; lint (`make lint`),
relevant tests, then `make build-app`, serially after any existing baseline finishes.
Every make test override MUST contain SWIFT_VERSION=5. Example:
`make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:supacodeTests/PiSessionSourceTests'`.
Verify `xcrun xcresulttool get test-results summary --path build/supacode-tests.xcresult`
reports nonzero totalTestCount, not an empty successful bundle. Tests use temp
fixtures, injected date/clock and in-memory Shared, never actual pi history.
Commit only slice files, focused why-message; launch/install the daily build after
validation. Owner-away instruction means agents proceed serially through all
slices, not wait for owner approval between them. Never start parallel xcodebuild.

### Slice 1 — See
1. Create domain/index/sidecar/key types and index tests; inject index root/time.
2. Add sessionItems/structure/cache bit, delegates and Sessions default view.
3. Wire launch refresh, restore/presence joining, provisional merge and focus.
4. Wire dormant exact-cwd registration/resume and branch capture now.
5. Update pi session_start sid emission now for useful first-launch live links;
   defer shutdown reason/settle handling to Slice 3.
Files: new files in architecture; AppFeature.swift; RepositoriesFeature.swift;
SidebarStructure.swift; SidebarTab.swift; SidebarView.swift; SupacodePaths.swift;
PiExtensionContent.swift; register-folder load/persistence/removal branches.
Tests (under supacodeTests): `PiSessionSourceTests.swift` (supacodeTests bundle):
header/title clear/fallback/count/timestamps, malformed tail, cache hit/miss,
file deletion/rewrite, temp aliases/component boundaries, fixture-only IO.
`SessionClassificationTests.swift` (supacodeTests): stable creation order.
`RepositoriesFeatureSessionsTests.swift` (supacodeFeatureTests): default tab,
structural no-op, provisional merge, live/dormant, branch ordered uniqueness.
`AppFeatureSessionsTests.swift` (supacodeFeatureTests): specific-surface focus,
resume command/exact cwd, folder registration sequencing, restore with shell
excluded, delayed index/restore ordering, missing cwd and duplicate click.
VCs: VC1–4, VC14; VC2 regression throughout; VC12 every slice.
Manual QA: start with real history; titles/directories present, newest first;
click a session in a nonfocused split, then dormant registered and unregistered
cwd; quit-without-terminate/relaunch, verify agents AND ordinary shells survive.
Boundary: usable See build; next/previous enhancements belong to Slice 2, as
scope's slice list specifies despite its broader "first slice" keyboard aspiration.

### Slice 2 — Move
1. Extend tab-aware live-only nav and command-digit routing/hints.
2. Add shortcut registrations/menu focused actions and no-prompt pi launch.
3. Add palette browse purpose/directory delegate; reuse Slice 1 launch function.
Files: RepositoriesFeature.swift; SessionsSidebarStructure.swift/list view;
AppFeature.swift/+SessionCommands.swift; AppShortcuts.swift; ContentView.swift;
TerminalCommands.swift; WorktreeCommands.swift; CommandPaletteFeature.swift and
palette overlay/panel only where existing mode labeling/shortcut dispatch needs it.
Tests: extend `RepositoriesFeatureSessionsTests.swift`: wrap both directions,
no selection/empty, dormant exclusions, live settled eligible, all-row arrows.
Extend `AppFeatureSessionsTests.swift`: new pi/current cwd/fallback, focus-only
nav, numeric precedence preserving other tabs, picker purpose/cancel/reset.
`SessionShortcutTests.swift` and `CommandPaletteSessionDirectoryTests.swift`
(supacodeTests): defaults unique, overrides, fuzzy browse delegate.
VCs: VC5–6; regression VC1–4/14; VC12.
Manual QA: compare repeated next/previous to today's worktree cycling; inspect
no new processes; ⌘1–9 maps visible hints; both new chords produce running pi,
including a space-containing unregistered directory; existing browse still works.

### Slice 3 — Settle
1. Implement sidecar mutations/context menus/manual chords; sections reorder only
   on lifecycle transitions; settle-and-advance snapshots successor first.
2. Add explicit-close attribution across conduit, direct commands/UI/confirm,
   accepted-removal callback and ALL teardown suppression before handling ends.
3. Add pi reason emission/parser and old-session replacement attribution.
4. Add branch confirm, annotation and minimal CLI query/commands.
Files: SessionSidecar/classification/key; session leaf/structure/view; AppFeature
and +SessionCommands; TerminalClient; WorktreeContentHost; LayoutSurfaceConduit;
WorktreeTerminalManager; terminal content teardown/hibernate implementation;
AppShortcuts/menus; PiExtensionContent/AgentPresenceOSC/AgentSignal;
AgentHookSocketServer; supacodeApp.swift; SessionQueryResponse; Deeplink/client;
SessionCommand/SupacodeCLI. NO sessions logic in LayoutFeature.
Tests: `SessionsPersistenceTests.swift` (supacodeTests): JSON roundtrip, marker,
DEBUG path isolation; extend both feature test files for manual persistence,
advance, sid replacement/reload, end-before-presence-removal, mismatch confirm
once/cancel/silent known/no-history, fresh branch probe, stale delayed old end.
`WorktreeTerminalManagerSessionsTests.swift` (supacodeTerminalTests): explicit
close/bypass/direct destroy/pane batch; cancel/locked rejection; unexpected probe
all three paths; hibernate, rebuild, Terminate Sessions/quit suppression ordering.
`AgentSignalSessionReasonTests.swift` (supacodeTests),
`PiExtensionSessionLifecycleTests.swift` (supacodeTests): sid/start/end/reason,
reload, no idle resurrection; `SessionCLITests.swift` (supacodeTests): parsing,
calling surface default, explicit/ambiguous ids, query/ack error and FD cleanup.
VCs: VC7–8, VC13, settle-and-advance half of VC10; all previous/VC12 regressions.
Manual QA: settle/unsettle/relaunch; cancel then accept close, pane close and CLI
destroy; pi quit/new/resume/fork settle old, reload does not; hibernate/Terminate
Sessions/quit/zmx kill stay active; branch mismatch cancel/confirm/no checkout.

### Slice 4 — Triage
1. Project status into leaves without publishing status in structure.
2. Add next-needs-me shortcut and circular live-only filtering.
3. Add auto-settle setting, default 3 days; coarse clock, manual hold and <4 rule.
Files: SessionClassification.swift; session leaf/structure; RepositoriesFeature;
SidebarStructure invalidations; AppFeature/+SessionCommands; AppShortcuts/menus;
SupacodeSettingsShared/Models/GlobalSettings.swift (decode defaults/encode) and
existing settings editor for numeric idle-days setting; SessionIndexClient refresh.
Tests: extend classification table for explicit/manual/live/<4/age boundaries,
future timestamps, new activity releasing hold, live overriding low count.
Extend feature tests: next-needs-me ignores dormant/idle/busy, wrap and no target;
TestClock refresh debounce/coarse wake, restore gate and refresh error safety.
`SessionsSidebarObservationTests.swift` (supacodeTests): Observation tracking of
sibling leaf and structure unchanged on status-only mutation, plus own-row update;
structural transitions still invalidate section/order. Settings roundtrip/default.
VCs: VC9, remaining VC10, VC11; FULL VC1–14 and VC12 at final checkpoint.
Manual QA: awaiting input/done-unseen jump, busy turns never reorder; set isolated
fixture history older than threshold, hold via manual unsettle, then activity;
observe live rows never age-settle; verify normal settings and Worktrees/Agents.
Final: install/run daily build and report actual commands, test counts, commits,
manual assertions and any unverified OS shutdown behavior. Do not declare VC12
from a diff or from the unrelated baseline test that ran during planning.

## 9. Risks / defaults (implementer should not stop to ask)
1. Cold IO vs "header + last title only": exact count/activity requires scanning.
   Default streaming off-main cached pass; defer optimization until measured.
2. Folder registration of git cwd isn't supported as persistent forced-kind today.
   Default narrow folder-root override described above; never resume at git root.
3. No existing complete teardown guard. Default add content-level suppression,
   App quit gate, and provenance tests BEFORE enabling automatic harness settling.
   Catch termination before dispatching kills, not from later surfacesClosed.
4. SIGTERM outside Supacode is reported as quit by pi, indistinguishable from
   actual quit absent app/system teardown notice. Default obey scope's guard;
   document residual OS-race explicitly, don't claim perfect signal provenance.
5. Old running extensions: restored sid works; otherwise provisional + dormant
   file can temporarily coexist until next busy. Default no title/cwd heuristic.
   Verify VC14 on newly installed extension AND restored snapshots separately.
6. Default Sessions means missing/invalid saved preference only; preserve explicit
   other panel choice. No one-off migration flag or mandatory forced tab switch.
7. ⌘digits conflict is real. Default tab-conditional routing above; don't globally
   rebind terminal tab commands or make user choose a collision resolution.
8. Auto settled rows remain settled until explicit resume/unsettle, even if disk
   gets new activity; manual-unsettle hold clears with genuinely newer activity.
9. No Point-Free/pfw skill was discoverable in local skill paths during planning;
   follow repository's existing TCA/Observable patterns, not a new state store.
10. Teardown boundary verified in TerminalContent (`TabContent.swift:187–200`).
    Guard there, not in post-hibernate callback; cover synchronous close and late
    buffered OSC in tests. A wake must release suppression for legitimate ends.

## 10. Cut candidates (ranked; scope stays intact unless owner approves)
1. Under-4-message rule: lowest value; requires full exact message count but count
   is otherwise requested. Keep in V1 as one classification case; first cut if IO
   forces costly transcript processing (never build a conversation-tree parser).
2. Full arbitrary-directory fuzzy browse: existing palette reuse makes it cheap;
   cut only variant's polish, not VC6 directory choice. No new directory index.
3. Forced folder-kind for unregistered git cwd: medium cost, necessary for literal
   scope/exact cwd and relaunch. Cannot silently replace with root registration.
4. Detailed OS shutdown discrimination: expensive/impossible for unannounced kills;
   ship deterministic app-owned teardown guard, disclose signal race. No daemon.
5. Incremental progress batches / append-only cache / disk cache: omit unless
   measured cold-load delay demands them. mtime/size memory cache is sufficient.
No search/grouping/other adapters/transcript UI/auto worktrees/pi /settle wrapper.
All four slices and VC1–VC14 remain required; cuts need owner approval.
