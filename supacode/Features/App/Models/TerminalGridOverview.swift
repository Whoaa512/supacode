import Foundation

enum TerminalGridOverview {
  struct Model: Equatable {
    var tiles: [Tile] = []
    var visibleTiles: [Tile] = []
    var counts = Counts()
    var filter: Filter = .all

    init(tiles: [Tile] = [], filter: Filter = .all) {
      let ordered = TerminalGridOverview.clustered(tiles)
      self.tiles = ordered
      self.visibleTiles = TerminalGridOverview.filtered(ordered, by: filter)
      self.counts = TerminalGridOverview.counts(for: ordered)
      self.filter = filter
    }
  }

  struct Tile: Equatable, Identifiable {
    let worktreeID: Worktree.ID
    let worktreeName: String
    let directoryName: String
    let repositoryPath: String
    let tabID: TabID
    let tabTitle: String
    let surfaceID: UUID
    let availability: TerminalSession.Availability
    let isFocused: Bool
    var agents: [AgentPresenceFeature.AgentInstance] = []

    var id: UUID { surfaceID }
    var activity: Activity { Activity.resolve(agents: agents) }
  }

  enum Activity: String, CaseIterable, Equatable, Hashable, Identifiable {
    case busy
    case awaitingInput
    case idle
    case none

    var id: String { rawValue }

    var label: String {
      switch self {
      case .busy: "Busy"
      case .awaitingInput: "Awaiting Input"
      case .idle: "Idle"
      case .none: "None"
      }
    }

    var systemImage: String {
      switch self {
      case .busy: "bolt.fill"
      case .awaitingInput: "exclamationmark.bubble.fill"
      case .idle: "pause.circle"
      case .none: "terminal"
      }
    }

    static func resolve(agents: [AgentPresenceFeature.AgentInstance]) -> Activity {
      if agents.contains(where: { $0.activity.isAttention }) { return .awaitingInput }
      if agents.contains(where: { $0.activity.isWorking }) { return .busy }
      return agents.isEmpty ? .none : .idle
    }
  }

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

  struct Counts: Equatable {
    var total = 0
    var byActivity: [Activity: Int] = [:]

    subscript(activity: Activity) -> Int { byActivity[activity] ?? 0 }

    func count(for filter: Filter) -> Int {
      switch filter {
      case .all: total
      case .activity(let activity): self[activity]
      }
    }
  }

  static func tiles(
    sessions: [TerminalSession],
    worktreeLookup: (Worktree.ID) -> Worktree?,
    agentsForSurface: (UUID) -> [AgentPresenceFeature.AgentInstance]
  ) -> [Tile] {
    sessions.map { session in
      Tile(
        worktreeID: session.worktreeID,
        worktreeName: session.worktreeName,
        directoryName: session.directoryName,
        repositoryPath: worktreeLookup(session.worktreeID)?.repositoryRootURL.path
          ?? session.directoryName,
        tabID: session.tabID,
        tabTitle: session.tabTitle,
        surfaceID: session.surfaceID,
        availability: session.availability,
        isFocused: session.isFocused,
        agents: agentsForSurface(session.surfaceID)
      )
    }
  }

  static func counts(for tiles: [Tile]) -> Counts {
    var result = Counts(total: tiles.count)
    for tile in tiles {
      result.byActivity[tile.activity, default: 0] += 1
    }
    return result
  }

  static func filtered(_ tiles: [Tile], by filter: Filter) -> [Tile] {
    guard filter != .all else { return tiles }
    return tiles.filter(filter.matches)
  }

  static func clustered(_ tiles: [Tile]) -> [Tile] {
    tiles.enumerated()
      .sorted { lhs, rhs in
        let left = sortKey(lhs.element)
        let right = sortKey(rhs.element)
        if left != right { return left < right }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private static func sortKey(_ tile: Tile) -> String {
    [tile.repositoryPath, tile.worktreeName, tile.worktreeID.rawValue]
      .joined(separator: "\u{1f}")
  }
}
