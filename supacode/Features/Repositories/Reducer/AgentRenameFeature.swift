import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// The Agents-tab rename sheet. Validation lives here so Save can be disabled
/// before a doomed rename reaches `AgentPresenceFeature`.
@Reducer
struct AgentRenameFeature {
  @ObservableState
  struct State: Equatable {
    let worktreeID: Worktree.ID
    let agent: SkillAgent
    /// Row title the sheet is editing, for the explanatory header.
    let subject: String
    /// Names held by other live agents; a rename onto one of these is rejected.
    let takenNames: Set<String>
    var name: String

    /// `nil` while the input is acceptable. Empty input means "clear the name".
    var validationError: String? {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      guard AgentPresenceFeature.validate(name: trimmed) else {
        return "Use 1–32 characters: a lowercase letter, then lowercase letters, digits, _ or -."
      }
      guard !takenNames.contains(trimmed) else { return "Another running agent already uses that name." }
      return nil
    }

    var canSave: Bool { validationError == nil }

    /// The value to store: `nil` clears the name.
    var resolvedName: String? {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case saveButtonTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case save(worktreeID: Worktree.ID, agent: SkillAgent, name: String?)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .saveButtonTapped:
        guard state.canSave else { return .none }
        return .send(
          .delegate(.save(worktreeID: state.worktreeID, agent: state.agent, name: state.resolvedName))
        )

      case .delegate:
        return .none
      }
    }
  }
}
