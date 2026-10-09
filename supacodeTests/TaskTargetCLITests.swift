import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// Drives the bundled `supacode` binary against a fixture socket to pin how
/// `--task` and `$SUPACODE_TASK_ID` reach the app. Serialized for the same
/// reason as `WorktreeStatusCLITests`: the fixture answers on the main actor.
@MainActor
@Suite(.serialized)
struct TaskTargetCLITests {
  private static let worktree = "%2Ftmp%2Frepo%2Fwt-1"
  private static let task = "00000000-0000-0000-0000-0000000000A1"
  private static let tab = "00000000-0000-0000-0000-0000000000B1"

  @Test(.timeLimit(.minutes(3)))
  func explicitTaskRidesOnTheQuery() async throws {
    try await withFixture { cli, queries, _ in
      _ = try await cli(["tab", "list", "-w", Self.worktree, "--task", Self.task], [:])
      #expect(queries.value == [["worktreeID": Self.worktree, "taskID": Self.task]])
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func environmentTaskAppliesOnlyToItsOwnWorktree() async throws {
    let home = ["SUPACODE_WORKTREE_ID": Self.worktree, "SUPACODE_TASK_ID": Self.task]
    try await withFixture { cli, queries, _ in
      _ = try await cli(["tab", "list", "-w", Self.worktree], home)
      // The app's and the environment's spelling of one path may differ by a slash.
      _ = try await cli(["tab", "list", "-w", Self.worktree + "%2F"], home)
      _ = try await cli(["tab", "list", "-w", "%2Ftmp%2Frepo%2Fwt-2"], home)
      _ = try await cli(["tab", "list", "-w", Self.worktree, "--task", "explicit"], home)
      #expect(
        queries.value == [
          ["worktreeID": Self.worktree, "taskID": Self.task],
          ["worktreeID": Self.worktree + "%2F", "taskID": Self.task],
          ["worktreeID": "%2Ftmp%2Frepo%2Fwt-2"],
          ["worktreeID": Self.worktree, "taskID": "explicit"],
        ])
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func aShellFromBeforeTasksSendsNoTask() async throws {
    try await withFixture { cli, queries, commands in
      let old = ["SUPACODE_WORKTREE_ID": Self.worktree, "SUPACODE_TASK_ID": ""]
      _ = try await cli(["tab", "list", "-w", Self.worktree], old)
      _ = try await cli(["tab", "focus", "-w", Self.worktree, "-t", Self.tab], old)
      #expect(queries.value == [["worktreeID": Self.worktree]])
      #expect(
        commands.value.map { DeeplinkClient.liveValue.parse($0) } == [
          .worktree(id: "/tmp/repo/wt-1", action: .tab(tabID: UUID(uuidString: Self.tab)!), task: nil)
        ])
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func taskBecomesADeeplinkSegmentTheAppParses() async throws {
    try await withFixture { cli, _, commands in
      _ = try await cli(["tab", "focus", "-w", Self.worktree, "-t", Self.tab, "--task", Self.task], [:])
      _ = try await cli(["pane", "equalize", "-w", Self.worktree, "--task", Self.task], [:])
      let parsed = commands.value.map { DeeplinkClient.liveValue.parse($0) }
      let task = LayoutID(task: UUID(uuidString: Self.task)!)
      #expect(
        parsed == [
          .worktree(id: "/tmp/repo/wt-1", action: .tab(tabID: UUID(uuidString: Self.tab)!), task: task),
          .worktree(id: "/tmp/repo/wt-1", action: .paneEqualize, task: task),
        ])
    }
  }

  // MARK: - Fixture.

  private func withFixture(
    body: (
      _ cli: ([String], [String: String]) async throws -> Int32,
      _ queries: LockIsolated<[[String: String]]>,
      _ commands: LockIsolated<[URL]>
    ) async throws -> Void
  ) async throws {
    // The basename must stay `pid-<live pid>`: `SocketDiscovery.isAlive` rejects
    // any other shape and the CLI would then fall back to the running Supacode.
    let directory = "/tmp/supacode-cli-\(UUID().uuidString)"
    let socketPath = "\(directory)/pid-\(ProcessInfo.processInfo.processIdentifier)"
    let queries = LockIsolated<[[String: String]]>([])
    let commands = LockIsolated<[URL]>([])
    let server = AgentHookSocketServer(socketPathOverride: socketPath)
    try #require(server.socketPath == socketPath)
    server.onQuery = { _, params, clientFD in
      queries.withValue { $0.append(params) }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: [])
    }
    server.onCommand = { url, clientFD in
      commands.withValue { $0.append(url) }
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: true)
    }
    defer {
      server.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }
    try await body({ try await Self.runCLI(arguments: $0, environment: $1, socketPath: socketPath) }, queries, commands)
  }

  private static func runCLI(
    arguments: [String], environment: [String: String], socketPath: String
  ) async throws -> Int32 {
    let executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    try #require(FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false)))
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments + ["--timeout", "30"]
    // The suite may itself run inside a Supacode terminal, so the task
    // variables are always set here: blank unless the case supplies them.
    var merged = ProcessInfo.processInfo.environment
    merged["SUPACODE_WORKTREE_ID"] = ""
    merged["SUPACODE_TASK_ID"] = ""
    merged.merge(environment) { _, fixture in fixture }
    merged["SUPACODE_SOCKET_PATH"] = socketPath
    process.environment = merged
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try await process.runToExit()
    return process.terminationStatus
  }
}
