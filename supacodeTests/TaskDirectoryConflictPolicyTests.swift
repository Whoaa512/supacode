import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase-3c pure half of the Resolved #11 cascade (plan assertion A20): the
/// three-step decision is a function of two inputs — is the directory owned by
/// another live task, and what has this repository already answered — and
/// nothing else. No filesystem, no clock, no reducer state.
///
/// The fourth answer, `.ask`, is what makes "default isolate" and "the sheet
/// appears once" compatible: an unanswered repository is not silently isolated,
/// it is asked, with isolate as the offered default (`TaskDirectoryIsolation`
/// `.default`).
struct TaskDirectoryConflictPolicyTests {
  // MARK: - Step 1: a free directory is used as-is

  /// A19's budget lives here: a free directory must never reach the sheet, and
  /// must never mint a worktree, whatever the repository remembers.
  @Test(arguments: [nil, TaskDirectoryIsolation.share, TaskDirectoryIsolation.isolate])
  func freeDirectoryIsUsedDirectlyWhateverTheRepositoryRemembers(_ isolation: TaskDirectoryIsolation?) {
    #expect(
      TaskDirectoryConflictPolicy.resolve(isDirectoryBusy: false, repositoryIsolation: isolation)
        == .useDirectly
    )
  }

  // MARK: - Steps 2 and 3: a busy directory consults the repository

  @Test func busyDirectoryWithARememberedShareShares() {
    #expect(
      TaskDirectoryConflictPolicy.resolve(isDirectoryBusy: true, repositoryIsolation: .share) == .share
    )
  }

  @Test func busyDirectoryWithARememberedIsolateIsolates() {
    #expect(
      TaskDirectoryConflictPolicy.resolve(isDirectoryBusy: true, repositoryIsolation: .isolate) == .isolate
    )
  }

  /// The one decision the user is ever asked for, and only the first time this
  /// repository hits a busy directory. An unanswered repository resolves to
  /// `.ask` rather than to the default: silently isolating would spend a
  /// worktree without ever offering `~/work/cj`'s "share anyway".
  @Test func busyDirectoryWithNothingRememberedAsks() {
    #expect(
      TaskDirectoryConflictPolicy.resolve(isDirectoryBusy: true, repositoryIsolation: nil) == .ask
    )
  }

  // MARK: - The remembered value

  /// A20: "per-repo, default isolate". The default is what the sheet offers and
  /// what a caller that cannot ask (no repository, no UI) falls back to.
  @Test func theOfferedDefaultIsIsolate() {
    #expect(TaskDirectoryIsolation.default == .isolate)
  }

  /// Persisted into `supacode.json`, so the spellings are a compatibility
  /// contract, not an implementation detail.
  @Test func rawValuesAreStableOnDisk() {
    #expect(TaskDirectoryIsolation.share.rawValue == "share")
    #expect(TaskDirectoryIsolation.isolate.rawValue == "isolate")
    #expect(Set(TaskDirectoryIsolation.allCases) == [.share, .isolate])
  }

  /// Absent is a third state, not a synonym for the default: it is what makes
  /// the sheet appear exactly once per repository.
  @Test func repositorySettingsRememberNothingByDefault() {
    #expect(RepositorySettings.default.taskDirectoryIsolation == nil)
  }

  @Test func repositorySettingsRoundTripTheRememberedPolicy() throws {
    var settings = RepositorySettings.default
    settings.taskDirectoryIsolation = .share

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(decoded.taskDirectoryIsolation == .share)
    // Additive tolerance, same rule the rest of the file follows: a build that
    // never wrote the key must not start answering `.share` for every repo.
    let legacy = try JSONDecoder().decode(
      RepositorySettings.self,
      from: Data(#"{"setupScript":"","archiveScript":"","deleteScript":""}"#.utf8)
    )
    #expect(legacy.taskDirectoryIsolation == nil)
  }
}
