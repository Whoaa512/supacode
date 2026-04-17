import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

struct SidebarFolderSectionView: View {
  let folderID: UUID
  let folderName: String
  let repositoryIDs: [Repository.ID]
  let hotkeyRows: [WorktreeRowModel]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager

  @State private var isRenaming = false
  @State private var draftName = ""

  var body: some View {
    Section(isExpanded: expansionBinding) {
      let repositoriesByID = Dictionary(
        uniqueKeysWithValues: store.state.repositories.map { ($0.id, $0) }
      )
      if repositoryIDs.isEmpty {
        Text("Drag a repository here")
          .font(.footnote)
          .foregroundStyle(.tertiary)
          .padding(.leading, 20)
          .padding(.vertical, 4)
      }
      ForEach(repositoryIDs, id: \.self) { repositoryID in
        if let repository = repositoriesByID[repositoryID] {
          SidebarRepositoryFolderChildView(
            repository: repository,
            hotkeyRows: hotkeyRows,
            selectedWorktreeIDs: selectedWorktreeIDs,
            store: store,
            terminalManager: terminalManager,
          )
        }
      }
    } header: {
      SidebarFolderHeaderView(
        folderID: folderID,
        folderName: folderName,
        isRenaming: $isRenaming,
        draftName: $draftName,
        store: store,
      )
    }
    .dropDestination(for: RepositoryIDTransferable.self) { items, _ in
      guard let item = items.first else { return false }
      let destinationIndex = repositoryIDs.count
      store.send(
        .repositoryMovedToFolder(item.id, folderID: folderID, destinationIndex: destinationIndex)
      )
      return true
    }
  }

  private var expansionBinding: Binding<Bool> {
    Binding(
      get: { !store.state.isFolderCollapsed(folderID) },
      set: { _ in store.send(.folderCollapseToggled(folderID)) },
    )
  }
}

private struct SidebarFolderHeaderView: View {
  let folderID: UUID
  let folderName: String
  @Binding var isRenaming: Bool
  @Binding var draftName: String
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "folder.fill")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      if isRenaming {
        TextField("Folder name", text: $draftName)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .onSubmit(commitRename)
          .onExitCommand {
            isRenaming = false
          }
      } else {
        Text(folderName)
          .foregroundStyle(.secondary)
          .onTapGesture(count: 2) {
            beginRename()
          }
      }
      Spacer()
    }
    .contextMenu {
      Button("Rename Folder") { beginRename() }
      Button("Delete Folder", role: .destructive) {
        store.send(.folderDeleted(folderID))
      }
    }
  }

  private func beginRename() {
    draftName = folderName
    isRenaming = true
  }

  private func commitRename() {
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    isRenaming = false
    guard !trimmed.isEmpty, trimmed != folderName else { return }
    store.send(.folderRenamed(folderID, trimmed))
  }
}

struct SidebarRepositoryFolderChildView: View {
  let repository: Repository
  let hotkeyRows: [WorktreeRowModel]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    let isRemoving = store.state.isRemovingRepository(repository)
    Section(isExpanded: expansionBinding) {
      WorktreeRowsView(
        repository: repository,
        hotkeyRows: hotkeyRows,
        selectedWorktreeIDs: selectedWorktreeIDs,
        store: store,
        terminalManager: terminalManager,
      )
    } header: {
      RepoSectionHeaderView(name: repository.name, isRemoving: isRemoving)
        .draggable(RepositoryIDTransferable(id: repository.id))
    }
  }

  private var expansionBinding: Binding<Bool> {
    Binding(
      get: { store.state.isRepositoryExpanded(repository.id) },
      set: { isExpanded in
        store.send(.repositoryExpansionChanged(repository.id, isExpanded: isExpanded))
      },
    )
  }
}

struct RepositoryIDTransferable: Codable, Transferable {
  let id: Repository.ID

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .supacodeRepositoryID)
  }
}

extension UTType {
  static let supacodeRepositoryID = UTType(exportedAs: "app.supabit.supacode.repository-id")
}

struct SidebarRepositoryMoveMenu: View {
  let repositoryID: Repository.ID
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    let folders = store.state.folders
    let currentFolderID = folders.first(where: { $0.repositoryIDs.contains(repositoryID) })?.id
    Menu("Move to Folder") {
      Button("No Folder (root)") {
        store.send(.repositoryMovedToFolder(repositoryID, folderID: nil, destinationIndex: Int.max))
      }
      .disabled(currentFolderID == nil)
      Divider()
      ForEach(folders) { folder in
        Button(folder.name) {
          store.send(
            .repositoryMovedToFolder(repositoryID, folderID: folder.id, destinationIndex: Int.max)
          )
        }
        .disabled(folder.id == currentFolderID)
      }
    }
    Button("New Folder from Repository…") {
      store.send(.folderCreated(name: "New Folder"))
    }
  }
}
