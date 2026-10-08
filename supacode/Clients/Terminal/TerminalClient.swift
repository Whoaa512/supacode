import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

struct TerminalClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>
  var listSurfaces: @MainActor @Sendable () -> [TerminalSession]
  var sessionPreview: @MainActor @Sendable (LayoutID, UUID) -> String?
  var focusSurface: @MainActor @Sendable (LayoutID, DirectoryContext, TabID, UUID) -> Void
  var closeSurface: @MainActor @Sendable (LayoutID, DirectoryContext, TabID, UUID) -> Void
  var closeTab: @MainActor @Sendable (LayoutID, TabID) -> Void
  var tabExists: @MainActor @Sendable (LayoutID, TabID) -> Bool
  var tabCanRename: @MainActor @Sendable (LayoutID, TabID) -> Bool
  var surfaceExists: @MainActor @Sendable (LayoutID, TabID, UUID) -> Bool
  var surfaceExistsInWorktree: @MainActor @Sendable (LayoutID, UUID) -> Bool
  /// Whether a UUID is already a tab or content id in any loaded worktree. The
  /// runtime keys content globally and hibernation keys tabs globally, so an
  /// explicit id must be unique across worktrees in both id spaces.
  var idExistsAnywhere: @MainActor @Sendable (UUID) -> Bool
  /// Whether a CLI / deeplink pane token (a pane, tab, or content id) resolves
  /// to a pane in the worktree.
  var paneExists: @MainActor @Sendable (LayoutID, UUID) -> Bool
  /// Whether a tab can move into a new split: its pane holds more than one tab
  /// and is not windowed. A single-tab or windowed pane refuses the move.
  var canMoveTabToNewSplit: @MainActor @Sendable (LayoutID, UUID) -> Bool
  var tabID: @MainActor @Sendable (LayoutID, UUID) -> TabID?
  var selectedTabID: @MainActor @Sendable (LayoutID) -> TabID?
  /// Active surface in the selected tab. Lets the reducer capture the target
  /// synchronously before an async dispatch races against AppKit focus reshuffle
  /// (e.g. when a palette dismisses and the leftmost pane reclaims first responder).
  var selectedSurfaceID: @MainActor @Sendable (LayoutID) -> UUID?
  /// Writes raw bytes to one live surface's PTY without focusing it, so
  /// `supacode agent prompt` / `send-keys` can drive a background agent.
  /// `false` when the surface is gone or dormant (dormant tabs have no PTY).
  var sendTextToSurface: @MainActor @Sendable (LayoutID, UUID, String) -> Bool
  /// Current screen text of one live surface (same cached read the
  /// accessibility tree uses). `nil` when the surface is gone or dormant.
  var surfaceScreenText: @MainActor @Sendable (LayoutID, UUID) -> String?
  var latestUnreadNotification: @MainActor @Sendable () -> NotificationLocation?
  var markNotificationRead: @MainActor @Sendable (LayoutID, UUID) -> Void
  /// Marks every notification in every worktree read (menu bar "Mark All as Read").
  var markAllNotificationsRead: @MainActor @Sendable () -> Void
  /// Blocking scripts (setup / archive / delete / run) bypass zmx and die
  /// with the app, so the auto-mode quit confirmation needs to know.
  var hasInflightBlockingScripts: @MainActor @Sendable () -> Bool
  var markUserCloseIntent: @MainActor @Sendable (LayoutID, Set<UUID>) -> Void = { _, _ in }
  var isHarnessEndSuppressed: @MainActor @Sendable (UUID) -> Bool = { _ in false }
  /// Close every tracked surface and kill its zmx session in parallel.
  /// Awaited from the quit path so teardown completes before process exit.
  var terminateAllSessions: @MainActor @Sendable () async -> Void
  /// Quit-path variant: persist layouts and scrollback before sessions die.
  var persistAndTerminateAllSessions:
    @MainActor @Sendable (
      _ agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]
    ) async -> Void = { _ in }
  /// Kill `supa-*` sessions hosted by the daemon that no persisted layout
  /// references. Called at launch to clean up crash / force-quit orphans.
  var reapOrphanSessions: @MainActor @Sendable (_ knownSurfaceIDs: Set<UUID>) async -> Void
  /// Persist layouts with embedded per-surface agent records. Called on
  /// background and on quit so a force-quit between them caps staleness.
  var saveLayoutsWithAgents:
    @MainActor @Sendable (
      _ agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]
    ) -> Void

  enum Command: Equatable {
    case createTab(
      LayoutID,
      DirectoryContext,
      runSetupScriptIfNew: Bool,
      id: UUID? = nil,
      title: String? = nil,
      focusing: Bool = true,
      anchor: UUID? = nil
    )
    case createTabWithInput(
      LayoutID,
      DirectoryContext,
      input: String,
      runSetupScriptIfNew: Bool,
      id: UUID? = nil,
      title: String? = nil,
      focusing: Bool = true,
      anchor: UUID? = nil
    )
    /// Runs the resolved open-file script for a File Explorer file. `input` is the ready shell
    /// command; the manager picks placement (tab in the zoomed/top-right pane, or a split).
    case openFileWithScript(LayoutID, DirectoryContext, input: String)
    case ensureInitialTab(LayoutID, DirectoryContext, runSetupScriptIfNew: Bool, focusing: Bool)
    case stopRunScript(LayoutID, DirectoryContext, focusing: Bool = true)
    case stopScript(LayoutID, DirectoryContext, definitionID: UUID, focusing: Bool = true)
    case runBlockingScript(LayoutID, DirectoryContext, kind: BlockingScriptKind, script: String, focusing: Bool = true)
    case closeFocusedTab(LayoutID, DirectoryContext)
    case closeFocusedSurface(LayoutID, DirectoryContext)
    case splitFocusedPane(LayoutID, direction: TerminalSplitMenuDirection)
    case focusSplit(LayoutID, direction: TerminalSplitMenuDirection)
    /// Cycles focus to the next or previous pane in visual tree order, wrapping at the ends.
    case focusRelativePane(LayoutID, forward: Bool)
    case toggleSplitZoom(LayoutID)
    case equalizeSplits(LayoutID)
    /// Pane-addressed layout ops from the CLI / deeplinks. `paneToken` is a pane
    /// id, or the id of a tab / content the pane hosts.
    case splitPane(
      LayoutID, DirectoryContext, paneToken: UUID, direction: SplitDirection, input: String?, id: UUID? = nil,
      focusing: Bool = true)
    case focusPane(LayoutID, paneToken: UUID)
    case closePane(LayoutID, paneToken: UUID)
    case toggleZoomPane(LayoutID, paneToken: UUID)
    case toggleWindowModeForPane(LayoutID, paneToken: UUID)
    case moveTabToSplit(LayoutID, tabID: UUID, direction: TerminalSplitMenuDirection, focusing: Bool = true)
    case performBindingAction(LayoutID, DirectoryContext, action: String)
    case performBindingActionOnSurface(LayoutID, DirectoryContext, surfaceID: UUID, action: String)
    case setImagePasteAgents(surfaceID: UUID, agents: Set<SkillAgent>)
    case startSearch(LayoutID, DirectoryContext)
    case searchSelection(LayoutID, DirectoryContext)
    case navigateSearchNext(LayoutID, DirectoryContext)
    case navigateSearchPrevious(LayoutID, DirectoryContext)
    case selectTab(LayoutID, DirectoryContext, tabID: TabID)
    case selectTabAtIndex(LayoutID, index: Int)
    /// Cycles to the next or previous tab in the focused pane, wrapping at the ends.
    case selectRelativeTab(LayoutID, forward: Bool)
    case focusSurface(LayoutID, DirectoryContext, tabID: TabID, surfaceID: UUID, input: String? = nil)
    case splitSurface(
      LayoutID, DirectoryContext, tabID: TabID, surfaceID: UUID, direction: SplitDirection,
      input: String?, id: UUID? = nil, focusing: Bool = true)
    case destroyTab(LayoutID, tabID: TabID, focusing: Bool = true)
    case destroySurface(LayoutID, DirectoryContext, tabID: TabID, surfaceID: UUID, focusing: Bool = true)
    case beginTabRename(LayoutID, DirectoryContext, tabID: TabID? = nil)
    /// Moves the worktree's focused pane into its own window, or back.
    case toggleWindowModeForFocusedPane(LayoutID)
    case renameTab(LayoutID, tabID: TabID, title: String)
    case prune(keeping: Set<Worktree.ID>, protectingRepositoryIDs: Set<Repository.ID>)
    /// Explicitly deleted worktree: its layout, sessions, and persisted record
    /// go with it, host or no host.
    case removeWorktreeLayout(worktreeID: Worktree.ID, remoteHost: RemoteHost?)
    case setNotificationsEnabled(Bool)
    case enforceNotificationRetentionLimit
    case setSelectedLayoutID(LayoutID?)
    /// Fans a hibernation Beta-flag flip into every worktree state: enabling
    /// re-arms grace timers for hidden tabs, disabling cancels pending ones.
    case setTerminalHibernationEnabled(Bool)
  }

  enum Event: Equatable {
    case notificationReceived(
      worktreeID: Worktree.ID, surfaceID: UUID, title: String, body: String, isViewed: Bool)
    case notificationIndicatorChanged(count: Int)
    case tabCreated(layoutID: LayoutID)
    case tabClosed(layoutID: LayoutID)
    case focusChanged(layoutID: LayoutID, surfaceID: UUID)
    case runStatusChanged(worktreeID: Worktree.ID, status: WorktreeRunStatus)
    case blockingScriptCompleted(
      worktreeID: Worktree.ID, kind: BlockingScriptKind, exitCode: Int?, tabId: TabID?)
    case commandPaletteToggleRequested(layoutID: LayoutID)
    case setupScriptConsumed(layoutID: LayoutID)
    /// Per-worktree projection emitted when surfaces / task-running / unseen / notifications drift.
    /// Routed by the parent into the matching `SidebarItemFeature` via the row's id.
    case worktreeProjectionChanged(Worktree.ID, WorktreeRowProjection)
    /// An explicitly-addressed tab or split landed in the layout; resolves the
    /// CLI / deeplink creation ack for that id.
    case surfaceCreated(layoutID: LayoutID, id: UUID)
    /// A tab was destroyed in the layout; resolves the matching close ack.
    case tabRemoved(layoutID: LayoutID, tabID: TabID)
    /// A rename command settled. `applied` is false when the tab vanished or its
    /// title was locked, so the CLI ack reports the failure instead of ok.
    case tabRenamed(layoutID: LayoutID, tabID: TabID, applied: Bool)
    /// The worktree's terminal state was torn down (prune path).
    case worktreeStateTornDown(worktreeID: Worktree.ID)
    case userClosedSurfaces(layoutID: LayoutID, Set<UUID>)
    /// Forwarded from the terminal manager when surfaces close (single or bulk).
    /// `AppFeature` translates this into `agentPresence(.surfaceClosed/surfacesClosed)`.
    /// `worktreeID` scopes the CLI close ack so a duplicate id elsewhere can't cross-resolve.
    case surfacesClosed(layoutID: LayoutID, Set<UUID>)
    /// Forwarded from the terminal manager for hook events received over the socket.
    /// `AppFeature` translates this into `agentPresence(.hookEventReceived)`.
    case agentHookEventReceived(AgentHookEvent)
    /// Flips when the "any live surface anywhere" aggregate changes. Lets
    /// menu / focused-action gates read one Bool instead of iterating
    /// `sidebarItems` from a view body.
    case terminalHasAnySurfaceChanged(hasAny: Bool)
    /// A surface split failed to materialize (target raced away, target was a
    /// blocking-script tab, or the layout insert threw). Lets a CLI completion
    /// ack report the failure instead of waiting for its timeout.
    case surfaceCreationFailed(layoutID: LayoutID, attemptedID: UUID, message: String)
    /// The initial-tab bootstrap for a new worktree failed. Distinct from
    /// `surfaceCreationFailed` so only this resolves the worktree-new ack and
    /// settles creation progress; the worktree then rests with no tabs.
    case initialTabCreationFailed(layoutID: LayoutID, message: String)
  }
}

extension TerminalClient: DependencyKey {
  static let liveValue = TerminalClient(
    send: { _ in fatalError("TerminalClient.send not configured") },
    events: { fatalError("TerminalClient.events not configured") },
    listSurfaces: { fatalError("TerminalClient.listSurfaces not configured") },
    sessionPreview: { _, _ in fatalError("TerminalClient.sessionPreview not configured") },
    focusSurface: { _, _, _, _ in fatalError("TerminalClient.focusSurface not configured") },
    closeSurface: { _, _, _, _ in fatalError("TerminalClient.closeSurface not configured") },
    closeTab: { _, _ in fatalError("TerminalClient.closeTab not configured") },
    tabExists: { _, _ in fatalError("TerminalClient.tabExists not configured") },
    tabCanRename: { _, _ in fatalError("TerminalClient.tabCanRename not configured") },
    surfaceExists: { _, _, _ in fatalError("TerminalClient.surfaceExists not configured") },
    surfaceExistsInWorktree: { _, _ in fatalError("TerminalClient.surfaceExistsInWorktree not configured") },
    idExistsAnywhere: { _ in fatalError("TerminalClient.idExistsAnywhere not configured") },
    paneExists: { _, _ in fatalError("TerminalClient.paneExists not configured") },
    canMoveTabToNewSplit: { _, _ in fatalError("TerminalClient.canMoveTabToNewSplit not configured") },
    tabID: { _, _ in fatalError("TerminalClient.tabID not configured") },
    selectedTabID: { _ in fatalError("TerminalClient.selectedTabID not configured") },
    selectedSurfaceID: { _ in fatalError("TerminalClient.selectedSurfaceID not configured") },
    sendTextToSurface: { _, _, _ in fatalError("TerminalClient.sendTextToSurface not configured") },
    surfaceScreenText: { _, _ in fatalError("TerminalClient.surfaceScreenText not configured") },
    latestUnreadNotification: { fatalError("TerminalClient.latestUnreadNotification not configured") },
    markNotificationRead: { _, _ in fatalError("TerminalClient.markNotificationRead not configured") },
    markAllNotificationsRead: { fatalError("TerminalClient.markAllNotificationsRead not configured") },
    hasInflightBlockingScripts: { fatalError("TerminalClient.hasInflightBlockingScripts not configured") },
    markUserCloseIntent: { _, _ in fatalError("TerminalClient.markUserCloseIntent not configured") },
    isHarnessEndSuppressed: { _ in fatalError("TerminalClient.isHarnessEndSuppressed not configured") },
    terminateAllSessions: { fatalError("TerminalClient.terminateAllSessions not configured") },
    persistAndTerminateAllSessions: { _ in
      fatalError("TerminalClient.persistAndTerminateAllSessions not configured")
    },
    reapOrphanSessions: { _ in fatalError("TerminalClient.reapOrphanSessions not configured") },
    saveLayoutsWithAgents: { _ in fatalError("TerminalClient.saveLayoutsWithAgents not configured") }
  )

  static let testValue = TerminalClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } },
    listSurfaces: { [] },
    sessionPreview: { _, _ in nil },
    focusSurface: unimplemented("TerminalClient.focusSurface"),
    closeSurface: unimplemented("TerminalClient.closeSurface"),
    closeTab: unimplemented("TerminalClient.closeTab"),
    tabExists: unimplemented("TerminalClient.tabExists", placeholder: true),
    tabCanRename: unimplemented("TerminalClient.tabCanRename", placeholder: true),
    surfaceExists: unimplemented("TerminalClient.surfaceExists", placeholder: true),
    surfaceExistsInWorktree: unimplemented("TerminalClient.surfaceExistsInWorktree", placeholder: true),
    // Benign default: the collision gate runs on every explicit-id creation, so
    // tests that don't exercise cross-worktree collisions need not override it.
    idExistsAnywhere: { _ in false },
    paneExists: unimplemented("TerminalClient.paneExists", placeholder: true),
    canMoveTabToNewSplit: unimplemented("TerminalClient.canMoveTabToNewSplit", placeholder: true),
    tabID: unimplemented("TerminalClient.tabID", placeholder: nil),
    selectedTabID: unimplemented("TerminalClient.selectedTabID", placeholder: nil),
    selectedSurfaceID: unimplemented("TerminalClient.selectedSurfaceID", placeholder: nil),
    sendTextToSurface: unimplemented("TerminalClient.sendTextToSurface", placeholder: false),
    surfaceScreenText: unimplemented("TerminalClient.surfaceScreenText", placeholder: nil),
    latestUnreadNotification: unimplemented("TerminalClient.latestUnreadNotification", placeholder: nil),
    markNotificationRead: unimplemented("TerminalClient.markNotificationRead"),
    markAllNotificationsRead: unimplemented("TerminalClient.markAllNotificationsRead"),
    hasInflightBlockingScripts: unimplemented("TerminalClient.hasInflightBlockingScripts", placeholder: false),
    markUserCloseIntent: { _, _ in },
    isHarnessEndSuppressed: { _ in false },
    terminateAllSessions: unimplemented("TerminalClient.terminateAllSessions"),
    persistAndTerminateAllSessions: unimplemented("TerminalClient.persistAndTerminateAllSessions"),
    reapOrphanSessions: unimplemented("TerminalClient.reapOrphanSessions"),
    saveLayoutsWithAgents: unimplemented("TerminalClient.saveLayoutsWithAgents")
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
