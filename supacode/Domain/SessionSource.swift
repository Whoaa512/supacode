import Foundation
import SupacodeSettingsShared

nonisolated protocol SessionSource: Sendable {
  func sessions() async throws -> [SessionSummary]
  func resumeCommand(sessionID: String) -> String?
}

nonisolated struct SessionKey: Hashable, Codable, Sendable, RawRepresentable {
  let rawValue: String

  init(rawValue: String) { self.rawValue = rawValue }

  init(harness: SkillAgent, sessionID: String) {
    rawValue = "\(harness.rawValue):\(sessionID)"
  }

  var isValid: Bool {
    let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, SkillAgent(rawValue: String(parts[0])) != nil else { return false }
    return AgentPresenceOSC.sanitizedSessionRef(String(parts[1])) != nil
  }
}

nonisolated struct SessionSummary: Equatable, Codable, Sendable, Identifiable {
  var harness: SkillAgent
  var sessionID: String
  var createdAt: Date
  var cwd: String
  var title: String
  var messageCount: Int
  var lastActivity: Date
  var isVerified: Bool = true

  var id: SessionKey { SessionKey(harness: harness, sessionID: sessionID) }

  private enum CodingKeys: String, CodingKey {
    case harness, sessionID, createdAt, cwd, title, messageCount, lastActivity
  }

}
