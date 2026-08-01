import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// Drives the bundled `supacode agent` binary against a fixture socket. The CLI
/// is a separate product with no test target, so a subprocess is the only way to
/// cover its target resolution and output shape. Serialized because every case
/// waits on fixture replies delivered on the main actor.
@MainActor
@Suite(.serialized)
struct AgentCLITests {
  private struct Run {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32

    func succeeding(_ sourceLocation: SourceLocation = #_sourceLocation) -> String {
      #expect(exitCode == 0, "CLI failed: \(standardError)", sourceLocation: sourceLocation)
      return standardOutput
    }
  }

  private static func row(
    name: String = "",
    agent: String = "claude",
    state: String = "idle",
    activity: String = "idle",
    worktreeID: String = "%2Ftmp%2Frepo%2Falpha",
    branch: String = "alpha",
    repo: String = "repo",
    title: String = "alpha"
  ) -> [String: String] {
    [
      "name": name,
      "agent": agent,
      "activity": activity,
      "state": state,
      "worktreeID": worktreeID,
      "branch": branch,
      "repo": repo,
      "worktreeTitle": title,
    ]
  }

  // MARK: - list.

  @Test(.timeLimit(.minutes(3)))
  func listPrintsColumnsWithADashForUnnamedAgents() async throws {
    let rows = [
      Self.row(name: "reviewer", state: "blocked", activity: "awaitingInput"),
      Self.row(agent: "codex", worktreeID: "%2Ftmp%2Frepo%2Fbravo", branch: "bravo", title: "bravo"),
    ]
    try await withFixture(rows: rows) { cli, _, _ in
      let output = try await cli(["agent", "list"]).succeeding()
      #expect(
        output == """
          reviewer\tclaude\tblocked\trepo\talpha\t%2Ftmp%2Frepo%2Falpha
          -\tcodex\tidle\trepo\tbravo\t%2Ftmp%2Frepo%2Fbravo

          """
      )
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func listEmitsJsonRowsWithAStableKeyOrder() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, _, _ in
      let output = try await cli(["agent", "list", "--json"]).succeeding()
      #expect(
        output == """
          {"name":"reviewer","agent":"claude","state":"idle","activity":"idle",\
          "repo":"repo","branch":"alpha","worktreeTitle":"alpha","worktreeID":"%2Ftmp%2Frepo%2Falpha"}

          """
      )
    }
  }

  // MARK: - rename.

  @Test(.timeLimit(.minutes(3)))
  func renameResolvesByBranchAndDispatchesTheDeeplink() async throws {
    try await withFixture(rows: [Self.row()]) { cli, _, deeplinks in
      _ = try await cli(["agent", "rename", "alpha", "reviewer"]).succeeding()
      #expect(deeplinks.value.count == 1)
      #expect(
        deeplinks.value.first?.hasPrefix("supacode://agent/%2Ftmp%2Frepo%2Falpha/claude/rename?name=reviewer") == true
      )
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func renameByWorktreeIDAcceptsTheDecodedForm() async throws {
    try await withFixture(rows: [Self.row()]) { cli, _, deeplinks in
      _ = try await cli(["agent", "rename", "/tmp/repo/alpha", "reviewer"]).succeeding()
      #expect(deeplinks.value.count == 1)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func clearOmitsTheNameParameter() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, _, deeplinks in
      _ = try await cli(["agent", "rename", "reviewer", "--clear"]).succeeding()
      let url = try #require(deeplinks.value.first)
      #expect(url.contains("/claude/rename"))
      #expect(!url.contains("name="))
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func renameRejectsBothANameAndClear() async throws {
    try await withFixture(rows: [Self.row()]) { cli, _, deeplinks in
      let conflict = try await cli(["agent", "rename", "alpha", "reviewer", "--clear"])
      #expect(conflict.exitCode != 0)
      #expect(conflict.standardError.contains("not both"))
      #expect(deeplinks.value.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func ambiguousWorktreeTargetListsCandidates() async throws {
    let rows = [Self.row(name: "reviewer"), Self.row(agent: "codex")]
    try await withFixture(rows: rows) { cli, _, deeplinks in
      let ambiguous = try await cli(["agent", "rename", "alpha", "builder"])
      #expect(ambiguous.exitCode != 0)
      #expect(ambiguous.standardError.contains("--agent <kind>"))
      #expect(ambiguous.standardError.contains("claude (reviewer)"))
      #expect(ambiguous.standardError.contains("codex"))
      #expect(deeplinks.value.isEmpty)

      // The kind disambiguates, and an exact name match never needs it.
      _ = try await cli(["agent", "rename", "alpha", "builder", "--agent", "codex"]).succeeding()
      _ = try await cli(["agent", "rename", "reviewer", "builder"]).succeeding()
      #expect(deeplinks.value.count == 2)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func unknownTargetFailsWithoutDispatching() async throws {
    try await withFixture(rows: [Self.row()]) { cli, _, deeplinks in
      let missing = try await cli(["agent", "rename", "nope", "reviewer"])
      #expect(missing.exitCode != 0)
      #expect(missing.standardError.contains("No running agent matches 'nope'"))
      #expect(deeplinks.value.isEmpty)
    }
  }

  // MARK: - wait.

  @Test(.timeLimit(.minutes(3)))
  func waitReturnsImmediatelyWhenTheStateAlreadyMatches() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer", state: "done")]) { cli, resources, _ in
      let output = try await cli(["agent", "wait", "reviewer"]).succeeding()
      #expect(output.contains("\"state\":\"done\""))
      // Default `--until` covers idle|done|blocked, so one poll suffices.
      #expect(resources.value.count == 1)
    }
  }

  @Test(.timeLimit(.minutes(3))) func waitTimesOutWhileTheAgentIsWorking() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer", state: "working")]) { cli, _, _ in
      let timedOut = try await cli(["agent", "wait", "reviewer", "--timeout", "1"])
      #expect(timedOut.exitCode != 0)
      #expect(timedOut.standardError.contains("Timed out after 1s"))
      #expect(timedOut.standardOutput.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func waitRejectsAnUnknownUntilState() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, resources, _ in
      let unknown = try await cli(["agent", "wait", "reviewer", "--until", "settled"])
      #expect(unknown.exitCode != 0)
      #expect(unknown.standardError.contains("Unknown state 'settled'"))
      // Validation runs before the query, so the app is never contacted.
      #expect(resources.value.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func waitOnANameThatNeverExistedReportsNoMatch() async throws {
    try await withFixture(rows: [Self.row()]) { cli, _, _ in
      let missing = try await cli(["agent", "wait", "reviewer", "--timeout", "1"])
      #expect(missing.exitCode != 0)
      #expect(missing.standardError.contains("No running agent matches"))
      #expect(!missing.standardError.contains("agent_not_running"))
    }
  }

  // MARK: - Fixture.

  /// Fixture socket answering `agents` queries with `rows` and recording the
  /// deeplinks the CLI dispatches. Mirrors `WorktreeStatusCLITests`; the socket
  /// basename must stay `pid-<live pid>` or `SocketDiscovery.isAlive` rejects it
  /// and the CLI falls back to the developer's running Supacode.
  private func withFixture(
    rows: [[String: String]],
    body: (
      _ cli: ([String]) async throws -> Run,
      _ resources: LockIsolated<[String]>,
      _ deeplinks: LockIsolated<[String]>
    ) async throws -> Void
  ) async throws {
    let directory = "/tmp/supacode-agent-cli-\(UUID().uuidString)"
    let socketPath = "\(directory)/pid-\(ProcessInfo.processInfo.processIdentifier)"
    let resources = LockIsolated<[String]>([])
    let deeplinks = LockIsolated<[String]>([])
    let server = AgentHookSocketServer(socketPathOverride: socketPath)
    try #require(server.socketPath == socketPath)
    server.onQuery = { resource, _, clientFD in
      resources.withValue { $0.append(resource) }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: rows)
    }
    server.onCommand = { url, clientFD in
      deeplinks.withValue { $0.append(url.absoluteString) }
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: true, error: nil)
    }
    defer {
      server.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }

    try await body({ try await Self.runCLI(arguments: $0, socketPath: socketPath) }, resources, deeplinks)
    #expect(resources.value.allSatisfy { $0 == "agents" })
  }

  private static func runCLI(arguments: [String], socketPath: String) async throws -> Run {
    let executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    try #require(FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false)))
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["SUPACODE_SOCKET_PATH": socketPath],
      uniquingKeysWith: { _, fixture in fixture }
    )
    process.standardOutput = output
    process.standardError = error

    try await process.runToExit()

    return Run(
      standardOutput: String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      standardError: String(bytes: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )
  }
}
