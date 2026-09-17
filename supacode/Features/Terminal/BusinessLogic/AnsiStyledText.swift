import SwiftUI

enum AnsiStyledText {
  static func attributedString(from text: String) -> AttributedString {
    var result = AttributedString()
    var run = String.UnicodeScalarView()
    var foreground: Color?
    var background: Color?
    var isBold = false

    func flushRun() {
      guard !run.isEmpty else { return }
      var piece = AttributedString(String(run))
      piece.foregroundColor = foreground
      piece.backgroundColor = background
      result += piece
      run = String.UnicodeScalarView()
    }

    var scalars = text.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      guard scalar == "\u{1b}" else {
        run.append(scalar)
        continue
      }
      guard scalars.next() == "[" else { continue }
      var body = ""
      while let byte = scalars.next() {
        if byte.value >= 0x40, byte.value <= 0x7E { break }
        body.unicodeScalars.append(byte)
      }
      flushRun()
      apply(
        parameters: body.split(separator: ";", omittingEmptySubsequences: false)
          .map { Int($0) ?? 0 },
        foreground: &foreground,
        background: &background,
        isBold: &isBold
      )
    }
    flushRun()
    return result
  }

  private static func apply(
    parameters: [Int],
    foreground: inout Color?,
    background: inout Color?,
    isBold: inout Bool
  ) {
    var index = 0
    while index < parameters.count {
      let code = parameters[index]
      switch code {
      case 0:
        foreground = nil
        background = nil
        isBold = false
      case 1: isBold = true
      case 22: isBold = false
      case 30...37: foreground = basicColor(code - 30, bright: isBold)
      case 39: foreground = nil
      case 40...47: background = basicColor(code - 40, bright: false)
      case 49: background = nil
      case 90...97: foreground = basicColor(code - 90, bright: true)
      case 100...107: background = basicColor(code - 100, bright: true)
      case 38, 48:
        let (color, consumed) = extendedColor(parameters, at: index)
        if code == 38 { foreground = color } else { background = color }
        index += consumed
      default: break
      }
      index += 1
    }
  }

  private static func extendedColor(_ parameters: [Int], at index: Int) -> (Color?, Int) {
    guard index + 1 < parameters.count else { return (nil, 0) }
    switch parameters[index + 1] {
    case 5 where index + 2 < parameters.count:
      return (palette256(parameters[index + 2]), 2)
    case 2 where index + 4 < parameters.count:
      return (rgb(parameters[index + 2], parameters[index + 3], parameters[index + 4]), 4)
    default:
      return (nil, 1)
    }
  }

  private static func palette256(_ index: Int) -> Color? {
    switch index {
    case 0...7: basicColor(index, bright: false)
    case 8...15: basicColor(index - 8, bright: true)
    case 16...231:
      rgb(
        [0, 95, 135, 175, 215, 255][(index - 16) / 36],
        [0, 95, 135, 175, 215, 255][((index - 16) / 6) % 6],
        [0, 95, 135, 175, 215, 255][(index - 16) % 6]
      )
    case 232...255:
      rgb(8 + (index - 232) * 10, 8 + (index - 232) * 10, 8 + (index - 232) * 10)
    default: nil
    }
  }

  private static let normalPalette = [
    0x000000, 0xCC4444, 0x44BB44, 0xBBBB44,
    0x4477DD, 0xBB44BB, 0x44BBBB, 0xCCCCCC,
  ]
  private static let brightPalette = [
    0x666666, 0xFF6666, 0x66FF66, 0xFFFF66,
    0x6699FF, 0xFF66FF, 0x66FFFF, 0xFFFFFF,
  ]

  private static func basicColor(_ index: Int, bright: Bool) -> Color? {
    guard (0...7).contains(index) else { return nil }
    let packed = bright ? brightPalette[index] : normalPalette[index]
    return rgb((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF)
  }

  private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
    Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
  }
}
