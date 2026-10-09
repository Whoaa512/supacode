import ArgumentParser
import Foundation

/// Resolves CLI resource ids from explicit flags, session env vars, or the
/// app's focused row.
enum IDResolvers {
  /// Resolves a worktree ID from an explicit flag or `$SUPACODE_WORKTREE_ID`.
  nonisolated static func resolveWorktreeID(_ explicit: String?) throws -> String {
    guard let id = Self.nonEmpty(explicit) ?? EnvironmentDefaults.worktreeID else {
      throw ValidationError(
        "Missing worktree ID. Pass -w <id> or run inside a Supacode terminal ($SUPACODE_WORKTREE_ID)."
      )
    }
    return id
  }

  /// Resolves a tab ID from an explicit flag or `$SUPACODE_TAB_ID`.
  nonisolated static func resolveTabID(_ explicit: String?) throws -> String {
    guard let id = Self.nonEmpty(explicit) ?? EnvironmentDefaults.tabID else {
      throw ValidationError(
        "Missing tab ID. Pass -t <id> or run inside a Supacode terminal ($SUPACODE_TAB_ID)."
      )
    }
    return id
  }

  /// Resolves a surface ID from an explicit flag or `$SUPACODE_SURFACE_ID`.
  nonisolated static func resolveSurfaceID(_ explicit: String?) throws -> String {
    guard let id = Self.nonEmpty(explicit) ?? EnvironmentDefaults.surfaceID else {
      throw ValidationError(
        "Missing surface ID. Pass -s <id> or run inside a Supacode terminal ($SUPACODE_SURFACE_ID)."
      )
    }
    return id
  }

  /// Resolves the worktree for a go-forward command: the explicit flag, else the
  /// app's focused worktree. Never reads the deprecated `$SUPACODE_WORKTREE_ID`.
  nonisolated static func resolveFocusedWorktreeID(_ explicit: String?, timeoutSeconds: Int) throws -> String {
    try Self.resolveFocused(
      explicit, resource: "worktrees", timeoutSeconds: timeoutSeconds,
      noneFocused: "No worktree is focused. Pass -w <id> (see `supacode worktree list`).")
  }

  /// Resolves the task a worktree-addressed command means: the explicit flag,
  /// else this terminal's own task when the command targets this terminal's
  /// own worktree, else none (the app picks the task the worktree shows). The
  /// environment's task belongs to the environment's worktree, so it is never
  /// applied to another one.
  nonisolated static func resolveTaskID(
    _ explicit: String?, worktreeID: String, environmentWorktreeID: String?, environmentTaskID: String?
  ) -> String? {
    if let explicit = Self.nonEmpty(explicit) { return explicit }
    guard let task = Self.nonEmpty(environmentTaskID), let home = Self.nonEmpty(environmentWorktreeID),
      Self.comparableWorktreeID(home) == Self.comparableWorktreeID(worktreeID)
    else { return nil }
    return task
  }

  /// A worktree id with its encoding and trailing slash taken out, so the
  /// app's and the environment's spelling of one path compare equal.
  private nonisolated static func comparableWorktreeID(_ value: String) -> String {
    let decoded = value.removingPercentEncoding ?? value
    return decoded.hasSuffix("/") && decoded.count > 1 ? String(decoded.dropLast()) : decoded
  }

  /// Resolves the pane token for a go-forward command: the explicit flag, else the
  /// app's focused pane. Never reads a session env var.
  nonisolated static func resolveFocusedPaneToken(
    _ explicit: String?, target: WorktreeTarget, timeoutSeconds: Int
  ) throws -> String {
    try Self.resolveFocused(
      explicit, resource: "panes", params: target.queryParams, timeoutSeconds: timeoutSeconds,
      noneFocused: "No pane is focused in this worktree. Pass -p <id> (see `supacode pane list`).")
  }

  /// Resolves the tab for a go-forward command: the explicit flag, else the app's
  /// focused tab. Never reads the deprecated `$SUPACODE_TAB_ID`.
  nonisolated static func resolveFocusedTabID(
    _ explicit: String?, target: WorktreeTarget, timeoutSeconds: Int
  ) throws -> String {
    try Self.resolveFocused(
      explicit, resource: "tabs", params: target.queryParams, timeoutSeconds: timeoutSeconds,
      noneFocused: "No tab is focused in this worktree. Pass -t <id> (see `supacode tab list`).")
  }

  /// Throws unless `newID` is nil or a well-formed UUID.
  nonisolated static func validateNewID(_ newID: String?) throws {
    if let newID, UUID(uuidString: newID) == nil {
      throw ValidationError("--id must be a UUID.")
    }
  }

  /// Resolves a repo ID from an explicit flag or `$SUPACODE_REPO_ID`, percent-encoded.
  nonisolated static func resolveRepoID(_ explicit: String?) throws -> String {
    if let explicit = Self.nonEmpty(explicit) {
      return Self.normalizeRepoID(explicit)
    }
    guard let id = EnvironmentDefaults.repoID else {
      throw ValidationError(
        "Missing repo ID. Pass -r <id> or run inside a Supacode terminal ($SUPACODE_REPO_ID)."
      )
    }
    return id
  }

  /// Validates that a `--script` argument is a well-formed UUID and returns
  /// the canonical `UUID.uuidString` form (uppercased). Fails early so the
  /// CLI surfaces a helpful error before dispatching an unparsable deeplink.
  nonisolated static func validatedScriptID(_ raw: String) throws -> String {
    guard let uuid = UUID(uuidString: raw) else {
      throw ValidationError(
        "Invalid --script value: expected a UUID. Run `supacode worktree script list` to list script IDs."
      )
    }
    return uuid.uuidString
  }

  /// Explicit flag, else the resource's focused row, else a validation error.
  private nonisolated static func resolveFocused(
    _ explicit: String?, resource: String, params: [String: String] = [:],
    timeoutSeconds: Int, noneFocused: String
  ) throws -> String {
    if let id = Self.nonEmpty(explicit) { return id }
    let items = try QueryDispatcher.query(resource: resource, params: params, timeoutSeconds: timeoutSeconds)
    guard let focused = items.first(where: { !($0["focused"] ?? "").isEmpty })?["id"] else {
      throw ValidationError(noneFocused)
    }
    return focused
  }

  private nonisolated static func normalizeRepoID(_ value: String) -> String {
    var decoded = value.removingPercentEncoding ?? value
    if !decoded.hasSuffix("/") { decoded += "/" }
    let allowed = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
    return decoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? decoded
  }

  private nonisolated static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}
