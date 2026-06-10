import Foundation
import SupacodeSettingsShared

enum ClipboardWorkflowHint: Equatable, Sendable {
  case fixCI
  case investigate
  case shipCheck

  var suggestedBuiltInID: UUID {
    switch self {
    case .fixCI:
      UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    case .investigate:
      UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    case .shipCheck:
      UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    }
  }
}

enum ClipboardPreselection {
  static func hint(from text: String) -> ClipboardWorkflowHint? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
      return nil
    }
    if host.contains("buildkite") {
      return .fixCI
    }
    if host.contains("slack.com") {
      return .investigate
    }
    if host.contains("docs.google.com") {
      return .investigate
    }
    if host.contains("github.com") || host.contains("github") {
      let path = url.path.lowercased()
      if path.contains("/pull/") {
        return .shipCheck
      }
      return .investigate
    }
    return nil
  }
}
