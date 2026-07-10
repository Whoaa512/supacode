import Foundation
import Testing

@testable import supacode

/// Fixture-backed extraction coverage: the replay corpus is the Phase 0
/// measurement harness, so these tests double as the extraction scorecard gate.
struct AttentionExtractionTests {
  private static var fixturesDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Attention", isDirectory: true)
  }

  private static func corpus(_ name: String) throws -> ReplayCorpus {
    let url = fixturesDirectory.appendingPathComponent("\(name).json")
    return try ReplayCorpus.decode(from: Data(contentsOf: url))
  }

  private let engine = AttentionExtractionEngine.hookBased()

  // MARK: - Corpus loading.

  @Test func loadsAllFixtureCorpora() throws {
    let corpora = try ReplayCorpus.loadAll(from: Self.fixturesDirectory)
    #expect(corpora.count == 3)
    // Deterministic, name-sorted order.
    #expect(corpora.map(\.name) == ["claude-explicit-input", "dedup-and-order", "pi-failures"])
  }

  // MARK: - Parsing / classification.

  @Test func extractsExplicitInputAndCompletionFromClaudeCorpus() throws {
    let corpus = try Self.corpus("claude-explicit-input")
    let candidates = engine.extract(from: corpus)

    #expect(candidates.map(\.kind) == [.explicitInputRequested, .agentCompleted])

    let input = try #require(candidates.first)
    #expect(input.question == "Migration will drop the legacy column. Proceed?")
    #expect(input.options.map(\.id) == ["yes", "no"])
    #expect(input.isActionable)
    #expect(input.isGrounded)
    #expect(input.evidence.first?.kind == .diff)
  }

  @Test func classifiesPiFailureNotifications() throws {
    let corpus = try Self.corpus("pi-failures")
    let candidates = engine.extract(from: corpus)

    #expect(
      candidates.map(\.kind) == [
        .testsFailed, .commandFailed, .permissionRequested, .agentExitedUnexpectedly,
      ])
    // Unclassified "progress" chatter must not produce a candidate.
    #expect(!candidates.contains { $0.sourceEventID == "pi-4-chatter" })
  }

  @Test func nonAttentionLifecycleEventsProduceNoCandidate() throws {
    let corpus = try Self.corpus("claude-explicit-input")
    let candidates = engine.extract(from: corpus)
    let sources = Set(candidates.map(\.sourceEventID))
    #expect(!sources.contains("claude-1-start"))
    #expect(!sources.contains("claude-2-busy"))
    #expect(!sources.contains("claude-4-idle"))
  }

  // MARK: - Idempotency & ordering.

  @Test func duplicateDeliveryCollapsesToOneCandidate() throws {
    let corpus = try Self.corpus("dedup-and-order")
    let candidates = engine.extract(from: corpus)
    #expect(candidates.filter { $0.sourceEventID == "dup-await" }.count == 1)
  }

  @Test func replayIsDeterministicRegardlessOfOrder() throws {
    let corpus = try Self.corpus("dedup-and-order")
    let first = engine.extract(from: corpus)

    let reversed = ReplayCorpusFixture.withEvents(corpus, corpus.events.reversed())
    let second = engine.extract(from: reversed)

    #expect(first == second)
    #expect(first.map(\.kind) == [.explicitInputRequested])
  }

  // MARK: - Malformed / unknown handling.

  @Test func truncatedJSONFailsToDecode() {
    let truncated = Data(#"{"name":"broken","agent":"pi","events":[{"source"#.utf8)
    #expect(throws: (any Error).self) {
      try ReplayCorpus.decode(from: truncated)
    }
  }

  @Test func unknownEventNameProducesNoCandidate() {
    let event = AgentHookEvent(
      agent: "pi", event: "some_future_event",
      surfaceID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
    let normalized = NormalizedAgentEvent(
      sourceEventID: "x", sessionID: SessionID("s"), occurredAt: .distantPast, raw: event)
    #expect(HookEventAdapter(agent: .pi).candidate(from: normalized) == nil)
  }

  @Test func eventsWithoutRegisteredAdapterAreSkipped() throws {
    let corpus = try Self.corpus("claude-explicit-input")
    let piOnly = AttentionExtractionEngine(adapters: [HookEventAdapter(agent: .pi)])
    #expect(piOnly.extract(from: corpus).isEmpty)
  }

  // MARK: - Scorecard.

  @Test func scorecardMeetsPrecisionRecallBarAcrossCorpus() throws {
    let corpora = try ReplayCorpus.loadAll(from: Self.fixturesDirectory)
    let scored = corpora.map { (corpus: $0, candidates: engine.extract(from: $0)) }
    let scorecard = ExtractionScorecard.score(corpora: scored)

    #expect(scorecard.precision == 1.0)
    #expect(scorecard.recall == 1.0)
    #expect(scorecard.kindMismatches == 0)
    #expect(scorecard.grounding > 0)
    #expect(scorecard.report().contains("Precision"))
  }
}

/// Test-only helper to rebuild a corpus with reordered events, decoded via JSON
/// so the raw events keep their exact wire shape.
private enum ReplayCorpusFixture {
  static func withEvents(_ corpus: ReplayCorpus, _ events: [ReplayEvent]) -> ReplayCorpus {
    ReplayCorpus(name: corpus.name, agent: corpus.agent, events: events)
  }
}
