import Foundation
import Testing

@testable import supacode

struct ClipboardPreselectionTests {
  @Test func buildkiteURLReturnsFIxCI() {
    let hint = ClipboardPreselection.hint(from: "https://buildkite.com/airbnb/some-pipeline/builds/12345")
    #expect(hint == .fixCI)
  }

  @Test func slackURLReturnsInvestigate() {
    let hint = ClipboardPreselection.hint(from: "https://app.slack.com/client/T123/C456/thread/C456-1234567890.123456")
    #expect(hint == .investigate)
  }

  @Test func googleDocsURLReturnsInvestigate() {
    let hint = ClipboardPreselection.hint(from: "https://docs.google.com/document/d/1abc123def456/edit")
    #expect(hint == .investigate)
  }

  @Test func githubPRURLReturnsShipCheck() {
    let hint = ClipboardPreselection.hint(from: "https://github.com/org/repo/pull/42")
    #expect(hint == .shipCheck)
  }

  @Test func githubNonPRURLReturnsInvestigate() {
    let hint = ClipboardPreselection.hint(from: "https://github.com/org/repo/issues/10")
    #expect(hint == .investigate)
  }

  @Test func plainTextReturnsNil() {
    let hint = ClipboardPreselection.hint(from: "just some random text")
    #expect(hint == nil)
  }

  @Test func emptyStringReturnsNil() {
    let hint = ClipboardPreselection.hint(from: "")
    #expect(hint == nil)
  }

  @Test func whitespaceWrappedURLWorks() {
    let hint = ClipboardPreselection.hint(from: "  https://buildkite.com/org/pipe/builds/1  \n")
    #expect(hint == .fixCI)
  }
}
