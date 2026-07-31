import Foundation

/// Path-text plumbing for the palette's browse mode. The query field *is* the path, so
/// every navigation is a string transform: `~/code/sup` browses `~/code` and filters the
/// listing on the leaf `sup`, and a trailing `/` means "I'm inside this directory".
/// The one filesystem touch is `resolve`'s existing-directory check for a slash-less
/// query, so `~` on its own lists the home directory instead of filtering it to nothing.
enum BrowsePath {
  /// A query split into the directory being listed and the partially typed name in it.
  struct Resolved: Equatable {
    let directoryText: String
    let leaf: String
  }

  /// Splits `query` at its last separator. A slash-less query is a leaf typed against
  /// `~/` (`code` filters the home listing) unless it is itself an existing directory
  /// (`~`), in which case it *is* the directory being browsed.
  static func resolve(_ query: String) -> Resolved {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard let lastSeparator = trimmed.lastIndex(of: "/") else {
      guard !trimmed.isEmpty, directoryExists(atPath: expand(trimmed)) else {
        return Resolved(directoryText: "~/", leaf: trimmed)
      }
      return Resolved(directoryText: ensureTrailingSlash(trimmed), leaf: "")
    }
    return Resolved(
      directoryText: String(trimmed[...lastSeparator]),
      leaf: String(trimmed[trimmed.index(after: lastSeparator)...])
    )
  }

  /// The directory portion of a query: everything up to and including the last separator.
  static func directoryText(of query: String) -> String {
    resolve(query).directoryText
  }

  /// The partially typed name after the last separator; empty when the query ends in `/`.
  static func leaf(of query: String) -> String {
    resolve(query).leaf
  }

  /// The directory the query currently browses, tilde-expanded and standardized.
  static func directoryURL(of query: String) -> URL {
    URL(fileURLWithPath: expand(directoryText(of: query))).standardized
  }

  /// Query text that descends into `fullPath`, keeping the user's tilde-vs-absolute style.
  static func descending(into fullPath: String, from query: String) -> String {
    ensureTrailingSlash(usesTilde(query) ? abbreviate(fullPath) : fullPath)
  }

  /// Query text one level up. Clears a partially typed leaf first (so ⌘↑ undoes typing
  /// before it changes directory); `nil` at the filesystem root.
  static func parent(of query: String) -> String? {
    let resolved = resolve(query)
    guard resolved.leaf.isEmpty else { return resolved.directoryText }

    let current = URL(fileURLWithPath: expand(resolved.directoryText)).standardized
    let parent = current.deletingLastPathComponent().standardized
    guard parent.path != current.path else { return nil }
    return descending(into: parent.path(percentEncoded: false), from: query)
  }

  /// Directory text always ends in a separator, so `leaf` of it is empty and the next
  /// character the user types starts a new leaf rather than extending the folder name.
  static func ensureTrailingSlash(_ text: String) -> String {
    text.hasSuffix("/") ? text : text + "/"
  }

  static func expand(_ text: String) -> String {
    (text as NSString).expandingTildeInPath
  }

  static func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  private static func directoryExists(atPath path: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }

  private static func usesTilde(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    return !trimmed.hasPrefix("/")
  }
}
