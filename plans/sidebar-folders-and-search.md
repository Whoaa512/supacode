# Sidebar Folders + Search

Add folder grouping and an in-sidebar search box to the repositories sidebar.

## Requirements

- Flat folders only (no nesting). Uncategorized repos live at root alongside folders.
- Users can create / rename / delete folders, drag repos into/out of folders, and drag to reorder.
- Folders collapsible/expandable, state persisted.
- Sidebar search text field at top of sidebar.
  - Filters tree in-place (hides non-matching repos/worktrees/folders; auto-expands folders containing matches).
  - ⌘K focuses the search box.
  - ⌘⇧P still opens the existing CommandPalette (unchanged).
- Persist everything via `@Shared(.appStorage(...))` (follow existing patterns in RepositoriesFeature / RepositoryPersistenceClient).

## Architecture

### State (RepositoriesFeature.State)
- `var folders: IdentifiedArrayOf<SidebarFolder> = []`
- `var sidebarRootOrder: [SidebarRootItemID] = []` — ordered list of root-level items (either `.folder(UUID)` or `.repository(Repository.ID)`).
- `var collapsedFolderIDs: Set<UUID> = []` (persisted)
- `var sidebarSearchQuery: String = ""` (NOT persisted; fresh per launch is fine)

Existing `repositoryOrderIDs` stays but becomes implicit — reproducible from `sidebarRootOrder` (keep during migration, remove once everything is wired). Easier path: keep `repositoryOrderIDs` untouched for backwards compat; layer `sidebarRootOrder` as the new source of truth and derive `repositoryOrderIDs` from it (root-level repos + repos inside folders, in display order).

### Models (new file: supacode/Features/Repositories/Models/SidebarFolder.swift)
```swift
struct SidebarFolder: Identifiable, Equatable, Codable, Hashable {
  let id: UUID
  var name: String
  var repositoryIDs: [Repository.ID]  // ordered
}

enum SidebarRootItemID: Equatable, Hashable, Codable {
  case folder(UUID)
  case repository(Repository.ID)
}
```

### Persistence (RepositoryPersistenceClient)
Add:
- `loadFolders / saveFolders: [SidebarFolder]`
- `loadSidebarRootOrder / saveSidebarRootOrder: [SidebarRootItemID]`
- `loadCollapsedFolderIDs / saveCollapsedFolderIDs: [UUID]`

Use `@Shared(.appStorage("sidebarFolders"))`, `@Shared(.appStorage("sidebarRootOrder"))`, `@Shared(.appStorage("collapsedFolderIDs"))`. Codable → JSON.

### Actions
- `case folderCreated(name: String)` → append new folder to `sidebarRootOrder`
- `case folderRenamed(UUID, String)`
- `case folderDeleted(UUID)` → repos inside move to root, preserving order
- `case folderCollapseToggled(UUID)`
- `case repositoryMovedToFolder(Repository.ID, folderID: UUID?, destinationIndex: Int)`
  - `folderID == nil` means root-level.
- `case sidebarRootReordered(IndexSet, Int)` (replaces/augments `repositoriesMoved`)
- `case folderContentsReordered(UUID, IndexSet, Int)`
- `case sidebarSearchQueryChanged(String)`
- `case focusSidebarSearch`  — sent from ⌘K

Persist each mutation via effect (match existing `saveRepositoryOrderIDs` pattern).

### View changes

1. **SidebarView.swift** — add `SidebarSearchField` above `SidebarListView`.
2. **SidebarSearchField.swift** (new) — `TextField` with magnifying-glass icon and `.focused` binding controlled by a `focusSidebarSearch` focused-scene-value / publisher. Submit label set to search; Esc clears.
3. **SidebarListView.swift**
   - Drive the outer `ForEach` off `sidebarRootOrder` instead of `orderedRoots` directly.
   - When an item is `.folder`, render a new `SidebarFolderSectionView` (DisclosureGroup-backed Section).
   - When `.repository`, render existing `SidebarRepositorySectionView`.
   - Filter the tree against `sidebarSearchQuery` (case-insensitive match on folder name, repo name, worktree branch+title+path). When query is non-empty, force-expand any folder with matches and any repo with matching worktrees. Hide everything that doesn't match.
   - Keep drag-to-reorder: `.onMove` on root `ForEach` + drag-and-drop between folders using `.dropDestination(for: Repository.ID.self)` on folder sections.
4. **SidebarFolderSectionView.swift** (new) — section header with folder icon, name (inline rename via double-click or context menu), disclosure caret, trailing ellipsis menu (Rename…, Delete, New Folder).
5. **RepoSectionHeaderView** — add a "Move to Folder…" context-menu item driving `repositoryMovedToFolder`.

### Commands / Shortcuts

- Add `AppShortcutID.sidebarSearch` (default: ⌘K) in `AppShortcuts.swift`.
- `SidebarCommands.swift` → add "Search Sidebar" menu item that sends `.focusSidebarSearch` via a focused-scene action key, with ⌘K binding.
- `AppFeature` dispatches `focusSidebarSearch` to a publisher/focused action that the `SidebarSearchField` observes.
- Add `AppShortcutID.newSidebarFolder` (no default) + menu item "New Folder" in SidebarCommands.

### Tests (supacodeTests)

Create `RepositoriesFeatureFoldersTests.swift`:
- Create folder, move repo in, persistence saves are invoked.
- Rename / delete folder (repos fall back to root).
- Reorder root / reorder within folder.
- Search filter: folder containing a matching repo is not hidden; non-matching repo is hidden.
- `focusSidebarSearch` action toggles focus state (test via delegate/effect).

Use `TestClock` where time is involved; never `Task.sleep`.

## Out of scope

- Nested folders.
- Folder colors/icons.
- Migration UI — quietly keep legacy `repositoryOrderIDs` working; new state layers on top.
- Changing CommandPalette behavior.

## Implementation order (tracer bullets)

1. Add models + shared persistence (no UI) + tests that folders/root-order round-trip.
2. Render root order as mix of folders/repos in sidebar (no create/delete UI yet; seed programmatically in a preview/test).
3. Folder CRUD UI + context menus + drag repos into folders.
4. Sidebar search field + filter logic + ⌘K shortcut.
5. Polish: rename inline, Move-to-Folder context menu, empty-folder placeholder.

Commit after each step.
