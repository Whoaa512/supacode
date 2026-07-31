import ComposableArchitecture
import SwiftUI

/// Full-screen modal grid of every live terminal surface across all
/// worktrees. Tiles show a live-updating text preview with a
/// directory › tab breadcrumb. Click or press Return to jump to a surface
/// (dismisses the modal), Delete closes the selected surface, ⇧Delete closes
/// its whole tab, Esc dismisses.
struct TerminalGridOverviewView: View {
  let store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager

  @State private var selectedSurfaceID: UUID?
  @State private var columnCount = 3
  @FocusState private var isGridFocused: Bool

  private static let tileMinWidth: CGFloat = 280
  private static let gridSpacing: CGFloat = 16

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
    let tiles = Self.flattenTiles(terminalManager.sessionOverviews())
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
              onCloseSurface: { closeSurface(tile) }
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
    let tiles = Self.flattenTiles(terminalManager.sessionOverviews())
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

  private func previewText(for tile: Tile) -> String? {
    guard !tile.isDormant else { return nil }
    let contents =
      terminalManager.screenPreview(worktreeID: tile.worktreeID, surfaceID: tile.surfaceID) ?? ""
    var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    return lines.suffix(12).joined(separator: "\n")
  }

  // MARK: - Tiles.

  struct Tile: Identifiable, Equatable {
    let worktreeID: Worktree.ID
    let worktreeName: String
    let directoryName: String
    let tabID: TerminalTabID
    let tabTitle: String
    let surfaceID: UUID
    let isDormant: Bool

    var id: UUID { surfaceID }
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
            isDormant: surface.isDormant
          )
        }
      }
    }
  }
}

/// One surface tile: directory › tab breadcrumb above a live text preview.
private struct TerminalGridTileView: View {
  let tile: TerminalGridOverviewView.Tile
  let isSelected: Bool
  let previewText: String?
  let onJump: () -> Void
  let onCloseSurface: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onJump) {
      tileContent
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help("Jump to this terminal")
    .accessibilityLabel("\(tile.directoryName), \(tile.tabTitle)")
  }

  private var tileContent: some View {
    VStack(alignment: .leading, spacing: 6) {
      breadcrumb
      preview
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 140, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
              isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
              lineWidth: isSelected ? 2 : 1
            )
        )
        .overlay(alignment: .topTrailing) {
          if isHovering {
            Button(role: .destructive, action: onCloseSurface) {
              Label("Close Terminal", systemImage: "xmark.circle.fill")
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .padding(6)
            .help("Close this terminal surface")
          }
        }
    }
    .contentShape(Rectangle())
  }

  private var breadcrumb: some View {
    HStack(spacing: 4) {
      Image(systemName: "folder")
        .accessibilityHidden(true)
      Text(tile.directoryName)
        .fontWeight(.medium)
        .lineLimit(1)
        .truncationMode(.middle)
      Image(systemName: "chevron.right")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(tile.tabTitle)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .font(.callout)
  }

  @ViewBuilder
  private var preview: some View {
    if let previewText {
      Text(previewText)
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(.quaternary.opacity(0.5))
    } else {
      VStack(spacing: 4) {
        Image(systemName: "moon.zzz")
          .font(.title3)
          .accessibilityHidden(true)
        Text("Asleep")
          .font(.caption)
      }
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.quaternary.opacity(0.5))
    }
  }
}
