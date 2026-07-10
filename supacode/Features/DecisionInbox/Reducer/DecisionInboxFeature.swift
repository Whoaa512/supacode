import ComposableArchitecture
import Foundation

/// TCA projection of the decision inbox. The authority is the pure
/// `AttentionDetector` value held in state; hook events flow in through the same
/// `agentHookEventReceived` plumbing the presence feature taps (routed by
/// `AppFeature`), so there is exactly one subscription and one source of truth.
/// The reducer never subscribes to the manager itself — it only reduces the
/// events the parent hands it, which keeps it trivially testable.
@Reducer
struct DecisionInboxFeature {
  @ObservableState
  struct State: Equatable {
    /// The pure detector — the sole authority for what wants attention. Its
    /// `candidates` are a deterministic function of the events applied so far.
    var detector = AttentionDetector()
    /// Presentation projection: detector candidates minus anything the user has
    /// already resolved this session (a dismiss has no clearing hook event, so
    /// the UI must subtract it itself). Kept as an `IdentifiedArray` keyed by
    /// candidate id so the list view diffs cheaply.
    var candidates: IdentifiedArrayOf<AttentionCandidate> = []
    /// Snapshots of candidates the user resolved (focused / copied / dismissed)
    /// that the detector still reports, keyed by id. Storing the whole candidate
    /// lets us resurface a re-asked signal: `input_requested` updates in place
    /// under the same id, so when the current candidate differs from the resolved
    /// snapshot (e.g. a changed recommendation) we drop the marker and show it
    /// again. Pruned once the underlying candidate clears via a real event.
    var resolved: [String: AttentionCandidate] = [:]
    /// Whether the inbox popover is open.
    var isPresented = false

    var unresolvedCount: Int { candidates.count }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case delegate(Delegate)
    case hookEventReceived(AgentHookEvent)
    case focusTapped(id: AttentionCandidate.ID)
    case copyTapped(id: AttentionCandidate.ID)
    case dismissTapped(id: AttentionCandidate.ID)

    @CasePathable
    enum Delegate: Equatable, Sendable {
      /// Route focus to the surface that raised the candidate. The parent owns
      /// worktree/tab resolution; the inbox only knows the surface id.
      case focusSurface(sessionID: UUID)
    }
  }

  @Dependency(\.decisionInboxClient) var client
  @Dependency(\.date) var date

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding, .delegate:
        return .none

      case .hookEventReceived(let event):
        state.detector = state.detector.reducing(event)
        Self.reproject(&state)
        return .none

      case .focusTapped(let id):
        guard let candidate = state.candidates[id: id] else { return .none }
        let sessionID = candidate.sessionID
        let resolution = Self.resolution(candidate, action: .focused, at: date.now)
        Self.resolve(candidate, in: &state)
        return .merge(
          .run { _ in client.persistResolution(resolution) },
          .send(.delegate(.focusSurface(sessionID: sessionID)))
        )

      case .copyTapped(let id):
        guard let candidate = state.candidates[id: id] else { return .none }
        let text = candidate.suggestedResponse
        let resolution = Self.resolution(candidate, action: .copied, at: date.now)
        Self.resolve(candidate, in: &state)
        return .run { _ in
          client.copyToPasteboard(text)
          client.persistResolution(resolution)
        }

      case .dismissTapped(let id):
        guard let candidate = state.candidates[id: id] else { return .none }
        let resolution = Self.resolution(candidate, action: .dismissed, at: date.now)
        Self.resolve(candidate, in: &state)
        return .run { _ in client.persistResolution(resolution) }
      }
    }
  }

  /// Rebuild the presentation list from the detector, subtracting resolved
  /// candidates. A resolved marker is kept only while its snapshot still matches
  /// the detector's current candidate for that id: if the detector no longer
  /// reports the id, or reports a changed candidate (a re-ask updated in place),
  /// the marker is dropped so the fresh signal resurfaces.
  private static func reproject(_ state: inout State) {
    let all = state.detector.candidates
    let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    state.resolved = state.resolved.filter { id, snapshot in byID[id] == snapshot }
    state.candidates = IdentifiedArray(
      uniqueElements: all.filter { state.resolved[$0.id] == nil })
  }

  /// Mark a candidate resolved (snapshotting its payload) and drop it from the
  /// visible list immediately.
  private static func resolve(_ candidate: AttentionCandidate, in state: inout State) {
    state.resolved[candidate.id] = candidate
    state.candidates.remove(id: candidate.id)
  }

  private static func resolution(
    _ candidate: AttentionCandidate,
    action: InboxResolution.ChosenAction,
    at now: Date
  ) -> InboxResolution {
    InboxResolution(
      candidateID: candidate.id,
      requestID: candidate.requestID,
      sessionID: candidate.sessionID,
      kind: candidate.kind.logDescription,
      chosenAction: action,
      resolvedAt: now,
      recommendationAccepted: action.recommendationAccepted,
      dismissalReason: nil)
  }
}

extension InboxResolution.ChosenAction {
  /// Copy takes the suggested response (accepted); dismiss rejects it; focus is
  /// unknown — the user went to look, we can't claim acceptance either way.
  fileprivate var recommendationAccepted: Bool? {
    switch self {
    case .copied: true
    case .dismissed: false
    case .focused: nil
    }
  }
}

extension AttentionCandidate.Kind {
  /// Stable string form for the durable log, flattening the `.processExited`
  /// associated value into readable variants.
  var logDescription: String {
    switch self {
    case .inputRequested: "input_requested"
    case .awaitingInput: "awaiting_input"
    case .notification: "notification"
    case .processExited(let failure): failure ? "process_exited_failure" : "process_exited"
    }
  }
}

extension AttentionCandidate {
  /// Text placed on the pasteboard by `Copy Suggested Response`: the
  /// recommendation when the agent gave one, else the question so the user has
  /// something to paste back. Empty only when the candidate carries neither.
  var suggestedResponse: String {
    if let recommendation, !recommendation.isEmpty { return recommendation }
    return question ?? ""
  }
}
