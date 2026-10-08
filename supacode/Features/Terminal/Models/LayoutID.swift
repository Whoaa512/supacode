/// The key a terminal layout is stored under. Aliases the worktree id until layouts are owned by tasks.
typealias LayoutID = Worktree.ID

extension WorktreeID {
  /// Under the alias this extends `WorktreeID`; F1 moves it onto the `LayoutID` struct.
  /// A layout id read from a persisted layouts blob, whose keys are worktree paths.
  init(legacyWorktreeKey key: String) { self.init(key) }

  /// The key this layout is written under in the persisted layouts blob.
  var persistenceKey: String { rawValue }
}
