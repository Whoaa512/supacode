import Foundation

private nonisolated let agentsSidebarLogger = SupaLogger("Settings")

/// One token in an Agents-tab row line. Semantic tokens name a field of the
/// dashboard entry; `$<key>` addresses a display-only metadata token the agent
/// reported over `supacode agent report-metadata`.
public nonisolated enum AgentRowToken: String, CaseIterable, Sendable {
  case stateIcon = "state_icon"
  /// The agent's user-assigned name, falling back to its kind.
  case agent
  case agentKind = "agent_kind"
  case repo
  case branch
  case worktree
  case stateText = "state_text"

  public static let metadataPrefix = "$"

  /// Whether the resolver understands `raw`. A bare `$` addresses nothing.
  public static func isSupported(_ raw: String) -> Bool {
    guard !raw.hasPrefix(metadataPrefix) else { return raw.count > 1 }
    return AgentRowToken(rawValue: raw) != nil
  }

  /// The metadata key `raw` addresses, or nil when it is not a `$` token.
  public static func metadataKey(of raw: String) -> String? {
    guard raw.hasPrefix(metadataPrefix), raw.count > 1 else { return nil }
    return String(raw.dropFirst())
  }

  /// Validation hint shown by the Settings editor.
  public static let help = allCases.map(\.rawValue).joined(separator: ", ") + ", $<metadata-key>"
}

/// Row layout for the sidebar's Agents tab: one line per row, each line an
/// ordered token list. `rowsByAgent` overrides `rows` for a single agent kind
/// (`SkillAgent` raw value). Lives in `supacode.json` under
/// `global.agentsSidebar`, with a Settings-UI counterpart writing the same keys.
public nonisolated struct AgentsSidebarSettings: Codable, Equatable, Sendable {
  public var rows: [[String]]
  public var rowsByAgent: [String: [[String]]]

  /// Renders identically to the pre-configuration Agents tab, so the default
  /// config is also the "use the built-in layout" signal (see `rows(forAgentKind:)`).
  public static let defaultRows: [[String]] = [
    [AgentRowToken.stateIcon.rawValue, AgentRowToken.agent.rawValue],
    [AgentRowToken.repo.rawValue, AgentRowToken.branch.rawValue],
  ]

  public static let `default` = AgentsSidebarSettings(rows: defaultRows, rowsByAgent: [:])

  enum CodingKeys: String, CodingKey {
    case rows
    case rowsByAgent
  }

  public init(rows: [[String]] = AgentsSidebarSettings.defaultRows, rowsByAgent: [String: [[String]]] = [:]) {
    let sanitized = Self.sanitized(rows)
    self.rows = sanitized.isEmpty ? Self.defaultRows : sanitized
    self.rowsByAgent = rowsByAgent.compactMapValues { lines in
      let sanitized = Self.sanitized(lines)
      return sanitized.isEmpty ? nil : sanitized
    }
  }

  /// Every failure mode collapses to the defaults: a hand-edited file must not
  /// be able to empty the Agents tab.
  public init(from decoder: any Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      self = .default
      return
    }
    let rows = (try? container.decodeIfPresent([[String]].self, forKey: .rows)) ?? nil
    let byAgent = (try? container.decodeIfPresent([String: [[String]]].self, forKey: .rowsByAgent)) ?? nil
    if rows == nil, byAgent == nil, !container.allKeys.isEmpty {
      agentsSidebarLogger.warning("Malformed `agentsSidebar` config; falling back to the default rows.")
    }
    self.init(rows: rows ?? Self.defaultRows, rowsByAgent: byAgent ?? [:])
  }

  /// True when nothing has been customized, which lets the Agents tab keep its
  /// built-in rendering path instead of resolving generic segments.
  public var isDefault: Bool { rows == Self.defaultRows && rowsByAgent.isEmpty }

  /// The lines to render for one agent kind, or nil to use the built-in layout.
  /// A per-agent override wins even when the global rows are the defaults.
  public func rows(forAgentKind kind: String) -> [[String]]? {
    if let override = rowsByAgent[kind] { return override }
    return rows == Self.defaultRows ? nil : rows
  }

  // MARK: - Text form (the Settings editor's shape).

  /// One row per line, tokens separated by whitespace.
  public static func rows(fromText text: String) -> [[String]] {
    text.split(separator: "\n").map { line in
      line.split(whereSeparator: \.isWhitespace).map(String.init)
    }
  }

  public var rowsText: String {
    rows.map { $0.joined(separator: " ") }.joined(separator: "\n")
  }

  /// Drops empty lines, unsupported tokens (with a warning), and whitespace.
  static func sanitized(_ rows: [[String]]) -> [[String]] {
    var lines: [[String]] = []
    for row in rows {
      var kept: [String] = []
      for raw in row {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { continue }
        guard AgentRowToken.isSupported(token) else {
          agentsSidebarLogger.warning(
            "Ignoring unsupported Agents row token '\(token)'. Supported: \(AgentRowToken.help).")
          continue
        }
        kept.append(token)
      }
      guard !kept.isEmpty else { continue }
      lines.append(kept)
    }
    return lines
  }
}
