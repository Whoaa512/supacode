import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Project-level workflow command center. Shows configured projects as cards
/// with favorite workflow buttons, plus live / completed run cards with
/// follow-up steering. Runs alongside the existing sidebar, not replacing it.
struct ProjectCommandCenterView: View {
  @Bindable var store: StoreOf<ProjectCommandCenterFeature>
  let repositories: IdentifiedArrayOf<Repository>
  @Shared(.settingsFile) private var settingsFile

  private var workflows: [WorkflowDefinition] {
    store.state.allWorkflows(global: settingsFile.global.globalWorkflows)
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        projectsSection
        if !store.runs.isEmpty {
          runsSection
        }
      }
      .padding()
    }
    .navigationTitle("Command Center")
    .sheet(
      item: Binding(
        get: { store.launcher },
        set: { if $0 == nil { store.send(.dismissLauncher) } }
      )
    ) { _ in
      WorkflowLauncherSheet(store: store)
    }
  }

  // MARK: - Projects

  private var projectsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Projects").font(.headline)
      if repositories.isEmpty {
        Text("No projects configured. Add a repository or folder from the sidebar.")
          .foregroundStyle(.secondary)
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
          ForEach(repositories) { repository in
            ProjectCardView(
              repository: repository,
              favorites: workflows.favorites,
              allWorkflows: workflows,
              activeRunCount: store.state.activeRunCount(forProjectID: repository.id),
              lastRun: lastRun(forProjectID: repository.id),
              workflowName: workflowName(for:),
              onLaunch: { workflow in launch(workflow, in: repository) }
            )
          }
        }
      }
    }
  }

  // MARK: - Runs

  private var runsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Runs").font(.headline)
      ForEach(sortedRuns) { run in
        WorkflowRunCardView(
          run: run,
          workflowName: workflowName(for: run.workflowID),
          projectName: repositories[id: run.projectID]?.name ?? run.projectID,
          onFollowUp: { action in followUp(run: run, action: action) },
          onDismiss: { store.send(.removeRun(runID: run.id)) }
        )
      }
    }
  }

  private var sortedRuns: [WorkflowRun] {
    store.runs.sorted { $0.startedAt > $1.startedAt }
  }

  // MARK: - Helpers

  private func workflowName(for id: UUID) -> String {
    workflows.first { $0.id == id }?.name ?? "Workflow"
  }

  private func lastRun(forProjectID projectID: String) -> WorkflowRun? {
    store.state.runs(forProjectID: projectID).max { $0.startedAt < $1.startedAt }
  }

  private func launch(_ workflow: WorkflowDefinition, in repository: Repository) {
    guard let worktree = repository.worktrees.first else { return }
    store.send(
      .presentLauncher(
        .init(
          workflow: workflow,
          worktree: worktree,
          projectID: repository.id,
          projectName: repository.name
        )
      )
    )
  }

  private func followUp(run: WorkflowRun, action: WorkflowFollowUpAction) {
    guard let worktree = repositories[id: run.projectID]?.worktrees.first else { return }
    store.send(.followUp(runID: run.id, worktree: worktree, action: action))
  }
}
