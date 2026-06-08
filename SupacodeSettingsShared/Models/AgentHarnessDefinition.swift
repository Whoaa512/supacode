import Foundation

/// How a harness receives the rendered workflow prompt.
public nonisolated enum AgentPromptTransport: String, Codable, Sendable {
  /// Prompt is passed as a command-line argument.
  case commandArgument
  /// Prompt is piped to the process's stdin.
  case stdin
}

/// A launchable agent harness. The launcher substitutes the rendered prompt
/// into `launchCommandTemplate` at the `{{prompt}}` token (shell-quoting is the
/// launcher's responsibility, not the template's). MVP ships only `pi`; new
/// harnesses can be added without changing any `WorkflowDefinition`.
public nonisolated struct AgentHarnessDefinition: Identifiable, Codable, Equatable, Hashable, Sendable {
  public var id: String
  public var displayName: String
  public var launchCommandTemplate: String
  public var promptTransport: AgentPromptTransport
  public var supportsStatusHooks: Bool
  public var supportsFollowUpSend: Bool

  public init(
    id: String,
    displayName: String,
    launchCommandTemplate: String,
    promptTransport: AgentPromptTransport,
    supportsStatusHooks: Bool,
    supportsFollowUpSend: Bool,
  ) {
    self.id = id
    self.displayName = displayName
    self.launchCommandTemplate = launchCommandTemplate
    self.promptTransport = promptTransport
    self.supportsStatusHooks = supportsStatusHooks
    self.supportsFollowUpSend = supportsFollowUpSend
  }

  public static let pi = AgentHarnessDefinition(
    id: "pi",
    displayName: "Pi",
    launchCommandTemplate: "pi {{prompt}}",
    promptTransport: .commandArgument,
    supportsStatusHooks: false,
    supportsFollowUpSend: true,
  )

  public static let all: [AgentHarnessDefinition] = [.pi]

  public static func harness(for id: String) -> AgentHarnessDefinition? {
    all.first { $0.id == id }
  }
}
