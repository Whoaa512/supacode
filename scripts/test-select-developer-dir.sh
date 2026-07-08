#!/usr/bin/env bash
# Regression test for the fork's select-developer-dir.sh fallthrough: when no
# Zig-linkable (<= 26.3 SDK) Xcode exists, the script must print the active
# Xcode and exit 0 so the hermetic SDK overlay can handle linking — NOT abort.
# Upstream's version (#468) hard-exits 1 here and has clobbered the fork's
# fallthrough during a sync before.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fake active Xcode that looks like a full Xcode (has usr/bin/xcodebuild) but
# whose SDK reports 26.5 (not zig-linkable), so every candidate fails the
# <= 26.3 gate and only the fallthrough can succeed.
fake_dev="$tmp/FakeXcode.app/Contents/Developer"
mkdir -p "$fake_dev/usr/bin"
printf '#!/bin/sh\nexit 0\n' > "$fake_dev/usr/bin/xcodebuild"
chmod +x "$fake_dev/usr/bin/xcodebuild"

mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho "%s"\n' "$fake_dev" > "$tmp/bin/xcode-select"
printf '#!/bin/sh\necho 26.5\n' > "$tmp/bin/xcrun"
chmod +x "$tmp/bin/xcode-select" "$tmp/bin/xcrun"

out="$(env -u DEVELOPER_DIR PATH="$tmp/bin:/usr/bin:/bin" \
  bash "$script_dir/select-developer-dir.sh")" || {
  echo "FAIL: script exited non-zero with no <=26.3 Xcode; fallthrough regressed (upstream #468 behavior)" >&2
  exit 1
}

if [ "$out" != "$fake_dev" ]; then
  echo "FAIL: expected fallthrough to active Xcode '$fake_dev', got '$out'" >&2
  exit 1
fi

echo "OK: falls through to active Xcode when no <=26.3 SDK is linkable"
