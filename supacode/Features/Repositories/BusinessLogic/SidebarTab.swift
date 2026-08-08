import Sharing

/// The top-level sidebar panels. `worktrees` is the repo/worktree tree the app
/// has always shipped; `agents` is the flat cross-repo agent dashboard; `tasks`
/// is the task inbox.
enum SidebarTab: String, CaseIterable, Codable, Sendable {
  case worktrees
  case agents
  case tasks

  /// Which panels the user has left switched on (A36). Tasks is absent on
  /// purpose: it is the floor, so "at least one tab is reachable" is a property
  /// of the type rather than a check every caller has to repeat.
  nonisolated struct Visibility: Equatable, Sendable {
    var showsWorktrees: Bool
    var showsAgents: Bool

    static let all = Visibility(showsWorktrees: true, showsAgents: true)
  }

  /// Safe read of the persisted raw value. A string this build doesn't know
  /// (written by a newer build, or hand-edited defaults) falls back to
  /// `.worktrees` instead of leaving the sidebar blank — every persisted-tab
  /// read goes through here so the fallback lives in one place.
  static func resolved(fromStoredValue rawValue: String) -> Self {
    SidebarTab(rawValue: rawValue) ?? .worktrees
  }

  /// The same read, plus A36: a tab the user has hidden falls back to the inbox.
  /// Hiding the panel you are standing on is the ordinary way to hide one, so
  /// this has to be a landing rather than an error.
  static func resolved(fromStoredValue rawValue: String, visibility: Visibility) -> Self {
    let tab = resolved(fromStoredValue: rawValue)
    return visibleCases(visibility).contains(tab) ? tab : .tasks
  }

  /// The first choice the user has not put away, or the inbox. Where every
  /// chord that *leaves* a panel lands, so no chord can strand the sidebar on a
  /// hidden tab.
  static func firstVisible(of preferences: [SidebarTab], visibility: Visibility) -> Self {
    let visible = visibleCases(visibility)
    return preferences.first { visible.contains($0) } ?? .tasks
  }

  /// The picker's segments, in `allCases` order so hiding one never reshuffles
  /// the others under the user's muscle memory.
  static func visibleCases(_ visibility: Visibility) -> [SidebarTab] {
    allCases.filter { tab in
      switch tab {
      case .worktrees: visibility.showsWorktrees
      case .agents: visibility.showsAgents
      case .tasks: true
      }
    }
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

  /// What ⌘N means while this panel is on screen. A19: on the inbox it captures
  /// work; everywhere else it still creates a worktree. Exhaustive so a new
  /// panel has to declare which meaning it takes, and so the menu label and the
  /// reducer's routing can never disagree about it.
  var newItemCapturesTask: Bool {
    switch self {
    case .tasks: true
    case .worktrees, .agents: false
    }
  }
}

/// Typed AppStorage handle for the sidebar's tab selection, mirroring the
/// `sidebarGroupPinnedRows` pattern so the key string and default live in one
/// place. Stored as the raw string so it round-trips through `UserDefaults`
/// without a custom coder.
///
/// Tasks is the home panel: a fresh launch lands on the inbox. A previously
/// picked tab still wins — the default only applies before the first explicit
/// switch is persisted.
nonisolated extension SharedReaderKey where Self == AppStorageKey<String>.Default {
  static var sidebarTab: Self {
    Self[.appStorage("sidebarTab"), default: SidebarTab.tasks.rawValue]
  }
}
