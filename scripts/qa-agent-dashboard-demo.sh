#!/usr/bin/env bash
# QA demo for the herdr-inspired Agents sidebar (plans/herdr-inspired-agent-dashboard.md).
#
# Launches an isolated debug Supacode (own state dir + zmx dir, never touches
# ~/.supacode or your running app), opens two throwaway repos, injects
# synthetic OSC 3008 agent-presence signals into the spawned terminals, then
# exercises the agent CLI and captures screenshots.
#
# Run while logged in at the machine with the screen unlocked. Screenshots
# need Screen Recording permission for your terminal host.
#
# Usage: scripts/qa-agent-dashboard-demo.sh [path-to-debug-supacode.app]
set -euo pipefail

APP=${1:-"$(cd "$(dirname "$0")/.." && pwd)/.build/DerivedData/Build/Products/Debug/supacode.app"}
CLI="$APP/Contents/Resources/bin/supacode"
ZMX="$APP/Contents/Resources/zmx/zmx"
STATE=/tmp/supacode-qa-state
ZDIR=/tmp/supacode-qa-zmx
HOMEQA=/tmp/supacode-qa-home
SHOTS=/tmp/supacode-qa-shots

[ -x "$CLI" ] || { echo "error: CLI not found at $CLI (build with make build-app)"; exit 1; }

echo "==> Preparing isolated state + demo repos"
rm -rf "$STATE" "$ZDIR" "$SHOTS"
mkdir -p "$STATE" "$ZDIR" "$SHOTS" "$HOMEQA/code"
for r in acme-api web-dash; do
  if [ ! -d "$HOMEQA/code/$r/.git" ]; then
    git -C "$HOMEQA/code" init -qb main "$r"
    git -C "$HOMEQA/code/$r" commit -q --allow-empty -m init
  fi
done

echo "==> Launching isolated debug Supacode"
open -n --env SUPACODE_STATE_DIR="$STATE" --env ZMX_DIR="$ZDIR" "$APP"
sleep 8

uid=$(id -u)
pid=$(pgrep -nx supacode)
export SUPACODE_SOCKET_PATH="/tmp/supacode-$uid/pid-$pid"
[ -S "$SUPACODE_SOCKET_PATH" ] || { echo "error: no socket at $SUPACODE_SOCKET_PATH"; exit 1; }
echo "    socket: $SUPACODE_SOCKET_PATH"

echo "==> Opening demo repos"
"$CLI" repo open "$HOMEQA/code/acme-api" || true
sleep 2
"$CLI" repo open "$HOMEQA/code/web-dash" || true
sleep 2

echo "==> Focusing worktrees to spawn terminals"
"$CLI" worktree focus --worktree "%2Ftmp%2Fsupacode-qa-home%2Fcode%2Fweb-dash%2F"
sleep 4
"$CLI" worktree focus --worktree "%2Ftmp%2Fsupacode-qa-home%2Fcode%2Facme-api%2F"
sleep 4

sessions=$(ZMX_DIR="$ZDIR" "$ZMX" list --short 2>/dev/null || true)
[ -n "$sessions" ] || { echo "error: no zmx sessions spawned; is the screen unlocked?"; exit 1; }
echo "    sessions: $sessions"

# Emit an OSC 3008 presence signal from inside a session's pty. zmx send types
# the printf into the shell; its output reaches Ghostty, which attributes the
# signal to the hosting surface.
emit() { # emit <session> <agent> <event>
  ZMX_DIR="$ZDIR" "$ZMX" send "$1" "printf '\\033]3008;start=$2;event=$3;pid='\$\$'\\033\\\\\\\\'
"
}

by_dir() { # by_dir <substring> -> session name
  ZMX_DIR="$ZDIR" "$ZMX" list 2>/dev/null | rg "$1" | rg -o 'name=\S+' | head -1 | cut -d= -f2
}

acme=$(by_dir acme-api)
dash=$(by_dir web-dash)
echo "==> Injecting synthetic agents (acme=$acme dash=$dash)"
emit "$acme" claude session_start; sleep 1
emit "$acme" claude busy; sleep 1
emit "$acme" pi session_start; sleep 1
emit "$acme" pi awaiting_input; sleep 1
emit "$dash" codex session_start; sleep 1
emit "$dash" codex busy; sleep 1
emit "$dash" codex idle; sleep 1   # finished while unfocused -> shows as done

echo "==> Naming an agent + reporting metadata"
"$CLI" agent rename "%2Ftmp%2Fsupacode-qa-home%2Fcode%2Facme-api%2F" reviewer --agent claude || true
"$CLI" agent report-metadata reviewer --token summary="refactoring auth" || true
sleep 1

echo "==> agent list"
"$CLI" agent list || true
echo "==> agent explain reviewer"
"$CLI" agent explain reviewer || true

echo "==> Screenshots (grant Screen Recording if these fail)"
win() {
  swift -e "import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String:Any]]; for w in l where (w[\"kCGWindowOwnerPID\"] as? Int) == $pid { if let b = w[\"kCGWindowBounds\"] as? [String:Int], (b[\"Width\"] ?? 0) > 500 { print(w[\"kCGWindowNumber\"] as? Int ?? 0); break } }" 2>/dev/null
}
wid=$(win)
snap() { screencapture -x -l "$wid" "$SHOTS/$1.png" && echo "    $SHOTS/$1.png"; }

snap 1-worktrees-tab || echo "    (screencapture failed: grant Screen Recording, then re-run)"
echo "    -> Now click the 'Agents' segment in the sidebar, then press Enter"
read -r
snap 2-agents-tab-flat || true
echo "    -> Toggle 'Group by state' on the Agents tab (if exposed), then press Enter"
read -r
snap 3-agents-tab-grouped || true

echo "==> Done. Screenshots in $SHOTS. Quit the QA app when finished:"
echo "    kill $pid"
