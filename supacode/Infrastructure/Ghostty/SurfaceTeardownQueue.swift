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
final class SurfaceTeardownQueue {
  private var pending: [UUID: GhosttySurfaceView] = [:]

  /// Number of `handOff(_:)` calls seen. Distinct from `pendingSurfaceIDs.count`
  /// so a surface handed off twice is observable.
  private(set) var handOffCount = 0

  var pendingSurfaceIDs: Set<UUID> { Set(pending.keys) }

  /// Takes ownership of `view`'s surface teardown and returns without touching
  /// ghostty, so the caller's turn on the main actor never waits on a free.
  func handOff(_ view: GhosttySurfaceView) {
    handOffCount += 1
    guard pending[view.id] == nil else { return }
    pending[view.id] = view
    view.prepareForDeferredTeardown()
  }
}
