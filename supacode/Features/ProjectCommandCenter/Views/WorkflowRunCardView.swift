import SupacodeSettingsShared
import SwiftUI

/// A live or completed workflow run with follow-up steering actions.
struct WorkflowRunCardView: View {
  let run: WorkflowRun
  let workflowName: String
  let projectName: String
  let onFollowUp: (WorkflowFollowUpAction) -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: statusSymbol)
          .foregroundStyle(statusColor)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(workflowName).font(.subheadline).bold()
          Text("\(projectName) · \(run.status.displayName)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !run.isActive {
          Button {
            onDismiss()
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Dismiss run")
          .help("Dismiss run")
        }
      }
      if !run.followUpActions.isEmpty {
        FlowLayout(spacing: 6) {
          ForEach(run.followUpActions, id: \.self) { action in
            Button(action.displayName) { onFollowUp(action) }
              .font(.caption)
              .buttonStyle(.bordered)
              .help(helpText(for: action))
          }
        }
      }
    }
    .padding(12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
  }

  private var statusSymbol: String {
    switch run.status {
    case .idle: "circle"
    case .active: "circle.fill"
    case .attentionNeeded: "exclamationmark.circle.fill"
    case .complete: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    case .stopped: "stop.circle"
    }
  }

  private var statusColor: Color {
    switch run.status {
    case .idle, .stopped: .secondary
    case .active: .green
    case .attentionNeeded: .orange
    case .complete: .blue
    case .failed: .red
    }
  }

  private func helpText(for action: WorkflowFollowUpAction) -> String {
    if let text = action.promptText {
      return "Send \"\(text)\" into the run"
    }
    switch action {
    case .copy: return "Copy the launch command"
    case .stop: return "Mark this run as stopped"
    default: return action.displayName
    }
  }
}
