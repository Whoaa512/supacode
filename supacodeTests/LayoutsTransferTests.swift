import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

struct LayoutsTransferTests {
  private typealias AgentRecord = TerminalLayoutSnapshot.SurfaceAgentRecord

  private static func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
  }

  private static func tabID(_ number: Int) -> TabID { TabID(rawValue: uuid(number)) }
  private static func paneID(_ number: Int) -> PaneID { PaneID(rawValue: uuid(number)) }

  /// Tab `n` has tab id `n` and content id `1000 + n` unless `content` says otherwise.
  private static func tab(_ number: Int, content: Int? = nil, agents: [AgentRecord]? = nil) -> TabItem {
    TabItem(
      id: tabID(number),
      title: "Tab \(number)",
      content: ContentSnapshot(
        id: ContentID(rawValue: uuid(content ?? 1000 + number)),
        state: .terminal(TerminalContentState(workingDirectory: "/tmp/cwd-\(number)", agents: agents))
      )
    )
  }

  private static func pane(_ number: Int, _ tabs: [Int], selected: Int? = nil) -> Pane {
    Pane(
      id: paneID(number),
      tabs: IdentifiedArray(uniqueElements: tabs.map { tab($0) }),
      selectedTabID: selected.map { tabID($0) }
    )
  }

  /// Panes left to right, each inserted to the right of the previous one.
  private static func layout(_ panes: [Pane], focused: Int? = nil) throws -> PaneLayout {
    var tree = SplitTree<PaneID>()
    for (index, pane) in panes.enumerated() {
      tree =
        index == 0
        ? SplitTree(view: pane.id)
        : try tree.inserting(view: pane.id, at: panes[index - 1].id, direction: .right)
    }
    return PaneLayout(
      tree: tree,
      panes: IdentifiedArray(uniqueElements: panes),
      focusedPaneID: focused.map { paneID($0) }
    )
  }

  /// Every (tab id, content id) pair, in pane then strip order.
  private static func ids(_ layout: PaneLayout) -> [String] {
    layout.panes.flatMap { pane in
      pane.tabs.map { "\($0.id.rawValue)/\($0.content.id.rawValue)" }
    }
  }

  private static func tabIDs(_ pane: Pane?) -> [TabID] {
    pane.map { Array($0.tabs.ids) } ?? []
  }

  /// Fresh pane ids start at 9001 so they never collide with fixture ids.
  private final class PaneIDSource {
    var calls = 0
    func next() -> PaneID {
      calls += 1
      return LayoutsTransferTests.paneID(9000 + calls)
    }
  }

  private static func destinationB() throws -> PaneLayout {
    try layout([pane(101, [101, 102]), pane(102, [103])], focused: 102)
  }

  // MARK: - flatten

  @Test func flattenAppendsToFocusedPaneAfterExistingTabs() throws {
    let source = try Self.layout([Self.pane(1, [1, 2])])
    let destination = try Self.destinationB()
    let fresh = PaneIDSource()

    let result = try LayoutTransfer.flatten(source, into: destination, makePaneID: fresh.next)

    #expect(Self.tabIDs(result.layout.panes[id: Self.paneID(102)]) == [103, 1, 2].map(Self.tabID))
    #expect(result.layout.panes[id: Self.paneID(101)] == destination.panes[id: Self.paneID(101)])
    #expect(result.targetPaneID == Self.paneID(102))
    #expect(result.movedTabIDs == [1, 2].map(Self.tabID))
    #expect(!result.createdPane)
    #expect(fresh.calls == 0)
    #expect(result.layout.isConsistent)
  }

  @Test func flattenKeepsEveryTabValueIntact() throws {
    let rich = TabItem(
      id: Self.tabID(1),
      title: "Runner",
      customTitle: "Mine",
      icon: "hammer",
      tintColor: .red,
      content: ContentSnapshot(
        id: ContentID(rawValue: Self.uuid(1001)),
        state: .terminal(
          TerminalContentState(
            workingDirectory: "/tmp/elsewhere",
            agents: [
              AgentRecord(
                agent: "pi", pids: [42], activity: "idle", doneUnseen: nil,
                sessionRef: "ref-1", resumeCandidate: nil)
            ],
            launch: LaunchOverride(command: "x", bypassZmx: true)
          ))
      ),
      isLocked: true
    )
    let source = try Self.layout([Pane(id: Self.paneID(1), tabs: [rich])])

    let appended = try LayoutTransfer.flatten(source, into: try Self.destinationB())
    #expect(appended.layout.panes[id: Self.paneID(102)]?.tabs[id: rich.id] == rich)

    let created = try LayoutTransfer.flatten(source, into: PaneLayout())
    #expect(created.layout.panes.first?.tabs[id: rich.id] == rich)
  }

  @Test func flattenUsesVisualPaneOrderNotCreationOrder() throws {
    let first = Self.pane(1, [1])
    let second = Self.pane(2, [2])
    let tree = try SplitTree(view: first.id).inserting(view: second.id, at: first.id, direction: .left)
    let source = PaneLayout(tree: tree, panes: [first, second], focusedPaneID: first.id)
    #expect(Array(source.panes.ids) == [first.id, second.id])
    #expect(source.tree.leaves() == [second.id, first.id])

    let result = try LayoutTransfer.flatten(source, into: try Self.destinationB())

    #expect(result.movedTabIDs == [2, 1].map(Self.tabID))
    #expect(Self.tabIDs(result.layout.panes[id: Self.paneID(102)]) == [103, 2, 1].map(Self.tabID))
  }

  @Test func flattenSourceWithSplitsLandsInOnePane() throws {
    let panes = [Self.pane(1, [1, 2]), Self.pane(2, [3]), Self.pane(3, [4])]
    let tree = try SplitTree(view: panes[0].id)
      .inserting(view: panes[1].id, at: panes[0].id, direction: .right)
      .inserting(view: panes[2].id, at: panes[0].id, direction: .down)
    let source = PaneLayout(tree: tree, panes: IdentifiedArray(uniqueElements: panes), focusedPaneID: panes[1].id)
    #expect(source.isConsistent)
    let destination = try Self.destinationB()

    let result = try LayoutTransfer.flatten(source, into: destination)

    #expect(result.layout.panes.count == destination.panes.count)
    #expect(result.layout.tree == destination.tree)
    #expect(Self.ids(result.layout).sorted() == (Self.ids(destination) + Self.ids(source)).sorted())
    #expect(result.movedTabIDs.count == 4)
    #expect(result.layout.isConsistent)
  }

  @Test func flattenKeepsDestinationSelectionFocusAndZoom() throws {
    var destination = try Self.layout(
      [Self.pane(101, [101, 102], selected: 102), Self.pane(102, [103])], focused: 101)
    destination.tree = destination.tree.settingZoomed(destination.tree.find(id: Self.uuid(101)))
    #expect(destination.tree.zoomed != nil)
    let source = try Self.layout([Self.pane(1, [1]), Self.pane(2, [2, 3], selected: 3)], focused: 2)

    let result = try LayoutTransfer.flatten(source, into: destination)

    #expect(result.layout.panes[id: Self.paneID(101)]?.selectedTabID == Self.tabID(102))
    #expect(result.layout.focusedPaneID == Self.paneID(101))
    #expect(result.layout.tree == destination.tree)
    #expect(result.sourceActiveTabID == Self.tabID(3))
    #expect(result.targetPaneID == Self.paneID(101))
  }

  @Test func flattenEmptySourceIsNoOp() throws {
    let destination = try Self.destinationB()

    let result = try LayoutTransfer.flatten(PaneLayout(), into: destination)

    #expect(result.layout == destination)
    #expect(result.movedTabIDs.isEmpty)
    #expect(result.sourceActiveTabID == nil)
  }

  @Test func flattenIntoEmptyDestinationMakesOnePane() throws {
    let source = try Self.layout([Self.pane(1, [1, 2]), Self.pane(2, [3, 4], selected: 3)], focused: 2)
    let fresh = PaneIDSource()

    let result = try LayoutTransfer.flatten(source, into: PaneLayout(), makePaneID: fresh.next)

    let created = Self.paneID(9001)
    #expect(Array(result.layout.panes.ids) == [created])
    #expect(result.layout.tree.leaves() == [created])
    #expect(Self.tabIDs(result.layout.panes[id: created]) == [1, 2, 3, 4].map(Self.tabID))
    #expect(result.layout.panes[id: created]?.selectedTabID == Self.tabID(3))
    #expect(result.layout.focusedPaneID == created)
    #expect(result.targetPaneID == created)
    #expect(result.createdPane)
    #expect(fresh.calls == 1)
    #expect(result.layout.isConsistent)
  }

  @Test func flattenBothEmpty() throws {
    let fresh = PaneIDSource()

    let result = try LayoutTransfer.flatten(PaneLayout(), into: PaneLayout(), makePaneID: fresh.next)

    #expect(result.layout == PaneLayout())
    #expect(result.targetPaneID == nil)
    #expect(!result.createdPane)
    #expect(fresh.calls == 0)
  }

  @Test func flattenRefusesSharedTabID() throws {
    let source = try Self.layout([Pane(id: Self.paneID(1), tabs: [Self.tab(1, content: 2001)])])
    let destination = try Self.layout([Pane(id: Self.paneID(101), tabs: [Self.tab(1, content: 2002)])])

    #expect(throws: LayoutTransfer.Failure.duplicateIdentity) {
      try LayoutTransfer.flatten(source, into: destination)
    }
  }

  @Test func flattenRefusesSharedContentID() throws {
    let source = try Self.layout([Pane(id: Self.paneID(1), tabs: [Self.tab(1, content: 2001)])])
    let destination = try Self.layout([Pane(id: Self.paneID(101), tabs: [Self.tab(101, content: 2001)])])

    #expect(throws: LayoutTransfer.Failure.duplicateIdentity) {
      try LayoutTransfer.flatten(source, into: destination)
    }
    #expect(throws: LayoutTransfer.Failure.duplicateIdentity) {
      try LayoutTransfer.flatten(source, into: source)
    }
  }

  @Test func flattenRefusesInconsistentInput() throws {
    let stray = Self.pane(2, [2])
    let broken = PaneLayout(
      tree: SplitTree(view: Self.paneID(1)), panes: [Self.pane(1, [1]), stray], focusedPaneID: Self.paneID(1))
    #expect(!broken.isConsistent)
    let destination = try Self.destinationB()

    #expect(throws: LayoutTransfer.Failure.inconsistentSource) {
      try LayoutTransfer.flatten(broken, into: destination)
    }
    #expect(throws: LayoutTransfer.Failure.inconsistentDestination) {
      try LayoutTransfer.flatten(destination, into: broken)
    }
  }

  @Test func flattenOrderSurvivesCodableRoundTrip() throws {
    let source = try Self.layout([Self.pane(1, [1, 2])])
    let result = try LayoutTransfer.flatten(source, into: try Self.destinationB())

    let data = try JSONEncoder().encode(result.layout)
    let decoded = try JSONDecoder().decode(PaneLayout.self, from: data)

    #expect(decoded.panes.map { Self.tabIDs($0) } == result.layout.panes.map { Self.tabIDs($0) })
    #expect(Self.tabIDs(decoded.panes[id: Self.paneID(102)]) == [103, 1, 2].map(Self.tabID))
  }

  @Test func flattenIsFlatAfterRepeatedMerge() throws {
    let sourceA = try Self.layout([Self.pane(1, [1, 2])])
    let middleB = try Self.layout([Self.pane(101, [101]), Self.pane(102, [102])], focused: 102)
    let lastC = try Self.layout([Self.pane(201, [201]), Self.pane(202, [202])], focused: 201)

    let merged = try LayoutTransfer.flatten(sourceA, into: middleB)
    let result = try LayoutTransfer.flatten(merged.layout, into: lastC)

    #expect(result.layout.tree == lastC.tree)
    #expect(result.layout.panes.count == 2)
    #expect(Self.tabIDs(result.layout.panes[id: Self.paneID(201)]) == [201, 101, 102, 1, 2].map(Self.tabID))
    #expect(result.layout.panes[id: Self.paneID(202)] == lastC.panes[id: Self.paneID(202)])
    #expect(result.layout.isConsistent)
  }

  // MARK: - extract

  @Test func extractReturnsSinglePaneLayoutWithSameTab() throws {
    let source = try Self.destinationB()
    let original = try #require(source.panes[id: Self.paneID(101)]?.tabs[id: Self.tabID(102)])
    let fresh = PaneIDSource()

    let result = try LayoutTransfer.extract(Self.tabID(102), from: source, makePaneID: fresh.next)

    let created = Self.paneID(9001)
    #expect(Array(result.extracted.panes.ids) == [created])
    #expect(result.extracted.tree.leaves() == [created])
    #expect(result.extracted.panes[id: created]?.tabs.elements == [original])
    #expect(result.extracted.panes[id: created]?.selectedTabID == original.id)
    #expect(result.extracted.focusedPaneID == created)
    #expect(result.extracted.isConsistent)
    #expect(fresh.calls == 1)
  }

  @Test func extractSelectedTabRetargetsToPrevious() throws {
    let middle = try Self.layout([Self.pane(1, [1, 2, 3], selected: 2)])
    let afterMiddle = try LayoutTransfer.extract(Self.tabID(2), from: middle)
    #expect(afterMiddle.remainder.panes[id: Self.paneID(1)]?.selectedTabID == Self.tabID(1))
    #expect(afterMiddle.remainder.focusedPaneID == Self.paneID(1))
    #expect(afterMiddle.collapsedPaneID == nil)

    let first = try Self.layout([Self.pane(1, [1, 2, 3], selected: 1)])
    let afterFirst = try LayoutTransfer.extract(Self.tabID(1), from: first)
    #expect(afterFirst.remainder.panes[id: Self.paneID(1)]?.selectedTabID == Self.tabID(2))
    #expect(afterFirst.remainder.isConsistent)
  }

  @Test func extractUnselectedTabKeepsSelection() throws {
    let source = try Self.layout([Self.pane(1, [1, 2, 3], selected: 3)])

    let result = try LayoutTransfer.extract(Self.tabID(1), from: source)

    #expect(result.remainder.panes[id: Self.paneID(1)]?.selectedTabID == Self.tabID(3))
    #expect(Self.tabIDs(result.remainder.panes[id: Self.paneID(1)]) == [2, 3].map(Self.tabID))
    #expect(result.collapsedPaneID == nil)
  }

  @Test func extractOnlyTabOfPaneCollapsesIt() throws {
    let source = try Self.layout([Self.pane(1, [1]), Self.pane(2, [2])], focused: 1)

    let result = try LayoutTransfer.extract(Self.tabID(2), from: source)

    #expect(Array(result.remainder.panes.ids) == [Self.paneID(1)])
    #expect(result.remainder.tree == SplitTree(view: Self.paneID(1)))
    #expect(result.remainder.focusedPaneID == Self.paneID(1))
    #expect(result.collapsedPaneID == Self.paneID(2))
    #expect(result.remainder.isConsistent)
  }

  @Test func extractOnlyTabOfFocusedPaneMovesFocusToNeighbour() throws {
    let panes = [Self.pane(1, [1]), Self.pane(2, [2]), Self.pane(3, [3])]

    let middle = try LayoutTransfer.extract(Self.tabID(2), from: try Self.layout(panes, focused: 2))
    #expect(middle.remainder.focusedPaneID == Self.paneID(1))
    #expect(middle.remainder.isConsistent)

    let leftmost = try LayoutTransfer.extract(Self.tabID(1), from: try Self.layout(panes, focused: 1))
    #expect(leftmost.remainder.focusedPaneID == Self.paneID(2))
    #expect(leftmost.remainder.isConsistent)
  }

  @Test func extractFromZoomedPaneClearsZoom() throws {
    var source = try Self.layout([Self.pane(1, [1]), Self.pane(2, [2])], focused: 2)
    source.tree = source.tree.settingZoomed(source.tree.find(id: Self.uuid(2)))
    #expect(source.tree.zoomed != nil)

    let result = try LayoutTransfer.extract(Self.tabID(2), from: source)

    #expect(result.remainder.tree.zoomed == nil)
    #expect(result.remainder.isConsistent)
  }

  @Test func extractLastTabLeavesEmptyLayout() throws {
    let source = try Self.layout([Self.pane(1, [1])])

    let result = try LayoutTransfer.extract(Self.tabID(1), from: source)

    #expect(result.remainder == PaneLayout())
    #expect(result.collapsedPaneID == Self.paneID(1))
    #expect(Self.ids(result.extracted) == Self.ids(source))
  }

  @Test func extractUnknownTabThrows() throws {
    let source = try Self.destinationB()
    #expect(throws: LayoutTransfer.Failure.tabNotFound) {
      try LayoutTransfer.extract(Self.tabID(999), from: source)
    }

    let broken = PaneLayout(
      tree: SplitTree(view: Self.paneID(1)),
      panes: [Self.pane(1, [1]), Self.pane(2, [2])],
      focusedPaneID: Self.paneID(1))
    #expect(throws: LayoutTransfer.Failure.inconsistentSource) {
      try LayoutTransfer.extract(Self.tabID(1), from: broken)
    }
  }

  @Test func extractLosesNothing() throws {
    let source = try Self.layout(
      [Self.pane(1, [1, 2]), Self.pane(2, [3]), Self.pane(3, [4, 5], selected: 5)], focused: 2)

    for number in 1...5 {
      let result = try LayoutTransfer.extract(Self.tabID(number), from: source)
      #expect(
        (Self.ids(result.extracted) + Self.ids(result.remainder)).sorted() == Self.ids(source).sorted())
      #expect(result.extracted.isConsistent)
      #expect(result.remainder.isConsistent)
    }
  }

  @Test func extractThenFlattenRoundTrips() throws {
    let source = try Self.layout(
      [Self.pane(1, [1, 2]), Self.pane(2, [3]), Self.pane(3, [4, 5], selected: 5)], focused: 2)

    for number in 1...5 {
      let split = try LayoutTransfer.extract(Self.tabID(number), from: source)
      let rejoined = try LayoutTransfer.flatten(split.extracted, into: split.remainder)
      #expect(rejoined.layout.isConsistent)
      #expect(Self.ids(rejoined.layout).sorted() == Self.ids(source).sorted())
    }
  }
}
