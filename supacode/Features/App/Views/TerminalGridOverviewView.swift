import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct TerminalGridOverviewView: View {
  let store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager

  @Dependency(TerminalClient.self) private var terminalClient
  @Shared(.settingsFile) private var settingsFile
  @State private var selectedSurfaceID: UUID?
  @State private var containerWidth: CGFloat = 1200
  @State private var diskPreviewCache = DiskPreviewCache()
  @FocusState private var isGridFocused: Bool

  private static let gridSpacing: CGFloat = 16
  private static let idealTileWidth: CGFloat = 440
  private static let minimumTileWidth: CGFloat = 300
  private static let minimumColumns = 3
  private static let previewLineLimit = 40

  static func columnCount(width: CGFloat) -> Int {
    let byIdealWidth = Int(width / idealTileWidth)
    let byMinimumWidth = max(1, Int(width / minimumTileWidth))
    return max(1, min(max(byIdealWidth, minimumColumns), byMinimumWidth))
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      content
        .task(id: context.date) { store.send(.refreshTerminalGrid) }
    }
    .background(.regularMaterial)
    .ignoresSafeArea()
    .focusable()
    .focused($isGridFocused)
    .focusEffectDisabled()
    .onAppear { isGridFocused = true }
    .onExitCommand { store.send(.setTerminalGridPresented(false)) }
    .onKeyPress(action: handleKeyPress)
    .accessibilityLabel("Terminal grid overview")
  }

  private var content: some View {
    let model = store.terminalGridOverview
    return VStack(spacing: 0) {
      TerminalGridHeaderView(store: store, model: model)
      if model.visibleTiles.isEmpty {
        emptyState(isFiltered: model.filter != .all)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        grid(tiles: model.visibleTiles)
      }
      TerminalGridFooterView()
    }
    .onChange(of: model.visibleTiles.map(\.id), initial: true) { _, ids in
      guard let selectedSurfaceID, ids.contains(selectedSurfaceID) else {
        selectedSurfaceID = ids.first
        return
      }
    }
  }

  @ViewBuilder
  private func emptyState(isFiltered: Bool) -> some View {
    if isFiltered {
      ContentUnavailableView {
        Label(
          "No \(store.terminalGridOverview.filter.label) Terminals",
          systemImage: "line.3.horizontal.decrease.circle"
        )
      } description: {
        Text("Nothing matches this filter right now.")
      } actions: {
        Button("Show All") { store.send(.setTerminalGridFilter(.all)) }
          .help("Clear the terminal activity filter")
      }
    } else {
      ContentUnavailableView(
        "No Terminal Sessions",
        systemImage: "terminal",
        description: Text("Open a terminal in a worktree and it will show up here.")
      )
    }
  }

  private func grid(tiles: [TerminalGridOverview.Tile]) -> some View {
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
              onClose: { closeSurface(tile) }
            )
            .id(tile.id)
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { containerWidth = $0 }
      }
      .onChange(of: selectedSurfaceID) { _, newValue in
        guard let newValue else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue) }
      }
    }
  }

  private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
    let tiles = store.terminalGridOverview.visibleTiles
    guard !tiles.isEmpty else { return .ignored }
    let currentIndex = tiles.firstIndex { $0.id == selectedSurfaceID } ?? 0
    let columns = Self.columnCount(width: containerWidth)
    switch press.key {
    case .rightArrow: select(currentIndex + 1, in: tiles)
    case .leftArrow: select(currentIndex - 1, in: tiles)
    case .downArrow: select(currentIndex + columns, in: tiles)
    case .upArrow: select(currentIndex - columns, in: tiles)
    case .return: jump(to: tiles[currentIndex])
    case .delete:
      let tile = tiles[currentIndex]
      if press.modifiers.contains(.shift) {
        store.send(.closeTerminalTab(worktreeID: tile.worktreeID, tabID: tile.tabID))
      } else {
        closeSurface(tile)
      }
    case .escape: store.send(.setTerminalGridPresented(false))
    default: return .ignored
    }
    return .handled
  }

  private func select(_ index: Int, in tiles: [TerminalGridOverview.Tile]) {
    guard tiles.indices.contains(index) else { return }
    selectedSurfaceID = tiles[index].id
  }

  private func jump(to tile: TerminalGridOverview.Tile) {
    store.send(
      .terminalGridJumpToSurface(
        worktreeID: tile.worktreeID,
        tabID: tile.tabID,
        surfaceID: tile.surfaceID
      )
    )
  }

  private func closeSurface(_ tile: TerminalGridOverview.Tile) {
    store.send(
      .closeTerminalSurface(
        worktreeID: tile.worktreeID,
        tabID: tile.tabID,
        surfaceID: tile.surfaceID
      )
    )
  }

  private func previewText(for tile: TerminalGridOverview.Tile) -> AttributedString? {
    if tile.availability == .live {
      guard let contents = terminalClient.sessionPreview(tile.worktreeID, tile.surfaceID) else { return nil }
      var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
      while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeLast()
      }
      guard !lines.isEmpty else { return nil }
      return AttributedString(lines.suffix(Self.previewLineLimit).joined(separator: "\n"))
    }
    return diskPreviewCache.tail(for: tile.surfaceID, maxLines: Self.previewLineLimit)
  }

  @MainActor
  final class DiskPreviewCache {
    private var previews: [UUID: AttributedString?] = [:]

    func tail(for surfaceID: UUID, maxLines: Int) -> AttributedString? {
      if let cached = previews[surfaceID] { return cached }
      let styled = ScrollbackPreview.tail(
        surfaceID: surfaceID,
        maxLines: maxLines,
        keepingSGRStyles: true
      ).map(AnsiStyledText.attributedString(from:))
      previews[surfaceID] = styled
      return styled
    }
  }
}

private struct TerminalGridHeaderView: View {
  let store: StoreOf<AppFeature>
  let model: TerminalGridOverview.Model

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Terminal Overview").appFont(.title2, weight: .bold)
        Text("\(model.counts.total) \(model.counts.total == 1 ? "surface" : "surfaces")")
          .appFont(.callout, monospaced: true)
          .foregroundStyle(.secondary)
        Spacer()
        Button { store.send(.setTerminalGridPresented(false)) } label: {
          Label("Close Overview", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Close terminal overview (Esc)")
      }
      HStack(spacing: 8) {
        ForEach(TerminalGridOverview.Filter.allCases, id: \.self) { filter in
          filterButton(filter)
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
  }

  private func filterButton(_ filter: TerminalGridOverview.Filter) -> some View {
    let count = model.counts.count(for: filter)
    let isSelected = model.filter == filter
    return Button { store.send(.setTerminalGridFilter(filter)) } label: {
      HStack(spacing: 5) {
        if case .activity(let activity) = filter {
          Image(systemName: activity.systemImage).accessibilityHidden(true)
        }
        Text(filter.label)
        Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
      }
      .appFont(.callout)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(isSelected ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary), in: Capsule())
      .overlay(Capsule().strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
    }
    .buttonStyle(.plain)
    .disabled(count == 0 && filter != .all)
    .help("Show \(filter.label.lowercased()) terminals (\(count))")
  }
}

private struct TerminalGridFooterView: View {
  var body: some View {
    Text("↑↓←→ Navigate   ↩ Jump   ⌫ Close terminal   ⇧⌫ Close tab   Esc Dismiss")
      .appFont(.caption, monospaced: true)
      .foregroundStyle(.secondary)
      .padding(.vertical, 10)
  }
}

private struct TerminalGridTileView: View {
  let tile: TerminalGridOverview.Tile
  let isSelected: Bool
  let previewText: AttributedString?
  let agentBadgesEnabled: Bool
  let terminalBackground: Color
  let terminalForeground: Color
  let onJump: () -> Void
  let onClose: () -> Void
  @State private var isHovering = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: onJump) {
        VStack(alignment: .leading, spacing: 6) {
          breadcrumb
          terminalBackground
            .aspectRatio(1.6, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomLeading) { preview }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) { statusBadges }
        }
      }
      .buttonStyle(.plain)
      .help("Focus this terminal and dismiss the overview (Return)")
      if isHovering {
        Button(role: .destructive, action: onClose) {
          Label("Close Terminal", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .padding(8)
        .help("Close this terminal (Delete)")
      }
    }
    .onHover { isHovering = $0 }
    .accessibilityLabel("\(tile.directoryName), \(tile.tabTitle), \(tile.activity.label)")
  }

  private var breadcrumb: some View {
    HStack(spacing: 4) {
      Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
      Text(tile.directoryName).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
      Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
      Text(tile.tabTitle).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 0)
      if tile.isFocused {
        Image(systemName: "scope").help("Focused terminal").accessibilityHidden(true)
      }
      if agentBadgesEnabled, !tile.agents.isEmpty { AgentAvatarGroupView(instances: tile.agents) }
    }
    .appFont(.callout)
  }

  private var statusBadges: some View {
    HStack(spacing: 6) {
      if tile.activity != .none {
        Image(systemName: tile.activity.systemImage)
          .padding(5)
          .background(.regularMaterial, in: Circle())
          .help(tile.activity.label)
          .accessibilityHidden(true)
      }
      if tile.availability != .live {
        Image(systemName: tile.availability == .dormant ? "moon.zzz.fill" : "externaldrive.fill")
          .padding(5)
          .background(.regularMaterial, in: Circle())
          .help(tile.availability == .dormant ? "Dormant session" : "Saved session")
          .accessibilityHidden(true)
      }
    }
    .foregroundStyle(.secondary)
    .padding(8)
  }

  @ViewBuilder
  private var preview: some View {
    if let previewText {
      Text(previewText)
        .appFont(.caption, monospaced: true)
        .foregroundStyle(terminalForeground)
        .opacity(tile.availability == .live ? 0.95 : 0.6)
        .fixedSize(horizontal: true, vertical: true)
        .padding(10)
    } else {
      ContentUnavailableView(
        tile.availability == .live ? "No Output" : "No Saved Preview",
        systemImage: tile.availability == .live ? "terminal" : "moon.zzz"
      )
      .foregroundStyle(terminalForeground.opacity(0.6))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
