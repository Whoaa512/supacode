import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Full-screen modal grid of every terminal surface: live ones (updating
/// preview), hibernated ones, and snoozed worktrees not yet restored this
/// launch (last on-disk snapshot). Tiles carry a directory › tab breadcrumb.
/// Click or Return jumps to a surface (dismisses the modal), Delete closes
/// the selected surface, ⇧Delete closes its whole tab, Esc dismisses.
struct TerminalGridOverviewView: View {
  let store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager

  @State private var selectedSurfaceID: UUID?
  @State private var containerWidth: CGFloat = 1200
  /// Disk-tail previews for dormant / snoozed surfaces. Their dumps can't
  /// change while dormant, so one read per surface per modal presentation.
  /// Reference-typed: filled lazily during render, which a `@State` dict
  /// mutation would flag as "modifying state during view update".
  @State private var diskPreviewCache = DiskPreviewCache()
  @FocusState private var isGridFocused: Bool
  @Shared(.layouts) private var layouts: [String: TerminalLayoutSnapshot] = [:]
  @Shared(.settingsFile) private var settingsFile: SettingsFile

  typealias Tile = TerminalGridOverview.Tile

  private static let gridSpacing: CGFloat = 16
  private static let previewLineLimit = 40
  /// A new column only appears once every column can be at least this wide,
  /// so between breakpoints the existing tiles grow to absorb the width.
  private static let idealTileWidth: CGFloat = 440
  /// Floor below which the minimum-column rule yields to keep tiles legible.
  private static let minimumTileWidth: CGFloat = 300
  /// YouTube-home baseline: never fewer than this many across (unless the
  /// window is too narrow for them at `minimumTileWidth`).
  private static let minimumColumns = 3

  /// YouTube-style responsive columns: at least `minimumColumns` across,
  /// tiles grow with the window, and another column appears only when it
  /// fits at `idealTileWidth`. Independent of tile count so the grid reads
  /// the same with 2 sessions or 20.
  static func columnCount(width: CGFloat) -> Int {
    let byIdealWidth = Int(width / idealTileWidth)
    let byMinimumWidth = max(1, Int(width / minimumTileWidth))
    return max(1, min(max(byIdealWidth, minimumColumns), byMinimumWidth))
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
      content
    }
    .background(.regularMaterial)
    .focusable()
    .focused($isGridFocused)
    .focusEffectDisabled()
    .onAppear { isGridFocused = true }
    .onExitCommand { store.send(.setTerminalGridPresented(false)) }
    .onKeyPress(action: handleKeyPress)
    .accessibilityLabel("Terminal grid overview")
  }

  @ViewBuilder
  private var content: some View {
    let ordered = orderedTiles()
    let counts = TerminalGridOverview.counts(for: ordered)
    let tiles = TerminalGridOverview.filtered(ordered, by: store.terminalGridFilter)
    VStack(spacing: 0) {
      header(counts: counts)
      if tiles.isEmpty {
        emptyState(isFiltered: store.terminalGridFilter != .all)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        grid(tiles: tiles)
      }
      footer
    }
    .onChange(of: tiles.map(\.id), initial: true) { _, ids in
      // Keep selection valid as surfaces come and go under the timeline.
      guard let selected = selectedSurfaceID, ids.contains(selected) else {
        selectedSurfaceID = ids.first
        return
      }
    }
  }

  @ViewBuilder
  private func emptyState(isFiltered: Bool) -> some View {
    if isFiltered {
      ContentUnavailableView {
        Label("No \(store.terminalGridFilter.label) Terminals", systemImage: "line.3.horizontal.decrease.circle")
      } description: {
        Text("Nothing matches this filter right now.")
      } actions: {
        Button("Show All") { store.send(.setTerminalGridFilter(.all)) }
          .help("Clear the activity filter")
      }
    } else {
      ContentUnavailableView(
        "No Terminal Sessions",
        systemImage: "terminal",
        description: Text("Open a terminal in a worktree and it will show up here.")
      )
    }
  }

  private func header(counts: TerminalGridOverview.Counts) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Terminal Overview")
          .font(.title2.bold())
        Text("\(counts.total) \(counts.total == 1 ? "surface" : "surfaces")")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          store.send(.setTerminalGridPresented(false))
        } label: {
          Label("Close Overview", systemImage: "xmark.circle.fill")
            .labelStyle(.iconOnly)
            .font(.title2)
        }
        .buttonStyle(.borderless)
        .help("Close overview (Esc)")
      }
      filterChips(counts: counts)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
  }

  /// Rollup counts double as the filter control: each chip shows its bucket's
  /// count over the unfiltered tiles, so the numbers stay put while filtering.
  private func filterChips(counts: TerminalGridOverview.Counts) -> some View {
    HStack(spacing: 8) {
      ForEach(TerminalGridOverview.Filter.allCases, id: \.self) { filter in
        let count = counts.count(for: filter)
        let isSelected = store.terminalGridFilter == filter
        Button {
          store.send(.setTerminalGridFilter(filter))
        } label: {
          HStack(spacing: 5) {
            if case .activity(let activity) = filter {
              Image(systemName: activity.systemImage)
                .imageScale(.small)
                .accessibilityHidden(true)
            }
            Text(filter.label)
            Text("\(count)")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          .font(.callout)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            isSelected ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary),
            in: Capsule()
          )
          .overlay(Capsule().strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && filter != .all)
        .help("Show only \(filter.label.lowercased()) terminals (\(count))")
        .accessibilityLabel("\(filter.label), \(count)")
      }
      Spacer(minLength: 0)
    }
  }

  private var footer: some View {
    HStack(spacing: 16) {
      keyHint("↑↓←→", "Navigate")
      keyHint("↩", "Jump")
      keyHint("⌫", "Close terminal")
      keyHint("⇧⌫", "Close tab")
      keyHint("esc", "Dismiss")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.vertical, 10)
  }

  private func keyHint(_ key: String, _ label: String) -> some View {
    HStack(spacing: 4) {
      Text(key)
        .font(.caption.monospaced())
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
      Text(label)
    }
  }

  private func grid(tiles: [Tile]) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
            count: Self.columnCount(width: containerWidth)
          ),
          spacing: Self.gridSpacing
        ) {
          let background = terminalManager.ghosttyRuntime.backgroundColor()
          let foreground: Color = background.isLightColor ? .black : .white
          ForEach(tiles) { tile in
            TerminalGridTileView(
              tile: tile,
              isSelected: tile.id == selectedSurfaceID,
              previewText: previewText(for: tile),
              agentBadgesEnabled: settingsFile.global.agentPresenceBadgesEnabled,
              terminalBackground: Color(nsColor: background),
              terminalForeground: foreground,
              onJump: { jump(to: tile) },
              onCloseSurface: tile.kind == .snoozed ? nil : { closeSurface(tile) }
            )
            .id(tile.id)
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
          containerWidth = width
        }
      }
      .onChange(of: selectedSurfaceID) { _, newValue in
        guard let newValue else { return }
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo(newValue, anchor: nil)
        }
      }
    }
  }

  // MARK: - Keyboard.

  private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
    // Navigation runs over the filtered list so arrows never land on a hidden tile.
    let tiles = TerminalGridOverview.filtered(orderedTiles(), by: store.terminalGridFilter)
    guard !tiles.isEmpty else {
      if press.key == .escape {
        store.send(.setTerminalGridPresented(false))
        return .handled
      }
      return .ignored
    }
    let currentIndex = tiles.firstIndex { $0.id == selectedSurfaceID } ?? 0
    let columnCount = Self.columnCount(width: containerWidth)

    switch press.key {
    case .rightArrow:
      select(index: currentIndex + 1, in: tiles)
      return .handled
    case .leftArrow:
      select(index: currentIndex - 1, in: tiles)
      return .handled
    case .downArrow:
      select(index: currentIndex + columnCount, in: tiles)
      return .handled
    case .upArrow:
      select(index: currentIndex - columnCount, in: tiles)
      return .handled
    case .return:
      jump(to: tiles[currentIndex])
      return .handled
    case .delete:
      let tile = tiles[currentIndex]
      // Snoozed surfaces have no live state to tear down; restore them first.
      guard tile.kind != .snoozed else { return .handled }
      if press.modifiers.contains(.shift) {
        store.send(.closeTerminalTab(worktreeID: tile.worktreeID, tabID: tile.tabID))
      } else {
        closeSurface(tile)
      }
      return .handled
    case .escape:
      store.send(.setTerminalGridPresented(false))
      return .handled
    default:
      return .ignored
    }
  }

  private func select(index: Int, in tiles: [Tile]) {
    guard tiles.indices.contains(index) else { return }
    selectedSurfaceID = tiles[index].id
  }

  private func jump(to tile: Tile) {
    store.send(
      .terminalGridJumpToSurface(
        worktreeID: tile.worktreeID, tabID: tile.tabID, surfaceID: tile.surfaceID))
  }

  private func closeSurface(_ tile: Tile) {
    store.send(
      .closeTerminalSurface(
        worktreeID: tile.worktreeID, tabID: tile.tabID, surfaceID: tile.surfaceID))
  }

  // MARK: - Previews.

  private func previewText(for tile: Tile) -> AttributedString? {
    switch tile.kind {
    case .live:
      let contents =
        terminalManager.screenPreview(worktreeID: tile.worktreeID, surfaceID: tile.surfaceID) ?? ""
      var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
      while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeLast()
      }
      guard !lines.isEmpty else { return nil }
      return AttributedString(lines.suffix(Self.previewLineLimit).joined(separator: "\n"))
    case .dormant, .snoozed:
      return diskPreviewCache.tail(for: tile.surfaceID, maxLines: Self.previewLineLimit)
    }
  }

  @MainActor
  final class DiskPreviewCache {
    private var previews: [UUID: AttributedString?] = [:]

    func tail(for surfaceID: UUID, maxLines: Int) -> AttributedString? {
      if let cached = previews[surfaceID] {
        return cached
      }
      let styled = ScrollbackPreview.tail(
        surfaceID: surfaceID, maxLines: maxLines, keepingSGRStyles: true
      ).map(AnsiStyledText.attributedString(from:))
      previews[surfaceID] = styled
      return styled
    }
  }

  // MARK: - Tiles.

  /// Every tile, clustered by repository, before the activity filter applies.
  private func orderedTiles() -> [Tile] {
    let presence = store.agentPresence
    let lookup: (Worktree.ID) -> Worktree? = { store.repositories.worktree(for: $0) }
    // Presence is read ungated: the header counts and filters are a triage
    // signal like the sidebar shimmer. Only the badge row honors the toggle.
    let live = TerminalGridOverview.liveTiles(
      terminalManager.sessionOverviews(),
      worktreeLookup: lookup,
      agentsForSurface: { presence.agents(across: [$0], badgesEnabled: true) }
    )
    let snoozed = TerminalGridOverview.snoozedTiles(
      layouts: layouts,
      excludingWorktreeIDs: Set(live.map(\.worktreeID)),
      worktreeLookup: lookup
    )
    return TerminalGridOverview.clustered(live + snoozed)
  }
}

/// One surface tile: directory › tab breadcrumb above a terminal-styled
/// text preview. Asleep surfaces show their last on-disk snapshot, dimmed,
/// with a moon badge.
private struct TerminalGridTileView: View {
  let tile: TerminalGridOverviewView.Tile
  let isSelected: Bool
  let previewText: AttributedString?
  let agentBadgesEnabled: Bool
  let terminalBackground: Color
  let terminalForeground: Color
  let onJump: () -> Void
  let onCloseSurface: (() -> Void)?

  @State private var isHovering = false
  @State private var tileWidth: CGFloat = 340

  private var isAsleep: Bool { tile.kind != .live }

  /// Terminal-ish density at any tile size: bigger tiles get bigger type
  /// instead of a postage stamp of caption text in a sea of black.
  private var previewFontSize: CGFloat {
    min(15, max(10, tileWidth / 42))
  }

  var body: some View {
    Button(action: onJump) {
      tileContent
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(isAsleep ? "Wake and jump to this terminal" : "Jump to this terminal")
    .accessibilityLabel(
      "\(tile.directoryName), \(tile.tabTitle), \(tile.activity.label)"
    )
  }

  private var tileContent: some View {
    VStack(alignment: .leading, spacing: 6) {
      breadcrumb
      // The theme-colored rectangle owns the tile's size (grid width × fixed
      // aspect); the preview text lives in an overlay so its natural size
      // can never inflate the layout, and overflow clips at the tile edge.
      terminalBackground
        .aspectRatio(1.6, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottomLeading) { preview }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
              isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
              lineWidth: isSelected ? 2.5 : 1
            )
        )
        .overlay(alignment: .topTrailing) { previewBadges }
        .shadow(color: .black.opacity(isSelected ? 0.35 : 0.15), radius: isSelected ? 8 : 4, y: 2)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
          tileWidth = width
        }
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var previewBadges: some View {
    HStack(spacing: 6) {
      if tile.activity == .busy || tile.activity == .blocked {
        Image(systemName: tile.activity.systemImage)
          .imageScale(.small)
          .foregroundStyle(tile.activity == .blocked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .padding(5)
          .background(.regularMaterial, in: Circle())
          .help(tile.activity == .blocked ? "An agent is waiting on you" : "An agent is working")
          .accessibilityHidden(true)
      }
      if isAsleep {
        Image(systemName: "moon.zzz.fill")
          .foregroundStyle(.secondary)
          .padding(4)
          .background(.regularMaterial, in: Circle())
          .help("Asleep — showing the last snapshot")
          .accessibilityHidden(true)
      }
      if isHovering, let onCloseSurface {
        Button(role: .destructive, action: onCloseSurface) {
          Label("Close Terminal", systemImage: "xmark.circle.fill")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Close this terminal surface")
      }
    }
    .padding(6)
  }

  private var breadcrumb: some View {
    HStack(spacing: 4) {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(tile.directoryName)
        .fontWeight(.semibold)
        .lineLimit(1)
        .truncationMode(.middle)
      if tile.tabTitle != tile.directoryName {
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
        Text(tile.tabTitle)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
      if agentBadgesEnabled, !tile.agents.isEmpty {
        AgentAvatarGroupView(instances: tile.agents)
      }
    }
    .font(.callout)
    .padding(.horizontal, 2)
  }

  @ViewBuilder
  private var preview: some View {
    if let previewText {
      // fixedSize keeps long lines on one line (clipped right) like a real
      // terminal. Bottom-aligned so the tail (prompt, latest output) is
      // always visible; SGR-colored runs carry their own colors and the
      // theme foreground fills the rest.
      Text(previewText)
        .font(.system(size: previewFontSize, design: .monospaced))
        .foregroundStyle(terminalForeground)
        .opacity(isAsleep ? 0.55 : 0.95)
        .fixedSize(horizontal: true, vertical: true)
        .padding(10)
    } else {
      VStack(spacing: 6) {
        Image(systemName: isAsleep ? "moon.zzz" : "terminal")
          .font(.title3)
          .accessibilityHidden(true)
        Text(isAsleep ? "Asleep" : "No output")
          .font(.caption)
      }
      .foregroundStyle(terminalForeground.opacity(0.5))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }
}
