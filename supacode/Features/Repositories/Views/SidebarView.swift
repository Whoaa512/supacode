import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct SidebarView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Shared(.settingsFile) private var settingsFile
  /// Raw string storage (AppStorage-native); mapped to `SidebarTab` for the picker.
  @Shared(.sidebarTab) private var sidebarTabRawValue: String

  private var sidebarTab: Binding<SidebarTab> {
    Binding(
      get: { SidebarTab.resolved(fromStoredValue: sidebarTabRawValue) },
      set: { newTab in $sidebarTabRawValue.withLock { $0 = newTab.rawValue } }
    )
  }

  var body: some View {
    let state = store.state
    let confirmAlert = state.confirmWorktreeAlert
    // Reducer-cached: deriving these from `sidebarItems` here would
    // observation-track every row and fan per-leaf ticks out to the whole List.
    let archiveTargets = state.sidebarSelectionSlice.archiveTargets
    let deleteTargets = state.sidebarSelectionSlice.deleteTargets
    let openRepo = AppShortcuts.openRepository.effective(from: settingsFile.global.shortcutOverrides)
    let toggleAgentsTab = AppShortcuts.toggleAgentsSidebarTab.effective(from: settingsFile.global.shortcutOverrides)
    let tabShortcut = toggleAgentsTab?.display ?? "none"

    return VStack(spacing: 0) {
      Picker("Sidebar Panel", selection: sidebarTab) {
        ForEach(SidebarTab.allCases, id: \.self) { tab in
          Label(tab.title, systemImage: tab.systemImage)
            .tag(tab)
            .help("\(tab.help) (\(tabShortcut) switches between panels)")
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .help("\(sidebarTab.wrappedValue.help) (\(tabShortcut) switches between panels)")

      Divider()

      switch sidebarTab.wrappedValue {
      case .worktrees:
        SidebarListView(
          store: store,
          terminalManager: terminalManager
        )
      case .agents:
        AgentDashboardListView(store: store)
      case .tasks:
        TasksSidebarPlaceholderView()
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            store.send(.requestOpenRepository)
          } label: {
            Label("Local Repository or Folder…", systemImage: "laptopcomputer")
          }
          .help("Add a local repository or folder (\(openRepo?.display ?? "none"))")
          Button {
            store.send(.requestAddRemoteRepository)
          } label: {
            Label("Remote Repository or Folder…", systemImage: "wifi")
          }
          .help("Add a repository or folder on an SSH host")
          Divider()
          Button {
            store.send(.requestCloneRepository)
          } label: {
            Label("Clone Repository…", systemImage: "square.and.arrow.down.on.square")
          }
          .help("Clone a remote repository into a local folder")
        } label: {
          Label {
            Text("Add…")
          } icon: {
            Image(systemName: "folder.badge.plus")
              .offset(y: -1)
              .accessibilityHidden(true)
          }
        }
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .help("Add Repository, Folder, or Remote")
      }
    }
    .sheet(item: $store.scope(state: \.remoteConnectionForm, action: \.remoteConnectionForm)) { formStore in
      RemoteConnectionFormView(store: formStore)
    }
    .sheet(item: $store.scope(state: \.cloneRepositoryForm, action: \.cloneRepositoryForm)) { formStore in
      CloneRepositoryFormView(store: formStore)
    }
    .focusedSceneAction(
      \.confirmWorktreeAction,
      enabled: confirmAlert != nil,
      token: confirmAlert
    ) {
      if let alert = confirmAlert {
        store.send(.alert(.presented(alert)))
      }
    }
    .focusedAction(
      \.archiveWorktreeAction,
      enabled: !archiveTargets.isEmpty,
      token: archiveTargets
    ) {
      if archiveTargets.count == 1, let target = archiveTargets.first {
        store.send(.requestArchiveWorktree(target.worktreeID, target.repositoryID))
      } else {
        store.send(.requestArchiveWorktrees(archiveTargets))
      }
    }
    .focusedAction(
      \.deleteWorktreeAction,
      enabled: !deleteTargets.isEmpty,
      token: deleteTargets
    ) {
      store.send(.requestDeleteSidebarItems(deleteTargets))
    }
  }
}

/// Stand-in for the Tasks panel so the tab is selectable and routing is
/// exercised before the real list exists. Replaced by the task list view.
private struct TasksSidebarPlaceholderView: View {
  var body: some View {
    ContentUnavailableView(
      "No Tasks",
      systemImage: SidebarTab.tasks.systemImage,
      description: Text("The task inbox isn't wired up yet.")
    )
  }
}
