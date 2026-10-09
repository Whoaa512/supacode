import Foundation
import IdentifiedCollections

/// Moves tabs between task layouts. Pure: never drops or re-identifies a tab
/// or its content, and refuses (throws, no partial result) rather than repair.
///
/// Callers must read both layouts and apply the result in one reducer turn,
/// and leave both tasks untouched on a throw. Left to the caller:
/// - `LayoutFeature.State` bookkeeping for panes that go away (pane windows,
///   alerts, tab rename in progress, equalize).
/// - Showing a moved tab: the destination's selection is kept.
/// - Sessions riding with a tab, primary refusal on detach, record deletion.
/// - Refusing while a tab is a locked blocking-script runner: such a tab moves
///   unchanged like any other.
nonisolated enum LayoutTransfer {
  enum Failure: Error, Equatable {
    case inconsistentSource
    case inconsistentDestination
    /// A tab id or content id appears on both sides.
    case duplicateIdentity
    case tabNotFound
  }

  struct Flattened: Equatable {
    /// The destination after the move.
    var layout: PaneLayout
    /// The pane the tabs landed in; nil only when both layouts are empty.
    var targetPaneID: PaneID?
    /// True when the destination was empty and `targetPaneID` is new.
    var createdPane: Bool
    /// Moved tabs in landing order.
    var movedTabIDs: [TabID]
    /// The tab the source was showing (its focused pane's selection).
    var sourceActiveTabID: TabID?
  }

  struct Extraction: Equatable {
    /// One new pane holding only the tab.
    var extracted: PaneLayout
    /// The source without the tab; empty when it was the last one.
    var remainder: PaneLayout
    /// The source pane the move emptied and removed, if any.
    var collapsedPaneID: PaneID?
  }

  /// Appends every tab of `source` to `destination`'s focused pane, after the
  /// tabs already there, in visual pane order (tree leaves) then strip order.
  /// The source's splits and zoom are discarded; the destination's tree,
  /// selection, focus and zoom are unchanged. An empty destination gets one
  /// new pane showing the source's active tab.
  static func flatten(
    _ source: PaneLayout,
    into destination: PaneLayout,
    makePaneID: () -> PaneID = { PaneID() }
  ) throws -> Flattened {
    guard source.isConsistent else { throw Failure.inconsistentSource }
    guard destination.isConsistent else { throw Failure.inconsistentDestination }

    // Leaf order is what the user sees; `panes` is creation history.
    let ordered = source.tree.leaves()
      .compactMap { source.panes[id: $0] }
      .flatMap { Array($0.tabs) }

    // `IdentifiedArray.append` silently skips a duplicate id, which here would
    // orphan a tab's session.
    let destinationTabIDs = Set(destination.panes.flatMap { $0.tabs.ids })
    let destinationContentIDs = Set(destination.allContentIDs)
    let collides = ordered.contains {
      destinationTabIDs.contains($0.id) || destinationContentIDs.contains($0.content.id)
    }
    guard !collides else { throw Failure.duplicateIdentity }

    let active = source.focusedPaneID.flatMap { source.panes[id: $0]?.selectedTabID }
    let moved = ordered.map(\.id)

    if let focused = destination.focusedPaneID, var pane = destination.panes[id: focused] {
      for tab in ordered {
        pane.tabs.append(tab)
      }
      var result = destination
      result.panes[id: focused] = pane
      assert(result.isConsistent)
      return Flattened(
        layout: result, targetPaneID: focused, createdPane: false,
        movedTabIDs: moved, sourceActiveTabID: active)
    }

    guard !ordered.isEmpty else {
      return Flattened(
        layout: destination, targetPaneID: nil, createdPane: false,
        movedTabIDs: [], sourceActiveTabID: nil)
    }

    let paneID = makePaneID()
    let result = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: ordered), selectedTabID: active)],
      focusedPaneID: paneID
    )
    assert(result.isConsistent)
    return Flattened(
      layout: result, targetPaneID: paneID, createdPane: true,
      movedTabIDs: moved, sourceActiveTabID: active)
  }

  /// Lifts one tab out into a single-pane layout under a fresh pane id (two
  /// layouts never share a pane id). The remainder follows the close-tab
  /// rules: selection retargets to the previous tab, else the first; a pane
  /// the move empties is removed and focus moves to its neighbour. Extracting
  /// the last tab leaves an empty remainder; whether that is allowed is the
  /// caller's policy.
  static func extract(
    _ tabID: TabID,
    from source: PaneLayout,
    makePaneID: () -> PaneID = { PaneID() }
  ) throws -> Extraction {
    guard source.isConsistent else { throw Failure.inconsistentSource }
    guard var pane = source.pane(containingTab: tabID), let index = pane.tabs.index(id: tabID) else {
      throw Failure.tabNotFound
    }
    let tab = pane.tabs[index]

    let newPaneID = makePaneID()
    let extracted = PaneLayout(
      tree: SplitTree(view: newPaneID),
      panes: [Pane(id: newPaneID, tabs: [tab], selectedTabID: tab.id)],
      focusedPaneID: newPaneID
    )
    assert(extracted.isConsistent)

    var remainder = source
    pane.tabs.remove(at: index)
    guard pane.tabs.isEmpty else {
      if pane.selectedTabID == tabID {
        pane.selectedTabID = index > 0 ? pane.tabs[index - 1].id : pane.tabs.first?.id
      }
      remainder.panes[id: pane.id] = pane
      assert(remainder.isConsistent)
      return Extraction(extracted: extracted, remainder: remainder, collapsedPaneID: nil)
    }

    let node = remainder.tree.find(id: pane.id.rawValue)
    // Resolved before the leaf goes, while its neighbours are still known.
    let focusTarget = node.flatMap { remainder.tree.focusTargetAfterClosing($0) }
    if let node {
      remainder.tree = remainder.tree.removing(node)
    }
    remainder.panes.remove(id: pane.id)
    if remainder.focusedPaneID == pane.id {
      remainder.focusedPaneID =
        focusTarget.flatMap { remainder.panes[id: $0] != nil ? $0 : nil } ?? remainder.panes.first?.id
    }
    assert(remainder.isConsistent)
    return Extraction(extracted: extracted, remainder: remainder, collapsedPaneID: pane.id)
  }
}
