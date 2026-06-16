import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Launch sheet for a workflow run. Shown when more than a one-click launch is
/// useful (context selectors, a note, a URL, harness, commit count).
struct WorkflowLauncherSheet: View {
  @Bindable var store: StoreOf<ProjectCommandCenterFeature>

  var body: some View {
    if let launcher = store.launcher {
      content(for: launcher)
    }
  }

  private func content(for launcher: ProjectCommandCenterFeature.Launcher) -> some View {
    Form {
      Section {
        LabeledContent("Project", value: launcher.projectName)
        LabeledContent("Workflow", value: launcher.workflow.name)
        Picker("Harness", selection: harnessBinding) {
          ForEach(AgentHarnessDefinition.all) { harness in
            Text(harness.displayName).tag(harness.id)
          }
        }
      } header: {
        Label(launcher.workflow.name, systemImage: launcher.workflow.systemImage)
          .font(.headline)
        if !launcher.workflow.description.isEmpty {
          Text(launcher.workflow.description).foregroundStyle(.secondary)
        }
      }
      .headerProminence(.increased)

      Section("Context") {
        ForEach(WorkflowContextSelector.allCases, id: \.self) { selector in
          Toggle(
            selector.displayName,
            isOn: Binding(
              get: { launcher.selectors.contains(selector) },
              set: { _ in store.send(.toggleSelector(selector)) }
            )
          )
        }
        if launcher.selectors.contains(.lastNCommits) {
          Stepper(
            "Commits: \(launcher.commitCount)",
            value: Binding(
              get: { launcher.commitCount },
              set: { store.send(.setLauncherCommitCount($0)) }
            ),
            in: 1...50
          )
        }
      }

      Section("Input") {
        TextField(
          "URL",
          text: Binding(get: { launcher.url }, set: { store.send(.setLauncherURL($0)) })
        )
        TextField(
          "Note",
          text: Binding(get: { launcher.note }, set: { store.send(.setLauncherNote($0)) }),
          axis: .vertical
        )
        .lineLimit(2...5)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 420, minHeight: 460)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button("Cancel", role: .cancel) { store.send(.dismissLauncher) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Run") { store.send(.confirmLaunch) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
      .padding()
      .background(.bar)
    }
  }

  private var harnessBinding: Binding<String> {
    Binding(
      get: { store.launcher?.harnessID ?? AgentHarnessDefinition.pi.id },
      set: { store.send(.setLauncherHarness($0)) }
    )
  }
}
