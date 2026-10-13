import ArgumentParser

/// Shared `--task` flag for the commands that act inside a worktree's terminal
/// layout. A worktree can hold several tasks; this picks one.
struct TaskOption: ParsableArguments {
  @Option(
    name: [.long],
    help: """
      Task ID. Defaults to $SUPACODE_TASK_ID when the worktree is this terminal's own, \
      otherwise to the task the worktree shows. A tab, pane, or surface ID always finds its own task.
      """
  )
  var task: String?

  func target(worktreeID: String) -> WorktreeTarget {
    Self.target(worktreeID: worktreeID, task: task)
  }

  /// The same rule without the parsed option, for a command that reads its
  /// task from elsewhere.
  static func target(worktreeID: String, task: String?) -> WorktreeTarget {
    WorktreeTarget(
      worktreeID: worktreeID,
      taskID: IDResolvers.resolveTaskID(
        task, worktreeID: worktreeID,
        environmentWorktreeID: EnvironmentDefaults.worktreeID, environmentTaskID: EnvironmentDefaults.taskID))
  }
}

/// A worktree, optionally one of its tasks, and optionally one surface in it,
/// as a command addresses it. The surface is the identity of a resolved agent
/// row: with it, the app reaches that agent or nothing, never a same-kind
/// sibling in the same task.
nonisolated struct WorktreeTarget: Equatable {
  let worktreeID: String
  let taskID: String?
  var surfaceID: String?

  /// What goes where a deeplink expects the worktree id: the id alone, or
  /// followed by the task segment.
  var urlSegment: String {
    guard let taskID else { return worktreeID }
    return "\(worktreeID)/task/\(taskID)"
  }

  /// The `surface=<id>` query item a resolved agent row adds to its URL, with
  /// the separator the URL needs next; empty without a surface.
  func surfaceQuery(first: Bool) -> String {
    guard let surfaceID else { return "" }
    return "\(first ? "?" : "&")surface=\(surfaceID)"
  }

  var queryParams: [String: String] {
    var params = ["worktreeID": worktreeID]
    if let taskID { params["taskID"] = taskID }
    if let surfaceID { params["surfaceID"] = surfaceID }
    return params
  }
}
