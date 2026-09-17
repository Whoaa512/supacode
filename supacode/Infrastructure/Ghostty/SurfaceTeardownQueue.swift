import Foundation
import SupacodeSettingsShared

/// Owns surfaces while their pty child is detached and allowed to exit.
/// `ghostty_surface_free` joins Ghostty threads, so freeing a wedged child on
/// the main actor can freeze the app. The queue retains the view until it can
/// safely free, or deliberately retains it forever when safety is unknown.
@MainActor
final class SurfaceTeardownQueue {
  private var pending: [ObjectIdentifier: GhosttySurfaceView] = [:]
  private var teardownTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var leaked: [GhosttySurfaceView] = []

  private let detachClients: @Sendable (String) async -> Void
  private let clock: any Clock<Duration>
  private let analytics: AnalyticsClient
  private let hasProcessExited: (GhosttySurfaceView) -> Bool
  private let free: (GhosttySurfaceView) -> Void

  private nonisolated static let logger = SupaLogger("SurfaceTeardown")
  private static let exitPollInterval: Duration = .milliseconds(50)
  private static let maxExitPollAttempts = 200
  private static let slowFreeThreshold: Duration = .milliseconds(250)
  private static let leakedLogEscalationThreshold = 32

  init(
    detachClients: @escaping @Sendable (String) async -> Void,
    clock: any Clock<Duration> = ContinuousClock(),
    analytics: AnalyticsClient,
    hasProcessExited: ((GhosttySurfaceView) -> Bool)? = nil,
    free: ((GhosttySurfaceView) -> Void)? = nil
  ) {
    self.detachClients = detachClients
    self.clock = clock
    self.analytics = analytics
    self.hasProcessExited = hasProcessExited ?? { $0.hasSurfaceProcessExited }
    self.free = free ?? { $0.performDeferredFree() }
  }

  var pendingSurfaceIDs: Set<UUID> { Set(pending.values.map(\.id)) }
  var pendingCount: Int { pending.count }
  var leakedCount: Int { leaked.count }
  var teardownTaskCount: Int { teardownTasks.count }
  private(set) var inlineFreeAtDeinitCount = 0

  func teardownTask(for view: GhosttySurfaceView) -> Task<Void, Never>? {
    teardownTasks[ObjectIdentifier(view)]
  }

  func isPending(_ view: GhosttySurfaceView) -> Bool {
    pending[ObjectIdentifier(view)] != nil
  }

  func recordInlineFreeAtDeinit(surfaceID: UUID) {
    inlineFreeAtDeinitCount += 1
    analytics.capture(
      "surface_freed_inline_at_deinit",
      ["inline_free_count": inlineFreeAtDeinitCount]
    )
  }

  /// Transfers ownership without calling Ghostty on the caller's turn.
  func handOff(_ view: GhosttySurfaceView, detachClients: Bool = true) {
    let key = ObjectIdentifier(view)
    guard pending[key] == nil else { return }
    pending[key] = view
    view.prepareForDeferredTeardown()
    let detach = self.detachClients
    let shouldDetach = detachClients && view.usesZmx
    let sessionID = ZmxSessionID.make(surfaceID: view.id)
    teardownTasks[key] = Task { [weak self] in
      if shouldDetach {
        await detach(sessionID)
      }
      await self?.awaitExitThenFree(key)
    }
  }

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
        leak(key, reason: "cancelled")
        return
      }
    }
    resolveExpiredPoll(key)
  }

  private func resolveExpiredPoll(_ key: ObjectIdentifier) {
    guard let view = pending[key] else { return }
    Self.logger.warning("Surface teardown timed out for \(view.id); used_zmx=\(view.usesZmx)")
    analytics.capture("surface_teardown_timed_out", ["used_zmx": view.usesZmx])
    guard view.usesZmx else {
      performFree(key, view)
      return
    }
    leak(key, reason: "wedged")
  }

  private func leak(_ key: ObjectIdentifier, reason: String) {
    guard let view = pending.removeValue(forKey: key) else { return }
    teardownTasks[key] = nil
    leaked.append(view)
    let message = "Leaked surface \(view.id): child did not exit; reason=\(reason), leaked=\(leaked.count)"
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

  private func performFree(_ key: ObjectIdentifier, _ view: GhosttySurfaceView) {
    let start = ContinuousClock.now
    free(view)
    let elapsed = ContinuousClock.now - start
    analytics.capture("surface_teardown_freed", ["used_zmx": view.usesZmx])
    Self.logger.info("Freed surface \(view.id); used_zmx=\(view.usesZmx)")
    if elapsed > Self.slowFreeThreshold {
      Self.logger.warning("Slow surface free for \(view.id): \(elapsed)")
      analytics.capture(
        "surface_teardown_slow_free",
        ["stall_ms": Self.milliseconds(elapsed), "used_zmx": view.usesZmx]
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
