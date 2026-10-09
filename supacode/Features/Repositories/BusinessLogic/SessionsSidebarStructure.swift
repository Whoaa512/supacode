import Foundation
import IdentifiedCollections
import Sharing

struct SessionsSidebarStructure: Equatable, Sendable {
  struct Section: Equatable, Identifiable, Sendable {
    var id: SessionClassification.Lifecycle
    var rowIDs: [SessionRowID]

    var title: String { id == .active ? "Active" : "Settled" }
  }

  /// One agent of the selected task. A member with no surface is dormant:
  /// a closed tangent, or a session another replaced.
  struct SubRow: Equatable, Identifiable, Sendable {
    var id: TaskMember
    var title: String
    var status: SessionClassification.Status?
    var location: SessionLocation?

    var isDormant: Bool { location == nil }
  }

  var sections: [Section] = []
  var liveIDs: [SessionRowID] = []
  /// The selected task and its members, primary first. Empty for any other
  /// selection and for a task of one agent, whose row already is that agent.
  var subRowsTaskID: LayoutID?
  var subRows: [SubRow] = []
  var allIDs: [SessionRowID] { sections.flatMap(\.rowIDs) }

  /// Where jump-to-attention lands: the row to highlight and the agent's own surface.
  struct AttentionTarget: Equatable, Sendable {
    var rowID: SessionRowID
    var location: SessionLocation
  }

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

  /// Moves the row selection. The sub-rows are the selected task's, so they follow it.
  mutating func selectSessionRow(_ id: SessionRowID?) {
    if sessionSelection != id { sessionSelection = id }
    let subRows = selectedTaskSubRows()
    guard sessionsSidebarStructure.subRowsTaskID != subRows.taskID || sessionsSidebarStructure.subRows != subRows.rows
    else { return }
    sessionsSidebarStructure.subRowsTaskID = subRows.taskID
    sessionsSidebarStructure.subRows = subRows.rows
  }

  /// The session's surface, when an agent runs it: its own row's, or the
  /// surface of the task it is grouped under.
  func sessionLocation(for key: SessionKey) -> SessionLocation? {
    if let row = sessionItems[id: .implicit(key)] { return row.location }
    return sessionSnapshots.first { $0.sessionKey == key }?.location
  }

  /// Where the session ran: the directory it resumes in.
  func sessionCwd(for key: SessionKey) -> String? {
    if let row = sessionItems[id: .implicit(key)] { return row.cwd }
    return sessionSummaries.first { $0.id == key }?.cwd ?? sessionSnapshots.first { $0.sessionKey == key }?.cwd
  }

  /// A task's agents in member order: the sessions it lists, then any agent
  /// on one of its surfaces the list has not caught up with.
  private func members(of layoutID: LayoutID, agents: [SessionLiveSnapshot]) -> [TaskMember] {
    var members = (taskSessions[layoutID] ?? []).map(TaskMember.session)
    // A set beside the list: a scan per agent is quadratic in a large task.
    var listed = Set(members)
    for agent in agents where listed.insert(agent.member).inserted { members.append(agent.member) }
    return members
  }

  /// The next agent waiting on the user, walking the live rows in order and
  /// a task's agents in member order, from the focused agent and round again.
  /// Worked out per press from the agents themselves: a task row only shows
  /// its most urgent agent, which can mask a tangent that needs attention.
  func nextAttentionTarget(
    after current: SessionRowID?, focusedSurfaceID: UUID?
  ) -> SessionsSidebarStructure.AttentionTarget? {
    typealias Target = SessionsSidebarStructure.AttentionTarget
    var agentsByTask: [LayoutID: [SessionLiveSnapshot]] = [:]
    for agent in sessionSnapshots { agentsByTask[agent.location.layoutID, default: []].append(agent) }

    // A stop is at (row, agent within the row).
    var stops: [(at: (Int, Int), target: Target)] = []
    var cursor: (Int, Int)?
    for (rowIndex, id) in sessionsSidebarStructure.liveIDs.enumerated() {
      guard case .task(let layoutID) = id else {
        if id == current { cursor = (rowIndex, 0) }
        guard let item = sessionItems[id: id], let location = item.location,
          Self.wantsAttention(item.status, jumpable: item.allowsAttentionNavigation)
        else { continue }
        stops.append(((rowIndex, 0), Target(rowID: id, location: location)))
        continue
      }
      let agents = agentsInMemberOrder(of: layoutID, agents: agentsByTask[layoutID] ?? [])
      if id == current {
        // Two harnesses on one surface are one stop; a shell tab sits before every agent.
        let focused = focusedSurfaceID.flatMap { surfaceID in
          agents.lastIndex { $0.location.surfaceID == surfaceID }
        }
        cursor = (rowIndex, focused ?? -1)
      }
      for (agentIndex, agent) in agents.enumerated()
      where Self.wantsAttention(agent.status, jumpable: agent.allowsAttentionNavigation) {
        stops.append(((rowIndex, agentIndex), Target(rowID: id, location: agent.location)))
      }
    }
    guard let cursor else { return stops.first?.target }
    return (stops.first { $0.at > cursor } ?? stops.first)?.target
  }

  private static func wantsAttention(_ status: SessionClassification.Status?, jumpable: Bool) -> Bool {
    jumpable && (status == .needsYou || status == .doneUnseen)
  }

  private func agentsInMemberOrder(of layoutID: LayoutID, agents: [SessionLiveSnapshot]) -> [SessionLiveSnapshot] {
    guard agents.count > 1 else { return agents }
    var rank: [TaskMember: Int] = [:]
    for (index, member) in members(of: layoutID, agents: agents).enumerated() where rank[member] == nil {
      rank[member] = index
    }
    // Agents sharing a member keep their snapshot order.
    return agents.enumerated().sorted {
      (rank[$0.element.member] ?? .max, $0.offset) < (rank[$1.element.member] ?? .max, $1.offset)
    }.map(\.element)
  }

  private func selectedTaskSubRows() -> (taskID: LayoutID?, rows: [SessionsSidebarStructure.SubRow]) {
    guard case .task(let layoutID) = sessionSelection else { return (nil, []) }
    let agents = sessionSnapshots.filter { $0.location.layoutID == layoutID }
    let members = members(of: layoutID, agents: agents)
    guard members.count > 1 else { return (nil, []) }
    // Lookups built once: this runs over the whole index on every status flip.
    let keys = Set(members.compactMap(\.sessionKey))
    var titles: [SessionKey: String] = [:]
    for summary in sessionSummaries where keys.contains(summary.id) && titles[summary.id] == nil {
      titles[summary.id] = summary.title
    }
    var agentByMember: [TaskMember: SessionLiveSnapshot] = [:]
    for agent in agents where agentByMember[agent.member] == nil { agentByMember[agent.member] = agent }
    let rows = members.compactMap { member -> SessionsSidebarStructure.SubRow? in
      let agent = agentByMember[member]
      let title = member.sessionKey.flatMap { titles[$0] }
      // One that is neither running nor on disk cannot be shown or resumed.
      guard agent != nil || title != nil else { return nil }
      return SessionsSidebarStructure.SubRow(
        id: member, title: title ?? "New session", status: agent?.status, location: agent?.location)
    }
    return rows.count > 1 ? (layoutID, rows) : (nil, [])
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
    let subRows = selectedTaskSubRows()
    let structure = SessionsSidebarStructure(
      sections: sections, liveIDs: liveIDs, subRowsTaskID: subRows.taskID, subRows: subRows.rows)
    if sessionsSidebarStructure != structure { sessionsSidebarStructure = structure }
  }

  /// What a task row is built from: its tabs, the agents on them and the
  /// indexed sessions it lists.
  private struct TaskGroup {
    var sessions: [SessionKey] = []
    var tabs: TaskLiveSnapshot?
    var agents: [SessionLiveSnapshot] = []
    var indexed: [SessionKey: SessionSummary] = [:]
  }

  /// Which task a session belongs to, built once per pass: the tasks that
  /// list it, and the known task whose surface it runs on. An agent on a
  /// surface no known task holds keeps a row of its own.
  private struct SessionGroups {
    var tasks: [LayoutID: TaskGroup] = [:]
    var tasksBySession: [SessionKey: [LayoutID]] = [:]
    var ungrouped: [SessionLiveSnapshot] = []
    /// The task each grouped agent's own row id was folded into.
    var taskByAgentRow: [SessionRowID: LayoutID] = [:]

    init(taskSessions: [LayoutID: [SessionKey]], tabs: [TaskLiveSnapshot], agents: [SessionLiveSnapshot]) {
      for (layoutID, keys) in taskSessions {
        tasks[layoutID, default: TaskGroup()].sessions = keys
        for key in keys { tasksBySession[key, default: []].append(layoutID) }
      }
      for task in tabs where tasks[task.location.layoutID]?.tabs == nil {
        tasks[task.location.layoutID, default: TaskGroup()].tabs = task
      }
      for agent in agents.sorted(by: { $0.location.surfaceID.uuidString < $1.location.surfaceID.uuidString }) {
        let layoutID = agent.location.layoutID
        guard tasks[layoutID] != nil else {
          ungrouped.append(agent)
          continue
        }
        tasks[layoutID]?.agents.append(agent)
        if taskByAgentRow[agent.id] == nil { taskByAgentRow[agent.id] = layoutID }
        guard let key = agent.sessionKey, tasksBySession[key]?.contains(layoutID) != true else { continue }
        tasksBySession[key, default: []].append(layoutID)
      }
    }
  }

  private struct RowDrafts {
    var drafts: [SessionRowDraft] = []
    var indexByID: [SessionRowID: Int] = [:]

    mutating func append(_ draft: SessionRowDraft) {
      indexByID[draft.id] = drafts.count
      drafts.append(draft)
    }
  }

  /// One sidecar read and one branch lookup per directory: a pass runs on
  /// the main thread for every agent status flip, over the whole index.
  private struct SidecarFacts {
    let sidecar: SessionSidecar
    var currentBranchByCwd: [String: String?] = [:]

    func lifecycle(for key: SessionKey) -> SessionClassification.Lifecycle {
      sidecar[key]?.settledAt == nil ? .active : .settled
    }
  }

  private func branchAnnotation(for key: SessionKey, cwd: String, facts: inout SidecarFacts) -> String? {
    guard let lastBranch = facts.sidecar[key]?.branches.last, !lastBranch.isEmpty else { return nil }
    let current: String?
    if let cached = facts.currentBranchByCwd[cwd] {
      current = cached
    } else {
      current = currentBranch(forSessionCwd: cwd)
      facts.currentBranchByCwd[cwd] = current
    }
    return current == lastBranch ? nil : lastBranch
  }

  /// One row per task and one per indexed session no task lists.
  ///
  /// `droppingUnindexedEnded` is set once a scan has finished: a session that
  /// ended and still has no file on disk never had a turn and cannot be
  /// resumed, so its placeholder row goes away instead of lingering.
  mutating func reconcileSessionItems(now: Date, droppingUnindexedEnded: Bool = false) {
    var facts = SidecarFacts(sidecar: sessions)
    var groups = SessionGroups(taskSessions: taskSessions, tabs: taskSnapshots, agents: sessionSnapshots)
    var rows = RowDrafts()
    rows.drafts.reserveCapacity(sessionSummaries.count + sessionSnapshots.count + groups.tasks.count)
    appendImplicitDrafts(to: &rows, groups: &groups, facts: &facts, keepingPlaceholders: !droppingUnindexedEnded)
    let movedSelection = appendUngroupedAgentDrafts(to: &rows, agents: groups.ungrouped, facts: &facts, now: now)
    appendTaskDrafts(to: &rows, groups: groups, facts: &facts, now: now, keepingPlaceholders: !droppingUnindexedEnded)

    let indexByID = rows.indexByID
    if sessionItems.count != rows.drafts.count || sessionItems.contains(where: { indexByID[$0.id] == nil }) {
      sessionItems.removeAll { indexByID[$0.id] == nil }
    }
    // Reads only: every write through `sessionItems` costs a pass over the
    // whole collection, so unchanged rows must not be touched.
    for draft in rows.drafts {
      guard let existing = sessionItems[id: draft.id] else {
        sessionItems.append(SessionSidebarItemFeature.State(draft))
        continue
      }
      if !existing.matches(draft) { sessionItems[id: draft.id]?.apply(draft) }
    }
    if let movedSelection { sessionSelection = movedSelection }
    guard let selection = sessionSelection, sessionItems[id: selection] == nil else { return }
    // A selected row that was folded into its task leaves the task selected.
    var owner = groups.taskByAgentRow[selection]
    if owner == nil, case .implicit(let key) = selection {
      owner = groups.tasksBySession[key]?.min { $0.persistenceKey < $1.persistenceKey }
    }
    sessionSelection = owner.flatMap { sessionItems[id: .task($0)]?.id }
  }

  /// A row for every indexed session no task lists; one a task does list
  /// is handed to that task instead.
  private func appendImplicitDrafts(
    to rows: inout RowDrafts, groups: inout SessionGroups, facts: inout SidecarFacts, keepingPlaceholders: Bool
  ) {
    for summary in sessionSummaries {
      if let owners = groups.tasksBySession[summary.id] {
        for layoutID in owners where groups.tasks[layoutID]?.indexed[summary.id] == nil {
          groups.tasks[layoutID]?.indexed[summary.id] = summary
        }
        continue
      }
      guard rows.indexByID[.implicit(summary.id)] == nil else { continue }
      rows.append(
        SessionRowDraft(
          id: .implicit(summary.id), title: summary.title, cwd: summary.cwd, createdAt: summary.createdAt,
          lifecycle: facts.lifecycle(for: summary.id),
          branchAnnotation: branchAnnotation(for: summary.id, cwd: summary.cwd, facts: &facts)))
    }
    guard keepingPlaceholders else { return }
    // A session that ended before the index caught up keeps its row.
    for row in sessionItems where row.isSynthetic {
      guard case .implicit(let key) = row.id, rows.indexByID[row.id] == nil, groups.tasksBySession[key] == nil
      else { continue }
      rows.append(
        SessionRowDraft(
          id: row.id, title: row.title, cwd: row.cwd, createdAt: row.createdAt, lifecycle: row.lifecycle,
          branchAnnotation: row.branchAnnotation, isSynthetic: true))
    }
  }

  /// Agents on a surface no known task holds, each on its own row. Returns
  /// the row a selected unreported agent became once it reported.
  private func appendUngroupedAgentDrafts(
    to rows: inout RowDrafts, agents: [SessionLiveSnapshot], facts: inout SidecarFacts, now: Date
  ) -> SessionRowID? {
    var movedSelection: SessionRowID?
    for snapshot in agents {
      let id = snapshot.id
      let provisionalID = SessionRowID.provisional(snapshot.harness, snapshot.location.surfaceID)
      if rows.indexByID[id] == nil {
        rows.append(
          SessionRowDraft(
            id: id, title: "New session", cwd: snapshot.cwd,
            createdAt: sessionItems[id: id]?.createdAt ?? sessionItems[id: provisionalID]?.createdAt ?? now,
            isSynthetic: true))
      }
      guard let index = rows.indexByID[id] else { continue }
      if case .implicit(let key) = id {
        rows.drafts[index].lifecycle = facts.lifecycle(for: key)
        rows.drafts[index].branchAnnotation = branchAnnotation(for: key, cwd: snapshot.cwd, facts: &facts)
      }
      rows.drafts[index].status = snapshot.status
      rows.drafts[index].allowsAttentionNavigation = snapshot.allowsAttentionNavigation
      if rows.drafts[index].location == nil || snapshot.location == sessionItems[id: id]?.location {
        rows.drafts[index].location = snapshot.location
      }
      if sessionSelection == provisionalID, id != provisionalID { movedSelection = id }
    }
    return movedSelection
  }

  private func appendTaskDrafts(
    to rows: inout RowDrafts, groups: SessionGroups, facts: inout SidecarFacts, now: Date, keepingPlaceholders: Bool
  ) {
    // Key order, so the rows come out the same whatever order the tasks were listed in.
    for layoutID in groups.tasks.keys.sorted(by: { $0.persistenceKey < $1.persistenceKey }) {
      guard let group = groups.tasks[layoutID] else { continue }
      let existing = sessionItems[id: .task(layoutID)]
      guard var row = taskDraft(layoutID, group: group, existing: existing, now: now) else { continue }
      // A task with no tab, no agent and no session on disk has nothing to show or resume.
      let isPlaceholder = existing?.isSynthetic == true && keepingPlaceholders
      guard row.location != nil || !group.indexed.isEmpty || isPlaceholder else { continue }
      if let primary = row.primary {
        // Settled is the primary's mark, but never for a task with a tab
        // open: its tabs would sit in the collapsed section.
        row.lifecycle = facts.lifecycle(for: primary) == .settled && row.location == nil ? .settled : .active
        let cwd = group.agents.first { $0.sessionKey == primary }?.cwd ?? group.indexed[primary]?.cwd
        row.branchAnnotation = cwd.flatMap { branchAnnotation(for: primary, cwd: $0, facts: &facts) }
      }
      rows.append(row)
    }
  }

  /// A task's row, less the two fields read from the sidecar. Nil for a
  /// task that is neither open nor lists anything.
  private func taskDraft(
    _ layoutID: LayoutID, group: TaskGroup, existing: SessionSidebarItemFeature.State?, now: Date
  ) -> SessionRowDraft? {
    let members = members(of: layoutID, agents: group.agents)
    guard group.tabs != nil || !members.isEmpty else { return nil }
    let keys = members.compactMap(\.sessionKey)
    let primary = members.first?.sessionKey
    // The row speaks for its most urgent agent, and leads to that agent.
    // Among equals the one the row already leads to stays, so it does not hop.
    let leading = group.agents.min {
      let lhs = ($0.status.urgency, $0.allowsAttentionNavigation ? 0 : 1, $0.location == existing?.location ? 0 : 1)
      let rhs = ($1.status.urgency, $1.allowsAttentionNavigation ? 0 : 1, $1.location == existing?.location ? 0 : 1)
      return lhs < rhs
    }
    // The primary titles the task. One that is running but not on disk yet
    // is a new session; one that never got there leaves the title to the
    // first member that did. Failing those, an open task is its directory.
    var title = primary.flatMap { group.indexed[$0]?.title }
    if title == nil, members.first.map({ member in group.agents.contains { $0.member == member } }) == true {
      title = "New session"
    }
    title = title ?? keys.lazy.compactMap { group.indexed[$0]?.title }.first ?? group.tabs?.title
    let indexedCwd = primary.flatMap { group.indexed[$0]?.cwd } ?? keys.lazy.compactMap { group.indexed[$0]?.cwd }.first
    // As old as its oldest session, so a replacement or a tangent does not move the row.
    let createdAt = group.indexed.values.map(\.createdAt).min() ?? group.tabs?.createdAt ?? existing?.createdAt ?? now
    return SessionRowDraft(
      id: .task(layoutID), title: title ?? existing?.title ?? "New session",
      cwd: group.tabs?.cwd ?? group.agents.first?.cwd ?? indexedCwd ?? existing?.cwd ?? "",
      createdAt: createdAt, location: leading?.location ?? group.tabs?.location, status: leading?.status,
      allowsAttentionNavigation: leading?.allowsAttentionNavigation ?? true,
      isSynthetic: !members.isEmpty && group.indexed.isEmpty, primary: primary)
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
      case .implicit(let key): liveKeys.insert(key)
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
