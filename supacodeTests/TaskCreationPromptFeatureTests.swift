import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase-3b contract for `TaskCreationPromptFeature`: the ⌘N prompt that turns
/// an optional title plus a fuzzy directory pick into one `.createTask`
/// delegate (assertion A19 of `plans/task-inbox-sidebar-plan.md`).
///
/// The reducer never scans disk: the parent hands it the candidate list built
/// from the live roster, already ordered by whatever recency the parent knows
/// about, and the prompt only filters, ranks and picks. That is why every test
/// here is pure reducer state — no sandbox, no filesystem.
///
/// Resolved #8: this is a new feature rather than an extension of
/// `WorktreeCreationPromptFeature` (which is worktree-shaped and needs a
/// pre-chosen repository). Only the validation / delegate idiom is borrowed.
@MainActor
struct TaskCreationPromptFeatureTests {
  private typealias Candidate = TaskCreationPromptFeature.Candidate

  // MARK: - Fixture

  private func makeCandidate(
    repository: String,
    leaf: String,
    branch: String? = nil,
    worktreeID: Worktree.ID? = nil,
    isBusy: Bool = false
  ) -> Candidate {
    let directoryURL = URL(filePath: "/repos/\(repository)/\(leaf)", directoryHint: .isDirectory)
    return Candidate(
      directoryURL: directoryURL,
      repositoryName: repository,
      branch: branch,
      worktreeID: worktreeID ?? WorktreeID(directoryURL.path(percentEncoded: false)),
      isBusy: isBusy
    )
  }

  private func makeState(_ candidates: [Candidate]) -> TaskCreationPromptFeature.State {
    TaskCreationPromptFeature.State(candidates: candidates)
  }

  private func makeStore(
    _ candidates: [Candidate]
  ) -> TestStoreOf<TaskCreationPromptFeature> {
    TestStore(initialState: makeState(candidates)) {
      TaskCreationPromptFeature()
    }
  }

  // MARK: - Ranking

  /// An empty query is not "no results": it is the whole list, in exactly the
  /// order the parent supplied (which is the recency order the Tasks tab
  /// already sorts by). Ties are broken by the parent, never re-sorted here.
  @Test func emptyQueryKeepsParentOrderAndSelectsTheFirstCandidate() {
    let first = makeCandidate(repository: "acme", leaf: "beta")
    let second = makeCandidate(repository: "acme", leaf: "alpha")
    let state = makeState([first, second])

    #expect(state.rankedCandidates == [first, second])
    #expect(state.selectedCandidate == first)
  }

  /// Whitespace is a gap in the fuzzy query, not a literal, so a query of only
  /// spaces still reads as "no query" rather than as an unmatchable needle.
  @Test func whitespaceOnlyQueryIsTreatedAsEmpty() {
    var state = makeState([makeCandidate(repository: "acme", leaf: "alpha")])
    state.directoryQuery = "   "

    #expect(state.rankedCandidates.count == 1)
  }

  /// A typed run beats the same letters scattered across word boundaries, and a
  /// candidate the query is not a subsequence of drops out entirely.
  @Test func queryRanksContiguousMatchesAboveScatteredOnes() {
    let contiguous = makeCandidate(repository: "acme", leaf: "supacode")
    let scattered = makeCandidate(repository: "acme", leaf: "s-u-p-a")
    let unrelated = makeCandidate(repository: "acme", leaf: "zzz")
    var state = makeState([scattered, contiguous, unrelated])
    state.directoryQuery = "supa"

    #expect(state.rankedCandidates == [contiguous, scattered])
  }

  /// The needle is matched against the directory leaf, the repository name and
  /// the branch, so any of the three the user remembers finds the row.
  @Test func queryMatchesLeafRepositoryNameAndBranch() {
    let alpha = makeCandidate(repository: "alpha", leaf: "one")
    let beta = makeCandidate(repository: "beta", leaf: "two", branch: "hotfix")
    var state = makeState([alpha, beta])

    state.directoryQuery = "alpha"
    #expect(state.rankedCandidates == [alpha])

    state.directoryQuery = "two"
    #expect(state.rankedCandidates == [beta])

    state.directoryQuery = "hotfix"
    #expect(state.rankedCandidates == [beta])

    state.directoryQuery = "nothinghere"
    #expect(state.rankedCandidates.isEmpty)
    #expect(state.selectedCandidate == nil)
  }

  // MARK: - Selection

  /// Retyping re-ranks under the cursor, so the highlight has to snap back to
  /// the top match instead of pointing at whatever now sits at the old index.
  @Test func typingResetsTheSelectionToTheTopMatch() async {
    let alpha = makeCandidate(repository: "acme", leaf: "alpha")
    let beta = makeCandidate(repository: "acme", leaf: "beta")
    let store = makeStore([alpha, beta])

    await store.send(.moveSelection(offset: 1)) {
      $0.selectedIndex = 1
    }
    await store.send(.set(\.directoryQuery, "a")) {
      $0.directoryQuery = "a"
      $0.selectedIndex = 0
    }
    #expect(store.state.selectedCandidate == alpha)
  }

  /// Clamped, not wrapped: the list is a ranked best-first pick, and rolling off
  /// the bottom back onto the best match reads as a jump, not as navigation.
  @Test func moveSelectionClampsAtBothEnds() async {
    let store = makeStore([
      makeCandidate(repository: "acme", leaf: "alpha"),
      makeCandidate(repository: "acme", leaf: "beta"),
    ])

    await store.send(.moveSelection(offset: -1))
    await store.send(.moveSelection(offset: 1)) {
      $0.selectedIndex = 1
    }
    await store.send(.moveSelection(offset: 1))
  }

  /// Clicking a row selects it by identity, so a re-rank between render and
  /// click can never land the pick on the row that took over the index.
  @Test func selectCandidateSelectsByIdentity() async {
    let alpha = makeCandidate(repository: "acme", leaf: "alpha")
    let beta = makeCandidate(repository: "acme", leaf: "beta")
    let store = makeStore([alpha, beta])

    await store.send(.selectCandidate(beta.id)) {
      $0.selectedIndex = 1
    }
    #expect(store.state.selectedCandidate == beta)

    // An id that is not in the current ranking leaves the selection alone.
    await store.send(.selectCandidate("/repos/acme/gone"))
    #expect(store.state.selectedCandidate == beta)
  }

  // MARK: - Submit

  /// A19: two interactions max — type, Enter. The title is optional and the
  /// directory comes from the highlighted row.
  @Test func createSendsTheSelectedDirectoryWithATrimmedTitle() async {
    let alpha = makeCandidate(repository: "acme", leaf: "alpha")
    let beta = makeCandidate(repository: "acme", leaf: "beta")
    let store = makeStore([alpha, beta])

    await store.send(.set(\.title, "  Ship the inbox  ")) {
      $0.title = "  Ship the inbox  "
    }
    await store.send(.set(\.directoryQuery, "beta")) {
      $0.directoryQuery = "beta"
    }
    await store.send(.createButtonTapped)
    await store.receive(
      .delegate(.createTask(title: "Ship the inbox", directoryURL: beta.directoryURL))
    )
  }

  /// An untitled task is the fast path, not an error: the parent's seeder
  /// cascade names it. `nil` (not `""`) is what says "you name it".
  @Test func createSendsNilTitleWhenTheFieldIsBlank() async {
    let alpha = makeCandidate(repository: "acme", leaf: "alpha")
    let store = makeStore([alpha])

    await store.send(.set(\.title, "   ")) {
      $0.title = "   "
    }
    await store.send(.createButtonTapped)
    await store.receive(
      .delegate(.createTask(title: nil, directoryURL: alpha.directoryURL))
    )
  }

  /// Submitting a query that matched nothing has no directory to create in, so
  /// it explains itself instead of silently doing nothing.
  @Test func createWithNoMatchValidatesInsteadOfSubmitting() async {
    let store = makeStore([makeCandidate(repository: "acme", leaf: "alpha")])

    await store.send(.set(\.directoryQuery, "nothinghere")) {
      $0.directoryQuery = "nothinghere"
    }
    await store.send(.createButtonTapped) {
      $0.validationMessage = "No matching directory."
    }
  }

  /// A prompt opened before any repository is registered can still be opened
  /// and dismissed; it just has nothing to create in (registration UX is P7).
  @Test func createWithNoCandidatesValidates() async {
    let store = makeStore([])

    await store.send(.createButtonTapped) {
      $0.validationMessage = "No matching directory."
    }
  }

  /// Editing after a refusal clears the message, matching the worktree prompt.
  @Test func bindingClearsTheValidationMessage() async {
    var state = makeState([makeCandidate(repository: "acme", leaf: "alpha")])
    state.validationMessage = "No matching directory."
    let store = TestStore(initialState: state) { TaskCreationPromptFeature() }

    await store.send(.set(\.directoryQuery, "al")) {
      $0.directoryQuery = "al"
      $0.validationMessage = nil
    }
  }

  @Test func cancelSendsTheCancelDelegate() async {
    let store = makeStore([makeCandidate(repository: "acme", leaf: "alpha")])

    await store.send(.cancelButtonTapped)
    await store.receive(.delegate(.cancel))
  }
}
