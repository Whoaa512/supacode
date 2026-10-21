## Build Commands

```bash
make # this show available commands
```

Requires [mise](https://mise.jdx.dev/) for zig, swiftlint, swift-format, xcbeautify, and xcsift tooling. Run `mise install` once to fetch the pinned versions.

### Running a subset of tests

- Pass extra xcodebuild flags via `LOCAL_XCODEBUILD_FLAGS`, but ALWAYS re-include `SWIFT_VERSION=5`: the Makefile's default value of that variable carries the TCA strict-concurrency workaround for local Xcode 26.4+ builds, and overriding it without the flag makes TCA itself fail to compile (`WritableKeyPath ... Sendable` errors in `Binding+Observation.swift`).
  ```bash
  make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:supacodeTests/MyTests'
  ```
- Tests are split across four bundles by filename globs in `Project.swift`; `-only-testing` with the wrong bundle matches nothing and the run "succeeds" with 0 tests. Verify with `xcrun xcresulttool get test-results summary --path build/supacode-tests.xcresult` (check `totalTestCount > 0`). Per-function selectors (`bundle/Suite/testFunc`) also silently match 0 tests for Swift Testing suites; the suite level (`bundle/Suite`) is the finest granularity that reliably selects anything. The `totalTestCount` check is how you notice either case. Bundle routing:
  - `supacodeFeatureTests`: `AppFeature*.swift`, `RepositoriesFeature*.swift`
  - `supacodeTerminalTests`: `Ghostty*.swift`, `LayoutFeature*.swift`, `Layouts*.swift`, `SplitTree*.swift`, `WorktreeTerminalManager*.swift`, `Zmx*.swift`
  - `supacodeGitTests`: `AgentHook*.swift`, `Git*.swift`, `ShellClient*.swift`, and a few named files
  - `supacodeTests`: everything else
- A test file created after the last `tuist generate` is not in the workspace; run `make generate-project` before testing it.

## Architecture

Supacode is a macOS terminal emulator that for running multiple coding agents in parallel in Git worktrees, using GhosttyKit as the underlying terminal.

### Tasks own layouts

- The unit of work is a **task** (`TaskRecord`, `supacode/Domain/TaskRecord.swift`): id `LayoutID` (an opaque UUID, never a path; `Features/Terminal/Models/LayoutID.swift`), a default `Directory` (worktree id + optional SSH host), a layout and an ordered member list (`sessions`, primary first). Layouts live in `terminals.layouts[id: layoutID]`; a worktree owns no layout. Several tasks may share a directory, and a tab may `cd` elsewhere.
- Tasks are never created by hand: the first tab on a task-less directory mints one (`PendingTaskLaunch`, `NewTaskSource`), and every indexed agent session without a record renders as an implicit one-member task; resuming it mints the record. Shell-only tasks are deleted when their last tab closes.
- The primary session gives the title; later sessions in the task's tabs are tangents, shown as sub-rows. Task settle (`settleSessionAndAdvance` on a task) closes every tab; auto-settle never closes a tab and skips any task with one open. Settle state stays in the session sidecar on the current primary. Orphan tasks (directory gone from the roster) are kept until settled by hand.
- Merge and detach are one level deep (`AppFeature+TaskTransfer.swift`, `TerminalsFeature.transferRefusal`): a task is a flat list of surfaces, never nested; detaching the primary is refused. Refusals (`TabTransferRefusal`) are decided on state alone, once for the toast and again by the manager in the turn that moves tabs.
- App-layer "which layout does this worktree mean" lookups go through one seam, `AppFeature.State.layoutID(forDirectory:)` (the task the directory shows, nil when it has none: only a first tab mints one), with `layoutID(forDirectory:holding:)` when a tab or surface id names the owner; `SUPACODE_WORKTREE_ID`, `-w` and worktree deeplinks stay path-based, `SUPACODE_TASK_ID` / `--task` / the `/task/<id>/` route segment name a task.
- **Decide at delivery, carry identity.** Anything that crosses an asynchronous boundary (a `.run` effect, a `terminalClient.send`, a debounce, a transfer completion) carries only identities: layout, tab, surface and directory ids. It never carries a list, a plan, a record or a verdict computed before the boundary. The receiver re-derives from current state when the command lands (`WorktreeTerminalManager.deliveryContext(for:carried:creating:command:)` is the gate for tab-creating and host-attaching commands) and applies every refusal there. A command sent to focus or show an existing task must not be one that can create a host, a layout or a tab. Tests for such a path make the target disappear between send and delivery and assert nothing is created or resurrected.

### Key Dependencies

- **TCA (swift-composable-architecture)**: App state, reducers, side effects
- **GhosttyKit**: Terminal emulator (built from Zig source in ThirdParty/ghostty)
- **Sparkle**: Auto-update framework
- **swift-dependencies**: Dependency injection for TCA clients
- **PostHog**: Analytics
- **Sentry**: Error tracking

## Code Guidelines

- Target macOS 26.0+, Swift 6.0
- Before doing a big feature or when planning, consult with pfw (pointfree) skills on TCA, Observable best practices first.
- Use `@ObservableState` for TCA feature state; use `@Observable` for non-TCA shared stores; never `ObservableObject`
- Always mark `@Observable` classes with `@MainActor`
- Modern SwiftUI only: `foregroundStyle()`, `NavigationStack`, `Button` over `onTapGesture()`
- When a new logic changes in the Reducer, always add tests
- In unit tests, never use `Task.sleep`; use `TestClock` (or an injected clock) and drive time with `advance`.
- Prefer Swift-native APIs over Foundation where they exist (e.g., `replacing()` not `replacingOccurrences()`)
- Avoid `GeometryReader` when `containerRelativeFrame()` or `visualEffect()` would work
- Do not use NSNotification to communicate between reducers.
- Prefer `@Shared` directly in reducers for app storage and shared settings; do not introduce new dependency clients solely to wrap `@Shared`.
- Use `SupaLogger` for all logging. Never use `print()` or `os.Logger` directly. `SupaLogger` prints in DEBUG and uses `os.Logger` in release.
- Avoid top-level free functions. Default to `static` methods, computed properties, or instance methods on a relevant type (enum/struct/extension). Free functions pollute the module namespace, are harder to discover, and easily drift from the inline implementation a consumer ends up writing instead. If the operation is pure and stateless, make it a `static` on a caseless `enum` or the most relevant type, not a top-level `func`.
- Closure-typed focused values invalidate the AppKit menu on every body run (closures have no Equatable conformance, so SwiftUI re-publishes every time). Always wrap menu-bar action closures with `FocusedAction<Input>` and publish via `.focusedSceneAction(_:enabled:token:perform:)` / `.focusedAction(_:enabled:token:perform:)`. The wrapper dedupes on `(isEnabled, token)`, so AppKit only rebuilds the menu when something the menu actually displays changes. Token rules in `App/Models/FocusedAction.swift`: set `token` to a hashable projection of any captured state that affects behavior; leave it `nil` when the closure captures only the store / `@State` bindings. Consumers should read the action with `@FocusedValue(\.x)` and gate with `action?.isEnabled != true`, not `action == nil`.
- Sidebar rows must not fan out invalidation. Per-row state lives in `RepositoriesFeature.State.sidebarItems` so a per-leaf mutation (notification tick, agent activity, running-script update) invalidates only that leaf, not every sibling. The view renders the cached `state.sidebarStructure` (computed in the reducer's post-reduce hook), never reading `sidebarItems[id:]` from a view body; derive per-leaf data in `computeSidebarStructure(...)`, not in the view.
- Never lift content-specific (e.g. terminal-only) mechanics or state into the layout layer. `LayoutFeature` owns topology and strip mechanics only (panes, tabs, selection, focus, zoom, rename identity); anything a specific content kind produces (agent badges, progress, script locks, busyness, reported title, pwd) lives on the content side, exposed to the strip through the content's observable `TabChrome` (`Features/Terminal/Content/TabChrome.swift`), never as layout reducer state or actions. High-frequency reported signals (title, pwd, bell) are the sharp edge of this rule: an agent TUI rewrites its title several times a second, so a reported title lands on the content's chrome and reaches the layout only as one discrete commit at teardown (`titleCommitted`), never one reducer action per report. The strip and window title read the live value off `TabChrome` (`TabTitle.resolved`), and persistence pulls it into the snapshot (`TabTitle.stored`).

## UX Standards

- Buttons must have tooltips explaining the action and associated hotkey
- Use Dynamic Type, avoid hardcoded font sizes
- Components should be layout-agnostic (parents control layout, children control appearance)
- Never use custom colors, always use system provided ones.
- We use `.monospaced()` modifier on fonts when appropriate

## Rules

- After a task, ensure the app builds: `make build-app`
- Automatically commit your changes and your changes only. Do not use `git add .`
- Before you go on your task, check the current git branch name, if it's something generic like an animal name, name it accordingly. Do not do this for main branch
- Do not open a pull request unless the user explicitly asks for one. Commit to the working branch and let the user decide when to push and open a PR.
- When the user does ask you to open an issue or pull request, follow the templates in `.github`: fill the bug or feature issue form, and use the pull request template (link the issue with `Closes #<number>`, complete the checklist, and disclose any AI tools you used). A human is the author of record: never set an AI agent as a commit author or co-author.
