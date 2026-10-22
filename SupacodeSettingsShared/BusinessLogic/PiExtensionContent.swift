/// Bundled TypeScript extension that Supacode installs into
/// `~/.pi/agent/extensions/supacode/index.ts` to report agent
/// lifecycle hooks back to the Supacode macOS app.
nonisolated enum PiExtensionContent {
  /// Directory name under `~/.pi/agent/extensions/`.
  static let extensionDirectoryName = "supacode"

  /// Marker comment used to identify Supacode-managed extensions.
  static let ownershipMarker = "/* supacode-managed-extension */"

  static let indexTs = """
    \(ownershipMarker)
    /**
     * Supacode + Pi integration extension.
     *
     * Reports agent lifecycle and notifications to Supacode by emitting OSC 3008
     * escape sequences to the controlling terminal. The sequences are inert in any
     * terminal that does not handle OSC 3008, and reach Supacode over SSH too (no
     * local socket needed), matching the Claude / Codex / Kiro hook integrations.
     *
     * Required env var (injected automatically by Supacode on every surface):
     *   SUPACODE_SURFACE_ID  present only on a Supacode surface; absence is the
     *                        no-op gate. Signals are unauthenticated.
     * Optional:
     *   SUPACODE_SOCKET_PATH  present only on the local host; gates the local pid
     *                         so the app's liveness sweep can reap a crashed agent.
     *
     * Hook event mapping:
     *   Pi session_start   -> session_start + sid=<session id>  (early link)
     *   Pi agent_start      -> busy + sid=<session id>  (resume ref)
     *   Pi agent_end        -> idle + sid=<session id>  (sticky ref)
     *   agent_start / agent_end of a sub-agent session in this process
     *                       -> busy;children=N on the owner (debounced)
     *   Pi tool_execution_start of a prompt tool -> awaiting_input;prompt=question
     *   Pi tool_execution_end of a prompt tool   -> busy (turn continues)
     *   Pi session_shutdown -> session_end + sid + reason
     */

    import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
    import { openSync, writeSync, closeSync } from "node:fs";

    interface NotifyContent {
      title?: string;
      body?: string;
    }

    const AGENT = "pi";

    /**
     * Tools that block the turn on the user answering in the TUI. Pi has no
     * permission hook (extensions confirm inside tool_call, invisible here),
     * so a prompt tool starting is the only observable "needs you" signal.
     */
    const PROMPT_TOOLS = new Set(["question", "questionnaire", "ask_user", "AskUserQuestion"]);

    let lastWarnedAt = 0;
    const WARN_INTERVAL_MS = 60_000;

    function isSupacodeSurface(): boolean {
      const id = process.env["SUPACODE_SURFACE_ID"];
      return !!id && id.length > 0;
    }

    /**
     * The agent's local process id as an OSC pid suffix, but only on the local
     * host (SUPACODE_SOCKET_PATH is set). A remote pid over SSH would be
     * meaningless to the app's liveness sweep, so it is omitted there.
     */
    function localPidSuffix(): string {
      return process.env["SUPACODE_SOCKET_PATH"] ? `;pid=${process.pid}` : "";
    }

    /**
     * Writes an OSC sequence to the controlling terminal. The extension runs
     * inside the Pi TUI process, which owns the terminal, so /dev/tty resolves.
     * Best-effort, but a systematically-failing tty is logged at most once per
     * `WARN_INTERVAL_MS` to stderr so a broken write path is distinguishable
     * from "not a Supacode surface" without spamming the log on every emit.
     */
    function writeToTerminal(sequence: string): void {
      try {
        const fd = openSync("/dev/tty", "w");
        try {
          // Loop until the full byte length lands: a short write would leave a
          // half OSC 3008 with no ST (ESC\\) and corrupt the terminal parser.
          const bytes = Buffer.from(sequence, "utf8");
          let offset = 0;
          while (offset < bytes.length) {
            try {
              const written = writeSync(fd, bytes, offset, bytes.length - offset);
              if (written <= 0) {
                throw new Error(`short write (${offset}/${bytes.length} bytes)`);
              }
              offset += written;
            } catch (writeErr) {
              // Retry interrupted / non-blocking transient errors; abort on anything else.
              const code = (writeErr as NodeJS.ErrnoException).code;
              if (code === "EINTR" || code === "EAGAIN") continue;
              throw writeErr;
            }
          }
        } finally {
          closeSync(fd);
        }
      } catch (err) {
        const now = Date.now();
        if (now - lastWarnedAt > WARN_INTERVAL_MS) {
          lastWarnedAt = now;
          const e = err as NodeJS.ErrnoException;
          const code = e.code ?? "";
          const errno = e.errno ?? "";
          const message = e.message ?? String(err);
          process.stderr.write(
            `supacode: OSC emit failed: code=${code} errno=${errno} message=${message}\\n`,
          );
        }
      }
    }

    /**
     * `;sid=<id>` when the session id is present and safe to carry. Mirrors
     * AgentPresenceOSC.sanitizedSessionRef: the app splices this value into a
     * `pi --session <id>` command line, so anything outside [A-Za-z0-9._-] or
     * over the byte budget is dropped rather than sanitized into something else.
     */
    function sessionRefSuffix(sessionRef: string | undefined): string {
      if (!sessionRef) return "";
      if (Buffer.byteLength(sessionRef, "utf8") > \(AgentPresenceOSC.sessionRefByteBudget)) return "";
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(sessionRef)) return "";
      return `;\(AgentPresenceOSC.sessionField)=${sessionRef}`;
    }

    function shutdownReasonSuffix(reason: unknown): string {
      if (typeof reason !== "string" || !["quit", "reload", "new", "resume", "fork"].includes(reason)) return "";
      return `;reason=${reason}`;
    }

    function emitPresence(
      event: string,
      sessionRef?: string,
      reason?: unknown,
      prompt?: string,
      children = 0,
    ): void {
      const action = event === "session_end" ? "end" : "start";
      const promptSuffix = prompt ? `;prompt=${prompt}` : "";
      const childrenSuffix = event === "busy" && children > 0 ? `;\(AgentPresenceOSC.childrenField)=${children}` : "";
      const meta =
        `event=${event}${promptSuffix}${childrenSuffix}${localPidSuffix()}` +
        `${sessionRefSuffix(sessionRef)}${shutdownReasonSuffix(reason)}`;
      writeToTerminal(`\\x1b]3008;${action}=${AGENT};${meta}\\x1b\\\\`);
    }

    /**
     * The session id `pi --session <id>` resumes. Guarded because an ephemeral
     * (unpersisted) session has nothing to resume, and older Pi builds may not
     * expose the getter at all.
     */
    function sessionRef(ctx: { sessionManager?: { getSessionId?(): string | undefined } }): string | undefined {
      try {
        return ctx.sessionManager?.getSessionId?.() || undefined;
      } catch {
        return undefined;
      }
    }

    /**
     * One session per process owns the surface. The `workflow` tool runs
     * sub-agent sessions inside the Pi process (createAgentSession loads this
     * extension again for each), and they would otherwise report their own
     * session ids and turns against the parent's surface, which the app reads
     * as the parent being replaced. Pi loads each extension as a fresh module,
     * so the owner lives on globalThis. The owning session releases on
     * shutdown so the session that follows a /new, /resume, /fork or /reload
     * claims the surface with its session_start. Only session_start may
     * claim: a sub-agent turn that lands between the owner's shutdown and
     * the next session_start (reload awaits resource loading first) would
     * otherwise take the surface and silence the real session for good.
     */
    const OWNER_KEY = Symbol.for("supacode.presenceOwner");
    const owners = globalThis as unknown as Record<symbol, unknown>;

    function claimSurface(ctx: { sessionManager?: unknown }): boolean {
      const owner = owners[OWNER_KEY];
      if (owner !== undefined && owner !== ctx.sessionManager) return false;
      owners[OWNER_KEY] = ctx.sessionManager;
      return true;
    }

    function ownsSurface(ctx: { sessionManager?: unknown }): boolean {
      return owners[OWNER_KEY] !== undefined && owners[OWNER_KEY] === ctx.sessionManager;
    }

    function releaseSurface(ctx: { sessionManager?: unknown }): boolean {
      if (!ownsSurface(ctx)) return false;
      owners[OWNER_KEY] = undefined;
      return true;
    }

    /**
     * The owner's own turn state plus the sub-agent sessions running in this
     * process. A `workflow` run outlives the owner's turn (the tool returns a
     * run id and the turn ends), so the row must keep reading as working, with
     * the count, until the last child ends. Children report nothing of their
     * own; the owner re-emits `busy;children=N` on each change, debounced so a
     * parallel fan-out of N starts lands as one signal. The watch lives on
     * globalThis with the owner, since every session loads its own module.
     */
    const WATCH_KEY = Symbol.for("supacode.childWatch");
    const CHILD_EMIT_DEBOUNCE_MS = 250;

    interface ChildWatch {
      ownerTurnLive: boolean;
      children: Set<unknown>;
      timer: ReturnType<typeof setTimeout> | undefined;
      lastEmittedChildren: number;
      lastEmittedEvent: string | undefined;
    }

    function childWatch(): ChildWatch {
      const existing = owners[WATCH_KEY] as ChildWatch | undefined;
      if (existing) return existing;
      const fresh: ChildWatch = {
        ownerTurnLive: false,
        children: new Set(),
        timer: undefined,
        lastEmittedChildren: 0,
        lastEmittedEvent: undefined,
      };
      owners[WATCH_KEY] = fresh;
      return fresh;
    }

    function cancelChildEmit(watch: ChildWatch): void {
      if (watch.timer === undefined) return;
      clearTimeout(watch.timer);
      watch.timer = undefined;
    }

    function resetChildWatch(): void {
      const watch = childWatch();
      cancelChildEmit(watch);
      watch.ownerTurnLive = false;
      watch.children.clear();
      watch.lastEmittedChildren = 0;
      watch.lastEmittedEvent = undefined;
    }

    /** Emits the owner's presence now, recording what went out so a debounced re-emit can skip a no-op. */
    function emitOwnerPresence(event: string, sessionRef: string | undefined, prompt?: string): void {
      const watch = childWatch();
      cancelChildEmit(watch);
      const children = watch.children.size;
      const effective = event === "idle" && children > 0 ? "busy" : event;
      watch.lastEmittedEvent = effective;
      watch.lastEmittedChildren = effective === "busy" ? children : 0;
      emitPresence(effective, sessionRef, undefined, prompt, children);
    }

    /** Owner sid for a debounced re-emit, read off the owning session manager. */
    function ownerSessionRef(): string | undefined {
      return sessionRef({ sessionManager: owners[OWNER_KEY] as { getSessionId?(): string | undefined } | undefined });
    }

    function scheduleChildEmit(): void {
      const watch = childWatch();
      if (watch.timer !== undefined) return;
      const timer = setTimeout(() => {
        watch.timer = undefined;
        if (owners[OWNER_KEY] === undefined) return;
        const children = watch.children.size;
        // An owner mid-turn is already busy; only the count can change. A
        // question blocks on the user whatever the children do.
        const asking = watch.lastEmittedEvent === "awaiting_input";
        const base = asking ? "awaiting_input" : watch.ownerTurnLive ? "busy" : "idle";
        const effective = base === "idle" && children > 0 ? "busy" : base;
        const emittedChildren = effective === "busy" ? children : 0;
        if (effective === watch.lastEmittedEvent && emittedChildren === watch.lastEmittedChildren) return;
        watch.lastEmittedEvent = effective;
        watch.lastEmittedChildren = emittedChildren;
        emitPresence(effective, ownerSessionRef(), undefined, undefined, children);
      }, CHILD_EMIT_DEBOUNCE_MS);
      timer.unref?.();
      watch.timer = timer;
    }

    function childStarted(ctx: { sessionManager?: unknown }): void {
      if (owners[OWNER_KEY] === undefined || ctx.sessionManager === undefined) return;
      childWatch().children.add(ctx.sessionManager);
      scheduleChildEmit();
    }

    function childEnded(ctx: { sessionManager?: unknown }): void {
      const watch = childWatch();
      if (!watch.children.delete(ctx.sessionManager)) return;
      scheduleChildEmit();
    }

    // JSON-escape (minus the surrounding quotes) so the wire matches the shell
    // awk path, byte-cap to the same budget, then base64. App-side
    // decodeNotifyValue reverses both and tolerates a mid-escape cut.
    function notifyField(value: string, budget: number): string {
      const escaped = JSON.stringify(value).slice(1, -1);
      const buf = Buffer.from(escaped, "utf8");
      const capped = buf.length > budget ? buf.subarray(0, budget) : buf;
      return capped.toString("base64");
    }

    function emitNotification(content: NotifyContent): void {
      const meta =
        `kind=notify` +
        `;title=${notifyField(content.title ?? "", \(AgentPresenceOSC.notifyTitleByteBudget))}` +
        `;body=${notifyField(content.body ?? "", \(AgentPresenceOSC.notifyBodyByteBudget))}`;
      writeToTerminal(`\\x1b]3008;start=${AGENT};${meta}\\x1b\\\\`);
    }

    function lastAssistantText(ctx: { sessionManager: { getEntries(): any[] } }): string | undefined {
      const entries = ctx.sessionManager.getEntries();
      for (let i = entries.length - 1; i >= 0; i--) {
        const entry = entries[i];
        if (entry.type !== "message") continue;
        if (entry.message.role !== "assistant") continue;

        const content = entry.message.content;
        if (!Array.isArray(content)) continue;

        const text = content
          .filter((c: { type: string; text?: string }) => c.type === "text" && typeof c.text === "string")
          .map((c: { text: string }) => c.text)
          .join("")
          .trim();

        if (text.length > 0) return text;
      }
      return undefined;
    }

    export default function (pi: ExtensionAPI) {
      // Not running under Supacode, or not a Supacode surface: stay inert.
      if (!isSupacodeSurface()) return;

      // session_start fires when pi has a fully initialised session context,
      // so the sid is already reachable via sessionRef(ctx). Emit it here so
      // restored and freshly resumed surfaces link without waiting for the
      // first turn. Replaces the unconditional load-time emitPresence above.
      pi.on("session_start", (_event, ctx) => {
        if (!claimSurface(ctx)) return;
        resetChildWatch();
        emitPresence("session_start", sessionRef(ctx));
      });

      pi.on("agent_start", (_event, ctx) => {
        if (!ownsSurface(ctx)) return childStarted(ctx);
        childWatch().ownerTurnLive = true;
        emitOwnerPresence("busy", sessionRef(ctx));
      });

      pi.on("tool_execution_start", (event, ctx) => {
        if (!ownsSurface(ctx) || !PROMPT_TOOLS.has(event.toolName)) return;
        emitOwnerPresence("awaiting_input", sessionRef(ctx), "question");
      });

      pi.on("tool_execution_end", (event, ctx) => {
        if (!ownsSurface(ctx) || !PROMPT_TOOLS.has(event.toolName)) return;
        emitOwnerPresence("busy", sessionRef(ctx));
      });

      pi.on("agent_end", (_event, ctx) => {
        if (!ownsSurface(ctx)) return childEnded(ctx);
        childWatch().ownerTurnLive = false;
        // Emit the sid on idle too so Supacode can associate the last-known
        // session id with the surface even when no busy turn occurred yet.
        // Running children keep this a busy, with their count.
        emitOwnerPresence("idle", sessionRef(ctx));
        emitNotification({ body: lastAssistantText(ctx) });
      });

      pi.on("session_shutdown", (event, ctx) => {
        if (!releaseSurface(ctx)) return childEnded(ctx);
        resetChildWatch();
        emitPresence("session_end", sessionRef(ctx), event.reason);
      });
    }
    """
}
