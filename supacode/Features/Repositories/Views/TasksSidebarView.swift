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
  /// Read here only to *notice* a change: the reducer re-reads app storage when
  /// it recomputes, so these are change detectors, not the source of truth.
  @Shared(.taskAutoSettleEnabled) private var isAutoSettleEnabled
  @Shared(.taskAutoSettleOnFinishedPullRequest) private var settlesOnFinishedPullRequest
  @Shared(.taskInactivityWindowDays) private var inactivityWindowDays

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
              isWoke: structure.wokeTaskIDs.contains(taskID),
              isSnoozed: structure.snoozedTaskIDs.contains(taskID)
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
              isSnoozed: true,
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
              isWoke: false,
              isSnoozed: structure.snoozedTaskIDs.contains(entry.id)
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
    // Mirrors `SidebarListView`'s grouping-toggle dispatch: the settle policy
    // lives in app storage, so flipping it in the settings window has to tell
    // this reducer to re-partition. Waiting for the 60s classification tick
    // would leave the list disagreeing with the switch the user just flipped
    // (A30).
    .onChange(of: isAutoSettleEnabled, initial: false) { _, _ in
      store.send(.tasks(.autoSettleSettingsChanged))
    }
    .onChange(of: settlesOnFinishedPullRequest, initial: false) { _, _ in
      store.send(.tasks(.autoSettleSettingsChanged))
    }
    .onChange(of: inactivityWindowDays, initial: false) { _, _ in
      store.send(.tasks(.autoSettleSettingsChanged))
    }
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
  /// The user's "not now" is still standing. NOT the same as rendering on the
  /// shelf: a raised hand (A25) puts a still-snoozed row back in Active, and
  /// that row needs Wake Now, not a Snooze menu it is already inside of.
  let isSnoozed: Bool
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
        status: leaf?.status ?? .ready,
        isDormant: leaf?.allSurfacesDormant == true,
        // A28: the row fades only when the leaf says nothing is owed. The two
        // statuses parked on a person can never reach this as `true`, which is
        // the whole reason the predicate lives in `TaskAttention` rather than
        // being re-spelled here.
        isReceded: leaf?.isReceded ?? false,
        isDoneUnread: leaf?.isDoneUnread == true,
        workingSince: leaf?.workingSince,
        pullRequest: leaf?.pullRequest ?? .none,
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
      snoozeMenuItems(canSnooze: leaf?.canSnooze ?? true, isSnoozed: isSnoozed)
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

  /// Presets are resolved when the menu content builds, never precomputed (A23):
  /// one whose instant has already passed is omitted rather than silently rolled
  /// to tomorrow, which would make a single menu item mean two things.
  ///
  /// `store.taskNow` rather than `Date()`: A18 keeps the clock injected so tests
  /// can drive it, and a view reaching for the ambient clock reintroduces
  /// exactly the seam the reducer's sample exists to close. `taskNow` re-stamps
  /// on every task arm and on the 60s classification tick, so a preset can be at
  /// most a minute stale — which never changes which presets are *offered*,
  /// since none of the boundaries are minute-grained.
  @ViewBuilder
  private func snoozeMenuItems(canSnooze: Bool, isSnoozed: Bool) -> some View {
    if isSnoozed {
      Button("Wake Now") { store.send(.tasks(.unsnooze(taskID))) }
        .help("Bring this task back to Active right now, ahead of its wake time.")
    }
    Menu("Snooze") {
      ForEach(
        TaskSnooze.resolveSnoozePresets(now: store.taskNow, calendar: .autoupdatingCurrent),
        id: \.preset
      ) { preset in
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

/// How the row draws the one status it reports (A27).
///
/// A presentation extension on the model rather than a parallel enum: a second
/// vocabulary would eventually gain a sixth case the classification rules do
/// not have, and "exactly one status per task" would stop being true of what
/// the user actually sees.
extension TaskStatusModel.Status {
  /// `nil` for `ready`, which is the absence of news and draws nothing.
  fileprivate var systemImage: String? {
    switch self {
    case .approval: "hand.raised.fill"
    case .input: "questionmark.bubble.fill"
    case .working: "circle.fill"
    case .failed: "exclamationmark.circle.fill"
    case .ready: nil
    }
  }

  fileprivate var style: AnyShapeStyle {
    switch self {
    case .approval, .input: AnyShapeStyle(.orange)
    case .working: AnyShapeStyle(.tint)
    case .failed: AnyShapeStyle(.red)
    case .ready: AnyShapeStyle(.secondary)
    }
  }

  fileprivate var help: String {
    switch self {
    case .approval: "An agent on this task is waiting for you to approve something"
    case .input: "An agent on this task is waiting on you"
    case .working: "An agent is working on this task"
    case .failed: "An agent on this task reported an error"
    case .ready: "No agent activity reported"
    }
  }
}

/// How the row draws what it knows about the pull request (A29).
///
/// Only the three *known* states draw: `loading` and `failed` are readings of
/// our own pipeline, and a glyph for "we have not asked yet" is a glyph that
/// says nothing while looking like it says something.
extension TaskPullRequestState {
  fileprivate var systemImage: String? {
    switch self {
    case .open: "arrow.triangle.pull"
    case .merged: "arrow.triangle.merge"
    case .closed: "xmark.circle"
    case .none, .loading, .failed, .unknown: nil
    }
  }

  fileprivate var style: AnyShapeStyle {
    switch self {
    case .open: AnyShapeStyle(.green)
    case .merged: AnyShapeStyle(.purple)
    default: AnyShapeStyle(.secondary)
    }
  }

  fileprivate var help: String {
    switch self {
    case .open: "This task has an open pull request"
    case .merged: "This task's pull request was merged"
    case .closed: "This task's pull request was closed without merging"
    case .none, .loading, .failed, .unknown: ""
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
  /// The one status this task reports (A27).
  let status: TaskStatusModel.Status
  /// Every owned session is hibernated. Orthogonal to `status`: a sleeping task
  /// is still `ready`, it just has nothing awake to be ready with.
  let isDormant: Bool
  /// Nothing on this row is owed a person, so it may fade (A28). Resolved by
  /// the leaf, never re-derived here — the row's contrast and the keyboard's
  /// jump target have to agree, and two spellings eventually would not.
  let isReceded: Bool
  /// A turn finished after the user's last visit. The Done pill's whole signal.
  let isDoneUnread: Bool
  /// When the current turn started, for the elapsed timer. `nil` renders no
  /// timer at all rather than a fabricated 0s (Resolved #5).
  let workingSince: Date?
  let pullRequest: TaskPullRequestState
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
            // A28's soft half: a quiet row steps back in weight as well as in
            // contrast, so the rows that still want something read as the
            // foreground of the list rather than as merely un-dimmed.
            .fontWeight(isReceded ? .light : .regular)
            .lineLimit(1)
            .truncationMode(.middle)
          if isDoneUnread {
            Text("Done")
              .font(.caption2)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.green.opacity(0.2), in: .capsule)
              .help("An agent finished a turn on this task while you weren't looking")
          }
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
        Self.wakeCountdown(wakeAt)
      }
      if let workingSince {
        Self.workingElapsed(workingSince)
      }
      if hasUnseenNotifications {
        Image(systemName: "bell.badge.fill")
          .font(.caption)
          .foregroundStyle(.tint)
          .accessibilityLabel("Unread terminal notification")
          .help("A terminal on this task posted a notification you haven't seen")
      }
      if let systemImage = pullRequest.systemImage {
        Image(systemName: systemImage)
          .font(.caption)
          .foregroundStyle(pullRequest.style)
          .accessibilityLabel(pullRequest.help)
          .help(pullRequest.help)
      }
      if isDormant {
        Image(systemName: "moon.zzz")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Hibernated")
          .help("Every session for this task is hibernated")
      }
      if let systemImage = status.systemImage {
        Image(systemName: systemImage)
          .font(.caption)
          .foregroundStyle(status.style)
          .accessibilityLabel(status.help)
          .help(status.help)
      }
    }
    .foregroundStyle(isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    // A28: the fade is a *sibling* of the settled treatment, not a replacement
    // — a settled row is history and a receded one is merely quiet, and a row
    // that is both should read as further back than either alone.
    .opacity(isReceded ? 0.7 : 1)
    .accessibilityElement(children: .combine)
  }

  /// A countdown that actually counts down. A bare relative `Text` renders once
  /// and then lies until something else invalidates the row — and nothing does:
  /// the classification tick re-stamps `taskNow`, but the structure it rebuilds
  /// is Equatable-diffed, so a minute passing without a placement change
  /// publishes nothing.
  ///
  /// `TimelineView` is the cheap fix precisely because it is scoped here: only
  /// rows that are actually parked carry a schedule, and the redraw is one
  /// `Text`, not the row, the section, or the List.
  private static func wakeCountdown(_ wakeAt: Date) -> some View {
    TimelineView(.periodic(from: .now, by: 60)) { _ in
      Text(wakeAt, format: .relative(presentation: .named))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("When this task comes back on its own")
    }
  }

  /// How long the current turn has been running, counted from the hook's own
  /// start instant (Resolved #5).
  ///
  /// Leaf-local `TimelineView`, for exactly the reason the wake countdown is
  /// one: only rows that are actually working carry a schedule, and the redraw
  /// is one `Text` — not the row, the section, or the List. Anchored on
  /// `workingSince` rather than on a duration, so the count survives every
  /// redraw between ticks.
  private static func workingElapsed(_ workingSince: Date) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      Text(workingSince, format: .relative(presentation: .numeric))
        .font(.caption)
        .monospaced()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("How long this task's current turn has been running")
    }
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
