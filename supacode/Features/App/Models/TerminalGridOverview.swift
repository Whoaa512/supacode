import Foundation

/// Pure model for the full-screen terminal grid overview (⌥⌘O): the tile list,
/// the activity bucket each tile falls into, the header rollup counts, and the
/// filter/ordering rules the view renders. Kept out of the view so the grid's
/// behavior is testable without SwiftUI.
enum TerminalGridOverview {
  /// One surface in the grid.
  struct Tile: Identifiable, Equatable {
    enum Kind: Equatable {
      /// Surface has a live view; preview reads the screen each tick.
      case live
      /// Tab is hibernated in a live worktree state; preview reads disk.
      case dormant
      /// Worktree not restored this launch; tile comes from the persisted
      /// layout snapshot and preview reads disk.
      case snoozed
    }

    let worktreeID: Worktree.ID
    let worktreeName: String
    let directoryName: String
    /// Cluster key: repository root path when known, else the directory name.
    /// Tiles sort by this first so sibling worktrees of one repo sit adjacent.
    let repositoryPath: String
    let tabID: TerminalTabID
    let tabTitle: String
    let surfaceID: UUID
    let kind: Kind
    /// Same presence lineup the sidebar rows render, scoped to this surface.
    var agents: [AgentPresenceFeature.AgentInstance] = []

    var id: UUID { surfaceID }

    /// Bucket this tile counts and filters under.
    var activity: Activity { Activity.resolve(kind: kind, agents: agents) }
  }

  /// Coarse per-tile state, rolled up in the header strip and used by the
  /// filter chips. Derived from the sidebar's `AgentPresenceFeature.Activity`
  /// so both surfaces agree on what "busy" means.
  enum Activity: String, CaseIterable, Identifiable, Equatable {
    /// An agent is mid-turn (`busy` or `compacting`).
    case busy
    /// An agent is parked on the user (`awaitingInput` or `error`).
    case blocked
    /// A live or dormant surface with nothing waiting on it.
    case idle
    /// Worktree not restored this launch.
    case snoozed

    var id: String { rawValue }

    var label: String {
      switch self {
      case .busy: "Busy"
      case .blocked: "Blocked"
      case .idle: "Idle"
      case .snoozed: "Snoozed"
      }
    }

    var systemImage: String {
      switch self {
      case .busy: "bolt.fill"
      case .blocked: "exclamationmark.bubble.fill"
      case .idle: "terminal"
      case .snoozed: "moon.zzz.fill"
      }
    }

    /// Attention beats work: a surface with one errored and one busy agent
    /// reads as blocked, because that is the one the user has to answer.
    static func resolve(
      kind: Tile.Kind,
      agents: [AgentPresenceFeature.AgentInstance]
    ) -> Activity {
      if kind == .snoozed { return .snoozed }
      if agents.contains(where: { $0.activity.isAttention }) { return .blocked }
      if agents.contains(where: { $0.activity.isWorking }) { return .busy }
      return .idle
    }
  }

  /// Header chip selection. `all` shows every tile.
  enum Filter: Equatable, Hashable {
    case all
    case activity(Activity)

    static let allCases: [Filter] = [.all] + Activity.allCases.map(Filter.activity)

    var label: String {
      switch self {
      case .all: "All"
      case .activity(let activity): activity.label
      }
    }

    func matches(_ tile: Tile) -> Bool {
      switch self {
      case .all: true
      case .activity(let activity): tile.activity == activity
      }
    }
  }

  /// Header rollup: the total surface count plus one count per activity.
  /// Always computed over the unfiltered tiles so the numbers don't move when
  /// the user picks a chip.
  struct Counts: Equatable {
    var total: Int = 0
    var byActivity: [Activity: Int] = [:]

    subscript(activity: Activity) -> Int { byActivity[activity] ?? 0 }

    func count(for filter: Filter) -> Int {
      switch filter {
      case .all: total
      case .activity(let activity): self[activity]
      }
    }
  }

  static func counts(for tiles: [Tile]) -> Counts {
    var counts = Counts(total: tiles.count)
    for tile in tiles {
      counts.byActivity[tile.activity, default: 0] += 1
    }
    return counts
  }

  static func filtered(_ tiles: [Tile], by filter: Filter) -> [Tile] {
    guard filter != .all else { return tiles }
    return tiles.filter(filter.matches)
  }

  /// Cluster sibling worktrees of the same repository next to each other while
  /// keeping the incoming per-worktree surface order. Flat grid, no section
  /// headers: adjacency is the only grouping signal.
  static func clustered(_ tiles: [Tile]) -> [Tile] {
    tiles
      .enumerated()
      .sorted { lhs, rhs in
        let left = sortKey(lhs.element)
        let right = sortKey(rhs.element)
        if left != right { return left < right }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private static func sortKey(_ tile: Tile) -> String {
    // Unit separator keeps a longer repo path from swallowing the next field.
    [tile.repositoryPath, tile.worktreeName, tile.worktreeID.rawValue].joined(separator: "\u{1f}")
  }

  /// One tile per surface, in the manager's stable worktree/tab order, so
  /// keyboard navigation indices match the rendered grid.
  static func liveTiles(
    _ overviews: [WorktreeTerminalManager.SessionWorktreeOverview],
    worktreeLookup: (Worktree.ID) -> Worktree?,
    agentsForSurface: (UUID) -> [AgentPresenceFeature.AgentInstance] = { _ in [] }
  ) -> [Tile] {
    overviews.flatMap { worktree in
      let repositoryPath =
        worktreeLookup(worktree.id)?.repositoryRootURL.path ?? worktree.directoryName
      return worktree.tabs.flatMap { tab in
        tab.surfaces.map { surface in
          Tile(
            worktreeID: worktree.id,
            worktreeName: worktree.name,
            directoryName: worktree.directoryName,
            repositoryPath: repositoryPath,
            tabID: tab.id,
            tabTitle: tab.title,
            surfaceID: surface.id,
            kind: surface.isDormant ? .dormant : .live,
            agents: agentsForSurface(surface.id)
          )
        }
      }
    }
  }

  /// Tiles for worktrees that persisted a layout but own no surfaces this
  /// launch (not yet visited / restored). Skips worktrees the lookup can't
  /// resolve (archived / deleted) and legacy snapshots without stable IDs.
  /// Sorted by directory name for a stable grid order.
  static func snoozedTiles(
    layouts: [String: TerminalLayoutSnapshot],
    excludingWorktreeIDs: Set<Worktree.ID>,
    worktreeLookup: (Worktree.ID) -> Worktree?
  ) -> [Tile] {
    layouts
      .compactMap { key, snapshot -> [Tile]? in
        let worktreeID = WorktreeID(key)
        guard !excludingWorktreeIDs.contains(worktreeID),
          let worktree = worktreeLookup(worktreeID)
        else { return nil }
        let tiles = snapshot.tabs.flatMap { tab -> [Tile] in
          guard let tabID = tab.id else { return [] }
          return tab.layout.leafSurfaceIDs.map { surfaceID in
            Tile(
              worktreeID: worktreeID,
              worktreeName: worktree.name,
              directoryName: worktree.workingDirectory.lastPathComponent,
              repositoryPath: worktree.repositoryRootURL.path,
              tabID: TerminalTabID(rawValue: tabID),
              tabTitle: tab.customTitle ?? tab.title,
              surfaceID: surfaceID,
              kind: .snoozed
            )
          }
        }
        return tiles.isEmpty ? nil : tiles
      }
      .sorted { lhs, rhs in
        guard let first = lhs.first, let second = rhs.first else { return false }
        return (first.directoryName, first.worktreeID.rawValue)
          < (second.directoryName, second.worktreeID.rawValue)
      }
      .flatMap { $0 }
  }
}
