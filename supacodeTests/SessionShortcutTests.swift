import Testing

@testable import SupacodeSettingsShared

@Suite
struct SessionShortcutTests {
  @Test func newSessionDefaultChordsAreRegisteredAndUnique() {
    #expect(AppShortcuts.newSession.display == "⌘⇧N")
    #expect(AppShortcuts.newSessionInDirectory.display == "⌘⇧⌥N")
    #expect(AppShortcuts.all.contains { $0.id == .newSession })
    #expect(AppShortcuts.all.contains { $0.id == .newSessionInDirectory })

    let duplicates = Dictionary(grouping: AppShortcuts.all.filter(\.isEnabledByDefault), by: \.display)
      .filter { $0.value.count > 1 }
      .mapValues { $0.map(\.id.displayName) }
    #expect(duplicates.isEmpty)
  }

  @Test func newSessionChordsReleaseGhosttyAndAvoidKnownGhosttyDefaults() {
    let ghosttyDefaults = Set([
      "super+n", "super+t", "super+w", "super+shift+w", "super+q",
      "super+comma", "super+enter", "super+shift+comma", "super+shift+j",
      "super+shift+k", "super+shift+left", "super+shift+right", "super+shift+up",
      "super+shift+down", "super+shift+open_bracket", "super+shift+close_bracket",
    ])

    #expect(AppShortcuts.newSession.ghosttyKeybind == "shift+super+n")
    #expect(AppShortcuts.newSessionInDirectory.ghosttyKeybind == "alt+shift+super+n")
    #expect(AppShortcuts.newSession.ghosttyUnbindConfigLine == "keybind = shift+super+n=unbind")
    #expect(AppShortcuts.newSessionInDirectory.ghosttyUnbindConfigLine == "keybind = alt+shift+super+n=unbind")
    #expect(!ghosttyDefaults.contains(AppShortcuts.newSession.ghosttyKeybind))
    #expect(!ghosttyDefaults.contains(AppShortcuts.newSessionInDirectory.ghosttyKeybind))
  }

  @Test func settleAndUnsettleDefaultChordsAreRegisteredAndUnique() {
    #expect(AppShortcuts.settleSessionAndAdvance.display == "⌘⌃E")
    #expect(AppShortcuts.unsettleSession.display == "⌘⌃U")
    #expect(AppShortcuts.nextSessionNeedsMe.display == "⌘⌃N")
    #expect(AppShortcuts.all.contains { $0.id == .settleSessionAndAdvance })
    #expect(AppShortcuts.all.contains { $0.id == .unsettleSession })
    #expect(AppShortcuts.all.contains { $0.id == .nextSessionNeedsMe })

    let duplicates = Dictionary(grouping: AppShortcuts.all.filter(\.isEnabledByDefault), by: \.display)
      .filter { $0.value.count > 1 }
      .mapValues { $0.map(\.id.displayName) }
    #expect(duplicates.isEmpty)
  }

  @Test func settleAndUnsettleGhosttyKeybinds() {
    let knownGhosttyDefaults = Set([
      "super+n", "super+t", "super+w", "super+shift+w", "super+q",
      "super+comma", "super+enter", "super+shift+comma", "super+shift+j",
      "super+shift+k", "super+shift+left", "super+shift+right", "super+shift+up",
      "super+shift+down", "super+shift+open_bracket", "super+shift+close_bracket",
    ])
    #expect(AppShortcuts.settleSessionAndAdvance.ghosttyKeybind == "ctrl+super+e")
    #expect(AppShortcuts.unsettleSession.ghosttyKeybind == "ctrl+super+u")
    #expect(AppShortcuts.nextSessionNeedsMe.ghosttyKeybind == "ctrl+super+n")
    #expect(!knownGhosttyDefaults.contains(AppShortcuts.settleSessionAndAdvance.ghosttyKeybind))
    #expect(!knownGhosttyDefaults.contains(AppShortcuts.unsettleSession.ghosttyKeybind))
    #expect(!knownGhosttyDefaults.contains(AppShortcuts.nextSessionNeedsMe.ghosttyKeybind))
  }
}
