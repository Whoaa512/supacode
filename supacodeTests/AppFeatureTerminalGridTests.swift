import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureTerminalGridTests {
  @Test(.dependencies) func setPresentedTogglesState() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree) { _ in }

    await store.send(.setTerminalGridPresented(true)) {
      $0.isTerminalGridPresented = true
    }
    await store.send(.setTerminalGridPresented(false)) {
      $0.isTerminalGridPresented = false
    }
  }

  @Test(.dependencies) func jumpDismissesGridAndFocusesSurface() async {
    let worktree = makeWorktree()
    let tabID = TerminalTabID(rawValue: UUID())
    let surfaceID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.setTerminalGridPresented(true)) {
      $0.isTerminalGridPresented = true
    }
    await store.send(
      .terminalGridJumpToSurface(worktreeID: worktree.id, tabID: tabID, surfaceID: surfaceID)
    ) {
      $0.isTerminalGridPresented = false
    }
    await store.receive(\.focusTerminalSurface)
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    let focusCommands = sent.value.filter {
      if case .focusSurface = $0 { return true } else { return false }
    }
    #expect(
      focusCommands == [.focusSurface(worktree, tabID: tabID, surfaceID: surfaceID, input: nil)])
  }

  @Test(.dependencies) func closeTabSendsDestroyTab() async {
    let worktree = makeWorktree()
    let tabID = TerminalTabID(rawValue: UUID())
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.closeTerminalTab(worktreeID: worktree.id, tabID: tabID))
    await store.finish()

    #expect(sent.value == [.destroyTab(worktree, tabID: tabID)])
  }

  @Test(.dependencies) func closeTabDropsWhenWorktreeMissing() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(
      .closeTerminalTab(
        worktreeID: WorktreeID("/tmp/repo/does-not-exist"), tabID: TerminalTabID(rawValue: UUID())))
    await store.finish()

    #expect(sent.value.isEmpty)
  }

  @Test func flattenTilesPreservesOverviewOrderAndBreadcrumbFields() {
    let tabID1 = TerminalTabID(rawValue: UUID())
    let tabID2 = TerminalTabID(rawValue: UUID())
    let surfaceA = UUID()
    let surfaceB = UUID()
    let surfaceC = UUID()
    let overviews = [
      WorktreeTerminalManager.SessionWorktreeOverview(
        id: WorktreeID("/tmp/repo/alpha"),
        name: "alpha",
        directoryName: "alpha-dir",
        tabs: [
          .init(
            id: tabID1, title: "tab-1",
            surfaces: [
              .init(id: surfaceA, isDormant: false),
              .init(id: surfaceB, isDormant: true),
            ]),
          .init(id: tabID2, title: "tab-2", surfaces: [.init(id: surfaceC, isDormant: false)]),
        ]
      )
    ]

    let tiles = TerminalGridOverviewView.flattenTiles(overviews)

    #expect(tiles.map(\.surfaceID) == [surfaceA, surfaceB, surfaceC])
    #expect(tiles.map(\.tabTitle) == ["tab-1", "tab-1", "tab-2"])
    #expect(tiles.allSatisfy { $0.directoryName == "alpha-dir" })
    #expect(tiles.map(\.kind) == [.live, .dormant, .live])
  }

  @Test func snoozedTilesComeFromPersistedLayoutsAndSkipLiveOrMissingWorktrees() {
    let liveWorktree = makeWorktree(id: "/tmp/repo/live", name: "live")
    let snoozedWorktree = makeWorktree(id: "/tmp/repo/snoozed", name: "snoozed")
    let tabID = UUID()
    let surfaceID = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        .init(
          id: tabID, title: "agent", customTitle: "my agent", icon: nil, tintColor: nil,
          layout: .leaf(.init(id: surfaceID, workingDirectory: nil)), focusedLeafIndex: 0)
      ],
      selectedTabIndex: 0
    )
    let worktrees = [liveWorktree.id: liveWorktree, snoozedWorktree.id: snoozedWorktree]

    let tiles = TerminalGridOverviewView.snoozedTiles(
      layouts: [
        liveWorktree.id.rawValue: snapshot,
        snoozedWorktree.id.rawValue: snapshot,
        "/tmp/repo/deleted": snapshot,
      ],
      excludingWorktreeIDs: [liveWorktree.id],
      worktreeLookup: { worktrees[$0] }
    )

    #expect(tiles.count == 1)
    #expect(tiles.first?.worktreeID == snoozedWorktree.id)
    #expect(tiles.first?.directoryName == "snoozed")
    #expect(tiles.first?.tabTitle == "my agent")
    #expect(tiles.first?.tabID == TerminalTabID(rawValue: tabID))
    #expect(tiles.first?.surfaceID == surfaceID)
    #expect(tiles.first?.kind == .snoozed)
  }

  @Test func columnCountGrowsWithWidthLikeAResponsiveHomePage() {
    // 14" laptop full screen: baseline three across.
    #expect(TerminalGridOverviewView.columnCount(width: 1500) == 3)
    // Wider monitors: a column appears only when it fits at the ideal width,
    // so tiles grow between breakpoints.
    #expect(TerminalGridOverviewView.columnCount(width: 2000) == 4)
    #expect(TerminalGridOverviewView.columnCount(width: 2500) == 5)
    // Narrow windows: the minimum tile width wins over the 3-column baseline.
    #expect(TerminalGridOverviewView.columnCount(width: 700) == 2)
    #expect(TerminalGridOverviewView.columnCount(width: 400) == 1)
  }

  @Test func ansiStyledTextColorsRunsAndResets() {
    let styled = AnsiStyledText.attributedString(
      from: "plain \u{1b}[32mgreen\u{1b}[0m \u{1b}[38;5;196mred256\u{1b}[39m tail")

    let runs = styled.runs.map {
      (String(styled[$0.range].characters), $0.foregroundColor != nil)
    }
    #expect(String(styled.characters) == "plain green red256 tail")
    #expect(runs.map(\.1) == [false, true, false, true, false])
  }

  @Test func scrollbackPreviewStripsEscapesAndNormalizesLineEndings() {
    let raw = "\u{1b}[32mgreen\u{1b}[0m line\r\nnext\rprogress\u{1b}]0;title\u{07}done"

    let visible = ScrollbackPreview.strippedVisibleText(raw)

    #expect(visible == "green line\nnext\nprogressdone")
  }

  // MARK: - Helpers.

  private func makeWorktree(
    id: String = "/tmp/repo/wt-1",
    name: String = "wt-1"
  ) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }

  private func makeStore(
    worktree: Worktree,
    withAdditionalDependencies: (inout DependencyValues) -> Void
  ) -> TestStoreOf<AppFeature> {
    var repositoriesState = RepositoriesFeature.State()
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree],
    )
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.isInitialLoadComplete = true

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: { values in
      values.terminalClient.tabExists = { _, _ in true }
      values.terminalClient.surfaceExists = { _, _, _ in true }
      withAdditionalDependencies(&values)
    }
    store.exhaustivity = .off
    return store
  }
}
