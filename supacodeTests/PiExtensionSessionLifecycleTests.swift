import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct PiExtensionSessionLifecycleTests {
  @Test func generatedExtensionEmitsSessionIdentityAndOnlyOneShutdownSignal() throws {
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
    let fixture = """
      const handlers = new Map();
      extension({ on: (name, handler) => handlers.set(name, handler) });
      const ctx = { sessionManager: { getSessionId: () => "session-1", getEntries: () => [] } };
      handlers.get("session_start")({}, ctx);
      handlers.get("agent_start")({}, ctx);
      handlers.get("agent_end")({}, ctx);
      for (const reason of ["quit", "reload", "new", "resume", "fork", "unknown", "quit;sid=evil"]) {
        handlers.get("session_shutdown")({ reason }, ctx);
      }
      process.stdout.write(JSON.stringify(signals));
      """
    let runnable = source.replacing(
      "export default function (pi: ExtensionAPI)", with: "function extension(pi: ExtensionAPI)")
    try (runnable + "\n" + fixture).write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    let miseNode = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/mise/shims/node")
    process.executableURL = FileManager.default.isExecutableFile(atPath: miseNode.path)
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
    let events = try signals.compactMap { signal -> AgentHookEvent? in
      let payload = String(signal.dropFirst("\u{1b}]3008;".count).dropLast(2))
      let fields = try #require(AgentSignal.contextSignalFields(payload: payload))
      if fields.metadata.contains("kind=notify") { return nil }
      return try AgentSignal.presenceEvent(
        id: fields.id, metadata: fields.metadata, surfaceID: surface, surfaceExists: true).get()
    }
    #expect(events.map(\.event) == ["session_start", "busy", "idle"] + Array(repeating: "session_end", count: 7))
    #expect(events.allSatisfy { $0.sessionRef == "session-1" && $0.pid == nil })
    #expect(events.suffix(7).map(\.shutdownReason) == ["quit", "reload", "new", "resume", "fork", nil, nil])
  }
}
