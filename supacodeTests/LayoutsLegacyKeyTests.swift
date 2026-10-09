import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

/// Golden v2 blob, keyed by worktree path. Must hydrate unchanged once layouts are task-owned.
@MainActor
struct LayoutsLegacyKeyTests {
  private static let blob = """
    {"schemaVersion":2,"worktrees":{
    "/tmp/repo/wt-a":{"layout":{"focusedPaneID":"00000000-0000-0000-0000-0000000000A1",
    "panes":[{"id":"00000000-0000-0000-0000-0000000000A1","selectedTabID":"00000000-0000-0000-0000-0000000000B1",
    "tabs":[{"content":{"id":"00000000-0000-0000-0000-0000000000C1","state":{"kind":"terminal","terminal":{}}},
    "id":"00000000-0000-0000-0000-0000000000B1","title":"One"}]}],
    "tree":{"root":{"kind":"leaf","leaf":"00000000-0000-0000-0000-0000000000A1"}}}},
    "/tmp/repo/wt-b":{"layout":{"focusedPaneID":"00000000-0000-0000-0000-0000000000A2",
    "panes":[{"id":"00000000-0000-0000-0000-0000000000A2","selectedTabID":"00000000-0000-0000-0000-0000000000B2",
    "tabs":[{"content":{"id":"00000000-0000-0000-0000-0000000000C2","state":{"kind":"terminal","terminal":{}}},
    "id":"00000000-0000-0000-0000-0000000000B2","title":"Two"}]}],
    "tree":{"root":{"kind":"leaf","leaf":"00000000-0000-0000-0000-0000000000A2"}}}}}}
    """

  private static func uuid(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")!
  }

  @Test func legacyV2BlobHydratesToExpectedIDs() throws {
    let file = try JSONDecoder().decode(LayoutsFile.self, from: Data(Self.blob.utf8))
    var state = TerminalsFeature.State()
    _ = TerminalsFeature().reduce(into: &state, action: .layoutsHydrated(TaskLayoutsFile(oneTaskPerDirectory: file)))

    let expected = ["/tmp/repo/wt-a": "1", "/tmp/repo/wt-b": "2"]
    #expect(state.layouts.ids.map(\.persistenceKey).sorted() == expected.keys.sorted())
    for (key, suffix) in expected {
      let layout = try #require(state.layouts[id: LayoutID(legacyWorktreeKey: key)]?.layout)
      #expect(layout.panes.map(\.id.rawValue) == [Self.uuid("A" + suffix)])
      #expect(layout.panes.flatMap(\.tabs.ids).map(\.rawValue) == [Self.uuid("B" + suffix)])
      #expect(layout.allContentIDs.map(\.rawValue) == [Self.uuid("C" + suffix)])
    }
  }

  @Test func persistenceKeyRoundTripsTheLegacyKey() {
    let key = "/tmp/repo/wt-a"
    #expect(LayoutID(legacyWorktreeKey: key).persistenceKey == key)
  }
}
