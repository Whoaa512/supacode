import Clocks
import Foundation
import GhosttyKit
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct TerminalSurfaceRecipeTests {
  private static func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/recipe-fixture/wt"),
      name: "wt",
      detail: "detail",
      // Explicit hints: fileURLWithPath would stat the path and grow a
      // trailing slash the moment the directory exists on the test machine.
      workingDirectory: URL(filePath: "/tmp/recipe-fixture/wt", directoryHint: .notDirectory),
      repositoryRootURL: URL(filePath: "/tmp/recipe-fixture", directoryHint: .notDirectory)
    )
  }

  @Test func environmentCarriesIdentityMarkers() {
    let tabID = TabID()
    let surfaceID = UUID()
    let env = TerminalSurfaceRecipe.environment(
      for: DirectoryContext(worktree: Self.makeWorktree()),
      layoutID: LayoutID(task: UUID()),
      tabID: tabID,
      surfaceID: surfaceID,
      socketPath: "/tmp/socket"
    )
    // Slashes are deliberately encoded: downstream deeplinks embed these IDs.
    #expect(env["SUPACODE_REPO_ID"] == "%2Ftmp%2Frecipe-fixture")
    #expect(env["SUPACODE_WORKTREE_ID"] == "%2Ftmp%2Frecipe-fixture%2Fwt")
    #expect(env["SUPACODE_TAB_ID"] == tabID.rawValue.uuidString)
    #expect(env["SUPACODE_SURFACE_ID"] == surfaceID.uuidString)
    #expect(env["SUPACODE_SOCKET_PATH"] == "/tmp/socket")
    #expect(env["ZMX_DIR"] != nil)
  }

  @Test func twoTasksOnOneDirectoryShareTheWorktreeIDAndDifferByTaskID() {
    let context = DirectoryContext(worktree: Self.makeWorktree())
    let minted = LayoutID(task: UUID())
    // The task a directory had before tasks is keyed by its path, so its id is
    // encoded the same way the worktree id is.
    let ownKey = Self.makeWorktree().id.layoutID
    let mintedEnv = TerminalSurfaceRecipe.environment(
      for: context, layoutID: minted, tabID: TabID(), surfaceID: UUID(), socketPath: nil)
    let ownKeyEnv = TerminalSurfaceRecipe.environment(
      for: context, layoutID: ownKey, tabID: TabID(), surfaceID: UUID(), socketPath: nil)
    #expect(mintedEnv["SUPACODE_WORKTREE_ID"] == "%2Ftmp%2Frecipe-fixture%2Fwt")
    #expect(ownKeyEnv["SUPACODE_WORKTREE_ID"] == "%2Ftmp%2Frecipe-fixture%2Fwt")
    #expect(mintedEnv["SUPACODE_TASK_ID"] == minted.persistenceKey)
    #expect(ownKeyEnv["SUPACODE_TASK_ID"] == "%2Ftmp%2Frecipe-fixture%2Fwt")
    #expect(LayoutID(external: mintedEnv["SUPACODE_TASK_ID"] ?? "") == minted)
    #expect(LayoutID(external: ownKeyEnv["SUPACODE_TASK_ID"] ?? "") == ownKey)
  }

  @Test func environmentOmitsSocketWhenAbsent() {
    let env = TerminalSurfaceRecipe.environment(
      for: DirectoryContext(worktree: Self.makeWorktree()),
      layoutID: LayoutID(task: UUID()),
      tabID: TabID(),
      surfaceID: UUID(),
      socketPath: nil
    )
    #expect(env["SUPACODE_SOCKET_PATH"] == nil)
  }

  @Test func extraVariablesCannotOverrideTheZmxDirectoryLock() {
    let env = TerminalSurfaceRecipe.environment(
      for: DirectoryContext(worktree: Self.makeWorktree()),
      layoutID: LayoutID(task: UUID()),
      tabID: TabID(),
      surfaceID: UUID(),
      socketPath: nil,
      extraVariables: ["ZMX_DIR": "/evil", "SUPACODE_SCRIPT": "1"]
    )
    #expect(env["ZMX_DIR"] == ZmxSocketBudget.socketDir())
    #expect(env["SUPACODE_SCRIPT"] == "1")
  }

  @Test func bypassingZmxKeepsTheCommandVerbatim() {
    let launch = TerminalSurfaceRecipe.launch(
      TerminalSurfaceRecipe.LaunchIntent(command: "./script.sh", initialInput: "input\n", bypassZmx: true),
      for: DirectoryContext(worktree: Self.makeWorktree()),
      surfaceID: UUID(),
      zmxExecutablePath: "/usr/local/bin/zmx"
    )
    #expect(launch.command == "./script.sh")
    #expect(launch.initialInput == "input\n")
    #expect(launch.commandWrapper.isEmpty)
    #expect(launch.usesZmx == false)
  }

  @Test func localLaunchDerivesTheSessionFromTheSurfaceID() {
    let surfaceID = UUID()
    let launch = TerminalSurfaceRecipe.launch(
      TerminalSurfaceRecipe.LaunchIntent(),
      for: DirectoryContext(worktree: Self.makeWorktree()),
      surfaceID: surfaceID,
      zmxExecutablePath: "/usr/local/bin/zmx"
    )
    // The session name is the surface identity; hibernated wakes and the CLI
    // both address it by this derivation.
    #expect(launch.usesZmx)
    #expect(launch.commandWrapper.contains(ZmxSessionID.make(surfaceID: surfaceID)))
  }

  // MARK: - Surface plans.

  private static func makeRequest(
    state: TerminalContentState = TerminalContentState(workingDirectory: nil),
    origin: ContentOrigin = .tab
  ) -> ContentRequest {
    ContentRequest(
      worktreeID: makeWorktree().id.layoutID,
      tabID: TabID(),
      contentID: ContentID(),
      content: .terminal(state),
      origin: origin
    )
  }

  @Test func planMapsOriginsToSurfaceContexts() {
    let worktree = Self.makeWorktree()
    let state = TerminalContentState(workingDirectory: nil)
    func context(of origin: ContentOrigin) -> ghostty_surface_context_e {
      TerminalSurfaceRecipe.plan(
        for: Self.makeRequest(state: state, origin: origin),
        seed: TerminalSurfaceRecipe.PlanSeed(
          terminalState: state,
          directory: DirectoryContext(worktree: worktree),
          socketPath: nil,
          zmxExecutablePath: nil
        )
      ).context
    }
    #expect(context(of: .first) == GHOSTTY_SURFACE_CONTEXT_WINDOW)
    #expect(context(of: .tab) == GHOSTTY_SURFACE_CONTEXT_TAB)
    #expect(context(of: .restored) == GHOSTTY_SURFACE_CONTEXT_TAB)
    #expect(context(of: .split) == GHOSTTY_SURFACE_CONTEXT_SPLIT)
  }

  @Test func planPrefersThePersistedWorkingDirectory() {
    let worktree = Self.makeWorktree()
    let persistedState = TerminalContentState(workingDirectory: "/tmp/elsewhere")
    let persisted = TerminalSurfaceRecipe.plan(
      for: Self.makeRequest(state: persistedState),
      seed: TerminalSurfaceRecipe.PlanSeed(
        terminalState: persistedState,
        directory: DirectoryContext(worktree: worktree),
        socketPath: nil,
        zmxExecutablePath: nil
      )
    )
    #expect(persisted.workingDirectory?.path(percentEncoded: false).hasPrefix("/tmp/elsewhere") == true)
    let emptyState = TerminalContentState(workingDirectory: nil)
    let fallback = TerminalSurfaceRecipe.plan(
      for: Self.makeRequest(state: emptyState),
      seed: TerminalSurfaceRecipe.PlanSeed(
        terminalState: emptyState,
        directory: DirectoryContext(worktree: worktree),
        socketPath: nil,
        zmxExecutablePath: nil
      )
    )
    #expect(fallback.workingDirectory == worktree.workingDirectory)
  }

  @Test func planCarriesTheFrozenFontAndIdentityEnvironment() throws {
    let worktree = Self.makeWorktree()
    let grid = try #require(
      FrozenGrid.from(backingSize: CGSize(width: 800, height: 600), columns: 80, rows: 24, scale: 2, fontSize: 13)
    )
    let state = TerminalContentState(workingDirectory: nil, frozenGrid: grid)
    let request = Self.makeRequest(state: state, origin: .restored)
    let plan = TerminalSurfaceRecipe.plan(
      for: request,
      seed: TerminalSurfaceRecipe.PlanSeed(
        terminalState: state,
        directory: DirectoryContext(worktree: worktree),
        socketPath: "/tmp/socket",
        zmxExecutablePath: "/usr/local/bin/zmx",
        // A frozen grid outranks any fallback font: the frozen backing size
        // only reproduces the grid at the frozen font.
        fallbackFontSize: 99
      )
    )
    #expect(plan.fontSize == 13)
    #expect(plan.environment["SUPACODE_TASK_ID"] == request.worktreeID.externalID)
    #expect(plan.environment["SUPACODE_TAB_ID"] == request.tabID.rawValue.uuidString)
    #expect(plan.environment["SUPACODE_SURFACE_ID"] == request.contentID.rawValue.uuidString)
    // The re-attach targets the zmx session derived from the content identity.
    #expect(plan.commandWrapper.contains(ZmxSessionID.make(surfaceID: request.contentID.rawValue)))
  }

  // MARK: - A content's owner is looked up, never remembered.

  /// What a builder hands its collaborators for each surface it builds.
  @MainActor
  private final class BuildLog {
    var owner: LayoutID?
    var wired: [ContentRequest] = []
    var extras: [ContentRequest] = []
    var directories: [LayoutID] = []
  }

  private static func makeBuilder(_ log: BuildLog) -> TerminalContentBuilder {
    // Inert teardown: nothing is detached and the child counts as exited.
    let queue = SurfaceTeardownQueue(
      detachClients: { _ in }, clock: ImmediateClock(),
      analytics: AnalyticsClient(capture: { _, _ in }, identify: { _ in }), hasProcessExited: { _ in true })
    return TerminalContentBuilder(
      runtime: GhosttyRuntime(surfaceTeardownQueue: queue),
      directory: { id in
        log.directories.append(id)
        return DirectoryContext(worktree: makeWorktree())
      },
      owner: { _ in log.owner },
      socketPath: { nil },
      zmxExecutablePath: { nil },
      sourceSurface: { _ in nil },
      wireSurface: { _, request in log.wired.append(request) },
      environmentExtras: { request in
        log.extras.append(request)
        return [:]
      },
      initialScrollbackPath: { _ in nil }
    )
  }

  private static func request(in layoutID: LayoutID) -> ContentRequest {
    ContentRequest(
      worktreeID: layoutID, tabID: TabID(), contentID: ContentID(),
      content: .terminal(TerminalContentState(workingDirectory: nil)), origin: .tab)
  }

  @Test func rewakeUsesTheCurrentOwner() {
    let created = LayoutID(task: UUID())
    let movedTo = LayoutID(task: UUID())
    let log = BuildLog()
    let content = Self.makeBuilder(log).factory().make(Self.request(in: created))
    content.startSession(at: .fallback)
    #expect(log.wired.map(\.worktreeID) == [created])

    // The tab moved to another task while hibernated.
    content.hibernate()
    log.owner = movedTo
    log.directories = []
    content.startSession(at: .fallback)

    #expect(log.wired.map(\.worktreeID) == [created, movedTo])
    #expect(log.extras.map(\.worktreeID) == [created, movedTo])
    #expect(log.directories == [movedTo], "the wake resolves the holder's directory")
    let plan = TerminalSurfaceRecipe.plan(
      for: log.wired[1],
      seed: TerminalSurfaceRecipe.PlanSeed(
        terminalState: TerminalContentState(workingDirectory: nil),
        directory: DirectoryContext(worktree: Self.makeWorktree()), socketPath: nil, zmxExecutablePath: nil))
    #expect(plan.environment["SUPACODE_TASK_ID"] == movedTo.externalID)
  }

  @Test func firstSpawnKeepsTheRequestOwner() {
    let created = LayoutID(task: UUID())
    let log = BuildLog()
    let content = Self.makeBuilder(log).factory().make(Self.request(in: created))

    // Provisioning runs before the tab is in any layout: nothing holds it.
    content.startSession(at: .fallback)

    #expect(log.wired.map(\.worktreeID) == [created])
    #expect(log.directories.allSatisfy { $0 == created })
  }
}
