import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Bounded scrollback-tail reader for previews when no live renderer exists.
enum ScrollbackPreview {
  static let tailByteLimit = 64 * 1024

  static func tail(surfaceID: UUID, maxLines: Int, keepingSGRStyles: Bool = false) -> String? {
    let url = SupacodePaths.scrollbackFileURL(surfaceID: surfaceID)
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return nil }
    let offset = end > UInt64(tailByteLimit) ? end - UInt64(tailByteLimit) : 0
    try? handle.seek(toOffset: offset)
    var data = try? handle.readToEnd()
    while let first = data?.first, (0x80...0xBF).contains(first) {
      data?.removeFirst()
    }
    guard let data, !data.isEmpty, let text = String(bytes: data, encoding: .utf8) else { return nil }
    let visible = visibleText(text, keepingSGRStyles: keepingSGRStyles)
    var lines = visible.split(separator: "\n", omittingEmptySubsequences: false)
    while let last = lines.last,
      strippedVisibleText(String(last)).trimmingCharacters(in: .whitespaces).isEmpty
    {
      lines.removeLast()
    }
    guard !lines.isEmpty else { return nil }
    return lines.suffix(maxLines).joined(separator: "\n")
  }

  static func strippedVisibleText(_ text: String) -> String {
    visibleText(text, keepingSGRStyles: false)
  }

  private static func visibleText(_ text: String, keepingSGRStyles: Bool) -> String {
    var result = String.UnicodeScalarView()
    result.reserveCapacity(text.unicodeScalars.count)
    var scalars = text.unicodeScalars.makeIterator()
    var previousWasCR = false
    while let scalar = scalars.next() {
      switch scalar {
      case "\u{1b}":
        consumeEscapeSequence(&scalars, into: &result, keepingSGRStyles: keepingSGRStyles)
        previousWasCR = false
      case "\r":
        result.append("\n")
        previousWasCR = true
      case "\n":
        if !previousWasCR { result.append("\n") }
        previousWasCR = false
      default:
        result.append(scalar)
        previousWasCR = false
      }
    }
    return String(result)
  }

  private static func consumeEscapeSequence(
    _ scalars: inout String.UnicodeScalarView.Iterator,
    into result: inout String.UnicodeScalarView,
    keepingSGRStyles: Bool
  ) {
    guard let introducer = scalars.next() else { return }
    switch introducer {
    case "[":
      var body = String.UnicodeScalarView()
      while let byte = scalars.next() {
        if byte.value >= 0x40, byte.value <= 0x7E {
          if keepingSGRStyles, byte == "m" {
            result.append("\u{1b}")
            result.append("[")
            result.append(contentsOf: body)
            result.append("m")
          }
          return
        }
        body.append(byte)
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
}

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
