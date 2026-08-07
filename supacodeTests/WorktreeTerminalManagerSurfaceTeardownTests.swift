import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
import Testing

@testable import supacode

/// Records every command the teardown queue runs, and lets a test decide what
/// `pgrep` reports so both the PID path and the no-match fallback are pinned.
private actor ShellSpy {
  private let pgrepStdout: String?
  private(set) var commands: [[String]] = []

  init(pgrepStdout: String? = nil) {
    self.pgrepStdout = pgrepStdout
  }

  func run(_ command: [String]) -> String? {
    commands.append(command)
    guard command.first == "pgrep" else { return "" }
    return pgrepStdout
  }

  var killCommands: [[String]] {
    commands.filter { $0.first == "kill" || $0.first == "pkill" }
  }
}

/// Pins `SurfaceTeardownQueue`'s bookkeeping. Surface UUIDs are REUSED when a
/// dormant tab wakes, so the queue must track view identity, not surface identity:
/// a UUID-keyed queue would treat the woken generation as already pending, skip the
/// hand-off, and let the free run inline again (the deadlock this whole change
/// exists to remove).
@MainActor
@Suite(.serialized, .dependencies)
struct SurfaceTeardownQueueTests {
  private func makeView(id: UUID, runtime: GhosttyRuntime) -> GhosttySurfaceView {
    GhosttySurfaceView(
      id: id,
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
  }

  private func makeQueue(_ spy: ShellSpy) -> SurfaceTeardownQueue {
    SurfaceTeardownQueue(
      shell: SurfaceTeardownShell { executable, arguments in
        await spy.run([executable.lastPathComponent] + arguments)
      }
    )
  }

  @Test func handOffTracksEachViewGenerationOfAReusedSurfaceID() {
    let runtime = GhosttyRuntime()
    let queue = makeQueue(ShellSpy())
    let surfaceID = UUID()
    let firstGeneration = makeView(id: surfaceID, runtime: runtime)
    let secondGeneration = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(firstGeneration)
    queue.handOff(secondGeneration)

    // Both views own a live ghostty surface, so both must be pending.
    #expect(queue.pendingCount == 2)
    #expect(queue.pendingSurfaceIDs == [surfaceID])
  }

  @Test func handOffIsIdempotentForTheSameView() {
    let runtime = GhosttyRuntime()
    let queue = makeQueue(ShellSpy())
    let view = makeView(id: UUID(), runtime: runtime)

    queue.handOff(view)
    queue.handOff(view)

    #expect(queue.pendingCount == 1)
  }

  /// `passwordInput` scopes SecureInput app-wide; a pending surface that keeps it
  /// set would leave secure event input enabled for every other terminal.
  @Test func handOffClearsPasswordInput() {
    let runtime = GhosttyRuntime()
    let view = makeView(id: UUID(), runtime: runtime)
    view.passwordInput = true

    makeQueue(ShellSpy()).handOff(view)

    #expect(view.passwordInput == false)
  }

  /// The local monitor sees every key event in the app, so a pending view that
  /// kept one would keep swallowing Cmd-keyUp for the surfaces still in the tree.
  @Test func handOffRemovesTheLocalEventMonitor() {
    let runtime = GhosttyRuntime()
    let view = makeView(id: UUID(), runtime: runtime)
    #expect(view.hasLocalEventMonitor)

    makeQueue(ShellSpy()).handOff(view)

    #expect(view.hasLocalEventMonitor == false)
  }

  /// The wedged pty io thread only gets EOF once its `zmx attach` CLIENT dies, so
  /// the kill must happen at hand-off. PID-targeted, because the `-f` pattern also
  /// matches any FUTURE client of the same (surviving) session.
  @Test func handOffKillsTheAttachClientByPID() async {
    let runtime = GhosttyRuntime()
    let spy = ShellSpy(pgrepStdout: "4242\n")
    let queue = makeQueue(spy)
    let surfaceID = UUID()
    let view = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(view)
    await queue.teardownTask(for: view)?.value

    let pattern = "zmx attach \(ZmxSessionID.make(surfaceID: surfaceID))"
    #expect(await spy.commands == [["pgrep", "-f", pattern], ["kill", "-TERM", "4242"]])
  }

  @Test func handOffFallsBackToASinglePkillWhenNoClientIsFound() async {
    let runtime = GhosttyRuntime()
    let spy = ShellSpy(pgrepStdout: nil)
    let queue = makeQueue(spy)
    let surfaceID = UUID()
    let view = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(view)
    await queue.teardownTask(for: view)?.value

    let pattern = "zmx attach \(ZmxSessionID.make(surfaceID: surfaceID))"
    #expect(await spy.killCommands == [["pkill", "-f", pattern]])
  }

  /// A woken surface reuses its UUID, so its NEW attach client is a different
  /// process and must be killed on ITS hand-off. (Re-killing the SAME hand-off
  /// later is what murders a freshly woken terminal — that's binding 8.)
  @Test func eachHandOffOfAReusedSurfaceIDKillsItsOwnClient() async {
    let runtime = GhosttyRuntime()
    let spy = ShellSpy(pgrepStdout: "4242\n")
    let queue = makeQueue(spy)
    let surfaceID = UUID()
    let firstGeneration = makeView(id: surfaceID, runtime: runtime)
    let secondGeneration = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(firstGeneration)
    await queue.teardownTask(for: firstGeneration)?.value
    queue.handOff(secondGeneration)
    await queue.teardownTask(for: secondGeneration)?.value

    #expect(await spy.killCommands.count == 2)
  }

  /// A surface still in the tree must never lose its client.
  @Test func noCommandsRunWithoutAHandOff() async {
    let runtime = GhosttyRuntime()
    let spy = ShellSpy()
    let queue = makeQueue(spy)
    _ = makeView(id: UUID(), runtime: runtime)
    _ = queue

    #expect(await spy.commands.isEmpty)
  }
}
