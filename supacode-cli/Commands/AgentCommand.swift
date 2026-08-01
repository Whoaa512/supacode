import ArgumentParser
import Darwin
import Foundation

struct AgentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agent",
    abstract: "Inspect, name, and wait on running coding agents.",
    subcommands: [
      List.self,
      Rename.self,
      Wait.self,
    ],
    defaultSubcommand: List.self
  )
}

// MARK: - Wire contract.

extension AgentCommand {
  /// Socket wire keys. Mirrors `AgentQueryResponse.Key` (app side); keep in sync
  /// (the CLI links no shared module to stay dependency-light).
  nonisolated enum Key {
    static let name = "name"
    static let agent = "agent"
    static let activity = "activity"
    static let state = "state"
    static let worktreeID = "worktreeID"
    static let branch = "branch"
    static let repo = "repo"
    static let worktreeTitle = "worktreeTitle"

    /// Column order for human-readable output and the JSON row.
    static let all = [name, agent, state, activity, repo, branch, worktreeTitle, worktreeID]
  }

  /// Mirrors `AgentDashboardState.wireValue` (app side); keep in sync.
  nonisolated enum AgentState: String, CaseIterable {
    case blocked
    case working
    case done
    case idle
    case unknown

    static let allValues = AgentState.allCases.map(\.rawValue).joined(separator: "|")

    /// Default `--until` set: every state where the agent has stopped working.
    static let settled: Set<AgentState> = [.idle, .done, .blocked]
  }

  /// Why a target failed to resolve. `notRunning` is distinct so `agent wait`
  /// can tell "the named agent exited" from "that name never existed".
  nonisolated enum TargetError: Error, CustomStringConvertible {
    case notFound(String)
    case notRunning(String)
    case ambiguous(target: String, candidates: [String])

    var description: String {
      switch self {
      case .notFound(let target):
        return "No running agent matches '\(target)'. Run `supacode agent list` to see live agents."
      case .notRunning(let target):
        return "agent_not_running: '\(target)' is no longer running."
      case .ambiguous(let target, let candidates):
        return "'\(target)' matches several agents. Disambiguate with --agent <kind>:\n"
          + candidates.map { "  \($0)" }.joined(separator: "\n")
      }
    }
  }

  /// Resolves a target to exactly one row. An exact live-name match wins, so a
  /// named agent is addressable even when its worktree hosts several kinds.
  static func resolve(
    target: String,
    agentKind: String?,
    in rows: [[String: String]]
  ) throws -> [String: String] {
    if let named = rows.first(where: { !($0[Key.name] ?? "").isEmpty && $0[Key.name] == target }) {
      return named
    }
    let decodedTarget = decoded(target)
    let matches = rows.filter { row in
      guard agentKind == nil || row[Key.agent] == agentKind else { return false }
      let id = decoded(row[Key.worktreeID] ?? "")
      return id == decodedTarget || row[Key.branch] == target || row[Key.worktreeTitle] == target
    }
    guard let first = matches.first else { throw TargetError.notFound(target) }
    guard matches.count == 1 else {
      throw TargetError.ambiguous(
        target: target,
        candidates: matches.map { row in
          let name = row[Key.name] ?? ""
          let kind = row[Key.agent] ?? ""
          return name.isEmpty ? kind : "\(kind) (\(name))"
        }
      )
    }
    return first
  }

  /// Percent-decodes and drops a trailing slash so encoded and decoded worktree
  /// IDs compare equal.
  private static func decoded(_ value: String) -> String {
    let decoded = value.removingPercentEncoding ?? value
    return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
  }

  /// Tab-separated columns, with unnamed agents rendered as `-` so the column
  /// never collapses. Blocked rows are underlined on a TTY.
  static func listLine(_ row: [String: String]) -> String {
    let name = row[Key.name] ?? ""
    let columns = [
      name.isEmpty ? "-" : name,
      row[Key.agent] ?? "",
      row[Key.state] ?? "",
      row[Key.repo] ?? "",
      row[Key.branch] ?? "",
      row[Key.worktreeID] ?? "",
    ]
    let text = columns.map(ListFormatting.sanitizeColumn).joined(separator: "\t")
    return ListFormatting.line(text, focused: row[Key.state] == AgentState.blocked.rawValue)
  }

  /// Single-line JSON with a fixed key order, so `agent wait` output is diffable
  /// without pulling in a JSON dependency on the read side.
  static func jsonLine(_ row: [String: String]) -> String {
    let fields = Key.all.map { key in
      "\"\(key)\":\(quoted(row[key] ?? ""))"
    }
    return "{\(fields.joined(separator: ","))}"
  }

  private static func quoted(_ value: String) -> String {
    let escaped = value
      .replacing("\\", with: "\\\\")
      .replacing("\"", with: "\\\"")
      .replacing("\n", with: "\\n")
      .replacing("\t", with: "\\t")
      .replacing("\r", with: "\\r")
    return "\"\(escaped)\""
  }

  static func parsedStates(_ values: [String]) throws -> Set<AgentState> {
    guard !values.isEmpty else { return AgentState.settled }
    return try Set(
      values.map { raw in
        guard let state = AgentState(rawValue: raw) else {
          throw ValidationError("Unknown state '\(raw)'. Expected one of: \(AgentState.allValues).")
        }
        return state
      }
    )
  }
}

// MARK: - Subcommands.

extension AgentCommand {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List running agents: name, kind, state, repo, branch, worktree ID."
    )

    @Flag(name: .long, help: "Print one JSON object per agent instead of columns.")
    var json = false

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let rows = try QueryDispatcher.query(resource: "agents", timeoutSeconds: timeoutOption.timeout)
      for row in rows {
        print(json ? AgentCommand.jsonLine(row) : AgentCommand.listLine(row))
      }
    }
  }

  struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Name a running agent so `--until` waits and other commands can address it."
    )

    @Argument(help: "Agent name, worktree ID, or branch.")
    var target: String

    @Argument(help: "New name: 1–32 characters matching [a-z][a-z0-9_-]*. Omit with --clear.")
    var name: String?

    @Flag(name: .long, help: "Clear the agent's name.")
    var clear = false

    @Option(name: .long, help: "Agent kind, to disambiguate a worktree running several agents.")
    var agent: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      guard clear != (name != nil) else {
        throw ValidationError("Pass either a name or --clear, not both.")
      }
    }

    func run() throws {
      let rows = try QueryDispatcher.query(resource: "agents", timeoutSeconds: timeoutOption.timeout)
      let row = try AgentCommand.resolve(target: target, agentKind: agent, in: rows)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.agentRename(
          worktreeID: row[Key.worktreeID] ?? "",
          agent: row[Key.agent] ?? "",
          name: clear ? nil : name
        ),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Block until an agent settles, then print its row as JSON."
    )

    @Argument(help: "Agent name, worktree ID, or branch.")
    var target: String

    @Option(
      name: .long,
      help: "State to wait for, repeatable: \(AgentState.allValues). Defaults to idle, done, and blocked."
    )
    var until: [String] = []

    @Option(name: .long, help: "Give up after this many seconds. 0 waits indefinitely.")
    var timeout: Int = 900

    @Option(name: .long, help: "Agent kind, to disambiguate a worktree running several agents.")
    var agent: String?

    /// Poll interval. Presence state is push-updated app-side, so this only
    /// bounds how stale the CLI's view can be.
    private static let pollInterval: TimeInterval = 0.5

    /// Per-poll socket read budget. Deliberately not `--timeout`: that flag is
    /// the wait deadline here, which can legitimately be hours.
    private static let queryTimeoutSeconds = 30

    func validate() throws {
      guard timeout >= 0 else { throw ValidationError("--timeout cannot be negative.") }
      _ = try AgentCommand.parsedStates(until)
    }

    func run() throws {
      let wanted = try AgentCommand.parsedStates(until)
      let deadline = timeout > 0 ? Date().addingTimeInterval(TimeInterval(timeout)) : Date.distantFuture
      // A name that resolved once and then stops resolving means the agent
      // exited; that is a different failure from a target that never existed.
      var everResolved = false

      while true {
        let rows = try QueryDispatcher.query(
          resource: "agents", timeoutSeconds: Self.queryTimeoutSeconds)
        do {
          let row = try AgentCommand.resolve(target: target, agentKind: agent, in: rows)
          everResolved = true
          let state = AgentState(rawValue: row[Key.state] ?? "") ?? .unknown
          if wanted.contains(state) {
            print(AgentCommand.jsonLine(row))
            return
          }
        } catch AgentCommand.TargetError.notFound(let target) where everResolved {
          throw AgentCommand.TargetError.notRunning(target)
        }
        guard Date().addingTimeInterval(Self.pollInterval) < deadline else {
          let states = wanted.map(\.rawValue).sorted().joined(separator: "|")
          throw SocketClient.Error.responseError(
            "Timed out after \(timeout)s waiting for '\(target)' to reach \(states)."
          )
        }
        Thread.sleep(forTimeInterval: Self.pollInterval)
      }
    }
  }
}
