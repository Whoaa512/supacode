import Foundation

/// fzf-style matching for the palette's browse mode. The typed characters have to appear
/// in order somewhere in a candidate's *root-relative path*, not just its name, so `co/sup`
/// (or `code supa`) finds `code/supacode` while browsing `~`. Spaces are dropped, which
/// makes a space read as "keep going, anywhere later in the path".
enum BrowseFuzzyMatch {
  /// How well a path matched, decomposed so ranking stays explainable. Bigger
  /// `boundaryHits` / `contiguousHits` is better; smaller depth / index is better.
  /// Deliberately no length term: candidates arrive breadth-first and alphabetically,
  /// and equal scores keep that order rather than being reshuffled by name length.
  struct Score: Equatable, Sendable {
    /// Matched characters that start a path segment or word (`/`, `-`, `_`, `.` before them).
    let boundaryHits: Int
    /// Matched characters immediately following the previous match, i.e. typed runs.
    let contiguousHits: Int
    /// Separators in the relative path: shallower results win ties.
    let depth: Int
    let firstMatchIndex: Int

    /// Match quality. Contiguity outweighs boundaries so a typed run (`supa`) beats a
    /// path that only happens to start every word with those letters (`s-u-p-a`), while a
    /// boundary hit still lifts `my-project-supacode` above a mid-word `unsupported`.
    var weight: Int { 3 * contiguousHits + 2 * boundaryHits }

    /// Best-first ordering. Kept as a function rather than `Comparable` because
    /// "less than" reads backwards for a score where bigger is better.
    static func isBetter(_ lhs: Score, _ rhs: Score) -> Bool {
      if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
      if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
      return lhs.firstMatchIndex < rhs.firstMatchIndex
    }
  }

  /// Characters that make the next character a segment / word boundary.
  private static let boundaryCharacters: Set<Character> = ["/", "-", "_", ".", " "]

  /// Case-folded, whitespace-free query. Spaces are gaps, not literals, so `code supa`
  /// and `codesupa` match the same paths.
  static func normalizedQuery(_ query: String) -> String {
    query.lowercased().filter { !$0.isWhitespace }
  }

  /// `nil` when the query isn't a subsequence of `path`. The alignment is the leftmost
  /// greedy one — cheap, and good enough because ranking leans on boundaries rather than
  /// on finding the theoretically tightest match.
  static func score(path: String, query: String) -> Score? {
    let needle = Array(normalizedQuery(query))
    guard !needle.isEmpty else { return nil }
    let haystack = Array(path.lowercased())

    var needleIndex = 0
    var boundaryHits = 0
    var contiguousHits = 0
    var firstMatchIndex: Int?
    var previousMatchIndex: Int?

    for (index, character) in haystack.enumerated() {
      guard needleIndex < needle.count, character == needle[needleIndex] else { continue }
      if firstMatchIndex == nil { firstMatchIndex = index }
      if Self.isBoundary(haystack, at: index) { boundaryHits += 1 }
      if previousMatchIndex == index - 1 { contiguousHits += 1 }
      previousMatchIndex = index
      needleIndex += 1
    }

    guard needleIndex == needle.count, let firstMatchIndex else { return nil }
    return Score(
      boundaryHits: boundaryHits,
      contiguousHits: contiguousHits,
      depth: haystack.count { $0 == "/" },
      firstMatchIndex: firstMatchIndex
    )
  }

  static func matches(path: String, query: String) -> Bool {
    Self.score(path: path, query: query) != nil
  }

  /// Matching items best-first, stable within equal scores so a late-arriving batch
  /// doesn't reshuffle rows that scored the same.
  static func ranked<Item>(
    _ items: [Item],
    query: String,
    path: (Item) -> String
  ) -> [Item] {
    items
      .enumerated()
      .compactMap { offset, item -> Ranked<Item>? in
        guard let score = Self.score(path: path(item), query: query) else { return nil }
        return Ranked(offset: offset, item: item, score: score)
      }
      .sorted { left, right in
        guard left.score != right.score else { return left.offset < right.offset }
        return Score.isBetter(left.score, right.score)
      }
      .map(\.item)
  }

  /// A scored candidate mid-sort; `offset` keeps equal scores in their incoming order.
  private struct Ranked<Item> {
    let offset: Int
    let item: Item
    let score: Score
  }

  private static func isBoundary(_ haystack: [Character], at index: Int) -> Bool {
    guard index > 0 else { return true }
    return Self.boundaryCharacters.contains(haystack[index - 1])
  }
}
