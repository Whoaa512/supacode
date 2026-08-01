import SwiftUI

struct CLIReferenceView: View {
  var body: some View {
    Form {
      // swiftlint:disable line_length
      Section {
        Text(
          "The \(code("supacode")) command is available in all Supacode terminal sessions. Run \(code("supacode --help")) for built-in usage information."
        )
        .foregroundStyle(.secondary)
        Text(
          "Inside a Supacode terminal, flags default to the current session's IDs. Outside, pass explicit IDs from \(code("supacode worktree list")) or \(code("supacode repo list"))."
        )
        .foregroundStyle(.secondary)
        Text(
          "Commands that create resources (\(code("tab new")), \(code("surface split"))) print the new UUID to stdout. Capture it to target the resource afterward."
        )
        .foregroundStyle(.secondary)
        // swiftlint:enable line_length
      } header: {
        Text("CLI Reference").font(.title.bold())
        Text("Control Supacode from the terminal.")
      }

      CLISection(title: "App", rows: Self.appRows)
      CLISection(title: "Worktree", rows: Self.worktreeRows)
      CLISection(title: "Tab", rows: Self.tabRows)
      CLISection(title: "Surface", rows: Self.surfaceRows)
      CLISection(title: "Agent", rows: Self.agentRows)
      CLISection(title: "Terminal", rows: Self.terminalRows)
      CLISection(title: "Repository", rows: Self.repoRows)
      CLISection(title: "Settings", rows: Self.settingsRows)
      CLISection(title: "Socket", rows: Self.socketRows)

      Section("Flags") {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
          ForEach(Self.flagRows) { row in
            GridRow {
              Text(row.command)
                .font(.body.monospaced())
                .gridColumnAlignment(.leading)
              Text(row.description)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            }
          }
        }
      }
    }
    .textSelection(.enabled)
    .formStyle(.grouped)
    .frame(minWidth: 300)
    .navigationTitle("")
  }

  // MARK: - Row data.

  private static let appRows: [CLIEntry] = [
    .init(command: "supacode", description: "Bring Supacode to front."),
    .init(command: "supacode open", description: "Same as above."),
  ]

  private static let worktreeRows: [CLIEntry] = [
    .init(
      command: "supacode worktree list [-f] [--status <status>] [--not-archived] [--with-status]",
      description:
        "List worktree IDs. -f for focused only; --status main|pinned|unpinned|archived "
        + "or --not-archived filters; --with-status appends a status column."
    ),
    .init(
      command: "supacode worktree status [-w <id>]",
      description: "Read the worktree's sidebar status, archived flag, and focus."
    ),
    .init(command: "supacode worktree focus [-w <id>]", description: "Focus a worktree."),
    .init(
      command: "supacode worktree run [-w <id>] [-c <uuid>]",
      description: "Run a script. Defaults to the primary run-kind script; -c targets a specific one."
    ),
    .init(
      command: "supacode worktree stop [-w <id>] [-c <uuid>]",
      description: "Stop a script. Defaults to all run-kind scripts; -c targets a specific one."
    ),
    .init(
      command: "supacode worktree script list [-w <id>]",
      description: "List configured scripts. Underlined rows are currently running."
    ),
    .init(command: "supacode worktree archive [-w <id>]", description: "Archive the worktree."),
    .init(command: "supacode worktree unarchive [-w <id>]", description: "Unarchive the worktree."),
    .init(command: "supacode worktree delete [-w <id>]", description: "Delete the worktree."),
    .init(command: "supacode worktree pin [-w <id>]", description: "Pin the worktree."),
    .init(command: "supacode worktree unpin [-w <id>]", description: "Unpin the worktree."),
    .init(
      command: "supacode worktree appearance [-w <id>] [--title <title>] [--color <value>]",
      description: "No flags reads stored title/tint overrides plus displayTitle; omitted update flags preserve values."
    ),
  ]

  private static let tabRows: [CLIEntry] = [
    .init(command: "supacode tab list [-w <id>] [-f]", description: "List tab UUIDs. -f for focused only."),
    .init(command: "supacode tab focus [-w <id>] [-t <id>]", description: "Focus a tab."),
    .init(
      command: "supacode tab new [-w <id>] [-i <cmd>] [-n <uuid>] [--title <title>]",
      description: "Create a named tab. Prints UUID to stdout."
    ),
    .init(
      command: "supacode tab rename [-w <id>] [-t <id>] --title <title>",
      description:
        "Set the persistent title override; an empty title clears it. Script tabs are locked."
    ),
    .init(command: "supacode tab close [-w <id>] [-t <id>]", description: "Close a tab."),
  ]

  private static let surfaceRows: [CLIEntry] = [
    .init(
      command: "supacode surface list [-w <id>] [-t <id>] [-f]",
      description: "List surface UUIDs. -f for focused only."
    ),
    .init(
      command: "supacode surface focus [-w <id>] [-t <id>] [-s <id>] [-i <cmd>]",
      description: "Focus a surface."
    ),
    .init(
      command: "supacode surface split [-w <id>] [-t <id>] [-s <id>] [-d h|v] [-i <cmd>] [-n <uuid>]",
      description: "Split a surface. Prints UUID to stdout."
    ),
    .init(
      command: "supacode surface close [-w <id>] [-t <id>] [-s <id>]",
      description: "Close a surface."
    ),
  ]

  private static let agentRows: [CLIEntry] = [
    .init(
      command: "supacode agent list [--json]",
      description:
        "List running agents: name, kind, state, repo, branch, worktree ID. "
        + "Blocked rows are underlined."
    ),
    .init(
      command: "supacode agent rename <target> <name> | --clear [--agent <kind>]",
      description:
        "Name a running agent ([a-z][a-z0-9_-]*, unique among live agents). "
        + "Target is a name, worktree ID, or branch."
    ),
    .init(
      command: "supacode agent wait <target> [--until <state>]... [--timeout <seconds>]",
      description:
        "Block until the agent reaches a state (default idle, done, or blocked), "
        + "then print its row as JSON."
    ),
    .init(
      command: "supacode agent prompt <target> <text> [--no-submit] [--wait] [--until <state>]...",
      description:
        "Type a prompt into a running agent and submit it. With --wait, block until the agent "
        + "starts the turn (else fail as agent_prompt_stalled) and then settles."
    ),
    .init(
      command: "supacode agent send-keys <target> <key>...",
      description:
        "Send keys: enter, esc, tab, backspace, space, up, down, left, right, home, end, "
        + "pageup, pagedown, ctrl+<letter>."
    ),
    .init(
      command: "supacode agent read <target> [--lines <n>]",
      description: "Print the tail of the terminal screen hosting the agent (default 80 lines)."
    ),
    .init(
      command: "supacode agent report-metadata <target> --token key=value [--clear]",
      description:
        "Attach display-only tokens (max 8, key ≤ 32 chars lowercase, value ≤ 120 chars). "
        + "The `summary` token renders in the Agents tab; tokens never affect state or waits."
    ),
  ]

  private static let terminalRows: [CLIEntry] = [
    .init(
      command: "supacode terminal wait-output <target> --regex <pattern> | --text <literal>",
      description:
        "Poll the worktree's focused terminal every 500ms until a line matches, then print it. "
        + "Target is an agent name, worktree ID, or branch; defaults to $SUPACODE_WORKTREE_ID."
    ),
  ]

  private static let repoRows: [CLIEntry] = [
    .init(command: "supacode repo list", description: "List repository IDs."),
    .init(command: "supacode repo open <path>", description: "Open a repository."),
    .init(
      command:
        "supacode repo worktree-new [-r <id>] [--branch <name>] [--base <ref>] [--fetch] "
        + "[--name <folder>] [--location <dir>]",
      description: "Create a worktree in a repository."
    ),
  ]

  private static let settingsRows: [CLIEntry] = [
    .init(command: "supacode settings", description: "Open settings."),
    .init(command: "supacode settings <section>", description: "Open a specific section."),
    .init(command: "supacode settings repo [-r <id>]", description: "Open repository settings."),
  ]

  private static let socketRows: [CLIEntry] = [
    .init(command: "supacode socket", description: "List active socket paths.")
  ]

  private static let flagRows: [CLIEntry] = [
    .init(command: "-w, --worktree", description: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID."),
    .init(command: "-t, --tab", description: "Tab UUID. Defaults to $SUPACODE_TAB_ID."),
    .init(command: "-s, --surface", description: "Surface UUID. Defaults to $SUPACODE_SURFACE_ID."),
    .init(command: "-c, --script", description: "Script UUID (for `worktree run`/`stop`)."),
    .init(
      command: "--title",
      description: "Tab title for tab new/rename, or sidebar title for worktree appearance; empty clears."),
    .init(command: "--color", description: "Sidebar tint override; pass none to clear."),
    .init(command: "-r, --repo", description: "Repository ID. Defaults to $SUPACODE_REPO_ID."),
    .init(command: "-i, --input", description: "Command to run in the terminal."),
    .init(command: "-d, --direction", description: "Split direction: horizontal (h) or vertical (v)."),
    .init(command: "-n, --id", description: "UUID for a new tab or surface."),
    .init(command: "-f, --focused", description: "Print only the focused item in list commands."),
  ]
}

// MARK: - Components.

private struct CLIEntry: Identifiable {
  let id = UUID()
  let command: String
  let description: String
}

private struct CLISection: View {
  let title: String
  let rows: [CLIEntry]

  var body: some View {
    Section(title) {
      Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
        ForEach(rows) { row in
          GridRow {
            Text(row.command)
              .font(.body.monospaced())
              .gridColumnAlignment(.leading)
            Text(row.description)
              .foregroundStyle(.secondary)
              .gridColumnAlignment(.leading)
          }
        }
      }
    }
  }
}

/// Inline code fragment styled as monospaced primary foreground.
private func code(_ value: String) -> Text {
  Text(value).monospaced().foregroundStyle(.primary)
}
