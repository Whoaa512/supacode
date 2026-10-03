import ArgumentParser
import Foundation

struct SessionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "session",
    abstract: "Inspect and settle harness sessions.",
    subcommands: [List.self, Settle.self, Unsettle.self],
    defaultSubcommand: List.self
  )
}

extension SessionCommand {
  nonisolated enum Key {
    static let id = "id"
    static let title = "title"
    static let cwd = "cwd"
    static let lifecycle = "lifecycle"
    static let live = "live"
    static let status = "status"
    static let branch = "branch"
    static let surfaceID = "surfaceID"
    static let all = [id, title, cwd, lifecycle, live, status, branch, surfaceID]
  }

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List known sessions.")

    @Flag(name: .long, help: "Print one JSON object per session instead of columns.")
    var json = false

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let rows = try QueryDispatcher.query(resource: "sessions", timeoutSeconds: timeoutOption.timeout)
      for row in rows {
        print(json ? SessionCommand.jsonLine(row) : SessionCommand.listLine(row))
      }
    }
  }

  struct Settle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Settle a session without closing anything.")

    @Argument(help: "Session id (harness:id). Defaults to $SUPACODE_SURFACE_ID.")
    var session: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      try SessionCommand.dispatch(action: "settle", explicitSession: session, timeout: timeoutOption.timeout)
    }
  }

  struct Unsettle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unsettle a session.")

    @Argument(help: "Session id (harness:id). Defaults to $SUPACODE_SURFACE_ID.")
    var session: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      try SessionCommand.dispatch(action: "unsettle", explicitSession: session, timeout: timeoutOption.timeout)
    }
  }

  static func dispatch(action: String, explicitSession: String?, timeout: Int) throws {
    let id = try resolveSessionID(explicitSession, timeout: timeout)
    try Dispatcher.dispatch(
      deeplinkURL: DeeplinkURLBuilder.sessionAction(id: id, action: action),
      timeoutSeconds: timeout
    )
  }

  static func resolveSessionID(_ explicit: String?, timeout: Int) throws -> String {
    if let explicit, !explicit.isEmpty { return explicit }
    guard let surfaceID = EnvironmentDefaults.surfaceID, !surfaceID.isEmpty else {
      throw ValidationError(
        "Missing session id. Pass a harness:id or run inside a Supacode surface ($SUPACODE_SURFACE_ID)."
      )
    }
    let rows = try QueryDispatcher.query(resource: "sessions", timeoutSeconds: timeout)
    let matches = rows.filter { $0[Key.surfaceID] == surfaceID }
    guard let first = matches.first else {
      throw ValidationError(
        "No session is attached to this surface. Run `supacode session list` to choose one."
      )
    }
    guard matches.count == 1 else {
      let ids = matches.compactMap { $0[Key.id] }.joined(separator: ", ")
      throw ValidationError("Multiple sessions are attached to this surface. Pass one explicitly: \(ids)")
    }
    return first[Key.id] ?? ""
  }

  static func listLine(_ row: [String: String]) -> String {
    let live = (row[Key.live] ?? "").isEmpty ? "dormant" : "live"
    let columns = [
      row[Key.id] ?? "",
      row[Key.lifecycle] ?? "",
      live,
      row[Key.branch] ?? "",
      row[Key.title] ?? "",
      row[Key.cwd] ?? "",
    ]
    return ListFormatting.line(
      columns.map(ListFormatting.sanitizeColumn).joined(separator: "\t"), focused: false)
  }

  static func jsonLine(_ row: [String: String]) -> String {
    var parts: [String] = []
    for key in Key.all {
      guard let value = row[key], !value.isEmpty else { continue }
      parts.append("\"\(escapeJSON(key))\":\"\(escapeJSON(value))\"")
    }
    return "{\(parts.joined(separator: ","))}"
  }

  private static func escapeJSON(_ value: String) -> String {
    var output = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\": output += "\\\\"
      case "\"": output += "\\\""
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      default: output.unicodeScalars.append(scalar)
      }
    }
    return output
  }
}
