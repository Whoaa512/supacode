import Foundation

/// Key names `supacode agent send-keys` accepts, and the bytes each one writes
/// to the PTY.
///
/// Raw escape sequences rather than synthetic `ghostty_surface_key` events: the
/// key path would need a full keycode + modifier translation table (and an
/// AppKit event) to produce exactly these bytes, which is what the agent TUI
/// reads anyway.
///
/// `supacode-cli` mirrors this roster in `AgentCommand.KeyNames` for
/// client-side validation; keep both sides in sync (the CLI links no shared
/// module to stay dependency-light).
nonisolated enum AgentKeySequence {
  /// Named keys. Aliases are spelled out so `esc` and `escape` both work
  /// without a normalization pass at the call site.
  private static let table: [String: String] = [
    "enter": "\r",
    "return": "\r",
    "esc": "\u{1b}",
    "escape": "\u{1b}",
    "tab": "\t",
    "backspace": "\u{7f}",
    "space": " ",
    "up": "\u{1b}[A",
    "down": "\u{1b}[B",
    "right": "\u{1b}[C",
    "left": "\u{1b}[D",
    "home": "\u{1b}[H",
    "end": "\u{1b}[F",
    "pageup": "\u{1b}[5~",
    "pagedown": "\u{1b}[6~",
  ]

  /// Help-text roster: every named key, then the control-key form.
  static let names = table.keys.sorted() + ["ctrl+<letter>"]

  /// The bytes for one key name, or `nil` when the name isn't supported.
  /// Case-insensitive; `ctrl+c` and `ctrl-c` are both accepted.
  static func sequence(for rawName: String) -> String? {
    let name = rawName.lowercased()
    if let named = table[name] { return named }
    return controlSequence(for: name)
  }

  /// Maps every key name in order, stopping at the first unknown one so the
  /// caller can name it before anything reaches the PTY.
  static func sequences(for names: [String]) -> (sequences: [String], unknownName: String?) {
    var sequences: [String] = []
    for name in names {
      guard let sequence = sequence(for: name) else { return (sequences, name) }
      sequences.append(sequence)
    }
    return (sequences, nil)
  }

  /// `ctrl+c` → 0x03. Only ASCII letters map: `ctrl+1` has no single-byte
  /// control code, so it is rejected rather than silently sent as `1`.
  private static func controlSequence(for name: String) -> String? {
    guard name.count == 6, name.hasPrefix("ctrl") else { return nil }
    let separator = name[name.index(name.startIndex, offsetBy: 4)]
    guard separator == "+" || separator == "-" else { return nil }
    guard let letter = name.last, letter.isASCII, letter.isLetter,
      let ascii = letter.asciiValue
    else { return nil }
    // Lowercased above, so 'a' (97) maps to 0x01.
    guard let scalar = Unicode.Scalar(UInt32(ascii - 96)) else { return nil }
    return String(Character(scalar))
  }
}
