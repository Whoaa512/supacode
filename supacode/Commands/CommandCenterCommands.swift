import Sharing
import SupacodeSettingsShared
import SwiftUI

struct CommandCenterCommands: Commands {
  @FocusedValue(\.toggleCommandCenterAction) private var toggleCommandCenterAction
  @Shared(.settingsFile) private var settingsFile

  var body: some Commands {
    let overrides = settingsFile.global.shortcutOverrides
    let toggleCommandCenter = AppShortcuts.toggleCommandCenter.effective(from: overrides)
    CommandGroup(after: .toolbar) {
      Button("Toggle Command Center", systemImage: "square.split.2x1") {
        toggleCommandCenterAction?()
      }
      .appKeyboardShortcut(toggleCommandCenter)
      .help("Toggle Command Center (\(toggleCommandCenter?.display ?? "none"))")
      .disabled(toggleCommandCenterAction?.isEnabled != true)
    }
  }
}
