import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

@MainActor
private struct SessionContextMenu: View {
  let store: StoreOf<SessionSidebarItemFeature>
  let onSettle: () -> Void
  let onUnsettle: () -> Void

  var body: some View {
    if store.lifecycle == .active {
      Button("Settle") { onSettle() }
    } else {
      Button("Unsettle") { onUnsettle() }
    }
  }
}

struct SessionsSidebarListView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let shortcutHintByID: [SessionRowID: String]
    if commandKeyObserver.isPressed {
      let overrides = settingsFile.global.shortcutOverrides
      let structure = store.sessionsSidebarStructure
      shortcutHintByID = structure.liveIDs.enumerated().reduce(into: [:]) { dict, pair in
        let (index, rowID) = pair
        if let hint = AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: index, overrides: overrides) {
          dict[rowID] = hint
        }
      }
    } else {
      shortcutHintByID = [:]
    }
    return List(
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
              SessionSidebarRowView(store: rowStore, shortcutHint: shortcutHintByID[id])
                .tag(id)
                .contextMenu {
                  if case .session(let key) = id {
                    SessionContextMenu(
                      store: rowStore,
                      onSettle: { store.send(.settleSession(key)) },
                      onUnsettle: { store.send(.unsettleSession(key)) }
                    )
                  }
                }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .onAppear { store.send(.sessionsSidebarShown) }
    .onKeyPress(.upArrow) { moveSelection(by: -1) }
    .onKeyPress(.downArrow) { moveSelection(by: 1) }
    .onKeyPress(.return) {
      guard let id = store.sessionSelection else { return .ignored }
      store.send(.activateSession(id))
      return .handled
    }
  }

  private func moveSelection(by offset: Int) -> KeyPress.Result {
    guard let id = store.sessionsSidebarStructure.selection(byOffset: offset, from: store.sessionSelection)
    else { return .ignored }
    store.send(.sessionSelectionChanged(id))
    return .handled
  }
}

private struct SessionSidebarRowView: View {
  let store: StoreOf<SessionSidebarItemFeature>
  let shortcutHint: String?

  var body: some View {
    Button {
      store.send(.activate)
    } label: {
      HStack {
        Image(systemName: store.isLive ? "terminal" : "moon")
          .accessibilityLabel(store.isLive ? "Live session" : "Dormant session")
        if let status = store.status {
          Image(systemName: status.systemImage)
            .foregroundStyle(status.tint)
            .accessibilityLabel(status.accessibilityLabel)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(store.title)
            .font(.body)
            .lineLimit(1)
          HStack(spacing: 4) {
            Text(URL(fileURLWithPath: store.cwd).lastPathComponent)
            if let branch = store.branchAnnotation {
              Text(branch)
                .foregroundStyle(.tertiary)
            }
          }
          .font(.caption)
          .monospaced()
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(store.cwd)
        }
        Spacer()
        if let hint = shortcutHint {
          Text(hint)
            .font(.caption)
            .foregroundStyle(.quaternary)
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

private extension SessionClassification.Status {
  var systemImage: String {
    switch self {
    case .needsYou: "exclamationmark.circle.fill"
    case .working: "gearshape.fill"
    case .doneUnseen: "checkmark.circle.fill"
    case .idle: "circle"
    }
  }

  var tint: AnyShapeStyle {
    switch self {
    case .needsYou: AnyShapeStyle(.orange)
    case .working: AnyShapeStyle(.blue)
    case .doneUnseen: AnyShapeStyle(.green)
    case .idle: AnyShapeStyle(.secondary)
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .needsYou: "Needs you"
    case .working: "Working"
    case .doneUnseen: "Done unseen"
    case .idle: "Idle"
    }
  }
}
