import AppKit
import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Owns workflow runs and the launch sheet for the project command center.
/// Reads workflows from `@Shared(.settingsFile)` (built-ins + user-defined) and
/// launches them into a terminal tab via `TerminalClient`. Worktrees are
/// resolved by the view (which has repositories state) and passed in, keeping
/// this reducer decoupled from `RepositoriesFeature` internals.
@Reducer
struct ProjectCommandCenterFeature {
  @ObservableState
  struct State: Equatable {
    var runs: IdentifiedArrayOf<WorkflowRun> = []
    var launcher: Launcher?

    /// Built-ins followed by user-defined workflows (built-in wins on id).
    func allWorkflows(global: [WorkflowDefinition]) -> [WorkflowDefinition] {
      .merged(builtIn: WorkflowDefinition.builtIns, user: global)
    }

    func runs(forProjectID projectID: String) -> [WorkflowRun] {
      runs.filter { $0.projectID == projectID }
    }

    func activeRunCount(forProjectID projectID: String) -> Int {
      runs.filter { $0.projectID == projectID && $0.isActive }.count
    }
  }

  /// Transient launch-sheet state. Carries the resolved `Worktree` so the
  /// confirm step can dispatch the terminal command without re-resolving.
  struct Launcher: Equatable, Identifiable {
    var id: UUID
    var workflow: WorkflowDefinition
    var worktree: Worktree
    var projectID: String
    var projectName: String
    var harnessID: String
    var selectors: [WorkflowContextSelector]
    var note: String
    var url: String
    var commitCount: Int

    init(
      id: UUID = UUID(),
      workflow: WorkflowDefinition,
      worktree: Worktree,
      projectID: String,
      projectName: String,
      harnessID: String = AgentHarnessDefinition.pi.id,
      note: String = "",
      url: String = "",
      commitCount: Int = 5,
    ) {
      self.id = id
      self.workflow = workflow
      self.worktree = worktree
      self.projectID = projectID
      self.projectName = projectName
      self.harnessID = harnessID
      self.selectors = workflow.defaultContextSelectors
      self.note = note
      self.url = url
      self.commitCount = commitCount
    }

    var inputs: WorkflowLaunchComposer.Inputs {
      .init(selectors: selectors, note: note, url: url, commitCount: commitCount)
    }
  }

  enum Action: Equatable {
    case presentLauncher(Launcher)
    case dismissLauncher
    case setLauncherNote(String)
    case setLauncherURL(String)
    case setLauncherCommitCount(Int)
    case setLauncherHarness(String)
    case toggleSelector(WorkflowContextSelector)
    case confirmLaunch
    /// Launch with default inputs, no sheet (project-card favorite button).
    case launchImmediately(workflow: WorkflowDefinition, worktree: Worktree, projectID: String, projectName: String)
    case followUp(runID: UUID, worktree: Worktree, action: WorkflowFollowUpAction)
    case setRunStatus(runID: UUID, status: WorkflowRunStatus)
    case removeRun(runID: UUID)
  }

  @Dependency(\.terminalClient) var terminalClient
  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .presentLauncher(let launcher):
        state.launcher = launcher
        return .none

      case .dismissLauncher:
        state.launcher = nil
        return .none

      case .setLauncherNote(let note):
        state.launcher?.note = note
        return .none

      case .setLauncherURL(let url):
        state.launcher?.url = url
        return .none

      case .setLauncherCommitCount(let count):
        state.launcher?.commitCount = max(1, count)
        return .none

      case .setLauncherHarness(let harnessID):
        state.launcher?.harnessID = harnessID
        return .none

      case .toggleSelector(let selector):
        guard state.launcher != nil else { return .none }
        if let index = state.launcher!.selectors.firstIndex(of: selector) {
          state.launcher!.selectors.remove(at: index)
        } else {
          state.launcher!.selectors.append(selector)
        }
        return .none

      case .confirmLaunch:
        guard let launcher = state.launcher else { return .none }
        state.launcher = nil
        return launch(
          LaunchRequest(
            workflow: launcher.workflow,
            worktree: launcher.worktree,
            projectID: launcher.projectID,
            harnessID: launcher.harnessID,
            inputs: launcher.inputs
          ),
          state: &state
        )

      case .launchImmediately(let workflow, let worktree, let projectID, _):
        return launch(
          LaunchRequest(
            workflow: workflow,
            worktree: worktree,
            projectID: projectID,
            harnessID: AgentHarnessDefinition.pi.id,
            inputs: .init(selectors: workflow.defaultContextSelectors)
          ),
          state: &state
        )

      case .followUp(let runID, let worktree, let followUpAction):
        return handleFollowUp(runID: runID, worktree: worktree, action: followUpAction, state: &state)

      case .setRunStatus(let runID, let status):
        guard state.runs[id: runID] != nil else { return .none }
        state.runs[id: runID]?.status = status
        if !status.isActiveStatus {
          state.runs[id: runID]?.completedAt = now
        }
        return .none

      case .removeRun(let runID):
        state.runs.remove(id: runID)
        return .none
      }
    }
  }

  // MARK: - Launch

  private struct LaunchRequest {
    var workflow: WorkflowDefinition
    var worktree: Worktree
    var projectID: String
    var harnessID: String
    var inputs: WorkflowLaunchComposer.Inputs
  }

  private func launch(_ request: LaunchRequest, state: inout State) -> Effect<Action> {
    let workflow = request.workflow
    let worktree = request.worktree
    let harness = AgentHarnessDefinition.harness(for: request.harnessID) ?? .pi
    let substitutions = WorkflowLaunchComposer.substitutions(for: request.inputs)
    let prompt = workflow.renderedPrompt(substitutions: substitutions)
    let command = launchCommand(harness: harness, prompt: prompt)
    let tabID = uuid()

    let run = WorkflowRun(
      id: uuid(),
      workflowID: workflow.id,
      projectID: request.projectID,
      harnessID: harness.id,
      terminalTabID: tabID,
      status: .active,
      startedAt: now,
      resolvedInputs: substitutions,
      contextSummary: command,
      followUpActions: workflow.followUpActions,
    )
    state.runs.append(run)

    let terminalClient = terminalClient
    return .run { _ in
      await terminalClient.send(
        .createTabWithInput(worktree, input: command, runSetupScriptIfNew: false, id: tabID)
      )
    }
  }

  private func launchCommand(harness: AgentHarnessDefinition, prompt: String) -> String {
    harness.launchCommandTemplate.replacing("{{prompt}}", with: Self.shellQuoted(prompt))
  }

  /// Single-quote the prompt so it survives the shell as one argument. Embedded
  /// single quotes are closed, escaped, and reopened (`'\''`).
  static func shellQuoted(_ value: String) -> String {
    "'" + value.replacing("'", with: "'\\''") + "'"
  }

  // MARK: - Follow-up

  private func handleFollowUp(
    runID: UUID,
    worktree: Worktree,
    action: WorkflowFollowUpAction,
    state: inout State,
  ) -> Effect<Action> {
    guard let run = state.runs[id: runID] else { return .none }

    if let text = action.promptText {
      guard let tabUUID = run.terminalTabID else { return .none }
      let terminalClient = terminalClient
      return .run { _ in
        await terminalClient.send(
          .sendTextToTab(worktree, tabID: TerminalTabID(rawValue: tabUUID), text: text)
        )
      }
    }

    switch action {
    case .stop:
      state.runs[id: runID]?.status = .stopped
      state.runs[id: runID]?.completedAt = now
      return .none
    case .copy:
      let summary = run.contextSummary
      return .run { _ in
        await MainActor.run {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(summary, forType: .string)
        }
      }
    case .addContext, .continueRun, .interviewMe, .fixFindings, .verify, .handoff:
      return .none
    }
  }
}

extension WorkflowRunStatus {
  fileprivate var isActiveStatus: Bool {
    switch self {
    case .idle, .active, .attentionNeeded: true
    case .complete, .failed, .stopped: false
    }
  }
}
