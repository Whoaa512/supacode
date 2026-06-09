import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct ProjectCommandCenterFeatureTests {
  private func makeWorktree(id: String = "/tmp/repo/wt-1") -> Worktree {
    Worktree(
      id: id,
      name: "wt-1",
      detail: "",
      workingDirectory: URL(filePath: id),
      repositoryRootURL: URL(filePath: "/tmp/repo"),
    )
  }

  @Test(.dependencies) func launchImmediatelyAppendsRunAndSendsCommand() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: ProjectCommandCenterFeature.State()) {
      ProjectCommandCenterFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    let workflow = WorkflowDefinition.builtIns.first { $0.id == WorkflowDefinition.investigateID }!
    await store.send(
      .launchImmediately(workflow: workflow, worktree: worktree, projectID: "/tmp/repo", projectName: "repo")
    )
    await store.finish()

    #expect(store.state.runs.count == 1)
    let run = store.state.runs[0]
    #expect(run.workflowID == WorkflowDefinition.investigateID)
    #expect(run.projectID == "/tmp/repo")
    #expect(run.status == .active)

    #expect(sent.value.count == 1)
    guard case .createTabWithInput(let sentWorktree, let input, _, let id) = sent.value.first else {
      Issue.record("Expected createTabWithInput")
      return
    }
    #expect(sentWorktree == worktree)
    #expect(input.hasPrefix("pi '"))
    #expect(id == run.terminalTabID)
  }

  @Test(.dependencies) func confirmLaunchUsesLauncherInputs() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: ProjectCommandCenterFeature.State()) {
      ProjectCommandCenterFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    let workflow = WorkflowDefinition(
      name: "Custom",
      category: .build,
      promptTemplate: "do {{note}}",
    )
    let launcher = ProjectCommandCenterFeature.Launcher(
      workflow: workflow,
      worktree: worktree,
      projectID: "/tmp/repo",
      projectName: "repo",
    )
    await store.send(.presentLauncher(launcher))
    await store.send(.setLauncherNote("the thing"))
    await store.send(.confirmLaunch)
    await store.finish()

    #expect(store.state.launcher == nil)
    #expect(store.state.runs.count == 1)
    guard case .createTabWithInput(_, let input, _, _) = sent.value.first else {
      Issue.record("Expected createTabWithInput")
      return
    }
    #expect(input == "pi 'do the thing'")
  }

  @Test(.dependencies) func followUpPromptTextSendsToTab() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let run = WorkflowRun(
      workflowID: WorkflowDefinition.shipCheckID,
      projectID: "/tmp/repo",
      terminalTabID: tabID,
      status: .active,
    )
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initial = ProjectCommandCenterFeature.State()
    initial.runs = [run]
    let store = TestStore(initialState: initial) {
      ProjectCommandCenterFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    await store.send(.followUp(runID: run.id, worktree: worktree, action: .verify))
    await store.finish()

    guard case .sendTextToTab(let sentWorktree, let sentTabID, let text) = sent.value.first else {
      Issue.record("Expected sendTextToTab")
      return
    }
    #expect(sentWorktree == worktree)
    #expect(sentTabID == TerminalTabID(rawValue: tabID))
    #expect(text == "verify")
  }

  @Test(.dependencies) func followUpStopMarksRunStopped() async {
    let worktree = makeWorktree()
    let run = WorkflowRun(workflowID: WorkflowDefinition.devLoopID, projectID: "/tmp/repo", status: .active)
    var initial = ProjectCommandCenterFeature.State()
    initial.runs = [run]
    let store = TestStore(initialState: initial) {
      ProjectCommandCenterFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
    }
    store.exhaustivity = .off

    await store.send(.followUp(runID: run.id, worktree: worktree, action: .stop))
    await store.finish()

    #expect(store.state.runs[id: run.id]?.status == .stopped)
    #expect(store.state.runs[id: run.id]?.completedAt == Date(timeIntervalSince1970: 100))
  }

  @Test(.dependencies) func toggleSelectorAddsAndRemoves() async {
    let worktree = makeWorktree()
    let workflow = WorkflowDefinition(name: "T", category: .build, defaultContextSelectors: [.currentDiff])
    let launcher = ProjectCommandCenterFeature.Launcher(
      workflow: workflow,
      worktree: worktree,
      projectID: "/tmp/repo",
      projectName: "repo",
    )
    let store = TestStore(initialState: ProjectCommandCenterFeature.State()) {
      ProjectCommandCenterFeature()
    }
    store.exhaustivity = .off

    await store.send(.presentLauncher(launcher))
    await store.send(.toggleSelector(.url))
    #expect(store.state.launcher?.selectors == [.currentDiff, .url])
    await store.send(.toggleSelector(.currentDiff))
    #expect(store.state.launcher?.selectors == [.url])
  }

  @Test func projectRunCountsFilterByProject() {
    var state = ProjectCommandCenterFeature.State()
    state.runs = [
      WorkflowRun(workflowID: UUID(), projectID: "/a", status: .active),
      WorkflowRun(workflowID: UUID(), projectID: "/a", status: .stopped),
      WorkflowRun(workflowID: UUID(), projectID: "/b", status: .active),
    ]
    #expect(state.runs(forProjectID: "/a").count == 2)
    #expect(state.activeRunCount(forProjectID: "/a") == 1)
    #expect(state.activeRunCount(forProjectID: "/b") == 1)
  }
}
