import Foundation

/// Lifecycle of a workflow run. `attentionNeeded` is initially inferred from
/// agent presence/activity; explicit `needsInput` hooks come later.
public nonisolated enum WorkflowRunStatus: String, Codable, Sendable {
  case idle
  case active
  case attentionNeeded
  case complete
  case failed
  case stopped

  public var displayName: String {
    switch self {
    case .idle: "Idle"
    case .active: "Active"
    case .attentionNeeded: "Attention needed"
    case .complete: "Complete"
    case .failed: "Failed"
    case .stopped: "Stopped"
    }
  }
}

/// A workflow run attached to a project directory. `projectID` is the
/// repository root path string (how the app keys repositories).
public nonisolated struct WorkflowRun: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var workflowID: UUID
  public var projectID: String
  public var harnessID: String
  public var terminalTabID: UUID?
  public var status: WorkflowRunStatus
  public var startedAt: Date
  public var completedAt: Date?
  public var resolvedInputs: [String: String]
  public var contextSummary: String
  public var outputSummary: String
  public var followUpActions: [WorkflowFollowUpAction]

  public init(
    id: UUID = UUID(),
    workflowID: UUID,
    projectID: String,
    harnessID: String = AgentHarnessDefinition.pi.id,
    terminalTabID: UUID? = nil,
    status: WorkflowRunStatus = .idle,
    startedAt: Date = Date(),
    completedAt: Date? = nil,
    resolvedInputs: [String: String] = [:],
    contextSummary: String = "",
    outputSummary: String = "",
    followUpActions: [WorkflowFollowUpAction] = [],
  ) {
    self.id = id
    self.workflowID = workflowID
    self.projectID = projectID
    self.harnessID = harnessID
    self.terminalTabID = terminalTabID
    self.status = status
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.resolvedInputs = resolvedInputs
    self.contextSummary = contextSummary
    self.outputSummary = outputSummary
    self.followUpActions = followUpActions
  }

  public var isActive: Bool {
    switch status {
    case .idle, .active, .attentionNeeded: true
    case .complete, .failed, .stopped: false
    }
  }
}
