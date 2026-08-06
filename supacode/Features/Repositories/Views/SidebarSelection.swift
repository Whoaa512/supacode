enum SidebarSelection: Hashable {
  case worktree(Worktree.ID)
  case archivedWorktrees
  case failedRepository(Repository.ID)
  /// A task-inbox row. Deliberately carries no worktree: `worktreeID` returns
  /// nil, which makes every worktree-only flow (archive, bulk ops, detail pane,
  /// arrow nav) inert by construction rather than by audit — the
  /// `.archivedWorktrees` precedent.
  case task(TaskID)

  var worktreeID: Worktree.ID? {
    switch self {
    case .worktree(let id):
      return id
    case .archivedWorktrees, .failedRepository, .task:
      return nil
    }
  }

  var failedRepositoryID: Repository.ID? {
    switch self {
    case .failedRepository(let id):
      return id
    case .worktree, .archivedWorktrees, .task:
      return nil
    }
  }

  var taskID: TaskID? {
    switch self {
    case .task(let id):
      return id
    case .worktree, .archivedWorktrees, .failedRepository:
      return nil
    }
  }

  /// Whether the reload-time sweep that clears a selection pointing at a
  /// vanished worktree applies to this case. `.archivedWorktrees` has always
  /// been exempt; `.task` joins it because a task outlives the worktree it
  /// started in. `.failedRepository` stays subject to the sweep so existing
  /// behaviour is unchanged.
  var isClearedByWorktreeValidation: Bool {
    switch self {
    case .worktree, .failedRepository:
      return true
    case .archivedWorktrees, .task:
      return false
    }
  }

  /// Whether selecting this row must leave the persisted
  /// `sidebar.focusedWorktreeID` alone. Both worktree-less browsing cases
  /// qualify: the archived list and a task row are detours, and clobbering the
  /// last focused live worktree would lose the row to return to — and for
  /// `.task` it would also write `sidebar.json` from a task operation, which
  /// assertion A11 forbids.
  var preservesFocusedWorktree: Bool {
    switch self {
    case .worktree, .failedRepository:
      return false
    case .archivedWorktrees, .task:
      return true
    }
  }
}
