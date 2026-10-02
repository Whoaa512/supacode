import ComposableArchitecture
import SwiftUI

struct SessionsSidebarListView: View {
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    List(
      selection: Binding(
        get: { store.sessionSelection },
        set: { store.send(.sessionSelectionChanged($0)) }
      )
    ) {
      if store.sessionsSidebarStructure.sections.isEmpty {
        Text("No sessions")
          .foregroundStyle(.secondary)
      }
      ForEach(store.sessionsSidebarStructure.sections) { section in
        Section(section.title) {
          ForEach(section.rowIDs, id: \.self) { id in
            if let rowStore = store.scope(
              state: \.sessionItems[id: id], action: \.sessionItems[id: id])
            {
              SessionSidebarRowView(store: rowStore)
                .tag(id)
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .onAppear { store.send(.sessionsSidebarShown) }
    .onKeyPress(.return) {
      guard let id = store.sessionSelection else { return .ignored }
      store.send(.activateSession(id))
      return .handled
    }
  }
}

private struct SessionSidebarRowView: View {
  let store: StoreOf<SessionSidebarItemFeature>

  var body: some View {
    Button {
      store.send(.activate)
    } label: {
      HStack {
        Image(systemName: store.isLive ? "terminal" : "moon")
          .accessibilityLabel(store.isLive ? "Live session" : "Dormant session")
        VStack(alignment: .leading, spacing: 2) {
          Text(store.title)
            .font(.body)
            .lineLimit(1)
          Text(URL(fileURLWithPath: store.cwd).lastPathComponent)
            .font(.caption)
            .monospaced()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(store.cwd)
        }
      }
      .foregroundStyle(store.isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(
      store.isLive ? "Focus this session (Return when selected)" : "Dormant session — \(store.cwd)")
  }
}
