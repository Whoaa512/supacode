import Foundation
import SupacodeSettingsShared

/// Builds the rendered agent prompt for a workflow launch from bounded context.
///
/// Context selectors become short instructions (e.g. "Use the current diff and
/// the last 5 commits as context."), never raw repo dumps — the agent runs in
/// the worktree and can read git itself. Free-form inputs (`note`, `url`) fill
/// their own tokens.
enum WorkflowLaunchComposer {
  struct Inputs: Equatable {
    var selectors: [WorkflowContextSelector]
    var note: String
    var url: String
    var commitCount: Int

    init(
      selectors: [WorkflowContextSelector] = [],
      note: String = "",
      url: String = "",
      commitCount: Int = 5,
    ) {
      self.selectors = selectors
      self.note = note
      self.url = url
      self.commitCount = commitCount
    }
  }

  static func substitutions(for inputs: Inputs) -> [String: String] {
    [
      "context": contextSentence(for: inputs),
      "note": inputs.note.trimmingCharacters(in: .whitespacesAndNewlines),
      "url": inputs.url.trimmingCharacters(in: .whitespacesAndNewlines),
      "commits": String(inputs.commitCount),
    ]
  }

  static func prompt(for workflow: WorkflowDefinition, inputs: Inputs) -> String {
    workflow.renderedPrompt(substitutions: substitutions(for: inputs))
  }

  private static func contextSentence(for inputs: Inputs) -> String {
    let phrases = inputs.selectors.compactMap { phrase(for: $0, commitCount: inputs.commitCount) }
    guard !phrases.isEmpty else { return "" }
    return "Use \(listPhrase(phrases)) as context."
  }

  private static func phrase(for selector: WorkflowContextSelector, commitCount: Int) -> String? {
    switch selector {
    case .currentDiff: "the current diff"
    case .lastNCommits: "the last \(commitCount) commits"
    case .pullRequestMetadata: "the pull request metadata"
    case .selectedFiles: "the selected files"
    case .failingCILog: "the failing CI log"
    // Free-form selectors carry their own tokens, not context phrasing.
    case .url, .clipboardText, .freeformNote: nil
    }
  }

  private static func listPhrase(_ phrases: [String]) -> String {
    switch phrases.count {
    case 1: phrases[0]
    case 2: "\(phrases[0]) and \(phrases[1])"
    default:
      "\(phrases.dropLast().joined(separator: ", ")), and \(phrases[phrases.count - 1])"
    }
  }
}
