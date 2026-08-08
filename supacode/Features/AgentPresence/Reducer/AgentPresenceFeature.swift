import ComposableArchitecture
import Darwin
import Foundation
import Sharing
import SupacodeSettingsShared

@Reducer
struct AgentPresenceFeature {
  /// Activity state per (surface, agent), set atomically by the wire events.
  /// Canonical lifecycle for the two attention states:
  ///
  /// - `error`: the turn died, so no `idle` ever follows it. Sticky, and only
  ///   `busy` (a new turn), `sessionStart` (a restart), or `clearAttention`
  ///   (the user focused the surface) may leave it. Any other event is dropped,
  ///   or Claude's 60s-idle `Notification` would quietly downgrade it.
  /// - `compacting`: transient, cleared by the turn's next event or by the
  ///   `sessionStart` Claude fires once compaction finishes.
  enum Activity: String, Sendable, Equatable {
    case awaitingInput
    case busy
    case idle
    case error
    case compacting

    /// Counts as the agent working: the row shimmers. Compaction happens inside a
    /// running turn, so it must not read as a stalled agent.
    var isWorking: Bool { self == .busy || self == .compacting }

    /// Parked on the user, so focusing the surface answers it.
    var isAttention: Bool { self == .error || self == .awaitingInput }
  }

  /// One badge worth of state. Surface ID is redundant; callers scope by surface set.
  struct AgentInstance: Hashable, Sendable {
    let agent: SkillAgent
    let activity: Activity
    /// The agent's last turn finished while the user wasn't looking at its
    /// surface. Only meaningful on `.idle`; the Agents dashboard maps it to
    /// `done` so a finished turn reads differently from a never-started one.
    var isDoneUnseen = false
    /// User-assigned name (`supacode agent rename`, sidebar context menu).
    /// Ephemeral: it dies with the record, so `nil` is the common case.
    var name: String?
    /// Display-only metadata tokens (`supacode agent report-metadata`). They
    /// never feed state, rollups, or waits — only row rendering.
    var metadata: [String: String] = [:]

    /// The one token the built-in row layout renders as a caption.
    var summary: String? { metadata[AgentPresenceFeature.summaryToken] }

    /// The avatar group flips contrast on awaiting-input instances.
    var awaitingInput: Bool { activity == .awaitingInput }
  }

  /// Everything one sidebar row shows about its agents, fanned out as a single
  /// value so a new flag doesn't grow the action or its dirty check. Compaction
  /// needs no entry: the badge carries it, and the row treats it as work.
  struct RowSnapshot: Equatable, Sendable {
    var agents: [AgentInstance] = []
    var isWorking = false
    var hasError = false
    /// When the newest errored record on these surfaces *entered* `.error`. The
    /// task inbox needs the *instant* of the failure, not just the fact of it:
    /// only an error newer than a snooze re-surfaces a parked row (A25).
    /// Deliberately not gated by the badge toggle — a display preference must
    /// not silently disable a wake signal.
    var errorAt: Date?
    /// When the newest turn that ended unseen on these surfaces *ended*.
    /// Cleared by focus, exactly like `isDoneUnseen`, so a finished turn the
    /// user already looked at stops holding a row out of the snoozed shelf.
    var completedTurnAt: Date?
  }

  // `nonisolated` so `stageRestore` (off-main at launch) can use Hashable.
  nonisolated struct PresenceKey: Hashable, Sendable {
    let agent: SkillAgent
    let surfaceID: UUID
  }

  nonisolated struct PresenceRecord: Equatable, Sendable {
    var activity: Activity = .idle
    /// Set when a working turn ends on an unfocused surface; cleared by focus
    /// (`clearAttention`) or by the next turn (`busy` / `sessionStart`).
    var isDoneUnseen = false
    /// The instant of the transition *into* `.error`, not the last time this
    /// record heard anything. Every hook event refreshes `lastEventAt` — a
    /// `Notification` on a dead session does it without changing state at all —
    /// so reading the failure instant off `lastEventAt` makes an error look
    /// perpetually fresh and re-wakes a snoozed task forever. Cleared when the
    /// record leaves `.error`.
    var erroredAt: Date?
    /// The instant the working turn ended, stamped where `isDoneUnseen` latches.
    /// Same reasoning as `erroredAt`: the completion instant must not slide
    /// forward on unrelated traffic. Cleared wherever `isDoneUnseen` clears.
    var turnCompletedAt: Date?
    /// Local pids attributed to this record. Empty means the OSC presence was
    /// emitted without a local pid (SSH attach); `pids.isEmpty` is the
    /// discriminator for the pid-less lifecycle branches below. Every event
    /// arrives over OSC now, so there is no "socket-owned" record to defend
    /// against.
    var pids: Set<pid_t>
    /// Diagnostics for `supacode agent explain`. Never authoritative for state,
    /// never persisted: they describe the last wire event this record saw.
    var lastEventName: String?
    /// The hook's own `ts`, not a locally sampled clock: an event that arrived
    /// without a timestamp reports `nil` rather than a plausible-looking lie.
    var lastEventAt: Date?
    /// `"busy→idle"` for the last activity flip this record made.
    var lastTransition: String?
    /// The agent's native session id, as last reported by a hook event that
    /// carried one. Unlike the diagnostics above this IS persisted: it is the
    /// only thing that makes a dead session resumable after a relaunch. Sticky
    /// on purpose — an event without a ref never clears an established one.
    var sessionRef: String?
  }

  /// A session whose process didn't survive: the record was persisted with pids,
  /// every one of them was dead at restore, and it carried a resumable ref.
  /// Deliberately NOT a `PresenceRecord`: a candidate is not a live agent, so it
  /// must never reach a badge, `agent list`, or a state rollup.
  nonisolated struct ResumeCandidate: Equatable, Sendable {
    let sessionRef: String
    /// The activity the session was in when the app went away. Display only.
    let lastActivity: Activity
  }

  nonisolated struct RestoredRecord: Sendable {
    let alivePids: Set<pid_t>
    let activity: Activity
    var isDoneUnseen = false
    var sessionRef: String?
  }

  // `nonisolated` is load-bearing here. Without it the @Reducer macro
  // propagates main-actor isolation onto CancelID's Hashable witness, which
  // then can't satisfy the Sendable requirement in `.cancellable(id:)`.
  nonisolated enum CancelID: Hashable, Sendable { case livenessSweep }

  enum Action {
    case delegate(Delegate)
    case hookEventReceived(AgentHookEvent)
    case livenessSweepTick
    case livenessSweepResult(snapshot: [PresenceKey: Set<pid_t>], alive: [PresenceKey: Set<pid_t>])
    case start
    case stop
    case surfaceClosed(UUID)
    case surfacesClosed(Set<UUID>)
    /// Assigns (or with `nil`, clears) the user-facing name of one live agent.
    /// Invalid or already-taken names are dropped; callers that need to report
    /// the failure validate with `validate(name:)` / `isNameTaken` first.
    case renameAgent(key: PresenceKey, name: String?)
    /// Merges display-only tokens onto a live agent. `clear` drops every token
    /// first, so `clear` alone wipes the agent's metadata.
    case reportMetadata(key: PresenceKey, tokens: [String: String], clear: Bool)
    /// The user focused these surfaces, so the states parked on them (`error`,
    /// `awaitingInput`) return to `idle`.
    case clearAttention(surfaces: Set<UUID>)
    /// Stage records for the off-main liveness pass. Apply lands as
    /// `restoreFromSnapshotChecked` so `kill(2)` never runs on the main actor.
    /// The resume command was typed into the candidate's surface, so the offer is
    /// spent. Dropped rather than kept pending: the relaunched agent re-reports
    /// its own session ref, and a lingering offer would type the command twice.
    case resumeCandidateConsumed(key: PresenceKey)
    case restoreFromSnapshot(staged: [PresenceKey: StagedRestore])
    case restoreFromSnapshotChecked(
      records: [PresenceKey: RestoredRecord], resumeCandidates: [PresenceKey: ResumeCandidate])

    enum Delegate: Equatable, Sendable {
      /// Surfaces whose presence record was added, removed, or had its activity flip.
      /// Parent fans out per-row `agentSnapshotChanged` via the `surfaceToItemID` reverse index.
      case surfacesChanged(Set<UUID>)
    }
  }

  @ObservableState
  struct State: Equatable {
    /// Per-(surface, agent) record. Pids drive the liveness sweep and record
    /// disposal. Socket bridges carry a pid; the OSC-over-SSH transport seeds
    /// pid-less records that the sweep skips.
    var records: [PresenceKey: PresenceRecord] = [:]
    /// Per-surface agent presence. A surface can host multiple agents (rare,
    /// but possible if e.g. Claude spawns Codex). Order not guaranteed; sort before display.
    var bySurface: [UUID: Set<SkillAgent>] = [:]
    /// The surfaces the user is currently looking at, as last reported by
    /// `.clearAttention` (the app dispatches it from terminal focus changes).
    /// Needed because focus only arrives as a *change*: without it, a turn that
    /// finishes on the already-focused surface would latch as `done` forever.
    var focusedSurfaceIDs: Set<UUID> = []
    /// User-assigned agent names, keyed like `records`. Never persisted: a name
    /// addresses a running agent, so it must not outlive one.
    var nameByKey: [PresenceKey: String] = [:]
    /// Display-only metadata tokens reported by the agent itself
    /// (`supacode agent report-metadata`). Same lifetime as `nameByKey`:
    /// ephemeral, never persisted, never authoritative for state.
    var metadataByKey: [PresenceKey: [String: String]] = [:]
    /// Sessions that died with the last app run and can be relaunched by their
    /// native resume command. Populated only at restore; dropped as soon as a
    /// live record appears for the same key, because the agent came back on its
    /// own and resuming again would fork the session.
    var resumeCandidates: [PresenceKey: ResumeCandidate] = [:]
  }

  /// Period between liveness sweeps. Cost scales with active sessions, not
  /// with the system process count. `nonisolated` so the Reduce closure can
  /// read it without crossing main-actor isolation.
  nonisolated static let livenessSweepInterval: Duration = .seconds(2)

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(\.continuousClock) var clock
      switch action {
      case .delegate:
        return .none

      case .hookEventReceived(let event):
        let changed = Self.applyRecordingDiagnostics(event: event, into: &state)
        Self.pruneEphemeral(in: &state)
        return Self.surfacesChangedEffect(changed)

      case .livenessSweepTick:
        // Run `kill(2)` off the main actor; the reducer body is shared with action-burst paths.
        let snapshot: [PresenceKey: Set<pid_t>] = state.records
          .compactMapValues { record in record.pids.isEmpty ? nil : record.pids }
        guard !snapshot.isEmpty else { return .none }
        return .run { send in
          let alive = Self.liveness(forSnapshot: snapshot)
          guard !alive.isEmpty else { return }
          await send(.livenessSweepResult(snapshot: snapshot, alive: alive))
        }

      case .livenessSweepResult(let snapshot, let alive):
        let changed = Self.applyLiveness(delta: alive, snapshot: snapshot, into: &state)
        Self.pruneEphemeral(in: &state)
        return Self.surfacesChangedEffect(changed)

      case .start:
        return .run { send in
          for await _ in clock.timer(interval: Self.livenessSweepInterval) {
            await send(.livenessSweepTick)
          }
        }
        .cancellable(id: CancelID.livenessSweep, cancelInFlight: true)

      case .stop:
        return .cancel(id: CancelID.livenessSweep)

      case .surfaceClosed(let id):
        Self.drop(surfaces: [id], from: &state)
        return Self.surfacesChangedEffect([id])

      case .surfacesClosed(let ids):
        Self.drop(surfaces: ids, from: &state)
        return Self.surfacesChangedEffect(ids)

      case .renameAgent(let key, let name):
        guard Self.rename(key: key, to: name, into: &state) else { return .none }
        return Self.surfacesChangedEffect([key.surfaceID])

      case .reportMetadata(let key, let tokens, let clear):
        guard Self.reportMetadata(key: key, tokens: tokens, clear: clear, into: &state) else { return .none }
        return Self.surfacesChangedEffect([key.surfaceID])

      case .clearAttention(let surfaces):
        let changed = Self.clearAttention(on: surfaces, into: &state)
        return Self.surfacesChangedEffect(changed)

      case .resumeCandidateConsumed(let key):
        state.resumeCandidates.removeValue(forKey: key)
        return .none

      case .restoreFromSnapshot(let staged):
        guard !staged.isEmpty else { return .none }
        @Shared(.settingsFile) var settingsFile
        let offersResume = settingsFile.global.resumeAgentsOnRestore
        return .run { send in
          var checked: [PresenceKey: RestoredRecord] = [:]
          var candidates: [PresenceKey: ResumeCandidate] = [:]
          for (key, stage) in staged {
            let alive = stage.pids.filter { Self.isAlive($0) }
            guard alive.isEmpty else {
              checked[key] = RestoredRecord(
                alivePids: alive, activity: stage.activity, isDoneUnseen: stage.isDoneUnseen,
                sessionRef: stage.sessionRef)
              continue
            }
            // Every pid dead + a resumable ref is exactly the "the process didn't
            // survive" signal. Resumability is checked here so an agent kind with
            // no resume CLI never becomes a candidate the user can't act on.
            guard offersResume, let ref = stage.sessionRef,
              AgentResumeCommand.command(agent: key.agent, sessionRef: ref) != nil
            else { continue }
            candidates[key] = ResumeCandidate(sessionRef: ref, lastActivity: stage.activity)
          }
          guard !checked.isEmpty || !candidates.isEmpty else { return }
          await send(.restoreFromSnapshotChecked(records: checked, resumeCandidates: candidates))
        }

      case .restoreFromSnapshotChecked(let records, let candidates):
        state.resumeCandidates.merge(candidates) { existing, _ in existing }
        let changed = Self.applyRestore(records: records, into: &state)
        return Self.surfacesChangedEffect(changed)
      }
    }
  }

  private static func surfacesChangedEffect(_ surfaces: Set<UUID>) -> Effect<Action> {
    guard !surfaces.isEmpty else { return .none }
    return .send(.delegate(.surfacesChanged(surfaces)))
  }

  // MARK: - Mutators.

  /// `apply(event:)` plus the per-record diagnostics `agent explain` reports.
  /// Diagnostics are written after the fact so no mutator has to thread them,
  /// and they never widen the returned dirty-surface set: nothing renders them.
  private static func applyRecordingDiagnostics(
    event: AgentHookEvent, into state: inout State
  ) -> Set<UUID> {
    guard let agent = SkillAgent(rawValue: event.agent) else { return apply(event: event, into: &state) }
    let key = PresenceKey(agent: agent, surfaceID: event.surfaceID)
    let before = state.records[key]?.activity
    let changed = apply(event: event, into: &state)
    // A live record means the agent is running, so any resume offer for it is
    // stale: it either came back on its own or the user already resumed it.
    if state.records[key] != nil { state.resumeCandidates.removeValue(forKey: key) }
    guard var record = state.records[key] else { return changed }
    record.lastEventName = event.event
    record.lastEventAt = event.timestamp
    if let before, before != record.activity {
      record.lastTransition = "\(before.rawValue)→\(record.activity.rawValue)"
    }
    // Sticky: only a reported ref overwrites, so the events that don't carry one
    // (every tool call) can't erase the session we'd resume.
    if let sessionRef = event.sessionRef { record.sessionRef = sessionRef }
    state.records[key] = record
    return changed
  }

  /// Returns the surface IDs whose row-visible state changed, so the parent can fan
  /// out per-row `agentSnapshotChanged` deltas without inspecting `bySurface` itself.
  private static func apply(event: AgentHookEvent, into state: inout State) -> Set<UUID> {
    guard let agent = SkillAgent(rawValue: event.agent) else { return [] }
    let key = PresenceKey(agent: agent, surfaceID: event.surfaceID)
    switch event.eventName {
    case .sessionStart:
      return applySessionStart(event: event, key: key, into: &state)
    case .sessionEnd:
      if let pid = event.pid {
        guard var record = state.records[key] else { return [] }
        let removed = record.pids.remove(pid) != nil
        if record.pids.isEmpty {
          state.records.removeValue(forKey: key)
        } else {
          state.records[key] = record
        }
        rebuildPresence(forSurface: event.surfaceID, in: &state)
        return removed ? [event.surfaceID] : []
      }
      // Pid-less (OSC over SSH): only tear down a pid-less record; never one
      // that carries a tracked local pid the liveness sweep still owns.
      guard let record = state.records[key], record.pids.isEmpty else { return [] }
      state.records.removeValue(forKey: key)
      rebuildPresence(forSurface: event.surfaceID, in: &state)
      return [event.surfaceID]
    case .busy:
      return applyActivity(.busy, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .awaitingInput:
      return applyActivity(.awaitingInput, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .idle:
      return applyActivity(.idle, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .error:
      return applyActivity(.error, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .compacting:
      return applyActivity(.compacting, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .notification, .none:
      return []
    }
  }

  /// A pid is the local-hook source (OSC presence carries `pid=$__ppid` only on the
  /// local host); a missing pid is the OSC-over-SSH source, which attributes by the
  /// receiving surface and has no local pid to track. Either way the restart clears
  /// a sticky state, or an SSH session that errored would never recover.
  private static func applySessionStart(
    event: AgentHookEvent, key: PresenceKey, into state: inout State
  ) -> Set<UUID> {
    if let pid = event.pid {
      var record = state.records[key] ?? PresenceRecord(pids: [])
      let inserted = record.pids.insert(pid).inserted
      let cleared = Self.normalizeStickyOnRestart(&record)
      state.records[key] = record
      rebuildPresence(forSurface: event.surfaceID, in: &state)
      return (inserted || cleared) ? [event.surfaceID] : []
    }
    // Pid-less OSC seed: don't clobber a record that already carries a pid.
    guard var record = state.records[key] else {
      state.records[key] = PresenceRecord(pids: [])
      rebuildPresence(forSurface: event.surfaceID, in: &state)
      return [event.surfaceID]
    }
    guard Self.normalizeStickyOnRestart(&record) else { return [] }
    state.records[key] = record
    rebuildPresence(forSurface: event.surfaceID, in: &state)
    return [event.surfaceID]
  }

  /// Resets a sticky `error` / `compacting` record to `idle` on a restart.
  /// A restart is a new turn, so any unseen-done marker from the last one is stale.
  /// Returns whether it changed anything.
  private static func normalizeStickyOnRestart(_ record: inout PresenceRecord) -> Bool {
    var changed = false
    if record.isDoneUnseen {
      record.isDoneUnseen = false
      record.turnCompletedAt = nil
      changed = true
    }
    guard record.activity == .error || record.activity == .compacting else { return changed }
    record.activity = .idle
    record.erroredAt = nil
    return true
  }

  /// Resets the states parked on the user (`error`, `awaitingInput`) to `idle`
  /// on the surfaces they focused, and marks those surfaces seen (clearing
  /// `isDoneUnseen`). Returns the surfaces whose record flipped.
  ///
  /// Also latches the focused set: the app only tells us about focus *changes*,
  /// so a turn finishing on the surface the user is already staring at must be
  /// born seen rather than waiting for a focus event that never comes.
  private static func clearAttention(on surfaces: Set<UUID>, into state: inout State) -> Set<UUID> {
    state.focusedSurfaceIDs = surfaces
    var changed: Set<UUID> = []
    for (key, record) in state.records where surfaces.contains(key.surfaceID) {
      var updated = record
      if record.activity.isAttention {
        updated.activity = .idle
        updated.erroredAt = nil
      }
      updated.isDoneUnseen = false
      updated.turnCompletedAt = nil
      guard updated != record else { continue }
      state.records[key] = updated
      changed.insert(key.surfaceID)
    }
    return changed
  }

  /// Auto-seed only on the OSC path (pid == nil), and only when the activity
  /// would actually carry a badge: SSH attach can land on `busy` /
  /// `awaiting_input` with no prior `session_start`, but an `idle` arriving
  /// after the `session_end` + `idle` composite shutdown emit must NOT
  /// re-create the record. A pid-less idle re-seed would be skipped by the
  /// liveness sweep and pinned until surface close. Hermes is the exception:
  /// its per-turn `on_session_end` emits idle only (no `session_end`), so over
  /// SSH its badge clears on surface close rather than at process exit.
  private static func applyActivity(
    _ activity: Activity, event: AgentHookEvent, key: PresenceKey, into state: inout State
  ) -> Bool {
    if var record = state.records[key] {
      guard record.activity != activity else { return false }
      // A dead turn stays dead: only a new turn (`busy`) may overwrite `error`.
      // Claude's 60s-idle `Notification` fires `awaitingInput` on exactly the
      // session that just died, and would otherwise downgrade it to "waiting".
      guard record.activity != .error || activity == .busy else { return false }
      // A working turn ending is the only producer of "done", and only when the
      // user isn't looking at that surface; a new turn clears it.
      if record.activity.isWorking, activity == .idle {
        record.isDoneUnseen = !state.focusedSurfaceIDs.contains(key.surfaceID)
        record.turnCompletedAt = record.isDoneUnseen ? event.timestamp : nil
      } else if activity == .busy {
        record.isDoneUnseen = false
        record.turnCompletedAt = nil
      }
      record.erroredAt = activity == .error ? event.timestamp : nil
      record.activity = activity
      state.records[key] = record
      return true
    }
    guard event.pid == nil, activity != .idle else { return false }
    state.records[key] = PresenceRecord(
      activity: activity, erroredAt: activity == .error ? event.timestamp : nil, pids: [])
    rebuildPresence(forSurface: event.surfaceID, in: &state)
    return true
  }

  private static func drop(surfaces: Set<UUID>, from state: inout State) {
    state.focusedSurfaceIDs.subtract(surfaces)
    for id in surfaces { state.bySurface.removeValue(forKey: id) }
    state.records = state.records.filter { !surfaces.contains($0.key.surfaceID) }
    // A resume offer is scoped to the surface that hosted the session; closing it
    // takes the offer with it, since there is nowhere left to type the command.
    state.resumeCandidates = state.resumeCandidates.filter { !surfaces.contains($0.key.surfaceID) }
    pruneEphemeral(in: &state)
  }

  // MARK: - Names.

  /// `^[a-z][a-z0-9_-]{0,31}$`, spelled out so the hot path skips NSRegularExpression.
  nonisolated static func validate(name: String) -> Bool {
    guard (1...32).contains(name.count) else { return false }
    guard let first = name.first, first.isASCII, first.isLetter, first.isLowercase else { return false }
    return name.dropFirst().allSatisfy { character in
      guard character.isASCII else { return false }
      return (character.isLetter && character.isLowercase) || character.isNumber
        || character == "_" || character == "-"
    }
  }

  /// Applies a validated rename. Returns whether anything changed, so the
  /// caller only emits `surfacesChanged` on a real edit.
  static func rename(key: PresenceKey, to name: String?, into state: inout State) -> Bool {
    // Naming a dead agent would leak a name no `agent list` row can clear.
    guard state.records[key] != nil else { return false }
    guard let name else { return state.nameByKey.removeValue(forKey: key) != nil }
    guard validate(name: name), !state.isNameTaken(name, excluding: key) else { return false }
    guard state.nameByKey[key] != name else { return false }
    state.nameByKey[key] = name
    return true
  }

  /// Drops names and metadata whose record is gone. Both address a *running*
  /// agent, so every record-removal path funnels through here.
  private static func pruneEphemeral(in state: inout State) {
    if !state.nameByKey.isEmpty {
      let live = state.nameByKey.filter { state.records[$0.key] != nil }
      if live.count != state.nameByKey.count { state.nameByKey = live }
    }
    guard !state.metadataByKey.isEmpty else { return }
    let live = state.metadataByKey.filter { state.records[$0.key] != nil }
    guard live.count != state.metadataByKey.count else { return }
    state.metadataByKey = live
  }

  // MARK: - Metadata tokens.

  /// Token limits. Tokens are display-only, so the caps exist to keep one
  /// chatty agent from bloating state or the sidebar row.
  nonisolated enum MetadataLimits {
    static let maxTokens = 8
    static let maxKeyLength = 32
    static let maxValueLength = 120
  }

  /// Validates a token batch. Returns a human-readable reason on rejection, so
  /// the deeplink path can ack `ok: false` with it.
  nonisolated static func validate(tokens: [String: String]) -> String? {
    guard tokens.count <= MetadataLimits.maxTokens else {
      return "Too many metadata tokens (\(tokens.count) > \(MetadataLimits.maxTokens))."
    }
    for (key, value) in tokens.sorted(by: { $0.key < $1.key }) {
      guard !key.isEmpty, key.count <= MetadataLimits.maxKeyLength else {
        return "Invalid metadata key '\(key)': 1–\(MetadataLimits.maxKeyLength) characters."
      }
      let isLowercaseToken = key.allSatisfy { character in
        guard character.isASCII else { return false }
        return (character.isLetter && character.isLowercase) || character.isNumber
          || character == "_" || character == "-"
      }
      guard isLowercaseToken else {
        return "Invalid metadata key '\(key)': lowercase letters, digits, '_' and '-' only."
      }
      guard value.count <= MetadataLimits.maxValueLength else {
        return "Metadata value for '\(key)' is too long (\(value.count) > \(MetadataLimits.maxValueLength))."
      }
    }
    return nil
  }

  /// Applies a validated token batch. Returns whether anything changed, so the
  /// caller only emits `surfacesChanged` on a real edit.
  static func reportMetadata(
    key: PresenceKey,
    tokens: [String: String],
    clear: Bool,
    into state: inout State
  ) -> Bool {
    // Metadata on a dead agent would leak: no `agent list` row can clear it.
    guard state.records[key] != nil else { return false }
    guard validate(tokens: tokens) == nil else { return false }
    var merged = clear ? [:] : (state.metadataByKey[key] ?? [:])
    for (token, value) in tokens { merged[token] = value }
    // Cap after the merge too: repeated batches must not grow past the limit.
    guard merged.count <= MetadataLimits.maxTokens else { return false }
    guard merged != state.metadataByKey[key] ?? [:] else { return false }
    if merged.isEmpty {
      state.metadataByKey.removeValue(forKey: key)
    } else {
      state.metadataByKey[key] = merged
    }
    return true
  }

  /// Pure liveness check; returns only keys whose alive subset diverges from the snapshot.
  nonisolated static func liveness(forSnapshot snapshot: [PresenceKey: Set<pid_t>]) -> [PresenceKey: Set<pid_t>] {
    var result: [PresenceKey: Set<pid_t>] = [:]
    for (key, pids) in snapshot {
      // `kill(0, 0)` / `kill(-N, 0)` succeed against the caller's process group; reject non-positive pids.
      let alive = pids.filter { $0 > 0 && kill($0, 0) == 0 }
      if alive != pids {
        result[key] = alive
      }
    }
    return result
  }

  /// Apply the liveness delta back to state. Pids added between snapshot capture and apply
  /// (e.g. a `.sessionStart` that landed during the off-main hop) are preserved.
  private static func applyLiveness(
    delta: [PresenceKey: Set<pid_t>],
    snapshot: [PresenceKey: Set<pid_t>],
    into state: inout State
  ) -> Set<UUID> {
    var dirtySurfaces: Set<UUID> = []
    for (key, alive) in delta {
      guard var record = state.records[key] else { continue }
      let snapshotPids = snapshot[key] ?? []
      // Subtract only the pids the sweep proved dead; current additions/removals stay authoritative.
      let deadPids = snapshotPids.subtracting(alive)
      let next = record.pids.subtracting(deadPids)
      if next.isEmpty {
        state.records.removeValue(forKey: key)
        dirtySurfaces.insert(key.surfaceID)
      } else if record.pids != next {
        record.pids = next
        state.records[key] = record
        dirtySurfaces.insert(key.surfaceID)
      }
    }
    for surfaceID in dirtySurfaces { rebuildPresence(forSurface: surfaceID, in: &state) }
    return dirtySurfaces
  }

  struct StagedRestore: Sendable {
    let pids: Set<pid_t>
    let activity: Activity
    var isDoneUnseen = false
    var sessionRef: String?
  }

  /// Build the staged-restore dict from persisted layouts. No `kill(2)` here;
  /// liveness check is the caller's responsibility in `.run`.
  nonisolated static func stageRestore(
    fromLayouts layouts: some Sequence<TerminalLayoutSnapshot>
  ) -> [PresenceKey: StagedRestore] {
    var staged: [PresenceKey: StagedRestore] = [:]
    for layout in layouts {
      for (surfaceID, records) in layout.allAgentRecords() {
        for record in records {
          guard let agent = SkillAgent(rawValue: record.agent) else { continue }
          // A record already proven dead in an earlier restore carries the flag
          // instead of pids, so it stays a candidate across any number of
          // relaunches until the user resumes it or closes the surface. Staged
          // with no pids so the liveness pass classifies it as dead again.
          if record.resumeCandidate == true, record.pids.isEmpty {
            staged[PresenceKey(agent: agent, surfaceID: surfaceID)] =
              StagedRestore(
                pids: [], activity: Activity(rawValue: record.activity) ?? .idle,
                isDoneUnseen: record.doneUnseen ?? false,
                sessionRef: AgentPresenceOSC.sanitizedSessionRef(record.sessionRef))
            continue
          }
          // Pid-less OSC records aren't restore-durable: they persist with no
          // pid, so they drop here and re-seed on the next OSC event post-relaunch.
          // They can't be resume candidates either: with no pid there is nothing
          // to prove dead, and the agent may still be running on the far side of
          // an SSH connection.
          let pids = Set(record.pids.filter { $0 > 0 })
          guard !pids.isEmpty else { continue }
          let activity = Activity(rawValue: record.activity) ?? .idle
          staged[PresenceKey(agent: agent, surfaceID: surfaceID)] =
            StagedRestore(
              pids: pids, activity: activity, isDoneUnseen: record.doneUnseen ?? false,
              sessionRef: AgentPresenceOSC.sanitizedSessionRef(record.sessionRef))
        }
      }
    }
    return staged
  }

  /// Rejects non-positive pids; `kill(0, ...)` targets process groups, not
  /// individual processes.
  nonisolated static func isAlive(_ pid: pid_t) -> Bool {
    pid > 0 && kill(pid, 0) == 0
  }

  /// A hook event that raced ahead of the restore takes precedence.
  private static func applyRestore(
    records: [PresenceKey: RestoredRecord],
    into state: inout State
  ) -> Set<UUID> {
    var dirtySurfaces: Set<UUID> = []
    for (key, record) in records {
      if state.records[key] != nil { continue }
      // Restored records always have alive pids (pid-less OSC records are dropped in stageRestore).
      state.records[key] = PresenceRecord(
        activity: record.activity, isDoneUnseen: record.isDoneUnseen, pids: record.alivePids,
        sessionRef: record.sessionRef)
      // A live record wins: resuming an agent that survived would fork its session.
      state.resumeCandidates.removeValue(forKey: key)
      dirtySurfaces.insert(key.surfaceID)
    }
    for surfaceID in dirtySurfaces { rebuildPresence(forSurface: surfaceID, in: &state) }
    return dirtySurfaces
  }

  private static func rebuildPresence(forSurface surfaceID: UUID, in state: inout State) {
    let agents = Set(
      state.records.compactMap { entry in
        entry.key.surfaceID == surfaceID ? entry.key.agent : nil
      },
    )
    if agents.isEmpty {
      state.bySurface.removeValue(forKey: surfaceID)
    } else {
      state.bySurface[surfaceID] = agents
    }
  }
}

extension AgentPresenceFeature.State {
  /// Sorted output so the persisted JSON stays diff-stable.
  func agentsBySurface() -> [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]] {
    guard !records.isEmpty || !resumeCandidates.isEmpty else { return [:] }
    var result: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]] = [:]
    for (key, record) in records {
      let entry = TerminalLayoutSnapshot.SurfaceAgentRecord(
        agent: key.agent.rawValue,
        pids: record.pids.sorted(),
        activity: record.activity.rawValue,
        doneUnseen: record.isDoneUnseen ? true : nil,
        sessionRef: record.sessionRef
      )
      result[key.surfaceID, default: []].append(entry)
    }
    // Unresumed candidates persist too, flagged so the next restore reads them as
    // already-dead rather than as a pid-less SSH agent.
    for (key, candidate) in resumeCandidates where records[key] == nil {
      result[key.surfaceID, default: []].append(
        TerminalLayoutSnapshot.SurfaceAgentRecord(
          agent: key.agent.rawValue,
          pids: [],
          activity: candidate.lastActivity.rawValue,
          doneUnseen: nil,
          sessionRef: candidate.sessionRef,
          resumeCandidate: true
        )
      )
    }
    for (id, entries) in result {
      result[id] = entries.sorted { $0.agent < $1.agent }
    }
    return result
  }
}

extension AgentPresenceFeature {
  /// The one token the dashboard renders. Every other token is CLI-visible only.
  nonisolated static let summaryToken = "summary"
}

extension AgentPresenceFeature.State {
  /// Whether `name` already addresses another live agent. Case-sensitive: names
  /// are validated lowercase, so a case-insensitive check would be dead code.
  func isNameTaken(_ name: String, excluding key: AgentPresenceFeature.PresenceKey? = nil) -> Bool {
    nameByKey.contains { $0.key != key && $0.value == name }
  }

  /// The resume candidate for one (worktree, agent) pair, in surface order, or
  /// nil when no surface of that worktree has a resumable dead session.
  func resumeCandidate(
    agent: SkillAgent,
    across surfaceIDs: some Sequence<UUID>
  ) -> (key: AgentPresenceFeature.PresenceKey, candidate: AgentPresenceFeature.ResumeCandidate)? {
    surfaceIDs.lazy
      .map { AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: $0) }
      .compactMap { key in resumeCandidates[key].map { (key: key, candidate: $0) } }
      .first
  }

  /// The live agent addressed by `name`, if any.
  func presenceKey(forName name: String) -> AgentPresenceFeature.PresenceKey? {
    nameByKey.first { $0.value == name }?.key
  }

  /// The canonical record for one (worktree, agent) pair. The Agents dashboard
  /// collapses every surface of a worktree into one row, so naming that row
  /// targets the first live record in surface order.
  func presenceKey(
    agent: SkillAgent,
    across surfaceIDs: some Sequence<UUID>
  ) -> AgentPresenceFeature.PresenceKey? {
    surfaceIDs.lazy
      .map { AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: $0) }
      .first { records[$0] != nil }
  }

  /// Agents on a single surface. Empty when badges are disabled by the user.
  func agents(forSurface id: UUID, badgesEnabled: Bool) -> Set<SkillAgent> {
    guard badgesEnabled else { return [] }
    return bySurface[id] ?? []
  }

  /// One `AgentInstance` per (surface, agent) pair across the given surface list.
  /// Duplicates preserved (a tab hosting two surfaces both running Claude shows
  /// two Claude badges). Sorted error-first, then awaiting-input, then by agent
  /// rawValue so iteration is stable across renders.
  func agents(
    across surfaceIDs: some Sequence<UUID>,
    badgesEnabled: Bool,
  ) -> [AgentPresenceFeature.AgentInstance] {
    guard badgesEnabled else { return [] }
    return
      surfaceIDs
      .flatMap { surfaceID -> [AgentPresenceFeature.AgentInstance] in
        (bySurface[surfaceID] ?? []).map { agent in
          let record = records[AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: surfaceID)]
          let key = AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: surfaceID)
          return AgentPresenceFeature.AgentInstance(
            agent: agent,
            activity: record?.activity ?? .idle,
            isDoneUnseen: record?.isDoneUnseen ?? false,
            name: nameByKey[key],
            metadata: metadataByKey[key] ?? [:]
          )
        }
      }
      .sorted { lhs, rhs in
        let lhsError = lhs.activity == .error
        let rhsError = rhs.activity == .error
        if lhsError != rhsError { return lhsError }
        if lhs.awaitingInput != rhs.awaitingInput { return lhs.awaitingInput }
        return lhs.agent.rawValue < rhs.agent.rawValue
      }
  }

  /// The badge lineup and the aggregates a sidebar row derives from it, in a
  /// single pass over `records`. The error is carried by the badge itself, so it
  /// only surfaces when badges are on; the shimmer is a generic "this worktree is
  /// doing work" signal and stays independent of the toggle.
  func rowSnapshot(
    across surfaceIDs: some Sequence<UUID>,
    badgesEnabled: Bool,
  ) -> AgentPresenceFeature.RowSnapshot {
    let surfaceSet = Set(surfaceIDs)
    var isWorking = false
    var hasError = false
    var errorAt: Date?
    var completedTurnAt: Date?
    for (key, record) in records where surfaceSet.contains(key.surfaceID) {
      if record.activity.isWorking { isWorking = true }
      if record.activity == .error, badgesEnabled { hasError = true }
      if record.activity == .error {
        errorAt = Self.newest(errorAt, record.erroredAt)
      }
      if record.isDoneUnseen {
        completedTurnAt = Self.newest(completedTurnAt, record.turnCompletedAt)
      }
    }
    return AgentPresenceFeature.RowSnapshot(
      agents: agents(across: surfaceSet, badgesEnabled: badgesEnabled),
      isWorking: isWorking,
      hasError: hasError,
      errorAt: errorAt,
      completedTurnAt: completedTurnAt
    )
  }

  /// Newest of two hook-reported instants. Routed through `TaskTimestamps` so a
  /// non-finite `ts` from the wire is dropped rather than winning every max.
  private static func newest(_ lhs: Date?, _ rhs: Date?) -> Date? {
    TaskTimestamps.latestValid([lhs, rhs])
  }

  /// Any agent on the listed surfaces is working (`busy`, or compacting inside a
  /// running turn). Awaiting-input is excluded: the agent is parked on the user,
  /// so it must not shimmer. Not gated by the badge toggle.
  func hasActivity(in surfaceIDs: some Sequence<UUID>) -> Bool {
    let surfaceSet = Set(surfaceIDs)
    return records.contains { entry in
      entry.value.activity.isWorking && surfaceSet.contains(entry.key.surfaceID)
    }
  }

  /// Any agent on the listed surfaces ended its turn in an API error.
  func hasError(in surfaceIDs: some Sequence<UUID>) -> Bool {
    let surfaceSet = Set(surfaceIDs)
    return records.contains { entry in
      entry.value.activity == .error && surfaceSet.contains(entry.key.surfaceID)
    }
  }

  /// Any agent on the listed surfaces is compacting its context.
  func isCompacting(in surfaceIDs: some Sequence<UUID>) -> Bool {
    let surfaceSet = Set(surfaceIDs)
    return records.contains { entry in
      entry.value.activity == .compacting && surfaceSet.contains(entry.key.surfaceID)
    }
  }
}
