import Foundation
import Testing

@testable import SupacodeSettingsShared

struct KimiHookSettingsTests {
  @Test func canonicalEntriesCoverCoreEvents() {
    let entries = KimiHookSettings.canonicalEntries()
    let events = entries.map(\.event)
    #expect(events.contains("SessionStart"))
    #expect(events.contains("UserPromptSubmit"))
    #expect(events.contains("PreToolUse"))
    #expect(events.contains("PostToolUse"))
    #expect(events.contains("Notification"))
    #expect(events.contains("Stop"))
    #expect(events.contains("SessionEnd"))
  }

  @Test func canonicalEntriesCarryMatcherForAwaitingInputSlot() {
    let entries = KimiHookSettings.canonicalEntries()
    let preToolUse = entries.filter { $0.event == "PreToolUse" }
    #expect(preToolUse.count == 3)
    #expect(preToolUse.first?.matcher == "")
    let matchers = preToolUse.dropFirst().map(\.matcher)
    #expect(matchers.sorted() == ["AskUserQuestion", "ExitPlanMode"])
  }

  @Test func onlyAskUserQuestionCarriesTheQuestionQualifier() {
    let preToolUse = KimiHookSettings.canonicalEntries().filter { $0.event == "PreToolUse" }
    for entry in preToolUse {
      let expectsQuestion = entry.matcher == "AskUserQuestion"
      #expect(entry.command.contains("event=awaiting_input;prompt=question") == expectsQuestion)
    }
  }

  @Test func everyCommandCarriesOwnershipSentinel() {
    let entries = KimiHookSettings.canonicalEntries()
    #expect(entries.allSatisfy { $0.command.contains(AgentHookSettingsCommand.ownershipMarker) })
  }

  @Test func everyCommandTargetsKimiAgent() {
    let entries = KimiHookSettings.canonicalEntries()
    #expect(entries.allSatisfy { $0.command.contains("start=kimi;") })
  }

  @Test func timeoutsArePositive() {
    let entries = KimiHookSettings.canonicalEntries()
    #expect(entries.allSatisfy { $0.timeout > 0 })
  }
}
