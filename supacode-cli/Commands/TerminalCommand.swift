import ArgumentParser
import Foundation

struct TerminalCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "terminal",
    abstract: "Watch terminal output.",
    subcommands: [WaitOutput.self],
    defaultSubcommand: WaitOutput.self
  )
}

extension TerminalCommand {
  struct WaitOutput: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "wait-output",
      abstract: "Block until a worktree's focused terminal shows matching output, then print the matched line."
    )

    @Argument(
      help: "Agent name, worktree ID, or branch. Defaults to $SUPACODE_WORKTREE_ID."
    )
    var target: String?

    @Option(name: .long, help: "Swift regex, matched per line.")
    var regex: String?

    @Option(name: .long, help: "Literal substring, matched per line.")
    var text: String?

    @Option(name: .long, help: "Give up after this many seconds. 0 waits indefinitely.")
    var timeout: Int = 900

    @Option(name: .long, help: "Lines of screen text to scan on each poll.")
    var lines: Int = 200

    /// Screen text is cached app-side for 500ms, so polling faster only burns
    /// socket round-trips.
    private static let pollInterval: TimeInterval = 0.5
    private static let queryTimeoutSeconds = 30

    func validate() throws {
      guard (regex == nil) != (text == nil) else {
        throw ValidationError("Pass exactly one of --regex or --text.")
      }
      guard timeout >= 0 else { throw ValidationError("--timeout cannot be negative.") }
      guard lines > 0 else { throw ValidationError("--lines must be positive.") }
      if let regex { _ = try Self.compiled(regex) }
    }

    func run() throws {
      let matcher = try Self.matcher(regex: regex, text: text)
      let worktreeID = try Self.resolvedWorktreeID(target)
      let deadline = timeout > 0 ? Date().addingTimeInterval(TimeInterval(timeout)) : Date.distantFuture

      while true {
        let screen = try AgentCommand.readScreen(
          worktreeID: worktreeID,
          agentKind: nil,
          lines: lines,
          timeoutSeconds: Self.queryTimeoutSeconds
        )
        if let matched = screen.split(separator: "\n", omittingEmptySubsequences: false)
          .map(String.init)
          .last(where: matcher)
        {
          print(matched)
          return
        }
        guard Date().addingTimeInterval(Self.pollInterval) < deadline else {
          throw SocketClient.Error.responseError(
            "Timed out after \(timeout)s waiting for output in '\(worktreeID)'."
          )
        }
        Thread.sleep(forTimeInterval: Self.pollInterval)
      }
    }

    /// Resolves an agent name / branch / title through the `agents` query, and
    /// falls back to treating the target as a worktree ID so an agentless
    /// worktree is still watchable.
    private static func resolvedWorktreeID(_ target: String?) throws -> String {
      guard let target, !target.isEmpty else { return try resolveWorktreeID(nil) }
      guard
        let rows = try? QueryDispatcher.query(resource: "agents", timeoutSeconds: queryTimeoutSeconds),
        let row = try? AgentCommand.resolve(target: target, agentKind: nil, in: rows),
        let worktreeID = row[AgentCommand.Key.worktreeID]
      else { return target }
      return worktreeID
    }

    private static func matcher(regex: String?, text: String?) throws -> (String) -> Bool {
      if let text { return { $0.contains(text) } }
      guard let regex else { return { _ in false } }
      let compiled = try Self.compiled(regex)
      return { line in line.contains(compiled) }
    }

    private static func compiled(_ pattern: String) throws -> Regex<AnyRegexOutput> {
      do {
        return try Regex(pattern)
      } catch {
        throw ValidationError("Invalid --regex '\(pattern)': \(error.localizedDescription)")
      }
    }
  }
}
