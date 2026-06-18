#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
repo_root="${srcroot}"
zmx_dir="${srcroot}/ThirdParty/zmx"
zmx_submodule_path="${zmx_dir#"${repo_root}/"}"
zmx_patches_dir="${srcroot}/patches/zmx"
zmx_build_root="${srcroot}/.build/zmx"
zmx_global_cache_dir="${zmx_build_root}/.zig-global-cache"
zmx_fingerprint_path="${zmx_build_root}/fingerprint"
zmx_binary_path="${zmx_build_root}/bin/zmx"

# Mirror Xcode's ARCHS_STANDARD for macOS (arm64, x86_64); resync if Configurations/Project.xcconfig pins ARCHS.
# Unconditional: every build emits both slices regardless of CONFIGURATION / ONLY_ACTIVE_ARCH.
zmx_targets=(
  "x86_64-macos"
  "aarch64-macos"
)

print_fingerprint() {
  (
    cd "${zmx_dir}"
    {
      git rev-parse HEAD
      git diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
      git ls-files --others --exclude-standard | LC_ALL=C sort | shasum -a 256
      shasum -a 256 "${script_path}" | awk '{print $1}'
      shasum -a 256 "${srcroot}/mise.toml" | awk '{print $1}'
    } | shasum -a 256 | awk '{print $1}'
  )
}

ensure_zmx_checkout() {
  if [ -f "${zmx_dir}/build.zig" ]; then
    return
  fi

  git -C "${repo_root}" submodule sync --recursive -- "${zmx_submodule_path}"
  git -C "${repo_root}" submodule update --init --recursive -- "${zmx_submodule_path}"

  if [ ! -f "${zmx_dir}/build.zig" ]; then
    echo "error: missing ${zmx_dir} after submodule update" >&2
    exit 1
  fi
}

# Patch the pinned submodule in place for this build only, restoring it on exit
# so the pin / `git status` stays clean. The patch makes zmx request ghostty's
# `emit-lib-vt` + `emit-xcframework=false` so the ghostty package dep builds only
# the native libghostty-vt and skips its iOS xcframework slice — which would
# otherwise need an iOS SDK the Command Line Tools toolchain lacks (and is dead
# weight everywhere, since zmx only links ghostty-vt).
apply_zmx_patches() {
  [ -d "${zmx_patches_dir}" ] || return 0
  local patch
  for patch in "${zmx_patches_dir}"/*.patch; do
    [ -e "${patch}" ] || continue
    if git -C "${zmx_dir}" apply --reverse --check "${patch}" 2>/dev/null; then
      continue # already applied
    fi
    if ! git -C "${zmx_dir}" apply --check "${patch}" 2>/dev/null; then
      git -C "${zmx_dir}" checkout -- . 2>/dev/null || true
      if ! git -C "${zmx_dir}" apply --check "${patch}" 2>/dev/null; then
        echo "error: ${patch} does not apply cleanly to ${zmx_submodule_path}." >&2
        echo "       The submodule may have been bumped (refresh the patch)." >&2
        exit 1
      fi
    fi
    git -C "${zmx_dir}" apply "${patch}"
  done
}

revert_zmx_patches() {
  [ -d "${zmx_patches_dir}" ] || return 0
  local patch
  for patch in "${zmx_patches_dir}"/*.patch; do
    [ -e "${patch}" ] || continue
    if git -C "${zmx_dir}" apply --reverse --check "${patch}" 2>/dev/null; then
      git -C "${zmx_dir}" apply --reverse "${patch}" 2>/dev/null ||
        git -C "${zmx_dir}" checkout -- . 2>/dev/null || true
    fi
  done
}

ensure_zmx_checkout

revert_and_signal_exit() {
  revert_zmx_patches
  trap - EXIT INT TERM
  case "$1" in
    TERM) exit 143 ;;
    *) exit 130 ;;
  esac
}
trap revert_zmx_patches EXIT
trap 'revert_and_signal_exit INT' INT
trap 'revert_and_signal_exit TERM' TERM
apply_zmx_patches

if [ "${1:-}" = "--print-fingerprint" ]; then
  print_fingerprint
  exit 0
fi

fingerprint="$(print_fingerprint)"

mkdir -p "${zmx_build_root}"
rm -rf "${zmx_build_root}/.zig-cache"

if [ -f "${zmx_fingerprint_path}" ] &&
  [ -x "${zmx_binary_path}" ] &&
  [ "$(cat "${zmx_fingerprint_path}")" = "${fingerprint}" ]; then
  exit 0
fi

cd "${zmx_dir}"

# Xcode 26.4+ local-build workaround (zig#31272): zig 0.15.2 can't link the
# 26.4+ macOS SDK (undefined libSystem symbols). When the active SDK is too new,
# point zig at the Command Line Tools SDK (<= 26.3) so the build runner + slices
# link. The ghostty package dep would otherwise also build its iOS xcframework
# slice (no iOS SDK under CLT); patches/zmx-emit-lib-vt.patch makes zmx request
# emit-lib-vt + emit-xcframework=false so only the native libghostty-vt is built.
zig_env=()
active_sdk_ver="$(xcrun --show-sdk-version 2>/dev/null || true)"
if [ -n "${active_sdk_ver}" ] &&
  [ "$(printf '%s\n26.3\n' "${active_sdk_ver}" | sort -V | tail -1)" != "26.3" ] &&
  [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]; then
  zig_env=(env DEVELOPER_DIR=/Library/Developer/CommandLineTools)
fi

slice_paths=()
for target in "${zmx_targets[@]}"; do
  slice_prefix="${zmx_build_root}/slices/${target}"
  slice_cache="${slice_prefix}/.zig-cache"
  slice_binary="${slice_prefix}/bin/zmx"
  "${zig_env[@]}" mise exec -- zig build \
    -Doptimize=ReleaseSafe \
    -Dtarget="${target}" \
    --prefix "${slice_prefix}" \
    --cache-dir "${slice_cache}" \
    --global-cache-dir "${zmx_global_cache_dir}"
  if [ ! -x "${slice_binary}" ]; then
    echo "error: zmx build produced no binary at ${slice_binary} for target ${target}" >&2
    exit 1
  fi
  slice_paths+=("${slice_binary}")
done

mkdir -p "$(dirname "${zmx_binary_path}")"
lipo -create "${slice_paths[@]}" -output "${zmx_binary_path}"

# Defense in depth: -verify_arch fails closed on a partial / thin lipo output, but exits silently.
if ! lipo "${zmx_binary_path}" -verify_arch x86_64 arm64; then
  echo "error: zmx universal binary at ${zmx_binary_path} is missing x86_64 or arm64 slice" >&2
  exit 1
fi

printf '%s\n' "${fingerprint}" > "${zmx_fingerprint_path}"
