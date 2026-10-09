import Foundation

/// How an id travels outside the app (surface environment, deeplinks, CLI
/// socket params): percent-encoded with slashes escaped, so a path-shaped id
/// stays one URL path segment.
nonisolated enum ExternalID {
  private static let allowed = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))

  static func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  /// Nil for a value that is empty or does not percent-decode.
  static func decode(_ raw: String) -> String? {
    guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty else { return nil }
    return decoded
  }
}

extension WorktreeID {
  /// A directory id as a deeplink or CLI names it. One trailing slash is
  /// dropped so both spellings of a path name the same directory; matching a
  /// roster id that keeps its slash is the resolver's job.
  init?(external raw: String) {
    guard let decoded = ExternalID.decode(raw) else { return nil }
    self.init(decoded.hasSuffix("/") && decoded.count > 1 ? String(decoded.dropLast()) : decoded)
  }
}
