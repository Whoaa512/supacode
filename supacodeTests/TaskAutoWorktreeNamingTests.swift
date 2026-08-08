import Foundation
import Testing

@testable import supacode

/// The branch (and therefore directory) name Supacode derives for an
/// auto-managed worktree, Phase 3c / plan assertion A20.
///
/// Deterministic on purpose: the name is derived from data the record already
/// carries (its title and its opaque id), never from a counter, a clock or a
/// roster scan, so the same capture always produces the same branch and a
/// retried creation cannot mint a second one. The task id tail is what keeps
/// two captures with the same title apart — titles are allowed to collide
/// (Resolved #15), ids are not.
struct TaskAutoWorktreeNamingTests {
  private static let taskID = TaskID("ABCDEF01-2345-6789-ABCD-EF0123456789")
  private static let otherTaskID = TaskID("99887766-5544-3322-1100-AABBCCDDEEFF")

  private static func branch(_ title: String, id: TaskID = taskID) -> String {
    TaskAutoWorktreeNaming.branchName(title: title, taskID: id)
  }

  // MARK: - The scheme

  @Test func theSchemeIsTaskSlugShortID() {
    #expect(Self.branch("Ship the inbox") == "task/ship-the-inbox-abcdef01")
  }

  @Test func punctuationAndCaseCollapseIntoSingleHyphens() {
    #expect(Self.branch("  Fix: the *thing*!!  ") == "task/fix-the-thing-abcdef01")
    #expect(Self.branch("PR #123 — retry/timeout") == "task/pr-123-retry-timeout-abcdef01")
  }

  /// git refuses plenty of what a title may contain; the slug keeps only
  /// `[a-z0-9-]` so no title can produce a name `git worktree add` rejects.
  @Test func theNameIsAlwaysAValidBranchName() {
    for title in ["a b", "~^:?*[", "..", "@{", "back\\slash", "trailing.lock"] {
      let name = Self.branch(title)
      #expect(name.hasPrefix("task/"))
      let tail = name.dropFirst("task/".count)
      #expect(tail.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
      #expect(!tail.hasPrefix("-"))
      #expect(!tail.hasSuffix("-"))
      #expect(!name.contains("--"))
    }
  }

  /// A title that slugs to nothing (emoji-only, punctuation-only) still names a
  /// worktree: the id tail alone is a complete name.
  @Test func anEmptySlugFallsBackToTheIDAlone() {
    #expect(Self.branch("🙂🙂") == "task/abcdef01")
    #expect(Self.branch("   ") == "task/abcdef01")
    #expect(Self.branch("") == "task/abcdef01")
  }

  /// Directory names have limits and a 200-character task title is a normal
  /// thing to type. The slug is capped; the id tail is never truncated, because
  /// it is the part that makes the name unique.
  @Test func longTitlesAreTruncatedButKeepTheIDTail() {
    let name = Self.branch(String(repeating: "supacode ", count: 40))
    let tail = String(name.dropFirst("task/".count))
    #expect(tail.hasSuffix("-abcdef01"))
    #expect(tail.count == 32 + "-abcdef01".count)
    #expect(!tail.hasPrefix("-"))
    // Truncation may not leave a dangling separator behind.
    #expect(!tail.dropLast("-abcdef01".count).hasSuffix("-"))
  }

  // MARK: - Determinism and uniqueness

  @Test func theSameCaptureAlwaysDerivesTheSameName() {
    #expect(Self.branch("Ship the inbox") == Self.branch("Ship the inbox"))
  }

  @Test func twoTasksWithTheSameTitleGetDifferentNames() {
    #expect(Self.branch("Ship the inbox") != Self.branch("Ship the inbox", id: Self.otherTaskID))
    #expect(Self.branch("Ship the inbox", id: Self.otherTaskID) == "task/ship-the-inbox-99887766")
  }

  /// The id is opaque and its raw spelling is a UUID string; the tail is taken
  /// from the id, never from the path or the branch the task started on.
  @Test func theTailIsTheLowercasedIDPrefix() {
    let id = TaskID("aabbccdd-0000-0000-0000-000000000000")
    #expect(Self.branch("x", id: id) == "task/x-aabbccdd")
  }
}
