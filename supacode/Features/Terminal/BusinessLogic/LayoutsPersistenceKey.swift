import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

nonisolated struct LayoutsKeyID: Hashable, Sendable {}

/// Load-only reader for the persisted layouts. Absent and unreadable both
/// fall back to the empty initial value, so readers never see empty state while
/// real records are persisted.
nonisolated struct LayoutsKey: SharedKey {
  private static let logger = SupaLogger("Layouts")

  var id: LayoutsKeyID { LayoutsKeyID() }

  func load(
    context _: LoadContext<TaskLayoutsFile>,
    continuation: LoadContinuation<TaskLayoutsFile>
  ) {
    // Absent and unreadable both serve the empty initial value here: this
    // reader only seeds sidebar badges. Destructive consumers (the orphan
    // reaper) read `TaskLayoutsFile.readPersisted(from:)` directly and skip on
    // `.unreadable`.
    @Dependency(\.defaultAppStorage) var store
    switch TaskLayoutsFile.readPersisted(from: store) {
    case .file(let file):
      continuation.resume(returning: file)
    case .absent, .unreadable:
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<TaskLayoutsFile>,
    subscriber _: SharedSubscriber<TaskLayoutsFile>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _: TaskLayoutsFile,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    // No-op: `LayoutsIncrementalWriter` is the sole writer for the persisted layouts blob.
    continuation.resume()
  }
}

nonisolated extension SharedReaderKey where Self == LayoutsKey.Default {
  static var layouts: Self {
    Self[LayoutsKey(), default: TaskLayoutsFile()]
  }
}
