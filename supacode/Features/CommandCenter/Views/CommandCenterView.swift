import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct CommandCenterView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 12) {
        ForEach(store.repositories.repositories) { repository in
          ProjectCardView(
            repository: repository,
            runs: store.commandCenter.runs.filter { $0.repositoryID == repository.id },
            onLaunchWorkflow: { workflow in
              guard let worktreeID = primaryWorktreeID(for: repository) else { return }
              store.send(.commandCenter(.launchWorkflow(
                workflow,
                repositoryID: repository.id,
                worktreeID: worktreeID,
                context: store.commandCenter.clipboardText
              )))
            },
            onFollowUp: { runID, text in
              store.send(.commandCenter(.sendFollowUp(runID: runID, text: text)))
            }
          )
        }
      }
      .padding()
    }
    .frame(minWidth: 280)
  }

  private func primaryWorktreeID(for repository: Repository) -> Worktree.ID? {
    if !repository.isGitRepository {
      return Repository.folderWorktreeID(for: repository.rootURL)
    }
    return repository.worktrees.first?.id
  }
}

struct ProjectCardView: View {
  let repository: Repository
  let runs: [WorkflowRun]
  let onLaunchWorkflow: (WorkflowDefinition) -> Void
  let onFollowUp: (WorkflowRun.ID, String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(repository.name)
          .font(.headline)
        Spacer()
        if !runs.isEmpty {
          statusIndicator
        }
      }

      Text(repository.rootURL.path(percentEncoded: false))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      workflowButtons

      if !runs.isEmpty {
        Divider()
        ForEach(runs) { run in
          RunCardView(run: run, onFollowUp: onFollowUp)
        }
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.3))
    .clipShape(.rect(cornerRadius: 8))
  }

  @ViewBuilder
  private var statusIndicator: some View {
    let activeCount = runs.filter { $0.status == .active }.count
    let attentionCount = runs.filter { $0.status == .attentionNeeded }.count
    if attentionCount > 0 {
      Label("\(attentionCount)", systemImage: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
    } else if activeCount > 0 {
      Label("\(activeCount) active", systemImage: "circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    }
  }

  private var workflowButtons: some View {
    FlowLayout(spacing: 6) {
      ForEach(WorkflowDefinition.builtIns.filter(\.isFavorite)) { workflow in
        Button {
          onLaunchWorkflow(workflow)
        } label: {
          Label(workflow.name, systemImage: workflow.systemImage)
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Launch \(workflow.name)")
      }
    }
  }
}

struct RunCardView: View {
  let run: WorkflowRun
  let onFollowUp: (WorkflowRun.ID, String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
        Text(workflowName)
          .font(.caption.weight(.medium))
        Spacer()
        Text(run.startedAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if run.status == .active || run.status == .attentionNeeded {
        HStack(spacing: 4) {
          followUpButton("intme", text: "intme")
          followUpButton("verify", text: "verify")
          followUpButton("fix", text: "fix")
          followUpButton("cont", text: "cont")
          followUpButton("handoff", text: "handoff")
        }
      }
    }
  }

  private var statusColor: Color {
    switch run.status {
    case .idle: .gray
    case .active: .green
    case .attentionNeeded: .orange
    case .complete: .blue
    }
  }

  private var workflowName: String {
    WorkflowDefinition.builtIns.first { $0.id == run.workflowID }?.name ?? "Workflow"
  }

  private func followUpButton(_ label: String, text: String) -> some View {
    Button(label) {
      onFollowUp(run.id, text)
    }
    .font(.caption2)
    .buttonStyle(.bordered)
    .controlSize(.mini)
  }
}

struct FlowLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = arrangeSubviews(proposal: proposal, subviews: subviews)
    return result.size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrangeSubviews(proposal: proposal, subviews: subviews)
    for (index, offset) in result.offsets.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
        proposal: .unspecified
      )
    }
  }

  private struct ArrangementResult {
    var offsets: [CGPoint]
    var size: CGSize
  }

  private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> ArrangementResult {
    let maxWidth = proposal.width ?? .infinity
    var offsets: [CGPoint] = []
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var totalWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if currentX + size.width > maxWidth, currentX > 0 {
        currentX = 0
        currentY += rowHeight + spacing
        rowHeight = 0
      }
      offsets.append(CGPoint(x: currentX, y: currentY))
      rowHeight = max(rowHeight, size.height)
      currentX += size.width + spacing
      totalWidth = max(totalWidth, currentX - spacing)
      totalHeight = max(totalHeight, currentY + rowHeight)
    }

    return ArrangementResult(offsets: offsets, size: CGSize(width: totalWidth, height: totalHeight))
  }
}
