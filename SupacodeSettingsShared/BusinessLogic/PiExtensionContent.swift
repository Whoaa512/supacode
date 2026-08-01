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
     *   extension load      -> session_start  (agent presence badge)
     *   Pi agent_start      -> busy + sid=<session id>  (resume ref)
     *   Pi agent_end        -> idle + notification with last_assistant_message
     *   Pi session_shutdown -> session_end + idle (defensive activity reset)
     *
     * The resume ref rides `busy` rather than `session_start` because the session
     * id is only reachable through the event context, which extension load has no
     * access to. Supacode keeps the last ref it saw, so one per turn is plenty.
     */

    import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
    import { openSync, writeSync, closeSync } from "node:fs";

    interface NotifyContent {
      title?: string;
      body?: string;
    }

    const AGENT = "pi";

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

    function emitPresence(event: string, sessionRef?: string): void {
      const action = event === "session_end" ? "end" : "start";
      const meta = `event=${event}${localPidSuffix()}${sessionRefSuffix(sessionRef)}`;
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

      // Extension load = agent process running. Pi has no equivalent of
      // Claude's SessionStart hook, so we fire it ourselves.
      emitPresence("session_start");

      pi.on("agent_start", (_event, ctx) => {
        emitPresence("busy", sessionRef(ctx));
      });

      pi.on("agent_end", (_event, ctx) => {
        // Atomic state-set: `idle` overwrites whatever was running on the
        // Supacode side (turn-level Stop equivalent).
        emitPresence("idle");
        emitNotification({ body: lastAssistantText(ctx) });
      });

      pi.on("session_shutdown", (_event, _ctx) => {
        emitPresence("session_end");
        emitPresence("idle");
      });
    }
    """
}
