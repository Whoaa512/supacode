import SwiftUI

/// Trailing-edge swap between a row's normal accessories and its ⌃n shortcut
/// hint while a modifier is held. Shared by the Worktrees and Agents sidebars so
/// the two panels can't drift in styling or animation.
///
/// `hint` is already resolved by the caller (a trivial join of the structure's
/// `slotByID` against `CommandKeyObserver` + the user's shortcut overrides);
/// `nil` means "no hint", which shows the accessories.
struct SidebarShortcutHintCrossfade<Accessories: View>: View {
  let hint: String?
  @ViewBuilder let accessories: Accessories

  var body: some View {
    let hasHint = hint != nil
    // Cross-fade via opacity so flipping ⌘ doesn't snap the row.
    ZStack(alignment: .trailing) {
      accessories
        .opacity(hasHint ? 0 : 1)
        .allowsHitTesting(!hasHint)

      Text(hint ?? "")
        .font(.caption)
        .foregroundStyle(.secondary)
        .opacity(hasHint ? 1 : 0)
    }
    .animation(.easeInOut(duration: TerminalTabBarMetrics.fadeAnimationDuration), value: hasHint)
  }
}
