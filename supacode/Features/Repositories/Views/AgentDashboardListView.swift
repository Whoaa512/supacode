import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Cross-repo agent list plus the Spaces rollup (the Agents sidebar tab). A dumb
/// iterator over `state.agentDashboardStructure`: every display field — including
/// the grouped sections and the per-repo rollup — is resolved in the reducer, so
/// this body never reads `sidebarItems[id:]`.
struct AgentDashboardListView: View {
  let store: StoreOf<RepositoriesFeature>
  @Shared(.sidebarTab) private var sidebarTabRawValue: String
  @Shared(.sidebarAgentsGroupByState) private var groupByState: Bool

  var body: some View {
    let structure = store.agentDashboardStructure

    return VStack(spacing: 0) {
      HStack(spacing: 4) {
        Spacer(minLength: 0)
        Toggle(isOn: Binding(get: { groupByState }, set: { new in $groupByState.withLock { $0 = new } })) {
          Label("Group by State", systemImage: "rectangle.3.group")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .help("Group agents into Blocked, Working, Done, Idle, and Unknown sections")
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 4)

      List {
        if structure.entries.isEmpty {
          Text("No active agents")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowSeparator(.hidden)
        }
        if structure.sections.isEmpty {
          ForEach(structure.entries) { entry in
            agentRow(entry)
          }
        } else {
          ForEach(structure.sections) { section in
            Section("\(section.title) (\(section.count))") {
              ForEach(section.entries) { entry in
                agentRow(entry)
              }
            }
          }
        }
        if !structure.spaces.isEmpty {
          Section("Spaces") {
            ForEach(structure.spaces) { space in
              spaceRow(space)
            }
          }
        }
      }
      .listStyle(.sidebar)
    }
    .frame(minWidth: 220)
    .onChange(of: groupByState, initial: false) { _, _ in
      store.send(.sidebarAgentsGroupByStateChanged)
    }
  }

  private func agentRow(_ entry: AgentDashboardEntry) -> some View {
    Button {
      store.send(.selectionChanged([.worktree(entry.worktreeID)], focusTerminal: true))
    } label: {
      AgentDashboardRowView(entry: entry)
    }
    .buttonStyle(.plain)
    .help("Focus \(entry.displayName) in \(entry.title) — \(entry.state.title)")
    .contextMenu {
      Button(entry.name == nil ? "Name Agent…" : "Rename Agent…") {
        store.send(.requestRenameAgent(entry.id))
      }
      .help("Give this agent a name `supacode agent` can address")
    }
  }

  /// Jumping to a repository means leaving the Agents tab: expand the repo's
  /// section so the Worktrees tree lands on it already open.
  private func spaceRow(_ space: AgentDashboardStructure.SpaceEntry) -> some View {
    Button {
      store.send(.repositoryExpansionChanged(space.id, isExpanded: true))
      $sidebarTabRawValue.withLock { $0 = SidebarTab.worktrees.rawValue }
    } label: {
      AgentDashboardSpaceRowView(space: space)
    }
    .buttonStyle(.plain)
    .help("Show \(space.title) in the Worktrees panel")
  }
}

private struct AgentDashboardRowView: View {
  let entry: AgentDashboardEntry

  var body: some View {
    HStack(spacing: 8) {
      if entry.rowLines.isEmpty {
        builtInLayout
      } else {
        AgentDashboardConfiguredRowView(entry: entry)
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

  /// The layout the Agents tab shipped with, kept as the default-config path so
  /// an untouched `supacode.json` renders exactly as before.
  private var builtInLayout: some View {
    HStack(spacing: 8) {
      Image(systemName: entry.state.systemImage)
        .foregroundStyle(AgentDashboardStateStyle.style(for: entry.state, hasError: entry.hasError))
        .accessibilityLabel(entry.state.title)
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.displayName)
          .font(.body)
          .monospaced(entry.name != nil)
          .lineLimit(1)
        Text(entry.subtitle)
          .font(.caption)
          .monospaced()
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        // Agent-reported `summary` token. Display-only, so it sits below the
        // semantic subtitle rather than replacing anything.
        if let summary = entry.summary {
          Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
    }
  }
}

/// Renders `entry.rowLines` verbatim: the first line is the headline, the rest
/// are captions. Segment kinds only pick styling — order and content are the
/// user's `agentsSidebar.rows` config, already resolved reducer-side.
private struct AgentDashboardConfiguredRowView: View {
  let entry: AgentDashboardEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(Array(entry.rowLines.enumerated()), id: \.offset) { index, line in
        HStack(spacing: 6) {
          ForEach(Array(line.enumerated()), id: \.offset) { _, segment in
            segmentView(segment, isHeadline: index == 0)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func segmentView(_ segment: AgentRowSegment, isHeadline: Bool) -> some View {
    switch segment.kind {
    case .stateIcon:
      Image(systemName: entry.state.systemImage)
        .foregroundStyle(AgentDashboardStateStyle.style(for: entry.state, hasError: entry.hasError))
        .accessibilityLabel(entry.state.title)
    default:
      Text(segment.text)
        .font(isHeadline ? .body : .caption)
        .monospaced(segment.kind == .branch || segment.kind == .worktree)
        .foregroundStyle(isHeadline ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

private struct AgentDashboardSpaceRowView: View {
  let space: AgentDashboardStructure.SpaceEntry

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(space.tint?.color ?? Color.secondary)
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
      Text(space.title)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
      Text("\(space.worktreeCount)")
        .font(.caption)
        .monospaced()
        .foregroundStyle(.secondary)
      if let state = space.state {
        Image(systemName: state.systemImage)
          .foregroundStyle(AgentDashboardStateStyle.style(for: state, hasError: false))
          .accessibilityLabel(state.title)
      }
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }
}

/// Shared tinting for the state glyph so agent rows and Spaces rows can't drift.
private enum AgentDashboardStateStyle {
  static func style(for state: AgentDashboardState, hasError: Bool) -> AnyShapeStyle {
    if hasError { return AnyShapeStyle(.red) }
    return switch state {
    case .blocked: AnyShapeStyle(.orange)
    case .working: AnyShapeStyle(.tint)
    case .done: AnyShapeStyle(.green)
    case .idle, .unknown: AnyShapeStyle(.secondary)
    }
  }
}
