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
    WorktreeTarget(
      worktreeID: worktreeID,
      taskID: IDResolvers.resolveTaskID(
        task, worktreeID: worktreeID,
        environmentWorktreeID: EnvironmentDefaults.worktreeID, environmentTaskID: EnvironmentDefaults.taskID))
  }
}

/// A worktree, and optionally one of its tasks, as a command addresses it.
nonisolated struct WorktreeTarget: Equatable {
  let worktreeID: String
  let taskID: String?

  /// What goes where a deeplink expects the worktree id: the id alone, or
  /// followed by the task segment.
  var urlSegment: String {
    guard let taskID else { return worktreeID }
    return "\(worktreeID)/task/\(taskID)"
  }

  var queryParams: [String: String] {
    guard let taskID else { return ["worktreeID": worktreeID] }
    return ["worktreeID": worktreeID, "taskID": taskID]
  }
}
