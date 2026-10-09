import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import SupacodeSettingsFeature
import SupacodeSettingsShared
import Testing

@testable import supacode

/// `focusRelativePane` walks the split tree's leaves in visual order and wraps,
/// restoring the pre-pane `goto_split:next/previous` muscle memory.
@MainActor
struct WorktreeTerminalManagerPaneCycleTests {
  private struct Harness {
    let manager: WorktreeTerminalManager
    let store: Store<AppFeature.State, AppFeature.Action>
    let worktree: Worktree
    let paneIDs: [PaneID]

    var focusedPaneID: PaneID? {
      store.withState { $0.terminals.layouts[id: worktree.id.layoutID]?.layout.focusedPaneID }
    }

    func focus(forward: Bool) {
      manager.handleCommand(.focusRelativePane(worktree.id.layoutID, forward: forward))
    }
  }

  /// Three panes laid out as `[a | [b / c]]`, so leaf order is a, b, c.
  private func makeHarness() throws -> Harness {
    let worktree = Worktree(
      id: WorktreeID("/tmp/repo/wt-relative-pane"),
      name: "wt-relative-pane",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-relative-pane"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let paneIDs = [PaneID(), PaneID(), PaneID()]
    let tree = try SplitTree(view: paneIDs[0])
      .inserting(view: paneIDs[1], at: paneIDs[0], direction: .right)
      .inserting(view: paneIDs[2], at: paneIDs[1], direction: .down)
    let layout = PaneLayout(
      tree: tree,
      panes: IdentifiedArray(uniqueElements: paneIDs.map(Self.pane)),
      focusedPaneID: paneIDs[0]
    )
    let manager = withDependencies {
      $0.settingsFileStorage = .inMemory()
      $0.defaultAppStorage = .inMemory
      $0.zmxClient = .noop
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let store = Store(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      // A tab change rebuilds the sessions sidebar rows, which are stamped.
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.contentRuntime = ContentRuntime()
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        InertTabContent(id: request.contentID, state: request.content)
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    manager.appStore = store
    store.send(
      .terminals(
        .layoutsHydrated(
          TaskLayoutsFile(
            oneTaskPerDirectory: LayoutsFile(worktrees: [worktree.id.rawValue: LayoutRecord(layout: layout)]))
        ))
    )
    return Harness(manager: manager, store: store, worktree: worktree, paneIDs: paneIDs)
  }

  private static func pane(_ id: PaneID) -> Pane {
    let tabID = TabID(rawValue: UUID())
    return Pane(
      id: id,
      tabs: [
        TabItem(
          id: tabID,
          title: "Tab",
          content: ContentSnapshot(
            id: ContentID(rawValue: tabID.rawValue),
            state: .terminal(TerminalContentState(workingDirectory: nil))
          )
        )
      ],
      selectedTabID: tabID
    )
  }

  @Test(.dependencies) func forwardCyclesLeavesInVisualOrderAndWraps() throws {
    let harness = try makeHarness()
    #expect(harness.focusedPaneID == harness.paneIDs[0])

    harness.focus(forward: true)
    #expect(harness.focusedPaneID == harness.paneIDs[1])
    harness.focus(forward: true)
    #expect(harness.focusedPaneID == harness.paneIDs[2])
    harness.focus(forward: true)
    #expect(harness.focusedPaneID == harness.paneIDs[0])
  }

  @Test(.dependencies) func backwardCyclesLeavesInReverseOrderAndWraps() throws {
    let harness = try makeHarness()

    harness.focus(forward: false)
    #expect(harness.focusedPaneID == harness.paneIDs[2])
    harness.focus(forward: false)
    #expect(harness.focusedPaneID == harness.paneIDs[1])
    harness.focus(forward: false)
    #expect(harness.focusedPaneID == harness.paneIDs[0])
  }

  // MARK: - Relative tab selection stays inside its layout

  private struct TabHarness {
    let manager: WorktreeTerminalManager
    let store: Store<AppFeature.State, AppFeature.Action>
    let near: LayoutID
    let far: LayoutID

    func tabIDs(_ layoutID: LayoutID) -> [TabID]? {
      store.withState { $0.terminals.layouts[id: layoutID]?.layout.panes.first?.tabs.map(\.id) }
    }

    func selectedIndex(_ layoutID: LayoutID) -> Int? {
      store.withState { state in
        guard let pane = state.terminals.layouts[id: layoutID]?.layout.panes.first else { return nil }
        return pane.selectedTabID.flatMap { pane.tabs.index(id: $0) }
      }
    }

    var selectedLayoutID: LayoutID? { store.withState { $0.terminals.selectedLayoutID } }
    var layoutIDs: [LayoutID] { store.withState { $0.terminals.layouts.map(\.id) } }
  }

  private static func tabbedLayout(tabCount: Int) -> PaneLayout {
    let paneID = PaneID()
    let tabs = (0..<tabCount).map { _ in Self.pane(PaneID()).tabs[0] }
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs[0].id)],
      focusedPaneID: paneID)
  }

  /// Two layouts of one pane each: `near` with three tabs, `far` with two.
  private func makeTabHarness() -> TabHarness {
    let near = WorktreeID("/tmp/repo/wt-near")
    let far = WorktreeID("/tmp/repo/wt-far")
    let manager = withDependencies {
      $0.settingsFileStorage = .inMemory()
      $0.defaultAppStorage = .inMemory
      $0.zmxClient = .noop
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let store = Store(
      initialState: AppFeature.State(repositories: RepositoriesFeature.State(), settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.contentRuntime = ContentRuntime()
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        InertTabContent(id: request.contentID, state: request.content)
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    manager.appStore = store
    store.send(
      .terminals(
        .layoutsHydrated(
          TaskLayoutsFile(
            oneTaskPerDirectory: LayoutsFile(worktrees: [
              near.rawValue: LayoutRecord(layout: Self.tabbedLayout(tabCount: 3)),
              far.rawValue: LayoutRecord(layout: Self.tabbedLayout(tabCount: 2)),
            ])))))
    return TabHarness(manager: manager, store: store, near: near.layoutID, far: far.layoutID)
  }

  @Test(.dependencies, arguments: [true, false])
  func relativeTabStaysInsideItsLayout(forward: Bool) {
    let harness = makeTabHarness()
    let nearTabs = harness.tabIDs(harness.near)
    let farTabs = harness.tabIDs(harness.far)
    let layoutIDs = harness.layoutIDs
    let selectedLayoutID = harness.selectedLayoutID
    #expect(nearTabs?.count == 3)
    #expect(farTabs?.count == 2)
    #expect(harness.selectedIndex(harness.near) == 0)

    var visited: [Int?] = []
    for _ in 0..<4 {
      harness.manager.handleCommand(.selectRelativeTab(harness.near, forward: forward))
      visited.append(harness.selectedIndex(harness.near))
    }

    #expect(visited == (forward ? [1, 2, 0, 1] : [2, 1, 0, 2]), "walks the layout's own tabs and wraps")
    #expect(harness.selectedIndex(harness.far) == 0, "another task's tab is never touched")
    #expect(harness.tabIDs(harness.near) == nearTabs, "no tab is created or closed")
    #expect(harness.tabIDs(harness.far) == farTabs)
    #expect(harness.layoutIDs == layoutIDs)
    #expect(harness.selectedLayoutID == selectedLayoutID)
  }

  @Test(.dependencies, arguments: [true, false])
  func relativeTabOnAnEmptyOrUnknownLayoutDoesNothing(forward: Bool) {
    let harness = makeTabHarness()
    let empty = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!)
    let unknown = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!)
    harness.store.send(
      .terminals(
        .attachLayout(
          worktreeID: empty, directory: TaskRecord.Directory(worktreeID: "/tmp/repo/wt-near"), titlePrefix: "near")))
    let layoutIDs = harness.layoutIDs
    #expect(layoutIDs.contains(empty))
    let nearTabs = harness.tabIDs(harness.near)

    harness.manager.handleCommand(.selectRelativeTab(empty, forward: forward))
    harness.manager.handleCommand(.selectRelativeTab(unknown, forward: forward))

    #expect(harness.layoutIDs == layoutIDs, "no layout is created for an id that has none")
    #expect(
      harness.store.withState { $0.terminals.layouts[id: empty]?.layout.panes.allSatisfy(\.tabs.isEmpty) } == true)
    #expect(harness.tabIDs(harness.near) == nearTabs)
    #expect(harness.selectedIndex(harness.near) == 0)
    #expect(harness.selectedLayoutID == nil)
  }
}
