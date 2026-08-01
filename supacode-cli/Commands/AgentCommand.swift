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
      Prompt.self,
      SendKeys.self,
      Read.self,
      ReportMetadata.self,
      Explain.self,
      Resume.self,
      ResumeCandidates.self,
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
    static let sessionRef = "sessionRef"

    /// Column order for human-readable output and the JSON row.
    static let all = [
      name, agent, state, activity, repo, branch, worktreeTitle, worktreeID, sessionRef,
    ]

    /// Metadata tokens arrive flattened as `token.<key>` (see
    /// `AgentQueryResponse.Key.tokenPrefix`).
    static let tokenPrefix = "token."
  }

  /// Socket wire keys of the `agentResumeCandidates` query. Mirrors
  /// `AgentResumeCandidateQueryResponse.Key` (app side); keep in sync.
  nonisolated enum ResumeKey {
    static let agent = Key.agent
    static let sessionRef = Key.sessionRef
    static let worktreeID = Key.worktreeID
    static let branch = Key.branch
    static let repo = Key.repo
    static let worktreeTitle = Key.worktreeTitle
    static let command = "command"

    static let all = [agent, sessionRef, command, repo, branch, worktreeTitle, worktreeID]
  }

  /// Socket wire keys of the `agentExplain` query. Mirrors
  /// `AgentExplainQueryResponse.Key` (app side); keep in sync.
  nonisolated enum ExplainKey {
    static let agent = "agent"
    static let name = "name"
    static let activity = "activity"
    static let dashboardState = "dashboardState"
    static let isDoneUnseen = "isDoneUnseen"
    static let lastEvent = "lastEvent"
    static let lastEventAt = "lastEventAt"
    static let lastTransition = "lastTransition"
    static let pids = "pids"
    static let source = "source"
    static let sessionRef = Key.sessionRef

    static let all = [
      agent, name, activity, dashboardState, isDoneUnseen, lastEvent, lastEventAt,
      lastTransition, pids, source, sessionRef,
    ]

    /// Report label per key, in print order.
    static let labels: [(key: String, label: String)] = [
      (name, "Name"),
      (agent, "Agent"),
      (dashboardState, "Dashboard state"),
      (activity, "Hook activity"),
      (isDoneUnseen, "Done, unseen"),
      (lastEvent, "Last event"),
      (lastEventAt, "Last event at"),
      (lastTransition, "Last transition"),
      (pids, "PIDs"),
      (source, "State source"),
      (sessionRef, "Session ref"),
    ]
  }

  /// Mirrors `AgentKeySequence` (app side); keep in sync. Validated here too so
  /// a typo fails before the app is contacted.
  nonisolated enum KeyNames {
    static let named: Set<String> = [
      "enter", "return", "esc", "escape", "tab", "backspace", "space",
      "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
    ]

    static let help = named.sorted().joined(separator: ", ") + ", ctrl+<letter>"

    static func isValid(_ rawName: String) -> Bool {
      let name = rawName.lowercased()
      if named.contains(name) { return true }
      guard name.count == 6, name.hasPrefix("ctrl") else { return false }
      let separator = name[name.index(name.startIndex, offsetBy: 4)]
      guard separator == "+" || separator == "-" else { return false }
      guard let letter = name.last else { return false }
      return letter.isASCII && letter.isLetter
    }
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
    case noResumeCandidate(String)

    var description: String {
      switch self {
      case .notFound(let target):
        return "No running agent matches '\(target)'. Run `supacode agent list` to see live agents."
      case .notRunning(let target):
        return "agent_not_running: '\(target)' is no longer running."
      case .noResumeCandidate(let target):
        return "No resumable agent session for '\(target)'. "
          + "Run `supacode agent resume-candidates` to see what can be resumed."
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
  static func decoded(_ value: String) -> String {
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
  static func jsonLine(_ row: [String: String], keys: [String] = Key.all) -> String {
    var fields = keys.map { key in
      "\"\(key)\":\(quoted(row[key] ?? ""))"
    }
    // Metadata tokens trail the fixed columns, sorted, so a new token can't
    // reorder the stable prefix.
    for key in row.keys.filter({ $0.hasPrefix(Key.tokenPrefix) }).sorted() {
      fields.append("\"\(key)\":\(quoted(row[key] ?? ""))")
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

  /// Queries `agents` once and resolves the target to a single row.
  static func resolvedRow(
    target: String,
    agentKind: String?,
    timeoutSeconds: Int
  ) throws -> [String: String] {
    let rows = try QueryDispatcher.query(resource: "agents", timeoutSeconds: timeoutSeconds)
    return try resolve(target: target, agentKind: agentKind, in: rows)
  }

  /// Poll interval for every agent-state wait. Presence state is push-updated
  /// app-side, so this only bounds how stale the CLI's view can be.
  static let pollInterval: TimeInterval = 0.5

  /// Per-poll socket read budget. Deliberately not the caller's `--timeout`:
  /// that is the wait deadline, which can legitimately be hours.
  static let queryTimeoutSeconds = 30

  /// Polls the `agents` query until `isSatisfied` accepts the target's row.
  /// Shared by `agent wait` and `agent prompt --wait`, so both agree on how a
  /// vanished agent and a blown deadline are reported.
  static func pollForRow(
    target: String,
    agentKind: String?,
    deadline: Date,
    interval: TimeInterval = AgentCommand.pollInterval,
    timedOut: (String) -> Error,
    isSatisfied: ([String: String]) -> Bool
  ) throws -> [String: String] {
    // A name that resolved once and then stops resolving means the agent
    // exited; that is a different failure from a target that never existed.
    var everResolved = false
    while true {
      let rows = try QueryDispatcher.query(resource: "agents", timeoutSeconds: queryTimeoutSeconds)
      do {
        let row = try resolve(target: target, agentKind: agentKind, in: rows)
        everResolved = true
        if isSatisfied(row) { return row }
      } catch TargetError.notFound(let target) where everResolved {
        throw TargetError.notRunning(target)
      }
      guard Date().addingTimeInterval(interval) < deadline else { throw timedOut(target) }
      Thread.sleep(forTimeInterval: interval)
    }
  }

  static func state(of row: [String: String]) -> AgentState {
    AgentState(rawValue: row[Key.state] ?? "") ?? .unknown
  }

  /// Parses `key=value` token arguments. Rejects an empty key so a stray `=x`
  /// can't create an unaddressable token.
  static func parsedTokens(_ values: [String]) throws -> [String: String] {
    var tokens: [String: String] = [:]
    for raw in values {
      guard let separator = raw.firstIndex(of: "="), separator != raw.startIndex else {
        throw ValidationError("Invalid --token '\(raw)'. Expected key=value.")
      }
      tokens[String(raw[raw.startIndex..<separator])] = String(raw[raw.index(after: separator)...])
    }
    return tokens
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

    func validate() throws {
      guard timeout >= 0 else { throw ValidationError("--timeout cannot be negative.") }
      _ = try AgentCommand.parsedStates(until)
    }

    func run() throws {
      let wanted = try AgentCommand.parsedStates(until)
      let row = try AgentCommand.pollForSettled(
        target: target, agentKind: agent, wanted: wanted, timeout: timeout)
      print(AgentCommand.jsonLine(row))
    }
  }

  /// Waits for the target to reach one of `wanted`. Shared by `agent wait` and
  /// the second phase of `agent prompt --wait`.
  static func pollForSettled(
    target: String,
    agentKind: String?,
    wanted: Set<AgentState>,
    timeout: Int
  ) throws -> [String: String] {
    let deadline = timeout > 0 ? Date().addingTimeInterval(TimeInterval(timeout)) : Date.distantFuture
    return try pollForRow(
      target: target,
      agentKind: agentKind,
      deadline: deadline,
      timedOut: { target in
        let states = wanted.map(\.rawValue).sorted().joined(separator: "|")
        return SocketClient.Error.responseError(
          "Timed out after \(timeout)s waiting for '\(target)' to reach \(states)."
        )
      },
      isSatisfied: { wanted.contains(state(of: $0)) }
    )
  }
}

// MARK: - Phase 4 subcommands.

extension AgentCommand {
  struct Prompt: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Type a prompt into a running agent, optionally waiting for the turn to finish."
    )

    @Argument(help: "Agent name, worktree ID, or branch.")
    var target: String

    @Argument(help: "Prompt text.")
    var text: String

    @Flag(name: .long, help: "Type the prompt without submitting it.")
    var noSubmit = false

    @Flag(name: .long, help: "Block until the agent starts the turn and then settles.")
    var wait = false

    @Option(
      name: .long,
      help: "With --wait, state to settle on, repeatable: \(AgentState.allValues). Defaults to idle, done, and blocked."
    )
    var until: [String] = []

    @Option(name: .long, help: "With --wait, give up after this many seconds. 0 waits indefinitely.")
    var timeout: Int = 900

    @Option(
      name: .long,
      help: "With --wait, seconds to allow for the agent to start working before reporting a stall."
    )
    var stallTimeout: Int = 5

    @Option(name: .long, help: "Agent kind, to disambiguate a worktree running several agents.")
    var agent: String?

    func validate() throws {
      guard !text.isEmpty else { throw ValidationError("Prompt text cannot be empty.") }
      guard timeout >= 0 else { throw ValidationError("--timeout cannot be negative.") }
      guard stallTimeout > 0 else { throw ValidationError("--stall-timeout must be positive.") }
      _ = try AgentCommand.parsedStates(until)
    }

    func run() throws {
      let wanted = try AgentCommand.parsedStates(until)
      let row = try AgentCommand.resolvedRow(
        target: target, agentKind: agent, timeoutSeconds: AgentCommand.queryTimeoutSeconds)
      let kind = row[Key.agent] ?? ""
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.agentPrompt(
          worktreeID: row[Key.worktreeID] ?? "",
          agent: kind,
          text: text,
          submit: !noSubmit
        ),
        timeoutSeconds: AgentCommand.queryTimeoutSeconds
      )
      guard wait else { return }
      // Require an observed transition into `working` first: without it, an
      // agent that never picked the prompt up would look instantly "settled"
      // and the wait would succeed against the previous turn's state.
      try waitForTurnToStart(kind: kind)
      let settled = try AgentCommand.pollForSettled(
        target: target, agentKind: kind, wanted: wanted, timeout: timeout)
      print(AgentCommand.jsonLine(settled))
    }

    /// Polls faster than the settle wait: a short turn can pass through
    /// `working` quickly, and missing it would report a false stall.
    private func waitForTurnToStart(kind: String) throws {
      _ = try AgentCommand.pollForRow(
        target: target,
        agentKind: kind,
        deadline: Date().addingTimeInterval(TimeInterval(stallTimeout)),
        interval: 0.25,
        timedOut: { target in
          SocketClient.Error.responseError(
            "agent_prompt_stalled: '\(target)' did not start working within \(stallTimeout)s."
          )
        },
        isSatisfied: { AgentCommand.state(of: $0) == .working }
      )
    }
  }

  struct SendKeys: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "send-keys",
      abstract: "Send key sequences to a running agent: \(KeyNames.help)."
    )

    @Argument(help: "Agent name, worktree ID, or branch.")
    var target: String

    @Argument(help: "Key names, in order: \(KeyNames.help).")
    var keys: [String]

    @Option(name: .long, help: "Agent kind, to disambiguate a worktree running several agents.")
    var agent: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      guard !keys.isEmpty else { throw ValidationError("Pass at least one key name.") }
      for key in keys where !KeyNames.isValid(key) {
        throw ValidationError("Unknown key '\(key)'. Supported: \(KeyNames.help).")
      }
    }

    func run() throws {
      let row = try AgentCommand.resolvedRow(
        target: target, agentKind: agent, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.agentSendKeys(
          worktreeID: row[Key.worktreeID] ?? "",
          agent: row[Key.agent] ?? "",
          keys: keys.map { $0.lowercased() }
        ),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Read: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the tail of the terminal screen hosting an agent."
    )

    @Argument(help: "Agent name, worktree ID, or branch.")
    var target: String

    @Option(name: .long, help: "Lines to print from the bottom of the screen.")
    var lines: Int = 80

    @Option(name: .long, help: "Agent kind, to disambiguate a worktree running several agents.")
    var agent: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      guard lines > 0 else { throw ValidationError("--lines must be positive.") }
    }

    func run() throws {
      let row = try AgentCommand.resolvedRow(
        target: target, agentKind: agent, timeoutSeconds: timeoutOption.timeout)
      let text = try AgentCommand.readScreen(
        worktreeID: row[Key.worktreeID] ?? "",
        agentKind: row[Key.agent],
        lines: lines,
        timeoutSeconds: timeoutOption.timeout
      )
      print(text)
    }
  }

  /// Screen text of one surface. Without `agentKind` the app reads the
  /// worktree's focused surface, which is what `terminal wait-output` watches.
  static func readScreen(
    worktreeID: String,
    agentKind: String?,
    lines: Int,
    timeoutSeconds: Int
  ) throws -> String {
    var params = ["worktreeID": worktreeID, "lines": String(lines)]
    if let agentKind, !agentKind.isEmpty { params["agent"] = agentKind }
    let rows = try QueryDispatcher.query(
      resource: "agentRead", params: params, timeoutSeconds: timeoutSeconds)
    guard let text = rows.first?["text"] else {
      throw SocketClient.Error.responseError("Supacode returned no screen text.")
    }
    return text
  }

  struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Report why an agent is in its current state: hook activity, last event, seen status."
    )

    @Argument(help: "Agent name, worktree ID, or branch.")
    var target: String

    @Flag(name: .long, help: "Print the raw row as JSON instead of a report.")
    var json = false

    @Option(name: .long, help: "Agent kind, to disambiguate a worktree running several agents.")
    var agent: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let row = try AgentCommand.resolvedRow(
        target: target, agentKind: agent, timeoutSeconds: timeoutOption.timeout)
      let explained = try AgentCommand.explain(
        worktreeID: row[Key.worktreeID] ?? "",
        agentKind: row[Key.agent] ?? "",
        timeoutSeconds: timeoutOption.timeout
      )
      guard !json else {
        print(AgentCommand.jsonLine(explained, keys: ExplainKey.all))
        return
      }
      print(AgentCommand.explainReport(explained, worktreeRow: row))
    }
  }

  static func explain(
    worktreeID: String,
    agentKind: String,
    timeoutSeconds: Int
  ) throws -> [String: String] {
    let rows = try QueryDispatcher.query(
      resource: "agentExplain",
      params: ["worktreeID": worktreeID, "agent": agentKind],
      timeoutSeconds: timeoutSeconds
    )
    guard let row = rows.first else {
      throw SocketClient.Error.responseError("Supacode returned no explanation for '\(agentKind)'.")
    }
    return row
  }

  /// Human-readable report. Unset diagnostics print as `-` rather than being
  /// omitted, so the reader can tell "never reported" from "key I forgot about".
  static func explainReport(_ row: [String: String], worktreeRow: [String: String]) -> String {
    var lines: [String] = []
    for (key, label) in ExplainKey.labels {
      let value = row[key] ?? ""
      lines.append("\(label.padding(toLength: 16, withPad: " ", startingAt: 0)) \(value.isEmpty ? "-" : value)")
    }
    for (label, key) in [("Repo", Key.repo), ("Branch", Key.branch), ("Worktree", Key.worktreeTitle)] {
      let value = worktreeRow[key] ?? ""
      guard !value.isEmpty else { continue }
      lines.append("\(label.padding(toLength: 16, withPad: " ", startingAt: 0)) \(value)")
    }
    let tokens = row.keys.filter { $0.hasPrefix(Key.tokenPrefix) }.sorted()
    for token in tokens {
      let label = "$" + token.dropFirst(Key.tokenPrefix.count)
      lines.append("\(label.padding(toLength: 16, withPad: " ", startingAt: 0)) \(row[token] ?? "")")
    }
    return lines.joined(separator: "\n")
  }

  struct ResumeCandidates: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "resume-candidates",
      abstract: "List agent sessions whose process is gone but that can still be resumed."
    )

    @Flag(name: .long, help: "Print one JSON object per candidate instead of columns.")
    var json = false

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let rows = try QueryDispatcher.query(
        resource: "agentResumeCandidates", timeoutSeconds: timeoutOption.timeout)
      for row in rows {
        print(json ? AgentCommand.jsonLine(row, keys: ResumeKey.all) : AgentCommand.candidateLine(row))
      }
    }
  }

  struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Relaunch a dead agent session with its native resume command.",
      discussion: """
        Types the resume command into the surface that hosted the session and \
        submits it. Only sessions listed by `agent resume-candidates` can be \
        resumed: the agent's process must be gone and its hook must have \
        reported a session id. Supacode never resumes on its own.
        """
    )

    @Argument(help: "Worktree ID or branch hosting the dead session.")
    var target: String

    @Option(name: .long, help: "Agent kind, to disambiguate a worktree with several dead sessions.")
    var agent: String?

    @Flag(name: .long, help: "Print the resume command instead of running it.")
    var dryRun = false

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let rows = try QueryDispatcher.query(
        resource: "agentResumeCandidates", timeoutSeconds: timeoutOption.timeout)
      let row = try AgentCommand.resolveCandidate(target: target, agentKind: agent, in: rows)
      guard !dryRun else {
        print(row[ResumeKey.command] ?? "")
        return
      }
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.agentResume(
          worktreeID: row[ResumeKey.worktreeID] ?? "",
          agent: row[ResumeKey.agent] ?? ""
        ),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  /// Resume candidates have no names (a name addresses a *running* agent), so
  /// they resolve by worktree only, with `--agent` as the tie-break.
  static func resolveCandidate(
    target: String,
    agentKind: String?,
    in rows: [[String: String]]
  ) throws -> [String: String] {
    let decodedTarget = decoded(target)
    let matches = rows.filter { row in
      guard agentKind == nil || row[ResumeKey.agent] == agentKind else { return false }
      let id = decoded(row[ResumeKey.worktreeID] ?? "")
      return id == decodedTarget || row[ResumeKey.branch] == target
        || row[ResumeKey.worktreeTitle] == target
    }
    guard let first = matches.first else {
      throw TargetError.noResumeCandidate(target)
    }
    guard matches.count == 1 else {
      throw TargetError.ambiguous(
        target: target, candidates: matches.map { $0[ResumeKey.agent] ?? "" })
    }
    return first
  }

  static func candidateLine(_ row: [String: String]) -> String {
    let columns = [
      row[ResumeKey.agent] ?? "",
      row[ResumeKey.sessionRef] ?? "",
      row[ResumeKey.repo] ?? "",
      row[ResumeKey.branch] ?? "",
      row[ResumeKey.worktreeID] ?? "",
    ]
    return columns.map(ListFormatting.sanitizeColumn).joined(separator: "\t")
  }

  struct ReportMetadata: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "report-metadata",
      abstract: "Attach display-only tokens to a running agent (never affects its state)."
    )

    @Argument(help: "Agent name, worktree ID, or branch.")
    var target: String

    @Option(name: .long, help: "Token as key=value. Repeatable, up to 8 tokens per agent.")
    var token: [String] = []

    @Flag(name: .long, help: "Drop the agent's existing tokens first.")
    var clear = false

    @Option(name: .long, help: "Agent kind, to disambiguate a worktree running several agents.")
    var agent: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      guard clear || !token.isEmpty else {
        throw ValidationError("Pass at least one --token, or --clear.")
      }
      _ = try AgentCommand.parsedTokens(token)
    }

    func run() throws {
      let tokens = try AgentCommand.parsedTokens(token)
      let row = try AgentCommand.resolvedRow(
        target: target, agentKind: agent, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.agentMetadata(
          worktreeID: row[Key.worktreeID] ?? "",
          agent: row[Key.agent] ?? "",
          tokens: tokens,
          clear: clear
        ),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }
}
