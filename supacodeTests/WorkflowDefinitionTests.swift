import Foundation
import Testing

@testable import SupacodeSettingsShared

@MainActor
struct WorkflowDefinitionTests {
  @Test func renderedPromptSubstitutesKnownTokens() {
    let workflow = WorkflowDefinition(
      name: "T",
      category: .build,
      promptTemplate: "fix {{url}} now {{note}}",
    )
    let rendered = workflow.renderedPrompt(substitutions: ["url": "https://x", "note": "be careful"])
    #expect(rendered == "fix https://x now be careful")
  }

  @Test func renderedPromptStripsUnknownTokens() {
    let workflow = WorkflowDefinition(
      name: "T",
      category: .build,
      promptTemplate: "do {{context}} thing {{missing}} end",
    )
    let rendered = workflow.renderedPrompt(substitutions: ["context": "X"])
    #expect(rendered == "do X thing  end")
  }

  @Test func renderedPromptLeavesPlainTextIntact() {
    let workflow = WorkflowDefinition(name: "T", category: .build, promptTemplate: "no tokens here")
    #expect(workflow.renderedPrompt(substitutions: [:]) == "no tokens here")
  }

  @Test func codableRoundTrip() throws {
    let original = WorkflowDefinition(
      name: "Ship Check",
      description: "review",
      category: .review,
      systemImage: "checkmark.seal",
      tintColor: .green,
      favorite: true,
      scope: .global,
      promptTemplate: "review {{context}}",
      defaultContextSelectors: [.currentDiff, .pullRequestMetadata],
      defaultLaunchMode: .newTab,
      followUpActions: [.fixFindings, .verify],
      isBuiltIn: false,
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WorkflowDefinition.self, from: data)
    #expect(decoded == original)
  }

  @Test func mergedPutsBuiltInsFirstAndDedupesByID() {
    let shared = UUID()
    let builtIn = WorkflowDefinition(id: shared, name: "BuiltIn", category: .review, isBuiltIn: true)
    let userCopy = WorkflowDefinition(id: shared, name: "UserOverride", category: .review)
    let userOnly = WorkflowDefinition(name: "UserOnly", category: .build)

    let merged = [WorkflowDefinition].merged(builtIn: [builtIn], user: [userCopy, userOnly])
    let names = merged.map(\.name)

    #expect(merged.count == 2)
    #expect(names == ["BuiltIn", "UserOnly"])
  }

  @Test func favoritesFiltersFavoriteWorkflows() {
    let workflows = [
      WorkflowDefinition(name: "A", category: .build, favorite: true),
      WorkflowDefinition(name: "B", category: .build, favorite: false),
    ]
    let favoriteNames = workflows.favorites.map(\.name)
    #expect(favoriteNames == ["A"])
  }

  @Test func builtInsContainExpectedWorkflows() {
    let builtIns = WorkflowDefinition.builtIns
    let ids = Set(builtIns.map(\.id))
    let names = builtIns.map(\.name)
    let allBuiltIn = builtIns.allSatisfy(\.isBuiltIn)
    #expect(builtIns.count == 5)
    #expect(allBuiltIn)
    #expect(ids.contains(WorkflowDefinition.shipCheckID))
    #expect(ids.contains(WorkflowDefinition.devLoopID))
    #expect(ids.contains(WorkflowDefinition.fixCIID))
    #expect(ids.contains(WorkflowDefinition.investigateID))
    #expect(ids.contains(WorkflowDefinition.handoffID))
    #expect(names.contains("Ship Check"))
  }

  @Test func followUpSteeringPromptText() {
    #expect(WorkflowFollowUpAction.continueRun.promptText == "cont")
    #expect(WorkflowFollowUpAction.interviewMe.promptText == "intme")
    #expect(WorkflowFollowUpAction.fixFindings.promptText == "fix")
    #expect(WorkflowFollowUpAction.verify.promptText == "verify")
    #expect(WorkflowFollowUpAction.handoff.promptText == "handoff")
    #expect(WorkflowFollowUpAction.stop.promptText == nil)
    #expect(WorkflowFollowUpAction.copy.promptText == nil)
    #expect(WorkflowFollowUpAction.addContext.promptText == nil)
  }

  private static let minimalGlobalFields =
    #""appearanceMode":"dark","updatesAutomaticallyCheckForUpdates":true,"updatesAutomaticallyDownloadUpdates":false"#

  @Test func globalSettingsDefaultsMissingWorkflowsToEmpty() throws {
    let data = Data("{\(Self.minimalGlobalFields)}".utf8)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalWorkflows.isEmpty)
  }

  @Test func globalSettingsDropsMalformedWorkflowsArray() throws {
    let json = "{\(Self.minimalGlobalFields),\"globalWorkflows\":\"not-an-array\"}"
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalWorkflows.isEmpty)
  }

  @Test func globalSettingsForcesIsBuiltInFalseOnLoad() throws {
    let forged = #"{"id":"\#(UUID().uuidString)","name":"Forged","category":"build","isBuiltIn":true}"#
    let json = "{\(Self.minimalGlobalFields),\"globalWorkflows\":[\(forged)]}"
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
    let flags = settings.globalWorkflows.map(\.isBuiltIn)
    #expect(flags == [false])
  }

  @Test func contextSelectorsDropOnlyUnknownElements() throws {
    let selectors = #"["currentDiff","bogusSelector","url"]"#
    let json = #"{"id":"\#(UUID().uuidString)","name":"T","category":"build","defaultContextSelectors":\#(selectors)}"#
    let decoded = try JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
    #expect(decoded.defaultContextSelectors == [.currentDiff, .url])
  }

  @Test func unknownCategoryFallsBackToBuild() throws {
    let json = #"{"id":"\#(UUID().uuidString)","name":"T","category":"nonexistent"}"#
    let decoded = try JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
    #expect(decoded.category == .build)
  }

  @Test func harnessLookupByID() {
    let found = AgentHarnessDefinition.harness(for: "pi")
    #expect(found == AgentHarnessDefinition.pi)
    #expect(AgentHarnessDefinition.harness(for: "nope") == nil)
  }

  @Test func globalSettingsRoundTripsWorkflows() throws {
    var settings = GlobalSettings.default
    settings.globalWorkflows = [WorkflowDefinition(name: "Custom", category: .ship)]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
    let names = decoded.globalWorkflows.map(\.name)
    #expect(names == ["Custom"])
  }
}
