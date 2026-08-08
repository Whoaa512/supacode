import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

extension View {
  /// Presents the conflict question over the app.
  ///
  /// Plain state rather than a scoped child store: the question has no child
  /// reducer, so a dismissal *is* the cancel action. Wrapped in a modifier
  /// rather than chained inline because `ContentView`'s sheet stack is already
  /// at the type-checker's limit.
  func taskDirectoryConflictSheet(store: StoreOf<RepositoriesFeature>) -> some View {
    let prompt = Binding<TaskDirectoryConflictPrompt?>(
      get: { store.taskDirectoryConflict },
      set: { if $0 == nil { store.send(.tasks(.cancelDirectoryConflict)) } }
    )
    return sheet(item: prompt) { TaskDirectoryConflictSheet(prompt: $0, store: store) }
  }
}

/// The one interaction Resolved #11 spends: another task is already working in
/// this directory, so does the new one join it or get a worktree of its own.
///
/// Asked once per repository — the remember toggle is what keeps A19's
/// two-interaction capture budget intact past the first conflict.
///
/// Deliberately plain, like the rest of the Tasks surface: what ships here is
/// the decision, not a design.
struct TaskDirectoryConflictSheet: View {
  let prompt: TaskDirectoryConflictPrompt
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Directory In Use")
          .font(.headline)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Text(prompt.directoryPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.head)

      ForEach(TaskDirectoryIsolation.allCases) { isolation in
        Button {
          store.send(.tasks(.resolveDirectoryConflict(isolation)))
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(isolation.title)
            Text(isolation.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(isolation.detail)
        .keyboardShortcut(isolation == .default ? .defaultAction : nil)
      }

      Toggle(
        "Remember this choice for this repository",
        isOn: Binding(
          get: { prompt.shouldRemember },
          set: { store.send(.tasks(.setConflictRemember($0))) }
        )
      )
      .help("Answer once. Later captures in this repository skip this question.")

      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.tasks(.cancelDirectoryConflict))
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel without creating a task (Esc)")
      }
    }
    .padding(20)
    .frame(minWidth: 420)
  }

  private var subtitle: String {
    guard let incumbentTitle = prompt.incumbentTitle else {
      return "Another task is already working here."
    }
    return "“\(incumbentTitle)” is already working here."
  }
}
