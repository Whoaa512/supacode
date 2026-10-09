import Foundation

/// Reducer-safe projection of one known terminal surface.
struct TerminalSession: Equatable, Identifiable, Sendable {
  enum Availability: Equatable, Sendable {
    case live
    case dormant
    case snapshot
  }

  let layoutID: LayoutID
  /// Nil when the layout's directory is not in the roster (hydrated, repository not loaded).
  let worktreeID: Worktree.ID?
  let worktreeName: String
  let directoryName: String
  let tabID: TabID
  let tabTitle: String
  let surfaceID: UUID
  let availability: Availability
  let isFocused: Bool

  var id: UUID { surfaceID }
}
