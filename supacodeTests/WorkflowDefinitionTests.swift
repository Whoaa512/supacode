import Foundation
import Testing

@testable import SupacodeSettingsShared

struct WorkflowDefinitionTests {
  @Test func builtInsHaveStableIDs() {
    let builtIns = WorkflowDefinition.builtIns
    #expect(builtIns.count == 5)
    #expect(builtIns[0].name == "Ship Check")
    #expect(builtIns[1].name == "Dev Loop")
    #expect(builtIns[2].name == "Fix CI")
    #expect(builtIns[3].name == "Investigate")
    #expect(builtIns[4].name == "Handoff")
    for workflow in builtIns {
      #expect(workflow.isBuiltIn)
      #expect(workflow.isFavorite)
    }
  }

  @Test func encodingDecoding() throws {
    let workflow = WorkflowDefinition(
      name: "Test Workflow",
      category: .review,
      promptTemplate: "Do the thing {{#context}}with {{context}}{{/context}}",
      isFavorite: true
    )
    let data = try JSONEncoder().encode(workflow)
    let decoded = try JSONDecoder().decode(WorkflowDefinition.self, from: data)
    #expect(decoded.id == workflow.id)
    #expect(decoded.name == workflow.name)
    #expect(decoded.category == workflow.category)
    #expect(decoded.promptTemplate == workflow.promptTemplate)
    #expect(decoded.isFavorite == workflow.isFavorite)
  }

  @Test func globalSettingsWorkflowPersistence() throws {
    var settings = GlobalSettings.default
    let workflow = WorkflowDefinition(
      name: "Custom",
      category: .build,
      promptTemplate: "build it"
    )
    settings.globalWorkflows = [workflow]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
    let decodedWorkflows = decoded.globalWorkflows
    #expect(decodedWorkflows.count == 1)
    let first = try #require(decodedWorkflows.first)
    #expect(first.name == "Custom")
    #expect(first.category == .build)
  }

  @Test func globalSettingsDecodesEmptyWorkflowsGracefully() throws {
    let json = """
      {"appearanceMode": "dark", "updatesAutomaticallyCheckForUpdates": true, "updatesAutomaticallyDownloadUpdates": false, "inAppNotificationsEnabled": true, "moveNotifiedWorktreeToTop": true}
      """
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
    let workflows = decoded.globalWorkflows
    #expect(workflows.isEmpty)
  }
}
