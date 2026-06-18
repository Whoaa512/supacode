# Re-implement sidebar folders (repo grouping) on upstream SidebarStructure

Dropped during the 2026-06-16 upstream sync. The fork's original commits
(`b54322c9` model+reducer, `c5785b60` rendering, `9cef9dff` tests) targeted the
pre-refactor sidebar view path (`SidebarRootView` / `displayItems`), which
upstream deleted when it rebuilt rendering around `SidebarStructure` +
`SidebarSectionDispatcher` (#323/#324/#328).

## Naming collision to resolve first
Upstream already uses `SidebarStructure.Section.folder(repositoryID:, rowID:)`
for a **non-git directory opened as a repo** (single synthesized worktree). The
fork's feature is **user-created groups holding multiple repos**. Pick a
distinct term (e.g. `group` / `collection`) to avoid clashing with upstream's
folder-repository concept.

## Scope to port
- `SidebarFolder` model + persistence (rootOrder / folders / collapsed state)
- Reducer actions: create/rename/delete group, move repo to group, collapse
- Rendering: group sections woven into `SidebarStructure.sections` +
  `SidebarSectionDispatcher`, not the old `SidebarRootView` ForEach
- Sidebar search field (`SidebarSearchField`, Cmd-K) + `repositoryMatchesSearch`
- Drag/reorder across groups via the structure's `reorderableRepositoryIDs`
- Tests (`RepositoriesFeatureFoldersTests`)

Original commits recoverable from tag `cj-main-pre-rebase-2026-06-16`.
