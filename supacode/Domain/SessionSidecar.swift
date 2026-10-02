import Foundation

typealias SessionSidecar = [SessionKey: SessionSidecarEntry]

nonisolated struct SessionSidecarEntry: Equatable, Codable, Sendable {
  var settledAt: Date?
  var manualUnsettledAtActivity: Date?
  private(set) var branches: [String] = []

  init(
    settledAt: Date? = nil,
    manualUnsettledAtActivity: Date? = nil,
    branches: [String] = []
  ) {
    self.settledAt = settledAt
    self.manualUnsettledAtActivity = manualUnsettledAtActivity
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
      branches: try container.decodeIfPresent([String].self, forKey: .branches) ?? []
    )
  }
}
