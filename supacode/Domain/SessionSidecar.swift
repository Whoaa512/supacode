import Foundation

typealias SessionSidecar = [SessionKey: SessionSidecarEntry]

nonisolated struct SessionSidecarEntry: Equatable, Codable, Sendable {
  var settledAt: Date?
  var manualUnsettledAtActivity: Date?
  /// Set while the user has hidden this session from its task's sub-rows.
  /// Cleared the moment the session runs again.
  var hiddenAt: Date?
  private(set) var branches: [String] = []

  init(
    settledAt: Date? = nil,
    manualUnsettledAtActivity: Date? = nil,
    hiddenAt: Date? = nil,
    branches: [String] = []
  ) {
    self.settledAt = settledAt
    self.manualUnsettledAtActivity = manualUnsettledAtActivity
    self.hiddenAt = hiddenAt
    for branch in branches { recordBranch(branch) }
  }

  mutating func recordBranch(_ branch: String) {
    guard !branch.isEmpty, !branches.contains(branch) else { return }
    branches.append(branch)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      settledAt: try container.decodeIfPresent(Date.self, forKey: .settledAt),
      manualUnsettledAtActivity: try container.decodeIfPresent(Date.self, forKey: .manualUnsettledAtActivity),
      hiddenAt: try container.decodeIfPresent(Date.self, forKey: .hiddenAt),
      branches: try container.decodeIfPresent([String].self, forKey: .branches) ?? []
    )
  }
}
