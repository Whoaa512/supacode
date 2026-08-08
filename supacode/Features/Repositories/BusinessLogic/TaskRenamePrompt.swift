import Foundation

/// The open "Rename Task…" question: which task, and the title it started with.
///
/// Plain state rather than a child reducer (the `TaskDirectoryConflictPrompt`
/// precedent): the sheet has one text field and two answers, so a per-keystroke
/// binding action through the store would buy nothing but a reducer arm that
/// runs on every character. The draft title lives in the sheet's own `@State`
/// and only the committed value reaches the store.
///
/// `startingTitle` is carried so the sheet opens on the title the row shows
/// without reading `taskRecords[id:]` from a view body, which the sidebar
/// doctrine forbids.
nonisolated struct TaskRenamePrompt: Equatable, Sendable, Identifiable {
  var taskID: TaskID
  var startingTitle: String

  var id: TaskID { taskID }
}
