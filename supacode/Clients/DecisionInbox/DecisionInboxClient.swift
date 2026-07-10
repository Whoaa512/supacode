import AppKit
import ComposableArchitecture
import Foundation

/// Side effects the decision inbox needs but that live outside pure reducer
/// state: persisting a resolution to the durable event log (owned by
/// `WorktreeTerminalManager`, so the app bridges it at startup — one store, no
/// second log) and copying a suggested response to the system pasteboard.
struct DecisionInboxClient: Sendable {
  var persistResolution: @Sendable (InboxResolution) -> Void
  var copyToPasteboard: @Sendable (String) -> Void

  init(
    persistResolution: @escaping @Sendable (InboxResolution) -> Void,
    copyToPasteboard: @escaping @Sendable (String) -> Void
  ) {
    self.persistResolution = persistResolution
    self.copyToPasteboard = copyToPasteboard
  }
}

extension DecisionInboxClient: DependencyKey {
  /// `persistResolution` is overridden in `supacodeApp.makeStore(_:)` to reach
  /// the manager's `AgentEventLog`; the placeholder genuinely no-ops so a dropped
  /// override degrades to "history not recorded" rather than reporting an issue
  /// or crashing a release build.
  static let liveValue = DecisionInboxClient(
    persistResolution: { _ in },
    copyToPasteboard: { text in
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
    }
  )

  static let testValue = DecisionInboxClient(
    persistResolution: unimplemented("DecisionInboxClient.persistResolution"),
    copyToPasteboard: unimplemented("DecisionInboxClient.copyToPasteboard")
  )
}

extension DependencyValues {
  var decisionInboxClient: DecisionInboxClient {
    get { self[DecisionInboxClient.self] }
    set { self[DecisionInboxClient.self] = newValue }
  }
}
