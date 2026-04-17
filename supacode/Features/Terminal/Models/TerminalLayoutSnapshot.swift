import Foundation
import SupacodeSettingsShared

struct TerminalLayoutSnapshot: Codable, Equatable, Sendable {
  let tabs: [TabSnapshot]
  let selectedTabIndex: Int

  struct TabSnapshot: Codable, Equatable, Sendable {
    let id: UUID?
    let title: String
    let icon: String?
    let tintColor: TerminalTabTintColor?
    let layout: LayoutNode
    let focusedLeafIndex: Int
  }

  indirect enum LayoutNode: Codable, Equatable, Sendable {
    case leaf(SurfaceSnapshot)
    case split(SplitSnapshot)
  }

  struct SplitSnapshot: Codable, Equatable, Sendable {
    let direction: SplitDirection
    let ratio: Double
    let left: LayoutNode
    let right: LayoutNode
  }

  struct SurfaceSnapshot: Codable, Equatable, Sendable {
    let id: UUID?
    let workingDirectory: String?
  }

}

extension TerminalLayoutSnapshot.LayoutNode {
  /// The leftmost leaf in the subtree.
  var firstLeaf: TerminalLayoutSnapshot.SurfaceSnapshot {
    switch self {
    case .leaf(let surface):
      return surface
    case .split(let split):
      return split.left.firstLeaf
    }
  }

  /// The number of leaves in the subtree.
  var leafCount: Int {
    switch self {
    case .leaf:
      return 1
    case .split(let split):
      return split.left.leafCount + split.right.leafCount
    }
  }

  /// Collects all surface IDs in the subtree.
  func collectSurfaceIDs(into ids: inout Set<UUID>) {
    switch self {
    case .leaf(let surface):
      if let id = surface.id { ids.insert(id) }
    case .split(let split):
      split.left.collectSurfaceIDs(into: &ids)
      split.right.collectSurfaceIDs(into: &ids)
    }
  }
}

extension TerminalLayoutSnapshot {
  var allSurfaceIDs: Set<UUID> {
    var ids: Set<UUID> = []
    for tab in tabs {
      tab.layout.collectSurfaceIDs(into: &ids)
    }
    return ids
  }
}
