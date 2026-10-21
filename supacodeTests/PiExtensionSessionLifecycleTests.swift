import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct PiExtensionSessionLifecycleTests {
  /// Runs the generated extension under node with the terminal write
  /// replaced by a recorder, drives it with `fixture`, and returns the
  /// presence events it emitted. `fixture` sees `handlers` (event name to
  /// handler) and `ctx(id)`, which makes a session context with a stable
  /// session manager per id.
  private func presenceEvents(fixture: String) throws -> [AgentHookEvent] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("lifecycle.mts")
    let source = PiExtensionContent.indexTs.replacing(
      "import { openSync, writeSync, closeSync } from \"node:fs\";",
      with: """
        const signals: string[] = [];
        const openSync = () => 1;
        const closeSync = () => {};
        const writeSync = (_fd: number, bytes: Buffer, offset: number, count: number) => {
          signals.push(bytes.subarray(offset, offset + count).toString());
          return count;
        };
        """)
    let prelude = """
      const handlers = new Map();
      extension({ on: (name, handler) => handlers.set(name, handler) });
      const managers = new Map();
      const ctx = (id) => {
        if (!managers.has(id)) managers.set(id, { getSessionId: () => id, getEntries: () => [] });
        return { sessionManager: managers.get(id) };
      };
      """
    let epilogue = "process.stdout.write(JSON.stringify(signals));"
    let runnable = source.replacing(
      "export default function (pi: ExtensionAPI)", with: "function extension(pi: ExtensionAPI)")
    try [runnable, prelude, fixture, epilogue].joined(separator: "\n")
      .write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    let miseNode = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/mise/shims/node")
    process.executableURL =
      FileManager.default.isExecutableFile(atPath: miseNode.path)
      ? miseNode : try LoginShellProbe.executable("node")
    process.arguments = ["--experimental-strip-types", script.path]
    var environment = ProcessInfo.processInfo.environment
    environment["SUPACODE_SURFACE_ID"] = "fixture"
    environment["SUPACODE_SOCKET_PATH"] = nil
    process.environment = environment
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, "\(errorText)")
    let signals = try JSONDecoder().decode([String].self, from: data)
    let surface = UUID()
    return try signals.compactMap { signal -> AgentHookEvent? in
      let payload = String(signal.dropFirst("\u{1b}]3008;".count).dropLast(2))
      let fields = try #require(AgentSignal.contextSignalFields(payload: payload))
      if fields.metadata.contains("kind=notify") { return nil }
      return try AgentSignal.presenceEvent(
        id: fields.id, metadata: fields.metadata, surfaceID: surface, surfaceExists: true
      ).get()
    }
  }

  @Test func generatedExtensionEmitsSessionIdentityAndOnlyOneShutdownSignal() throws {
    let events = try presenceEvents(
      fixture: """
        handlers.get("session_start")({}, ctx("session-1"));
        handlers.get("agent_start")({}, ctx("session-1"));
        handlers.get("agent_end")({}, ctx("session-1"));
        handlers.get("session_shutdown")({ reason: "quit" }, ctx("session-1"));
        handlers.get("session_shutdown")({ reason: "quit" }, ctx("session-1"));
        """)
    #expect(events.map(\.event) == ["session_start", "busy", "idle", "session_end"])
    #expect(events.allSatisfy { $0.sessionRef == "session-1" && $0.pid == nil })
    #expect(events.last?.shutdownReason == "quit")
  }

  @Test func aPromptToolReportsAwaitingInputUntilItReturnsAndOtherToolsStaySilent() throws {
    let events = try presenceEvents(
      fixture: """
        handlers.get("session_start")({}, ctx("session-1"));
        handlers.get("agent_start")({}, ctx("session-1"));
        handlers.get("tool_execution_start")({ toolName: "bash" }, ctx("session-1"));
        handlers.get("tool_execution_end")({ toolName: "bash" }, ctx("session-1"));
        handlers.get("tool_execution_start")({ toolName: "question" }, ctx("session-1"));
        handlers.get("tool_execution_end")({ toolName: "question" }, ctx("session-1"));
        handlers.get("tool_execution_start")({ toolName: "questionnaire" }, ctx("session-2"));
        handlers.get("agent_end")({}, ctx("session-1"));
        """)
    #expect(events.map(\.event) == ["session_start", "busy", "awaiting_input", "busy", "idle"])
    #expect(events.map(\.prompt) == [nil, nil, "question", nil, nil])
    #expect(events.allSatisfy { $0.sessionRef == "session-1" })
  }

  @Test func shutdownReasonsReachTheWireAsPiNamesThem() throws {
    let events = try presenceEvents(
      fixture: """
        for (const reason of ["quit", "reload", "new", "resume", "fork", "unknown", "quit;sid=evil"]) {
          handlers.get("session_start")({}, ctx(reason));
          handlers.get("session_shutdown")({ reason }, ctx(reason));
        }
        """)
    let ends = events.filter { $0.event == "session_end" }
    #expect(ends.count == 7)
    #expect(ends.map(\.shutdownReason) == ["quit", "reload", "new", "resume", "fork", nil, nil])
  }

  /// Pi's reload awaits resource loading between the owner's shutdown and
  /// the next session_start, so a sub-agent turn can land while the surface
  /// is unowned. Only session_start may claim it; the child stays silent and
  /// the parent resumes reporting.
  @Test func aNestedSessionCannotClaimTheSurfaceBetweenShutdownAndTheNextStart() throws {
    let events = try presenceEvents(
      fixture: """
        handlers.get("session_start")({}, ctx("parent"));
        handlers.get("session_shutdown")({ reason: "reload" }, ctx("parent"));
        handlers.get("agent_start")({}, ctx("child"));
        handlers.get("agent_end")({}, ctx("child"));
        handlers.get("session_shutdown")({ reason: "quit" }, ctx("child"));
        handlers.get("session_start")({}, ctx("parent"));
        handlers.get("agent_start")({}, ctx("child"));
        handlers.get("agent_start")({}, ctx("parent"));
        """)
    #expect(events.map(\.event) == ["session_start", "session_end", "session_start", "busy"])
    #expect(events.allSatisfy { $0.sessionRef == "parent" })
  }

  /// The `workflow` tool runs sub-agent sessions inside the Pi process, each
  /// with its own session manager and no session_start. Their turns must not
  /// reach the surface while the session that owns it is live.
  @Test func aSessionNestedInTheProcessReportsNothingWhileTheOwnerIsLive() throws {
    let events = try presenceEvents(
      fixture: """
        handlers.get("session_start")({}, ctx("parent"));
        handlers.get("agent_start")({}, ctx("parent"));
        handlers.get("agent_start")({}, ctx("child-1"));
        handlers.get("agent_start")({}, ctx("child-2"));
        handlers.get("agent_end")({}, ctx("child-1"));
        handlers.get("session_shutdown")({ reason: "quit" }, ctx("child-1"));
        handlers.get("agent_end")({}, ctx("child-2"));
        handlers.get("agent_end")({}, ctx("parent"));
        """)
    #expect(events.map(\.event) == ["session_start", "busy", "idle"])
    #expect(events.allSatisfy { $0.sessionRef == "parent" })
  }

  /// Pi ends a session before it starts the next one in the same process, so
  /// the owner's shutdown hands the surface to whichever session starts next.
  @Test func theSessionAfterTheOwnersShutdownTakesOverTheSurface() throws {
    let events = try presenceEvents(
      fixture: """
        handlers.get("session_start")({}, ctx("first"));
        handlers.get("session_shutdown")({ reason: "new" }, ctx("first"));
        handlers.get("session_start")({}, ctx("second"));
        handlers.get("agent_start")({}, ctx("first"));
        handlers.get("agent_start")({}, ctx("second"));
        """)
    #expect(events.map(\.event) == ["session_start", "session_end", "session_start", "busy"])
    #expect(events.map(\.sessionRef) == ["first", "first", "second", "second"])
  }
}
