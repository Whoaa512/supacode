import Foundation

/// Whether a workflow is shared across every project or scoped to one.
public nonisolated enum WorkflowScope: String, Codable, Sendable {
  case global
  case project
}

/// A named agent-launch recipe. Unlike `ScriptDefinition` (a shell command),
/// a workflow carries a prompt template, bounded context selectors, a target
/// harness, and follow-up steering actions. Built-ins are computed (never
/// persisted); user-defined workflows persist in `GlobalSettings.globalWorkflows`.
///
/// `promptTemplate` supports simple `{{token}}` substitution. Known tokens:
/// `{{context}}`, `{{commits}}`, `{{url}}`, `{{note}}`. Unknown tokens are
/// stripped at render time.
public nonisolated struct WorkflowDefinition: Identifiable, Codable, Equatable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var description: String
  public var category: WorkflowCategory
  public var systemImage: String
  public var tintColor: RepositoryColor
  public var favorite: Bool
  public var scope: WorkflowScope
  public var promptTemplate: String
  public var defaultContextSelectors: [WorkflowContextSelector]
  public var defaultLaunchMode: WorkflowLaunchMode
  public var followUpActions: [WorkflowFollowUpAction]
  public var isBuiltIn: Bool

  public init(
    id: UUID = UUID(),
    name: String,
    description: String = "",
    category: WorkflowCategory,
    systemImage: String = "play.circle",
    tintColor: RepositoryColor = .blue,
    favorite: Bool = false,
    scope: WorkflowScope = .global,
    promptTemplate: String = "",
    defaultContextSelectors: [WorkflowContextSelector] = [],
    defaultLaunchMode: WorkflowLaunchMode = .newTab,
    followUpActions: [WorkflowFollowUpAction] = [],
    isBuiltIn: Bool = false,
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.category = category
    self.systemImage = systemImage
    self.tintColor = tintColor
    self.favorite = favorite
    self.scope = scope
    self.promptTemplate = promptTemplate
    self.defaultContextSelectors = defaultContextSelectors
    self.defaultLaunchMode = defaultLaunchMode
    self.followUpActions = followUpActions
    self.isBuiltIn = isBuiltIn
  }

  /// Replaces `{{token}}` placeholders. Unknown tokens are stripped so a
  /// half-filled launch never leaves raw `{{...}}` in the agent prompt.
  public nonisolated func renderedPrompt(substitutions: [String: String]) -> String {
    var result = promptTemplate
    for (key, value) in substitutions {
      result = result.replacing("{{\(key)}}", with: value)
    }
    // Strip any remaining unmatched tokens.
    while let open = result.range(of: "{{"),
      let close = result.range(of: "}}", range: open.upperBound..<result.endIndex)
    {
      result.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, description, category, systemImage, tintColor, favorite
    case scope, promptTemplate, defaultContextSelectors, defaultLaunchMode
    case followUpActions, isBuiltIn
  }

  /// Optional / enum fields use `try?` so a malformed override drops just that
  /// field rather than the whole workflow entry.
  public nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    description = ((try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil) ?? ""
    category = (try? container.decode(WorkflowCategory.self, forKey: .category)) ?? .build
    systemImage = ((try? container.decodeIfPresent(String.self, forKey: .systemImage)) ?? nil) ?? "play.circle"
    tintColor = ((try? container.decodeIfPresent(RepositoryColor.self, forKey: .tintColor)) ?? nil) ?? .blue
    favorite = ((try? container.decodeIfPresent(Bool.self, forKey: .favorite)) ?? nil) ?? false
    scope = ((try? container.decodeIfPresent(WorkflowScope.self, forKey: .scope)) ?? nil) ?? .global
    promptTemplate = ((try? container.decodeIfPresent(String.self, forKey: .promptTemplate)) ?? nil) ?? ""
    // Lossy per-element decode so one unknown enum case (e.g. a selector added
    // by a newer build) drops just that element, not the whole array.
    defaultContextSelectors = container.decodeLossyArrayIfPresent(forKey: .defaultContextSelectors) ?? []
    defaultLaunchMode =
      ((try? container.decodeIfPresent(WorkflowLaunchMode.self, forKey: .defaultLaunchMode)) ?? nil) ?? .newTab
    followUpActions = container.decodeLossyArrayIfPresent(forKey: .followUpActions) ?? []
    isBuiltIn = ((try? container.decodeIfPresent(Bool.self, forKey: .isBuiltIn)) ?? nil) ?? false
  }
}

// MARK: - Built-ins

extension WorkflowDefinition {
  /// Deterministic ids so a built-in keeps its identity across launches (used
  /// for favorite toggles, run linkage, and `merged` dedup against user copies).
  private static func builtInID(_ uuid: String) -> UUID {
    UUID(uuidString: uuid)!
  }

  public static let shipCheckID = builtInID("0000A001-0000-0000-0000-000000000001")
  public static let devLoopID = builtInID("0000A001-0000-0000-0000-000000000002")
  public static let fixCIID = builtInID("0000A001-0000-0000-0000-000000000003")
  public static let investigateID = builtInID("0000A001-0000-0000-0000-000000000004")
  public static let handoffID = builtInID("0000A001-0000-0000-0000-000000000005")

  public static var builtIns: [WorkflowDefinition] {
    [
      WorkflowDefinition(
        id: shipCheckID,
        name: "Ship Check",
        description: "Readiness review of the current branch before shipping.",
        category: .review,
        systemImage: "checkmark.seal",
        tintColor: .green,
        favorite: true,
        promptTemplate: """
          Do a ship-readiness review of the current branch. Check the diff, tests, \
          and PR state. Call out anything that must be fixed before merging, ranked \
          by severity. {{context}}
          """,
        defaultContextSelectors: [.currentDiff, .lastNCommits, .pullRequestMetadata],
        followUpActions: [.fixFindings, .verify, .copy, .handoff],
        isBuiltIn: true,
      ),
      WorkflowDefinition(
        id: devLoopID,
        name: "Dev Loop",
        description: "Implement the next slice, then review, iterate.",
        category: .build,
        systemImage: "hammer",
        tintColor: .orange,
        favorite: true,
        promptTemplate: """
          dev loop it: implement one thing at a time, then review, repeat until the \
          work is complete. {{note}} {{context}}
          """,
        defaultContextSelectors: [.freeformNote, .currentDiff],
        followUpActions: [.continueRun, .interviewMe, .verify, .stop],
        isBuiltIn: true,
      ),
      WorkflowDefinition(
        id: fixCIID,
        name: "Fix CI",
        description: "Diagnose and fix a failing CI build.",
        category: .ship,
        systemImage: "wrench.and.screwdriver",
        tintColor: .red,
        favorite: true,
        promptTemplate: """
          Investigate this failing CI build, explain the root cause, and fix it. \
          {{url}} {{context}}
          """,
        defaultContextSelectors: [.failingCILog, .url],
        followUpActions: [.fixFindings, .verify, .continueRun, .stop],
        isBuiltIn: true,
      ),
      WorkflowDefinition(
        id: investigateID,
        name: "Investigate",
        description: "Investigate a thread, doc, error, or question.",
        category: .understand,
        systemImage: "magnifyingglass",
        tintColor: .blue,
        promptTemplate: """
          Investigate the following and report what you find with citations. \
          {{url}} {{note}} {{context}}
          """,
        defaultContextSelectors: [.url, .freeformNote, .clipboardText],
        followUpActions: [.interviewMe, .continueRun, .copy, .handoff],
        isBuiltIn: true,
      ),
      WorkflowDefinition(
        id: handoffID,
        name: "Handoff",
        description: "Summarize current state for a fresh session.",
        category: .package,
        systemImage: "arrowshape.turn.up.right",
        tintColor: .purple,
        promptTemplate: """
          Summarize the current state of this work for a fresh session: what was \
          done, what's left, key decisions, and the next concrete step. {{context}}
          """,
        defaultContextSelectors: [.currentDiff, .lastNCommits, .freeformNote],
        followUpActions: [.copy, .verify],
        isBuiltIn: true,
      ),
    ]
  }
}

// MARK: - Collection helpers

extension [WorkflowDefinition] {
  /// Built-ins first, then user-defined workflows; built-in wins on id collision.
  public static func merged(
    builtIn: [WorkflowDefinition],
    user: [WorkflowDefinition],
  ) -> [WorkflowDefinition] {
    let builtInIDs = Set(builtIn.map(\.id))
    return builtIn + user.filter { !builtInIDs.contains($0.id) }
  }

  public var favorites: [WorkflowDefinition] {
    filter(\.favorite)
  }
}
