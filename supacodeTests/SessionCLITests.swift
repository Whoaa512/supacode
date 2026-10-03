import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@Suite(.serialized)
@MainActor
struct SessionCLITests {
  @Test func sessionsQueryIncludesBranchAndSurfaceID() {
    let key = SessionKey(harness: .pi, sessionID: "abc")
    let surface = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
    var repositories = RepositoriesFeature.State()
    repositories.$sessions = Shared(value: [key: SessionSidecarEntry(branches: ["feature/session"])])
    repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(key), title: "Title", cwd: "/tmp/project", createdAt: .distantPast,
        lifecycle: .active,
        location: SessionLocation(worktreeID: WorktreeID("/tmp/project"), tabID: TabID(), surfaceID: surface),
        branchAnnotation: "feature/session")
    ]
    repositories.recomputeSessionsSidebarStructureIfChanged()

    let rows = SessionQueryResponse.rows(repositories: repositories)

    #expect(rows.count == 1)
    #expect(rows[0][SessionQueryResponse.Key.id] == "pi:abc")
    #expect(rows[0][SessionQueryResponse.Key.live] == "1")
    #expect(rows[0][SessionQueryResponse.Key.branch] == "feature/session")
    #expect(rows[0][SessionQueryResponse.Key.surfaceID] == surface.uuidString)
  }

  @Test func sessionDeeplinkParsesSettleAndUnsettle() {
    let client = DeeplinkClient.liveValue

    #expect(
      client.parse(URL(string: "supacode://session/pi%3Aabc/settle")!)
        == .session(key: SessionKey(rawValue: "pi:abc"), action: .settle))
    #expect(
      client.parse(URL(string: "supacode://session/pi%3Aabc/unsettle")!)
        == .session(key: SessionKey(rawValue: "pi:abc"), action: .unsettle))
    #expect(client.parse(URL(string: "supacode://session/pi%3Aabc/delete")!) == nil)
  }
}
