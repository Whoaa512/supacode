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
    title: String = "alpha",
    taskID: String = "",
    surfaceID: String = ""
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
      "taskID": taskID,
      "surfaceID": surfaceID,
    ]
  }

  private static let surfaceA = "00000000-0000-0000-0000-00000000005A"
  private static let surfaceB = "00000000-0000-0000-0000-00000000005B"

  private static let taskA = "00000000-0000-0000-0000-0000000000A1"
  private static let taskB = "00000000-0000-0000-0000-0000000000B2"

  /// Fixture `agentExplain` reply. `pids` is deliberately empty so the report's
  /// "unset reads as `-`" branch is covered.
  private static let explainRow: [String: String] = [
    "agent": "claude",
    "name": "reviewer",
    "activity": "idle",
    "dashboardState": "done",
    "isDoneUnseen": "true",
    "lastEvent": "idle",
    "lastEventAt": "2023-11-14T22:13:20Z",
    "lastTransition": "busy\u{2192}idle",
    "pids": "",
    "source": "hook",
    "token.summary": "fixing tests",
  ]

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

  // MARK: - Two agents of one kind on one worktree: the task tells them apart.

  private static var twoTasks: [[String: String]] {
    [Self.row(taskID: taskA), Self.row(taskID: taskB)]
  }

  @Test(.timeLimit(.minutes(3)))
  func sameKindOnOneWorktreeIsAmbiguousUntilATaskPicks() async throws {
    try await withFixture(rows: Self.twoTasks) { cli, _, deeplinks in
      let ambiguous = try await cli(["agent", "rename", "alpha", "builder"])
      #expect(ambiguous.exitCode != 0)
      #expect(ambiguous.standardError.contains("--task <id>"))
      #expect(ambiguous.standardError.contains("claude --task \(Self.taskA)"))
      #expect(ambiguous.standardError.contains("claude --task \(Self.taskB)"))
      #expect(deeplinks.value.isEmpty)

      _ = try await cli(["agent", "rename", "alpha", "builder", "--task", Self.taskB]).succeeding()
      #expect(
        deeplinks.value == [
          "supacode://agent/%2Ftmp%2Frepo%2Falpha/task/\(Self.taskB)/claude/rename?name=builder&timeout=180"
        ])
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func theEnvironmentsTaskBreaksATieOnlyWhenExactlyOneCandidateIsOnIt() async throws {
    try await withFixture(rows: Self.twoTasks, environment: ["SUPACODE_TASK_ID": Self.taskA]) { cli, _, deeplinks in
      _ = try await cli(["agent", "send-keys", "alpha", "esc"]).succeeding()
      #expect(deeplinks.value.first?.contains("/task/\(Self.taskA)/claude/send-keys") == true)
      // An explicit --task outranks the environment.
      _ = try await cli(["agent", "send-keys", "alpha", "esc", "--task", Self.taskB]).succeeding()
      #expect(deeplinks.value.last?.contains("/task/\(Self.taskB)/claude/send-keys") == true)
    }
    // Two candidates on the environment's task: still ambiguous, nothing picked.
    let bothOnA = [Self.row(taskID: Self.taskA), Self.row(name: "second", taskID: Self.taskA)]
    try await withFixture(rows: bothOnA, environment: ["SUPACODE_TASK_ID": Self.taskA]) { cli, _, deeplinks in
      let ambiguous = try await cli(["agent", "send-keys", "alpha", "esc"])
      #expect(ambiguous.exitCode != 0)
      #expect(deeplinks.value.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func aNameWinsOverAContradictingTaskAndCarriesItsOwnTask() async throws {
    let rows = [Self.row(name: "reviewer", taskID: Self.taskA), Self.row(taskID: Self.taskB)]
    try await withFixture(rows: rows) { cli, _, deeplinks in
      _ = try await cli(["agent", "prompt", "reviewer", "go", "--task", Self.taskB]).succeeding()
      #expect(deeplinks.value.first?.contains("/task/\(Self.taskA)/claude/prompt") == true)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func aRowWithNoTaskEmitsNoTaskSegmentAndMatchesNoTask() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, _, deeplinks in
      _ = try await cli(["agent", "send-keys", "reviewer", "esc"]).succeeding()
      #expect(deeplinks.value == ["supacode://agent/%2Ftmp%2Frepo%2Falpha/claude/send-keys?keys=esc&timeout=180"])
      let missing = try await cli(["agent", "send-keys", "alpha", "esc", "--task", Self.taskA])
      #expect(missing.exitCode != 0)
      #expect(deeplinks.value.count == 1)
    }
  }

  /// Two agents of one kind in one task: a name resolves one row, and every
  /// command carries that row's surface so the app reaches that agent, not
  /// the first same-kind one in the task.
  @Test(.timeLimit(.minutes(3)))
  func aResolvedRowCarriesItsSurfaceSoANamedAgentIsReachedExactly() async throws {
    let rows = [
      Self.row(name: "first", taskID: Self.taskA, surfaceID: Self.surfaceA),
      Self.row(name: "second", taskID: Self.taskA, surfaceID: Self.surfaceB),
    ]
    try await withFixture(rows: rows, screen: "ok") { cli, params, deeplinks in
      _ = try await cli(["agent", "prompt", "second", "go"]).succeeding()
      _ = try await cli(["agent", "rename", "second", "two"]).succeeding()
      _ = try await cli(["agent", "report-metadata", "second", "--token", "summary=x"]).succeeding()
      _ = try await cli(["agent", "read", "second"]).succeeding()
      let base = "supacode://agent/%2Ftmp%2Frepo%2Falpha/task/\(Self.taskA)/claude"
      let surface = "surface=\(Self.surfaceB)&timeout="
      #expect(deeplinks.value.contains { $0.hasPrefix("\(base)/prompt?text=go&\(surface)") })
      #expect(deeplinks.value.contains { $0.hasPrefix("\(base)/rename?name=two&\(surface)") })
      #expect(deeplinks.value.contains { $0.hasPrefix("\(base)/metadata?summary=x&\(surface)") })
      #expect(params.value.contains("agentRead surfaceID=\(Self.surfaceB)"))
      // Named at the task alone, two candidates stay ambiguous.
      let ambiguous = try await cli(["agent", "prompt", "alpha", "go", "--task", Self.taskA])
      #expect(ambiguous.exitCode != 0)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func listJsonCarriesTheTaskAndOmitsAnEmptyOne() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer", taskID: Self.taskA), Self.row(name: "plain")]) {
      cli, _, _ in
      let output = try await cli(["agent", "list", "--json"]).succeeding()
      let lines = output.split(separator: "\n").map(String.init)
      #expect(lines[0].hasSuffix("\"worktreeID\":\"%2Ftmp%2Frepo%2Falpha\",\"taskID\":\"\(Self.taskA)\"}"))
      #expect(lines[1].hasSuffix("\"worktreeID\":\"%2Ftmp%2Frepo%2Falpha\"}"))
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func readAndExplainSendTheResolvedRowsTask() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer", taskID: Self.taskA)], screen: "ok") { cli, params, _ in
      _ = try await cli(["agent", "read", "reviewer"]).succeeding()
      _ = try await cli(["agent", "explain", "reviewer", "--json"]).succeeding()
      #expect(params.value.contains("agentRead taskID=\(Self.taskA)"))
      #expect(params.value.contains("agentExplain taskID=\(Self.taskA)"))
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

  // MARK: - prompt.

  @Test(.timeLimit(.minutes(3)))
  func promptDispatchesTheDeeplinkAndSubmitsByDefault() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, _, deeplinks in
      _ = try await cli(["agent", "prompt", "reviewer", "run the tests"]).succeeding()
      let url = try #require(deeplinks.value.first)
      #expect(url.hasPrefix("supacode://agent/%2Ftmp%2Frepo%2Falpha/claude/prompt?text=run%20the%20tests"))
      #expect(!url.contains("submit=false"))
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func promptNoSubmitOptsOutOfTheEnterSequence() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, _, deeplinks in
      _ = try await cli(["agent", "prompt", "reviewer", "draft", "--no-submit"]).succeeding()
      #expect(deeplinks.value.first?.contains("submit=false") == true)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func promptWaitFailsAsStalledWhenTheAgentNeverStartsWorking() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer", state: "idle")]) { cli, _, deeplinks in
      let stalled = try await cli(
        ["agent", "prompt", "reviewer", "go", "--wait", "--stall-timeout", "1"])
      #expect(stalled.exitCode != 0)
      #expect(stalled.standardError.contains("agent_prompt_stalled"))
      // The prompt itself still went out; only the wait failed.
      #expect(deeplinks.value.count == 1)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func promptWaitReturnsTheSettledRowAfterTheTurnStarts() async throws {
    // Poll 0 answers the resolve before dispatch, poll 1 proves the turn
    // started, poll 2 settles it.
    let states = ["idle", "working", "done"]
    let rowsForPoll: (Int) -> [[String: String]] = { poll in
      [Self.row(name: "reviewer", state: states[min(poll, states.count - 1)])]
    }
    try await withFixture(rowsForPoll: rowsForPoll) { cli, _, deeplinks in
      let output = try await cli(
        ["agent", "prompt", "reviewer", "go", "--wait", "--stall-timeout", "5", "--timeout", "20"]
      ).succeeding()
      #expect(output.contains("\"state\":\"done\""))
      #expect(deeplinks.value.count == 1)
    }
  }

  // MARK: - send-keys.

  @Test(.timeLimit(.minutes(3)))
  func sendKeysDispatchesTheJoinedKeyList() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, _, deeplinks in
      _ = try await cli(["agent", "send-keys", "reviewer", "esc", "CTRL+C", "enter"]).succeeding()
      #expect(
        deeplinks.value.first
          == "supacode://agent/%2Ftmp%2Frepo%2Falpha/claude/send-keys?keys=esc,ctrl+c,enter&timeout=180"
      )
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func sendKeysRejectsAnUnknownKeyBeforeContactingTheApp() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, resources, deeplinks in
      let unknown = try await cli(["agent", "send-keys", "reviewer", "esc", "f13"])
      #expect(unknown.exitCode != 0)
      #expect(unknown.standardError.contains("Unknown key 'f13'"))
      #expect(resources.value.isEmpty)
      #expect(deeplinks.value.isEmpty)
    }
  }

  // MARK: - read.

  @Test(.timeLimit(.minutes(3)))
  func readPrintsTheScreenTextForTheResolvedAgent() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")], screen: "tests passed") { cli, resources, _ in
      let output = try await cli(["agent", "read", "reviewer", "--lines", "5"]).succeeding()
      #expect(output == "tests passed\n")
      #expect(resources.value == ["agents", "agentRead"])
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func readRejectsANonPositiveLineCount() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, resources, _ in
      let invalid = try await cli(["agent", "read", "reviewer", "--lines", "0"])
      #expect(invalid.exitCode != 0)
      #expect(resources.value.isEmpty)
    }
  }

  // MARK: - report-metadata.

  @Test(.timeLimit(.minutes(3)))
  func reportMetadataDispatchesSortedTokens() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, _, deeplinks in
      _ = try await cli(
        ["agent", "report-metadata", "reviewer", "--token", "summary=fixing tests", "--token", "model=opus"]
      ).succeeding()
      let url = try #require(deeplinks.value.first)
      #expect(url.hasPrefix("supacode://agent/%2Ftmp%2Frepo%2Falpha/claude/metadata?model=opus&summary=fixing%20tests"))
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func reportMetadataClearNeedsNoTokens() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, _, deeplinks in
      _ = try await cli(["agent", "report-metadata", "reviewer", "--clear"]).succeeding()
      #expect(deeplinks.value.first?.contains("metadata?clear=true") == true)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func reportMetadataRejectsMalformedTokensAndEmptyInvocations() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, resources, deeplinks in
      let malformed = try await cli(["agent", "report-metadata", "reviewer", "--token", "summary"])
      #expect(malformed.exitCode != 0)
      #expect(malformed.standardError.contains("Expected key=value"))

      let empty = try await cli(["agent", "report-metadata", "reviewer"])
      #expect(empty.exitCode != 0)
      #expect(empty.standardError.contains("at least one --token"))

      #expect(resources.value.isEmpty)
      #expect(deeplinks.value.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func listJsonTrailsMetadataTokensAfterTheFixedColumns() async throws {
    var row = Self.row(name: "reviewer")
    row["token.summary"] = "fixing tests"
    row["token.model"] = "opus"
    try await withFixture(rows: [row]) { cli, _, _ in
      let output = try await cli(["agent", "list", "--json"]).succeeding()
      #expect(output.hasSuffix("\"token.model\":\"opus\",\"token.summary\":\"fixing tests\"}\n"))
      #expect(output.contains("\"name\":\"reviewer\""))
    }
  }

  // MARK: - explain.

  @Test(.timeLimit(.minutes(3)))
  func explainPrintsALabelledReportJoinedWithTheWorktreeRow() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer", state: "done")]) { cli, resources, _ in
      let output = try await cli(["agent", "explain", "reviewer"]).succeeding()
      #expect(output.contains("Name             reviewer"))
      #expect(output.contains("Dashboard state  done"))
      #expect(output.contains("Last transition  busy\u{2192}idle"))
      #expect(output.contains("Last event at    2023-11-14T22:13:20Z"))
      #expect(output.contains("State source     hook"))
      // Unreported diagnostics read as `-` rather than vanishing.
      #expect(output.contains("PIDs             -"))
      // Worktree context comes from the `agents` row the target resolved against.
      #expect(output.contains("Branch           alpha"))
      #expect(output.contains("$summary         fixing tests"))
      #expect(resources.value == ["agents", "agentExplain"])
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func explainJsonEmitsTheRawRowWithAStableKeyOrder() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")]) { cli, _, _ in
      let output = try await cli(["agent", "explain", "reviewer", "--json"]).succeeding()
      #expect(
        output == """
          {"agent":"claude","name":"reviewer","activity":"idle","dashboardState":"done",\
          "isDoneUnseen":"true","lastEvent":"idle","lastEventAt":"2023-11-14T22:13:20Z",\
          "lastTransition":"busy\u{2192}idle","pids":"","source":"hook","sessionRef":"",\
          "token.summary":"fixing tests"}

          """
      )
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func explainFailsWithoutQueryingWhenTheTargetIsUnknown() async throws {
    try await withFixture(rows: [Self.row()]) { cli, resources, _ in
      let missing = try await cli(["agent", "explain", "nope"])
      #expect(missing.exitCode != 0)
      #expect(missing.standardError.contains("No running agent matches 'nope'"))
      #expect(resources.value == ["agents"])
    }
  }

  // MARK: - terminal wait-output.

  @Test(.timeLimit(.minutes(3)))
  func waitOutputPrintsTheMatchingLineForALiteral() async throws {
    try await withFixture(
      rows: [Self.row(name: "reviewer")],
      screen: "running tests\n42 passed, 0 failed"
    ) { cli, resources, _ in
      let output = try await cli(["terminal", "wait-output", "reviewer", "--text", "passed"]).succeeding()
      #expect(output == "42 passed, 0 failed\n")
      #expect(resources.value.contains("agentRead"))
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func waitOutputMatchesARegexPerLine() async throws {
    try await withFixture(
      rows: [Self.row(name: "reviewer")],
      screen: "building\nBUILD FAILED: 3 errors"
    ) { cli, _, _ in
      let output = try await cli(
        ["terminal", "wait-output", "reviewer", "--regex", "BUILD (FAILED|SUCCEEDED)"]
      ).succeeding()
      #expect(output == "BUILD FAILED: 3 errors\n")
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func waitOutputTimesOutWhenNothingMatches() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")], screen: "still building") { cli, _, _ in
      let timedOut = try await cli(
        ["terminal", "wait-output", "reviewer", "--text", "passed", "--timeout", "1"])
      #expect(timedOut.exitCode != 0)
      #expect(timedOut.standardError.contains("Timed out after 1s"))
      #expect(timedOut.standardOutput.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func waitOutputRequiresExactlyOneMatcher() async throws {
    try await withFixture(rows: [Self.row(name: "reviewer")], screen: "x") { cli, resources, _ in
      let neither = try await cli(["terminal", "wait-output", "reviewer"])
      #expect(neither.exitCode != 0)
      #expect(neither.standardError.contains("exactly one of --regex or --text"))

      let both = try await cli(
        ["terminal", "wait-output", "reviewer", "--text", "a", "--regex", "a"])
      #expect(both.exitCode != 0)

      #expect(resources.value.isEmpty)
    }
  }

  // MARK: - Fixture.

  /// Fixture socket answering `agents` queries with `rows` and recording the
  /// deeplinks the CLI dispatches. Mirrors `WorktreeStatusCLITests`; the socket
  /// basename must stay `pid-<live pid>` or `SocketDiscovery.isAlive` rejects it
  /// and the CLI falls back to the developer's running Supacode.
  private func withFixture(
    rows: [[String: String]],
    screen: String = "",
    environment: [String: String] = [:],
    body: (
      _ cli: ([String]) async throws -> Run,
      _ resources: LockIsolated<[String]>,
      _ deeplinks: LockIsolated<[String]>
    ) async throws -> Void
  ) async throws {
    try await withFixture(rowsForPoll: { _ in rows }, screen: screen, environment: environment, body: body)
  }

  /// Variant whose `agents` reply depends on the poll index, so a wait that
  /// needs a state transition doesn't need `Task.sleep` to get one.
  private func withFixture(
    rowsForPoll: @escaping (Int) -> [[String: String]],
    screen: String = "",
    environment: [String: String] = [:],
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
    let agentPolls = LockIsolated(0)
    server.onQuery = { resource, params, clientFD in
      resources.withValue { $0.append(resource) }
      if let taskID = params["taskID"] { resources.withValue { $0.append("\(resource) taskID=\(taskID)") } }
      if let surfaceID = params["surfaceID"] {
        resources.withValue { $0.append("\(resource) surfaceID=\(surfaceID)") }
      }
      if resource == "agentExplain" {
        AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: [Self.explainRow])
        return
      }
      guard resource == "agents" else {
        let lines = AgentReadQueryResponse.lineCount(params["lines"])
        AgentHookSocketServer.sendQueryResponse(
          clientFD: clientFD, data: AgentReadQueryResponse.rows(screen: screen, lines: lines))
        return
      }
      let poll = agentPolls.withValue { count -> Int in
        defer { count += 1 }
        return count
      }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: rowsForPoll(poll))
    }
    server.onCommand = { url, clientFD in
      deeplinks.withValue { $0.append(url.absoluteString) }
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: true, error: nil)
    }
    defer {
      server.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }

    try await body(
      { try await Self.runCLI(arguments: $0, environment: environment, socketPath: socketPath) }, resources,
      deeplinks)
    #expect(
      resources.value.allSatisfy {
        ["agents", "agentRead", "agentExplain"].contains($0) || $0.contains(" taskID=") || $0.contains(" surfaceID=")
      })
  }

  private static func runCLI(
    arguments: [String], environment: [String: String] = [:], socketPath: String
  ) async throws -> Run {
    let executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    try #require(FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false)))
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    // The test's own terminal may run inside a task; the fixture decides the task.
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["SUPACODE_SOCKET_PATH": socketPath, "SUPACODE_TASK_ID": ""].merging(
        environment, uniquingKeysWith: { _, given in given }),
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
