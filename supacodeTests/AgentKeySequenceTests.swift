import Testing

@testable import supacode

/// Pure key-name → PTY-byte mapping behind `supacode agent send-keys`.
struct AgentKeySequenceTests {
  @Test(
    arguments: [
      ("enter", "\r"),
      ("return", "\r"),
      ("esc", "\u{1b}"),
      ("escape", "\u{1b}"),
      ("tab", "\t"),
      ("space", " "),
      ("backspace", "\u{7f}"),
      ("up", "\u{1b}[A"),
      ("down", "\u{1b}[B"),
      ("right", "\u{1b}[C"),
      ("left", "\u{1b}[D"),
      ("home", "\u{1b}[H"),
      ("end", "\u{1b}[F"),
      ("pageup", "\u{1b}[5~"),
      ("pagedown", "\u{1b}[6~"),
    ]
  )
  func namedKeysMapToTheirSequences(name: String, expected: String) {
    #expect(AgentKeySequence.sequence(for: name) == expected)
    // Case-insensitive so `ESC` from a shell script still works.
    #expect(AgentKeySequence.sequence(for: name.uppercased()) == expected)
  }

  @Test(
    arguments: [
      ("ctrl+c", "\u{03}"),
      ("ctrl-c", "\u{03}"),
      ("CTRL+C", "\u{03}"),
      ("ctrl+a", "\u{01}"),
      ("ctrl+z", "\u{1a}"),
    ]
  )
  func controlKeysMapToControlCodes(name: String, expected: String) {
    #expect(AgentKeySequence.sequence(for: name) == expected)
  }

  @Test(arguments: ["", "ctrl", "ctrl+", "ctrl+1", "ctrl++", "ctrl+ab", "meta+c", "f1", "enter "])
  func unsupportedNamesReturnNil(name: String) {
    #expect(AgentKeySequence.sequence(for: name) == nil)
  }

  @Test func batchMappingStopsAtTheFirstUnknownName() {
    let mapped = AgentKeySequence.sequences(for: ["esc", "nope", "enter"])

    #expect(mapped.unknownName == "nope")
    // The prefix is returned but the caller must discard it: a half-driven
    // agent is worse than a rejected command.
    #expect(mapped.sequences == ["\u{1b}"])
  }

  @Test func batchMappingReturnsEverySequenceInOrder() {
    let mapped = AgentKeySequence.sequences(for: ["esc", "ctrl+c", "enter"])

    #expect(mapped.unknownName == nil)
    #expect(mapped.sequences == ["\u{1b}", "\u{03}", "\r"])
  }

  @Test func helpRosterListsTheControlForm() {
    #expect(AgentKeySequence.names.contains("ctrl+<letter>"))
    #expect(AgentKeySequence.names.contains("enter"))
  }
}
