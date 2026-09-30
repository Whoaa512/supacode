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
      store.withState { $0.terminals.layouts[id: worktree.id]?.layout.focusedPaneID }
    }

    func focus(forward: Bool) {
      manager.handleCommand(.focusRelativePane(worktree, forward: forward))
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
      $0.contentRuntime = ContentRuntime()
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        InertTabContent(id: request.contentID, state: request.content)
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    manager.appStore = store
    store.send(
      .terminals(.layoutsHydrated(LayoutsFile(worktrees: [worktree.id.rawValue: LayoutRecord(layout: layout)])))
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
}
