import ComposableArchitecture
import Foundation

/// The ⌘N capture prompt: an optional title plus a fuzzy directory pick, out as
/// one `.createTask` delegate (assertion A19 of
/// `plans/task-inbox-sidebar-plan.md` — two interactions, type and Enter).
///
/// This reducer never scans disk. The parent hands it the candidate list built
/// from the live roster — the directory the user is currently standing in
/// first, then the rest in sidebar order — and the prompt only filters, ranks
/// and picks. There is no recency signal in this list; the leading row is the
/// selection, not a most-recently-used ranking.
///
/// Resolved #8: a new feature rather than an extension of
/// `WorktreeCreationPromptFeature`, which is worktree-shaped and needs a
/// pre-chosen repository. Only the validation / delegate idiom is borrowed.
@Reducer
struct TaskCreationPromptFeature {
  /// One pickable directory.
  ///
  /// `id` is the normalized directory path, the same identity
  /// `TaskRecord.directoryPath` carries, so a click can be matched against a
  /// record without re-deriving anything. The parent is expected to hand in an
  /// already symlink-resolved `directoryURL` (canonicalization touches the
  /// filesystem, which a reducer must not).
  struct Candidate: Equatable, Identifiable, Sendable {
    let id: String
    let directoryURL: URL
    let repositoryName: String
    /// `nil` when the row could not prove a branch (A2) — never a guess.
    let branch: String?
    /// The live sidebar row for this directory, when there is one. Carried so
    /// the parent can request a terminal without re-deriving the worktree.
    let worktreeID: Worktree.ID?
    /// Another unsettled task already owns this directory. Rendered as a hint in
    /// 3b; it is the input to Phase 3c's isolation cascade.
    let isBusy: Bool
    /// Haystack the fuzzy query runs against: the directory leaf, the repository
    /// name and the branch, so any of the three the user remembers finds the row.
    /// Joined with `/` because `BrowseFuzzyMatch` treats that as a word boundary.
    let matchText: String

    init(
      directoryURL: URL,
      repositoryName: String,
      branch: String? = nil,
      worktreeID: Worktree.ID? = nil,
      isBusy: Bool = false
    ) {
      self.id = TaskDirectoryPath.normalized(directoryURL.path(percentEncoded: false))
      self.directoryURL = directoryURL
      self.repositoryName = repositoryName
      self.branch = branch
      self.worktreeID = worktreeID
      self.isBusy = isBusy
      self.matchText = [directoryURL.lastPathComponent, repositoryName, branch]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "/")
    }
  }

  @ObservableState
  struct State: Equatable {
    /// Parent-ordered, best default first; an empty query renders them verbatim
    /// rather than re-sorted, so ⌘N ↩ lands on the directory the user is in.
    var candidates: [Candidate]
    var title: String = ""
    var directoryQuery: String = ""
    /// Index into `rankedCandidates`, not into `candidates`.
    var selectedIndex: Int = 0
    var validationMessage: String?

    init(candidates: [Candidate]) {
      self.candidates = candidates
    }

    /// An empty query is not "no results": it is the whole list in the order the
    /// parent supplied. Whitespace is a gap in a fuzzy query rather than a
    /// literal, so a query of only spaces still reads as "no query".
    var rankedCandidates: [Candidate] {
      guard !BrowseFuzzyMatch.normalizedQuery(directoryQuery).isEmpty else { return candidates }
      return BrowseFuzzyMatch.ranked(candidates, query: directoryQuery, path: \.matchText)
    }

    var selectedCandidate: Candidate? {
      let ranked = rankedCandidates
      guard ranked.indices.contains(selectedIndex) else { return nil }
      return ranked[selectedIndex]
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case createButtonTapped
    /// Keyboard navigation. Clamped, never wrapped.
    case moveSelection(offset: Int)
    /// Click / tap, by identity so a re-rank between render and click cannot
    /// land the pick on whatever row took over the index.
    case selectCandidate(Candidate.ID)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    /// `title` is trimmed, and `nil` (not `""`) when the field was blank — that
    /// is what tells the parent's seeder cascade to name the task.
    case createTask(title: String?, directoryURL: URL)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      // Retyping re-ranks under the cursor, so the highlight snaps back to the
      // top match instead of pointing at whatever now sits at the old index.
      case .binding(\.directoryQuery):
        state.validationMessage = nil
        state.selectedIndex = 0
        return .none

      case .binding:
        state.validationMessage = nil
        return .none

      case .moveSelection(let offset):
        let count = state.rankedCandidates.count
        guard count > 0 else { return .none }
        // Clamped, not wrapped: this is a ranked best-first pick, and rolling off
        // the bottom back onto the best match reads as a jump, not as navigation.
        let next = min(max(state.selectedIndex + offset, 0), count - 1)
        guard next != state.selectedIndex else { return .none }
        state.selectedIndex = next
        return .none

      case .selectCandidate(let id):
        guard let index = state.rankedCandidates.firstIndex(where: { $0.id == id }) else {
          return .none
        }
        guard index != state.selectedIndex else { return .none }
        state.selectedIndex = index
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .createButtonTapped:
        guard let candidate = state.selectedCandidate else {
          state.validationMessage = "No matching directory."
          return .none
        }
        let trimmed = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .send(
          .delegate(
            .createTask(
              title: trimmed.isEmpty ? nil : trimmed,
              directoryURL: candidate.directoryURL
            )
          )
        )

      case .delegate:
        return .none
      }
    }
  }
}
