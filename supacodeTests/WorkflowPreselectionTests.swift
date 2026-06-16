import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WorkflowPreselectionTests {
  @Test func buildkiteURLPreselectsFixCI() {
    let suggestion = WorkflowPreselection.suggestion(forPastedText: "https://buildkite.com/airbnb/x/builds/123")
    #expect(suggestion?.workflowID == WorkflowDefinition.fixCIID)
    #expect(suggestion?.contextTarget == .url)
  }

  @Test func slackURLPreselectsInvestigate() {
    let suggestion = WorkflowPreselection.suggestion(forPastedText: "https://airbnb.slack.com/archives/C123/p456")
    #expect(suggestion?.workflowID == WorkflowDefinition.investigateID)
    #expect(suggestion?.contextTarget == .url)
  }

  @Test func gdocURLPreselectsInvestigate() {
    let suggestion = WorkflowPreselection.suggestion(forPastedText: "https://docs.google.com/document/d/abc/edit")
    #expect(suggestion?.workflowID == WorkflowDefinition.investigateID)
  }

  @Test func pullRequestURLPreselectsShipCheck() {
    let suggestion = WorkflowPreselection.suggestion(forPastedText: "https://github.com/org/repo/pull/42")
    #expect(suggestion?.workflowID == WorkflowDefinition.shipCheckID)
    #expect(suggestion?.contextTarget == .url)
  }

  @Test func enterprisePullRequestURLPreselectsShipCheck() {
    let suggestion = WorkflowPreselection.suggestion(forPastedText: "https://git.musta.ch/org/repo/pull/7")
    #expect(suggestion?.workflowID == WorkflowDefinition.shipCheckID)
  }

  @Test func errorTextPreselectsFixCIIntoNote() {
    let suggestion = WorkflowPreselection.suggestion(forPastedText: "Traceback (most recent call last): ...")
    #expect(suggestion?.workflowID == WorkflowDefinition.fixCIID)
    #expect(suggestion?.contextTarget == .note)
  }

  @Test func plainTextHasNoSuggestion() {
    #expect(WorkflowPreselection.suggestion(forPastedText: "just some words") == nil)
  }

  @Test func emptyTextHasNoSuggestion() {
    #expect(WorkflowPreselection.suggestion(forPastedText: "   ") == nil)
  }
}
