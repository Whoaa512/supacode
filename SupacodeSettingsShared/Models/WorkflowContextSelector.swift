import Foundation

public nonisolated enum WorkflowContextSelector: String, Codable, CaseIterable, Sendable, Hashable {
  case currentDiff
  case lastNCommits
  case pullRequestMetadata
  case selectedFiles
  case url
  case clipboardText
  case freeformNote
  case failingCILog

  public var displayName: String {
    switch self {
    case .currentDiff: "Current Diff"
    case .lastNCommits: "Last N Commits"
    case .pullRequestMetadata: "Pull Request Metadata"
    case .selectedFiles: "Selected Files"
    case .url: "URL"
    case .clipboardText: "Clipboard Text"
    case .freeformNote: "Freeform Note"
    case .failingCILog: "Failing CI Log"
    }
  }
}
