import ComposableArchitecture
import SwiftUI

struct WorktreeCreationPromptView: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  @FocusState private var isBranchFieldFocused: Bool
  @FocusState private var isBaseRefFieldFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("Branch name", text: $store.branchName)
          .focused($isBranchFieldFocused)
          .onSubmit {
            store.send(.createButtonTapped)
          }
      } header: {
        Text("New Worktree")
        Text("Create a branch in `\(store.repositoryName)`.")
      }
      .headerProminence(.increased)

      Section {
        VStack(alignment: .leading, spacing: 4) {
          Text("Base ref")
          Text("The branch or ref the new worktree will be created from.")
            .foregroundStyle(.secondary)
            .font(.caption)

          BaseRefSearchField(
            searchText: $store.baseRefSearchText,
            isFocused: $isBaseRefFieldFocused,
            automaticBaseRef: store.automaticBaseRef,
            filteredOptions: store.filteredBaseRefOptions,
            selectedBaseRef: store.selectedBaseRef,
            onSelect: { ref in
              store.send(.baseRefSelected(ref))
              isBaseRefFieldFocused = false
            },
          )
        }

        Toggle(isOn: $store.fetchOrigin) {
          Text("Fetch remote branch")
          Text(
            "Runs `git fetch` to ensure the base branch is up to date before creating the worktree."
          )
        }
      } footer: {
        if let validationMessage = store.validationMessage, !validationMessage.isEmpty {
          Text(validationMessage)
            .foregroundStyle(.red)
        }
      }

    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        if store.isValidating {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button("Create") {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Create (↩)")
        .disabled(store.isValidating)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { isBranchFieldFocused = true }
  }
}

private struct BaseRefSearchField: View {
  @Binding var searchText: String
  var isFocused: FocusState<Bool>.Binding
  let automaticBaseRef: String
  let filteredOptions: [String]
  let selectedBaseRef: String?
  let onSelect: (String?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.caption)
          .accessibilityHidden(true)
        TextField(autoPlaceholder, text: $searchText)
          .textFieldStyle(.plain)
          .focused(isFocused)
        if selectedBaseRef != nil {
          Button {
            onSelect(nil)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
              .accessibilityLabel("Reset to auto")
          }
          .buttonStyle(.plain)
          .help("Reset to auto")
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(.quinary)
      .clipShape(RoundedRectangle(cornerRadius: 6))

      if isFocused.wrappedValue {
        suggestionsList
      }
    }
  }

  private var autoPlaceholder: String {
    guard !automaticBaseRef.isEmpty else { return "Search refs…" }
    return "Auto (\(automaticBaseRef))"
  }

  @ViewBuilder
  private var suggestionsList: some View {
    let suggestions = filteredOptions
    if !suggestions.isEmpty {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(suggestions, id: \.self) { ref in
            Button {
              onSelect(ref)
            } label: {
              HStack {
                Text(ref)
                  .monospaced()
                  .lineLimit(1)
                Spacer()
                if selectedBaseRef == ref {
                  Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                }
              }
              .contentShape(Rectangle())
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .frame(maxHeight: 180)
      .background(.quinary)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .padding(.top, 4)
    }
  }
}
