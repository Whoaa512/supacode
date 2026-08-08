import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The auto-settle policy behind the Tasks tab (A15, A30).
///
/// Reads `@Shared` app storage directly rather than going through
/// `SettingsFeature`: these three values have no validation, no side effects
/// and no file to write, so routing them through a reducer would add a binding
/// hop and a second place for the defaults to live. The Tasks panel notices the
/// change and re-partitions on its own.
public struct TasksSettingsView: View {
  @Shared(.taskAutoSettleEnabled) private var isAutoSettleEnabled
  @Shared(.taskAutoSettleOnFinishedPullRequest) private var settlesOnFinishedPullRequest
  @Shared(.taskInactivityWindowDays) private var inactivityWindowDays
  @Shared(.sidebarShowsWorktreesTab) private var showsWorktreesTab
  @Shared(.sidebarShowsAgentsTab) private var showsAgentsTab

  public init() {}

  public var body: some View {
    Form {
      Section {
        Toggle(isOn: Binding($isAutoSettleEnabled)) {
          Text("Settle finished work automatically")
          Text("Files quiet tasks into the settled tail. Tasks you settled yourself stay settled either way.")
        }
        .help("Turn off to keep every task in Active until you settle it by hand.")
      } footer: {
        Text("Settling never closes anything: sessions hibernate and scrollback is kept.")
      }
      Section {
        Toggle(isOn: Binding($settlesOnFinishedPullRequest)) {
          Text("Settle when the pull request is merged or closed")
          Text("Waits until the task has also been quiet for an hour, so a follow-up message keeps it active.")
        }
        .disabled(!isAutoSettleEnabled)
        .help("Only applies while automatic settling is on. An open pull request always keeps a task active.")
        Stepper(value: Binding($inactivityWindowDays), in: 0...90) {
          Text("Settle after \(inactivityLabel)")
          Text("How long a task can go without activity before it is filed away. Zero turns this off.")
        }
        .disabled(!isAutoSettleEnabled)
        .help("Days of no activity before a task moves to the settled tail. Set to zero to never settle on time alone.")
      }
      Section {
        Toggle(isOn: Binding($showsWorktreesTab)) {
          Text("Show the Worktrees panel")
        }
        .help("Hiding a panel only removes its segment — nothing is deleted, and ⌘N still reaches every directory.")
        Toggle(isOn: Binding($showsAgentsTab)) {
          Text("Show the Agents panel")
        }
        .help("Hiding a panel only removes its segment. Its shortcut brings it back.")
      } header: {
        Text("Sidebar panels")
      } footer: {
        Text("Tasks is always shown. Hiding a panel keeps everything in it — its shortcut unhides it again.")
      }
    }
    .formStyle(.grouped)
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Tasks")
  }

  /// Spelled out rather than "0 days", because zero is a *mode* here (the
  /// inactivity path off), not a duration anybody waits.
  private var inactivityLabel: String {
    switch inactivityWindowDays {
    case ...0: "never"
    case 1: "1 day of quiet"
    default: "\(inactivityWindowDays) days of quiet"
    }
  }
}
