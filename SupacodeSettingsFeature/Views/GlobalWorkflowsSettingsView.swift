import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

public struct GlobalWorkflowsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  public init(store: StoreOf<SettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      if store.globalWorkflows.isEmpty {
        ContentUnavailableView(
          "No Custom Workflows",
          systemImage: "arrow.trianglehead.2.clockwise",
          description: Text("Add a workflow template to launch agent tasks from the command center.")
        )
      } else {
        workflowsForm
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.addGlobalWorkflow)
        } label: {
          Image(systemName: "plus")
            .accessibilityLabel("Add Workflow")
        }
        .help("Add a new workflow template.")
      }
    }
  }

  private var workflowsForm: some View {
    Form {
      ForEach($store.globalWorkflows) { $workflow in
        Section {
          TextField("Name", text: $workflow.name)
          Picker("Category", selection: $workflow.category) {
            ForEach(WorkflowCategory.allCases, id: \.self) { category in
              Text(category.rawValue.capitalized).tag(category)
            }
          }
          TextField("Prompt Template", text: $workflow.promptTemplate, axis: .vertical)
            .lineLimit(3...8)
          Toggle("Favorite", isOn: $workflow.isFavorite)
          Button("Remove", role: .destructive) {
            store.send(.removeGlobalWorkflow(workflow.id))
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}
