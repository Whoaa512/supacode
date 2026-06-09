import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WorkflowLaunchComposerTests {
  @Test func contextSentenceForSingleSelector() {
    let subs = WorkflowLaunchComposer.substitutions(for: .init(selectors: [.currentDiff]))
    #expect(subs["context"] == "Use the current diff as context.")
  }

  @Test func contextSentenceForTwoSelectors() {
    let subs = WorkflowLaunchComposer.substitutions(for: .init(selectors: [.currentDiff, .pullRequestMetadata]))
    #expect(subs["context"] == "Use the current diff and the pull request metadata as context.")
  }

  @Test func contextSentenceForThreeSelectorsUsesOxfordComma() {
    let inputs = WorkflowLaunchComposer.Inputs(
      selectors: [.currentDiff, .lastNCommits, .pullRequestMetadata],
      commitCount: 5,
    )
    let subs = WorkflowLaunchComposer.substitutions(for: inputs)
    #expect(subs["context"] == "Use the current diff, the last 5 commits, and the pull request metadata as context.")
  }

  @Test func freeFormSelectorsAddNoContextSentence() {
    let subs = WorkflowLaunchComposer.substitutions(for: .init(selectors: [.url, .freeformNote]))
    #expect(subs["context"] == "")
  }

  @Test func tokensCarryNoteURLAndCommits() {
    let inputs = WorkflowLaunchComposer.Inputs(note: "be careful", url: "https://x", commitCount: 3)
    let subs = WorkflowLaunchComposer.substitutions(for: inputs)
    #expect(subs["note"] == "be careful")
    #expect(subs["url"] == "https://x")
    #expect(subs["commits"] == "3")
  }

  @Test func promptRendersWorkflowTemplate() {
    let workflow = WorkflowDefinition(name: "T", category: .ship, promptTemplate: "fix {{url}} {{context}}")
    let inputs = WorkflowLaunchComposer.Inputs(selectors: [.currentDiff], url: "https://ci")
    let prompt = WorkflowLaunchComposer.prompt(for: workflow, inputs: inputs)
    #expect(prompt == "fix https://ci Use the current diff as context.")
  }

  @Test func shellQuotingWrapsAndEscapes() {
    #expect(ProjectCommandCenterFeature.shellQuoted("plain") == "'plain'")
    #expect(ProjectCommandCenterFeature.shellQuoted("it's") == #"'it'\''s'"#)
  }
}
