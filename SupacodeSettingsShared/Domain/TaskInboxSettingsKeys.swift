import Foundation
import Sharing

/// The three app-storage handles the task inbox's auto-settle policy is built
/// from (A15, A30).
///
/// `@Shared` app storage rather than a settings client: the doctrine is that
/// settings are read where they are used, and wrapping three booleans in a
/// dependency would buy nothing but a second place for the defaults to drift.
/// They live in the shared module because two targets read them — the reducer
/// that classifies rows and the settings pane that writes them — and a key
/// string spelled twice is a setting that silently stops working.
///
/// Defaults are the shipping behaviour: auto-settle on, both paths on, a week
/// of quiet. An inbox that never files anything away is the pile the Tasks tab
/// exists to replace.
nonisolated extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  /// The global off-switch. Kills the *auto* paths only — an explicit settle,
  /// and the `.settled` override behind it, are the user talking, and a setting
  /// may never overrule that.
  public static var taskAutoSettleEnabled: Self {
    Self[.appStorage("taskAutoSettleEnabled"), default: true]
  }

  /// Whether a merged or closed pull request settles its task once the task has
  /// also gone quiet. Independent of the inactivity window: someone who wants
  /// only time-based filing turns this off and keeps the rest.
  public static var taskAutoSettleOnFinishedPullRequest: Self {
    Self[.appStorage("taskAutoSettleOnFinishedPullRequest"), default: true]
  }
}

nonisolated extension SharedReaderKey where Self == AppStorageKey<Int>.Default {
  /// How many days of no activity file a task into the settled tail. `0` (or
  /// anything lower) disables the inactivity path without touching the
  /// finished-PR one.
  public static var taskInactivityWindowDays: Self {
    Self[.appStorage("taskInactivityWindowDays"), default: 7]
  }
}
