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
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.sidebarTab) private var sidebarTabRawValue: String
  @Shared(.sidebarAgentsGroupByState) private var groupByState: Bool
  @Shared(.settingsFile) private var settingsFile

  /// Mirrors the Worktrees panel: native `List` selection supplies the highlight,
  /// so both panels can't drift visually. Writes route through the reducer, which
  /// owns the keyboard selection.
  private var keyboardSelection: Binding<AgentDashboardEntry.EntryID?> {
    Binding(
      get: { store.agentDashboardSelection },
      set: { store.send(.agentDashboardSelectionChanged($0)) }
    )
  }

  var body: some View {
    let structure = store.agentDashboardStructure
    let toggleTabShortcut =
      AppShortcuts.toggleAgentsSidebarTab
      .effective(from: settingsFile.global.shortcutOverrides)?.display ?? "none"

    // The only legal view-side computation, same as the Worktrees panel: a
    // trivial join from the reducer-derived `slotByID` against the ⌘ state +
    // shortcut overrides. Rows past the last ⌃n shortcut resolve to nil and drop
    // out, so only the first nine carry a hint.
    let shortcutHintByID: [AgentDashboardEntry.EntryID: String]
    if commandKeyObserver.isPressed {
      let overrides = settingsFile.global.shortcutOverrides
      shortcutHintByID = structure.slotByID.compactMapValues { index in
        AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: index, overrides: overrides)
      }
    } else {
      shortcutHintByID = [:]
    }

    return VStack(spacing: 0) {
      HStack(spacing: 4) {
        Spacer(minLength: 0)
        Toggle(isOn: Binding(get: { groupByState }, set: { new in $groupByState.withLock { $0 = new } })) {
          Label("Group by State", systemImage: "rectangle.3.group")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .help(
          "Group agents into Blocked, Working, Done, Idle, and Unknown sections. "
            + "Turn it off for one flat list, still ordered by triage urgency."
        )
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 4)

      ScrollViewReader { scrollProxy in
        agentList(
          structure,
          toggleTabShortcut: toggleTabShortcut,
          shortcutHintByID: shortcutHintByID
        )
          .onChange(of: store.agentDashboardSelection, initial: false) { _, selection in
            guard let selection else { return }
            scrollProxy.scrollTo(selection, anchor: .center)
          }
      }
    }
    .frame(minWidth: 220)
    .onChange(of: groupByState, initial: false) { _, _ in
      store.send(.sidebarAgentsGroupByStateChanged)
    }
  }

  private func agentList(
    _ structure: AgentDashboardStructure,
    toggleTabShortcut: String,
    shortcutHintByID: [AgentDashboardEntry.EntryID: String]
  ) -> some View {
    List(selection: keyboardSelection) {
      if structure.entries.isEmpty {
        Text("No active agents")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .listRowSeparator(.hidden)
          .help("No agent has reported activity yet. Start one in a worktree terminal to see it here.")
      }
      if structure.sections.isEmpty {
        ForEach(structure.entries) { entry in
          agentRow(entry, shortcutHint: shortcutHintByID[entry.id])
        }
      } else {
        ForEach(structure.sections) { section in
          Section {
            ForEach(section.entries) { entry in
              agentRow(entry, shortcutHint: shortcutHintByID[entry.id])
            }
          } header: {
            Text("\(section.title) (\(section.count))")
              .help("\(section.count) agent(s) — \(section.state.help)")
          }
        }
      }
      if !structure.spaces.isEmpty {
        Section {
          ForEach(structure.spaces) { space in
            spaceRow(space, toggleTabShortcut: toggleTabShortcut)
          }
        } header: {
          Text("Spaces")
            .help("One row per repository, with its worktree count and worst agent state rolled up")
        }
      }
    }
    .listStyle(.sidebar)
    // ↵ on the selected row does what clicking it does. Scoped to the list so
    // it can't shadow Return anywhere else in the app.
    .onKeyPress(.return) {
      guard store.agentDashboardSelection != nil else { return .ignored }
      store.send(.activateAgentDashboardSelection)
      return .handled
    }
  }

  private func agentRow(_ entry: AgentDashboardEntry, shortcutHint: String?) -> some View {
    Button {
      store.send(.activateAgentDashboardEntry(entry.id))
    } label: {
      AgentDashboardRowView(entry: entry, shortcutHint: shortcutHint)
    }
    .buttonStyle(.plain)
    .tag(entry.id)
    .help(
      "Focus \(entry.displayName) in \(entry.title) — \(entry.state.help). "
        + "⌃⌘↓ / ⌃⌘↑ or ⌃1…⌃0 jump straight here. "
        + "Right-click to \(entry.name == nil ? "name" : "rename") it."
    )
    .contextMenu {
      Button(entry.name == nil ? "Name Agent…" : "Rename Agent…") {
        store.send(.requestRenameAgent(entry.id))
      }
      .help("Give this agent a name `supacode agent` can address")
    }
  }

  /// Jumping to a repository means leaving the Agents tab: expand the repo's
  /// section so the Worktrees tree lands on it already open.
  private func spaceRow(
    _ space: AgentDashboardStructure.SpaceEntry,
    toggleTabShortcut: String
  ) -> some View {
    Button {
      store.send(.repositoryExpansionChanged(space.id, isExpanded: true))
      $sidebarTabRawValue.withLock { $0 = SidebarTab.worktrees.rawValue }
    } label: {
      AgentDashboardSpaceRowView(space: space)
    }
    .buttonStyle(.plain)
    .help(
      "Show \(space.title) in the Worktrees panel — \(space.worktreeCount) worktree(s). "
        + "\(toggleTabShortcut) comes back to Agents."
    )
  }
}

private struct AgentDashboardRowView: View {
  let entry: AgentDashboardEntry
  /// Resolved ⌃n hint, non-nil only while the modifier is held on one of the
  /// first nine rows.
  let shortcutHint: String?

  var body: some View {
    HStack(spacing: 8) {
      if entry.rowLines.isEmpty {
        builtInLayout
      } else {
        AgentDashboardConfiguredRowView(entry: entry)
      }
      Spacer(minLength: 0)
      SidebarShortcutHintCrossfade(hint: shortcutHint) {
        if let tint = entry.repoTint {
          Circle()
            .fill(tint.color)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
            .help("Color assigned to \(entry.repositoryTitle)")
        }
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
        .help(entry.hasError ? "Error — the agent reported a failure" : entry.state.help)
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
        .help(entry.hasError ? "Error — the agent reported a failure" : entry.state.help)
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
        .help("Color assigned to \(space.title)")
      Text(space.title)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
      Text("\(space.worktreeCount)")
        .font(.caption)
        .monospaced()
        .foregroundStyle(.secondary)
        .help("\(space.worktreeCount) worktree(s) in \(space.title)")
      if let state = space.state {
        Image(systemName: state.systemImage)
          .foregroundStyle(AgentDashboardStateStyle.style(for: state, hasError: false))
          .accessibilityLabel(state.title)
          .help("Worst agent state across \(space.title): \(state.help)")
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
