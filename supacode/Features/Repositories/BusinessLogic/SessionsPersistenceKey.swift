import Sharing
import SupacodeSettingsShared

nonisolated extension SharedReaderKey where Self == FileStorageKey<SessionSidecar>.Default {
  static var sessions: Self {
    Self[.fileStorage(SupacodePaths.sessionsURL), default: [:]]
  }
}
