import Foundation
import SupacodeSettingsShared

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
/// Resolve policy per surface: detach the session's zmx clients once over IPC,
/// then poll `ghostty_surface_process_exited` on an injected clock with a bounded
/// number of attempts, and free only once the child is gone.
///
/// Detach, never signal: the zmx daemon is a plain `fork()` of the client, so its
/// command line is IDENTICAL — any `pgrep -f`/`pkill` pattern matches both, and a
/// SIGTERM that lands on the daemon SIGKILLs the entire terminal process group
/// (`handleKill`), murdering the session hibernation exists to preserve. The IPC
/// `DetachAll` has no code path to `handleKill`, so it cannot kill the session by
/// construction; the client exits on socket HUP, which is the EOF the wedged pty
/// io reader needs.
@MainActor
final class SurfaceTeardownQueue {
  /// Keyed by VIEW identity, not surface UUID: a dormant tab reuses its surface
  /// UUIDs on wake, so a UUID-keyed map would treat the woken generation as
  /// already pending, skip the hand-off, and let its free run inline again.
  private var pending: [ObjectIdentifier: GhosttySurfaceView] = [:]
  /// One Task per pending view: no central driver loop. Retained so callers (and
  /// tests) can await a surface's teardown, and so a resolved surface drops its
  /// Task instead of accumulating one per hibernate.
  private var teardownTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  /// Detaches every client of a zmx session over the daemon's IPC socket
  /// (`ZmxClient.detachSessionClients` in production).
  private let detachClients: @Sendable (String) async -> Void
  private let clock: any Clock<Duration>
  private let analytics: AnalyticsClient
  private let hasProcessExited: (GhosttySurfaceView) -> Bool
  private let free: (GhosttySurfaceView) -> Void
  private nonisolated static let logger = SupaLogger("SurfaceTeardown")
  /// Deliberately leaked surfaces, kept RETAINED: ghostty holds the
  /// bridge as userdata with no liveness registry, so dropping a view whose surface
  /// is still alive is a use-after-free on the next callback. Retention is
  /// therefore not optional — the cap below only escalates logging.
  private var leaked: [GhosttySurfaceView] = []
  /// Past this many leaks something systemic is wrong (a wedged pty is rare; 32 of
  /// them means every hibernate is wedging), so the log switches to `error`. The
  /// views are still retained.
  private static let leakedLogEscalationThreshold = 32

  /// How long the child gets to die after the detach before the surface is
  /// abandoned: 200 * 50ms = 10s. A busy shell (agent flushing output, shell exit
  /// hooks) can take seconds to unwind after its attach client is EOF'd, and the
  /// two outcomes are wildly asymmetric — waiting longer costs one 50ms-interval
  /// Task, giving up costs a permanently retained surface.
  private static let exitPollInterval: Duration = .milliseconds(50)
  private static let maxExitPollAttempts = 200
  /// Above this, the free stalled the main actor long enough to be user-visible.
  private static let slowFreeThreshold: Duration = .milliseconds(250)

  init(
    detachClients: @escaping @Sendable (String) async -> Void,
    clock: any Clock<Duration> = ContinuousClock(),
    analytics: AnalyticsClient,
    hasProcessExited: @escaping (GhosttySurfaceView) -> Bool = { $0.hasSurfaceProcessExited },
    free: @escaping (GhosttySurfaceView) -> Void = { $0.performDeferredFree() }
  ) {
    self.detachClients = detachClients
    self.clock = clock
    self.analytics = analytics
    self.hasProcessExited = hasProcessExited
    self.free = free
  }

  var pendingSurfaceIDs: Set<UUID> { Set(pending.values.map(\.id)) }

  var pendingCount: Int { pending.count }

  var leakedCount: Int { leaked.count }

  /// Live per-view Tasks. A resolved (freed or leaked) surface must drop its Task,
  /// so a long session cannot accumulate them.
  var teardownTaskCount: Int { teardownTasks.count }

  func teardownTask(for view: GhosttySurfaceView) -> Task<Void, Never>? {
    teardownTasks[ObjectIdentifier(view)]
  }

  func isPending(_ view: GhosttySurfaceView) -> Bool {
    pending[ObjectIdentifier(view)] != nil
  }

  /// Surfaces freed inline from `GhosttySurfaceView.deinit` — the residual deadlock
  /// path, where no owner called `closeSurface()` so the free was never made safe.
  /// Reported through the queue rather than the view because `deinit` cannot resolve
  /// a `@Dependency` without resurrecting `self`, and the queue already holds the
  /// analytics client the rest of the teardown path reports on.
  private(set) var inlineFreeAtDeinitCount = 0

  func recordInlineFreeAtDeinit(surfaceID: UUID) {
    inlineFreeAtDeinitCount += 1
    analytics.capture(
      "surface_freed_inline_at_deinit",
      ["inline_free_count": inlineFreeAtDeinitCount]
    )
  }

  /// Takes ownership of `view`'s surface teardown and returns without touching
  /// ghostty, so the caller's turn on the main actor never waits on a free.
  ///
  /// - Parameter detachClients: `false` skips the detach for a surface whose child
  ///   is already gone but whose zmx session is being reattached under the same
  ///   surface id: `DetachAll` is session-wide, so it would boot the replacement's
  ///   freshly attached client (recoverable, but pointless).
  func handOff(_ view: GhosttySurfaceView, detachClients: Bool = true) {
    let key = ObjectIdentifier(view)
    guard pending[key] == nil else { return }
    pending[key] = view
    view.prepareForDeferredTeardown()
    let sessionID = ZmxSessionID.make(surfaceID: view.id)
    let detach = self.detachClients
    // A non-zmx surface (script tab, or zmx unbundled) has no attach client and no
    // session daemon, so there is nothing to detach.
    let shouldDetach = detachClients && view.usesZmx
    teardownTasks[key] = Task { [weak self] in
      if shouldDetach {
        await detach(sessionID)
      }
      await self?.awaitExitThenFree(key)
    }
  }

  /// Polls `ghostty_surface_process_exited` on the injected clock and frees only
  /// once the pty child is gone: freeing earlier is exactly the join that wedges
  /// the main actor.
  private func awaitExitThenFree(_ key: ObjectIdentifier) async {
    for _ in 0..<Self.maxExitPollAttempts {
      guard let view = pending[key] else { return }
      if hasProcessExited(view) {
        performFree(key, view)
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

  /// Poll bound exhausted. Leaking is only earned when a detach was possible: for
  /// a zmx surface the detach already went out, so a still-live child means a
  /// client that survived socket HUP (or a genuinely wedged reader) and the free
  /// would hang the app. A non-zmx surface has no detach mechanism at all, so
  /// "never exited" carries no such evidence — free it anyway, which is what
  /// closing the pty did before this queue existed (the free SIGHUPs the child;
  /// only a wedged reader can block it).
  private func resolveExpiredPoll(_ key: ObjectIdentifier) {
    guard let view = pending[key] else { return }
    guard view.usesZmx else {
      performFree(key, view)
      return
    }
    leak(key, reason: "wedged")
  }

  /// Leak over hang: freeing a surface whose child may still hold the pty would join
  /// a wedged io thread and freeze the app. Skip the free and keep the view.
  ///
  /// - Parameter reason: `wedged` (detach went out, child never exited) or
  ///   `cancelled` (poll interrupted, child's state unknown). There is deliberately
  ///   no "no detach possible" reason: a surface with no attach client to detach is
  ///   FREED when the poll expires (see `resolveExpiredPoll`), so it never leaks.
  private func leak(_ key: ObjectIdentifier, reason: String) {
    guard let view = pending[key] else { return }
    pending[key] = nil
    teardownTasks[key] = nil
    leaked.append(view)
    let message = """
      leaked surface \(view.id): pty child still alive after \
      \(Self.maxExitPollAttempts) polls; skipping free (leaked: \(leaked.count))
      """
    if leaked.count > Self.leakedLogEscalationThreshold {
      Self.logger.error(message)
    } else {
      Self.logger.warning(message)
    }
    analytics.capture(
      "surface_teardown_leaked",
      ["leaked_count": leaked.count, "reason": reason, "used_zmx": view.usesZmx]
    )
  }

  /// Frees on the main actor through the view, then drops the queue's last strong
  /// reference.
  private func performFree(_ key: ObjectIdentifier, _ view: GhosttySurfaceView) {
    // Measured on a REAL clock, not the injected one: `Surface.deinit` also joins
    // the RENDERER thread, which `process_exited` does not bound, so this is the
    // residual main-actor stall and only wall time describes it.
    let start = ContinuousClock.now
    free(view)
    let elapsed = ContinuousClock.now - start
    let usedZmx = view.usesZmx
    // The denominator for the leak rate: every resolved surface reports exactly one
    // of `surface_teardown_freed` / `surface_teardown_leaked`.
    analytics.capture("surface_teardown_freed", ["used_zmx": usedZmx])
    if elapsed > Self.slowFreeThreshold {
      Self.logger.warning(
        "slow surface free for \(view.id): \(elapsed) (main actor stalled)"
      )
      analytics.capture(
        "surface_teardown_slow_free",
        ["stall_ms": Self.milliseconds(elapsed), "used_zmx": usedZmx]
      )
    }
    pending[key] = nil
    teardownTasks[key] = nil
  }

  private nonisolated static func milliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
  }
}
