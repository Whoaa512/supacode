import Foundation
import IdentifiedCollections
import Sharing

struct SessionsSidebarStructure: Equatable, Sendable {
  struct Section: Equatable, Identifiable, Sendable {
    var id: SessionClassification.Lifecycle
    var rowIDs: [SessionRowID]

    var title: String { id == .active ? "Active" : "Settled" }
  }

  var sections: [Section] = []
  var liveIDs: [SessionRowID] = []
  var allIDs: [SessionRowID] { sections.flatMap(\.rowIDs) }

  func selection(
    byOffset offset: Int, from current: SessionRowID?, includingSettled: Bool = true
  ) -> SessionRowID? {
    let ids = includingSettled ? allIDs : sections.filter { $0.id == .active }.flatMap(\.rowIDs)
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else {
      return offset > 0 ? ids.first : ids.last
    }
    return ids[(index + offset + ids.count) % ids.count]
  }

  func nextNeedingAttention(
    from current: SessionRowID?, items: IdentifiedArrayOf<SessionSidebarItemFeature.State>
  ) -> SessionRowID? {
    guard !liveIDs.isEmpty else { return nil }
    let startIndex = current.flatMap { liveIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    for offset in liveIDs.indices {
      let id = liveIDs[(startIndex + offset) % liveIDs.count]
      guard let item = items[id: id], item.allowsAttentionNavigation, let status = item.status
      else { continue }
      if status == .needsYou || status == .doneUnseen { return id }
    }
    return nil
  }
}

extension RepositoriesFeature.State {
  /// The selected task, while the selection still sits on its directory: a
  /// directory that was removed or deselected takes its task with it.
  var selectedTaskID: LayoutID? {
    guard let selectedTask else { return nil }
    if selectedTask.directoryID == selection?.worktreeID { return selectedTask.id }
    return orphanTaskID
  }

  /// The selected task when its directory is no roster worktree, so nothing
  /// is selected beside it. Any other selection, or a plain deselect, ends it.
  var orphanTaskID: LayoutID? {
    guard let selectedTask, selection == nil, worktree(for: selectedTask.directoryID) == nil else { return nil }
    return selectedTask.id
  }

  var isSessionsSidebarTabActive: Bool {
    let sidebarTabRawValue = SharedReader(.sidebarTab).wrappedValue
    return SidebarTab(rawValue: sidebarTabRawValue) == .sessions
  }

  func sessionRowID(atSlot index: Int) -> SessionRowID? {
    let live = sessionsSidebarStructure.liveIDs
    guard live.indices.contains(index) else { return nil }
    return live[index]
  }

  func sessionRowID(byOffset offset: Int, focusedRowID: SessionRowID?) -> SessionRowID? {
    let live = sessionsSidebarStructure.liveIDs
    guard !live.isEmpty else { return nil }
    let current = focusedRowID ?? sessionSelection
    guard let current, let index = live.firstIndex(of: current) else {
      return live[offset > 0 ? 0 : live.count - 1]
    }
    return live[(index + offset + live.count) % live.count]
  }

  mutating func recomputeSessionsSidebarStructureIfChanged() {
    // Plain tuples: sorting the observable rows directly pays an observation
    // access per comparison, which dominates at a few thousand rows.
    let ordered = sessionItems.map { (id: $0.id, createdAt: $0.createdAt, lifecycle: $0.lifecycle, isLive: $0.isLive) }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
        return $0.id.sortKey < $1.id.sortKey
      }
    var sections: [SessionsSidebarStructure.Section] = []
    var liveIDs: [SessionRowID] = []
    for lifecycle in [SessionClassification.Lifecycle.active, .settled] {
      let rows = ordered.filter { $0.lifecycle == lifecycle }
      guard !rows.isEmpty else { continue }
      sections.append(SessionsSidebarStructure.Section(id: lifecycle, rowIDs: rows.map(\.id)))
      liveIDs.append(contentsOf: rows.filter(\.isLive).map(\.id))
    }
    let structure = SessionsSidebarStructure(sections: sections, liveIDs: liveIDs)
    if sessionsSidebarStructure != structure { sessionsSidebarStructure = structure }
  }

  /// `droppingUnindexedEnded` is set once a scan has finished: a session that
  /// ended and still has no file on disk never had a turn and cannot be
  /// resumed, so its placeholder row goes away instead of lingering.
  mutating func reconcileSessionItems(now: Date, droppingUnindexedEnded: Bool = false) {
    // One sidecar read and one branch lookup per directory: this runs on the
    // main thread for every agent status flip, over the whole index.
    let sidecar = sessions
    var currentBranchByCwd: [String: String?] = [:]
    func branchAnnotation(for key: SessionKey, cwd: String) -> String? {
      guard let lastBranch = sidecar[key]?.branches.last, !lastBranch.isEmpty else { return nil }
      let current: String?
      if let cached = currentBranchByCwd[cwd] {
        current = cached
      } else {
        current = currentBranch(forSessionCwd: cwd)
        currentBranchByCwd[cwd] = current
      }
      return current == lastBranch ? nil : lastBranch
    }
    func lifecycle(for key: SessionKey) -> SessionClassification.Lifecycle {
      sidecar[key]?.settledAt == nil ? .active : .settled
    }

    var drafts: [SessionRowDraft] = []
    var indexByID: [SessionRowID: Int] = [:]
    drafts.reserveCapacity(sessionSummaries.count + sessionSnapshots.count + taskSnapshots.count)
    func append(_ draft: SessionRowDraft) {
      indexByID[draft.id] = drafts.count
      drafts.append(draft)
    }
    for summary in sessionSummaries where indexByID[.session(summary.id)] == nil {
      append(
        SessionRowDraft(
          id: .session(summary.id), title: summary.title, cwd: summary.cwd, createdAt: summary.createdAt,
          lifecycle: lifecycle(for: summary.id),
          branchAnnotation: branchAnnotation(for: summary.id, cwd: summary.cwd)))
    }
    // A session that ended before the index caught up keeps its row.
    for row in sessionItems where row.isSynthetic && !droppingUnindexedEnded {
      guard case .session = row.id, indexByID[row.id] == nil else { continue }
      append(
        SessionRowDraft(
          id: row.id, title: row.title, cwd: row.cwd, createdAt: row.createdAt, lifecycle: row.lifecycle,
          branchAnnotation: row.branchAnnotation, isSynthetic: true))
    }
    for snapshot in sessionSnapshots.sorted(by: {
      $0.location.surfaceID.uuidString < $1.location.surfaceID.uuidString
    }) {
      let id = snapshot.id
      let provisionalID = SessionRowID.provisional(snapshot.harness, snapshot.location.surfaceID)
      if indexByID[id] == nil {
        append(
          SessionRowDraft(
            id: id, title: "New session", cwd: snapshot.cwd,
            createdAt: sessionItems[id: id]?.createdAt ?? sessionItems[id: provisionalID]?.createdAt ?? now,
            isSynthetic: true))
      }
      guard let index = indexByID[id] else { continue }
      if case .session(let key) = id {
        drafts[index].lifecycle = lifecycle(for: key)
        drafts[index].branchAnnotation = branchAnnotation(for: key, cwd: snapshot.cwd)
      }
      drafts[index].status = snapshot.status
      drafts[index].allowsAttentionNavigation = snapshot.allowsAttentionNavigation
      if drafts[index].location == nil || snapshot.location == sessionItems[id: id]?.location {
        drafts[index].location = snapshot.location
      }
      if sessionSelection == provisionalID, id != provisionalID { sessionSelection = id }
    }
    // A task gets its own row only when no session row leads to it.
    let reached = Set(drafts.compactMap(\.location?.layoutID))
    for task in taskSnapshots where indexByID[task.id] == nil && !reached.contains(task.location.layoutID) {
      append(
        SessionRowDraft(
          id: task.id, title: task.title, cwd: task.cwd,
          createdAt: task.createdAt ?? sessionItems[id: task.id]?.createdAt ?? now, location: task.location))
    }

    if sessionItems.count != drafts.count || sessionItems.contains(where: { indexByID[$0.id] == nil }) {
      sessionItems.removeAll { indexByID[$0.id] == nil }
    }
    // Reads only: every write through `sessionItems` costs a pass over the
    // whole collection, so unchanged rows must not be touched.
    for draft in drafts {
      guard let existing = sessionItems[id: draft.id] else {
        sessionItems.append(SessionSidebarItemFeature.State(draft))
        continue
      }
      if !existing.matches(draft) { sessionItems[id: draft.id]?.apply(draft) }
    }
    if let selection = sessionSelection, sessionItems[id: selection] == nil {
      sessionSelection = nil
    }
  }

  private func currentBranch(forSessionCwd cwd: String) -> String? {
    let url = URL(fileURLWithPath: cwd).standardizedFileURL
    for repository in repositories {
      for worktree in repository.worktrees where worktree.workingDirectory.standardizedFileURL == url {
        let branch = sidebarItems[id: worktree.id]?.branchName
        return branch?.isEmpty == false ? branch : nil
      }
    }
    return nil
  }

  mutating func applySettle(key: SessionKey, now: Date) {
    $sessions.withLock { sidecar in
      var entry = sidecar[key] ?? SessionSidecarEntry()
      entry.settledAt = now
      entry.manualUnsettledAtActivity = nil
      sidecar[key] = entry
    }
  }

  mutating func autoSettleSessions(now: Date, idleDays: Int) {
    guard sessionsRestorationFinished, sessionsRefreshSucceeded, !sessionsHasUnresolvedLivePresence
    else { return }
    // A provisional agent may be any session in its task directory or in the
    // directory its tab was recorded running in, so it only blocks auto-settle
    // in those, not globally.
    var liveKeys = sessionsLiveKeys
    var provisionalCwds: Set<String> = []
    var standardizedByCwd: [String: String] = [:]
    func standardized(_ cwd: String) -> String {
      if let cached = standardizedByCwd[cwd] { return cached }
      let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
      standardizedByCwd[cwd] = path
      return path
    }
    for snapshot in sessionSnapshots {
      switch snapshot.id {
      case .session(let key): liveKeys.insert(key)
      case .task: break
      case .provisional:
        provisionalCwds.insert(standardized(snapshot.cwd))
        if let surfaceCwd = snapshot.surfaceCwd { provisionalCwds.insert(standardized(surfaceCwd)) }
      }
    }
    let sidecar = sessions
    let tasks = TaskIdleness(
      taskSessions: taskSessions, snapshots: sessionSnapshots, openTasks: Set(taskSnapshots.map(\.location.layoutID)),
      summaries: sessionSummaries, sidecar: sidecar)
    var releasedHolds: [SessionKey] = []
    var settled: [SessionKey] = []
    for summary in sessionSummaries where summary.isVerified {
      var entry = sidecar[summary.id]
      if let hold = entry?.manualUnsettledAtActivity, summary.lastActivity > hold {
        entry?.manualUnsettledAtActivity = nil
        releasedHolds.append(summary.id)
      }
      guard entry?.settledAt == nil, !provisionalCwds.contains(standardized(summary.cwd)),
        let judged = tasks.judged(summary, liveKeys: liveKeys),
        SessionClassification.classify(
          summary: judged, isLive: false, sidecar: entry, now: now, idleDays: idleDays
        ).lifecycle == .settled
      else { continue }
      settled.append(summary.id)
    }
    guard !releasedHolds.isEmpty || !settled.isEmpty else { return }
    $sessions.withLock { sidecar in
      for key in releasedHolds { sidecar[key]?.manualUnsettledAtActivity = nil }
      for key in settled {
        var entry = sidecar[key] ?? SessionSidecarEntry()
        entry.settledAt = now
        entry.manualUnsettledAtActivity = nil
        sidecar[key] = entry
      }
    }
    guard !settled.isEmpty else { return }
    reconcileSessionItems(now: now)
    recomputeSessionsSidebarStructureIfChanged()
  }

  /// A task is judged as a whole, so its sessions get one answer: none
  /// settles while the task has a tab open (a shell, or an agent's tab after
  /// the agent ended: auto-settle closes nothing, and a settled task shows no
  /// tab), while any agent runs in it or while the user's unsettle still
  /// holds one of them, it has been idle only as long as its most recently
  /// active session, and it is as long as all of them together. That needs
  /// every one of them read: a session this refresh could not read, or lists
  /// nothing for, may be the newest, so it holds the task like a running one.
  private struct TaskIdleness {
    let taskSessions: [LayoutID: [SessionKey]]
    let runningTasks: Set<LayoutID>
    let openTasks: Set<LayoutID>
    var tasksBySession: [SessionKey: [LayoutID]] = [:]
    var activityByKey: [SessionKey: Date] = [:]
    var messagesByKey: [SessionKey: Int] = [:]
    var held: Set<SessionKey> = []
    var read: Set<SessionKey> = []

    init(
      taskSessions: [LayoutID: [SessionKey]], snapshots: [SessionLiveSnapshot], openTasks: Set<LayoutID>,
      summaries: [SessionSummary], sidecar: SessionSidecar
    ) {
      self.taskSessions = taskSessions
      self.openTasks = openTasks
      runningTasks = Set(snapshots.map(\.location.layoutID))
      for (layoutID, members) in taskSessions {
        for key in members { tasksBySession[key, default: []].append(layoutID) }
      }
      // Only a task with several sessions has another member to read.
      guard taskSessions.values.contains(where: { $0.count > 1 }) else { return }
      var unread: Set<SessionKey> = []
      for summary in summaries {
        if summary.isVerified { read.insert(summary.id) } else { unread.insert(summary.id) }
        activityByKey[summary.id] = max(summary.lastActivity, activityByKey[summary.id] ?? .distantPast)
        messagesByKey[summary.id] = max(summary.messageCount, messagesByKey[summary.id] ?? 0)
        guard let hold = sidecar[summary.id]?.manualUnsettledAtActivity, summary.lastActivity <= hold else { continue }
        held.insert(summary.id)
      }
      read.subtract(unread)
    }

    /// The session as its tasks stand: their newest activity and all their
    /// messages. `nil` while the session, or anything in a task that lists
    /// it, is open, running, held or unread, which no idle time settles.
    func judged(_ summary: SessionSummary, liveKeys: Set<SessionKey>) -> SessionSummary? {
      if liveKeys.contains(summary.id) { return nil }
      var judged = summary
      for layoutID in tasksBySession[summary.id] ?? [] {
        let members = taskSessions[layoutID] ?? []
        if openTasks.contains(layoutID) || runningTasks.contains(layoutID)
          || members.contains(where: { liveKeys.contains($0) || held.contains($0) })
        {
          return nil
        }
        if members.count > 1, !members.allSatisfy(read.contains) { return nil }
        var messages = 0
        for member in members {
          messages += messagesByKey[member] ?? 0
          guard let activity = activityByKey[member], activity > judged.lastActivity else { continue }
          judged.lastActivity = activity
        }
        judged.messageCount = max(judged.messageCount, messages)
      }
      return judged
    }
  }

  mutating func applyUnsettle(key: SessionKey, summaries: [SessionSummary], now: Date) {
    let watermark = summaries.first(where: { $0.id == key })?.lastActivity ?? now
    $sessions.withLock { sidecar in
      var entry = sidecar[key] ?? SessionSidecarEntry()
      entry.settledAt = nil
      entry.manualUnsettledAtActivity = watermark
      sidecar[key] = entry
    }
    reconcileSessionItems(now: now)
    recomputeSessionsSidebarStructureIfChanged()
  }
}
