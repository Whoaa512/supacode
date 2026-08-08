import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// The parent half of task creation (A3/A19): a freshly captured task gets a tab
/// of its own, and that tab is claimed *for that task* only once it exists.
///
/// `createTab` returns before the surface does, so the claim is deferred until
/// the terminal reports the tab's projection — the same shape the CLI's
/// completion acks use. Promoting inline reads an empty split tree and claims
/// nothing, which is the failure this suite exists to keep out.
@MainActor
struct AppFeatureTaskTerminalTests {
  private typealias Sandbox = TaskInboxSandbox

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "AppFeatureTaskTerminalTests")
  }

  private func makeStore(
    sandbox: Sandbox,
    directory: URL,
    lifecycle: SidebarItemFeature.State.Lifecycle = .idle,
    records: [TaskRecord] = [],
    sentCommands: LockIsolated<[TerminalClient.Command]>,
    liveTabSurfaceIDs: LockIsolated<[TerminalTabID: Set<UUID>]>
  ) -> TestStoreOf<AppFeature> {
    var repositories = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      hasLoadedTasks: true
    )
    repositories.taskRecords = IdentifiedArray(uniqueElements: records)
    repositories.sidebarItems[id: WorktreeID(directory.path(percentEncoded: false))]?
      .lifecycle = lifecycle
    repositories.applyPostReduceCacheRecomputes(.all)
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = sandbox.storage
      $0.date.now = TaskInboxFixture.now
      $0.uuid = .incrementing
      $0.terminalClient.send = { command in sentCommands.withValue { $0.append(command) } }
      $0.terminalClient.tabSurfaceIDs = { _, tabID in liveTabSurfaceIDs.value[tabID] ?? [] }
      $0.terminalClient.selectedTabID = { _ in nil }
      $0.terminalClient.tabID = { _, surfaceID in
        liveTabSurfaceIDs.value.first { $0.value.contains(surfaceID) }?.key
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off
    return store
  }

  /// The created tab id, read back off the command the reducer actually sent.
  private func createdTabID(in commands: LockIsolated<[TerminalClient.Command]>) throws -> TerminalTabID {
    for command in commands.value {
      guard case .createTab(_, _, let id?, _) = command else { continue }
      return TerminalTabID(rawValue: id)
    }
    throw TestFailure.noTabCreated
  }

  private enum TestFailure: Error { case noTabCreated }

  /// The race, in one test: the tab is minted, nothing is claimed while it is
  /// empty, and the claim fires — naming the task — when the tab reports its
  /// first surface.
  @Test(.dependencies) func theTabIsClaimedOnlyOnceItReportsASurface() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: TaskInboxFixture.freshDate)
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let liveTabs = LockIsolated<[TerminalTabID: Set<UUID>]>([:])
    let store = makeStore(
      sandbox: sandbox, directory: directory, sentCommands: commands, liveTabSurfaceIDs: liveTabs)
    let worktreeID = WorktreeID(directory.path(percentEncoded: false))

    await store.send(
      .repositories(.tasks(.createTask(title: "Ship it", directoryURL: directory))))
    // Ordering: the selection is applied inside the creation arm, so by the time
    // the parent acts on the terminal request the new task is already open (A4).
    await store.receive(\.repositories.delegate.selectedWorktreeChanged)
    await store.receive(\.repositories.delegate.openTaskTerminal)
    let taskID = try #require(store.state.repositories.selection?.taskID)
    #expect(store.state.repositories.taskRecords[id: taskID]?.title == "Ship it")

    let tabID = try createdTabID(in: commands)
    // Nothing claimed yet: the tab exists on paper, but it has no split tree.
    #expect(store.state.repositories.taskRecords[id: taskID]?.surfaceIDs.isEmpty == true)
    #expect(store.state.pendingTaskTabClaims[id: tabID] != nil)

    let surfaceID = UUID()
    liveTabs.withValue { $0[tabID] = [surfaceID] }
    await store.send(
      .terminalEvent(
        .tabProjectionChanged(
          worktreeID: worktreeID,
          WorktreeTabProjection(
            tabID: tabID,
            surfaceIDs: [surfaceID],
            activeSurfaceID: surfaceID,
            unseenNotificationCount: 0
          )
        )
      )
    )
    await store.receive(\.repositories.tasks.promoteTab)
    await store.finish()

    #expect(store.state.repositories.taskRecords[id: taskID]?.surfaceIDs == [surfaceID])
    // The claim is consumed exactly once, so a later projection on the same tab
    // does not re-promote.
    #expect(store.state.pendingTaskTabClaims.isEmpty)
  }

  /// A projection for someone else's tab leaves the claim pending — the task's
  /// own tab is still coming.
  @Test(.dependencies) func anotherTabsProjectionDoesNotConsumeTheClaim() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: TaskInboxFixture.freshDate)
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let liveTabs = LockIsolated<[TerminalTabID: Set<UUID>]>([:])
    let store = makeStore(
      sandbox: sandbox, directory: directory, sentCommands: commands, liveTabSurfaceIDs: liveTabs)
    let worktreeID = WorktreeID(directory.path(percentEncoded: false))

    await store.send(
      .repositories(.tasks(.createTask(title: "Ship it", directoryURL: directory))))
    await store.receive(\.repositories.delegate.openTaskTerminal)
    let tabID = try createdTabID(in: commands)

    await store.send(
      .terminalEvent(
        .tabProjectionChanged(
          worktreeID: worktreeID,
          WorktreeTabProjection(
            tabID: TerminalTabID(),
            surfaceIDs: [UUID()],
            activeSurfaceID: nil,
            unseenNotificationCount: 0
          )
        )
      )
    )
    await store.finish()

    #expect(store.state.pendingTaskTabClaims[id: tabID] != nil)
    let taskID = try #require(store.state.repositories.selection?.taskID)
    #expect(store.state.repositories.taskRecords[id: taskID]?.surfaceIDs.isEmpty == true)
  }

  /// A tab that never materialized drops its claim rather than waiting forever.
  @Test(.dependencies) func aFailedTabCreationDropsTheClaim() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: TaskInboxFixture.freshDate)
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let liveTabs = LockIsolated<[TerminalTabID: Set<UUID>]>([:])
    let store = makeStore(
      sandbox: sandbox, directory: directory, sentCommands: commands, liveTabSurfaceIDs: liveTabs)
    let worktreeID = WorktreeID(directory.path(percentEncoded: false))

    await store.send(
      .repositories(.tasks(.createTask(title: "Ship it", directoryURL: directory))))
    await store.receive(\.repositories.delegate.openTaskTerminal)
    let tabID = try createdTabID(in: commands)

    await store.send(
      .terminalEvent(
        .surfaceCreationFailed(
          worktreeID: worktreeID, attemptedID: tabID.rawValue, message: "nope")))
    await store.finish()

    #expect(store.state.pendingTaskTabClaims.isEmpty)
  }

  /// M5: the setup script belongs to a worktree that is still being set up, not
  /// to every tab opened in it afterwards. Same rule ⌘T follows.
  @Test(.dependencies) func aSettledWorktreeDoesNotRerunItsSetupScript() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: TaskInboxFixture.freshDate)
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let liveTabs = LockIsolated<[TerminalTabID: Set<UUID>]>([:])
    let store = makeStore(
      sandbox: sandbox, directory: directory, sentCommands: commands, liveTabSurfaceIDs: liveTabs)

    await store.send(
      .repositories(.tasks(.createTask(title: "Ship it", directoryURL: directory))))
    await store.receive(\.repositories.delegate.openTaskTerminal)
    await store.finish()

    #expect(Self.runSetupScriptFlags(commands.value) == [false])
  }

  /// The control: a worktree still running its setup gets it, so the assertion
  /// above is not passing because the flag is hardcoded off.
  @Test(.dependencies) func aPendingWorktreeStillGetsItsSetupScript() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: TaskInboxFixture.freshDate)
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let liveTabs = LockIsolated<[TerminalTabID: Set<UUID>]>([:])
    let store = makeStore(
      sandbox: sandbox,
      directory: directory,
      lifecycle: .pending,
      sentCommands: commands,
      liveTabSurfaceIDs: liveTabs
    )

    await store.send(
      .repositories(.tasks(.createTask(title: "Ship it", directoryURL: directory))))
    await store.receive(\.repositories.delegate.openTaskTerminal)
    await store.finish()

    #expect(Self.runSetupScriptFlags(commands.value) == [true])
  }

  /// "Open Terminal Here" on a row reuses the creation machinery with an
  /// existing record as the claim target, so the tab has to land on the task the
  /// user right-clicked. Two tasks share this directory and the *newer* one is
  /// what a directory-resolved claim would pick, which is the bug this pins:
  /// the older, surface-less row is the one that asked.
  @Test(.dependencies) func openTerminalClaimsTheTabForTheTaskThatAskedForIt() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: TaskInboxFixture.freshDate)
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let liveTabs = LockIsolated<[TerminalTabID: Set<UUID>]>([:])
    let stranded = TaskInboxFixture.makeRecord(
      directory: directory,
      createdAt: TaskInboxFixture.freshDate.addingTimeInterval(-600)
    )
    let newer = TaskInboxFixture.makeRecord(
      directory: directory,
      surfaceIDs: [UUID()],
      createdAt: TaskInboxFixture.freshDate
    )
    let store = makeStore(
      sandbox: sandbox,
      directory: directory,
      records: [stranded, newer],
      sentCommands: commands,
      liveTabSurfaceIDs: liveTabs
    )
    let worktreeID = WorktreeID(directory.path(percentEncoded: false))

    await store.send(.repositories(.tasks(.openTerminal(stranded.id))))
    await store.receive(\.repositories.delegate.openTaskTerminal)
    let tabID = try createdTabID(in: commands)
    #expect(store.state.pendingTaskTabClaims[id: tabID]?.taskID == stranded.id)

    let surfaceID = UUID()
    liveTabs.withValue { $0[tabID] = [surfaceID] }
    await store.send(
      .terminalEvent(
        .tabProjectionChanged(
          worktreeID: worktreeID,
          WorktreeTabProjection(
            tabID: tabID,
            surfaceIDs: [surfaceID],
            activeSurfaceID: surfaceID,
            unseenNotificationCount: 0
          )
        )
      )
    )
    await store.receive(\.repositories.tasks.promoteTab)
    await store.finish()

    #expect(store.state.repositories.taskRecords[id: stranded.id]?.surfaceIDs == [surfaceID])
    #expect(store.state.repositories.taskRecords[id: newer.id]?.surfaceIDs.contains(surfaceID) == false)
  }

  private static func runSetupScriptFlags(_ commands: [TerminalClient.Command]) -> [Bool] {
    commands.compactMap { command in
      guard case .createTab(_, let runSetupScriptIfNew, _, _) = command else { return nil }
      return runSetupScriptIfNew
    }
  }
}
