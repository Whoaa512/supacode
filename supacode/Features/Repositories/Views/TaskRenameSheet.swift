import ComposableArchitecture
import SwiftUI

extension View {
  /// Presents the rename question over the app.
  ///
  /// Plain state rather than a scoped child store, exactly like
  /// `taskDirectoryConflictSheet`: the question has no child reducer, so a
  /// dismissal *is* the cancel action. Wrapped in a modifier because
  /// `ContentView`'s sheet stack is already at the type-checker's limit.
  func taskRenameSheet(store: StoreOf<RepositoriesFeature>) -> some View {
    let prompt = Binding<TaskRenamePrompt?>(
      get: { store.taskRenamePrompt },
      set: { if $0 == nil { store.send(.tasks(.cancelRenamePrompt)) } }
    )
    return sheet(item: prompt) { TaskRenameSheet(prompt: $0, store: store) }
  }
}

/// Retitle one task. The title is the only handle the panel gives a row — it is
/// what the list shows, what the filter matches and what the seeder guessed — so
/// being able to fix a bad guess is what makes a seeded inbox somebody's own.
struct TaskRenameSheet: View {
  let prompt: TaskRenamePrompt
  let store: StoreOf<RepositoriesFeature>
  /// The draft lives here, not in the store: a per-keystroke action would run
  /// the whole reducer (and its post-reduce recomputes) on every character for a
  /// value only the Save button ever reads.
  @State private var title: String
  @FocusState private var isTitleFocused: Bool

  init(prompt: TaskRenamePrompt, store: StoreOf<RepositoriesFeature>) {
    self.prompt = prompt
    self.store = store
    _title = State(initialValue: prompt.startingTitle)
  }

  var body: some View {
    Form {
      Section {
        TextField("Title", text: $title, prompt: Text(prompt.startingTitle))
          .focused($isTitleFocused)
          .onSubmit { save() }
      } header: {
        Text("Rename Task")
        Text("What this task is called in the sidebar and in the title filter.")
      }
      .headerProminence(.increased)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Spacer()
        Button("Cancel") { store.send(.tasks(.cancelRenamePrompt)) }
          .keyboardShortcut(.cancelAction)
          .help("Keep the current title (Esc)")
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
          .help(
            canSave
              ? "Rename this task (↩)"
              : "A task needs a title — it is what the sidebar and the filter show."
          )
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { isTitleFocused = true }
  }

  /// An all-whitespace title is refused rather than cleared, which the reducer
  /// enforces too — this half is what makes the refusal visible instead of a
  /// button that does nothing.
  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func save() {
    guard canSave else { return }
    store.send(.tasks(.renameTask(prompt.taskID, title: title)))
  }
}
