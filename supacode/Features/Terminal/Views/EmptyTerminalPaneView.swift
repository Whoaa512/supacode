import SupacodeSettingsShared
import SwiftUI

struct EmptyTerminalPaneView: View {
  let message: String
  /// The recovery hint below the message; the default names the strip's
  /// new-tab button, so tab-less states must pass an affordance that exists.
  var hint: Text = Text("Use the \(Text("+").bold()) button to open a terminal.")
  /// Starts an agent task in the directory on screen; only a directory with
  /// no task to show passes it.
  var newTaskHere: (() -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "apple.terminal.on.rectangle")
        .appFont(.title)
        .imageScale(.large)
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
      VStack(spacing: 4) {
        Text(message)
          .appFont(.title3)
        hint
          .appFont(.subheadline)
          .foregroundStyle(.secondary)
      }
      if let newTaskHere {
        Button("New Task Here", systemImage: "plus", action: newTaskHere)
          .help("Start a new agent task in this directory")
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
