import Foundation

/// Path-text plumbing for the palette's browse mode. The query field *is* the path, so
/// every navigation is a string transform: `~/code/sup` browses `~/code` and filters the
/// listing on the leaf `sup`, and a trailing `/` means "I'm inside this directory".
/// Nothing here touches the filesystem except tilde expansion, so it is trivially testable.
enum BrowsePath {
  /// The directory portion of a query: everything up to and including the last separator.
  /// A query with no separator at all (`code`) is treated as a leaf typed against `~/`.
  static func directoryText(of query: String) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard let lastSeparator = trimmed.lastIndex(of: "/") else { return "~/" }
    return String(trimmed[...lastSeparator])
  }

  /// The partially typed name after the last separator; empty when the query ends in `/`.
  static func leaf(of query: String) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard let lastSeparator = trimmed.lastIndex(of: "/") else { return trimmed }
    return String(trimmed[trimmed.index(after: lastSeparator)...])
  }

  /// The directory the query currently browses, tilde-expanded and standardized.
  static func directoryURL(of query: String) -> URL {
    URL(fileURLWithPath: expand(directoryText(of: query))).standardized
  }

  /// Query text that descends into `fullPath`, keeping the user's tilde-vs-absolute style.
  static func descending(into fullPath: String, from query: String) -> String {
    let text = usesTilde(query) ? abbreviate(fullPath) : fullPath
    return text.hasSuffix("/") ? text : text + "/"
  }

  /// Query text one level up. Clears a partially typed leaf first (so ⌘← undoes typing
  /// before it changes directory); `nil` at the filesystem root.
  static func parent(of query: String) -> String? {
    let directory = directoryText(of: query)
    guard leaf(of: query).isEmpty else { return directory }

    let current = URL(fileURLWithPath: expand(directory)).standardized
    let parent = current.deletingLastPathComponent().standardized
    guard parent.path != current.path else { return nil }
    return descending(into: parent.path(percentEncoded: false), from: query)
  }

  static func expand(_ text: String) -> String {
    (text as NSString).expandingTildeInPath
  }

  static func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  private static func usesTilde(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    return !trimmed.hasPrefix("/")
  }
}
