import Dependencies
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

nonisolated private let migrationLogger = SupaLogger("Layouts")

/// One worktree's persisted layout plus the write-once pre-migration original.
nonisolated struct LayoutRecord: Equatable, Codable, Sendable {
  var layout: PaneLayout
  /// The v1 snapshot verbatim, written once at migration and never read by the
  /// app; enables rollback tooling.
  let origin: TerminalLayoutSnapshot?

  private enum CodingKeys: String, CodingKey {
    case layout
    case origin
  }

  init(layout: PaneLayout, origin: TerminalLayoutSnapshot? = nil) {
    self.layout = layout
    self.origin = origin
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    layout = try container.decode(PaneLayout.self, forKey: .layout)
    // `try?` so origin rot never fails this record's decode outright.
    origin =
      (try? container.decodeIfPresent(TerminalLayoutSnapshot.self, forKey: .origin)) ?? nil
    // A present, non-null origin that failed to decode still owns surface ids
    // nothing else references, so it counts as decode loss: the file reads as
    // lossy instead of being rewritten (or reaped) without it.
    guard origin == nil, container.contains(.origin), (try? container.decodeNil(forKey: .origin)) != true
    else { return }
    migrationLogger.error("Dropped an unreadable migration origin; treating the layouts as lossy.")
    (decoder.userInfo[.layoutDecodeLoss] as? LayoutDecodeLoss)?.droppedCount += 1
  }
}

/// The v2 layouts shape: a version stamp over per-worktree records. Legacy:
/// decoded only to be mapped into `TaskLayoutsFile`; never written by the app.
nonisolated struct LayoutsFile: Equatable, Codable, Sendable {
  static let currentSchemaVersion = 2

  var schemaVersion: Int
  var worktrees: [String: LayoutRecord]
  /// Worktree entries or tabs the tolerant decode dropped; never encoded. A
  /// non-zero count marks the value as lossy, so readers and writers reject it.
  var undecodedEntryCount = 0

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case worktrees
  }

  init(schemaVersion: Int = LayoutsFile.currentSchemaVersion, worktrees: [String: LayoutRecord]) {
    self.schemaVersion = schemaVersion
    self.worktrees = worktrees
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    // Element-wise so one rotten worktree entry drops that entry, not the file.
    let raw = try container.decode([String: FailableDecodable<LayoutRecord>].self, forKey: .worktrees)
    worktrees = raw.compactMapValues(\.value)
    // A dropped entry loses its session references to the orphan reaper; the
    // loss must at least be diagnosable.
    let dropped = raw.keys.filter { worktrees[$0] == nil }
    if !dropped.isEmpty {
      migrationLogger.error("Dropped unreadable layout entries: \(dropped.sorted())")
    }
    // Fold in content the nested decode dropped (a lost tab or a duplicate pane):
    // a record can decode while silently losing content, which must read as lossy.
    let droppedContent = (decoder.userInfo[.layoutDecodeLoss] as? LayoutDecodeLoss)?.droppedCount ?? 0
    undecodedEntryCount = dropped.count + droppedContent
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(worktrees, forKey: .worktrees)
  }
}

nonisolated extension LayoutsFile {
  /// UserDefaults key holding the encoded layouts (v3 `TaskLayoutsFile`, or a
  /// v2 `LayoutsFile` not upgraded yet). Layouts are internal state, not a
  /// user-editable file.
  static let userDefaultsKey = "layoutsFile"

  /// Sibling key holding the last v2 blob verbatim, written once before the
  /// first v3 write.
  static let preTasksBackupKey = userDefaultsKey + ".pre-tasks.bak"

  /// Sibling key holding the last unsplit blob verbatim (v2, or v3 with one
  /// task per directory), written once before the task split replaces it.
  static let preSplitBackupKey = userDefaultsKey + ".pre-task-split.bak"

  /// Every session identity persisted anywhere in the file, including the
  /// write-once v1 origin, so the orphan reaper can never kill a session a
  /// dropped or not-yet-migrated record still owns.
  var allKnownSurfaceIDs: Set<UUID> {
    var ids: Set<UUID> = []
    for record in worktrees.values {
      ids.formUnion(record.layout.allContentIDs.map(\.rawValue))
      if let origin = record.origin {
        ids.formUnion(origin.allSurfaceIDs)
      }
    }
    return ids
  }
}

nonisolated extension TaskRecord {
  /// `createdAt` of a task mapped from a v2 record, which never stored one.
  /// Fixed so the mapping is pure and a re-read equals the previous read.
  static let legacyCreatedAt = Date(timeIntervalSinceReferenceDate: 0)
}

nonisolated extension TaskLayoutsFile {
  /// A v2 file mapped 1:1: each directory's record becomes one task under its
  /// legacy id, its origin moves to `origins`. No tab moves.
  init(oneTaskPerDirectory file: LayoutsFile) {
    self.init()
    tasksSplit = false
    undecodedEntryCount = file.undecodedEntryCount
    for (key, record) in file.worktrees {
      tasks[key] = TaskRecord(
        id: LayoutID(legacyWorktreeKey: key),
        directory: LayoutsTaskSplitter.directory(forLegacyKey: key),
        layout: record.layout,
        createdAt: TaskRecord.legacyCreatedAt
      )
      if let origin = record.origin {
        origins[key] = origin
      }
    }
  }

  /// What a launch-time read of the persisted layouts found. `.absent` is a fresh
  /// start; `.unreadable` means bytes exist but could not be decoded, so a
  /// caller must never treat the store as empty (the orphan reaper would
  /// sweep every detached session).
  enum DiskState {
    case file(TaskLayoutsFile)
    case absent
    case unreadable
  }

  /// What a persisted blob holds. `.legacy` is a v2 (or v1) blob mapped in
  /// memory: usable, but the bytes must be backed up before v3 replaces them.
  enum PersistedBlob {
    case tasks(TaskLayoutsFile)
    case legacy(TaskLayoutsFile)
    case newer(Int)
    /// Decodes, but dropped an entry or a tab; never authoritative.
    case lossy
    case undecodable
  }

  private struct SchemaStamp: Decodable {
    let schemaVersion: Int
  }

  /// Reads and decodes the persisted layouts from UserDefaults. Before the store
  /// is seeded, falls back to the legacy `layouts.json` so a present-but-unreadable
  /// legacy file never reads as `.absent` (which would let the orphan reaper sweep
  /// every detached session). The decode guards schema and lossiness.
  static func readPersisted(from store: UserDefaults) -> DiskState {
    guard let data = store.data(forKey: LayoutsFile.userDefaultsKey) else { return readFromDisk() }
    return diskState(from: data)
  }

  /// Reads and decodes a legacy `layouts.json` (v2, or a still-v1 file from a
  /// deferred migration) mapped in memory, so readers see the real records
  /// while the on-disk bytes survive.
  static func readFromDisk(url: URL = SupacodePaths.legacyLayoutsURL) -> DiskState {
    @Dependency(\.settingsFileStorage) var storage
    let data: Data
    do {
      data = try storage.load(url)
    } catch {
      guard LayoutsIncrementalWriter.isFileAbsent(error) else {
        migrationLogger.error("layouts.json unreadable: \(error)")
        return .unreadable
      }
      return .absent
    }
    return diskState(from: data)
  }

  private static func diskState(from data: Data) -> DiskState {
    switch classify(data) {
    case .tasks(let file), .legacy(let file):
      return .file(file)
    case .newer(let version):
      // A newer build's blob decodes partially here, so a downgrade must not
      // treat it as authoritative and reap.
      migrationLogger.error(
        "Layouts schema v\(version) is newer than v\(currentSchemaVersion); treating as unreadable.")
      return .unreadable
    case .lossy:
      // A tolerant decode that dropped entries or tabs leaves `allKnownSurfaceIDs`
      // incomplete; the orphan reaper would then kill sessions the dropped
      // records still own.
      migrationLogger.error("Persisted layouts dropped entries on decode; treating as unreadable.")
      return .unreadable
    case .undecodable:
      migrationLogger.error("Persisted layouts are neither v3, v2 nor v1; treating as unreadable.")
      return .unreadable
    }
  }

  /// Shared decode for every reader and the writer: v3, else v2 or v1 mapped
  /// one task per directory.
  static func classify(_ data: Data) -> PersistedBlob {
    let decoder = JSONDecoder()
    decoder.userInfo[.layoutDecodeLoss] = LayoutDecodeLoss()
    if let stamp = try? JSONDecoder().decode(SchemaStamp.self, from: data),
      stamp.schemaVersion >= currentSchemaVersion
    {
      guard stamp.schemaVersion == currentSchemaVersion else { return .newer(stamp.schemaVersion) }
      guard let file = try? decoder.decode(TaskLayoutsFile.self, from: data) else { return .undecodable }
      return file.undecodedEntryCount == 0 ? .tasks(file) : .lossy
    }
    if let file = try? decoder.decode(LayoutsFile.self, from: data) {
      guard file.undecodedEntryCount == 0 else { return .lossy }
      return .legacy(TaskLayoutsFile(oneTaskPerDirectory: file))
    }
    guard
      let raw = try? JSONDecoder().decode(
        [String: FailableDecodable<TerminalLayoutSnapshot>].self, from: data
      )
    else { return .undecodable }
    let legacy = raw.compactMapValues(\.value)
    // Any dropped v1 entry leaves its detached sessions unreferenced, so a
    // partial decode is lossy, never empty.
    guard legacy.count == raw.count else { return .lossy }
    return .legacy(TaskLayoutsFile(oneTaskPerDirectory: LayoutsMigrator.migrate(legacy)))
  }
}

nonisolated extension PaneLayout {
  /// `(surfaceID, agents)` for every terminal content carrying agent records;
  /// drives the launch-time agent-presence restore.
  func allAgentRecords() -> [(surfaceID: UUID, records: [TerminalLayoutSnapshot.SurfaceAgentRecord])] {
    panes.flatMap { pane in
      pane.tabs.compactMap { tab in
        guard case .terminal(let state) = tab.content.state,
          let agents = state.agents, !agents.isEmpty
        else { return nil }
        return (tab.content.id.rawValue, agents)
      }
    }
  }
}

/// Transforms v1 layouts (splits-per-tab) into the v2 pane topology.
///
/// Mapping rule: the selected tab's split tree becomes the pane arrangement,
/// one pane per leaf; every other tab lands in the pane of the selected tab's
/// focused leaf; a multi-leaf non-selected tab fans its leaves into adjacent
/// tabs. The old tab's ID stays on the tab at its focused leaf; fanned
/// siblings mint their content's UUID as tab ID, re-establishing the
/// documented initial-surface-equals-tab-ID invariant. No content is dropped.
nonisolated enum LayoutsMigrator {
  /// A migrated worktree; `nil` layout output never happens, empty input maps
  /// to an empty record.
  static func migrate(_ snapshot: TerminalLayoutSnapshot) -> LayoutRecord {
    var builder = Builder()
    let tabs = snapshot.tabs
    guard !tabs.isEmpty else {
      return LayoutRecord(layout: PaneLayout(), origin: snapshot)
    }
    let selectedIndex = max(0, min(snapshot.selectedTabIndex, tabs.count - 1))
    let selected = tabs[selectedIndex]
    // Old tab IDs commonly equal their initial leaf's surface UUID; reserve
    // them so a fanned sibling cannot claim an identity leaf's ID first.
    builder.reservedTabIDs = Set(tabs.compactMap(\.id))

    // The selected tab's split tree becomes the pane arrangement.
    let tree = builder.buildTree(from: selected.layout)
    let selectedLeaves = selected.layout.leaves
    let focusedLeafIndex = max(0, min(selected.focusedLeafIndex, selectedLeaves.count - 1))
    for (index, leaf) in selectedLeaves.enumerated() {
      let carriesTabIdentity = index == focusedLeafIndex
      builder.appendTab(
        toPaneAt: index,
        Self.tabItem(
          from: leaf,
          tab: selected,
          carriesTabIdentity: carriesTabIdentity,
          builder: &builder
        )
      )
    }
    let homePaneIndex = focusedLeafIndex

    // Every other tab lands in the focused leaf's pane, in tab order; fanned
    // leaves of a multi-leaf tab stay adjacent, its focused leaf carrying the
    // tab identity.
    for (index, tab) in tabs.enumerated() where index != selectedIndex {
      let leaves = tab.layout.leaves
      let tabFocusedIndex = max(0, min(tab.focusedLeafIndex, leaves.count - 1))
      for (leafIndex, leaf) in leaves.enumerated() {
        builder.appendTab(
          toPaneAt: homePaneIndex,
          Self.tabItem(
            from: leaf,
            tab: tab,
            carriesTabIdentity: leafIndex == tabFocusedIndex,
            builder: &builder
          )
        )
      }
    }

    var panes = IdentifiedArrayOf<Pane>()
    for (index, paneID) in builder.paneIDs.enumerated() {
      let tabs = builder.tabsByPane[index] ?? []
      // Each pane's first tab is its own leaf's tab, so first-tab selection
      // keeps the selected tab selected in the home pane too.
      panes.append(
        Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs.first?.id)
      )
    }
    let layout = PaneLayout(
      tree: tree,
      panes: panes,
      focusedPaneID: builder.paneIDs.indices.contains(homePaneIndex)
        ? builder.paneIDs[homePaneIndex] : builder.paneIDs.first
    )
    return LayoutRecord(layout: layout, origin: snapshot)
  }

  /// Builds the v2 file from a v1 dictionary; every worktree keeps every
  /// content ID.
  ///
  /// Runner contract: gate each record on `layout.isConsistent` before serving
  /// it; compute the orphan reaper's known set as the union of
  /// `layout.allContentIDs` and `origin.allSurfaceIDs`; treat a file whose
  /// `schemaVersion` exceeds `currentSchemaVersion` as read-only.
  static func migrate(_ legacy: [String: TerminalLayoutSnapshot]) -> LayoutsFile {
    LayoutsFile(worktrees: legacy.mapValues { migrate($0) })
  }

  private static func tabItem(
    from leaf: TerminalLayoutSnapshot.SurfaceSnapshot,
    tab: TerminalLayoutSnapshot.TabSnapshot,
    carriesTabIdentity: Bool,
    builder: inout Builder
  ) -> TabItem {
    let contentUUID = leaf.id ?? UUID()
    let content = ContentSnapshot(
      id: ContentID(rawValue: contentUUID),
      state: .terminal(
        TerminalContentState(
          workingDirectory: leaf.workingDirectory,
          agents: leaf.agents
        )
      )
    )
    // The identity-carrying tab keeps the old tab's ID and full metadata;
    // fanned siblings mint their content UUID and inherit only presentation,
    // never the custom title. A sibling may not claim a reserved old tab ID:
    // tab IDs commonly equal the initial leaf's surface UUID, and identity
    // must not be stolen by leaf order.
    let requestedID = carriesTabIdentity ? (tab.id ?? contentUUID) : contentUUID
    let isTaken =
      builder.usedTabIDs.contains(requestedID)
      || (!carriesTabIdentity && builder.reservedTabIDs.contains(requestedID))
    let tabID = isTaken ? UUID() : requestedID
    if isTaken {
      migrationLogger.warning(
        "Reminted migrated tab ID \(requestedID) -> \(tabID) (identity: \(carriesTabIdentity))"
      )
    }
    builder.usedTabIDs.insert(tabID)
    return TabItem(
      id: TabID(rawValue: tabID),
      title: tab.title,
      customTitle: carriesTabIdentity ? tab.customTitle : nil,
      icon: tab.icon,
      tintColor: tab.tintColor,
      content: content
    )
  }

  /// Accumulates panes while the selected tab's tree is mirrored.
  private struct Builder {
    var paneIDs: [PaneID] = []
    var tabsByPane: [Int: [TabItem]] = [:]
    var usedTabIDs: Set<UUID> = []
    var reservedTabIDs: Set<UUID> = []

    mutating func appendTab(toPaneAt index: Int, _ tab: TabItem) {
      tabsByPane[index, default: []].append(tab)
    }

    /// Mirrors the v1 layout node into a tree of freshly minted pane IDs,
    /// leaves in traversal order.
    mutating func buildTree(from node: TerminalLayoutSnapshot.LayoutNode) -> SplitTree<PaneID> {
      SplitTree(root: buildNode(from: node))
    }

    private mutating func buildNode(
      from node: TerminalLayoutSnapshot.LayoutNode
    ) -> SplitTree<PaneID>.Node {
      switch node {
      case .leaf:
        let paneID = PaneID()
        paneIDs.append(paneID)
        return .leaf(view: paneID)
      case .split(let split):
        let left = buildNode(from: split.left)
        let right = buildNode(from: split.right)
        let direction: SplitTree<PaneID>.Direction =
          switch split.direction {
          case .horizontal: .horizontal
          case .vertical: .vertical
          }
        return .split(
          SplitTree<PaneID>.Split(
            direction: direction,
            ratio: split.ratio,
            left: left,
            right: right
          )
        )
      }
    }
  }
}

nonisolated extension TerminalLayoutSnapshot.LayoutNode {
  /// Leaves in traversal order, matching `leafSurfaceIDs`.
  fileprivate var leaves: [TerminalLayoutSnapshot.SurfaceSnapshot] {
    switch self {
    case .leaf(let surface):
      return [surface]
    case .split(let split):
      return split.left.leaves + split.right.leaves
    }
  }
}

nonisolated extension LayoutsMigrator {
  /// Presence of the stamp means v2 or newer; such files are never rewritten
  /// here (newer schemas are read-only for this build).
  private struct SchemaStamp: Decodable {
    let schemaVersion: Int
  }

  /// Rewrites a v1 layouts.json into the v2 pane topology, exactly once,
  /// before hydration. The v1 original is backed up create-if-absent first;
  /// a failed backup defers the whole migration to the next launch.
  static func migrateFileIfNeeded(
    url: URL = SupacodePaths.layoutsURL,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
  ) {
    @Dependency(\.settingsFileStorage) var storage
    let data: Data
    do {
      data = try storage.load(url)
    } catch {
      // A fresh install has no file; anything else defers with a diagnostic.
      if !LayoutsIncrementalWriter.isFileAbsent(error) {
        migrationLogger.error("layouts.json unreadable, deferring migration: \(error)")
      }
      return
    }
    guard (try? JSONDecoder().decode(SchemaStamp.self, from: data)) == nil else { return }
    guard
      let raw = try? JSONDecoder().decode(
        [String: FailableDecodable<TerminalLayoutSnapshot>].self, from: data
      )
    else {
      migrationLogger.error("layouts.json is neither stamped v2 nor readable v1; leaving it untouched.")
      return
    }
    // Element-wise so one rotten entry cannot strand the whole file on v1;
    // the dropped entry survives only in the backup.
    let legacy = raw.compactMapValues(\.value)
    let dropped = raw.keys.filter { legacy[$0] == nil }
    if !dropped.isEmpty {
      migrationLogger.error("Migration drops unreadable v1 entries: \(dropped.sorted())")
    }
    // Defer whenever any v1 entry fails to decode: migrating the readable ones
    // would drop the rotten record's session references and let the launch
    // reaper kill them. The untouched file retries on the next launch.
    guard legacy.count == raw.count else {
      migrationLogger.error("\(dropped.count) v1 entrie(s) unreadable; deferring migration.")
      return
    }
    let backupURL = url.appendingPathExtension("pre-tabs-per-split.bak")
    if !fileExists(backupURL) {
      do {
        try storage.save(data, backupURL)
      } catch {
        migrationLogger.error("Backing up v1 layouts failed, deferring migration: \(error)")
        return
      }
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try storage.save(try encoder.encode(migrate(legacy)), url)
      migrationLogger.info("Migrated layouts.json to schema v\(LayoutsFile.currentSchemaVersion).")
    } catch {
      // The v1 file is untouched; the next launch retries.
      migrationLogger.error("Writing migrated layouts failed: \(error)")
    }
  }
}

nonisolated extension LayoutsMigrator {
  /// Upgrades the persisted layouts before hydration, once each: a v2 blob
  /// becomes v3, and an unsplit store (v2, or v3 written before the split) has
  /// every agent tab moved into its own task. The bytes about to be replaced
  /// are backed up first. A lossy, newer or undecodable blob is left untouched
  /// and retried next launch. A split that fails its integrity check is not
  /// written: the store stays unsplit (a v2 blob still upgrades one task per
  /// directory) and the split is retried next launch.
  static func migrateStoreToTasksIfNeeded(
    defaults: UserDefaults,
    now: Date = Date(),
    makeUUID: () -> UUID = { UUID() },
    split: ((TaskLayoutsFile) -> TaskLayoutsFile)? = nil
  ) {
    let store = LayoutsUserDefaultsStore(defaults: defaults)
    guard let data = store.read() else { return }
    switch TaskLayoutsFile.classify(data) {
    case .newer, .lossy, .undecodable:
      migrationLogger.error("Persisted layouts not cleanly readable; deferring the v3 upgrade.")
    case .tasks(let file):
      guard !file.tasksSplit else { return }
      guard let encoded = verifiedSplit(of: file, now: now, makeUUID: makeUUID, split: split) else { return }
      guard store.backUpUnsplitIfAbsent(data) else {
        migrationLogger.error("Backing up the unsplit layouts failed; leaving them in place.")
        return
      }
      store.write(encoded)
      migrationLogger.info("Split persisted layouts into tasks.")
    case .legacy(let file):
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let splitEncoded = verifiedSplit(of: file, now: now, makeUUID: makeUUID, split: split)
      guard let encoded = splitEncoded ?? (try? encoder.encode(file)) else {
        migrationLogger.error("Encoding v3 layouts failed; leaving v2 in place.")
        return
      }
      guard store.backUpLegacyIfAbsent(data), splitEncoded == nil || store.backUpUnsplitIfAbsent(data) else {
        migrationLogger.error("Backing up the v2 layouts failed; leaving v2 in place.")
        return
      }
      store.write(encoded)
      migrationLogger.info("Upgraded persisted layouts to schema v\(TaskLayoutsFile.currentSchemaVersion).")
    }
  }

  /// The encoded split of `file`, or nil when the split cannot be proved
  /// lossless. Checked on the value that would be written, read back through
  /// the same decode every reader uses.
  private static func verifiedSplit(
    of file: TaskLayoutsFile,
    now: Date,
    makeUUID: () -> UUID,
    split: ((TaskLayoutsFile) -> TaskLayoutsFile)?
  ) -> Data? {
    let result = split?(file) ?? LayoutsTaskSplitter.split(file, now: now, makeUUID: makeUUID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let encoded = try? encoder.encode(result),
      case .tasks(let written) = TaskLayoutsFile.classify(encoded)
    else {
      migrationLogger.error("Split layouts do not read back; keeping the unsplit store.")
      return nil
    }
    if let failure = splitIntegrityFailure(from: file, to: written) {
      migrationLogger.error("Split layouts failed the integrity check (\(failure)); keeping the unsplit store.")
      return nil
    }
    return encoded
  }

  /// Why `split` is not a lossless regrouping of `source`, or nil when it is:
  /// same tabs with the same content (ids are compared as multisets, so a
  /// duplicated tab fails too), same origins, same reaper and presence-restore
  /// coverage, and no directory resolving to a task that does not exist or
  /// sits on another directory.
  static func splitIntegrityFailure(from source: TaskLayoutsFile, to split: TaskLayoutsFile) -> String? {
    func tabs(_ file: TaskLayoutsFile) -> [TabItem] {
      file.tasks.values
        .flatMap { $0.layout.panes.flatMap(\.tabs) }
        .sorted {
          ($0.id.rawValue.uuidString, $0.content.id.rawValue.uuidString) < (
            $1.id.rawValue.uuidString, $1.content.id.rawValue.uuidString
          )
        }
    }
    func agentSurfaces(_ file: TaskLayoutsFile) -> Set<UUID> {
      Set(file.tasks.values.flatMap { $0.layout.allAgentRecords().map(\.surfaceID) })
    }
    guard split.tasksSplit, split.undecodedEntryCount == 0 else { return "not a clean split file" }
    guard tabs(split) == tabs(source) else { return "tabs differ" }
    guard split.origins == source.origins else { return "origins differ" }
    guard split.allKnownSurfaceIDs == source.allKnownSurfaceIDs else { return "known surfaces differ" }
    guard agentSurfaces(split) == agentSurfaces(source) else { return "agent surfaces differ" }
    guard split.tasks.allSatisfy({ $0.key == $0.value.id.persistenceKey }) else {
      return "task stored under another id"
    }
    guard split.activeTasks.values.allSatisfy({ split.tasks[$0] != nil }) else { return "active task missing" }
    // Hydration ignores an entry naming another directory's task.
    guard
      split.activeTasks.allSatisfy({ LayoutsTaskSplitter.isTask($0.value, in: split, onDirectory: $0.key) })
    else { return "active task on another directory" }
    // A directory that had tabs under its own key must still resolve to a
    // task. One with none yields no task, which is not a loss.
    for (key, record) in source.tasks where record.directory.worktreeID.rawValue == key {
      guard record.layout.panes.contains(where: { !$0.tabs.isEmpty }) else { continue }
      guard LayoutsTaskSplitter.isTask(split.activeTasks[key] ?? key, in: split, onDirectory: key) else {
        return "directory left without a task"
      }
    }
    return nil
  }
}
