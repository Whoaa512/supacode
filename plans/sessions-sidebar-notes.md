# Sessions sidebar implementation notes

## Slice 1, step 1 — index/domain foundation
- Implemented SessionSource, SessionSummary, SessionKey; pi-only actor and dependency seam.
- Streams byte chunks; selectively decodes header, session_info and first user message.
- Counts message lines/extracts timestamps without decoding transcript payloads.
- Persistent path/mtime/size summary cache is accessible before refresh; changed files reparse.
- One directory level, regular JSONL only; symlinks/temp cwd aliases excluded.
- Sidecar contains settle markers and ordered unique branches; Shared fileStorage sessions key.
- Pure creation-order Active/Settled and live/dormant classification; no age/count auto rules.
- No UI/reducer wiring; no app launch/install, process signaling or protected-state writes.
- make generate-project: exit 0.
- First targeted make test: exit 2 (missing test module import); corrected.
- Targeted make test SWIFT_VERSION=5, PiSessionSourceTests + SessionClassificationTests: exit 0.
- xcresulttool summary: exit 0; totalTestCount 13, failedTests 0; 20 parameterized runs.
- make lint: exit 2; existing complexity violations DeeplinkClient:26, CommandPaletteFeature:1245 only.
- make build-app: exit 0; pgrep checked before every build/test, no concurrent xcodebuild.
- git diff --check: exit 0. Implementation commit: 26115243.
- Tooling friction logged through papercut; PAPERCUTS.md and .worktrees remain untracked.
- Independent review unavailable: code-critic failed to start due to pi theme resolver error.
- Full tests/live-history/manual QA deliberately not run. Next scope: Slice 1 step 2.
