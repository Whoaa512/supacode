import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Session-ref capture, persistence, and resume-command construction — the three
/// pure halves of the resume path. The wiring that types the command lives in
/// `AppFeature+AgentCommands` and needs a live surface, so it is not covered here.
@MainActor
struct AgentSessionResumeTests {
  // MARK: - Wire parse.

  @Test func parsesSessionRefFromPresenceMetadata() {
    let signal = AgentPresenceOSC.parse(
      id: "claude", metadata: "event=session_start;pid=4321;sid=abc-123_4.5")
    #expect(signal?.sessionRef == "abc-123_4.5")
    #expect(signal?.pid == 4321)
  }

  @Test func presenceSignalWithoutSessionRefReportsNil() {
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "event=busy")?.sessionRef == nil)
  }

  /// The ref reaches a terminal inside `claude --resume <ref>`, so anything that
  /// could break out of that command line must not survive the parse.
  @Test(arguments: [
    "a b", "a;b", "a$(id)", "a`id`", "a|b", "a&b", "a>b", "a'b", "a\"b", "a\nb", "../etc/passwd",
    // Charset-clean, but the agent's own CLI would read a leading `-` as a flag.
    "-rf", "--help", ".hidden", "",
  ])
  func rejectsUnsafeSessionRef(_ raw: String) {
    #expect(AgentPresenceOSC.sanitizedSessionRef(raw) == nil)
  }

  @Test func rejectsOverlongSessionRef() {
    let long = String(repeating: "a", count: AgentPresenceOSC.sessionRefByteBudget + 1)
    #expect(AgentPresenceOSC.sanitizedSessionRef(long) == nil)
    #expect(
      AgentPresenceOSC.sanitizedSessionRef(String(long.dropLast())) == String(long.dropLast()))
  }

  /// A spliced second `sid=` would otherwise decide which session a later resume
  /// relaunches, so a duplicate drops the whole signal (same rule as `event`).
  @Test func rejectsDuplicateSessionRefField() {
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;sid=one;sid=two") == nil)
  }

  // MARK: - Record capture.

  @Test func sessionStartRecordsSessionRef() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(event(.sessionStart, surfaceID: surfaceID, sessionRef: "sess-1")))
    #expect(harness.state.records[key(surfaceID)]?.sessionRef == "sess-1")
  }

  @Test func busyRecordsSessionRefForAgentsThatReportItPerTurn() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(event(.sessionStart, surfaceID: surfaceID, agent: .pi)))
    harness.send(
      .hookEventReceived(event(.busy, surfaceID: surfaceID, agent: .pi, sessionRef: "pi-42")))
    #expect(harness.state.records[key(surfaceID, agent: .pi)]?.sessionRef == "pi-42")
  }

  /// Most events carry no ref (a hook that reads stdin costs more), so an absent
  /// ref must never erase the session we'd resume.
  @Test func laterEventWithoutSessionRefKeepsTheStoredOne() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(event(.sessionStart, surfaceID: surfaceID, sessionRef: "sess-1")))
    harness.send(.hookEventReceived(event(.busy, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(event(.idle, surfaceID: surfaceID)))
    #expect(harness.state.records[key(surfaceID)]?.sessionRef == "sess-1")
  }

  @Test func unsafeSessionRefNeverReachesTheRecord() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(
      .hookEventReceived(event(.sessionStart, surfaceID: surfaceID, sessionRef: "a;rm -rf /")))
    #expect(harness.state.records[key(surfaceID)]?.sessionRef == nil)
  }

  // MARK: - Persistence round-trip.

  @Test func persistsSessionRefOnTheSurfaceRecord() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(event(.sessionStart, surfaceID: surfaceID, sessionRef: "sess-1")))
    let persisted = harness.state.agentsBySurface()[surfaceID]?.first
    #expect(persisted?.sessionRef == "sess-1")
    #expect(persisted?.resumeCandidate == nil)
  }

  /// Old layouts have no `sessionRef` / `resumeCandidate` keys; they must decode
  /// as before rather than throwing the whole leaf away.
  @Test func decodesLegacySurfaceAgentRecordWithoutResumeFields() throws {
    let json = #"{"agent":"claude","pids":[1],"activity":"busy"}"#
    let record = try JSONDecoder().decode(
      TerminalLayoutSnapshot.SurfaceAgentRecord.self, from: Data(json.utf8))
    #expect(record.sessionRef == nil)
    #expect(record.resumeCandidate == nil)
  }

  /// The core VC8 assertion: every persisted pid dead + a ref = a resume
  /// candidate, and no live record (which would badge a dead agent).
  @Test func deadPidsWithSessionRefBecomeAResumeCandidate() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.restoreFromLayouts([
      layout(surfaceID: surfaceID, record: record(pids: [Self.deadPid], sessionRef: "sess-1"))
    ])
    #expect(harness.state.records[key(surfaceID)] == nil)
    #expect(harness.state.resumeCandidates[key(surfaceID)]?.sessionRef == "sess-1")
  }

  @Test func deadPidsWithoutSessionRefAreNotCandidates() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.restoreFromLayouts([
      layout(surfaceID: surfaceID, record: record(pids: [Self.deadPid]))
    ])
    #expect(harness.state.resumeCandidates.isEmpty)
  }

  /// A pid-less record is an SSH-attached agent that may still be running on the
  /// far side, so restore must not offer to resume it.
  @Test func pidlessRecordIsNotAResumeCandidate() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.restoreFromLayouts([
      layout(surfaceID: surfaceID, record: record(pids: [], sessionRef: "sess-1"))
    ])
    #expect(harness.state.resumeCandidates.isEmpty)
    #expect(harness.state.records.isEmpty)
  }

  @Test func resumeCandidatesAreSkippedWhenTheSettingIsOff() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.restoreFromLayouts(
      [layout(surfaceID: surfaceID, record: record(pids: [Self.deadPid], sessionRef: "sess-1"))],
      offersResume: false
    )
    #expect(harness.state.resumeCandidates.isEmpty)
  }

  /// An agent with no resume-by-id CLI can't be acted on, so it never becomes an
  /// offer the user has to dismiss.
  @Test func agentWithoutResumeCommandIsNotACandidate() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.restoreFromLayouts([
      layout(
        surfaceID: surfaceID,
        record: record(agent: .kiro, pids: [Self.deadPid], sessionRef: "sess-1"))
    ])
    #expect(harness.state.resumeCandidates.isEmpty)
  }

  /// A candidate the user never resumed survives further relaunches, which needs
  /// the explicit flag: without it the re-persisted pid-less record would read as
  /// an SSH agent and be dropped.
  @Test func unresumedCandidateRoundTripsThroughAnotherRestore() {
    var first = Harness()
    let surfaceID = UUID()
    first.restoreFromLayouts([
      layout(surfaceID: surfaceID, record: record(pids: [Self.deadPid], sessionRef: "sess-1"))
    ])
    let persisted = first.state.agentsBySurface()[surfaceID]
    #expect(persisted?.first?.resumeCandidate == true)
    #expect(persisted?.first?.pids.isEmpty == true)

    var second = Harness()
    second.restoreFromLayouts([
      TerminalLayoutSnapshotTestFactory.layout(surfaceID: surfaceID, agents: persisted ?? [])
    ])
    #expect(second.state.resumeCandidates[key(surfaceID)]?.sessionRef == "sess-1")
  }

  /// The agent came back on its own, so the offer is stale: resuming again would
  /// fork the session.
  @Test func liveHookEventClearsTheResumeCandidate() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.restoreFromLayouts([
      layout(surfaceID: surfaceID, record: record(pids: [Self.deadPid], sessionRef: "sess-1"))
    ])
    #expect(harness.state.resumeCandidates.count == 1)
    harness.send(.hookEventReceived(event(.sessionStart, surfaceID: surfaceID, pid: 1)))
    #expect(harness.state.resumeCandidates.isEmpty)
    #expect(harness.state.records[key(surfaceID)] != nil)
  }

  @Test func consumingTheOfferDropsTheCandidate() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.restoreFromLayouts([
      layout(surfaceID: surfaceID, record: record(pids: [Self.deadPid], sessionRef: "sess-1"))
    ])
    harness.send(.resumeCandidateConsumed(key: key(surfaceID)))
    #expect(harness.state.resumeCandidates.isEmpty)
  }

  /// Closing the surface takes the offer with it: there is nowhere left to type.
  @Test func closingTheSurfaceDropsTheCandidate() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.restoreFromLayouts([
      layout(surfaceID: surfaceID, record: record(pids: [Self.deadPid], sessionRef: "sess-1"))
    ])
    harness.send(.surfaceClosed(surfaceID))
    #expect(harness.state.resumeCandidates.isEmpty)
  }

  // MARK: - Resume command construction.

  @Test(arguments: [
    (SkillAgent.claude, "claude --resume sess-1"),
    (SkillAgent.pi, "pi --session sess-1"),
    (SkillAgent.codex, "codex resume sess-1"),
  ])
  func buildsNativeResumeCommand(_ agent: SkillAgent, _ expected: String) {
    #expect(AgentResumeCommand.command(agent: agent, sessionRef: "sess-1") == expected)
  }

  @Test(arguments: [
    SkillAgent.copilot, .grok, .hermes, .kimi, .kiro, .omp, .opencode,
  ])
  func reportsNoCommandForAgentsWithoutResumeByID(_ agent: SkillAgent) {
    #expect(AgentResumeCommand.command(agent: agent, sessionRef: "sess-1") == nil)
  }

  /// Last hop before the ref becomes terminal input, so it re-validates rather
  /// than trusting state that was seeded from an unauthenticated OSC signal.
  @Test func refusesToBuildACommandForAnUnsafeRef() {
    #expect(AgentResumeCommand.command(agent: .claude, sessionRef: "x; rm -rf /") == nil)
  }

  @Test func supportedAgentsAreTheThreeWithResumeCLIs() {
    #expect(AgentResumeCommand.supportedAgents == [.claude, .codex, .pi])
  }

  // MARK: - Query exposure.

  @Test func explainRowCarriesTheSessionRef() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(event(.sessionStart, surfaceID: surfaceID, sessionRef: "sess-1")))
    let row = AgentExplainQueryResponse.row(key: key(surfaceID), presence: harness.state)
    #expect(row?[AgentExplainQueryResponse.Key.sessionRef] == "sess-1")
  }

  @Test func explainRowReportsAnEmptySessionRefWhenNoneWasCaptured() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(event(.sessionStart, surfaceID: surfaceID)))
    let row = AgentExplainQueryResponse.row(key: key(surfaceID), presence: harness.state)
    #expect(row?[AgentExplainQueryResponse.Key.sessionRef] == "")
  }

  // MARK: - Emitted hook shape.

  /// The shell probe is the first line of defence for a hostile hook payload, so
  /// it must delete unsafe bytes rather than quote them.
  @Test func sessionRefProbeSanitizesInShell() {
    let probe = AgentPresenceOSC.sessionRefProbeShell()
    #expect(probe.contains("tr -cd 'A-Za-z0-9._-'"))
    #expect(probe.contains("cut -b 1-\(AgentPresenceOSC.sessionRefByteBudget)"))
  }

  @Test(arguments: [SkillAgent.claude, .codex])
  func sessionStartHookCapturesTheSessionRef(_ agent: SkillAgent) throws {
    let hooks = try agent == .claude
      ? ClaudeHookSettings.hooksByEvent() : CodexHookSettings.hooksByEvent()
    let command = try #require(Self.command(in: hooks, event: "SessionStart"))
    #expect(command.contains("__sid="))
    #expect(command.contains(";\(AgentPresenceOSC.sessionField)=$__sid"))
  }

  /// A hook that already read stdin must not `cat` again: the pipe is exhausted
  /// and the second read would block until the hook timeout.
  @Test func sessionRefCaptureAndNotifyShareOneStdinRead() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionStart], forwardStdinAsNotification: true, agent: .claude,
      capturesSessionRef: true)
    #expect(command.components(separatedBy: "__in=$(cat)").count == 2)
  }

  @Test func piExtensionEmitsTheSessionRefOnBusy() {
    #expect(PiExtensionContent.indexTs.contains("getSessionId"))
    #expect(PiExtensionContent.indexTs.contains("emitPresence(\"busy\", sessionRef(ctx))"))
    #expect(PiExtensionContent.indexTs.contains("/^[A-Za-z0-9][A-Za-z0-9._-]*$/"))
  }

  // MARK: - Helpers.

  /// A pid that cannot be alive: `kill(2)` on it always fails, so restore
  /// classifies the record as dead without depending on the host's process table.
  private static let deadPid: Int32 = 0x7FFF_FFFE

  private static func command(in hooks: [String: [JSONValue]], event: String) -> String? {
    hooks[event]?.first?.objectValue?["hooks"]?.arrayValue?.first?
      .objectValue?["command"]?.stringValue
  }

  private func key(_ surfaceID: UUID, agent: SkillAgent = .claude) -> AgentPresenceFeature
    .PresenceKey
  {
    AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: surfaceID)
  }

  private func event(
    _ name: AgentHookEvent.EventName,
    surfaceID: UUID,
    agent: SkillAgent = .claude,
    pid: pid_t? = nil,
    sessionRef: String? = nil
  ) -> AgentHookEvent {
    AgentHookEvent(
      agent: agent.rawValue, event: name.rawValue, surfaceID: surfaceID, pid: pid,
      sessionRef: sessionRef)
  }

  private func record(
    agent: SkillAgent = .claude,
    pids: [Int32],
    activity: String = "idle",
    sessionRef: String? = nil,
    resumeCandidate: Bool? = nil
  ) -> TerminalLayoutSnapshot.SurfaceAgentRecord {
    TerminalLayoutSnapshot.SurfaceAgentRecord(
      agent: agent.rawValue, pids: pids, activity: activity, doneUnseen: nil,
      sessionRef: sessionRef, resumeCandidate: resumeCandidate)
  }

  private func layout(
    surfaceID: UUID, record: TerminalLayoutSnapshot.SurfaceAgentRecord
  ) -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshotTestFactory.layout(surfaceID: surfaceID, agents: [record])
  }

  /// Direct-reducer harness. Mirrors `AgentPresenceFeatureTests.Harness`, with
  /// the restore split reproduced so the resume-candidate branch is exercised
  /// without the off-main hop.
  private struct Harness {
    var state = AgentPresenceFeature.State()
    private let reducer = AgentPresenceFeature()

    @MainActor mutating func send(_ action: AgentPresenceFeature.Action) {
      _ = reducer.reduce(into: &state, action: action)
    }

    @MainActor mutating func restoreFromLayouts(
      _ layouts: [TerminalLayoutSnapshot],
      offersResume: Bool = true
    ) {
      let staged = AgentPresenceFeature.stageRestore(fromLayouts: layouts)
      var checked: [AgentPresenceFeature.PresenceKey: AgentPresenceFeature.RestoredRecord] = [:]
      var candidates: [AgentPresenceFeature.PresenceKey: AgentPresenceFeature.ResumeCandidate] = [:]
      for (key, stage) in staged {
        let alive = stage.pids.filter { AgentPresenceFeature.isAlive($0) }
        guard alive.isEmpty else {
          checked[key] = AgentPresenceFeature.RestoredRecord(
            alivePids: alive, activity: stage.activity, isDoneUnseen: stage.isDoneUnseen,
            sessionRef: stage.sessionRef)
          continue
        }
        guard offersResume, let ref = stage.sessionRef,
          AgentResumeCommand.command(agent: key.agent, sessionRef: ref) != nil
        else { continue }
        candidates[key] = AgentPresenceFeature.ResumeCandidate(
          sessionRef: ref, lastActivity: stage.activity)
      }
      send(.restoreFromSnapshotChecked(records: checked, resumeCandidates: candidates))
    }
  }
}

/// Single-leaf layout builder shared by the resume suites.
enum TerminalLayoutSnapshotTestFactory {
  static func layout(
    surfaceID: UUID, agents: [TerminalLayoutSnapshot.SurfaceAgentRecord]
  ) -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot(
              id: surfaceID, workingDirectory: nil, agents: agents)),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
  }
}
