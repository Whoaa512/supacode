import Foundation

/// Where a workflow run is launched. MVP only supports a new terminal tab,
/// but this is modeled as an enum so future launch targets (split, existing
/// tab, background) can be added without changing `WorkflowDefinition`.
public nonisolated enum WorkflowLaunchMode: String, Codable, CaseIterable, Sendable {
  case newTab

  public var defaultName: String {
    switch self {
    case .newTab: "New tab"
    }
  }
}
