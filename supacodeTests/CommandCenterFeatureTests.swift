import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct CommandCenterFeatureTests {
  @Test(.dependencies) func launchWorkflowCreatesRunAndDelegatesTabCreation() async {
    let testUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let testDate = Date(timeIntervalSince1970: 1_000_000)
    let workflow = WorkflowDefinition.builtIns[0]

    let store = TestStore(
      initialState: CommandCenterFeature.State()
    ) {
      CommandCenterFeature()
    } withDependencies: {
      $0.uuid = .constant(testUUID)
      $0.date = .constant(testDate)
    }

    await store.send(.launchWorkflow(workflow, repositoryID: "/tmp/repo", worktreeID: "wt-1", context: nil)) {
      $0.runs.append(WorkflowRun(
        id: testUUID,
        workflowID: workflow.id,
        repositoryID: "/tmp/repo",
        worktreeID: "wt-1",
        tabID: testUUID,
        startedAt: testDate
      ))
    }
    await store.receive(\.workflowLaunched)
    await store.receive(\.delegate.createTabWithInput)
  }

  @Test(.dependencies) func launchWorkflowWithContextInterpolatesPrompt() async {
    let testUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let testDate = Date(timeIntervalSince1970: 1_000_000)
    let workflow = WorkflowDefinition.builtIns[2]

    let store = TestStore(
      initialState: CommandCenterFeature.State()
    ) {
      CommandCenterFeature()
    } withDependencies: {
      $0.uuid = .constant(testUUID)
      $0.date = .constant(testDate)
    }

    await store.send(
      .launchWorkflow(
        workflow,
        repositoryID: "/tmp/repo",
        worktreeID: "wt-1",
        context: "https://buildkite.com/org/pipeline/builds/123"
      )
    ) {
      $0.runs.append(WorkflowRun(
        id: testUUID,
        workflowID: workflow.id,
        repositoryID: "/tmp/repo",
        worktreeID: "wt-1",
        tabID: testUUID,
        startedAt: testDate
      ))
    }
    await store.receive(\.workflowLaunched)
    await store.receive(\.delegate.createTabWithInput)
  }

  @Test(.dependencies) func updateRunStatus() async {
    let runID = UUID()
    let run = WorkflowRun(
      id: runID,
      workflowID: WorkflowDefinition.builtIns[0].id,
      repositoryID: "/tmp/repo",
      worktreeID: "wt-1",
      tabID: UUID(),
      startedAt: Date()
    )
    var initialState = CommandCenterFeature.State()
    initialState.runs.append(run)

    let testDate = Date(timeIntervalSince1970: 2_000_000)
    let store = TestStore(initialState: initialState) {
      CommandCenterFeature()
    } withDependencies: {
      $0.date = .constant(testDate)
    }

    await store.send(.updateRunStatus(id: runID, status: .complete)) {
      $0.runs[id: runID]?.status = .complete
      $0.runs[id: runID]?.completedAt = testDate
    }
  }

  @Test(.dependencies) func sendFollowUpDelegates() async {
    let runID = UUID()
    let tabID = UUID()
    let run = WorkflowRun(
      id: runID,
      workflowID: WorkflowDefinition.builtIns[0].id,
      repositoryID: "/tmp/repo",
      worktreeID: "wt-1",
      tabID: tabID,
      startedAt: Date()
    )
    var initialState = CommandCenterFeature.State()
    initialState.runs.append(run)

    let store = TestStore(initialState: initialState) {
      CommandCenterFeature()
    }

    await store.send(.sendFollowUp(runID: runID, text: "intme"))
    await store.receive(\.delegate.sendInputToTab)
  }

  @Test(.dependencies) func clipboardChangedSetsHint() async {
    let store = TestStore(
      initialState: CommandCenterFeature.State()
    ) {
      CommandCenterFeature()
    }

    await store.send(.clipboardChanged("https://buildkite.com/org/pipeline/builds/123")) {
      $0.clipboardText = "https://buildkite.com/org/pipeline/builds/123"
      $0.clipboardHint = .fixCI
    }

    await store.send(.clipboardChanged("https://github.com/org/repo/pull/42")) {
      $0.clipboardText = "https://github.com/org/repo/pull/42"
      $0.clipboardHint = .shipCheck
    }

    await store.send(.clipboardChanged("https://app.slack.com/client/T123/C456")) {
      $0.clipboardText = "https://app.slack.com/client/T123/C456"
      $0.clipboardHint = .investigate
    }

    await store.send(.clipboardChanged("https://docs.google.com/document/d/abc123")) {
      $0.clipboardText = "https://docs.google.com/document/d/abc123"
      $0.clipboardHint = .investigate
    }

    await store.send(.clipboardChanged("just some plain text")) {
      $0.clipboardText = "just some plain text"
      $0.clipboardHint = nil
    }

    await store.send(.clipboardChanged(nil)) {
      $0.clipboardText = nil
      $0.clipboardHint = nil
    }
  }

  @Test(.dependencies) func removeRun() async {
    let runID = UUID()
    let run = WorkflowRun(
      id: runID,
      workflowID: WorkflowDefinition.builtIns[0].id,
      repositoryID: "/tmp/repo",
      worktreeID: "wt-1",
      tabID: UUID(),
      startedAt: Date()
    )
    var initialState = CommandCenterFeature.State()
    initialState.runs.append(run)

    let store = TestStore(initialState: initialState) {
      CommandCenterFeature()
    }

    await store.send(.removeRun(id: runID)) {
      $0.runs.remove(id: runID)
    }
  }
}
