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
  /// Above this, the free stalled the main actor long enough to be user-visible.
  private static let slowFreeThreshold: Duration = .milliseconds(250)

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

  var pendingSurfaceIDs: Set<UUID> { Set(pending.values.map(\.view.id)) }

  var pendingCount: Int { pending.count }

  var leakedCount: Int { leaked.count }

  /// Live per-view Tasks. A resolved (freed or leaked) surface must drop its Task,
  /// so a long session cannot accumulate them.
  var teardownTaskCount: Int { teardownTasks.count }

  func teardownTask(for view: GhosttySurfaceView) -> Task<Void, Never>? {
    teardownTasks[ObjectIdentifier(view)]
  }

  func stage(for view: GhosttySurfaceView) -> Stage? {
    pending[ObjectIdentifier(view)]?.stage
  }

  /// Takes ownership of `view`'s surface teardown and returns without touching
  /// ghostty, so the caller's turn on the main actor never waits on a free.
  ///
  /// - Parameter killAttachClient: `false` skips the client kill for a surface whose
  ///   child is already gone but whose zmx session is being reattached under the
  ///   same surface id: the kill matches by session pattern, so it would take out
  ///   the replacement's client instead (binding 8, same hazard as re-killing).
  func handOff(_ view: GhosttySurfaceView, killAttachClient: Bool = true) {
    let key = ObjectIdentifier(view)
    guard pending[key] == nil else { return }
    pending[key] = Entry(view: view, stage: .killRequested)
    view.prepareForDeferredTeardown()
    let sessionID = ZmxSessionID.make(surfaceID: view.id)
    let shell = shell
    // A non-zmx surface (script tab, or zmx unbundled) has no attach client, so
    // there is nothing to pgrep for and nothing to EOF.
    let shouldKill = killAttachClient && view.usesZmx
    teardownTasks[key] = Task { [weak self] in
      if shouldKill {
        await Self.killAttachClient(sessionID: sessionID, shell: shell)
      }
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
        // Cancelled mid-poll: nothing knows whether the child is gone, so the free
        // is not safe and the view must not simply be dropped either (ghostty holds
        // its bridge as userdata). Leak it — retained, logged, counted — instead of
        // leaving it pending with no Task to resolve it.
        leak(key, reason: "cancelled")
        return
      }
    }
    resolveExpiredPoll(key)
  }

  /// Poll bound exhausted. Leaking is only earned when a client kill was possible:
  /// for a zmx surface the kill already went out, so a still-live child means a
  /// genuinely wedged reader and the free would hang the app. A non-zmx surface has
  /// no kill mechanism at all, so "never exited" carries no such evidence — free it
  /// anyway, which is what closing the pty did before this queue existed (the free
  /// SIGHUPs the child; only a wedged reader can block it).
  private func resolveExpiredPoll(_ key: ObjectIdentifier) {
    guard let entry = pending[key] else { return }
    guard entry.view.usesZmx else {
      performFree(key, entry.view)
      return
    }
    leak(key, reason: "wedged")
  }

  /// Leak over hang: freeing a surface whose child may still hold the pty would join
  /// a wedged io thread and freeze the app. Skip the free and keep the view.
  ///
  /// - Parameter reason: `wedged` (kill went out, child never exited) or `cancelled`
  ///   (poll interrupted, child's state unknown).
  private func leak(_ key: ObjectIdentifier, reason: String) {
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
    analytics.capture(
      "surface_teardown_leaked",
      ["leaked_count": leaked.count, "reason": reason, "used_zmx": entry.view.usesZmx]
    )
  }

  /// Frees on the main actor (constraint 1) through the view (binding 11), then
  /// drops the queue's last strong reference.
  private func performFree(_ key: ObjectIdentifier, _ view: GhosttySurfaceView) {
    // Measured on a REAL clock, not the injected one: `Surface.deinit` also joins
    // the RENDERER thread, which `process_exited` does not bound (binding 12), so
    // this is the residual main-actor stall and only wall time describes it.
    let start = ContinuousClock.now
    free(view)
    let elapsed = ContinuousClock.now - start
    if elapsed > Self.slowFreeThreshold {
      Self.logger.warning(
        "slow surface free for \(view.id): \(elapsed) (main actor stalled)"
      )
    }
    pending[key]?.stage = .freed
    pending[key] = nil
    teardownTasks[key] = nil
  }

  /// Kills the surface's `zmx attach` CLIENT (never the session, which must
  /// survive to be re-attached on wake) so the wedged pty io-reader gets EOF.
  ///
  /// Exactly ONE kill, at hand-off, and always PID-targeted: the `-f` pattern also
  /// matches any FUTURE client of the same (surviving) session, so both a retry and
  /// a pattern-wide `pkill` risk murdering a freshly woken terminal. When `pgrep`
  /// finds nothing there is no client left to EOF, so there is nothing to do.
  private nonisolated static func killAttachClient(
    sessionID: String,
    shell: SurfaceTeardownShell
  ) async {
    let pattern = "zmx attach \(sessionID)"
    let stdout = await shell.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", pattern])
    let pids = Self.parsePIDs(stdout ?? "")
    guard !pids.isEmpty else {
      logger.warning("no zmx attach client found for \(sessionID); nothing to kill")
      return
    }
    _ = await shell.run(URL(fileURLWithPath: "/bin/kill"), ["-TERM"] + pids)
  }

  private nonisolated static func parsePIDs(_ stdout: String) -> [String] {
    stdout
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { Int32($0) != nil }
  }
}
