---
name: supacode-cli
description: Control Supacode from the terminal. Use when running Supacode CLI commands, managing worktrees, panes, and tabs programmatically, or when inside a Supacode terminal session.
---

# Supacode CLI

Control Supacode from the terminal. The `supacode` command is available in all Supacode terminal sessions.

A **task** owns a layout: a split tree of **panes**; each pane holds a strip of
**tabs**; each tab is one terminal. Split a pane to grow the tree; add a tab to
a pane to stack terminals in the same split. A worktree can hold several tasks
(each agent session is its own task); pane and tab commands act on one task,
by default the one the terminal you run them in belongs to (`$SUPACODE_TASK_ID`),
or the task the worktree shows when run from outside. `--task <id>` names
another; a tab, pane, or surface id always finds its own task.

Task ids are opaque UUIDs minted by the app (never a path). Read your own from
`$SUPACODE_TASK_ID`; agent rows (`supacode agent list --json`) carry `taskID`.
Deeplinks address a task as `supacode://worktree/<worktree_id>/task/<task_id>/…`.

## CRITICAL: ID Tracking

**NEVER call `supacode tab new` or `supacode pane split` without capturing the
output.** These commands print the new tab's UUID to stdout. You MUST capture
it into a variable, or you cannot target the tab afterward.

Pane and tab commands resolve an omitted `-w` / `-p` / `-t` from the **focused**
worktree / pane / tab. That is the target the user is currently looking at, so
when you act on something you created, **pass its id explicitly.**

### Correct pattern — ALWAYS follow this:

**Run all related commands in a SINGLE Bash call** so captured variables
are available to subsequent commands. If you split across tool calls,
variables like `$TAB_ID` will be lost.

```sh
# 1. ALWAYS capture the UUID from tab new / pane split.
TAB_ID=$(supacode tab new -i "npm start")

# 2. pane split opens a new pane; -p accepts a pane, tab, or content UUID.
SPLIT_ID=$(supacode pane split -p "$TAB_ID" -d v -i "npm test")

# 3. ALWAYS use captured IDs for subsequent operations.
supacode tab focus -t "$SPLIT_ID"
supacode tab close -t "$SPLIT_ID"
supacode tab close -t "$TAB_ID"
```

### WRONG — never do this:

```sh
# BAD: not capturing the UUID: you lose the reference.
supacode tab new -i "npm start"

# BAD: relying on the focused default for something you created: it targets
# whatever the user is looking at, not your new pane.
supacode pane split -d v -i "npm test"

# BAD: splitting commands across separate Bash calls — variables are lost.
# Call 1: TAB_ID=$(supacode tab new)
# Call 2: supacode pane split -p "$TAB_ID" ...  ← $TAB_ID is empty!
```

## CRITICAL: Archiving or Deleting the Current Worktree

`supacode worktree archive` and `supacode worktree delete` remove the worktree
from Supacode's active terminals. Run against the worktree you are working in,
they close your own terminal: commands after the call do not run. Worktrees
removed directly through Git disappear the same way once Supacode refreshes.
`--background` does not change this; it only leaves focus untouched.

Make archiving or deleting your own worktree your FINAL operation. Finish all
edits, checks, commits, integration, and reporting first, and do not chain or
schedule follow-up commands after it.

## Sandboxed Harnesses

`supacode` talks to the app over a Unix domain socket. Sandboxes that deny
socket connections fail every command with "Operation not permitted"; that is
the sandbox, not Supacode. Re-run the command with escalated permissions
(approve the elevation prompt) or from an unsandboxed shell.

## Environment

Inside Supacode terminals, these environment variables are set automatically:

| Variable | Description |
|----------|-------------|
| `SUPACODE_SOCKET_PATH` | Socket for app communication. |
| `SUPACODE_TASK_ID` | Current task (UUID). Default `--task` for pane, tab, and agent commands run against this terminal's own worktree; a tie-breaker for agent targets. |
| `SUPACODE_WORKTREE_ID` | Deprecated. Current worktree (percent-encoded path). |
| `SUPACODE_TAB_ID` | Deprecated. Current tab UUID. |
| `SUPACODE_SURFACE_ID` | Deprecated. Current content UUID (used by `surface` commands). |
| `SUPACODE_REPO_ID` | Deprecated. Current repository (percent-encoded path). |

The deprecated id variables **will be removed in the next release**: new
pane/tab commands ignore them and resolve an omitted worktree/pane/tab from the
focused target instead. Only the deprecated `surface` commands still read them.
`SUPACODE_TASK_ID` is not deprecated.

## Commands

### App

```
supacode                          # Bring Supacode to front.
supacode open                     # Same as above.
```

### Worktree

```
supacode worktree list [-f] [--status <status>] [--not-archived] [--with-status]  # List worktree IDs (-f = focused only).
supacode worktree status [-w <id>]                  # Read status/archived/focused for one worktree.
supacode worktree focus [-w <id>]                   # Focus worktree.
supacode worktree run [-w <id>] [-c <uuid>] [--background]         # Run script (default: primary run-kind; -c for a specific UUID).
supacode worktree stop [-w <id>] [-c <uuid>] [--background]        # Stop script (default: all run-kind; -c for a specific UUID).
supacode worktree script list [-w <id>]             # List configured scripts (id / kind / name).
supacode worktree archive [-w <id>] [--background]                 # Archive worktree.
supacode worktree unarchive [-w <id>] [--background]               # Unarchive worktree.
supacode worktree delete [-w <id>] [--background]                  # Delete worktree.
supacode worktree pin [-w <id>] [--background]                     # Pin worktree.
supacode worktree unpin [-w <id>] [--background]                   # Unpin worktree.
supacode worktree appearance [-w <id>] [--title <title>] [--color <value>]  # Read stored title/tint overrides; flags update them (empty title or color none clears).
```

### Pane

A pane is a split-tree leaf holding a strip of tabs. `-w` defaults to the
focused worktree; `--task` to `$SUPACODE_TASK_ID` in your own worktree, else
the task the worktree shows; `-p` defaults to the focused pane. `-p` accepts a
pane, tab, or content UUID. Every pane command takes `--task <id>`.

```
supacode pane list [-w <id>] [-f]                                   # List pane UUIDs (-f = focused only).
supacode pane focus [-w <id>] [-p <id>] [-d l|r|u|d]                # Focus a pane by id, or its neighbor by direction.
supacode pane split [-w <id>] [-p <token>] [-d h|v] [-i <cmd>] [-n <uuid>] [--background]  # Split into a new pane (prints the new tab UUID).
supacode pane close [-w <id>] [-p <token>] [--background]           # Close a pane and all its tabs.
supacode pane zoom [-w <id>] [-p <token>]                           # Toggle a pane's zoom.
supacode pane equalize [-w <id>]                                    # Equalize every split ratio.
supacode pane window [-w <id>] [-p <token>]                         # Toggle a pane's window mode.
```

### Tab

`-t` defaults to the focused tab. Every tab command takes `--task <id>` with
the same default as pane commands.

```
supacode tab list [-w <id>] [-f]                                    # List tab UUIDs in worktree (-f = focused only).
supacode tab focus [-w <id>] [-t <id>]                              # Focus tab.
supacode tab new [-w <id>] [-i <cmd>] [-n <uuid>] [--title <title>] [-p <pane-token>] [--background]  # Create tab in a pane (prints UUID to stdout).
supacode tab rename [-w <id>] [-t <id>] --title <title>             # Rename tab (empty title clears override; script tabs are locked).
supacode tab move [-w <id>] [-t <id>] -d l|r|u|d [--background]     # Move a tab into a new split.
supacode tab close [-w <id>] [-t <id>] [--background]               # Close tab.
```

### Surface (deprecated)

A surface is now a tab's content. These commands still work and still read the
deprecated `$SUPACODE_TAB_ID` / `$SUPACODE_SURFACE_ID`, but they are deprecated
and **will be removed in the next release**; prefer the pane/tab equivalents.

```
supacode surface split …   # Deprecated: use `supacode pane split`.
supacode surface focus …   # Deprecated: use `supacode tab focus`.
supacode surface close …   # Deprecated: use `supacode tab close`.
supacode surface list …    # Deprecated: use `supacode tab list`.
```

### Agent

Address running coding agents. `<target>` is an agent name (from `agent rename`),
a worktree ID, or a branch. With several same-kind agents on one worktree,
`--agent <kind>` picks the harness and `--task <id>` picks the task; with no
`--task`, `$SUPACODE_TASK_ID` breaks the tie only when exactly one candidate is
on this terminal's task, otherwise the command fails listing `--task` values.
A resolved target reaches exactly that agent, never a same-kind sibling.

```
supacode agent list [--json]                                        # Running agents: name, kind, state, repo, branch, worktree ID, taskID.
supacode agent rename <target> <name> | --clear [--agent <kind>] [--task <id>]
supacode agent wait <target> [--until <state>]... [--timeout <s>] [--task <id>]   # Block until idle/done/blocked (or --until), print the row as JSON.
supacode agent prompt <target> <text> [--no-submit] [--wait] [--until <state>]... [--task <id>]
supacode agent send-keys <target> <key>... [--task <id>]            # enter, esc, tab, up, down, ctrl+<letter>, ...
supacode agent read <target> [--lines <n>] [--task <id>]            # Tail of the screen hosting the agent.
supacode agent explain <target> [--json] [--task <id>]              # Why the agent is in its state.
supacode agent report-metadata <target> --token key=value [--clear] [--task <id>]
supacode agent resume-candidates [--json]                           # Dead sessions that can be resumed.
supacode agent resume <worktree-or-branch> [--agent <kind>] [--task <id>] [--dry-run]  # Relaunch a dead session into its task.
supacode terminal wait-output <target> --regex <pattern> | --text <literal>   # Poll the target's terminal until a line matches.
```

### Repository

```
supacode repo list                                                     # List repository IDs.
supacode repo open <path>                                              # Open repository.
supacode repo worktree-new [-r <id>] [--branch <name>] [--base <ref>] [--upstream <ref> | --no-upstream] [--fetch] [--name <folder>] [--location <dir>] [--pin] [--background]  # Create worktree (prints the new worktree ID to stdout; --upstream sets the new branch's tracking branch, --no-upstream clears it; --pin pins it as soon as creation starts, local repositories only).
```

### Settings

```
supacode settings [<section>]        # Open settings (general|notifications|worktrees|developer|shortcuts|scripts|updates|github).
supacode settings repo [-r <id>]     # Open repository settings.
supacode settings repo scripts [-r <id>]  # Open repository Scripts settings.
```

### Socket

```
supacode socket                      # List active socket paths.
```

## Output Formats

`list` commands output one ID per line: percent-encoded paths for worktrees and
repositories, UUIDs for panes and tabs. Use these IDs directly as `-w`, `-p`,
`-t`, `-r`, `-c` flag values.

`worktree list` filters with `--status main|pinned|unpinned|archived`
(comma-separated) or `--not-archived` (not both); `--with-status` appends a
tab-separated status column.

`worktree status` outputs `status=<value>`, `archived=<true|false>`, and
`focused=<true|false>` for a single worktree.

`worktree script list` outputs tab-separated `<uuid>\t<kind>\t<displayName>`
rows. When stdout is a TTY, running scripts are ANSI-underlined; captured or
piped output carries no running indicator.

`worktree appearance` with no flags outputs `title=<stored override>`,
`color=<stored override or none>`, and `displayTitle=<effective title>`.
With `--title` / `--color`, omitted update flags preserve existing values;
`--title ""` clears the title override and `--color none` clears the tint.

## Background Mode

Pass `--background` when acting on behalf of a user working elsewhere: it
leaves the sidebar selection and keyboard focus untouched, and new panes and
tabs stay in the background instead of becoming active. It is accepted by every
action that would otherwise focus its target (`tab new`, `tab move`,
`pane split`, `pane close`, `repo worktree-new`, `worktree run`/`stop`/
`archive`/`unarchive`/`delete`/`pin`/`unpin`, and `tab close`); the `focus`,
`zoom`, `equalize`, and `window` commands do not accept it.

## Flag Reference

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--worktree` | `-w` | focused worktree | Worktree ID. |
| `--task` | - | `$SUPACODE_TASK_ID` in its own worktree, else the shown task | Task ID (UUID) for pane, tab, and agent commands. |
| `--pane` | `-p` | focused pane | Pane token: a pane, tab, or content UUID. |
| `--tab` | `-t` | focused tab | Tab UUID. |
| `--script` | `-c` | - | Script UUID (for `worktree run`/`stop`). |
| `--title` | - | - | Tab title for `tab new`/`rename`, or sidebar title for `worktree appearance`; an empty string clears it for `rename` and `appearance` (rejected by `tab new`). |
| `--color` | - | - | Sidebar tint override; pass `none` to clear. |
| `--repo` | `-r` | `$SUPACODE_REPO_ID` | Repository ID. |
| `--input` | `-i` | - | Command to run in the terminal. |
| `--direction` | `-d` | `horizontal` | Split direction (`h`/`v`) for splits; neighbor direction (`l`/`r`/`u`/`d`) for `pane focus` and `tab move`. |
| `--id` | `-n` | random | UUID for a new tab. |
| `--focused` | `-f` | - | Print only the focused item in `list` commands. |
| `--background` | - | - | Do not move the selection or focus; see Background Mode. |
| `--surface` | `-s` | `$SUPACODE_SURFACE_ID` | Deprecated. Surface UUID for the deprecated `surface` commands. |
| `--timeout` | - | app default | Seconds to wait for the app's response; `0` waits indefinitely. |
