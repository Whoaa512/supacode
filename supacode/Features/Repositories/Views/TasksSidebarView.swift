import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The Tasks panel. Phase 1's deliberately plain list: the point here is the
/// invalidation shape, not the styling.
///
/// This body reads `store.tasksSidebarStructure` (plus the two cheap scalars the
/// shelf needs) and *nothing else*. Order, sections, paging and the settled
/// label's timestamp all arrive pre-resolved from the reducer, so no agent tick
/// can reach this body — per-row data is read one level down, inside
/// `TaskSidebarRowView`, so a leaf mutation invalidates exactly one row
/// (assertion A10). Reading `taskRecords[id:]` or `taskLeaves[id:]` here would
/// observation-track every task and fan every tick out to the whole List.
struct TasksSidebarView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>

  var body: some View {
    let structure = store.tasksSidebarStructure
    let selectedTaskID = store.selection?.taskID
    let isSettledTailExpanded = store.isSettledTailExpanded
    let isSnoozedShelfExpanded = store.isSnoozedShelfExpanded

    return VStack(spacing: 0) {
      TasksNewTaskBar(store: store)
      Divider()
      taskList(
        structure: structure,
        selectedTaskID: selectedTaskID,
        isSettledTailExpanded: isSettledTailExpanded,
        isSnoozedShelfExpanded: isSnoozedShelfExpanded
      )
    }
  }

  private func taskList(
    structure: TasksSidebarStructure,
    selectedTaskID: TaskID?,
    isSettledTailExpanded: Bool,
    isSnoozedShelfExpanded: Bool
  ) -> some View {
    List(selection: selectionBinding(current: selectedTaskID)) {
      if structure.visibleTaskIDs.isEmpty, structure.settledTotalCount == 0,
        structure.snoozedTotalCount == 0
      {
        emptyRow
      }

      if !structure.activeTaskIDs.isEmpty {
        Section {
          ForEach(structure.activeTaskIDs, id: \.self) { taskID in
            TaskSidebarRowView(
              store: store,
              taskID: taskID,
              settledTimestamp: nil,
              isSettled: false,
              isPinned: structure.pinnedTaskIDs.contains(taskID),
              isWoke: structure.wokeTaskIDs.contains(taskID)
            )
          }
        } header: {
          Text("Active (\(structure.activeTaskIDs.count))")
            .help("\(structure.activeTaskIDs.count) task(s) still in flight, newest first")
        }
      }

      if structure.snoozedTotalCount > 0 {
        Section {
          ForEach(structure.visibleSnoozedEntries) { entry in
            TaskSidebarRowView(
              store: store,
              taskID: entry.id,
              settledTimestamp: nil,
              isSettled: false,
              isPinned: structure.pinnedTaskIDs.contains(entry.id),
              isWoke: false,
              wakeAt: entry.wakeAt
            )
          }
        } header: {
          snoozedHeader(structure: structure, isExpanded: isSnoozedShelfExpanded)
        }
      }

      if structure.settledTotalCount > 0 {
        Section {
          ForEach(structure.visibleSettledTail) { entry in
            TaskSidebarRowView(
              store: store,
              taskID: entry.id,
              settledTimestamp: entry.settledTimestamp,
              isSettled: true,
              isPinned: false,
              isWoke: false
            )
          }
          if structure.hiddenSettledCount > 0 {
            showMoreRow(hiddenCount: structure.hiddenSettledCount)
          }
        } header: {
          settledHeader(structure: structure, isExpanded: isSettledTailExpanded)
        }
      }
    }
    .listStyle(.sidebar)
    .frame(minWidth: 220)
  }

  /// Native list highlight, with clicks and keyboard both routed through
  /// `.tasks(.select)` so either one stamps `lastVisitedAt` and focuses the
  /// task's surfaces (A5). Guarded on a change so re-selecting the open row
  /// doesn't re-stamp and re-persist on every keypress.
  private func selectionBinding(current: TaskID?) -> Binding<Set<SidebarSelection>> {
    Binding(
      get: { current.map { [SidebarSelection.task($0)] } ?? [] },
      set: { newValue in
        guard let taskID = newValue.compactMap(\.taskID).first, taskID != current else { return }
        store.send(.tasks(.select(taskID)))
      }
    )
  }

  private var emptyRow: some View {
    ContentUnavailableView(
      "No Tasks",
      systemImage: SidebarTab.tasks.systemImage,
      description: Text("Work you have open shows up here once Supacode has seen activity in it.")
    )
    .listRowSeparator(.hidden)
  }

  private func settledHeader(structure: TasksSidebarStructure, isExpanded: Bool) -> some View {
    Button {
      store.send(.tasks(.setSettledTailExpanded(!isExpanded)))
    } label: {
      HStack(spacing: 4) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .accessibilityHidden(true)
        Text("Settled (\(structure.settledTotalCount))")
        Spacer(minLength: 0)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(
      isExpanded
        ? "Hide the settled tail — \(structure.settledTotalCount) task(s) wrapped up"
        : "Show the settled tail — \(structure.settledTotalCount) task(s) wrapped up"
    )
  }

  private func snoozedHeader(structure: TasksSidebarStructure, isExpanded: Bool) -> some View {
    Button {
      store.send(.tasks(.setSnoozedShelfExpanded(!isExpanded)))
    } label: {
      HStack(spacing: 4) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .accessibilityHidden(true)
        Text("Snoozed (\(structure.snoozedTotalCount))")
        Spacer(minLength: 0)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(
      isExpanded
        ? "Hide the snoozed shelf — \(structure.snoozedTotalCount) task(s) parked until later"
        : "Show the snoozed shelf — \(structure.snoozedTotalCount) task(s) parked until later"
    )
  }

  private func showMoreRow(hiddenCount: Int) -> some View {
    Button {
      store.send(.tasks(.expandSettledTail))
    } label: {
      Text("Show \(hiddenCount) more")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .help("Load the next page of settled tasks (\(hiddenCount) still hidden)")
  }
}

/// The discoverable half of ⌘N: the shortcut is the fast path, this is how
/// someone finds out it exists.
///
/// Its own view so the `@Shared(.settingsFile)` read stays here. On the panel
/// itself, every settings write — any shortcut override, any unrelated global —
/// would invalidate the whole List along with the bar (A10).
private struct TasksNewTaskBar: View {
  let store: StoreOf<RepositoriesFeature>
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let shortcut = AppShortcuts.newWorktree.effective(from: settingsFile.global.shortcutOverrides)
    return Button {
      store.send(.tasks(.presentCreationPrompt))
    } label: {
      Label("New Task", systemImage: "plus")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .help("Capture a new task — name it and pick where it runs (\(shortcut?.display ?? "none"))")
  }
}

/// One task row, and the whole reason the panel is split in two: this is the
/// only place a task record or task leaf is read from a view body, so an agent
/// tick on one task invalidates this row and no sibling (A10).
///
/// `taskRecords` is not element-observable (a plain `TaskRecord` isn't
/// `@ObservableState`), so a lifecycle mutation — settle, unsettle, a visit
/// stamp — does invalidate every row. That is the rare, user-initiated path, and
/// it usually changes the cached structure anyway; the frequent path (agent and
/// terminal activity) touches `taskLeaves`, which is element-observable.
private struct TaskSidebarRowView: View {
  let store: StoreOf<RepositoriesFeature>
  let taskID: TaskID
  /// Pre-resolved by the structure — the same value the tail was sorted by, so
  /// the label can't drift from the order (A17).
  let settledTimestamp: Date?
  let isSettled: Bool
  let isPinned: Bool
  /// Its snooze ended and the user has not opened it since (A24). Derived by the
  /// structure, never stored, so a relaunch re-derives the same answer.
  let isWoke: Bool
  /// Set only for rows on the snoozed shelf, for the countdown.
  var wakeAt: Date?

  var body: some View {
    #if DEBUG
      TaskRowBodyEvalCounter.record(taskID)
    #endif
    let record = store.taskRecords[id: taskID]
    let leaf = store.taskLeaves[id: taskID]

    return Button {
      store.send(.tasks(.select(taskID)))
    } label: {
      TaskSidebarRowContentView(
        title: record?.title ?? "",
        directoryName: Self.directoryName(for: record),
        branch: record?.branch,
        isLowConfidenceSeed: (record?.seedEvidence).map { $0.confidence != .high } ?? false,
        hasUnseenNotifications: leaf?.hasUnseenNotifications == true,
        activity: TaskRowActivity(leaf: leaf),
        childAgents: leaf?.childAgents ?? [],
        settledTimestamp: settledTimestamp,
        isSettled: isSettled,
        isPinned: isPinned,
        isWoke: isWoke,
        wakeAt: wakeAt
      )
    }
    .buttonStyle(.plain)
    .tag(SidebarSelection.task(taskID))
    .help(Self.help(title: record?.title, isSettled: isSettled))
    .contextMenu {
      lifecycleMenuItems(canSettle: leaf?.canSettle ?? true)
      Divider()
      snoozeMenuItems(canSnooze: leaf?.canSnooze ?? true, isSnoozed: wakeAt != nil)
      Divider()
      pinMenuItems()
    }
  }

  /// A18b: the affordance is *disabled* rather than hidden, and says why. A menu
  /// item that vanishes when an agent asks a question reads as a bug; one that
  /// greys out with a reason reads as the app knowing something.
  @ViewBuilder
  private func lifecycleMenuItems(canSettle: Bool) -> some View {
    if isSettled {
      Button("Unsettle") { store.send(.tasks(.unsettle(taskID))) }
        .help("Move this task back to Active. Its sessions stay as they are until you open it.")
    } else {
      Button("Settle") { store.send(.tasks(.settle(taskID))) }
        .disabled(!canSettle)
        .help(
          canSettle
            ? "Mark this task wrapped up and move it to the settled tail. "
              + "Its sessions hibernate when nothing else is using the directory; scrollback is kept."
            : "An agent on this task is working or waiting on you — answer it first."
        )
    }
    Button("Keep Active") { store.send(.tasks(.keepActive(taskID))) }
      .help("Pin this task as active so it is never auto-settled by inactivity.")
  }

  /// Presets are resolved against the clock at menu-open time, never precomputed
  /// (A23): one whose instant has already passed is omitted rather than silently
  /// rolled to tomorrow, which would make a single menu item mean two things.
  @ViewBuilder
  private func snoozeMenuItems(canSnooze: Bool, isSnoozed: Bool) -> some View {
    if isSnoozed {
      Button("Wake Now") { store.send(.tasks(.unsnooze(taskID))) }
        .help("Bring this task back to Active right now, ahead of its wake time.")
    }
    Menu("Snooze") {
      ForEach(TaskSnooze.resolveSnoozePresets(now: Date(), calendar: .autoupdatingCurrent), id: \.preset) { preset in
        Button(Self.presetTitle(preset)) {
          store.send(.tasks(.snooze(taskID, until: preset.wakeAt)))
        }
        .help("Park this task until \(Self.presetTitle(preset).lowercased()); it comes back where it is now.")
      }
    }
    .disabled(!canSnooze)
    .help(
      canSnooze
        ? "Park this task until later. It comes back in the same place, and an agent that needs you wakes it early."
        : "This task is waiting on you — snoozing it would surface it again immediately."
    )
  }

  @ViewBuilder
  private func pinMenuItems() -> some View {
    if isPinned {
      Button("Unpin") { store.send(.tasks(.unpin(taskID))) }
        .help("Stop keeping this task at the top of Active.")
    } else {
      Button("Pin") { store.send(.tasks(.pin(taskID))) }
        .help("Keep this task at the top of Active. Settling it clears the pin.")
    }
  }

  private static func presetTitle(_ preset: TaskSnooze.ResolvedPreset) -> String {
    switch preset.preset {
    case .oneHour: "In an Hour"
    case .thisEvening: "This Evening"
    case .tomorrow: "Tomorrow"
    case .nextWeek: "Next Week"
    }
  }

  /// Trailing path component of the task's directory — the part that identifies
  /// the worktree in a sidebar-width row.
  private static func directoryName(for record: TaskRecord?) -> String {
    guard let record, !record.directoryPath.isEmpty else { return "" }
    return URL(filePath: record.directoryPath).lastPathComponent
  }

  private static func help(title: String?, isSettled: Bool) -> String {
    let name = title ?? "this task"
    return isSettled
      ? "Open \(name) — settled. Right-click to unsettle it."
      : "Open \(name) and focus its terminal. Right-click to settle it."
  }
}

/// What a row shows about activity. A tiny value rather than the leaf itself so
/// the presentational view can't reach for anything else, and so the dot's
/// precedence (error beats working) lives in one place.
private enum TaskRowActivity: Equatable {
  case error
  case working
  case dormant
  case none

  init(leaf: TaskLeafState?) {
    guard let leaf else {
      self = .none
      return
    }
    if leaf.agentSnapshot.hasError {
      self = .error
    } else if leaf.agentSnapshot.isWorking {
      self = .working
    } else if leaf.allSurfacesDormant {
      self = .dormant
    } else {
      self = .none
    }
  }

  var systemImage: String? {
    switch self {
    case .error: "exclamationmark.circle.fill"
    case .working: "circle.fill"
    case .dormant: "moon.zzz"
    case .none: nil
    }
  }

  var style: AnyShapeStyle {
    switch self {
    case .error: AnyShapeStyle(.red)
    case .working: AnyShapeStyle(.tint)
    case .dormant, .none: AnyShapeStyle(.secondary)
    }
  }

  var help: String {
    switch self {
    case .error: "An agent on this task reported an error"
    case .working: "An agent is working on this task"
    case .dormant: "Every session for this task is hibernated"
    case .none: "No agent activity reported"
    }
  }
}

/// Pure presentation: every field is already resolved, so this view has nothing
/// to observe and re-renders only when its inputs actually differ.
private struct TaskSidebarRowContentView: View {
  let title: String
  let directoryName: String
  /// `nil` when the branch was never provable. Renders nothing rather than a
  /// guess (A2).
  let branch: String?
  let isLowConfidenceSeed: Bool
  let hasUnseenNotifications: Bool
  let activity: TaskRowActivity
  /// Hook-reported agents on this task's surfaces (A22). Empty is the common
  /// case and renders nothing.
  let childAgents: [TaskLeafState.ChildAgent]
  let settledTimestamp: Date?
  let isSettled: Bool
  let isPinned: Bool
  let isWoke: Bool
  /// Wake instant for a parked row — the same value the shelf sorted by (A17's
  /// rule applied to snooze), so the countdown can't disagree with the order.
  let wakeAt: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      summary
      // Inside the task's row rather than as sibling List rows: a child row's
      // drill-in *is* the task's surface tabs (A22), so the whole thing is one
      // click target and one selectable row.
      ForEach(childAgents) { child in
        TaskChildAgentRowView(child: child)
      }
    }
    .contentShape(.rect)
  }

  private var summary: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          if isPinned {
            Image(systemName: "pin.fill")
              .font(.caption)
              .accessibilityLabel("Pinned")
              .help("Pinned to the top of Active")
          }
          Text(title)
            .font(isSettled ? .callout : .body)
            .lineLimit(1)
            .truncationMode(.middle)
          if isWoke {
            Text("Woke")
              .font(.caption2)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.tint.opacity(0.2), in: .capsule)
              .help("This task came back from a snooze and you haven't opened it since")
          }
        }
        HStack(spacing: 4) {
          if let secondary {
            Text(secondary)
              .font(.caption)
              .monospaced()
              .lineLimit(1)
              .truncationMode(.middle)
          }
          if isLowConfidenceSeed {
            Image(systemName: "questionmark.circle")
              .font(.caption)
              .accessibilityLabel("Unknown details")
              .help("Seeded from weak evidence — details here may be incomplete")
          }
        }
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if let settledTimestamp {
        Text(settledTimestamp, format: .relative(presentation: .named))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help("When this task wrapped up")
      }
      if let wakeAt {
        Text(wakeAt, format: .relative(presentation: .named))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help("When this task comes back on its own")
      }
      if hasUnseenNotifications {
        Image(systemName: "bell.badge.fill")
          .font(.caption)
          .foregroundStyle(.tint)
          .accessibilityLabel("Unread terminal notification")
          .help("A terminal on this task posted a notification you haven't seen")
      }
      if let systemImage = activity.systemImage {
        Image(systemName: systemImage)
          .font(.caption)
          .foregroundStyle(activity.style)
          .accessibilityLabel(activity.help)
          .help(activity.help)
      }
    }
    .foregroundStyle(isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    .accessibilityElement(children: .combine)
  }

  /// One agent reporting on the task's surfaces: the state glyph the Agents tab
  /// uses, and the name the user addresses it by. Indented under the task and
  /// deliberately not clickable on its own — the row it sits in already opens
  /// the task's surfaces, which is where a child drills in to (A22).
  private struct TaskChildAgentRowView: View {
    let child: TaskLeafState.ChildAgent

    var body: some View {
      HStack(spacing: 4) {
        Image(systemName: child.state.systemImage)
          .foregroundStyle(AgentDashboardStateStyle.style(for: child.state, hasError: false))
          .accessibilityLabel(child.state.title)
        Text(child.displayName)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .padding(.leading, 14)
      .help("\(child.displayName) on this task — \(child.state.help)")
      .accessibilityElement(children: .combine)
    }
  }

  /// Directory leaf, plus the branch when there is one. An empty string means
  /// there is nothing honest to show.
  private var secondary: String? {
    let parts = [directoryName, branch].compactMap { $0 }.filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " · ")
  }
}
