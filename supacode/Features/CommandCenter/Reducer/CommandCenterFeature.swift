import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared

@Reducer
struct CommandCenterFeature {
  @ObservableState
  struct State: Equatable {
    var runs: IdentifiedArrayOf<WorkflowRun> = []
    var clipboardHint: ClipboardWorkflowHint?
    var clipboardText: String?
  }

  enum Action: Equatable {
    case launchWorkflow(WorkflowDefinition, repositoryID: Repository.ID, worktreeID: Worktree.ID, context: String?)
    case workflowLaunched(WorkflowRun)
    case updateRunStatus(id: WorkflowRun.ID, status: WorkflowRunStatus)
    case removeRun(id: WorkflowRun.ID)
    case sendFollowUp(runID: WorkflowRun.ID, text: String)
    case clipboardChanged(String?)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case createTabWithInput(worktreeID: Worktree.ID, input: String, tabID: UUID)
    case sendInputToTab(worktreeID: Worktree.ID, tabID: UUID, surfaceID: UUID?, input: String)
  }

  @Dependency(\.date.now) private var now
  @Dependency(\.uuid) private var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .launchWorkflow(let workflow, let repositoryID, let worktreeID, let context):
        let tabID = uuid()
        let prompt = renderPrompt(template: workflow.promptTemplate, context: context)
        let input = "pi \"\(escapeForShell(prompt))\"\n"
        let run = WorkflowRun(
          id: uuid(),
          workflowID: workflow.id,
          repositoryID: repositoryID,
          worktreeID: worktreeID,
          tabID: tabID,
          startedAt: now
        )
        state.runs.append(run)
        return .merge(
          .send(.workflowLaunched(run)),
          .send(.delegate(.createTabWithInput(worktreeID: worktreeID, input: input, tabID: tabID)))
        )

      case .workflowLaunched:
        return .none

      case .updateRunStatus(let id, let status):
        guard state.runs[id: id] != nil else { return .none }
        state.runs[id: id]?.status = status
        if status == .complete {
          state.runs[id: id]?.completedAt = now
        }
        return .none

      case .removeRun(let id):
        state.runs.remove(id: id)
        return .none

      case .sendFollowUp(let runID, let text):
        guard let run = state.runs[id: runID] else { return .none }
        return .send(.delegate(.sendInputToTab(
          worktreeID: run.worktreeID,
          tabID: run.tabID,
          surfaceID: nil,
          input: text + "\n"
        )))

      case .clipboardChanged(let text):
        state.clipboardText = text
        state.clipboardHint = text.flatMap { ClipboardPreselection.hint(from: $0) }
        return .none

      case .delegate:
        return .none
      }
    }
  }
}

private func renderPrompt(template: String, context: String?) -> String {
  var result = template
  if let context, !context.isEmpty {
    result = result.replacingOccurrences(of: "{{#context}}", with: "")
    result = result.replacingOccurrences(of: "{{/context}}", with: "")
    result = result.replacingOccurrences(of: "{{^context}}", with: "")
    result = result.replacingOccurrences(of: "{{context}}", with: context)
    if let range = result.range(of: "{{^context}}") {
      if let endRange = result.range(of: "{{/context}}", range: range.upperBound..<result.endIndex) {
        result.removeSubrange(range.lowerBound..<endRange.upperBound)
      }
    }
  } else {
    while let startRange = result.range(of: "{{#context}}") {
      if let endRange = result.range(of: "{{/context}}", range: startRange.upperBound..<result.endIndex) {
        result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
      } else {
        break
      }
    }
    result = result.replacingOccurrences(of: "{{^context}}", with: "")
    result = result.replacingOccurrences(of: "{{/context}}", with: "")
  }
  return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func escapeForShell(_ string: String) -> String {
  string.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "$", with: "\\$")
    .replacingOccurrences(of: "`", with: "\\`")
}
