# Supacode

**A native macOS command center for running coding agents in parallel.**

Run several coding agents side by side from one window: each task gets its own real terminal,
and git worktrees keep tasks that need isolation out of each other's way. Sessions persist in the background, so quitting the app or dropping an SSH
connection loses nothing.

[supacode.sh](https://supacode.sh)

<img width="3180" height="1788" alt="Supacode screenshot" src="https://github.com/user-attachments/assets/72a8dc95-020a-4dc2-9010-ba1adc9518ba" />

## Features

### Tasks

The sidebar's unit of work is a task: an agent session (or a plain shell) with its own tabs and
splits. A task is never made by hand. ⌘N starts one in the current task's directory with the
default agent; ⌘⇧N opens a picker (directory, agent or shell); ⌘⌥⇧N creates a new worktree.
Every indexed agent session shows as a task from day one; clicking a history row resumes it.
⌘P searches tasks by title, directory and agent: active ones first, then the recently settled
with how long ago; Enter shows the task, or resumes it when settled. Type `w:` to search
worktrees instead (⌘⌥P opens that switcher directly).

An agent started inside a task's tab joins that task. The first session is the primary and gives
the task its title; the others show as sub-rows while the task is selected, dimmed once they
end, click to resume. Two tasks may share a directory; the directory is a default for new
tabs, not a rule. Settle is task-level: it marks the task done and closes every tab, so nothing
runs on; reopening resumes the primary. Auto-settle (idle timeout) never closes a tab and skips
any task that still has one open. A task whose directory was removed or deleted stays as an
orphan until you settle it.

**Merge and detach**, one level deep, from the row's context menu or the command palette.
Merge A into B moves A's tabs and sessions into B and removes A. Detach moves one tab (and the
session on it) into a new task; the primary cannot be detached, merge the other way instead,
and neither can a task's only tab unless a session stays behind to keep the task. Both refuse
across machines, while tasks are still loading, while a session is still starting in the
source task, while a blocking script runs on a moved tab, while a close confirmation is
pending on either task, while the layouts store is unreadable or read-only, and while
Supacode is quitting.

**Hide a tangent** that has ended from the row's context menu ("Hide from Task"). ⌘⌃H ("Hide
Ended Sessions in Task") is a bulk action: it hides every ended tangent of the task shown in the
terminal, not one row. The primary and any running session cannot be
hidden. A hidden session stays in the task: resume, settle, merge and detach count it as
before, and it unhides itself the moment it runs again. The task row shows "+N hidden";
click it to list them dimmed and "Unhide" from their menu.

### Worktrees

A worktree is optional directory isolation: create one when agents must not collide, and start
as many tasks in it as you like. Starting a task never creates a worktree; ⌘⌥⇧N, the sidebar,
the command palette, the CLI, or a deeplink does. The sidebar
refreshes branch, file, and pull request state live, nests rows by branch, and hoists the
worktrees that need you (an agent awaiting input, a running script) to the top. Pin, archive,
auto-delete after N days, and jump to any with ⌃1 to ⌃9.

### Background session persistence

Sessions run inside [zmx](https://zmx.sh), a lightweight session daemon, not as children of the
app. Quit and relaunch, and every session reattaches exactly where you left it, scrollback
included. On by default; a quit option tears everything down when you want a clean start.

### Remote SSH repositories (Beta)

Point Supacode at a repository on a remote host over SSH and it manages that repo's worktrees
like a local one. Every git probe and the terminal share one multiplexed SSH connection, so you
authenticate (or touch your security key) once. When the host has zmx, remote sessions survive
dropped connections and laptop sleep: the connection retries and reattaches instead of
restarting. Beta, with some local-only features reduced.

### Folders and repositories

Git repositories and plain folders are both first-class in the sidebar. A folder gets a real
persistent terminal rooted there, with the same tabs, scripts, pinning, and appearance as a repo,
minus the git-only tools. You can also clone a remote URL straight into a folder.

### Coding agent presence

Supacode detects the agent in each pane and shows a live badge: busy, awaiting input, or idle. It
supports the common agents (Claude, Codex, Copilot) through hooks it installs, works locally and
over SSH, and drives notifications so you know the moment an agent needs you.

### The CLI and deeplinks

Drive the app from any terminal, script, or other tool. The `supacode` CLI manages worktrees,
tasks, tabs, splits, repos, and running agents (`supacode agent prompt|wait|read|resume …`).
Every session exports `SUPACODE_TASK_ID` with its worktree id, so pane, tab, and agent commands
default to the task you run them in; `--task <id>` names another. The id is on the task, not
the directory: two tasks on one worktree are told apart. Deeplinks (`supacode://...`) mirror the CLI, so
you can bind an action to a hotkey or fire it from another app.

### More

- **A real terminal.** libghostty renders every session, with tabs, horizontal and vertical
  splits, per-surface backgrounds, and theme sync with the app's appearance.
- **Command palette.** Fuzzy-search and run any action without the mouse: jump to a worktree, open
  or clone a repo, manage worktrees, run scripts, and drive the full set of pull request actions.
- **Pull request tracking.** With GitHub integration on, each worktree's PR state, checks, and
  merge readiness show in the sidebar and refresh live, with configurable merge strategy.
- **Notifications and bells.** In-app and optional system notifications, a selectable sound,
  per-surface muting, and an option to float a notified worktree to the top.
- **Custom scripts.** Named commands with an icon and tint, per repository or global, that run in
  their own tab and appear in the Script Menu, the palette, and as deeplinks. Repositories also
  get setup and archive scripts.
- **Auto-updates** through Sparkle, with a selectable update channel.

## Requirements

- macOS 26.0+
- [mise](https://mise.jdx.dev/) for the pinned toolchain. Add `~/.local/bin` to your `PATH`.
- git submodules: `git submodule update --init --recursive`
- **Xcode 26.3** if you are on macOS 26.4+ (see [below](#building-on-macos-264-tahoe)).

## Quick start

```bash
git clone --recursive git@github.com:supabitapp/supacode.git
cd supacode
mise install
make doctor    # check every build prerequisite and print fixes for anything missing
make run-app   # build and launch the Debug app
```

`make doctor` verifies mise, submodules, a Zig-linkable Xcode, the Metal Toolchain, and the
pinned tools, and prints the exact command to fix anything that is missing. The build targets
run it automatically as a quiet preflight.

## Building

```bash
make build-ghostty-xcframework   # build GhosttyKit from Zig source (slow, cached)
make build-app                   # build the macOS app (Debug)
make run-app                     # build and launch
```

### Building on macOS 26.4+ (Tahoe)

GhosttyKit is built with a pinned Zig (`0.15.2`, required exactly by ghostty) whose linker
cannot link the macOS 26.4+ SDK: that SDK dropped the `arm64-macos` slice from `libSystem.tbd`
([ziglang/zig#31658](https://github.com/ziglang/zig/issues/31658)), so the build fails with a
wall of `undefined symbol` errors. Install [Xcode 26.3](https://developer.apple.com/download/all/?q=Xcode%2026.3),
which ships the macOS 26.2 SDK that still has `arm64-macos`. You do not need to switch it
globally: the build auto-detects a Zig-linkable Xcode and pins it for that build only. After
installing Xcode 26.3 once:

```bash
sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -license accept
sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -runFirstLaunch
sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
```

See [AGENTS.md](AGENTS.md) for the full rationale and the rest of the architecture.

## Development

```bash
make check   # swift-format + swiftlint
make test    # run the tests
make format  # swift-format only
```

## Technical stack

- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
- [libghostty](https://github.com/ghostty-org/ghostty)
- [zmx](https://zmx.sh) for session persistence

## Contributing

Contributions are reviewed personally, line by line, and a clear issue is worth more than a
large pull request. Start by opening an issue, wait for the `ready` label, then open a focused
pull request that links it. The full process, including the rule that a human (never an AI
agent) is the accountable author, is in the [Contributing guide](CONTRIBUTING.md).

- [Contributing guide](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)

## License

See [LICENSE](LICENSE).
