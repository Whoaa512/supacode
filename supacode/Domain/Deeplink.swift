import Foundation

/// A parsed deeplink action from a `supacode://` URL.
enum Deeplink: Equatable, Sendable {
  case open
  case help
  /// `worktree/<worktree-id>[/task/<task-id>][/<action>...]`. The task segment
  /// picks one of the directory's tasks for an action that carries no tab,
  /// pane or surface id; without it such an action goes to the task the
  /// directory shows.
  case worktree(id: Worktree.ID, action: WorktreeAction, background: Bool = false, task: LayoutID? = nil)
  case repoOpen(path: URL)
  case repoWorktreeNew(
    repositoryID: Repository.ID,
    branch: String?,
    baseRef: String?,
    /// Raw `upstream` query value (omitted / empty / ref); parsed at execution
    /// so the parser stays dumb.
    upstream: String? = nil,
    fetchOrigin: Bool,
    worktreeName: String?,
    worktreePath: String?,
    background: Bool = false,
    pin: Bool = false
  )
  /// `agent/<worktree-id>/<agent-kind>/<action>`. The kind stays a raw string so
  /// the parser doesn't have to know the `SkillAgent` roster.
  case agent(worktreeID: Worktree.ID, agent: String, action: AgentAction)
  case session(key: SessionKey, action: SessionAction)
  case settings(section: DeeplinkSettingsSection?)
  case settingsRepo(repositoryID: Repository.ID)
  case settingsRepoScripts(repositoryID: Repository.ID)

  enum AgentAction: Equatable, Sendable {
    /// `nil` clears the agent's name.
    case rename(name: String?)
    /// Types `text` into the agent's surface. `submit` also sends the enter
    /// sequence, which is what makes the agent start the turn.
    case prompt(text: String, submit: Bool)
    /// Raw key names (see `AgentKeySequence`), sent in order.
    case sendKeys(keys: [String])
    /// Display-only metadata tokens. `clear` drops every token; otherwise the
    /// listed tokens are merged over the existing ones.
    case metadata(tokens: [String: String], clear: Bool)
    /// Types the agent's native resume command into the surface that hosted its
    /// dead session. Refused when the agent is running, so it can never fork a
    /// live session.
    case resume
  }

  enum SessionAction: Equatable, Sendable {
    case settle
    case unsettle
  }

  enum WorktreeAction: Equatable, Sendable {
    case select
    case run
    case stop
    case runScript(scriptID: UUID)
    case stopScript(scriptID: UUID)
    case archive
    case unarchive
    case delete
    case pin
    case unpin
    /// Raw appearance values from the URL; parsed at execution so the parser
    /// stays dumb. `nil` means the query item was omitted and should be preserved.
    case appearance(title: String?, color: String?)
    case tab(tabID: UUID)
    case tabNew(input: String?, id: UUID?, title: String? = nil, pane: UUID? = nil)
    case tabRename(tabID: UUID, title: String)
    case tabDestroy(tabID: UUID)
    /// Moves a tab into a fresh split neighboring its current pane.
    case tabMove(tabID: UUID, direction: TerminalSplitMenuDirection)
    /// Focus the pane resolved from a token (its own id, or a tab / content it hosts).
    case paneFocus(token: UUID)
    /// Move focus to the pane neighboring the focused one.
    case paneFocusDirection(direction: TerminalSplitMenuDirection)
    /// Split a pane, opening a fresh tab in the new pane. `token` is the pane's
    /// own id or the id of a tab / content it hosts.
    case paneSplit(token: UUID, direction: SplitDirection, input: String?, id: UUID?)
    case paneDestroy(token: UUID)
    case paneZoom(token: UUID)
    /// Toggle window mode for the pane addressed by `token`.
    case paneWindow(token: UUID)
    case paneEqualize
    case surface(tabID: UUID, surfaceID: UUID, input: String?)
    case surfaceSplit(tabID: UUID, surfaceID: UUID, direction: SplitDirection, input: String?, id: UUID?)
    case surfaceDestroy(tabID: UUID, surfaceID: UUID)

    /// The pane, tab and surface ids the action addresses, most specific
    /// first. Ids it only proposes for something new are not listed.
    var addressedIDs: [UUID] {
      switch self {
      case .tab(let tabID), .tabRename(let tabID, _), .tabDestroy(let tabID), .tabMove(let tabID, _):
        [tabID]
      case .tabNew(_, _, _, let pane):
        pane.map { [$0] } ?? []
      case .paneFocus(let token), .paneSplit(let token, _, _, _), .paneDestroy(let token), .paneZoom(let token),
        .paneWindow(let token):
        [token]
      case .surface(let tabID, let surfaceID, _), .surfaceSplit(let tabID, let surfaceID, _, _, _),
        .surfaceDestroy(let tabID, let surfaceID):
        [surfaceID, tabID]
      case .select, .run, .stop, .runScript, .stopScript, .archive, .unarchive, .delete, .pin, .unpin,
        .appearance, .paneFocusDirection, .paneEqualize:
        []
      }
    }

    /// Whether dispatching this action should also select / focus the worktree.
    /// Metadata-only updates (appearance, tab rename) skip it so they don't steal focus.
    var selectsWorktree: Bool {
      switch self {
      case .appearance, .tabRename: false
      default: true
      }
    }
  }

  /// Settings sections reachable via deeplink.
  enum DeeplinkSettingsSection: String, Equatable, Sendable {
    case general
    case notifications
    case worktrees
    case developer
    case shortcuts
    case scripts
    case updates
    case github
    case forges
  }
}
