import ComposableArchitecture
import ConcurrencyExtras
import Darwin
import DependenciesTestSupport
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
        location: SessionLocation(
          layoutID: LayoutID(legacyWorktreeKey: "/tmp/project"), directoryID: WorktreeID("/tmp/project"),
          tabID: TabID(),
          surfaceID: surface),
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

  @Test(.dependencies, arguments: ["abc", "unknown:abc", "pi:", ":abc", "pi:-flag", "pi:has space", "pi:a:b"])
  func malformedSessionIDsNeverMutateOrAckSuccess(_ raw: String) async throws {
    var state = AppFeature.State()
    state.repositories.$sessions = Shared(value: [:])
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off
    for action in [Deeplink.SessionAction.settle, .unsettle] {
      let pipe = Pipe()
      let writer = dup(pipe.fileHandleForWriting.fileDescriptor)
      try #require(writer >= 0)
      try pipe.fileHandleForWriting.close()
      await store.send(
        .deeplink(
          .session(key: SessionKey(rawValue: raw), action: action),
          source: .socket, responseFD: writer, timeoutSeconds: 0))
      await store.finish()
      var reader = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
      #expect(poll(&reader, 1, 0) == 1)
      #expect(reader.revents & Int16(POLLHUP) != 0)
      let data = pipe.fileHandleForReading.availableData
      let ack = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(ack["ok"] as? Bool == false)
      #expect(ack["error"] as? String == "Invalid session id. Expected harness:id.")
      #expect(store.state.repositories.sessions.isEmpty)
    }
  }

  @Test(.dependencies, arguments: [false, true])
  func sessionCLIRejectsUnknownTargetsAndAcceptsIndexedOrLiveTargets(live: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "session-cli-\(UUID())")
    let socket = directory.appending(path: "pid-1").path
    let server = AgentHookSocketServer(socketPathOverride: socket)
    defer {
      server.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
    try #require(server.socketPath == socket)
    let key = SessionKey(harness: .pi, sessionID: "known")
    var state = AppFeature.State()
    state.repositories.isInitialLoadComplete = true
    state.repositories.$sessions = Shared(value: [:])
    state.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(key), title: "Known", cwd: directory.path, createdAt: .distantPast,
        location: live
          ? SessionLocation(
            layoutID: LayoutID(legacyWorktreeKey: directory.path), directoryID: WorktreeID(directory.path),
            tabID: TabID(),
            surfaceID: UUID()) : nil)
    ]
    if let location = state.repositories.sessionItems[id: .session(key)]?.location {
      state.repositories.sessionSnapshots = [
        SessionLiveSnapshot(harness: .pi, sessionRef: "known", cwd: directory.path, location: location)
      ]
    }
    if !live {
      state.repositories.sessionSummaries = [
        SessionSummary(
          harness: .pi, sessionID: "known", createdAt: .distantPast, cwd: directory.path,
          title: "Known", messageCount: 4, lastActivity: .distantPast)
      ]
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 123)
      $0.deeplinkClient = .liveValue
    }
    store.exhaustivity = .off
    server.onCommand = { url, clientFD in
      Task { @MainActor in
        await store.send(.deeplinkReceived(url, source: .socket, responseFD: clientFD))
      }
    }
    for action in ["settle", "unsettle"] {
      for id in ["pi:has space", "pi:missing", "pi:known"] {
        let process = Process()
        let error = Pipe()
        process.executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
        process.arguments = ["session", action, id, "--timeout", "10"]
        process.environment = ProcessInfo.processInfo.environment.merging(
          ["SUPACODE_SOCKET_PATH": socket], uniquingKeysWith: { _, fixture in fixture })
        process.standardError = error
        process.standardOutput = Pipe()
        try await process.runToExit()
        await store.finish()
        let message = String(bytes: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect((process.terminationStatus == 0) == (id == "pi:known"), "CLI: \(message)")
        #expect(store.state.repositories.sessions[SessionKey(rawValue: id)] == nil || id == "pi:known")
        if id == "pi:known" {
          #expect((store.state.repositories.sessions[key]?.settledAt != nil) == (action == "settle"))
        } else {
          #expect(!message.isEmpty)
        }
      }
    }
    #expect(store.state.repositories.sessions.count == 1)
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
    for raw in ["abc", "unknown:abc", "pi:", ":abc", "pi:-flag", "pi:has space", "pi:a:b"] {
      let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
      #expect(client.parse(URL(string: "supacode://session/\(encoded)/settle")!) == nil)
    }
    #expect(client.parse(URL(string: "supacode://session/pi%3Aabc/settle/extra")!) == nil)
  }
}
