import Foundation
import SupacodeSettingsShared

/// Native resume command per agent kind. Pure string construction: the caller
/// decides whether typing it into a surface is safe.
///
/// Only the agents whose CLI documents a resume-by-id flag are listed. An agent
/// that isn't listed reports `nil`, which the whole resume path reads as "no
/// offer" — never as "guess a command".
enum AgentResumeCommand {
  /// The shell command that reattaches `agent` to `sessionRef`, or nil when the
  /// agent has no resume-by-id CLI or the ref isn't a shape we'd put on a
  /// command line.
  ///
  /// The ref is re-validated here rather than trusted from state: it arrived over
  /// an unauthenticated OSC signal, and this is the last hop before it becomes
  /// terminal input.
  static func command(agent: SkillAgent, sessionRef: String) -> String? {
    guard let ref = AgentPresenceOSC.sanitizedSessionRef(sessionRef) else { return nil }
    switch agent {
    case .claude: return "claude --resume \(ref)"
    case .pi: return "pi --session \(ref)"
    case .codex: return "codex resume \(ref)"
    case .copilot, .grok, .hermes, .kimi, .kiro, .omp, .opencode:
      return nil
    }
  }

  /// Agent kinds that can be resumed at all, for docs and error messages.
  static var supportedAgents: [SkillAgent] {
    SkillAgent.allCases.filter { command(agent: $0, sessionRef: "x") != nil }
  }
}
