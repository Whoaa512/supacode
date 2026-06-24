#!/usr/bin/env bash
# Hermetic SDK overlay for building GhosttyKit with zig 0.15.2 against a macOS
# 26.x SDK. See scripts/sdk-stubs/README.md for the full why.
#
# zig 0.15.2 can't resolve arm64 libc symbols for a *native* host target against
# the 26.x SDK (its libSystem tbds export only arm64e-macos). We build an overlay
# SDK that reuses the live 26.x headers/frameworks but shadows libSystem + its
# reexports + libc++ with vendored 15.4 stubs (which still carry arm64-macos), then
# point zig's `xcrun --sdk macosx --show-sdk-path` at it via a PATH shim.
#
# Sourced by build-ghostty.sh. Two entrypoints:
#   ghostty_make_sdk_overlay <real_sdk> <stub_dir> <out_dir>   -> prints overlay SDK path
#   ghostty_make_build_shims <overlay_sdk> <out_dir>           -> prints shim dir (prepend to PATH)

set -euo pipefail

# Build an overlay SDK at <out_dir>/MacOSX.sdk: every entry symlinks the live SDK,
# except the vendored host-link tbds which are symlinked from <stub_dir>. Rebuilt
# fresh each call (symlinks are cheap) so it never goes stale against an SDK bump.
ghostty_make_sdk_overlay() {
  local real_sdk="$1" stub_dir="$2" out_dir="$3"

  # Absolutize: symlink targets must be absolute or they break relative to the
  # overlay. CDPATH= keeps a user CDPATH from making `cd` echo the directory.
  real_sdk="$(CDPATH= cd "${real_sdk}" && pwd)"
  stub_dir="$(CDPATH= cd "${stub_dir}" && pwd)"
  rm -rf "${out_dir}"
  mkdir -p "${out_dir}"
  out_dir="$(CDPATH= cd "${out_dir}" && pwd)"
  local ov="${out_dir}/MacOSX.sdk"
  mkdir -p "${ov}/usr/lib/system"

  # Top level: symlink everything except usr (we need to shadow tbds under it).
  local e b
  for e in "${real_sdk}"/* "${real_sdk}"/.[!.]*; do
    [ -e "${e}" ] || continue
    b="$(basename "${e}")"
    [ "${b}" = usr ] && continue
    ln -s "${e}" "${ov}/${b}"
  done

  # usr: symlink everything except lib.
  for e in "${real_sdk}/usr"/*; do
    [ -e "${e}" ] || continue
    b="$(basename "${e}")"
    [ "${b}" = lib ] && continue
    ln -s "${e}" "${ov}/usr/${b}"
  done

  # usr/lib top level: symlink live entries except those a stub shadows (same
  # basename present under stub_dir/usr/lib), then add the stubs.
  for e in "${real_sdk}/usr/lib"/*; do
    [ -e "${e}" ] || continue
    b="$(basename "${e}")"
    [ "${b}" = system ] && continue
    [ -e "${stub_dir}/usr/lib/${b}" ] && continue
    ln -s "${e}" "${ov}/usr/lib/${b}"
  done
  for e in "${stub_dir}/usr/lib"/*.tbd; do
    [ -e "${e}" ] || continue
    ln -s "${e}" "${ov}/usr/lib/$(basename "${e}")"
  done

  # usr/lib/system: stubs fully replace the live tbd set (the vendored libSystem
  # only reexports the libs present here). Symlink live non-tbd entries through.
  for e in "${real_sdk}/usr/lib/system"/*; do
    [ -e "${e}" ] || continue
    case "${e}" in *.tbd) continue;; esac
    ln -s "${e}" "${ov}/usr/lib/system/$(basename "${e}")"
  done
  for e in "${stub_dir}/usr/lib/system"/*.tbd; do
    [ -e "${e}" ] || continue
    ln -s "${e}" "${ov}/usr/lib/system/$(basename "${e}")"
  done

  printf '%s\n' "${ov}"
}

# Write PATH shims at <out_dir>/bin and print the dir (prepend to PATH):
#
#  * xcrun  - returns the overlay path for `xcrun --sdk macosx --show-sdk-path`
#    (zig's native SDK detection); everything else delegates to /usr/bin/xcrun.
#    Steps that must hit the real SDK (Metal, xcframework assembly) call
#    /usr/bin/xcrun by absolute path and are unaffected.
#
#  * libtool - translates `libtool -static -o OUT IN...` into an llvm-ar (zig ar)
#    MRI merge. Xcode 26's libtool silently drops archive members that aren't
#    8-byte aligned (zig emits such objects, e.g. the ~9MB libghostty_zcu.o that
#    carries the embedded C API), so the combined fat lib loses ghostty_app_* and
#    the consuming app fails to link. llvm-ar preserves every member. Any other
#    libtool usage delegates to the real /usr/bin/libtool.
ghostty_make_build_shims() {
  local overlay_sdk="$1" out_dir="$2"
  local bin="${out_dir}/bin"

  rm -rf "${out_dir}"
  mkdir -p "${bin}"

  cat > "${bin}/xcrun" <<EOF
#!/bin/sh
sdk=macosx
want_path=0
prev=
for a in "\$@"; do
  case "\$a" in --show-sdk-path|-show-sdk-path) want_path=1;; esac
  case "\$prev" in --sdk|-sdk) sdk="\$a";; esac
  prev="\$a"
done
if [ "\$want_path" = 1 ] && [ "\$sdk" = macosx ]; then
  printf '%s\n' "${overlay_sdk}"
  exit 0
fi
exec /usr/bin/xcrun "\$@"
EOF
  chmod +x "${bin}/xcrun"

  cat > "${bin}/libtool" <<'EOF'
#!/bin/sh
# Translate `libtool -static -o OUT IN...` into an llvm-ar MRI merge.
static=0
out=""
expect_out=0
inputs=""
for a in "$@"; do
  if [ "$expect_out" = 1 ]; then out="$a"; expect_out=0; continue; fi
  case "$a" in
    -static) static=1; continue;;
    -o) expect_out=1; continue;;
  esac
  inputs="$inputs $a"
done
if [ "$static" = 1 ] && [ -n "$out" ]; then
  zig="$(command -v zig 2>/dev/null || true)"
  {
    printf 'create %s\n' "$out"
    for i in $inputs; do printf 'addlib %s\n' "$i"; done
    printf 'save\nend\n'
  } | { [ -n "$zig" ] && "$zig" ar -M || mise exec -- zig ar -M; }
  exit $?
fi
exec /usr/bin/libtool "$@"
EOF
  chmod +x "${bin}/libtool"

  printf '%s\n' "${bin}"
}
