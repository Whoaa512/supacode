# Full-text search across all terminal surfaces

Goal: cmd-something from anywhere → type query → ranked list of hits across every
surface in every worktree → select one → jump to worktree+tab+surface and (ideally)
scroll to the match.

## The corpus already exists (good news)

Two sources, both already wired:

1. **Live surfaces (in-memory)** — `ghostty_surface_read_text` with a SCREEN-tagged
   selection dumps the full screen + scrollback as plain UTF-8.
   - Already used in `GhosttySurfaceView.readScreenContents()`
   - Zero escape codes, cheap, always current
   - Per surface, on-demand

2. **`.vt` dump files on disk** — `~/.supacode/scrollback/<surfaceID>.vt`
   - Written by `WorktreeTerminalState.saveScrollbackFiles()` during
     `saveAllLayoutSnapshots()` (quit / layout save)
   - VT format → contains ANSI escape sequences (colors, cursor moves). Needs a
     strip pass before indexing.
   - Covers past surfaces we aren't holding in memory after a restart (if any —
     unclear if we restore them all).

For the MVP: **source 1 is enough**. Every surface the user cares about is in a
running worktree state. Dump → index → search on demand. No persistent index.

## Topology we need to walk

```
WorktreeTerminalManager.states: [Worktree.ID: WorktreeTerminalState]
  WorktreeTerminalState
    tabManager.tabs: [TerminalTabItem]
    surfaces: [UUID: GhosttySurfaceView]   // the actual corpus holders
    tabId(containing: UUID) -> TerminalTabID
    focusSurface(id: UUID) -> Bool          // <- the jump primitive
```

So each hit is `(worktreeID, tabID, surfaceID, line, matchedText)`. Jumping is:
`manager.selectedWorktreeID = wid` → `state.focusSurface(id: sid)`.

## Do we need Rust?

**No.** Not for MVP.

- Corpus size: worst case a few dozen surfaces × a few thousand scrollback lines × ~100 chars
  ≈ low single-digit MB of text. Swift with `String.range(of:options:)` or
  `NSRegularExpression` over this is well under 50ms.
- No persistence / no index rebuilds / no background daemon. Dump-and-scan on
  palette open is fine.
- If we later want fuzzy ranking, `CommandPaletteFeature` already has a ranking
  pattern we can steal.
- Plugging in a binary (ripgrep, tantivy CLI, fzf) is easy later: write text to a
  temp dir keyed by surfaceID, `rg --json -F <query> <dir>`, parse. But it's
  extra process/IO overhead for a problem Swift solves natively.

Decision: **grug mode, pure Swift first.** Revisit if profile proves otherwise.

If we do want Rust later, the cleanest plug point is a sidecar binary in `bins/`
(same pattern as `git-wt`) that takes a dir of text files + query on stdin and
returns JSONL hits. The rest of this design doesn't care which engine is
under the hood.

## Shape of the feature

### 1. Corpus snapshotter
New file: `supacode/Features/TerminalSearch/TerminalSearchCorpus.swift`

```swift
struct TerminalSearchDocument {
  let worktreeID: Worktree.ID
  let tabID: TerminalTabID
  let surfaceID: UUID
  let worktreeLabel: String      // branch / repo for UI
  let tabTitle: String
  let text: String               // from ghostty_surface_read_text
}
```

Method on `WorktreeTerminalManager` (or a thin helper):
`func snapshotAllSurfaces() -> [TerminalSearchDocument]` — iterates
`states` → each state's `surfaces` → calls `surface.readScreenContents()`.
All @MainActor, synchronous, fast. Call once when the palette opens.

### 2. Search engine (Swift)
`TerminalSearchEngine.search(query:, in: [TerminalSearchDocument]) -> [Hit]`
- case-insensitive literal by default
- optional regex mode (prefix `/...`)
- split text on `\n`, keep line number + ~40 chars of context each side
- dedup noisy repeats (e.g. TUI redraws) by line + surface

```swift
struct TerminalSearchHit {
  let documentID: UUID           // surfaceID
  let worktreeID: Worktree.ID
  let tabID: TerminalTabID
  let line: Int
  let snippet: AttributedString  // match highlighted
  let worktreeLabel: String
  let tabTitle: String
}
```

### 3. UI (reuse command palette chrome)
New TCA feature `TerminalSearchFeature` that mirrors `CommandPaletteFeature`:
- global hotkey (e.g. `⌘⇧F`)
- search field + grouped results (by worktree → tab)
- selection → emits action that the root app handles:
  1. `terminalClient.send(.selectWorktree(wid))` (or equivalent — already exists
     for worktree switching)
  2. `terminalClient.send(.focusSurface(sid))` — new command, wraps
     `state.selectTab(tabID)` + `state.focusSurface(id: sid)`
  3. (stretch) `terminalClient.send(.scrollToLine(sid, line))` — need a new
     Ghostty binding action or API call; see open question below.

### 4. Jump-to-match (the tricky bit)
`focusSurface` lands us in the right place but leaves the user to scroll. Two
options:

a. **Cheap MVP: trigger in-surface search.** After focusing, send a
   `GHOSTTY_ACTION_START_SEARCH` with the query pre-filled (see
   `ghostty_action_start_search_s.needle`). User sees native highlight and next/prev.
   Zero new scroll logic. Likely the right call.

b. **Scroll to exact line.** Convert our line number to a `ghostty_point_s` and
   call a scroll-to-point binding. Ghostty has scroll_to_* commands; needs
   verification. More plumbing, nicer UX.

Recommend (a) for MVP, keep (b) as a follow-up.

## Open questions

1. Does `.vt` scrollback need to be indexed too? Only matters if a surface
   isn't currently running but the user wants to search it. Check whether we
   reload scrollback into fresh surfaces on launch — if yes, source 1 covers it.
2. Do we want to cache the corpus for N seconds to avoid dumping on every
   keystroke? Probably yes — debounce queries, snapshot once per palette open.
3. Regex vs literal vs fuzzy — start with case-insensitive literal,
   regex via `/` prefix, add fuzzy only if asked.
4. Should closed-but-recent surfaces be searchable? Requires retaining text
   after `closeSurface`. Out of scope for v1.

## Minimal implementation order

1. `snapshotAllSurfaces()` on the manager (pure read, no state change)
2. Tiny Swift `TerminalSearchEngine` + tests (literal + regex, line snippets)
3. TCA feature + view, hotkey
4. Wire selection → switch worktree + `focusSurface` + native in-surface
   search with the prefilled needle
5. Polish: debounce, grouping, empty states, no-match shake

Stretch: swap the engine for a Rust sidecar if profile shows it matters, or
persist an index of closed surfaces.

## Files to touch

- `supacode/Features/TerminalSearch/...` (new feature)
- `supacode/Clients/Terminal/TerminalClient.swift` (add `focusSurface`,
  `snapshotSurfaces` commands)
- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
  (expose `snapshotAllSurfaces`, `focus(surfaceID: worktreeID:)`)
- `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
  (expose iterating surfaces publicly — already mostly there)
- `supacode/Features/App/AppFeature.swift` (hotkey + wiring)
- `SupacodeSettingsFeature` shortcuts (new shortcut)
- Tests: `supacodeTests/TerminalSearchEngineTests.swift`

## TL;DR

Live scrollback is already a C call away (`ghostty_surface_read_text`),
`.vt` dumps already exist on disk, and we already know how to focus an
arbitrary surface. Ship it in Swift first. Rust/sidecar only if measurement
demands it.
