import SwiftUI

private struct ToggleCommandCenterActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var toggleCommandCenterAction: FocusedAction<Void>? {
    get { self[ToggleCommandCenterActionKey.self] }
    set { self[ToggleCommandCenterActionKey.self] = newValue }
  }
}
