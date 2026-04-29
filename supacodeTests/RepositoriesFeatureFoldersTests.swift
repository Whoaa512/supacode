import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureFoldersTests {
  @Test func folderCreatedAppendsFolderAndPersists() async {
    let folderID = UUID()
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = UUIDGenerator { folderID }
    }

    await store.send(.folderCreated(name: "Work")) {
      $0.$sidebar.withLock { sidebar in
        sidebar.folders = IdentifiedArray(uniqueElements: [SidebarFolder(id: folderID, name: "Work")])
        sidebar.rootOrder = [.folder(folderID)]
      }
    }
  }

  @Test func folderRenamedUpdatesName() async {
    let folderID = UUID()
    var initial = RepositoriesFeature.State()
    initial.$sidebar.withLock { sidebar in
      sidebar.folders = IdentifiedArray(uniqueElements: [SidebarFolder(id: folderID, name: "Work")])
      sidebar.rootOrder = [.folder(folderID)]
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.folderRenamed(folderID, "Personal")) {
      $0.$sidebar.withLock { sidebar in
        sidebar.folders[id: folderID]?.name = "Personal"
      }
    }
  }

  @Test func repositoryMovedToFolderUpdatesBothContainers() async {
    let folderID = UUID()
    var initial = RepositoriesFeature.State()
    initial.$sidebar.withLock { sidebar in
      sidebar.folders = IdentifiedArray(uniqueElements: [SidebarFolder(id: folderID, name: "Work")])
      sidebar.rootOrder = [.folder(folderID), .repository("/tmp/repo")]
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.repositoryMovedToFolder("/tmp/repo", folderID: folderID, destinationIndex: 0)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.folders[id: folderID]?.repositoryIDs = ["/tmp/repo"]
        sidebar.rootOrder = [.folder(folderID)]
      }
    }
  }

  @Test func folderDeletedReturnsReposToRoot() async {
    let folderID = UUID()
    var initial = RepositoriesFeature.State()
    initial.$sidebar.withLock { sidebar in
      sidebar.folders = IdentifiedArray(
        uniqueElements: [SidebarFolder(id: folderID, name: "Work", repositoryIDs: ["/tmp/a", "/tmp/b"])]
      )
      sidebar.rootOrder = [.folder(folderID), .repository("/tmp/c")]
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.folderDeleted(folderID)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.folders = []
        sidebar.rootOrder = [.repository("/tmp/a"), .repository("/tmp/b"), .repository("/tmp/c")]
      }
    }
  }

  @Test func folderCollapseToggledFlips() async {
    let folderID = UUID()
    var initial = RepositoriesFeature.State()
    initial.$sidebar.withLock { sidebar in
      sidebar.folders = IdentifiedArray(uniqueElements: [SidebarFolder(id: folderID, name: "Work")])
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.folderCollapseToggled(folderID)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.collapsedFolderIDs = [folderID]
      }
    }

    await store.send(.folderCollapseToggled(folderID)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.collapsedFolderIDs = []
      }
    }
  }

  @Test func searchQueryMatchesFolderContainingMatchingRepo() {
    var state = RepositoriesFeature.State()
    let worktree = Worktree(
      id: "/tmp/acme/main",
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/acme/main"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/acme"),
    )
    let repo = Repository(
      id: "/tmp/acme",
      rootURL: URL(fileURLWithPath: "/tmp/acme"),
      name: "acme",
      worktrees: IdentifiedArray(uniqueElements: [worktree]),
    )
    state.repositories = IdentifiedArray(uniqueElements: [repo])
    let folder = SidebarFolder(id: UUID(), name: "Work", repositoryIDs: ["/tmp/acme"])

    #expect(state.folderMatchesSearch(folder, query: "acme"))
    #expect(state.folderMatchesSearch(folder, query: "work"))
    #expect(!state.folderMatchesSearch(folder, query: "zzz"))
    #expect(state.repositoryMatchesSearch(repo, query: "acme"))
    #expect(!state.repositoryMatchesSearch(repo, query: "nope"))
  }

  @Test func sidebarSearchQueryChangedStoresValue() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }
    await store.send(.sidebarSearchQueryChanged("hello")) {
      $0.sidebarSearchQuery = "hello"
    }
  }

  @Test func sidebarDisplayItemsFallsBackToRepositoryOrder() {
    var state = RepositoriesFeature.State()
    let repoA = Repository(
      id: "/tmp/a",
      rootURL: URL(fileURLWithPath: "/tmp/a"),
      name: "a",
      worktrees: [],
    )
    let repoB = Repository(
      id: "/tmp/b",
      rootURL: URL(fileURLWithPath: "/tmp/b"),
      name: "b",
      worktrees: [],
    )
    state.repositories = IdentifiedArray(uniqueElements: [repoA, repoB])
    state.repositoryRoots = [repoA.rootURL, repoB.rootURL]
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repoA.id] = .init()
      sidebar.sections[repoB.id] = .init()
    }

    let items = state.sidebarDisplayItems()
    #expect(items == [.repository("/tmp/a"), .repository("/tmp/b")])
  }

  @Test func sidebarDisplayItemsUsesFolderRootOrder() {
    let folderID = UUID()
    var state = RepositoriesFeature.State()
    let repoA = Repository(
      id: "/tmp/a",
      rootURL: URL(fileURLWithPath: "/tmp/a"),
      name: "a",
      worktrees: [],
    )
    let repoB = Repository(
      id: "/tmp/b",
      rootURL: URL(fileURLWithPath: "/tmp/b"),
      name: "b",
      worktrees: [],
    )
    state.repositories = IdentifiedArray(uniqueElements: [repoA, repoB])
    state.$sidebar.withLock { sidebar in
      sidebar.folders = IdentifiedArray(
        uniqueElements: [SidebarFolder(id: folderID, name: "Work", repositoryIDs: ["/tmp/a"])]
      )
      sidebar.rootOrder = [.folder(folderID), .repository("/tmp/b")]
    }

    let items = state.sidebarDisplayItems()
    #expect(items == [.folder(folderID, repositoryIDs: ["/tmp/a"]), .repository("/tmp/b")])
  }

  @Test func sidebarRootReorderedMovesItems() async {
    let folderID = UUID()
    var initial = RepositoriesFeature.State()
    initial.$sidebar.withLock { sidebar in
      sidebar.folders = IdentifiedArray(uniqueElements: [SidebarFolder(id: folderID, name: "Work")])
      sidebar.rootOrder = [.repository("/tmp/a"), .folder(folderID), .repository("/tmp/b")]
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.sidebarRootReordered(IndexSet(integer: 2), 0)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.rootOrder = [.repository("/tmp/b"), .repository("/tmp/a"), .folder(folderID)]
      }
    }
  }
}
