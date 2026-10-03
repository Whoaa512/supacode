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
    #expect(duplicates["⌘⇧N"] == nil)
    #expect(duplicates["⌘⇧⌥N"] == nil)
  }
}
