import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

@MainActor
private struct SessionContextMenu: View {
  let store: StoreOf<SessionSidebarItemFeature>
  let onSettle: (SessionKey) -> Void
  let onUnsettle: (SessionKey) -> Void

  var body: some View {
    // A shell-only task has no session to settle.
    if let key = store.sessionKey {
      if store.lifecycle == .active {
        Button(store.isTask ? "Settle and Close Tabs" : "Settle and Close Tab") { onSettle(key) }
      } else {
        Button("Unsettle") { onUnsettle(key) }
      }
    }
  }
}

struct SessionsSidebarListView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.settingsFile) private var settingsFile
  @State private var isSettledExpanded = false

  var body: some View {
    let shortcutHintByID: [SessionRowID: String]
    let overrides = settingsFile.global.shortcutOverrides
    let structure = store.sessionsSidebarStructure
    let subRows = SubRows(
      taskID: structure.subRowsTaskID,
      rows: structure.subRows,
      nextTab: AppShortcuts.selectNextTab.effective(from: overrides)?.display,
      previousTab: AppShortcuts.selectPreviousTab.effective(from: overrides)?.display)
    if commandKeyObserver.isPressed {
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
      // Running agents show up as rows before the first scan lands, so the
      // list is rarely empty while history is still loading.
      let isEmpty = structure.sections.isEmpty
      if !store.sessionsHasCompletedRefresh || (isEmpty && store.sessionsIndexingInProgress) {
        Text("Indexing sessions\u{2026}")
          .foregroundStyle(.secondary)
      } else if isEmpty {
        Text("No sessions")
          .foregroundStyle(.secondary)
      }
      ForEach(structure.sections) { section in
        if section.id == .active {
          Section(section.title) { rows(section.rowIDs, shortcutHintByID: shortcutHintByID, subRows: subRows) }
        } else {
          // Settled is the whole history, thousands of rows; they are only
          // built while the section is open.
          Section("\(section.title) (\(section.rowIDs.count))", isExpanded: $isSettledExpanded) {
            if isSettledExpanded { rows(section.rowIDs, shortcutHintByID: shortcutHintByID, subRows: subRows) }
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

  /// The selected task's sessions, from the cached structure, with the tab
  /// chords their tooltips name.
  private struct SubRows {
    let taskID: LayoutID?
    let rows: [SessionsSidebarStructure.SubRow]
    let nextTab: String?
    let previousTab: String?
  }

  private func rows(
    _ ids: [SessionRowID], shortcutHintByID: [SessionRowID: String], subRows: SubRows
  ) -> some View {
    ForEach(ids, id: \.self) { id in
      if let rowStore = store.scope(state: \.sessionItems[id: id], action: \.sessionItems[id: id]) {
        SessionSidebarRowView(store: rowStore, shortcutHint: shortcutHintByID[id])
          .tag(id)
          .contextMenu {
            SessionContextMenu(
              store: rowStore,
              onSettle: { key in
                if case .task(let layoutID) = id {
                  store.send(.settleTaskRequested(layoutID))
                } else {
                  store.send(.settleSessionRequested(key))
                }
              },
              onUnsettle: { store.send(.unsettleSession($0)) }
            )
          }
      }
      // Untagged: a sub-row is not a selection, so the highlight stays on its task.
      if case .task(let layoutID) = id, layoutID == subRows.taskID {
        ForEach(subRows.rows) { row in
          SessionSubRowView(row: row, nextTab: subRows.nextTab, previousTab: subRows.previousTab) {
            store.send(.activateSessionSubRow(task: layoutID, member: row.id))
          }
        }
      }
    }
  }

  private func moveSelection(by offset: Int) -> KeyPress.Result {
    guard
      let id = store.sessionsSidebarStructure.selection(
        byOffset: offset, from: store.sessionSelection, includingSettled: isSettledExpanded)
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
    .help(helpText)
  }
}

extension SessionSidebarRowView {
  private var helpText: String {
    if store.isTask {
      return store.isLive
        ? "Show this task (Return when selected)" : "Reopen this task on its primary session (Return when selected)"
    }
    return store.isLive ? "Focus this session (Return when selected)" : "Dormant session — \(store.cwd)"
  }
}

/// One session of the selected task. Plain values only: it reads no store.
private struct SessionSubRowView: View {
  let row: SessionsSidebarStructure.SubRow
  let nextTab: String?
  let previousTab: String?
  let activate: () -> Void

  var body: some View {
    Button(action: activate) {
      HStack {
        Image(systemName: row.isDormant ? "moon" : "terminal")
          .accessibilityLabel(row.isDormant ? "Dormant session" : "Live session")
        if let status = row.status {
          Image(systemName: status.systemImage)
            .foregroundStyle(status.tint)
            .accessibilityLabel(status.accessibilityLabel)
        }
        Text(row.title)
          .font(.callout)
          .lineLimit(1)
        Spacer()
      }
      .foregroundStyle(row.isDormant ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .padding(.leading)
    .help(helpText)
  }

  private var helpText: String {
    guard !row.isDormant else { return "Resume this session in a new tab of this task" }
    let chords = [nextTab.map { "Next Tab \($0)" }, previousTab.map { "Previous Tab \($0)" }].compactMap { $0 }
    return chords.isEmpty ? "Focus this session" : "Focus this session (\(chords.joined(separator: ", ")))"
  }
}

extension SessionClassification.Status {
  fileprivate var systemImage: String {
    switch self {
    case .needsYou: "exclamationmark.circle.fill"
    case .working: "gearshape.fill"
    case .doneUnseen: "checkmark.circle.fill"
    case .idle: "circle"
    }
  }

  fileprivate var tint: AnyShapeStyle {
    switch self {
    case .needsYou: AnyShapeStyle(.orange)
    case .working: AnyShapeStyle(.blue)
    case .doneUnseen: AnyShapeStyle(.green)
    case .idle: AnyShapeStyle(.secondary)
    }
  }

  fileprivate var accessibilityLabel: String {
    switch self {
    case .needsYou: "Needs you"
    case .working: "Working"
    case .doneUnseen: "Done unseen"
    case .idle: "Idle"
    }
  }
}
