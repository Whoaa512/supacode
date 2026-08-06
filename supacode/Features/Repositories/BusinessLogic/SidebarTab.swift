import Sharing

/// The top-level sidebar panels. `worktrees` is the repo/worktree tree the app
/// has always shipped; `agents` is the flat cross-repo agent dashboard; `tasks`
/// is the task inbox.
enum SidebarTab: String, CaseIterable, Codable, Sendable {
  case worktrees
  case agents
  case tasks

  /// Safe read of the persisted raw value. A string this build doesn't know
  /// (written by a newer build, or hand-edited defaults) falls back to
  /// `.worktrees` instead of leaving the sidebar blank — every persisted-tab
  /// read goes through here so the fallback lives in one place.
  static func resolved(fromStoredValue rawValue: String) -> Self {
    SidebarTab(rawValue: rawValue) ?? .worktrees
  }

  var title: String {
    switch self {
    case .worktrees: "Worktrees"
    case .agents: "Agents"
    case .tasks: "Tasks"
    }
  }

  var help: String {
    switch self {
    case .worktrees: "Show repositories and worktrees"
    case .agents: "Show every running agent across repositories"
    case .tasks: "Show the task inbox"
    }
  }

  var systemImage: String {
    switch self {
    case .worktrees: "folder"
    case .agents: "sparkles"
    case .tasks: "checklist"
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
