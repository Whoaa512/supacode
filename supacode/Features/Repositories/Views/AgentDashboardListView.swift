import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Flat cross-repo agent list (the Agents sidebar tab). A dumb iterator over
/// `state.agentDashboardStructure`: every display field is resolved in the
/// reducer, so this body never reads `sidebarItems[id:]`.
struct AgentDashboardListView: View {
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    let entries = store.agentDashboardStructure.entries

    return List {
      if entries.isEmpty {
        Text("No active agents")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .listRowSeparator(.hidden)
      }
      ForEach(entries) { entry in
        Button {
          store.send(.selectionChanged([.worktree(entry.worktreeID)], focusTerminal: true))
        } label: {
          AgentDashboardRowView(entry: entry)
        }
        .buttonStyle(.plain)
        .help("Focus \(entry.agent.displayName) in \(entry.title) — \(entry.state.title)")
      }
    }
    .listStyle(.sidebar)
    .frame(minWidth: 220)
  }
}

private struct AgentDashboardRowView: View {
  let entry: AgentDashboardEntry

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: entry.state.systemImage)
        .foregroundStyle(iconStyle)
        .accessibilityLabel(entry.state.title)
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.agent.displayName)
          .font(.body)
          .lineLimit(1)
        Text(entry.subtitle)
          .font(.caption)
          .monospaced()
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if let tint = entry.repoTint {
        Circle()
          .fill(tint.color)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
      }
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  private var iconStyle: some ShapeStyle {
    if entry.hasError { return AnyShapeStyle(.red) }
    return switch entry.state {
    case .blocked: AnyShapeStyle(.orange)
    case .working: AnyShapeStyle(.tint)
    case .done: AnyShapeStyle(.green)
    case .idle, .unknown: AnyShapeStyle(.secondary)
    }
  }
}
