import Foundation
import Testing

@testable import supacode

struct TerminalRestorePrunerTests {
  // MARK: - Scrollback triviality

  @Test func emptyDataIsTrivial() {
    #expect(!TerminalRestorePruner.isScrollbackMeaningful(Data()))
  }

  @Test func promptOnlyDumpIsTrivial() {
    // Typical fresh-shell dump: OSC title, CSI colors, one prompt line.
    let dump = "\u{1b}]0;zsh\u{07}\u{1b}[1m\u{1b}[32m~/code/supacode\u{1b}[0m $ \r\n"
    #expect(!TerminalRestorePruner.isScrollbackMeaningful(Data(dump.utf8)))
  }

  @Test func fiveContentLinesIsTrivial() {
    let dump = (1...5).map { "line \($0)" }.joined(separator: "\r\n")
    #expect(!TerminalRestorePruner.isScrollbackMeaningful(Data(dump.utf8)))
  }

  @Test func sixContentLinesIsMeaningful() {
    let dump = (1...6).map { "line \($0)" }.joined(separator: "\r\n")
    #expect(TerminalRestorePruner.isScrollbackMeaningful(Data(dump.utf8)))
  }

  @Test func escapeOnlyLinesDoNotCount() {
    let dump = Array(repeating: "\u{1b}[2J\u{1b}[H\u{1b}]0;title\u{07}", count: 20)
      .joined(separator: "\r\n")
    #expect(!TerminalRestorePruner.isScrollbackMeaningful(Data(dump.utf8)))
  }

  @Test func whitespaceOnlyLinesDoNotCount() {
    let dump = Array(repeating: "   \t  ", count: 20).joined(separator: "\n")
    #expect(!TerminalRestorePruner.isScrollbackMeaningful(Data(dump.utf8)))
  }

  @Test func oversizedDumpIsMeaningfulWithoutParsing() {
    // All escape bytes, but over the parse cap: treated as meaningful.
    let dump = String(repeating: "\u{1b}[2J", count: 8192)
    #expect(dump.utf8.count > TerminalRestorePruner.parseByteLimit)
    #expect(TerminalRestorePruner.isScrollbackMeaningful(Data(dump.utf8)))
  }

  @Test func oscTerminatedByStringTerminatorIsStripped() {
    let dump = "\u{1b}]633;stuff\u{1b}\\prompt $\n"
    #expect(TerminalRestorePruner.contentLineCount(dump) == 1)
  }

  @Test func trailingLineWithoutNewlineCounts() {
    #expect(TerminalRestorePruner.contentLineCount("no newline") == 1)
  }

  // MARK: - Snapshot pruning

  private func leaf(_ id: UUID?) -> TerminalLayoutSnapshot.LayoutNode {
    .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: id, workingDirectory: nil))
  }

  private func split(
    _ left: TerminalLayoutSnapshot.LayoutNode,
    _ right: TerminalLayoutSnapshot.LayoutNode
  ) -> TerminalLayoutSnapshot.LayoutNode {
    .split(
      TerminalLayoutSnapshot.SplitSnapshot(
        direction: .horizontal, ratio: 0.5, left: left, right: right))
  }

  private func tab(
    _ layout: TerminalLayoutSnapshot.LayoutNode,
    focusedLeafIndex: Int = 0
  ) -> TerminalLayoutSnapshot.TabSnapshot {
    TerminalLayoutSnapshot.TabSnapshot(
      id: UUID(),
      title: "tab",
      customTitle: nil,
      icon: nil,
      tintColor: nil,
      layout: layout,
      focusedLeafIndex: focusedLeafIndex
    )
  }

  @Test func fullyPrunedSnapshotReturnsNil() {
    let snapshot = TerminalLayoutSnapshot(tabs: [tab(leaf(UUID()))], selectedTabIndex: 0)
    #expect(TerminalRestorePruner.prunedSnapshot(snapshot) { _ in false } == nil)
  }

  @Test func nothingPrunedReturnsIdenticalSnapshot() {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [tab(split(leaf(UUID()), leaf(UUID())), focusedLeafIndex: 1)],
      selectedTabIndex: 0
    )
    #expect(TerminalRestorePruner.prunedSnapshot(snapshot) { _ in true } == snapshot)
  }

  @Test func splitCollapsesOntoSurvivingChild() {
    let keep = UUID()
    let drop = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [tab(split(leaf(drop), leaf(keep)))],
      selectedTabIndex: 0
    )
    let pruned = TerminalRestorePruner.prunedSnapshot(snapshot) { $0.id == keep }
    #expect(pruned?.tabs.count == 1)
    #expect(pruned?.tabs.first?.layout == leaf(keep))
  }

  @Test func emptyTabDropsAndSelectedTabRemaps() {
    let keep = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [tab(leaf(UUID())), tab(leaf(keep))],
      selectedTabIndex: 1
    )
    let pruned = TerminalRestorePruner.prunedSnapshot(snapshot) { $0.id == keep }
    #expect(pruned?.tabs.count == 1)
    #expect(pruned?.selectedTabIndex == 0)
  }

  @Test func droppedSelectedTabClampsToZero() {
    let keep = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [tab(leaf(keep)), tab(leaf(UUID()))],
      selectedTabIndex: 1
    )
    let pruned = TerminalRestorePruner.prunedSnapshot(snapshot) { $0.id == keep }
    #expect(pruned?.tabs.count == 1)
    #expect(pruned?.selectedTabIndex == 0)
  }

  @Test func focusedLeafIndexRemapsToSurvivor() {
    let keep = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        tab(split(leaf(UUID()), split(leaf(UUID()), leaf(keep))), focusedLeafIndex: 2)
      ],
      selectedTabIndex: 0
    )
    let pruned = TerminalRestorePruner.prunedSnapshot(snapshot) { $0.id == keep }
    #expect(pruned?.tabs.first?.focusedLeafIndex == 0)
  }

  @Test func prunedFocusedLeafFallsBackToZero() {
    let keep = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [tab(split(leaf(keep), leaf(UUID())), focusedLeafIndex: 1)],
      selectedTabIndex: 0
    )
    let pruned = TerminalRestorePruner.prunedSnapshot(snapshot) { $0.id == keep }
    #expect(pruned?.tabs.first?.focusedLeafIndex == 0)
  }
}

// Serialized: spins real GhosttyRuntime surfaces like the other terminal suites.
@MainActor
@Suite(.serialized)
struct RestorePruneEnsureInitialTabTests {
  private func makeWorktree(id: String = "/tmp/repo/wt-prune") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func snapshot(leafIDs: [UUID]) -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshot(
      tabs: leafIDs.map { id in
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: id, workingDirectory: nil)),
          focusedLeafIndex: 0
        )
      },
      selectedTabIndex: 0
    )
  }

  @Test func fullyBareSnapshotRestoresNoTabs() {
    let state = WorktreeTerminalState(runtime: GhosttyRuntime(), worktree: makeWorktree())
    state.pendingLayoutSnapshot = snapshot(leafIDs: [UUID(), UUID()])
    state.scrollbackDataProvider = { _ in nil }
    var prunedFired = false
    state.onRestorePruned = { prunedFired = true }

    state.ensureInitialTab(focusing: false)

    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.pendingLayoutSnapshot == nil)
    #expect(state.hasAttemptedInitialTab)
    #expect(prunedFired)
  }

  @Test func meaningfulScrollbackKeepsItsTabAndDropsBareOne() {
    let keep = UUID()
    let bare = UUID()
    let state = WorktreeTerminalState(runtime: GhosttyRuntime(), worktree: makeWorktree())
    state.pendingLayoutSnapshot = snapshot(leafIDs: [keep, bare])
    state.scrollbackDataProvider = { id in
      guard id == keep else { return nil }
      return Data((1...10).map { "line \($0)" }.joined(separator: "\n").utf8)
    }
    var prunedFired = false
    state.onRestorePruned = { prunedFired = true }

    state.ensureInitialTab(focusing: false)

    #expect(state.tabManager.tabs.count == 1)
    #expect(state.allSurfaceIDs == [keep])
    #expect(prunedFired)
    state.closeAllSurfaces()
  }

  @Test func untouchedSnapshotDoesNotFirePrunedCallback() {
    let keep = UUID()
    let state = WorktreeTerminalState(runtime: GhosttyRuntime(), worktree: makeWorktree())
    state.pendingLayoutSnapshot = snapshot(leafIDs: [keep])
    state.scrollbackDataProvider = { _ in
      Data((1...10).map { "line \($0)" }.joined(separator: "\n").utf8)
    }
    var prunedFired = false
    state.onRestorePruned = { prunedFired = true }

    state.ensureInitialTab(focusing: false)

    #expect(state.tabManager.tabs.count == 1)
    #expect(!prunedFired)
    state.closeAllSurfaces()
  }
}
