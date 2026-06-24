# Vendored libSystem `.tbd` stubs (zig 0.15.2 + macOS 26.x SDK workaround)

These are Apple TAPI text stubs copied verbatim from the **macOS 15.4 SDK**
(`MacOSX15.4.sdk`, `Version 15.4`). They exist solely to work around a zig
0.15.2 linker limitation, see `scripts/sdk-overlay.sh` and
`scripts/build-ghostty.sh`.

## Why

zig 0.15.2 cannot resolve `arm64` (aarch64) libc symbols for a **native** host
target against the macOS 26.x SDK, because Apple dropped the plain `arm64-macos`
target from `libSystem.tbd` and ~33 of its reexported system stubs (they now
export only `arm64e-macos`). For native targets zig 0.15.2 matches the arch
strictly and resolves zero libSystem symbols, so the build runner and native
host tools fail to link. (zig 0.16.0 added the arm64↔arm64e fallback; the pinned
ghostty hard-requires 0.15.2.)

These 15.4 stubs still carry `arm64-macos`. `sdk-overlay.sh` builds an overlay
SDK that uses the live 26.x headers/frameworks but shadows `libSystem` + its
reexports + `libc++` with these stubs, so native host links succeed while the
real 26.x SDK is still used for everything else.

## Set

- `usr/lib/{libSystem,libSystem.B,libc++,libc++abi}.tbd`
- `usr/lib/system/*.tbd` (the full libSystem reexport set)

## Refreshing

Re-copy from the newest macOS SDK that still ships `arm64-macos` in its tbds
(check `rg -c arm64-macos <sdk>/usr/lib/libSystem.tbd`). This whole workaround
is retired once ghostty/supacode move to zig 0.16+.
