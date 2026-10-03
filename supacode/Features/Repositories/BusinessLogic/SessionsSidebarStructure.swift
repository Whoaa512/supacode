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

  func selection(byOffset offset: Int, from current: SessionRowID?) -> SessionRowID? {
    let ids = allIDs
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
    let ordered = sessionItems.sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.id.sortKey < $1.id.sortKey
    }
    let sections = [SessionClassification.Lifecycle.active, .settled].compactMap { lifecycle in
      let ids = ordered.filter { $0.lifecycle == lifecycle }.map(\.id)
      return ids.isEmpty ? nil : SessionsSidebarStructure.Section(id: lifecycle, rowIDs: ids)
    }
    let structure = SessionsSidebarStructure(
      sections: sections,
      liveIDs: sections.flatMap(\.rowIDs).filter { sessionItems[id: $0]?.isLive == true }
    )
    if sessionsSidebarStructure != structure { sessionsSidebarStructure = structure }
  }

  mutating func reconcileSessionItems(now: Date) {
    let previous = sessionItems
    var rows = IdentifiedArrayOf<SessionSidebarItemFeature.State>()
    for summary in sessionSummaries where rows[id: .session(summary.id)] == nil {
      rows.append(
        SessionSidebarItemFeature.State(
          id: .session(summary.id), title: summary.title, cwd: summary.cwd,
          createdAt: summary.createdAt,
          lifecycle: SessionClassification.classify(isLive: false, sidecar: sessions[summary.id])
            .lifecycle,
          status: nil,
          branchAnnotation: branchAnnotation(for: summary.id, cwd: summary.cwd)
        ))
    }
    for row in previous where row.isSynthetic {
      guard case .session = row.id, rows[id: row.id] == nil else { continue }
      rows.append(
        SessionSidebarItemFeature.State(
          id: row.id, title: row.title, cwd: row.cwd, createdAt: row.createdAt,
          lifecycle: row.lifecycle, status: nil, branchAnnotation: row.branchAnnotation, isSynthetic: true
        ))
    }
    for snapshot in sessionSnapshots.sorted(by: {
      $0.location.surfaceID.uuidString < $1.location.surfaceID.uuidString
    }) {
      let id = snapshot.id
      let provisionalID = SessionRowID.provisional(snapshot.harness, snapshot.location.surfaceID)
      if rows[id: id] == nil {
        rows.append(
          SessionSidebarItemFeature.State(
            id: id, title: "New session", cwd: snapshot.cwd,
            createdAt: previous[id: id]?.createdAt ?? previous[id: provisionalID]?.createdAt ?? now,
            status: snapshot.status,
            isSynthetic: true
          ))
      }
      if case .session(let key) = id {
        rows[id: id]?.lifecycle =
          SessionClassification.classify(isLive: true, sidecar: sessions[key]).lifecycle
        rows[id: id]?.branchAnnotation = branchAnnotation(for: key, cwd: snapshot.cwd)
      }
      rows[id: id]?.status = snapshot.status
      rows[id: id]?.allowsAttentionNavigation = snapshot.allowsAttentionNavigation
      let preferred = previous[id: id]?.location
      if rows[id: id]?.location == nil || snapshot.location == preferred {
        rows[id: id]?.location = snapshot.location
      }
      if sessionSelection == provisionalID, id != provisionalID { sessionSelection = id }
    }
    for row in rows {
      if sessionItems[id: row.id] == nil { sessionItems.append(row) }
      if sessionItems[id: row.id] != row { sessionItems[id: row.id]?.update(from: row) }
    }
    sessionItems.removeAll { rows[id: $0.id] == nil }
    if let selection = sessionSelection, sessionItems[id: selection] == nil {
      sessionSelection = nil
    }
  }

  private func branchAnnotation(for key: SessionKey, cwd: String) -> String? {
    guard let lastBranch = sessions[key]?.branches.last, !lastBranch.isEmpty else { return nil }
    guard currentBranch(forSessionCwd: cwd) != lastBranch else { return nil }
    return lastBranch
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
    guard sessionsRestorationFinished, sessionsRefreshSucceeded, !sessionsHasUnresolvedLivePresence,
      !sessionSnapshots.contains(where: { if case .provisional = $0.id { return true }; return false })
    else { return }
    for summary in sessionSummaries {
      let live = sessionsLiveKeys.contains(summary.id)
        || sessionSnapshots.contains { $0.id == .session(summary.id) }
      if let hold = sessions[summary.id]?.manualUnsettledAtActivity, summary.lastActivity > hold {
        $sessions.withLock { $0[summary.id]?.manualUnsettledAtActivity = nil }
      }
      guard sessions[summary.id]?.settledAt == nil,
        SessionClassification.classify(
          summary: summary, isLive: live, sidecar: sessions[summary.id], now: now, idleDays: idleDays
        ).lifecycle == .settled
      else { continue }
      applySettle(key: summary.id, now: now)
    }
    reconcileSessionItems(now: now)
    recomputeSessionsSidebarStructureIfChanged()
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
