import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// The per-repository answer to Resolved #11's conflict question, editable
/// before the question is ever asked — and re-editable after, which is the only
/// way back once "remember this choice" has been ticked.
@MainActor
struct RepositorySettingsTaskIsolationTests {
  private static let rootURL = URL(filePath: "/tmp/test-repo-task-isolation")

  private func makeStore(
    isolation: TaskDirectoryIsolation? = nil
  ) -> TestStore<RepositorySettingsFeature.State, RepositorySettingsFeature.Action> {
    var settings = RepositorySettings.default
    settings.taskDirectoryIsolation = isolation
    return TestStore(
      initialState: RepositorySettingsFeature.State(rootURL: Self.rootURL, settings: settings)
    ) {
      RepositorySettingsFeature()
    }
  }

  @Test(.dependencies) func pickingAnIsolationPolicyPersistsAndNotifies() async {
    let store = makeStore()
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.binding(.set(\.settings.taskDirectoryIsolation, .share)))
    await store.receive(\.delegate.settingsChanged)

    #expect(store.state.settings.taskDirectoryIsolation == .share)
    @Shared(.repositorySettings(Self.rootURL, host: nil)) var persisted
    #expect(persisted.taskDirectoryIsolation == .share)
  }

  /// Back to "ask me": the third state has to be reachable from the picker, or a
  /// remembered answer is permanent.
  @Test(.dependencies) func clearingThePolicyRestoresTheQuestion() async {
    let store = makeStore(isolation: .isolate)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.binding(.set(\.settings.taskDirectoryIsolation, nil)))
    await store.receive(\.delegate.settingsChanged)

    #expect(store.state.settings.taskDirectoryIsolation == nil)
    #expect(
      TaskDirectoryConflictPolicy.resolve(
        isDirectoryBusy: true,
        repositoryIsolation: store.state.settings.taskDirectoryIsolation
      ) == .ask
    )
  }
}
