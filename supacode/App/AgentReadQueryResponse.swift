import Foundation

/// Builds the `supacode agent read` / `terminal wait-output` payload: the tail
/// of one surface's screen text as a single row.
enum AgentReadQueryResponse {
  static let defaultLines = 80

  /// Wire key for the returned text. One row, one field: the CLI prints it raw.
  static let textKey = "text"

  /// Clamps the requested line count. `0` and garbage fall back to the default;
  /// the upper bound is the scrollback the cached screen read can return anyway.
  static func lineCount(_ raw: String?) -> Int {
    guard let raw, let parsed = Int(raw), parsed > 0 else { return defaultLines }
    return min(parsed, 10_000)
  }

  /// Last `lines` lines of `screen`, with trailing blank lines dropped so a
  /// mostly-empty pane doesn't return a wall of newlines.
  static func tail(of screen: String, lines: Int) -> String {
    var rows = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      rows.removeLast()
    }
    if rows.count > lines {
      rows.removeFirst(rows.count - lines)
    }
    return rows.joined(separator: "\n")
  }

  static func rows(screen: String, lines: Int) -> [[String: String]] {
    [[textKey: tail(of: screen, lines: lines)]]
  }
}
