import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@Suite(.serialized)
@MainActor
struct CommandPaletteSessionDirectoryTests {
  @Test func newSessionBrowsePurposeDelegatesAndResets() async {
    let directory = URL(fileURLWithPath: "/tmp/session-dir", isDirectory: true)
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    } withDependencies: {
      $0.fileSystemBrowseClient.listDirectory = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.enterBrowseMode(basePath: directory, purpose: .newSession)) {
      $0.isPresented = true
      $0.mode = .browse
      $0.browse.purpose = .newSession
    }
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browseSelectRepository(directory)) {
      $0.isPresented = false
      $0.mode = .commands
      $0.query = ""
      $0.selectedIndex = nil
      $0.browse = CommandPaletteFeature.BrowseState()
    }
    await store.receive(\.delegate.newSessionDirectorySelected)
  }

  @Test func newSessionNativeFallbackDelegatesPurposeAndResets() async {
    let directory = URL(fileURLWithPath: "/tmp/session-native", isDirectory: true)
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    } withDependencies: {
      $0.fileSystemBrowseClient.listDirectory = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.enterBrowseMode(basePath: directory, purpose: .newSession)) {
      $0.isPresented = true
      $0.mode = .browse
      $0.browse.purpose = .newSession
    }
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browseOpenNativePanel) {
      $0.isPresented = false
      $0.mode = .commands
      $0.query = ""
      $0.selectedIndex = nil
      $0.browse = CommandPaletteFeature.BrowseState()
    }
    await store.receive(.delegate(.browseOpenNativePanel(.newSession)))
  }

  @Test func defaultBrowsePurposeStillOpensRepositoryAndResets() async {
    let directory = URL(fileURLWithPath: "/tmp/repo-dir", isDirectory: true)
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    } withDependencies: {
      $0.fileSystemBrowseClient.listDirectory = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.enterBrowseMode(basePath: directory)) {
      $0.isPresented = true
      $0.mode = .browse
      $0.browse.purpose = .openRepository
    }
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browseSelectRepository(directory)) {
      $0.isPresented = false
      $0.mode = .commands
      $0.query = ""
      $0.selectedIndex = nil
      $0.browse = CommandPaletteFeature.BrowseState()
    }
    await store.receive(\.delegate.browseSelectRepository)
  }

  // MARK: - Known directories (P1)

  private let alpha = NewTaskDirectory(
    id: "/Users/me/code/alpha", name: "alpha", repositoryName: "alpha-repo", path: "~/code/alpha",
    localPath: "/Users/me/code/alpha", hostLabel: nil)
  private let beta = NewTaskDirectory(
    id: "/Users/me/code/beta", name: "beta", repositoryName: nil, path: "~/code/beta",
    localPath: "/Users/me/code/beta", hostLabel: nil)
  private let gamma = NewTaskDirectory(
    id: "me@box/srv/gamma", name: "gamma", repositoryName: "gamma-repo", path: "/srv/gamma",
    localPath: nil, hostLabel: "me@box")
  private var all: [NewTaskDirectory] { [alpha, beta, gamma] }

  private struct FileSystemCalls {
    let lists = LockIsolated<[URL]>([])
    let searches = LockIsolated<[String]>([])
  }

  private func pickerStore(calls: FileSystemCalls) -> TestStoreOf<CommandPaletteFeature> {
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.fileSystemBrowseClient.listDirectory = { url in
        calls.lists.withValue { $0.append(url) }
        return []
      }
      $0.fileSystemBrowseClient.searchDirectories = { _, leaf, _ in
        calls.searches.withValue { $0.append(leaf) }
        return []
      }
    }
    store.exhaustivity = .off
    return store
  }

  @Test func newSessionPickerOpensOnKnownDirectories() async {
    let calls = FileSystemCalls()
    let store = pickerStore(calls: calls)

    await store.send(.enterBrowseMode(basePath: URL(fileURLWithPath: "/tmp/x"), purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)
    await store.finish()

    #expect(store.state.browse.pathQuery == "")
    #expect(store.state.browse.listsKnown)
    #expect(store.state.browse.knownMatches == all)
    #expect(store.state.browse.selectedIndex == 0)
    #expect(store.state.browse.filteredEntries.isEmpty)
    #expect(store.state.browse.isLoading == false)
    #expect(calls.lists.value.isEmpty)
    #expect(calls.searches.value.isEmpty)
  }

  @Test func emptyRosterOpensOnTheBasePath() async {
    let calls = FileSystemCalls()
    let store = pickerStore(calls: calls)

    await store.send(.enterBrowseMode(basePath: URL(fileURLWithPath: "/tmp/x"), purpose: .newSession, known: []))
    await store.receive(\.browsePathQueryChanged)
    await store.finish()

    #expect(store.state.browse.pathQuery == "/tmp/x/")
    #expect(!store.state.browse.listsKnown)
    #expect(calls.lists.value.count == 1)
  }

  @Test func slashlessQueryFiltersKnownDirectories() async {
    let calls = FileSystemCalls()
    let store = pickerStore(calls: calls)
    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)

    await store.send(.browsePathQueryChanged("gam"))
    #expect(store.state.browse.knownMatches == [gamma])
    #expect(store.state.browse.selectedIndex == 0)
    #expect(calls.lists.value.isEmpty)
    #expect(calls.searches.value.isEmpty)

    await store.send(.browsePathQueryChanged("zzz"))
    #expect(store.state.browse.knownMatches.isEmpty)
    #expect(store.state.browse.selectedIndex == nil)
    await store.send(.browseSubmit)
    await store.finish()
    #expect(store.state.isPresented)
  }

  @Test func pathTextLeavesKnownMode() async {
    let calls = FileSystemCalls()
    let store = pickerStore(calls: calls)
    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)

    await store.send(.browsePathQueryChanged("~/"))
    #expect(!store.state.browse.listsKnown)
    #expect(store.state.browse.knownMatches.isEmpty)
    await store.receive(\.browseDirectoryLoaded)
    #expect(calls.lists.value.count == 1)

    await store.send(.browsePathQueryChanged("al"))
    await store.finish()
    #expect(store.state.browse.listsKnown)
    #expect(store.state.browse.knownMatches == [alpha])
    #expect(store.state.browse.isLoading == false)
    #expect(store.state.browse.loadedDirectory == nil)
    #expect(calls.lists.value.count == 1)
    #expect(calls.searches.value.isEmpty)
  }

  @Test func staleLoadInKnownModeIsIgnored() async {
    let store = pickerStore(calls: FileSystemCalls())
    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browseMoveSelection(.downSelection)) { $0.browse.selectedIndex = 1 }

    let home = store.state.browse.directoryURL
    let entry = DirectoryEntry(name: "stale", fullPath: "/Users/me/stale", isGitRepo: false)
    await store.send(.browseDirectoryLoaded(directory: home, entries: [entry]))
    await store.send(.browseSearchResultsLoaded(directory: home, query: "", results: [entry]))
    await store.finish()

    #expect(store.state.browse.filteredEntries.isEmpty)
    #expect(store.state.browse.entries.isEmpty)
    #expect(store.state.browse.knownMatches == all)
    #expect(store.state.browse.selectedIndex == 1)
  }

  @Test(arguments: [CommandPaletteFeature.Action.browseSubmit, .browseForceOpen])
  func submitOnAKnownRowDelegatesItsIdAndKind(confirm: CommandPaletteFeature.Action) async {
    let store = pickerStore(calls: FileSystemCalls())
    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browseMoveSelection(.downSelection)) { $0.browse.selectedIndex = 1 }

    await store.send(confirm)
    await store.receive(.browseSelectKnown(beta.id)) {
      $0.isPresented = false
      $0.mode = .commands
      $0.query = ""
      $0.selectedIndex = nil
      $0.browse = CommandPaletteFeature.BrowseState()
    }
    await store.receive(.delegate(.newTaskDirectoryPicked(beta.id, kind: .agent)))
    await store.finish()
  }

  @Test func shellChoiceRidesOnEveryConfirm() async {
    let directory = URL(fileURLWithPath: "/tmp/session-dir", isDirectory: true)
    let store = pickerStore(calls: FileSystemCalls())

    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browseToggleKind) { $0.browse.kind = .shell }
    await store.send(.browseSubmit)
    await store.receive(\.browseSelectKnown)
    await store.receive(.delegate(.newTaskDirectoryPicked(alpha.id, kind: .shell)))
    #expect(store.state.browse.kind == .agent)

    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browseKindChanged(.shell)) { $0.browse.kind = .shell }
    await store.send(.browseSelectRepository(directory))
    await store.receive(.delegate(.newSessionDirectorySelected(directory, kind: .shell)))
    #expect(store.state.browse.kind == .agent)

    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browseToggleKind) { $0.browse.kind = .shell }
    await store.send(.browseOpenNativePanel)
    await store.receive(.delegate(.browseOpenNativePanel(.newSession, kind: .shell)))
    await store.finish()
    #expect(store.state.browse.kind == .agent)
  }

  @Test func toggleKeepsQueryAndSelection() async {
    let store = pickerStore(calls: FileSystemCalls())
    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browsePathQueryChanged("be"))
    let before = store.state.browse

    await store.send(.browseToggleKind) { $0.browse.kind = .shell }
    await store.send(.browseToggleKind) { $0.browse.kind = .agent }
    await store.finish()

    #expect(store.state.browse == before)
    #expect(store.state.browse.pathQuery == "be")
    #expect(store.state.browse.knownMatches == [beta])
    #expect(store.state.browse.selectedIndex == 0)
  }

  @Test func tabOnALocalKnownRowBrowsesFromIt() async {
    let calls = FileSystemCalls()
    let store = pickerStore(calls: calls)
    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)

    await store.send(.browseAutocomplete)
    await store.receive(.browsePathQueryChanged(BrowsePath.descending(into: "/Users/me/code/alpha", from: "~/")))
    await store.finish()
    #expect(!store.state.browse.listsKnown)
    #expect(calls.lists.value == [URL(fileURLWithPath: "/Users/me/code/alpha").standardized])
  }

  @Test func tabOnARemoteKnownRowDoesNothing() async {
    let calls = FileSystemCalls()
    let store = pickerStore(calls: calls)
    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)
    await store.send(.browseMoveSelection(.upSelection)) { $0.browse.selectedIndex = 2 }
    #expect(store.state.browse.selectedKnown == gamma)

    await store.send(.browseAutocomplete)
    await store.finish()
    #expect(store.state.browse.listsKnown)
    #expect(store.state.browse.selectedIndex == 2)
    #expect(calls.lists.value.isEmpty)
  }

  @Test func moveSelectionWrapsOverKnownRows() async {
    let store = pickerStore(calls: FileSystemCalls())
    await store.send(.enterBrowseMode(basePath: nil, purpose: .newSession, known: all))
    await store.receive(\.browsePathQueryChanged)

    await store.send(.browseMoveSelection(.downSelection)) { $0.browse.selectedIndex = 1 }
    await store.send(.browseMoveSelection(.downSelection)) { $0.browse.selectedIndex = 2 }
    await store.send(.browseMoveSelection(.downSelection)) { $0.browse.selectedIndex = 0 }
    await store.send(.browseMoveSelection(.upSelection)) { $0.browse.selectedIndex = 2 }
    await store.send(.browseNavigateUp)
    await store.finish()
    #expect(store.state.browse.selectedIndex == 2)
  }

  @Test func openRepositoryPurposeIgnoresPickerActions() async {
    let store = pickerStore(calls: FileSystemCalls())
    await store.send(.enterBrowseMode(basePath: URL(fileURLWithPath: "/tmp/repo"), known: all))
    await store.receive(\.browsePathQueryChanged)
    await store.receive(\.browseDirectoryLoaded)
    #expect(store.state.browse.known.isEmpty)
    #expect(!store.state.browse.listsKnown)
    let before = store.state

    await store.send(.browseToggleKind)
    await store.send(.browseKindChanged(.shell))
    await store.send(.browseSelectKnown(alpha.id))
    await store.finish()
    #expect(store.state == before)
    #expect(store.state.isPresented)
  }
}
