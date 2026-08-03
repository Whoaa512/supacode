import Testing

@testable import supacode

/// Screen-text shaping behind `supacode agent read` / `terminal wait-output`.
struct AgentReadQueryResponseTests {
  @Test func tailKeepsTheLastRequestedLines() {
    let screen = (1...10).map { "line \($0)" }.joined(separator: "\n")

    #expect(AgentReadQueryResponse.tail(of: screen, lines: 3) == "line 8\nline 9\nline 10")
  }

  @Test func tailDropsTrailingBlankLines() {
    // A mostly-empty pane is padded to the window height; returning that padding
    // would make every read look like a wall of newlines.
    let screen = "prompt>\n   \n\n\n"

    #expect(AgentReadQueryResponse.tail(of: screen, lines: 80) == "prompt>")
  }

  @Test func tailKeepsBlankLinesInsideTheOutput() {
    let screen = "first\n\nlast\n\n"

    #expect(AgentReadQueryResponse.tail(of: screen, lines: 80) == "first\n\nlast")
  }

  @Test func tailOfAShorterScreenReturnsEverything() {
    #expect(AgentReadQueryResponse.tail(of: "only", lines: 80) == "only")
    #expect(AgentReadQueryResponse.tail(of: "", lines: 80) == "")
  }

  @Test(arguments: [nil, "", "0", "-4", "nope"])
  func lineCountFallsBackToTheDefault(raw: String?) {
    #expect(AgentReadQueryResponse.lineCount(raw) == AgentReadQueryResponse.defaultLines)
  }

  @Test func lineCountIsClampedToTheScrollbackCeiling() {
    #expect(AgentReadQueryResponse.lineCount("25") == 25)
    #expect(AgentReadQueryResponse.lineCount("999999") == 10_000)
  }

  @Test func rowsCarryTheTailUnderTheTextKey() {
    let rows = AgentReadQueryResponse.rows(screen: "a\nb\nc\n", lines: 2)

    #expect(rows == [[AgentReadQueryResponse.textKey: "b\nc"]])
  }
}
