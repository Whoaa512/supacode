import SwiftUI

private struct ToggleCommandCenterActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var toggleCommandCenterAction: (() -> Void)? {
    get { self[ToggleCommandCenterActionKey.self] }
    set { self[ToggleCommandCenterActionKey.self] = newValue }
  }
}
