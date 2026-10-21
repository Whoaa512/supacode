import Sharing

enum SidebarTab: String, CaseIterable, Codable, Sendable {
  case sessions
  case worktrees

  var title: String {
    switch self {
    case .sessions: "Sessions"
    case .worktrees: "Worktrees"
    }
  }

  var help: String {
    switch self {
    case .sessions: "Show agent sessions across directories"
    case .worktrees: "Show repositories and worktrees"
    }
  }

  /// Resolves a persisted raw value. Unknown strings (including the retired
  /// `agents` panel) land on `sessions`, so every reader agrees on one panel.
  static func stored(_ rawValue: String) -> SidebarTab {
    SidebarTab(rawValue: rawValue) ?? .sessions
  }

  var next: SidebarTab {
    let all = Self.allCases
    let index = all.firstIndex(of: self) ?? 0
    return all[(index + 1) % all.count]
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
