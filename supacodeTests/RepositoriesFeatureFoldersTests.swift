import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureFoldersTests {
  @Test func folderCreatedAppendsFolderAndPersists() async {
    let folderID = UUID()
    let savedFolders = LockIsolated<[SidebarFolder]>([])
    let savedOrder = LockIsolated<[SidebarRootItemID]>([])
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = UUIDGenerator { folderID }
      $0.repositoryPersistence.saveSidebarFolders = { folders in
        savedFolders.withValue { $0 = folders }
      }
      $0.repositoryPersistence.saveSidebarRootOrder = { order in
        savedOrder.withValue { $0 = order }
      }
    }

    await store.send(.folderCreated(name: "Work")) {
      $0.folders = IdentifiedArray(uniqueElements: [SidebarFolder(id: folderID, name: "Work")])
      $0.sidebarRootOrder = [.folder(folderID)]
    }
    await store.finish()

    #expect(savedFolders.value == [SidebarFolder(id: folderID, name: "Work")])
    #expect(savedOrder.value == [.folder(folderID)])
  }

  @Test func repositoryMovedToFolderUpdatesBothContainers() async {
    let folderID = UUID()
    var initial = RepositoriesFeature.State()
    initial.folders = IdentifiedArray(uniqueElements: [SidebarFolder(id: folderID, name: "Work")])
    initial.sidebarRootOrder = [.folder(folderID), .repository("/tmp/repo")]
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveSidebarFolders = { _ in }
      $0.repositoryPersistence.saveSidebarRootOrder = { _ in }
    }

    await store.send(.repositoryMovedToFolder("/tmp/repo", folderID: folderID, destinationIndex: 0)) {
      $0.folders[id: folderID]?.repositoryIDs = ["/tmp/repo"]
      $0.sidebarRootOrder = [.folder(folderID)]
    }
  }

  @Test func folderDeletedReturnsReposToRoot() async {
    let folderID = UUID()
    var initial = RepositoriesFeature.State()
    initial.folders = IdentifiedArray(
      uniqueElements: [SidebarFolder(id: folderID, name: "Work", repositoryIDs: ["/tmp/a", "/tmp/b"])]
    )
    initial.sidebarRootOrder = [.folder(folderID), .repository("/tmp/c")]
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveSidebarFolders = { _ in }
      $0.repositoryPersistence.saveSidebarRootOrder = { _ in }
    }

    await store.send(.folderDeleted(folderID)) {
      $0.folders = []
      $0.sidebarRootOrder = [.repository("/tmp/a"), .repository("/tmp/b"), .repository("/tmp/c")]
    }
  }

  @Test func folderCollapseToggledFlipsAndPersists() async {
    let folderID = UUID()
    var initial = RepositoriesFeature.State()
    initial.folders = IdentifiedArray(uniqueElements: [SidebarFolder(id: folderID, name: "Work")])
    let savedIDs = LockIsolated<[UUID]>([])
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveCollapsedFolderIDs = { ids in
        savedIDs.withValue { $0 = ids }
      }
    }

    await store.send(.folderCollapseToggled(folderID)) {
      $0.collapsedFolderIDs = [folderID]
    }
    await store.finish()
    #expect(savedIDs.value == [folderID])

    await store.send(.folderCollapseToggled(folderID)) {
      $0.collapsedFolderIDs = []
    }
    await store.finish()
    #expect(savedIDs.value == [])
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
    state.folders = IdentifiedArray(uniqueElements: [folder])

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
}
