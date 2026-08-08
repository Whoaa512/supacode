# Task Inbox — Keyboard Context Map (A31 gate)

**Status: reviewed and shipped.** This was Phase 6 deliverable 1, written as a
review request. cj signed off on §4; every item — including the three that were
**NEEDS-CJ** — is now implemented, and each §4 heading records the decision that
shipped rather than the recommendation that was made. The review-request framing
is kept because §1–§2 are the observed *before* picture, which is what makes the
§5 regression inventory legible; §2.3 is now shipped behaviour, not a proposal.

Everything in §1–§2 is **observed reality on branch `task-inbox-sidebar`**, with
file:line. Where a claim is inferred rather than read, it is labelled
`[INFERRED — verify in QA]`.

---

## 0. Corrections to the plan text before anything else

Two statements in `plans/task-inbox-sidebar-plan.md` do not match the code:

1. **A32 and the Phase 6 spec say "⌘1–9" for task slots. ⌘1–9 is already taken**
   — it is *terminal tab* selection (`AppShortcuts.selectTab1…9`,
   `AppShortcuts.swift:445-453`, driven by `TerminalTabSelectionCommands`,
   `supacode/Commands/TerminalCommands.swift:89-113`). The sidebar-row slot
   chord in both existing panels is **⌃1–9** (`selectWorktree1…9`,
   `AppShortcuts.swift:435-443`). Taking ⌘1–9 for tasks would break terminal tab
   switching. **Read A32 as ⌃1–9.**

2. **"Do NOT wedge task IDs into `HotkeyWorktreeSlot` — new slot type"** is the
   right instinct but overshoots. The Agents panel — the proven precedent — has
   **no slot struct at all**: `AgentDashboardStructure.slotByID:
   [AgentDashboardEntry.EntryID: Int]`
   (`BusinessLogic/AgentDashboardStructure.swift:207`) plus a reducer accessor
   `state.agentDashboardEntryID(atSlot:)`. `HotkeyWorktreeSlot`
   (`Commands/WorktreeCommands.swift:237`) only exists because the Worktrees
   panel needs `name` / `repositoryID` / `repositoryName` alongside the ID. Tasks
   need nothing but the ID. See §3.

---

## 1. Mechanisms — how a keystroke actually resolves today

Nine gates decide every cell in §2. Named here once so the matrix can be terse.

| # | Mechanism | Where | What it does |
|---|---|---|---|
| **M1** | **Ghostty unbind** | `AppShortcuts.swift:244` `ghosttyUnbindArgument`, `:595` `ghosttyCLIKeybindArguments`, applied at `supacodeApp.swift:18-31` | Every shortcut in `AppShortcuts.all` emits `--keybind=<chord>=unbind` into ghostty's argv. The chord is therefore **not** a ghostty binding, `bindingFlags(for:)` returns nil, and `performKeyEquivalent` falls through to the AppKit menu. **This is why app chords work while the terminal is focused, and it is automatic for any new `AppShortcut` added to a group.** |
| **M2** | **Ghostty first-responder gate** | `GhosttySurfaceView.swift:1137` `guard focused, window?.firstResponder === self` | The surface only claims a chord when AppKit says it *is* the first responder. A click into the sidebar releases every chord back to the menu even before `resignFirstResponder` lands. |
| **M3** | **Ghostty binding → menu forwarding** | `GhosttySurfaceView.swift:1146-1180`, `shouldAttemptMenu` `:1495`, `forwardableMenuItem` `:1453` | For a chord that *is* a ghostty binding: if the binding is `CONSUMED && !ALL && !PERFORMABLE`, and an **app-owned** (non-system-managed) menu item matches exactly, the menu item wins. Otherwise the terminal swallows it. Relevant to ⌃1–9 only (see M4). |
| **M4** | **⌃1–9 double life** | `AppShortcuts.swift:571-587` `tabSelectionGhosttyKeybindArguments` | `worktreeSelection` (⌃1–9) is unbound *and then re-bound* to ghostty `goto_tab:N` (plus a `ctrl+digit_N` layout alias). With a terminal focused, ⌃1 hits M3: the "Select Worktree 1" menu item exists and is app-owned, so the menu should win and `goto_tab` is the fallback. `[INFERRED — verify in QA that ⌃1 with a focused terminal moves the sidebar row, not the ghostty tab.]` |
| **M5** | **Menu-item disable** | e.g. `WorktreeCommands.swift:71` `.disabled(!capturesTask && !snapshot.canCreateWorktree)` | A disabled `NSMenuItem` does not fire its key equivalent. This is the *only* real "inert" mechanism for a ⌘-chord. |
| **M6** | **`FocusedAction` enablement** | `App/Models/FocusedAction.swift`, consumed as `.disabled(action?.isEnabled != true)` | Same effect as M5, but the enablement travels from the view that owns the target through `focusedSceneValue` / `focusedValue`. Equatable on `(isEnabled, token)` so the menu doesn't rebuild per body run. |
| **M7** | **Reducer tab switch** | `RepositoriesFeature.swift:3656-3679` (`selectWorktreeAtHotkeySlot`), `:3681-3711` (next/prev), `:3729`/`:3742` (history) | The chord **always fires**; the arm then switches on `state.activeSidebarTab` and either acts or `NSSound.beep()`s. Today `.tasks` beeps in all five arms. This is "fires, no-ops audibly" — not inert. |
| **M8** | **Sidebar type-ahead** | `SidebarListView.swift:84-100` | In the **Worktrees panel only**: any keypress that is not a nav key and carries no ⌘ is forwarded into the selected worktree's terminal via `focusAndInsertText`. **This is why an unmodified letter can never become a task shortcut** — in the Worktrees panel it is already someone's typing. |
| **M9** | **`SidebarRightArrowMonitor`** | `SidebarListView.swift:101-112`, monitor `:575-628` (commit `71dc4b57`) | Bare → with **zero** modifiers, window-scoped, gated on `@FocusState isSidebarFocused`, moves focus into the selected worktree's terminal. `NSOutlineView` eats arrows before SwiftUI `onKeyPress`, hence the AppKit monitor. **Only `SidebarListView` owns that `@FocusState`** — Tasks and Agents can never trigger it. |

### Focus reality (the uncomfortable part)

There is **no app-wide focus-context enum**. "Focus context" is three unrelated things:

- **Terminal focus** = AppKit first responder is a `GhosttySurfaceView`
  (`GhosttySurfaceView.swift:203, 635, 655`). Nothing publishes it into SwiftUI;
  consumers sniff the responder class
  (`WorktreeTerminalTabsView.swift:114-119`).
- **Sidebar-nav focus** = exactly one `@FocusState`, `SidebarListView.swift:11`.
  **`TasksSidebarView` and `AgentDashboardListView` have none.**
- **`FocusedValues`** are scene-wide, not region-wide. They gate menu items; they
  **cannot** distinguish sidebar focus from terminal focus.

Consequences that shape every recommendation below:

- (a) ⌘⇧A / ⌘⇧T swap the visible panel but **leave the first responder in the
  terminal** (`ContentView.swift:155,162` → `RepositoriesFeature.swift:3210,3224`).
  The freshly-revealed list is not arrow-navigable until clicked.
- (b) ⌘⇧E is the **only** chord today that moves focus *into* the sidebar
  (`SidebarListView.swift:180` sets `isSidebarFocused = true` off
  `pendingSidebarReveal`), and it is worktree-only — enabled at
  `ContentView.swift:146` on `selectedWorktreeID != nil`.
- (c) The Tasks panel has **zero** keyboard affordances of its own: no
  `@FocusState`, no `onKeyPress`, no Return activation, no → escape hatch. Its
  `List(selection:)` (`TasksSidebarView.swift:48`, binding `:136-145`) gives
  native ↑/↓ selection and nothing else.

---

## 2. The matrix

**Columns (focus context):**

- **T** — a Ghostty surface is first responder.
- **S** — sidebar list is first responder (`NSOutlineView`). *Tasks/Agents can
  reach this by clicking; only Worktrees tracks it in `@FocusState`.*
- **F** — a text field has focus (task-creation prompt field, rename sheet,
  branch filter, command-palette query).
- **H** — a sheet is up (`ContentView.swift:77-118`: deeplink confirm, worktree
  creation, **task creation**, directory conflict, repo/worktree customization,
  agent rename, rename branch) or the command palette panel is open
  (`CommandPalettePanel.swift:204`).
- **M** — an NSMenu is tracking (menu bar open, or a row's context menu open).

**Cell values:** `FIRES` · `INERT` (menu item disabled — M5/M6) · `BEEP` (fires,
tab-gated no-op — M7) · `→TERM` (forwarded to the terminal) · `N/A`.
Parenthesised code is the deciding mechanism.

### 2.1 Existing shortcuts — Tasks tab active

| Chord | Action (`AppShortcutID`) | T | S | F | H | M |
|---|---|---|---|---|---|---|
| ⌘N | `newWorktree` → **New Task** (`WorktreeCommands.swift:64-71`, `RepositoriesFeature.swift:~3786`) | FIRES (M1) | FIRES | FIRES (M1 — menu equivalents outrank a focused `NSTextField`) | FIRES → **second prompt over the first** ⚠️ (M5 doesn't gate it) | N/A (AppKit swallows during menu tracking) |
| ⌘⇧T | `toggleTasksSidebarTab` → switches to Worktrees | FIRES (M1); focus stays in terminal (a) | FIRES | FIRES | FIRES | N/A |
| ⌘⇧A | `toggleAgentsSidebarTab` | FIRES (M1) | FIRES | FIRES | FIRES | N/A |
| ⌃1–9 | `selectWorktreeAtHotkeySlot(n)` | BEEP (M4→M7) | BEEP (M7) | BEEP | BEEP | N/A |
| ⌃⌘↓ / ⌃⌘↑ | `selectNext/PreviousWorktree` | BEEP (M7 `:3688`,`:3706`) | BEEP | BEEP | BEEP | N/A |
| ⌃⌘← / ⌃⌘→ | `worktreeHistoryBack/Forward` | BEEP (M7 `:3729`,`:3742`) | BEEP | BEEP | BEEP | N/A |
| ↑ / ↓ (bare) | native List selection → `.tasks(.select)` | →TERM (surface owns it) | FIRES (`TasksSidebarView.swift:48`) | N/A (field editing) | N/A | N/A (menu nav) |
| → (bare) | escape hatch into terminal | →TERM | **NOTHING** ⚠️ (M9 is Worktrees-only) | N/A | N/A | N/A |
| ← (bare) | outline collapse | →TERM | FIRES (native, no-op on a flat list) | N/A | N/A | N/A |
| any letter (bare) | — | →TERM (surface) | **nothing** — M8 is Worktrees-only, so it is dropped | typed into field | typed into field | menu type-select |
| ⌘P / ⌘⇧P | `worktreeSwitcher` / `commandPalette` | FIRES (M1) | FIRES | FIRES | FIRES (palette re-presents) | N/A |
| ⌘⇧E | `revealInSidebar` | INERT (M6 — `ContentView.swift:146` needs `selectedWorktreeID`, and a task selection nils it: `RepositoriesFeatureTasksTabRoutingTests.swift:192`) | INERT | INERT | INERT | N/A |
| ⌘⌫ / ⌘⇧⌫ | `archiveWorktree` / `deleteWorktree` | INERT (M6) | INERT | INERT | INERT | N/A |
| ⌘↵ | `confirmWorktreeAction` | INERT (M6) | INERT | INERT | FIRES in the creation sheet (its own `FocusedAction`) | N/A |
| ⌘1–9 | `selectTab(n)` — terminal tabs | FIRES (M1) | FIRES | FIRES | FIRES | N/A |
| ⌘R / ⌘. | `runScript` / `stopRunScript` | INERT (M6, no worktree selection) | INERT | INERT | INERT | N/A |
| ⌘[ , ⌃⌘[ , ⌃⌘] | sidebar toggle / collapse-all / expand-all | FIRES (M1) | FIRES | FIRES | FIRES | N/A |

### 2.2 Same existing shortcuts — Worktrees / Agents tab active (regression baseline)

| Chord | Worktrees · T | Worktrees · S | Agents · T | Agents · S |
|---|---|---|---|---|
| ⌘N | FIRES ("New Worktree", gated on `canCreateWorktree`, M5) | FIRES | FIRES (worktree) | FIRES |
| ⌃1–9 | FIRES → `selectWorktree` (M4/M7 `:3672`) | FIRES | FIRES → `activateAgentDashboardEntry` (M7 `:3663`) | FIRES |
| ⌃⌘↓/↑ | FIRES (`worktreeID(byOffset:)` `:5259`) | FIRES | FIRES (`agentDashboardEntryID(byOffset:)`) | FIRES |
| → (bare) | →TERM | **FIRES → focuses terminal** (M9) | →TERM | nothing (no `@FocusState`) |
| letter (bare) | →TERM | **→TERM** (M8 type-ahead) | →TERM | nothing |
| ↵ (bare) | →TERM | native | →TERM | FIRES → activate row (`AgentDashboardListView.swift:126`) |
| ⌘⌫ / ⌘⇧⌫ / ⌘R / ⌘. / ⌘⇧E | FIRES when a worktree is selected (M6) | same | same | same |

**The single most important row above:** in the Worktrees sidebar, an unmodified
letter is *already someone's typing* (M8). A34's "never intercept typing" is
therefore not a soft goal — it is a live constraint that any bare-key task
binding would violate the moment cj is on the Worktrees tab.

### 2.3 Shipped shortcuts — Tasks tab active

Same notation. `FIRES*` = new behaviour this phase added; every row below is
implemented. The `H` column is the one that moved during review: it read
`FIRES ⚠️` in the review draft and is `INERT` everywhere now (§4.6).

| Chord | Action | T | S | F | H | M |
|---|---|---|---|---|---|---|
| ⌃1–9 | **task slot** → open visible task *n* | FIRES\* (M4→M7 `.tasks` arm) | FIRES\* | FIRES\* | INERT\* (`hasBlockingSheet`) | N/A |
| ⌃⌘↓ / ⌃⌘↑ | **next / prev task** over `visibleTaskIDs` | FIRES\* (M7) | FIRES\* | FIRES\* | INERT\* | N/A |
| ⌃⌘J | **jump to next needing me** (A33) | FIRES\* (M1) | FIRES\* | FIRES\* | INERT\* | N/A |
| ⌃⌘S | **settle / unsettle focused task** | FIRES\* (M1+M6) | FIRES\* | FIRES\* | INERT\* | N/A |
| ⌃⌘Z | **snooze for an hour / wake now** | FIRES\* | FIRES\* | FIRES\* | INERT\* | N/A |
| ⌃⌘K | **pin / unpin focused task** (refused when settled) | FIRES\* | FIRES\* | FIRES\* | INERT\* | N/A |
| → (bare) | **escape hatch: sidebar → task terminal** | →TERM (unchanged) | FIRES\* (new Tasks-side M9) | N/A | N/A | N/A |
| ⌘⇧E | **escape hatch: terminal → task row** | FIRES\* (M6 re-enabled for a task selection) | FIRES\* | FIRES\* | INERT\* | N/A |

On **Worktrees / Agents tabs**, every row in 2.3 is unchanged from 2.2: the new
`AppShortcutID`s (⌃⌘J/S/Z/K) publish `FocusedAction`s only from
`TasksSidebarView`, so on other tabs the focused value is absent and the menu
items are `INERT` via M6. ⌃1–9 and ⌃⌘↑↓ keep their existing per-tab arms
untouched (M7) — this is the whole of A35's protection.

---

## 3. A32 slot design

### What gets built

1. **`TasksSidebarStructure.slotByTaskID: [TaskID: Int]`** — computed alongside
   `visibleTaskIDs` in `TasksSidebarStructure.compute(...)`
   (`BusinessLogic/TasksSidebarStructure.swift:211`), as
   `visibleTaskIDs.enumerated()` inverted. Exactly mirrors
   `AgentDashboardStructure.slotByID:207` and `SidebarStructure.slotByID:278`.
   **No new struct type.** `HotkeyWorktreeSlot` is untouched, satisfying the
   plan's constraint; a parallel `HotkeyTaskSlot` would carry only the ID it is
   keyed by, which is a type earning nothing.

2. **`state.taskID(atSlot: Int) -> TaskID?`** in
   `Reducer/RepositoriesFeature+Tasks.swift` — the analogue of
   `agentDashboardEntryID(atSlot:)`. Reads
   `tasksSidebarStructure.visibleTaskIDs`, bounds-checked; nil → the existing
   beep.

3. **Hint pills** — the join in `TasksSidebarView` is the same three lines used
   in `SidebarListView.swift:37-45` and `AgentDashboardListView.swift:37-45`:

   ```
   if commandKeyObserver.isPressed {
     hintByID = structure.slotByTaskID.compactMapValues {
       AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: $0, overrides: overrides)
     }
   }
   ```

   and render through the existing `SidebarShortcutHintCrossfade`
   (`Views/SidebarShortcutHintCrossfade.swift:10`, 0.15s crossfade). Because the
   chord *is* `worktreeSelection`, the hint string is resolved by the same
   helper — **hint and target cannot disagree** (A32's last clause) since both
   read one `slotByTaskID` and one `AppShortcuts` entry.

4. **No new `CommandKeyObserver` work.** It already flips on ⌘ *or* ⌃
   (`App/CommandKeyObserver.swift:59`), has no debounce, resyncs on
   `didBecomeActive`, and forces false on `didResignActive`. Its
   `tabSelectionHints` cache is for the terminal tab bar and is not touched.

   **Known wart, pre-existing, all three panels — ticket-worthy on its own:**
   `CommandKeyObserver.isPressed` flips on ⌘ *or* ⌃, so **holding ⌘ reveals the
   ⌃n hint pills** — pills advertising a chord the held modifier does not fire.
   Inherited verbatim by the Tasks panel rather than diverging one panel's hint
   rule from the other two. The fix is to split the observer into per-modifier
   state and have each hint join read the modifier its own chord actually
   carries; not attempted here because it moves the Worktrees and Agents panels
   too, which is A35 surface this phase deliberately does not touch.

### Why visible-only falls out for free

`visibleTaskIDs` is already exactly what the `List` renders, in render order —
`activeTaskIDs + visibleSnoozedEntries.map(\.id) + visibleSettledTail.map(\.id)`
(`:211`). A collapsed snooze shelf contributes `[]` (`visibleSnoozed` `:325-333`),
and paged-out settled rows are excluded by `visibleSettled` (`:339-355`), with
the one documented exception that the *open* task is always pulled in (A8). So
"snoozed/paged rows consume no slots" needs **zero** extra logic; it needs a test
that pins it. The struct's own doc comment already declares this contract
(`:110-113`).

### Slot count

`AppShortcuts.worktreeSelection` has **9** entries (⌃1–⌃9), not 10 — despite
`AppShortcutID.selectWorktree(0)` rendering as "Select Worktree 10"
(`AppShortcuts.swift:164`) and `SelectWorktreeSubmenuItems` being described as a
"static 10-item submenu" (`WorktreeCommands.swift:170`) while actually iterating
`0..<9`. Tasks inherit 9 slots. Not worth fixing here; noted so nobody "fixes"
the count mid-implementation.

---

## 4. Decisions for cj

Each item: recommendation, why this over the alternatives, and a ship marker.

### 4.1 Task slot chord → **reuse ⌃1–9** · CONSERVATIVE

Extend the existing `.tasks` arm of `selectWorktreeAtHotkeySlot`
(`RepositoriesFeature.swift:3668-3671`, currently a beep) to resolve
`taskID(atSlot:)` and `.send(.tasks(.select(id)))`.

**Why:** zero new `AppShortcutID`s, zero new settings rows, zero new conflict
surface, and it is *literally* what the Agents panel did. The alternative — a
dedicated `selectTask1…9` set — adds 9 IDs, 9 settings rows, 9 ghostty unbinds,
and creates a genuine conflict-warning storm because the natural chord is the
one already used. It also makes ⌃1 mean two different things depending on the
tab, which is already the established pattern here, not a new inconsistency.

**Cost:** the settings row stays labelled "Select Worktree 1". Acceptable —
rebinding it moves the chord for all three panels coherently.

### 4.2 Next / prev task → **reuse ⌃⌘↓ / ⌃⌘↑** · CONSERVATIVE

Extend the `.tasks` arms of `selectNextWorktree` / `selectPreviousWorktree`
(`:3688`, `:3706`) with a `taskID(byOffset:)` walking `visibleTaskIDs` with
modulo wrap — the direct analogue of `worktreeID(byOffset:)` (`:5259`) and
`agentDashboardEntryID(byOffset:)`.

**Why:** same argument as 4.1. Note this is *cycling within the visible list*,
which is distinct from `TaskForwardNavigation` (`RepositoriesFeature+Tasks.swift:1632`),
the post-settle "what do I look at next" policy. Two different questions; do not
merge them.

### 4.3 Jump-to-next-needs-me → **new ID `jumpToNextTaskNeedingAttention`, default ⌃⌘J** · CONSERVATIVE

Pure predicate already exists and is currently read by **nothing in the UI**:
`TaskLeafState.needsHuman` (`Reducer/TaskLeafState.swift:98`) →
`TaskAttention.needsHuman` (`BusinessLogic/TaskAttention.swift:30`) =
`status.needsHuman || isDoneUnread || isWoke`. A33's "skips working and receded"
is exactly `!needsHuman`, and `isReceded` is its complement minus `.working`
(`:37`) — so one predicate serves the row's fade and the jump target and they
**cannot** disagree. The new pure function is a scan:
`visibleTaskIDs`, starting after the current selection, wrapping once, first
`needsHuman`; nil → beep.

**Chord:** ⌃⌘J. Free — the only ⌃⌘ chords in use are ↓ ↑ ← → , `[` , `]` , G
(`openPullRequest`), A (`archivedWorktrees`). Not in `appKitReservedDisplayStrings`
(`⌘Q ⌘W ⌘H ⌘M`, `AppShortcutOverride.swift:92`) and not a known macOS symbolic
hotkey (⌃⌘Space/F/Q are; J is not). `AppShortcuts.conflictWarnings(from: [:])`
must return nil for it — assert that, mirroring
`inspectorShortcutsHaveNoDefaultConflict` (`AppShortcutsTests.swift:442`).

**Alternative rejected:** overloading ⌘⇧U (`jumpToLatestUnread`). Semantically
adjacent but it is notification-scoped over worktrees; overloading it makes one
chord mean three things across three tabs with three different orderings.

### 4.4 Mouseless settle / snooze / pin → **⌃⌘S / ⌃⌘Z / ⌃⌘K on the selected row** · DECIDED, shipped

**Shipped semantics**, all three resolving the focused task in the reducer:

- **⌃⌘S** settle ⇄ unsettle, refused while an agent is awaiting a person (A18b).
- **⌃⌘Z** snooze **one hour** ⇄ **Wake Now**. The one-hour preset is the ruling
  on the open question below; the toggle is the review's addition — without it
  the chord was a one-way door whose only undo was a right-click, which is the
  mouse A34 exists to avoid. `canSnooze` gates only the parking direction: a
  task waiting on a person must always be able to come *back*.
- **⌃⌘K** pin ⇄ unpin, **refused on a settled row**: A16 makes settling clear
  the pin, so a pin there is a write that means nothing the moment it lands. The
  row's context menu hides the item for the same reason (hidden, not greyed —
  it is not a refusal the user can satisfy).

The original recommendation, for the record:

New IDs `settleTask`, `snoozeTask`, `pinTask`, in a **new
`AppShortcutCategory.tasks`** group (required — `groupsCoverAllShortcuts`
`AppShortcutsTests.swift:281` and `groupsCategoriesMatchAllCases` `:402` both
fail otherwise). Menu items live in a new `TaskCommands` `CommandMenu`,
each reading a `FocusedAction<Void>` published by `TasksSidebarView`.

- **⌃⌘S settle** — reuses `.tasks(.settle(id))` (`RepositoriesFeature+Tasks.swift:52`).
  Enablement token must hash `(selectedTaskID, canSettle, isSettled)`; when
  settled the item flips to "Unsettle" → `.unsettle` (`:53`), matching the
  context menu's own branch (`TasksSidebarView.swift:311-317`).
- **⌃⌘K pin/unpin** — `.tasks(.pin/.unpin)` (`:59-60`). Token hashes
  `(selectedTaskID, isPinned)`. ⌃⌘P was the obvious pick and is free, but ⌘P and
  ⌘⇧P are both palette-ish already; a third P is a footgun. ⌃⌘K reads as "keep".
- **⌃⌘Z snooze** — `.tasks(.snooze(id, until:))` needs a *duration*, which a
  bare chord cannot express. A chord cannot open a submenu.
  **Recommendation: snooze to the first preset, "In an Hour"**
  (`TasksSidebarView.swift:376-381`, `TaskSnooze.resolveSnoozePresets`) — it is
  the cheapest, most reversible one, and Wake Now (`.unsnooze`) is one context
  menu away. ~~**NEEDS-CJ on the preset choice only**~~ — **ruled: one hour**,
  and Wake Now moved from "one context menu away" to the same chord again.

**Why chords and not the row's context menu:** the context menu already covers
all three (`TasksSidebarView.swift:298-397`) but requires a pointer. A34's whole
content is that these must work mouselessly.

**Why ⌃⌘ and not ⌘⇧:** the ⌘⇧ space is dense (⌘⇧A T E B P R C O K U ⌫ all
taken), and ⌘⇧S/Z/K would collide or read as Save/Undo relatives.

### 4.5 Escape hatch — **bare → out, ⌘⇧E back in** · DECIDED, both halves shipped

**Shipped semantics.** cj took the full round trip rather than the additive-only
half:

- `revealInSidebarAction`'s enablement is now
  `selectedWorktreeID != nil || selection?.taskID != nil`
  (`ContentView.swift`). The task branch is checked **first**, so a stale
  worktree id can never win over the row actually open. The Worktrees path is
  untouched below that guard, which is what keeps A35's regression risk at zero.
- A task selection fires `.tasks(.revealSelectedInSidebar)`: the arm flips
  `@Shared(.sidebarTab)` to `.tasks` (⌘⇧E from a terminal means "show me where I
  am", and the panel may not be the one on screen) and posts a
  `PendingTaskReveal`. No section uncollapse is needed — A8 already pulls the
  open task into the visible order whatever shelf it lives on.
- `TasksSidebarView` consumes it exactly as `SidebarListView` consumes the
  worktree reveal: two `Task.yield()`s, `isTasksSidebarFocused = true`,
  `scrollTo(taskID, anchor: .center)`, then `.tasks(.consumeSidebarReveal(id))`.
  A monotonic id means a stale consumer cannot clear a newer request.

**QA must verify** the one half unit tests cannot reach: that after ⌘⇧E from a
terminal the *keyboard* is genuinely in the Tasks list — ↑/↓ move the task
selection rather than going to the terminal. Tests cover the tab flip, the
posted request, and the consume/stale-consume rules; `@FocusState` restoration
into an `NSOutlineView` is only observable in the running app.

The original recommendation, for the record:

This is the item with the most missing scaffolding, because the Tasks panel has
**no `@FocusState` at all** (§1c). Both halves need one first.

- **Sidebar → terminal: bare →.** Add `@FocusState private var isTasksSidebarFocused`
  to `TasksSidebarView`, `.focused(...)` on its `List`, and reuse
  `SidebarRightArrowMonitor` verbatim (`SidebarListView.swift:575-628`) with a
  handler that resolves the selected task's owned surface and focuses it. The
  monitor is already modifier-disjoint (`isDisjoint(with: [.command,.shift,.option,.control])`),
  window-scoped, and focus-gated — it cannot intercept typing. **A34-safe by
  construction. CONSERVATIVE.**
  *Note:* the monitor is `private` inside `SidebarListView.swift`; lifting it to
  its own file is a prerequisite refactor, no behaviour change.
- **Terminal → sidebar: ⌘⇧E.** `revealInSidebar` is the only existing
  focus-moving chord (§1b), and it already does the right shape of thing —
  reveal, scroll, `isSidebarFocused = true` (`SidebarListView.swift:171-180`).
  But it is gated on `selectedWorktreeID != nil` (`ContentView.swift:146`), and a
  task selection nils that (`RepositoriesFeatureTasksTabRoutingTests.swift:192`),
  so today it is INERT on the Tasks tab. Making it work means widening the
  `FocusedAction` enablement to "a task is selected" and adding a
  `pendingTasksSidebarReveal` mirror.
  **NEEDS-CJ**: this touches the Worktrees reveal path's enablement, which is the
  one place A35 has real regression risk. If cj wants Phase 6 to stay
  additive-only, defer the return half and ship the → half; the return path is
  then "click the sidebar", which is what it is today.

### 4.6 Sheet gating — **DECIDED, shipped (narrowed to the Tasks panel)**

**Shipped mechanism**, which is *not* the `WorktreeMenuSnapshot` route
recommended below: `RepositoriesFeature.State.hasBlockingSheet` — one computed
property over every `@Presents` field the reducer owns plus
`taskDirectoryConflict` (a sheet without a child reducer). Two consumers, one
property, so they cannot drift:

- The reducer refuses `.tasks(.jumpToNextNeedingAttention / .settleSelected /
  .snoozeSelected / .togglePinSelected)` and the `.tasks` branch of
  `selectWorktreeAtHotkeySlot` / `selectNext` / `selectPreviousWorktree`.
  **Silently, not with a beep** — the sheet has a text field in it, and beeping
  at every chord-shaped keystroke typed there is noise, not feedback.
- `TasksSidebarView` ANDs `!hasBlockingSheet` into the four `FocusedAction`
  enablements, so the Tasks menu greys out and the refusal is visible rather
  than mysterious.

**Deliberately narrowed twice.** (a) Only the `.tasks` branches of the shared
nav arms are gated; the Worktrees behaviour is pre-existing and pinned by A35,
and widening it is not Phase 6 scope. (b) `AppFeature`'s own two modals (`alert`,
`deeplinkInputConfirmation`) are invisible from this reducer and are **not**
covered — both present over the detail pane rather than the sidebar, so the
chords the Tasks panel owns stay legitimate underneath them. **Still open:** ⌘N
over an open creation prompt presenting a second one (`WorktreeCommands.swift`)
is the original §4.6 bug and is untouched — it lives in the worktree menu's
`.disabled`, not in any task arm.

The original recommendation, for the record:

⌘N with the task-creation sheet already open presents a **second** prompt: the
menu item's `.disabled` (`WorktreeCommands.swift:71`) only consults
`capturesTask` / `canCreateWorktree`, never "a creation sheet is up". The same
hole lets ⌃1–9 and ⌃⌘↑↓ move the sidebar selection out from under an open sheet.
`[INFERRED — verify in QA; SwiftUI sheets do not automatically disable main-menu
key equivalents.]`

**Recommendation:** add `hasBlockingSheet` to `WorktreeMenuSnapshot`
(`Features/App/Models/WorktreeMenuSnapshot.swift:24` is where `activeSidebarTab`
already lives, and the snapshot gate already recomputes on presentation actions)
and OR it into the `.disabled` of every navigation and lifecycle item.
Marked **NEEDS-CJ** because it is pre-existing scope, not Phase 6 scope — but it
is the single cell in §2 that is actively wrong rather than merely absent.

### 4.7 A34 hard rule — stated, and how each proposal satisfies it

> **Typing in a terminal or a text field is NEVER intercepted. Every new chord
> must either carry ⌘, or fire only from sidebar-nav focus and be a
> non-printing key.**

| Proposal | Satisfies via |
|---|---|
| ⌃1–9, ⌃⌘↑↓ | carry ⌘/⌃; already unbound in ghostty (M1); no change to the existing gate |
| ⌃⌘J / S / Z / K | carry ⌘; M1 gives them the same terminal-safe path as every other app chord |
| bare → | non-printing, modifier-disjoint, `@FocusState`-gated, window-scoped (M9) |
| everything else | no bare printable key is bound anywhere in this phase |

Nothing proposed here adds a printable-character handler. M8 (the Worktrees
type-ahead) is not extended to the Tasks panel.

---

## 5. A35 regression inventory

What currently locks behaviour, and what each new binding forces.

### 5.1 Tests that will **fail** unless the new shortcuts are added correctly

| Test | File:line | Forces |
|---|---|---|
| `groupsCoverAllShortcuts` | `AppShortcutsTests.swift:281` | every new `AppShortcut` must appear in an `AppShortcutGroup` |
| `groupsCategoriesMatchAllCases` | `:402` | a new `.tasks` category must have a group |
| `allShortcutsHaveUniqueIDs` | `:238` | no ID collisions |
| `displayNameFromID` | `:243` | `AppShortcutID.displayName` is an exhaustive switch — new cases won't compile without it |
| `categoryDisplayNames` | `:393` | new category needs a display name |
| round-trip coding | `:409`, `:415` | new IDs need `stableKey` + `stableKeyMap` entries, or persistence silently drops overrides |

### 5.2 Tests that lock behaviour the new bindings must **not** disturb

| Test | File:line | Locks |
|---|---|---|
| `worktreeSelectionUsesControlNumberShortcuts` | `AppShortcutsTests.swift:122` | ⌃1–9 stay `[.control]` — this is the load-bearing assertion behind §0.1 |
| `ghosttyCLIArgumentsKeepWorktreeUnbindsAndTabBinds` | `:182` | uses `contains`, not equality — new unbind args are additive-safe |
| `tabSelectionGhosttyKeybindArguments*` | `:156`, `:200`, `:211`, `:222`, `:229` | the ⌃N → `goto_tab` re-bind (M4) is untouched |
| `activeSlots*` (4 tests) | `:324`–`:348` | slot/override interaction |
| `inspectorShortcutsHaveNoDefaultConflict` | `:442` | the pattern to copy for ⌃⌘J/S/Z/K |
| `AppShortcutOverrideTests.swift` | whole file | key-code/display machinery under rebinds |
| `CommandKeyObserverTests.swift` | `:12`, `:19`, `:27` | ⌘-or-⌃ hint gating and override-following hints |

### 5.3 The Tasks-tab inertness tests — read carefully

`supacodeTests/RepositoriesFeatureTasksTabRoutingTests.swift`:

- `:91` `selectNextWorktreeDoesNotMoveSelectionWhileTasksIsActive`
- `:102` `selectPreviousWorktreeDoesNotMoveSelectionWhileTasksIsActive`
- `:113` `hotkeySlotDoesNotMoveSelectionWhileTasksIsActive`
- `:124`, `:143` history back/forward equivalents

These assert `store.state.selectedWorktreeID` is **unchanged**, and their fixture
(`makeState()` `:29`) contains **no tasks**. So after Phase 6 they still pass —
slot/offset resolution finds nothing and beeps. **They must be kept**, because
they are the assertion that task navigation never moves *worktree* selection.
They must be **joined** by positive counterparts with tasks present:

- ⌃1 with 3 visible tasks selects the first, and leaves `selectedWorktreeID` alone
- ⌃⌘↓ wraps at the end of `visibleTaskIDs`
- a collapsed snooze shelf makes its rows unaddressable by slot
- ⌃⌘J from a working row lands on the next `needsHuman` row, skipping receded ones

Sibling suites to keep green: `RepositoriesFeatureAgentKeyboardNavTests.swift`
(the Agents `atSlot`/`byOffset` behaviour these changes sit beside),
`AppFeatureTaskMenuTests.swift` (the ⌘N label flip and the snapshot gate — a new
`CommandMenu` in the same scene must not perturb it),
`RepositoriesFeatureTasksTests.swift`, `TaskAttentionTests.swift`,
`TaskStatusModelTests.swift`.

### 5.4 What has no coverage today and needs some

- Nothing asserts hint-pill/target agreement for **any** panel. The Tasks
  implementation should add the assertion that
  `slotByTaskID[visibleTaskIDs[n]] == n` for all n.
- ~~Nothing asserts the sheet-open gating in §4.6 (because it does not exist).~~
  Shipped and covered: `everyTaskChordIsInertWhileACreationPromptIsUp` /
  `theChordsComeBackWhenThePromptIsDismissed`
  (`RepositoriesFeatureTaskKeyboardTests.swift`), both driving the sheet through
  `.presentCreationPrompt` — the arm that actually raises it — rather than
  assigning the presentation state by hand.
- No test exercises `SidebarRightArrowMonitor`; it is an `NSEvent` monitor. The →
  escape hatch will be QA-verified via `devtools`-equivalent manual steps, not a
  unit test. Say so rather than pretending.

---

## 6. Bundle routing note for whoever implements

New test files route by **filename glob** (`Project.swift`):
`RepositoriesFeature*` → `supacodeFeatureTests`; `AppShortcuts*` /
`TaskAttention*` / everything else → `supacodeTests`. A new file needs
`make generate-project` before it exists in the workspace, and `-only-testing`
against the wrong bundle passes with 0 tests — verify `totalTestCount > 0` via
`xcrun xcresulttool get test-results summary --path build/supacode-tests.xcresult`.
