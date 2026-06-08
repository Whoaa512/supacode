import Foundation

public nonisolated enum WorkflowCategory: String, Codable, CaseIterable, Sendable {
  case understand
  case build
  case review
  case ship
  case package

  public var displayName: String {
    switch self {
    case .understand: "Understand"
    case .build: "Build"
    case .review: "Review"
    case .ship: "Ship"
    case .package: "Package"
    }
  }
}
