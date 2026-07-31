import Foundation

/// Decides which persisted surfaces are worth restoring at launch. A surface
/// earns restoration by having a live zmx session to reattach or meaningful
/// disk scrollback to replay; anything else would restore as a bare fresh
/// shell, so it is pruned from the snapshot before restore.
enum TerminalRestorePruner {
  /// Max content lines a scrollback dump can carry and still count as "just a
  /// fresh shell" (prompt plus banner noise).
  static let trivialLineThreshold = 5
  /// Raw dumps larger than this are meaningful without parsing: a fresh prompt
  /// never comes close, and it bounds the per-surface parse cost at launch.
  static let parseByteLimit = 16 * 1024

  /// True when a scrollback dump carries more than a fresh shell's prompt.
  static func isScrollbackMeaningful(_ data: Data) -> Bool {
    guard data.count <= parseByteLimit else { return true }
    // Undecodable bytes can't be classified; keep the surface (fail open).
    guard let text = String(bytes: data, encoding: .utf8) else { return true }
    return contentLineCount(text, limit: trivialLineThreshold + 1) > trivialLineThreshold
  }

  /// Non-empty visible lines after stripping VT escape sequences, capped at
  /// `limit` so a big-but-under-`parseByteLimit` dump stops counting early.
  static func contentLineCount(_ text: String, limit: Int = .max) -> Int {
    var count = 0
    var lineHasContent = false
    var scalars = text.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      switch scalar {
      case "\u{1b}":
        skipEscapeSequence(&scalars)
      case "\n", "\r":
        if lineHasContent {
          count += 1
          if count >= limit { return count }
          lineHasContent = false
        }
      default:
        if !scalar.properties.isWhitespace {
          lineHasContent = true
        }
      }
    }
    if lineHasContent { count += 1 }
    return count
  }

  /// Consumes one escape sequence after a seen ESC: CSI (`ESC [ ... final`),
  /// OSC (`ESC ] ... BEL` or `ESC \`), or a single-character escape.
  private static func skipEscapeSequence(_ scalars: inout String.UnicodeScalarView.Iterator) {
    guard let introducer = scalars.next() else { return }
    switch introducer {
    case "[":
      // CSI: parameter/intermediate bytes 0x20-0x3F, final byte 0x40-0x7E.
      while let byte = scalars.next() {
        if byte.value >= 0x40, byte.value <= 0x7E { return }
      }
    case "]":
      // OSC: terminated by BEL or ST (ESC \).
      var previousWasEscape = false
      while let byte = scalars.next() {
        if byte == "\u{07}" { return }
        if previousWasEscape, byte == "\\" { return }
        previousWasEscape = byte == "\u{1b}"
      }
    default:
      // Single-character escape (RIS, DECSC, charset selection, ...).
      return
    }
  }

  /// Rebuilds the snapshot keeping only leaves `shouldKeepLeaf` approves:
  /// splits collapse onto their surviving child, empty tabs drop, and the
  /// focused-leaf / selected-tab indices remap to the survivors. Returns nil
  /// when nothing survives.
  static func prunedSnapshot(
    _ snapshot: TerminalLayoutSnapshot,
    shouldKeepLeaf: (TerminalLayoutSnapshot.SurfaceSnapshot) -> Bool
  ) -> TerminalLayoutSnapshot? {
    var keptTabs: [TerminalLayoutSnapshot.TabSnapshot] = []
    var selectedTabIndex = 0
    for (index, tab) in snapshot.tabs.enumerated() {
      guard let layout = prunedNode(tab.layout, shouldKeepLeaf: shouldKeepLeaf) else { continue }
      let originalLeaves = leaves(of: tab.layout)
      let focusedID: UUID? =
        originalLeaves.indices.contains(tab.focusedLeafIndex)
        ? originalLeaves[tab.focusedLeafIndex].id
        : nil
      let keptLeafIDs = leaves(of: layout).map(\.id)
      let focusedLeafIndex = focusedID.flatMap { id in keptLeafIDs.firstIndex(of: id) } ?? 0
      if index == snapshot.selectedTabIndex {
        selectedTabIndex = keptTabs.count
      }
      keptTabs.append(
        TerminalLayoutSnapshot.TabSnapshot(
          id: tab.id,
          title: tab.title,
          customTitle: tab.customTitle,
          icon: tab.icon,
          tintColor: tab.tintColor,
          layout: layout,
          focusedLeafIndex: focusedLeafIndex
        )
      )
    }
    guard !keptTabs.isEmpty else { return nil }
    return TerminalLayoutSnapshot(tabs: keptTabs, selectedTabIndex: selectedTabIndex)
  }

  private static func prunedNode(
    _ node: TerminalLayoutSnapshot.LayoutNode,
    shouldKeepLeaf: (TerminalLayoutSnapshot.SurfaceSnapshot) -> Bool
  ) -> TerminalLayoutSnapshot.LayoutNode? {
    switch node {
    case .leaf(let surface):
      return shouldKeepLeaf(surface) ? node : nil
    case .split(let split):
      let left = prunedNode(split.left, shouldKeepLeaf: shouldKeepLeaf)
      let right = prunedNode(split.right, shouldKeepLeaf: shouldKeepLeaf)
      switch (left, right) {
      case (nil, nil):
        return nil
      case (let survivor?, nil), (nil, let survivor?):
        return survivor
      case (let left?, let right?):
        return .split(
          TerminalLayoutSnapshot.SplitSnapshot(
            direction: split.direction,
            ratio: split.ratio,
            left: left,
            right: right
          )
        )
      }
    }
  }

  private static func leaves(
    of node: TerminalLayoutSnapshot.LayoutNode
  ) -> [TerminalLayoutSnapshot.SurfaceSnapshot] {
    switch node {
    case .leaf(let surface):
      return [surface]
    case .split(let split):
      return leaves(of: split.left) + leaves(of: split.right)
    }
  }
}
