import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct WorktreeTerminalManagerSessionsTests {
  @Test func terminalContentSuppressesHarnessEndAcrossTeardownAndStart() throws {
    let runtime = GhosttyRuntime(surfaceTeardownQueue: TeardownTestSupport.queue(probe: TeardownProbeSpy()))
    let content = TeardownTestSupport.content(runtime: runtime)
    var suppressed: [UUID] = []
    var allowed: [UUID] = []
    content.onWillTearDown = { suppressed.append($0) }
    content.onDidStart = { allowed.append($0) }

    content.startSession(at: .fallback)
    content.hibernate()

    #expect(allowed == [content.id.rawValue])
    #expect(suppressed == [content.id.rawValue])
  }

  @Test func unexpectedZmxPathsAreNotExplicitUserCloses() {
    #expect(
      LayoutSurfaceConduit.shouldProbeUnexpectedZmxClose(
        isExplicit: false,
        processAlive: false,
        isHibernatable: true
      )
    )
    #expect(
      !LayoutSurfaceConduit.shouldProbeUnexpectedZmxClose(
        isExplicit: true,
        processAlive: false,
        isHibernatable: true
      )
    )
    #expect(
      !LayoutSurfaceConduit.shouldProbeUnexpectedZmxClose(
        isExplicit: false,
        processAlive: true,
        isHibernatable: true
      )
    )
  }
}
