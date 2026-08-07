import ComposableArchitecture
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

    return List(selection: selectionBinding(current: selectedTaskID)) {
      if structure.visibleTaskIDs.isEmpty, structure.settledTotalCount == 0 {
        emptyRow
      }

      if !structure.activeTaskIDs.isEmpty {
        Section {
          ForEach(structure.activeTaskIDs, id: \.self) { taskID in
            TaskSidebarRowView(store: store, taskID: taskID, settledTimestamp: nil, isSettled: false)
          }
        } header: {
          Text("Active (\(structure.activeTaskIDs.count))")
            .help("\(structure.activeTaskIDs.count) task(s) still in flight, newest first")
        }
      }

      if structure.settledTotalCount > 0 {
        Section {
          ForEach(structure.visibleSettledTail) { entry in
            TaskSidebarRowView(
              store: store,
              taskID: entry.id,
              settledTimestamp: entry.settledTimestamp,
              isSettled: true
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
        isLowConfidenceSeed: record?.seedEvidence?.confidence == .low,
        hasUnseenNotifications: leaf?.hasUnseenNotifications == true,
        activity: TaskRowActivity(leaf: leaf),
        settledTimestamp: settledTimestamp,
        isSettled: isSettled
      )
    }
    .buttonStyle(.plain)
    .tag(SidebarSelection.task(taskID))
    .help(Self.help(title: record?.title, isSettled: isSettled))
    .contextMenu {
      if isSettled {
        Button("Unsettle") { store.send(.tasks(.unsettle(taskID))) }
          .help("Move this task back to Active. Its sessions stay as they are until you open it.")
      } else {
        Button("Settle") { store.send(.tasks(.settle(taskID))) }
          .help(
            "Mark this task wrapped up and move it to the settled tail. "
              + "Its sessions hibernate when nothing else is using the directory; scrollback is kept."
          )
      }
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
  let settledTimestamp: Date?
  let isSettled: Bool

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(isSettled ? .callout : .body)
          .lineLimit(1)
          .truncationMode(.middle)
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
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  /// Directory leaf, plus the branch when there is one. An empty string means
  /// there is nothing honest to show.
  private var secondary: String? {
    let parts = [directoryName, branch].compactMap { $0 }.filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " · ")
  }
}
