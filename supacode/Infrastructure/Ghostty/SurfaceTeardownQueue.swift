import Foundation
import SupacodeSettingsShared

/// Off-main command runner the teardown path needs: one closure, so tests get a
/// double without standing up all of `ShellClient`. Returns stdout, or nil when
/// the command failed to run or exited non-zero (`pgrep` exits 1 on no match).
nonisolated struct SurfaceTeardownShell: Sendable {
  var run: @Sendable (URL, [String]) async -> String?

  static func live(_ shell: ShellClient) -> SurfaceTeardownShell {
    SurfaceTeardownShell { executable, arguments in
      try? await shell.run(executable, arguments, nil).stdout
    }
  }
}

/// Owns ghostty surfaces whose teardown has been deferred off the main-actor
/// critical path.
///
/// `ghostty_surface_free` joins the surface's io thread, so a wedged pty reader
/// freezes the whole app whenever the free runs inline (hibernation, tab close).
/// Handing a view here transfers OWNERSHIP: the queue holds the last strong
/// reference, which is what makes the free deferred — `GhosttySurfaceView` has an
/// `isolated deinit` that frees inline, so merely dropping the caller's reference
/// would still block the main actor.
///
/// The resolve policy (kill the zmx attach client, gate on
/// `ghostty_surface_process_exited`, bounded poll, leak-over-hang) lands in a
/// later slice; for now a handed-off surface stays pending forever.
@MainActor
final class SurfaceTeardownQueue {
  /// Keyed by VIEW identity, not surface UUID: a dormant tab reuses its surface
  /// UUIDs on wake, so a UUID-keyed map would treat the woken generation as
  /// already pending, skip the hand-off, and let its free run inline again.
  private var pending: [ObjectIdentifier: GhosttySurfaceView] = [:]
  /// One Task per pending view (binding 13: no central driver loop). Retained so
  /// callers can observe completion and so quit can abandon them.
  private var teardownTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private let shell: SurfaceTeardownShell
  private nonisolated static let logger = SupaLogger("SurfaceTeardown")

  init(shell: SurfaceTeardownShell) {
    self.shell = shell
  }

  /// Number of `handOff(_:)` calls seen. Distinct from `pendingCount` so a view
  /// handed off twice is observable.
  private(set) var handOffCount = 0

  var pendingSurfaceIDs: Set<UUID> { Set(pending.values.map(\.id)) }

  var pendingCount: Int { pending.count }

  func teardownTask(for view: GhosttySurfaceView) -> Task<Void, Never>? {
    teardownTasks[ObjectIdentifier(view)]
  }

  /// Takes ownership of `view`'s surface teardown and returns without touching
  /// ghostty, so the caller's turn on the main actor never waits on a free.
  func handOff(_ view: GhosttySurfaceView) {
    handOffCount += 1
    let key = ObjectIdentifier(view)
    guard pending[key] == nil else { return }
    pending[key] = view
    view.prepareForDeferredTeardown()
    let sessionID = ZmxSessionID.make(surfaceID: view.id)
    let shell = shell
    teardownTasks[key] = Task {
      await Self.killAttachClient(sessionID: sessionID, shell: shell)
    }
  }

  /// Kills the surface's `zmx attach` CLIENT (never the session, which must
  /// survive to be re-attached on wake) so the wedged pty io-reader gets EOF.
  ///
  /// Exactly ONE kill, at hand-off (binding 8): the `-f` pattern also matches any
  /// FUTURE client of the same session, so re-killing later would murder a
  /// freshly woken terminal. PID-targeted when `pgrep` finds the client, with a
  /// single pattern `pkill` as the fallback for the race where it doesn't.
  private nonisolated static func killAttachClient(
    sessionID: String,
    shell: SurfaceTeardownShell
  ) async {
    let pattern = "zmx attach \(sessionID)"
    let stdout = await shell.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", pattern])
    let pids = Self.parsePIDs(stdout ?? "")
    guard pids.isEmpty else {
      _ = await shell.run(URL(fileURLWithPath: "/bin/kill"), ["-TERM"] + pids)
      return
    }
    logger.warning("no zmx attach client found for \(sessionID); falling back to pkill")
    _ = await shell.run(URL(fileURLWithPath: "/usr/bin/pkill"), ["-f", pattern])
  }

  private nonisolated static func parsePIDs(_ stdout: String) -> [String] {
    stdout
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { Int32($0) != nil }
  }
}
