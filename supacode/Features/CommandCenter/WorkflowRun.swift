import Foundation
import SupacodeSettingsShared

enum WorkflowRunStatus: Equatable, Sendable {
  case idle
  case active
  case attentionNeeded
  case complete
}

struct WorkflowRun: Identifiable, Equatable, Sendable {
  let id: UUID
  let workflowID: UUID
  let repositoryID: Repository.ID
  let worktreeID: Worktree.ID
  let tabID: UUID
  let startedAt: Date
  var status: WorkflowRunStatus
  var completedAt: Date?

  init(
    id: UUID = UUID(),
    workflowID: UUID,
    repositoryID: Repository.ID,
    worktreeID: Worktree.ID,
    tabID: UUID,
    startedAt: Date,
    status: WorkflowRunStatus = .active,
    completedAt: Date? = nil
  ) {
    self.id = id
    self.workflowID = workflowID
    self.repositoryID = repositoryID
    self.worktreeID = worktreeID
    self.tabID = tabID
    self.startedAt = startedAt
    self.status = status
    self.completedAt = completedAt
  }
}
