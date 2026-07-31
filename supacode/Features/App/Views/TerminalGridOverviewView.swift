import ComposableArchitecture
import Sharing
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
  @State private var columnCount = 3
  /// Disk-tail previews for dormant / snoozed surfaces. Their dumps can't
  /// change while dormant, so one read per surface per modal presentation.
  /// Reference-typed: filled lazily during render, which a `@State` dict
  /// mutation would flag as "modifying state during view update".
  @State private var diskPreviewCache = DiskPreviewCache()
  @FocusState private var isGridFocused: Bool
  @Shared(.layouts) private var layouts: [String: TerminalLayoutSnapshot] = [:]

  private static let tileMinWidth: CGFloat = 340
  private static let gridSpacing: CGFloat = 16
  private static let previewLineLimit = 14

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
    let tiles = currentTiles()
    VStack(spacing: 0) {
      header
      if tiles.isEmpty {
        ContentUnavailableView(
          "No Terminal Sessions",
          systemImage: "terminal",
          description: Text("Open a terminal in a worktree and it will show up here.")
        )
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

  private var header: some View {
    HStack {
      Text("Terminal Overview")
        .font(.title2.bold())
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
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
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
            count: columnCount
          ),
          spacing: Self.gridSpacing
        ) {
          ForEach(tiles) { tile in
            TerminalGridTileView(
              tile: tile,
              isSelected: tile.id == selectedSurfaceID,
              previewText: previewText(for: tile),
              onJump: { jump(to: tile) },
              onCloseSurface: tile.kind == .snoozed ? nil : { closeSurface(tile) }
            )
            .id(tile.id)
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
          columnCount = max(1, Int(width / Self.tileMinWidth))
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
    let tiles = currentTiles()
    guard !tiles.isEmpty else {
      if press.key == .escape {
        store.send(.setTerminalGridPresented(false))
        return .handled
      }
      return .ignored
    }
    let currentIndex = tiles.firstIndex { $0.id == selectedSurfaceID } ?? 0

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

  private func previewText(for tile: Tile) -> String? {
    switch tile.kind {
    case .live:
      let contents =
        terminalManager.screenPreview(worktreeID: tile.worktreeID, surfaceID: tile.surfaceID) ?? ""
      var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
      while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeLast()
      }
      guard !lines.isEmpty else { return nil }
      return lines.suffix(Self.previewLineLimit).joined(separator: "\n")
    case .dormant, .snoozed:
      return diskPreviewCache.tail(for: tile.surfaceID, maxLines: Self.previewLineLimit)
    }
  }

  @MainActor
  final class DiskPreviewCache {
    private var previews: [UUID: String] = [:]

    func tail(for surfaceID: UUID, maxLines: Int) -> String? {
      if let cached = previews[surfaceID] {
        return cached.isEmpty ? nil : cached
      }
      let tail = ScrollbackPreview.tail(surfaceID: surfaceID, maxLines: maxLines)
      previews[surfaceID] = tail ?? ""
      return tail
    }
  }

  // MARK: - Tiles.

  struct Tile: Identifiable, Equatable {
    enum Kind: Equatable {
      /// Surface has a live view; preview reads the screen each tick.
      case live
      /// Tab is hibernated in a live worktree state; preview reads disk.
      case dormant
      /// Worktree not restored this launch; tile comes from the persisted
      /// layout snapshot and preview reads disk.
      case snoozed
    }

    let worktreeID: Worktree.ID
    let worktreeName: String
    let directoryName: String
    let tabID: TerminalTabID
    let tabTitle: String
    let surfaceID: UUID
    let kind: Kind

    var id: UUID { surfaceID }
  }

  private func currentTiles() -> [Tile] {
    let live = Self.flattenTiles(terminalManager.sessionOverviews())
    let snoozed = Self.snoozedTiles(
      layouts: layouts,
      excludingWorktreeIDs: Set(live.map(\.worktreeID)),
      worktreeLookup: { store.repositories.worktree(for: $0) }
    )
    return live + snoozed
  }

  /// One tile per surface, in the manager's stable worktree/tab order, so
  /// keyboard navigation indices match the rendered grid.
  static func flattenTiles(
    _ overviews: [WorktreeTerminalManager.SessionWorktreeOverview]
  ) -> [Tile] {
    overviews.flatMap { worktree in
      worktree.tabs.flatMap { tab in
        tab.surfaces.map { surface in
          Tile(
            worktreeID: worktree.id,
            worktreeName: worktree.name,
            directoryName: worktree.directoryName,
            tabID: tab.id,
            tabTitle: tab.title,
            surfaceID: surface.id,
            kind: surface.isDormant ? .dormant : .live
          )
        }
      }
    }
  }

  /// Tiles for worktrees that persisted a layout but own no surfaces this
  /// launch (not yet visited / restored). Skips worktrees the lookup can't
  /// resolve (archived / deleted) and legacy snapshots without stable IDs.
  /// Sorted by directory name for a stable grid order.
  static func snoozedTiles(
    layouts: [String: TerminalLayoutSnapshot],
    excludingWorktreeIDs: Set<Worktree.ID>,
    worktreeLookup: (Worktree.ID) -> Worktree?
  ) -> [Tile] {
    layouts
      .compactMap { key, snapshot -> [Tile]? in
        let worktreeID = WorktreeID(key)
        guard !excludingWorktreeIDs.contains(worktreeID),
          let worktree = worktreeLookup(worktreeID)
        else { return nil }
        let tiles = snapshot.tabs.flatMap { tab -> [Tile] in
          guard let tabID = tab.id else { return [] }
          return tab.layout.leafSurfaceIDs.map { surfaceID in
            Tile(
              worktreeID: worktreeID,
              worktreeName: worktree.name,
              directoryName: worktree.workingDirectory.lastPathComponent,
              tabID: TerminalTabID(rawValue: tabID),
              tabTitle: tab.customTitle ?? tab.title,
              surfaceID: surfaceID,
              kind: .snoozed
            )
          }
        }
        return tiles.isEmpty ? nil : tiles
      }
      .sorted { lhs, rhs in
        guard let first = lhs.first, let second = rhs.first else { return false }
        return (first.directoryName, first.worktreeID.rawValue)
          < (second.directoryName, second.worktreeID.rawValue)
      }
      .flatMap { $0 }
  }
}

/// One surface tile: directory › tab breadcrumb above a terminal-styled
/// text preview. Asleep surfaces show their last on-disk snapshot, dimmed,
/// with a moon badge.
private struct TerminalGridTileView: View {
  let tile: TerminalGridOverviewView.Tile
  let isSelected: Bool
  let previewText: String?
  let onJump: () -> Void
  let onCloseSurface: (() -> Void)?

  @State private var isHovering = false

  private var isAsleep: Bool { tile.kind != .live }

  var body: some View {
    Button(action: onJump) {
      tileContent
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(isAsleep ? "Wake and jump to this terminal" : "Jump to this terminal")
    .accessibilityLabel("\(tile.directoryName), \(tile.tabTitle)\(isAsleep ? ", asleep" : "")")
  }

  private var tileContent: some View {
    VStack(alignment: .leading, spacing: 6) {
      breadcrumb
      preview
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180, alignment: .topLeading)
        .background(.black)
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
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var previewBadges: some View {
    HStack(spacing: 6) {
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
    }
    .font(.callout)
    .padding(.horizontal, 2)
  }

  @ViewBuilder
  private var preview: some View {
    if let previewText {
      // fixedSize keeps long lines on one line (clipped right), matching how
      // a terminal looks instead of soft-wrapping into paragraph soup.
      Text(previewText)
        .font(.caption2.monospaced())
        .foregroundStyle(.white)
        .opacity(isAsleep ? 0.5 : 0.9)
        .fixedSize(horizontal: true, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    } else {
      VStack(spacing: 6) {
        Image(systemName: isAsleep ? "moon.zzz" : "terminal")
          .font(.title3)
          .accessibilityHidden(true)
        Text(isAsleep ? "Asleep" : "No output")
          .font(.caption)
      }
      .foregroundStyle(.white.opacity(0.4))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
