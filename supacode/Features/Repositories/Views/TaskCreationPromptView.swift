import ComposableArchitecture
import SwiftUI

/// The ⌘N capture sheet. A19 budgets two interactions — type, Enter — so the
/// title field takes focus on open, ↑/↓ walk the ranked directory list, ↩
/// creates and Esc cancels.
///
/// Deliberately plain, like the Tasks panel itself: the contract this ships is
/// the capture flow, not a design.
struct TaskCreationPromptView: View {
  @Bindable var store: StoreOf<TaskCreationPromptFeature>
  @FocusState private var isTitleFieldFocused: Bool

  var body: some View {
    let ranked = store.rankedCandidates
    let selectedID = store.selectedCandidate?.id

    return VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("New Task")
          .font(.headline)
        Text("Name it if you like, then pick where the work happens.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      TextField("Title", text: $store.title, prompt: Text("Untitled — named from the directory"))
        .focused($isTitleFieldFocused)
        .onSubmit { store.send(.createButtonTapped) }
        .help("Optional. Left blank, the task takes its name from the directory it runs in.")

      TextField("Directory", text: $store.directoryQuery, prompt: Text("Filter directories"))
        .onSubmit { store.send(.createButtonTapped) }
        .help("Fuzzy-match a directory by folder name, repository, or branch")

      candidateList(ranked, selectedID: selectedID)

      if let message = store.validationMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel without creating a task (Esc)")
        Button("Create") {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Create the task and open a terminal for it (↩)")
      }
    }
    .textFieldStyle(.roundedBorder)
    .padding(20)
    .frame(minWidth: 420)
    .task { isTitleFieldFocused = true }
  }

  private func candidateList(
    _ ranked: [TaskCreationPromptFeature.Candidate],
    selectedID: TaskCreationPromptFeature.Candidate.ID?
  ) -> some View {
    ScrollViewReader { proxy in
      List {
        if ranked.isEmpty {
          Text(store.candidates.isEmpty ? "No directories yet — open a repository first." : "No matching directory.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        ForEach(ranked) { candidate in
          Button {
            store.send(.selectCandidate(candidate.id))
          } label: {
            TaskCreationCandidateRow(candidate: candidate, isSelected: candidate.id == selectedID)
          }
          .buttonStyle(.plain)
          .id(candidate.id)
          .help("Create the task in \(candidate.directoryURL.path(percentEncoded: false))")
        }
      }
      .listStyle(.bordered)
      .frame(minHeight: 160)
      .onChange(of: selectedID) { _, newValue in
        guard let newValue else { return }
        proxy.scrollTo(newValue)
      }
    }
    // Arrow keys on the list rather than the text field, so typing and walking
    // the ranking never fight over the same key.
    .onMoveCommand { direction in
      switch direction {
      case .up: store.send(.moveSelection(offset: -1))
      case .down: store.send(.moveSelection(offset: 1))
      default: break
      }
    }
  }
}

/// Pure presentation: every field is resolved by the reducer's candidate.
private struct TaskCreationCandidateRow: View {
  let candidate: TaskCreationPromptFeature.Candidate
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
        .font(.caption)
        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(candidate.directoryURL.lastPathComponent)
          .lineLimit(1)
          .truncationMode(.middle)
        if let secondary {
          Text(secondary)
            .font(.caption)
            .monospaced()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 0)
      if candidate.isBusy {
        Image(systemName: "person.2")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Already in use")
          .help("Another active task is already running in this directory — you'll be sharing it")
      }
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// "shared" is written into the line, not left to the icon's tooltip: picking
  /// a busy directory changes what the user gets (a second task working in the
  /// same tree as the first, or a question about it), and a hover-only hint is a
  /// hint nobody reads before pressing ↩.
  private var secondary: String? {
    let parts = [candidate.repositoryName, candidate.branch, candidate.isBusy ? "shared" : nil]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " · ")
  }
}
