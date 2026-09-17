import Foundation
import IdentifiedCollections

nonisolated enum TerminalRestorePruner {
  static let trivialLineThreshold = 5
  static let parseByteLimit = 16 * 1024

  static func shouldPrune(
    isRemote: Bool,
    settingEnabled: Bool,
    scrollbackEnabled: Bool,
    zmxBundled: Bool,
    liveSessionNames: Set<String>?
  ) -> Bool {
    !isRemote && settingEnabled && scrollbackEnabled && zmxBundled && liveSessionNames != nil
  }

  static func isScrollbackMeaningful(_ data: Data) -> Bool {
    guard data.count <= parseByteLimit else { return true }
    guard let text = String(bytes: data, encoding: .utf8) else { return true }
    return contentLineCount(text, limit: trivialLineThreshold + 1) > trivialLineThreshold
  }

  static func contentLineCount(_ text: String, limit: Int = .max) -> Int {
    var count = 0
    var lineHasContent = false
    var scalars = text.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      switch scalar {
      case "\u{1b}":
        skipEscapeSequence(&scalars)
      case "\n", "\r":
        guard lineHasContent else { continue }
        count += 1
        if count >= limit { return count }
        lineHasContent = false
      default:
        if !scalar.properties.isWhitespace {
          lineHasContent = true
        }
      }
    }
    if lineHasContent { count += 1 }
    return count
  }

  private static func skipEscapeSequence(
    _ scalars: inout String.UnicodeScalarView.Iterator
  ) {
    guard let introducer = scalars.next() else { return }
    switch introducer {
    case "[":
      while let byte = scalars.next() {
        if byte.value >= 0x40, byte.value <= 0x7E { return }
      }
    case "]":
      var previousWasEscape = false
      while let byte = scalars.next() {
        if byte == "\u{07}" { return }
        if previousWasEscape, byte == "\\" { return }
        previousWasEscape = byte == "\u{1b}"
      }
    default:
      return
    }
  }

  static func prunedLayout(
    _ layout: PaneLayout,
    shouldKeepContent: (ContentSnapshot) -> Bool
  ) -> PaneLayout? {
    var result = layout
    for pane in layout.panes {
      let kept = IdentifiedArray(uniqueElements: pane.tabs.filter {
        shouldKeepContent($0.content)
      })
      guard !kept.isEmpty else {
        if let node = result.tree.find(id: pane.id.rawValue) {
          result.tree = result.tree.removing(node)
        }
        result.panes.remove(id: pane.id)
        continue
      }
      var survivor = pane
      survivor.tabs = kept
      survivor.selectedTabID = pane.selectedTabID.flatMap { kept[id: $0] != nil ? $0 : nil }
        ?? kept.first?.id
      result.panes[id: pane.id] = survivor
    }
    guard !result.panes.isEmpty else { return nil }
    if let focusedPaneID = result.focusedPaneID, result.panes[id: focusedPaneID] == nil {
      result.focusedPaneID = result.panes.first?.id
    }
    return result
  }
}
