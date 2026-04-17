import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct SidebarSearchField: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  @Shared(.settingsFile) private var settingsFile
  @FocusState private var isFocused: Bool

  var body: some View {
    let shortcut = AppShortcuts.sidebarSearch.effective(from: settingsFile.global.shortcutOverrides)
    let hint = shortcut?.display ?? "⌘K"

    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(
        "Search repositories",
        text: Binding(
          get: { store.state.sidebarSearchQuery },
          set: { store.send(.sidebarSearchQueryChanged($0)) },
        ),
      )
      .textFieldStyle(.plain)
      .focused($isFocused)
      .onExitCommand {
        store.send(.sidebarSearchQueryChanged(""))
        isFocused = false
      }
      if !store.state.sidebarSearchQuery.isEmpty {
        Button {
          store.send(.sidebarSearchQueryChanged(""))
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      } else {
        Text(hint)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .monospaced()
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
    )
    .padding(.horizontal, 8)
    .padding(.top, 6)
    .padding(.bottom, 2)
    .focusedSceneValue(\.focusSidebarSearchAction) {
      isFocused = true
    }
  }
}

private struct FocusSidebarSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var focusSidebarSearchAction: (() -> Void)? {
    get { self[FocusSidebarSearchActionKey.self] }
    set { self[FocusSidebarSearchActionKey.self] = newValue }
  }
}
