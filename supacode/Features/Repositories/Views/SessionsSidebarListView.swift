import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

@MainActor
private struct SessionContextMenu: View {
  let store: StoreOf<SessionSidebarItemFeature>
  /// The other tasks this row's task can merge into; empty for a row that is no task.
  let mergeTargets: [SessionsSidebarStructure.MergeTarget]
  let onSettle: (SessionKey) -> Void
  let onUnsettle: (SessionKey) -> Void
  let onMerge: (LayoutID) -> Void
  let onMarkUnread: (Bool) -> Void

  var body: some View {
    // An idle agent can be put back on the to-do pile; a done one taken off it.
    if store.status == .idle {
      Button("Mark as Unread") { onMarkUnread(true) }
        .help("Bring back the done badge so this shows up in “next session needs me”")
    } else if store.status == .doneUnseen {
      Button("Mark as Read") { onMarkUnread(false) }
    }
    // A shell-only task has no session to settle.
    if let key = store.sessionKey {
      if store.lifecycle == .active {
        Button(store.isTask ? "Settle and Close Tabs" : "Settle and Close Tab") { onSettle(key) }
      } else {
        Button("Unsettle") { onUnsettle(key) }
      }
    }
    if !mergeTargets.isEmpty {
      Menu("Merge into…") {
        ForEach(mergeTargets) { target in
          Button(target.title) { onMerge(target.id) }
            .help("Move this task's tabs and sessions into “\(target.title)”")
        }
      }
    }
  }
}

/// How many agents wait on the user, and the jump the chord makes, for
/// the mouse. Its own view: the count flips with every agent, and only this
/// should redraw when it does.
private struct AttentionBadge: View {
  let store: StoreOf<RepositoriesFeature>
  @FocusedValue(\.nextSessionNeedsMeAction) private var jump
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let count = store.sessionsAttentionCount
    if count > 0 {
      let chord = AppShortcuts.nextSessionNeedsMe.effective(from: settingsFile.global.shortcutOverrides)?.display
      Button {
        jump?()
      } label: {
        Label("\(count)", systemImage: "exclamationmark.circle.fill")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.orange)
      }
      .buttonStyle(.plain)
      .disabled(jump?.isEnabled != true)
      .help("\(count) waiting on you. Jump to the next session that needs you (\(chord ?? "none"))")
      .accessibilityLabel("\(count) sessions need you")
    }
  }
}

struct SessionsSidebarListView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.settingsFile) private var settingsFile
  @Shared(.sessionsExpandSelectedTask) private var expandSelectedTask: Bool
  @State private var isSettledExpanded = false
  @State private var settledLimit = SessionsSidebarStructure.settledPageSize

  var body: some View {
    let shortcutHintByID: [SessionRowID: String]
    let overrides = settingsFile.global.shortcutOverrides
    let structure = store.sessionsSidebarStructure
    let subRows = SubRows(
      taskID: structure.subRowsTaskID,
      rows: structure.subRows,
      nextTab: AppShortcuts.selectNextTab.effective(from: overrides)?.display,
      previousTab: AppShortcuts.selectPreviousTab.effective(from: overrides)?.display,
      mergeTargets: structure.mergeTargets,
      chevronTaskIDs: expandSelectedTask ? nil : store.expandedSessionTaskIDs)
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
          Section {
            rows(section.rowIDs, shortcutHintByID: shortcutHintByID, subRows: subRows)
          } header: {
            HStack {
              Text(section.title)
              Spacer()
              AttentionBadge(store: store)
            }
          }
        } else {
          // Settled is the whole history, thousands of rows; only the
          // most recent page is built, and only while the section is open.
          Section("\(section.title) (\(section.rowIDs.count))", isExpanded: $isSettledExpanded) {
            if isSettledExpanded {
              rows(Array(section.rowIDs.prefix(settledLimit)), shortcutHintByID: shortcutHintByID, subRows: subRows)
              if section.rowIDs.count > settledLimit {
                showMoreRow(remaining: section.rowIDs.count - settledLimit)
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .onAppear { store.send(.sessionsSidebarShown) }
    .onChange(of: isSettledExpanded) { _, expanded in
      if !expanded { settledLimit = SessionsSidebarStructure.settledPageSize }
    }
    .onChange(of: expandSelectedTask) { _, _ in store.send(.sessionsExpandSelectedTaskChanged) }
    .onKeyPress(.upArrow) { moveSelection(by: -1) }
    .onKeyPress(.downArrow) { moveSelection(by: 1) }
    .onKeyPress(.return) {
      guard let id = store.sessionSelection else { return .ignored }
      store.send(.activateSession(id))
      return .handled
    }
  }

  /// The selected task's sessions and the merge targets, from the cached
  /// structure, with the tab chords the tooltips name.
  private struct SubRows {
    let taskID: LayoutID?
    let rows: [SessionsSidebarStructure.SubRow]
    let nextTab: String?
    let previousTab: String?
    let mergeTargets: [SessionsSidebarStructure.MergeTarget]
    /// The tasks opened by hand, while selecting a task does not open it. Nil when it does.
    let chevronTaskIDs: Set<LayoutID>?

    /// A chevron for a task the user opens by hand: nil when selection opens it.
    func chevron(for id: SessionRowID) -> (isExpanded: Bool, layoutID: LayoutID)? {
      guard let chevronTaskIDs, case .task(let layoutID) = id else { return nil }
      return (chevronTaskIDs.contains(layoutID), layoutID)
    }
  }

  private func rows(
    _ ids: [SessionRowID], shortcutHintByID: [SessionRowID: String], subRows: SubRows
  ) -> some View {
    ForEach(ids, id: \.self) { id in
      if let rowStore = store.scope(state: \.sessionItems[id: id], action: \.sessionItems[id: id]) {
        // Only a task row merges; an implicit row has no record to move.
        let mergeTargets: [SessionsSidebarStructure.MergeTarget] =
          if case .task(let layoutID) = id { subRows.mergeTargets.filter { $0.id != layoutID } } else { [] }
        SessionSidebarRowView(store: rowStore, shortcutHint: shortcutHintByID[id], chevron: subRows.chevron(for: id)) {
          store.send(.toggleSessionTaskExpanded($0))
        }
        .tag(id)
        .contextMenu {
          SessionContextMenu(
            store: rowStore,
            mergeTargets: mergeTargets,
            onSettle: { key in
              if case .task(let layoutID) = id {
                store.send(.settleTaskRequested(layoutID))
              } else {
                store.send(.settleSessionRequested(key))
              }
            },
            onUnsettle: { store.send(.unsettleSession($0)) },
            onMerge: { target in
              if case .task(let layoutID) = id { store.send(.mergeTaskRequested(layoutID, into: target)) }
            },
            onMarkUnread: { store.send(.markRowUnreadRequested(id, unread: $0)) }
          )
        }
      }
      // Untagged: a sub-row is not a selection, so the highlight stays on its task.
      if case .task(let layoutID) = id, layoutID == subRows.taskID {
        ForEach(subRows.rows) { row in
          SessionSubRowView(row: row, nextTab: subRows.nextTab, previousTab: subRows.previousTab) {
            store.send(.activateSessionSubRow(task: layoutID, member: row.id))
          }
          .contextMenu {
            if row.isDetachable, let location = row.location {
              Button("Detach into New Task") {
                store.send(.detachTabRequested(location.layoutID, tabID: location.tabID))
              }
              .help("Move this session's tab into its own task")
            }
          }
        }
      }
    }
  }

  private func showMoreRow(remaining: Int) -> some View {
    let step = min(remaining, SessionsSidebarStructure.settledPageSize)
    return Button("Show \(step) more") {
      settledLimit += SessionsSidebarStructure.settledPageSize
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity)
    .help("Load the next \(step) settled sessions (\(remaining) not shown)")
  }

  private func moveSelection(by offset: Int) -> KeyPress.Result {
    let structure = store.sessionsSidebarStructure
    var limit = isSettledExpanded ? settledLimit : 0
    if structure.reachesSettledPageEnd(from: store.sessionSelection, offset: offset, settledLimit: limit) {
      limit += SessionsSidebarStructure.settledPageSize
      settledLimit = limit
    }
    guard let id = structure.selection(byOffset: offset, from: store.sessionSelection, settledLimit: limit)
    else { return .ignored }
    store.send(.sessionSelectionChanged(id))
    return .handled
  }
}

private struct SessionSidebarRowView: View {
  let store: StoreOf<SessionSidebarItemFeature>
  let shortcutHint: String?
  let chevron: (isExpanded: Bool, layoutID: LayoutID)?
  let toggleExpanded: (LayoutID) -> Void

  var body: some View {
    Button {
      store.send(.activate)
    } label: {
      HStack {
        SessionKindIcon(harness: store.harness, isDormant: !store.isLive, status: store.status)
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
        if let chevron, store.hasTangents {
          Button {
            toggleExpanded(chevron.layoutID)
          } label: {
            Image(systemName: chevron.isExpanded ? "chevron.down" : "chevron.right")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel(chevron.isExpanded ? "Hide sessions" : "Show sessions")
          }
          .buttonStyle(.plain)
          .help(chevron.isExpanded ? "Hide this task's sessions" : "Show this task's sessions")
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
    let settled = store.lifecycle == .settled ? "settled " : ""
    if store.isTask {
      return store.isLive
        ? "Show this task (Return when selected)"
        : "Resume this \(settled)task on its primary session (click or Return when selected)"
    }
    return store.isLive
      ? "Focus this session (Return when selected)"
      : "Resume this \(settled)session in a new tab (click or Return when selected) — \(store.cwd)"
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
        SessionKindIcon(harness: row.harness, isDormant: row.isDormant, status: row.status)
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

/// What the row is (agent mark, or a terminal for a shell-only task), then
/// how it is doing: the agent's status, or a moon when nothing is running.
private struct SessionKindIcon: View {
  let harness: SkillAgent?
  let isDormant: Bool
  let status: SessionClassification.Status?

  var body: some View {
    if let harness {
      AgentBadgeView(agent: harness, size: 16)
    } else {
      Image(systemName: "terminal")
        .accessibilityLabel("Shell")
        .help("Shell only, no agent session")
    }
    if isDormant {
      Image(systemName: "moon")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Dormant session")
    } else if let status {
      Image(systemName: status.systemImage)
        .foregroundStyle(status.tint)
        .accessibilityLabel(status.accessibilityLabel)
    }
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
