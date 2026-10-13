import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// The agent rows name the task holding each surface, so the CLI can tell two
/// same-kind agents on one directory apart; a surface no task holds reads empty.
@MainActor
struct AgentQueryResponseTaskTests {
  private let worktree = Worktree(
    id: WorktreeID("/tmp/repo/wt-1"),
    name: "wt-1",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
  )
  private let task = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!)
  private let inTask = UUID()
  private let loose = UUID()

  private func repositories() -> RepositoriesFeature.State {
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [
      Repository(id: "/tmp/repo", rootURL: URL(fileURLWithPath: "/tmp/repo"), name: "repo", worktrees: [worktree])
    ]
    repositories.isInitialLoadComplete = true
    repositories.reconcileSidebarForTesting()
    repositories.sidebarItems[id: worktree.id]?.surfaceIDs = [inTask, loose]
    return repositories
  }

  @Test func liveRowsCarryTheTaskOfTheSurfaceOrNothing() {
    var presence = AgentPresenceFeature.State()
    presence.records[.init(agent: .pi, surfaceID: inTask)] = AgentPresenceFeature.PresenceRecord(pids: [1])
    presence.records[.init(agent: .claude, surfaceID: loose)] = AgentPresenceFeature.PresenceRecord(pids: [2])
    let rows = AgentQueryResponse.rows(presence: presence, repositories: repositories(), tasks: [inTask: task])
    let byAgent = Dictionary(uniqueKeysWithValues: rows.map { ($0[AgentQueryResponse.Key.agent] ?? "", $0) })
    #expect(byAgent["pi"]?[AgentQueryResponse.Key.taskID] == task.externalID)
    #expect(byAgent["claude"]?[AgentQueryResponse.Key.taskID] == "")
  }

  @Test func resumeCandidateRowsCarryTheTaskToo() {
    var presence = AgentPresenceFeature.State()
    presence.resumeCandidates[.init(agent: .pi, surfaceID: inTask)] = .init(sessionRef: "s1", lastActivity: .idle)
    presence.resumeCandidates[.init(agent: .pi, surfaceID: loose)] = .init(sessionRef: "s2", lastActivity: .idle)
    let rows = AgentResumeCandidateQueryResponse.rows(
      presence: presence, repositories: repositories(), tasks: [inTask: task])
    let byRef = Dictionary(uniqueKeysWithValues: rows.map { ($0[AgentQueryResponse.Key.sessionRef] ?? "", $0) })
    #expect(byRef["s1"]?[AgentResumeCandidateQueryResponse.Key.taskID] == task.externalID)
    #expect(byRef["s2"]?[AgentResumeCandidateQueryResponse.Key.taskID] == "")
    #expect(AgentResumeCandidateQueryResponse.Key.all.last == AgentResumeCandidateQueryResponse.Key.taskID)
  }
}
