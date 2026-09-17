import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import supacode

struct TerminalRestorePrunerTests {
  @Test func emptyDataIsTrivial() {
    #expect(!TerminalRestorePruner.isScrollbackMeaningful(Data()))
  }

  @Test func promptOnlyDumpIsTrivial() {
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

  @Test func escapeAndWhitespaceOnlyLinesAreTrivial() {
    let escapeLines = Array(repeating: "\u{1b}[2J\u{1b}[H\u{1b}]0;title\u{07}", count: 20)
      .joined(separator: "\r\n")
    let whitespaceLines = Array(repeating: "   \t  ", count: 20).joined(separator: "\n")
    #expect(!TerminalRestorePruner.isScrollbackMeaningful(Data(escapeLines.utf8)))
    #expect(!TerminalRestorePruner.isScrollbackMeaningful(Data(whitespaceLines.utf8)))
  }

  @Test func oversizedDumpFailsOpen() {
    let dump = String(repeating: "\u{1b}[2J", count: 8192)
    #expect(dump.utf8.count > TerminalRestorePruner.parseByteLimit)
    #expect(TerminalRestorePruner.isScrollbackMeaningful(Data(dump.utf8)))
  }

  @Test func stringTerminatedOSCIsStripped() {
    #expect(TerminalRestorePruner.contentLineCount("\u{1b}]633;stuff\u{1b}\\prompt $\n") == 1)
  }

  @Test func pruneGateRequiresEverySafetySignal() {
    #expect(
      TerminalRestorePruner.shouldPrune(
        isRemote: false,
        settingEnabled: true,
        scrollbackEnabled: true,
        zmxBundled: true,
        liveSessionNames: []
      ))
    #expect(
      !TerminalRestorePruner.shouldPrune(
        isRemote: true,
        settingEnabled: true,
        scrollbackEnabled: true,
        zmxBundled: true,
        liveSessionNames: []
      ))
    #expect(
      !TerminalRestorePruner.shouldPrune(
        isRemote: false,
        settingEnabled: false,
        scrollbackEnabled: true,
        zmxBundled: true,
        liveSessionNames: []
      ))
    #expect(
      !TerminalRestorePruner.shouldPrune(
        isRemote: false,
        settingEnabled: true,
        scrollbackEnabled: false,
        zmxBundled: true,
        liveSessionNames: []
      ))
    #expect(
      !TerminalRestorePruner.shouldPrune(
        isRemote: false,
        settingEnabled: true,
        scrollbackEnabled: true,
        zmxBundled: false,
        liveSessionNames: []
      ))
    #expect(
      !TerminalRestorePruner.shouldPrune(
        isRemote: false,
        settingEnabled: true,
        scrollbackEnabled: true,
        zmxBundled: true,
        liveSessionNames: nil
      ))
  }

  @Test func fullyPrunedLayoutReturnsNil() {
    let contentID = ContentID()
    let layout = makeLayout(panes: [makePane(contents: [contentID])])
    #expect(TerminalRestorePruner.prunedLayout(layout) { _ in false } == nil)
  }

  @Test func nothingPrunedReturnsIdenticalLayout() {
    let layout = makeLayout(
      panes: [makePane(contents: [ContentID(), ContentID()])]
    )
    #expect(TerminalRestorePruner.prunedLayout(layout) { _ in true } == layout)
  }

  @Test func emptyPaneDropsAndTreeCollapses() throws {
    let dropped = ContentID()
    let kept = ContentID()
    let left = makePane(contents: [dropped])
    let right = makePane(contents: [kept])
    let layout = makeLayout(panes: [left, right], focusedPaneID: left.id)

    let pruned = try #require(
      TerminalRestorePruner.prunedLayout(layout) { $0.id == kept })

    #expect(pruned.panes.ids == [right.id])
    #expect(pruned.tree.leaves() == [right.id])
    #expect(pruned.focusedPaneID == right.id)
  }

  @Test func droppedSelectedTabFallsBackToFirstSurvivor() throws {
    let kept = ContentID()
    let dropped = ContentID()
    let pane = makePane(contents: [kept, dropped], selectedIndex: 1)
    let layout = makeLayout(panes: [pane])

    let pruned = try #require(
      TerminalRestorePruner.prunedLayout(layout) { $0.id == kept })

    #expect(pruned.panes.first?.tabs.map(\.content.id) == [kept])
    #expect(pruned.panes.first?.selectedTabID == pruned.panes.first?.tabs.first?.id)
  }

  private func makePane(
    contents: [ContentID],
    selectedIndex: Int = 0
  ) -> Pane {
    let tabs = IdentifiedArray(uniqueElements: contents.map { contentID in
      TabItem(
        id: TabID(),
        title: "tab",
        content: ContentSnapshot(
          id: contentID,
          state: .terminal(TerminalContentState(workingDirectory: nil))
        )
      )
    })
    return Pane(
      id: PaneID(),
      tabs: tabs,
      selectedTabID: tabs.indices.contains(selectedIndex) ? tabs[selectedIndex].id : nil
    )
  }

  private func makeLayout(
    panes: [Pane],
    focusedPaneID: PaneID? = nil
  ) -> PaneLayout {
    let identified = IdentifiedArray(uniqueElements: panes)
    let tree: SplitTree<PaneID>
    if panes.count == 2 {
      tree = SplitTree(
        root: .split(
          .init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(view: panes[0].id),
            right: .leaf(view: panes[1].id)
          )))
    } else {
      tree = panes.first.map { SplitTree(view: $0.id) } ?? SplitTree()
    }
    return PaneLayout(tree: tree, panes: identified, focusedPaneID: focusedPaneID)
  }
}
