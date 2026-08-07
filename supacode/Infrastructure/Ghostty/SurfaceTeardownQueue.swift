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
/// Resolve policy per surface: kill the zmx attach client once, then poll
/// `ghostty_surface_process_exited` on an injected clock with a bounded number of
/// attempts, and free only once the child is gone.
@MainActor
final class SurfaceTeardownQueue {
  /// Per-surface state machine (binding 13). One Task drives one surface through
  /// it; there is no central driver loop.
  enum Stage: Equatable {
    case killRequested
    case awaitingExit(attempt: Int)
    case freed
    case leaked
  }

  private struct Entry {
    let view: GhosttySurfaceView
    var stage: Stage
  }

  /// Keyed by VIEW identity, not surface UUID: a dormant tab reuses its surface
  /// UUIDs on wake, so a UUID-keyed map would treat the woken generation as
  /// already pending, skip the hand-off, and let its free run inline again.
  private var pending: [ObjectIdentifier: Entry] = [:]
  /// One Task per pending view (binding 13: no central driver loop). Retained so
  /// callers can observe completion and so quit can abandon them.
  private var teardownTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private let shell: SurfaceTeardownShell
  private let clock: any Clock<Duration>
  private let analytics: AnalyticsClient
  private let hasProcessExited: (GhosttySurfaceView) -> Bool
  private let free: (GhosttySurfaceView) -> Void
  private nonisolated static let logger = SupaLogger("SurfaceTeardown")
  /// Deliberately leaked surfaces, kept RETAINED (binding 6): ghostty holds the
  /// bridge as userdata with no liveness registry, so dropping a view whose surface
  /// is still alive is a use-after-free on the next callback. Retention is
  /// therefore not optional — the cap below only escalates logging.
  private var leaked: [GhosttySurfaceView] = []
  /// Past this many leaks something systemic is wrong (a wedged pty is rare; 32 of
  /// them means every hibernate is wedging), so the log switches to `error`. The
  /// views are still retained.
  private static let leakedWarningCap = 32

  /// How long the child gets to die after the SIGTERM before the surface is
  /// abandoned: 40 * 50ms = 2s. Long enough for a normal `zmx attach` teardown,
  /// short enough that a truly wedged pty doesn't pile up pending surfaces.
  private static let exitPollInterval: Duration = .milliseconds(50)
  private static let maxExitPollAttempts = 40

  init(
    shell: SurfaceTeardownShell,
    clock: any Clock<Duration> = ContinuousClock(),
    analytics: AnalyticsClient,
    hasProcessExited: @escaping (GhosttySurfaceView) -> Bool = { $0.hasSurfaceProcessExited },
    free: @escaping (GhosttySurfaceView) -> Void = { $0.performDeferredFree() }
  ) {
    self.shell = shell
    self.clock = clock
    self.analytics = analytics
    self.hasProcessExited = hasProcessExited
    self.free = free
  }

  /// Number of `handOff(_:)` calls seen. Distinct from `pendingCount` so a view
  /// handed off twice is observable.
  private(set) var handOffCount = 0

  var pendingSurfaceIDs: Set<UUID> { Set(pending.values.map(\.view.id)) }

  var pendingCount: Int { pending.count }

  var leakedCount: Int { leaked.count }

  func teardownTask(for view: GhosttySurfaceView) -> Task<Void, Never>? {
    teardownTasks[ObjectIdentifier(view)]
  }

  func stage(for view: GhosttySurfaceView) -> Stage? {
    pending[ObjectIdentifier(view)]?.stage
  }

  /// Takes ownership of `view`'s surface teardown and returns without touching
  /// ghostty, so the caller's turn on the main actor never waits on a free.
  func handOff(_ view: GhosttySurfaceView) {
    handOffCount += 1
    let key = ObjectIdentifier(view)
    guard pending[key] == nil else { return }
    pending[key] = Entry(view: view, stage: .killRequested)
    view.prepareForDeferredTeardown()
    let sessionID = ZmxSessionID.make(surfaceID: view.id)
    let shell = shell
    teardownTasks[key] = Task { [weak self] in
      await Self.killAttachClient(sessionID: sessionID, shell: shell)
      await self?.awaitExitThenFree(key)
    }
  }

  /// Polls `ghostty_surface_process_exited` on the injected clock and frees only
  /// once the pty child is gone: freeing earlier is exactly the join that wedges
  /// the main actor.
  private func awaitExitThenFree(_ key: ObjectIdentifier) async {
    for attempt in 0..<Self.maxExitPollAttempts {
      guard let entry = pending[key] else { return }
      pending[key]?.stage = .awaitingExit(attempt: attempt)
      if hasProcessExited(entry.view) {
        performFree(key, entry.view)
        return
      }
      do {
        try await clock.sleep(for: Self.exitPollInterval)
      } catch {
        return
      }
    }
    leak(key)
  }

  /// Leak over hang (decision 1): the child never exited, so freeing would join a
  /// wedged io thread and freeze the app. Skip the free and keep the view.
  private func leak(_ key: ObjectIdentifier) {
    guard let entry = pending[key] else { return }
    pending[key] = nil
    teardownTasks[key] = nil
    leaked.append(entry.view)
    let message = """
      leaked surface \(entry.view.id): pty child still alive after \
      \(Self.maxExitPollAttempts) polls; skipping free (leaked: \(leaked.count))
      """
    if leaked.count > Self.leakedWarningCap {
      Self.logger.error(message)
    } else {
      Self.logger.warning(message)
    }
    analytics.capture("surface_teardown_leaked", ["leaked_count": leaked.count])
  }

  /// Frees on the main actor (constraint 1) through the view (binding 11), then
  /// drops the queue's last strong reference.
  private func performFree(_ key: ObjectIdentifier, _ view: GhosttySurfaceView) {
    free(view)
    pending[key]?.stage = .freed
    pending[key] = nil
    teardownTasks[key] = nil
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
