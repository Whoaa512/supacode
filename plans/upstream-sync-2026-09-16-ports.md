# Upstream sync 2026-09-16 — terminal-layer ports

Branch: `cj-main-rebase-2026-09-16` (fresh cut of `upstream/main` @ 81cba553).
111 fork commits cherry-picked cleanly; the clusters below could NOT be
cherry-picked because upstream #786 rewrote the terminal layer
(`WorktreeTerminalState` → `WorktreeContentHost` + `TabContent` +
`LayoutFeature`/`TerminalsFeature`/`PaneLayout`; `WorktreeTerminalManagerTests`
deleted). Each is a feature port against the new API. Reference the fork
commits on `cj-main` (tag `cj-main-pre-rebase-2026-09-16`) for behavior + tests.

Dropped for good (upstream subsumed): `5850ff8d` search-overlay Escape (#819
find bar), `856b5b32` badge renderingMode (#651 fixed upstream), `253240b0`
skip close-confirm on ⌘⇧W (upstream `confirmCloseTab: busy|always|never`),
`930a61f0` done-unseen (carried forward by later fork commits).

## A. Equalize splits on split/close setting — `c8004154 a94dd896 786856ee`
- `GlobalSettings.equalizeSplitsOnSplit` still exists (decode/encode) but is
  not in `SettingsFeature.State` nor `applyOwnedFields` (#824). Add both, plus
  a toggle in `TerminalSettingsView` (upstream #790 pane).
- Gate: when the setting is on, a new split and a pane close call the existing
  `SplitTree.equalized()` / `PaneLayout` equalize. Find the split/close paths in
  `LayoutFeature` / `WorktreeContentHost`.
- Tests: port `SplitTreeTests` `newSplitEqualizes*`, `closeEqualizes*`,
  `closeDoesNotEqualize*` (target `supacodeTerminalTests`).

## B. Scrollback persistence (Swift side) — `4ead469b c3bccdfd d5fd5fe7 7f7ff541 51621278 27ee2e81 708a4b25 b1954296 f821dad1 2e6d1424`
- Native side already landed: `patches/ghostty-scrollback-persistence.patch`
  (`ghostty_surface_write_scrollback`, replay engine), `patches/zmx/zmx-emit-lib-vt.patch`,
  `GhosttySurfaceView.writeScrollback(to:)` if not present.
- Port: `SupacodePaths.scrollbackDirectory` (0700) + `purgeAllScrollbackFiles`;
  periodic + on-quit `saveScrollbackFiles` in `WorktreeTerminalManager`
  (cooperative `Task.yield`); `initialScrollbackPath` threaded into surface
  creation (`TerminalSurfaceRecipe` / `TabContent`) only when no live zmx
  session for that surface (`resolveLiveZmxSessions` gate); "scrollback
  restored from disk" boundary marker; restore-prune of bare shells
  (`TerminalRestorePruner`, opt-in `pruneBareSurfacesOnRestore`).
- Settings: `persistScrollbackEnabled` (already in GlobalSettings + State);
  add toggle to `TerminalSettingsView` with purge-on-disable.
- Tests: `ScrollbackPersistenceTests`, `TerminalRestorePrunerTests`;
  `./scripts/smoke-zmx-scrollback-replay.sh`.

## C. Hibernation teardown queue — `44f05b92 … 59cbde9c` (40 commits)
- Upstream still frees synchronously on main (`GhosttySurfaceView.closeSurface`
  → `DispatchQueue.main.async { ghostty_surface_free }`), so a wedged pty io
  thread still hangs the app. Fork fix: `SurfaceTeardownQueue` (detach the zmx
  attach client over IPC via `ZmxClient.detach(session:)`, poll
  `ghostty_surface_process_exited` with injected clock, then free on main;
  leak + log on timeout). Spec: `plans/hibernation-teardown-deadlock.md`.
- Port points: `TabContent.hibernate()` / `close()` and any other
  `closeSurface()` caller route through the queue; `WorktreeContentHost`
  hibernation must not await the free.
- Tests: the 5 `WorktreeTerminalManager*TeardownTests` files on cj-main —
  re-target to the host/TabContent seams.

## D. Terminal Sessions settings pane + grid overview — `22d55bc6 017d116a 2a331f0d 6310ff9f 7e3cc985 49e5be2e 949986e6 5bda3a9d 6114ab2f 22b95a0b`
- Needs a per-surface enumeration (worktree, tab, surface id, title, focused,
  dormant/snapshot) from `WorktreeTerminalManager` over `hosts`, plus
  `screenPreview` (already re-added), focus + close actions.
- `TerminalGridOverview` model/view, ⌥⌘O menu item (overridable shortcut),
  activity buckets from `AgentPresence`. `AnsiStyledText` for thumbnails.
- Tests: `AppFeatureTerminalGridTests`, `AppFeatureTerminalSessionBrowserTests`,
  `TerminalGridOverviewTests`.

## Order
A → B → C → D. Commit per cluster; `make build-app` + targeted tests each.
