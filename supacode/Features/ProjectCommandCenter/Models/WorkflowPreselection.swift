import Foundation
import SupacodeSettingsShared

/// Lightweight, paste-aware preselection. Biases the launcher toward a likely
/// workflow based on clipboard / selected text. Never auto-runs — callers use
/// the suggestion only to preselect a workflow and route the text into the
/// right context field.
enum WorkflowPreselection {
  /// Which context field the pasted text should populate.
  enum ContextTarget: Equatable {
    case url
    case note
  }

  struct Suggestion: Equatable {
    var workflowID: UUID
    var contextTarget: ContextTarget
  }

  static func suggestion(forPastedText raw: String) -> Suggestion? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    if let urlSuggestion = suggestionForURL(text) {
      return urlSuggestion
    }
    if looksLikeError(text) {
      return Suggestion(workflowID: WorkflowDefinition.fixCIID, contextTarget: .note)
    }
    return nil
  }

  private static func suggestionForURL(_ text: String) -> Suggestion? {
    guard let host = firstURLHost(in: text) else { return nil }

    if host.contains("buildkite.com") {
      return Suggestion(workflowID: WorkflowDefinition.fixCIID, contextTarget: .url)
    }
    if host.contains("slack.com") {
      return Suggestion(workflowID: WorkflowDefinition.investigateID, contextTarget: .url)
    }
    if host.contains("docs.google.com") {
      return Suggestion(workflowID: WorkflowDefinition.investigateID, contextTarget: .url)
    }
    if isPullRequestURL(text, host: host) {
      return Suggestion(workflowID: WorkflowDefinition.shipCheckID, contextTarget: .url)
    }
    return nil
  }

  private static func firstURLHost(in text: String) -> String? {
    for token in text.split(whereSeparator: { $0.isWhitespace }) {
      guard let url = URL(string: String(token)), let host = url.host() else { continue }
      return host
    }
    return nil
  }

  private static func isPullRequestURL(_ text: String, host: String) -> Bool {
    let isGitHostName = host.contains("github.com") || host.contains("git.")
    return isGitHostName && (text.contains("/pull/") || text.contains("/pull-requests/"))
  }

  private static func looksLikeError(_ text: String) -> Bool {
    let markers = ["Traceback", "Exception", "error:", "Error:", "panic:", "    at ", "FAILED"]
    return markers.contains { text.contains($0) }
  }
}
