#!/usr/bin/env bash
set -euo pipefail

# Verifies zmx's session-state replay survives a client kill + reattach — the
# mechanism Supacode's scrollback restore-on-launch depends on. Runs against
# the built zmx binary only (no app required), in an isolated ZMX_DIR.
#
# Regression guard for the 2026-07 upstream zmx bump (6084a4e3 -> 4b4e2a86)
# whose new pre-state-tracking output filtering could eat scrollback content.
# The probe content includes the patterns that expose such filtering bugs:
#   - plain text markers
#   - OSC 8 hyperlinks (wrapped text must survive, sequences may be stripped)
#   - UTF-8 chars whose encoding ends in 0x9D (e.g. U+255D) followed by "8;",
#     which a naive OSC-8 detector misreads as an OSC introducer and then
#     swallows everything until the next BEL/ST.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
zmx_path="${ZMX:-${repo_root}/.build/zmx/bin/zmx}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[ -x "${zmx_path}" ] || fail "missing executable zmx at ${zmx_path}. Run: scripts/build-zmx.sh"

exec /usr/bin/env python3 - "${zmx_path}" <<'PYEOF'
import fcntl
import os
import pty
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

zmx = sys.argv[1]
zdir = tempfile.mkdtemp(prefix="zmx-replay-smoke-")
session = "smoke-replay"
env = dict(os.environ, ZMX_DIR=zdir)
# The harness may itself run inside a zmx session; a set ZMX_SESSION makes
# `zmx attach` switch sessions instead of creating/attaching ours.
env.pop("ZMX_SESSION", None)
# Hermetic shell: the user's zsh init (e.g. powerlevel10k instant prompt) can
# drop input typed during startup, flaking the harness.
env["SHELL"] = "/bin/bash"
env["PS1"] = "$ "

MARKER = b"SMOKE-MARKER-42"
LINK_TEXT = b"SMOKE-LINKTEXT"
AFTER_LINK = b"SMOKE-AFTER-LINK"
AFTER_9D = b"SMOKE-AFTER-9D"

# printf script emitting the probe content (see header comment). Every
# needle is split with '' quote-concatenation so the shell's echo of the
# typed command never contains a contiguous needle — only the actual PTY
# output does. Otherwise a state tracker that eats output would still pass
# because the command echo carries the marker.
probe_cmd = (
    b"printf '"
    b"SMOKE-MAR''KER-42\\n"
    b"\\033]8;;http://example.com\\033\\\\SMOKE-LINK''TEXT\\033]8;;\\033\\\\ SMOKE-AFTER''-LINK\\n"
    b"\\342\\225\\2358; SMOKE-AFTER''-9D\\n"
    b"'\n"
)


def attach(keys, capture_seconds):
    """Attach a pty client, type keys, capture output, then SIGKILL the
    client (simulating an app quit) leaving the daemon alive."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(zmx, [zmx, "attach", session], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    out = b""
    os.set_blocking(fd, False)

    def drain(seconds, quiet_after=1.0):
        nonlocal out
        got_any = False
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                chunk = os.read(fd, 65536)
                if chunk:
                    out += chunk
                    got_any = True
                    deadline = time.time() + quiet_after
            except BlockingIOError:
                time.sleep(0.05)
            except OSError:
                break
        return got_any

    # Wait for the shell prompt (any output) before typing, up to 10s.
    if keys and not drain(10.0):
        print("FAIL: no shell output after attach; harness broken", file=sys.stderr)
    for key in keys:
        os.write(fd, key)
        drain(5.0)
    drain(capture_seconds)
    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass
    os.close(fd)
    return out


def zmx_run(*args):
    return subprocess.run([zmx, *args], env=env, capture_output=True, timeout=15)


failures = []
try:
    first = attach([probe_cmd], capture_seconds=2.0)
    if MARKER not in first:
        failures.append("probe command produced no output on first attach; harness broken")

    # Deterministic check: `history` returns the daemon's serialized terminal
    # state — the exact payload replayed to a reattaching client.
    history = zmx_run("history", session).stdout
    replay = attach([], capture_seconds=4.0)

    for name, needle in (
        ("plain marker", MARKER),
        ("OSC8 link text", LINK_TEXT),
        ("text after OSC8 link", AFTER_LINK),
        ("text after 0x9D byte + '8;'", AFTER_9D),
    ):
        if needle not in history:
            failures.append(f"{name} missing from serialized state (zmx history)")
        if needle not in replay:
            failures.append(f"{name} missing from reattach replay")
finally:
    zmx_run("kill", session)
    shutil.rmtree(zdir, ignore_errors=True)

if failures:
    for f in failures:
        print(f"FAIL: {f}", file=sys.stderr)
    sys.exit(1)
print("PASS: zmx scrollback state survived client kill + reattach")
PYEOF
