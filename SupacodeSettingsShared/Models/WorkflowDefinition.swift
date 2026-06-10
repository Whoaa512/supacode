import Foundation

public enum WorkflowCategory: String, Codable, CaseIterable, Sendable, Equatable {
  case understand
  case build
  case review
  case ship
  case package
}

public nonisolated struct WorkflowDefinition: Identifiable, Codable, Equatable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var category: WorkflowCategory
  public var promptTemplate: String
  public var systemImage: String
  public var isFavorite: Bool
  public var isBuiltIn: Bool

  public nonisolated init(
    id: UUID = UUID(),
    name: String,
    category: WorkflowCategory,
    promptTemplate: String,
    systemImage: String = "terminal",
    isFavorite: Bool = false,
    isBuiltIn: Bool = false
  ) {
    self.id = id
    self.name = name
    self.category = category
    self.promptTemplate = promptTemplate
    self.systemImage = systemImage
    self.isFavorite = isFavorite
    self.isBuiltIn = isBuiltIn
  }
}

extension WorkflowDefinition {
  public static let builtIns: [WorkflowDefinition] = [
    WorkflowDefinition(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      name: "Ship Check",
      category: .review,
      promptTemplate: "Run a ship check on this project. Review the current branch for readiness: check tests pass, lint is clean, PR description is complete, and flag any issues that should be fixed before merging.",
      systemImage: "checkmark.shield",
      isFavorite: true,
      isBuiltIn: true
    ),
    WorkflowDefinition(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      name: "Dev Loop",
      category: .build,
      promptTemplate: "Start a dev loop: implement the next task, then review your own work for correctness and quality. Repeat until complete.",
      systemImage: "arrow.trianglehead.2.clockwise",
      isFavorite: true,
      isBuiltIn: true
    ),
    WorkflowDefinition(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
      name: "Fix CI",
      category: .ship,
      promptTemplate: "Fix the CI failures. Investigate the failing checks, identify root causes, and apply fixes.{{#context}} Context: {{context}}{{/context}}",
      systemImage: "wrench.and.screwdriver",
      isFavorite: true,
      isBuiltIn: true
    ),
    WorkflowDefinition(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      name: "Investigate",
      category: .understand,
      promptTemplate: "Investigate this:{{#context}} {{context}}{{/context}}{{^context}} explore the codebase and report findings.{{/context}}",
      systemImage: "magnifyingglass",
      isFavorite: true,
      isBuiltIn: true
    ),
    WorkflowDefinition(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
      name: "Handoff",
      category: .package,
      promptTemplate: "Create a handoff summary of the current state of work. Include: what was done, what's remaining, key decisions made, and any blockers or open questions for the next session.",
      systemImage: "arrow.right.arrow.left",
      isFavorite: true,
      isBuiltIn: true
    ),
  ]
}
