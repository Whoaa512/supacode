import Sharing

enum SidebarTab: String, CaseIterable, Codable, Sendable {
  case sessions
  case worktrees
  case agents

  var title: String {
    switch self {
    case .sessions: "Sessions"
    case .worktrees: "Worktrees"
    case .agents: "Agents"
    }
  }

  var help: String {
    switch self {
    case .sessions: "Show agent sessions across directories"
    case .worktrees: "Show repositories and worktrees"
    case .agents: "Show every running agent across repositories"
    }
  }
}

/// Typed AppStorage handle for the sidebar's tab selection, mirroring the
/// `sidebarGroupPinnedRows` pattern so the key string and default live in one
/// place. Stored as the raw string so it round-trips through `UserDefaults`
/// without a custom coder.
nonisolated extension SharedReaderKey where Self == AppStorageKey<String>.Default {
  static var sidebarTab: Self {
    Self[.appStorage("sessionsSidebarTab"), default: SidebarTab.sessions.rawValue]
  }
}
