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
  /// The keyboard sits on the settled "Show more" row; the list shows no selected row then.
  @State private var isShowMoreSelected = false

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
      revealedTaskIDs: store.revealedHiddenTaskIDs,
      chevronTaskIDs: expandSelectedTask ? nil : store.expandedSessionTaskIDs,
      selection: store.sessionSelection)
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
        get: { isShowMoreSelected ? nil : store.sessionSelection },
        set: {
          isShowMoreSelected = false
          store.send(.sessionSelectionChanged($0))
        }
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
      if !expanded {
        settledLimit = SessionsSidebarStructure.settledPageSize
        isShowMoreSelected = false
      }
    }
    .onChange(of: store.sessionSelection) { _, _ in isShowMoreSelected = false }
    .onChange(of: expandSelectedTask) { _, _ in store.send(.sessionsExpandSelectedTaskChanged) }
    .onKeyPress(.upArrow) { moveSelection(by: -1) }
    .onKeyPress(.downArrow) { moveSelection(by: 1) }
    .onKeyPress(.return) {
      if isShowMoreSelected {
        showMoreSettled()
        return .handled
      }
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
    let revealedTaskIDs: Set<LayoutID>
    /// The tasks opened by hand, while selecting a task does not open it. Nil when it does.
    let chevronTaskIDs: Set<LayoutID>?
    let selection: SessionRowID?

    // No chord: a sub-row is not a selection, so the keyboard cannot name one.
    static let hideHelp = "Drop this ended session from the task's list; it stays in the task"

    /// A chevron for a task the user opens by hand: nil when selection opens it.
    func chevron(for id: SessionRowID) -> (isExpanded: Bool, layoutID: LayoutID)? {
      guard let chevronTaskIDs, case .task(let layoutID) = id else { return nil }
      return (selection == id && chevronTaskIDs.contains(layoutID), layoutID)
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
        SessionSidebarRowView(
          store: rowStore, shortcutHint: shortcutHintByID[id], chevron: subRows.chevron(for: id),
          revealsHidden: subRows.revealedTaskIDs.contains(where: { .task($0) == id }),
          toggleExpanded: { store.send(.toggleSessionTaskExpanded($0)) },
          toggleHidden: { store.send(.toggleHiddenSessionsRevealed($0)) }
        )
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
            if let key = row.id.sessionKey {
              if row.isHidden {
                Button("Unhide") { store.send(.unhideSessionInTask(layoutID, key)) }
                  .help("List this session under the task again")
              } else {
                Button("Hide from Task") { store.send(.hideSessionFromTask(layoutID, key)) }
                  .disabled(!row.isHideable)
                  .help(row.hideRefusal?.reason ?? SubRows.hideHelp)
              }
            }
          }
        }
      }
    }
  }

  private func showMoreRow(remaining: Int) -> some View {
    let step = min(remaining, SessionsSidebarStructure.settledPageSize)
    return Button("Show \(step) more") { showMoreSettled() }
      .buttonStyle(.plain)
      .foregroundStyle(isShowMoreSelected ? .primary : .secondary)
      .frame(maxWidth: .infinity)
      .listRowBackground(isShowMoreSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.5) : nil)
      .help("Load the next \(step) settled sessions (\(remaining) not shown). Return when selected")
  }

  private func showMoreSettled() {
    settledLimit += SessionsSidebarStructure.settledPageSize
    guard isShowMoreSelected, !store.sessionsSidebarStructure.hasMoreSettled(than: settledLimit) else { return }
    // Nothing left to page: the keyboard falls back onto the last row.
    isShowMoreSelected = false
    if let last = store.sessionsSidebarStructure.visibleIDs(settledLimit: settledLimit).last {
      store.send(.sessionSelectionChanged(last))
    }
  }

  private func moveSelection(by offset: Int) -> KeyPress.Result {
    let structure = store.sessionsSidebarStructure
    let limit = isSettledExpanded ? settledLimit : 0
    let current: SessionsSidebarStructure.KeyboardStop? =
      isShowMoreSelected ? .showMoreSettled : store.sessionSelection.map { .row($0) }
    guard let stop = structure.keyboardStop(byOffset: offset, from: current, settledLimit: limit)
    else { return .ignored }
    switch stop {
    case .showMoreSettled:
      isShowMoreSelected = true
    case .row(let id):
      isShowMoreSelected = false
      store.send(.sessionSelectionChanged(id))
    }
    return .handled
  }
}

private struct SessionSidebarRowView: View {
  let store: StoreOf<SessionSidebarItemFeature>
  let shortcutHint: String?
  let chevron: (isExpanded: Bool, layoutID: LayoutID)?
  let revealsHidden: Bool
  let toggleExpanded: (LayoutID) -> Void
  let toggleHidden: (LayoutID) -> Void

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
        if case .task(let layoutID) = store.id, store.hiddenCount > 0 {
          Button {
            toggleHidden(layoutID)
          } label: {
            Text("+\(store.hiddenCount) hidden")
              .font(.caption)
              .foregroundStyle(revealsHidden ? .primary : .secondary)
          }
          .buttonStyle(.plain)
          .help(
            revealsHidden
              ? "Stop listing the \(store.hiddenCount) hidden sessions of this task"
              : "List the \(store.hiddenCount) sessions hidden from this task, dimmed"
          )
          .accessibilityLabel("\(store.hiddenCount) hidden sessions")
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
      .opacity(row.isHidden ? 0.6 : 1)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .padding(.leading)
    .help(helpText)
  }

  private var helpText: String {
    if row.isHidden { return "Hidden from this task. Click to resume it, or Unhide from its menu" }
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
      let glyph = status.glyph
      Image(systemName: glyph.symbol)
        .foregroundStyle(glyph.tint)
        .accessibilityLabel(glyph.label)
        .help(glyph.label)
    }
  }
}

extension SessionClassification.Status {
  /// What the sessions row draws for a status. One value so a test can pin a
  /// status to its symbol and tooltip without rendering the row.
  struct Glyph: Equatable {
    var symbol: String
    var label: String
    var tint: Color
  }

  var glyph: Glyph {
    switch self {
    case .needsYou: Glyph(symbol: "exclamationmark.circle.fill", label: "Needs you", tint: .orange)
    case .question: Glyph(symbol: "questionmark.bubble.fill", label: "Waiting for your answer", tint: .orange)
    case .working: Glyph(symbol: "gearshape.fill", label: "Working", tint: .blue)
    case .doneUnseen: Glyph(symbol: "checkmark.circle.fill", label: "Done unseen", tint: .green)
    case .idle: Glyph(symbol: "circle", label: "Idle", tint: .secondary)
    }
  }
}
