import ComposableArchitecture
import SwiftUI

struct AgentRenameView: View {
  @Bindable var store: StoreOf<AgentRenameFeature>
  @FocusState private var isNameFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $store.name, prompt: Text("reviewer"))
          .focused($isNameFocused)
          .monospaced()
          .onSubmit { store.send(.saveButtonTapped) }
        if let error = store.validationError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Rename Agent")
        Text("Name `\(store.subject)` so `supacode agent` can address it. Leave empty to clear.")
      }
      .headerProminence(.increased)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Spacer()
        Button("Cancel") { store.send(.cancelButtonTapped) }
          .keyboardShortcut(.cancelAction)
          .help("Cancel (Esc)")
        Button("Save") { store.send(.saveButtonTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(!store.canSave)
          .help("Save the agent name (↩)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { isNameFocused = true }
  }
}
