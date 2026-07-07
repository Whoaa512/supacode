#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"

# Pin a Zig-linkable Xcode for `zig build`'s SDK lookups (see select-developer-dir.sh).
# Always delegate so an inherited DEVELOPER_DIR is validated, not trusted blindly.
# Plain assignment, separate export, so a selector failure aborts under set -e.
DEVELOPER_DIR="$("${script_dir}/select-developer-dir.sh")"
export DEVELOPER_DIR
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

# Xcode 26.4+ local-build workaround (zig#31272 / zig#31658): zig 0.15.2 can't
# link the 26.4+ macOS SDK (undefined libSystem symbols in the build runner).
# When the active SDK is too new, point zig's SDK lookups at a concrete <= 26.3
# SDK so the build runner + both slices link. Unlike build-ghostty.sh (which uses
# the arm64-only stub overlay for its single native slice), zmx builds a universal
# binary, so we reuse a full <= 26.3 SDK (which ships both arches). We can't rely
# on DEVELOPER_DIR=CommandLineTools: its default MacOSX.sdk symlink now tracks the
# newest installed SDK (26.5), so we resolve an explicit older SDK path and shim
# zig's internal `xcrun --show-sdk-path` at it (SDKROOT alone is ignored by zig).
# The ghostty package dep would otherwise also build its iOS xcframework slice
# (no iOS SDK under CLT); patches/zmx-emit-lib-vt.patch makes zmx request
# emit-lib-vt + emit-xcframework=false so only the native libghostty-vt is built.

# Newest installed macOS SDK whose version is <= 26.3 (zig-linkable), or empty.
find_linkable_macos_sdk() {
  local dir sdk ver best="" best_ver=""
  local sdk_dirs=(
    /Library/Developer/CommandLineTools/SDKs
    "$(/usr/bin/xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/SDKs"
  )
  for dir in "${sdk_dirs[@]}"; do
    [ -d "${dir}" ] || continue
    for sdk in "${dir}"/MacOSX*.sdk; do
      [ -d "${sdk}" ] || continue
      ver="$(/usr/bin/plutil -extract Version raw "${sdk}/SDKSettings.plist" 2>/dev/null || true)"
      [ -n "${ver}" ] || continue
      [ "$(printf '%s\n26.3\n' "${ver}" | sort -V | tail -1)" = "26.3" ] || continue
      if [ -z "${best_ver}" ] ||
        [ "$(printf '%s\n%s\n' "${best_ver}" "${ver}" | sort -V | tail -1)" = "${ver}" ]; then
        best="${sdk}"
        best_ver="${ver}"
      fi
    done
  done
  printf '%s' "${best}"
}

zig_env=()
active_sdk_ver="$(xcrun --show-sdk-version 2>/dev/null || true)"
if [ -n "${active_sdk_ver}" ] &&
  [ "$(printf '%s\n26.3\n' "${active_sdk_ver}" | sort -V | tail -1)" != "26.3" ]; then
  linkable_sdk="$(find_linkable_macos_sdk)"
  if [ -z "${linkable_sdk}" ]; then
    echo "error: active macOS SDK ${active_sdk_ver} is too new for zig 0.15.2 and no <= 26.3 SDK was found." >&2
    echo "       Install an older SDK (Xcode 26.3, or a MacOSX15.x SDK under CommandLineTools) so zmx can link." >&2
    exit 1
  fi
  shim_dir="${zmx_build_root}/sdk-shim"
  mkdir -p "${shim_dir}"
  cat > "${shim_dir}/xcrun" <<SHIM
#!/bin/bash
if [ "\$1" = "--sdk" ] && [ "\$2" = "macosx" ] && [ "\$3" = "--show-sdk-path" ]; then echo "${linkable_sdk}"; exit 0; fi
if [ "\$1" = "--show-sdk-path" ]; then echo "${linkable_sdk}"; exit 0; fi
exec /usr/bin/xcrun "\$@"
SHIM
  chmod +x "${shim_dir}/xcrun"
  zig_env=(env "PATH=${shim_dir}:${PATH}" "SDKROOT=${linkable_sdk}")
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
