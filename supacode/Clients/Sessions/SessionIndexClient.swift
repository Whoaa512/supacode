import Dependencies
import Foundation
import SupacodeSettingsShared

nonisolated struct SessionIndexClient: Sendable {
  var cached: @Sendable () async -> [SessionSummary]
  var refresh: @Sendable () async throws -> [SessionSummary]
}

extension SessionIndexClient: DependencyKey {
  static let liveValue: SessionIndexClient = {
    let source = PiSessionSource(
      root: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent/sessions"),
      cacheURL: SupacodePaths.baseDirectory.appending(path: "session-index.json")
    )
    return SessionIndexClient(cached: { await source.cachedSessions() }, refresh: { try await source.sessions() })
  }()

  static let testValue = SessionIndexClient(cached: { [] }, refresh: { [] })
}

extension DependencyValues {
  var sessionIndex: SessionIndexClient {
    get { self[SessionIndexClient.self] }
    set { self[SessionIndexClient.self] = newValue }
  }
}
