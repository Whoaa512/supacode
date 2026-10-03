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

  @Test func newSessionNativeFallbackUsesTypedDirectoryAndResets() async {
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
    await store.receive(\.delegate.newSessionDirectorySelected)
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
}
