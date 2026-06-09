import SupacodeSettingsShared
import SwiftUI

/// One project in the command center grid: name, path, activity, favorite
/// workflow buttons, an "all workflows" menu, and the last run summary.
struct ProjectCardView: View {
  let repository: Repository
  let favorites: [WorkflowDefinition]
  let allWorkflows: [WorkflowDefinition]
  let activeRunCount: Int
  let lastRun: WorkflowRun?
  let workflowName: (UUID) -> String
  let onLaunch: (WorkflowDefinition) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      Divider()
      favoriteButtons
      footer
    }
    .padding(14)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(repository.name).font(.headline).lineLimit(1)
        Spacer()
        activityBadge
      }
      Text(repository.rootURL.path(percentEncoded: false))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var activityBadge: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(activeRunCount > 0 ? Color.green : Color.secondary)
        .frame(width: 7, height: 7)
      Text(activeRunCount > 0 ? "\(activeRunCount) active" : "idle")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var favoriteButtons: some View {
    FlowLayout(spacing: 6) {
      ForEach(favorites) { workflow in
        Button {
          onLaunch(workflow)
        } label: {
          Label(workflow.name, systemImage: workflow.systemImage)
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(workflow.tintColor.color)
        .help("Launch \(workflow.name) in \(repository.name)")
      }
      workflowMenu
    }
  }

  private var workflowMenu: some View {
    Menu {
      ForEach(WorkflowCategory.allCases, id: \.self) { category in
        let inCategory = allWorkflows.filter { $0.category == category }
        if !inCategory.isEmpty {
          Section(category.displayName) {
            ForEach(inCategory) { workflow in
              Button(workflow.name) { onLaunch(workflow) }
            }
          }
        }
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
        .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("All workflows")
  }

  @ViewBuilder private var footer: some View {
    if let lastRun {
      Text("last: \(workflowName(lastRun.workflowID)) · \(lastRun.status.displayName)")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}
