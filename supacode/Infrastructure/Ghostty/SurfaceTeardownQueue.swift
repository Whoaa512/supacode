import Foundation

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

  /// Number of `handOff(_:)` calls seen. Distinct from `pendingCount` so a view
  /// handed off twice is observable.
  private(set) var handOffCount = 0

  var pendingSurfaceIDs: Set<UUID> { Set(pending.values.map(\.id)) }

  var pendingCount: Int { pending.count }

  /// Takes ownership of `view`'s surface teardown and returns without touching
  /// ghostty, so the caller's turn on the main actor never waits on a free.
  func handOff(_ view: GhosttySurfaceView) {
    handOffCount += 1
    let key = ObjectIdentifier(view)
    guard pending[key] == nil else { return }
    pending[key] = view
    view.prepareForDeferredTeardown()
  }
}
