import Sharing

/// The two top-level sidebar panels. `worktrees` is the repo/worktree tree the
/// app has always shipped; `agents` is the flat cross-repo agent dashboard.
enum SidebarTab: String, CaseIterable, Codable, Sendable {
  case worktrees
  case agents

  var title: String {
    switch self {
    case .worktrees: "Worktrees"
    case .agents: "Agents"
    }
  }

  var help: String {
    switch self {
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
    Self[.appStorage("sidebarTab"), default: SidebarTab.worktrees.rawValue]
  }
}
