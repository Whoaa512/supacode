import Foundation
import Testing

@testable import supacode

struct AnsiStyledTextTests {
  @Test func colorsRunsAndResets() {
    let styled = AnsiStyledText.attributedString(
      from: "plain \u{1b}[32mgreen\u{1b}[0m \u{1b}[38;5;196mred256\u{1b}[39m tail")
    let runs = styled.runs.map {
      (String(styled[$0.range].characters), $0.foregroundColor != nil)
    }

    #expect(String(styled.characters) == "plain green red256 tail")
    #expect(runs.map(\.1) == [false, true, false, true, false])
  }

  @Test func supportsTrueColorAndBackground() {
    let styled = AnsiStyledText.attributedString(
      from: "\u{1b}[38;2;1;2;3mfg\u{1b}[48;5;42mboth\u{1b}[0mplain")
    let runs = Array(styled.runs)

    #expect(String(styled.characters) == "fgbothplain")
    #expect(runs.count == 3)
    #expect(runs[0].foregroundColor != nil)
    #expect(runs[1].foregroundColor != nil)
    #expect(runs[1].backgroundColor != nil)
    #expect(runs[2].foregroundColor == nil)
    #expect(runs[2].backgroundColor == nil)
  }
}
