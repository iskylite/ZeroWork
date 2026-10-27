# Vendored dependencies

## Zenit

- Upstream: https://github.com/version-next/zenit
- Revision: `9c1ba9bfea58210404e447b04b6ff25b6442f0ff`
- Package: `zenit` (`dev/zig-0.17.0`, complete source snapshot tracked by ZeroWork)
- Local patch revision: `2026-10-27-neutral-empty-input-placeholder` (optional `width`/`wrap`; upstream revision and license unchanged)
- Minimum Zig: `0.17.0`
- License: GPL-3.0-only (commercial alternative documented upstream)
- Canonical source files: `3505` (tracked sources plus declared working-tree additions)
- Canonical tracked-tree SHA-256: `d417156edf6a76521934524fa94e9abc025aac9fee31e5a60b492a8042780e8a`
- Hash algorithm: sort and deduplicate `git ls-files --cached --others --exclude-standard vendor/zenit`; for each path hash big-endian u64 path length, path relative to `vendor/zenit`, big-endian u64 content length, then raw content bytes
- Project decision: GPL-3.0-only use authorized for current development; distribution obligations remain active.

The upstream `LICENSE`, `LICENSING.md`, source, and package metadata are retained under `vendor/zenit/`. Do not update this tree without recording a new fixed revision and reviewing its license and build contract.

Latest local patch keeps placeholders visually neutral for required-but-empty inputs; existing mouse-move hit-count accounting before drag callbacks is retained. No API, toolchain or license changes.

Local adaptations are included in the canonical hash: bounded/wrapping Tooltip content through public optional properties (defaults preserve the existing API and behavior), native close confirmation/commit/completion and IME handling, rendering and hit-test fixes, idle interaction-geometry drainage, material subtree cache ranges, safe focus cleanup, legacy hidden-control window configuration, fixed ASCII grid positioning for explicitly configured terminal faces, and the compile-time automation boundary that removes all process environment overrides from formal macOS App builds. The upstream repository metadata is not required for building this snapshot. Run `python3 scripts/verify_vendor_zenit.py` to verify the exact vendored tree.

## Planned VT dependency

- Preferred upstream: https://github.com/ghostty-org/ghostty
- Tag: `v1.3.1`
- Revision: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- Module: `ghostty-vt`
- Minimum Zig: `0.17.0`
- License: MIT
- Status: official `zig-0.17` branch is vendored under `vendor/libghostty-vt` at `af7fd981e4d9c2af8ab897f5ce86afb982e4e546`; native `zig build -Demit-lib-vt -Dtarget=aarch64-macos.14.0 -Demit-xcframework=false` succeeds with the available uucode dependency cache. ZeroWork adapter/build integration remains the next gate.

### Vendored fallback: libvterm

- Version: `0.3.3`
- Upstream archive: `https://www.leonerd.org.uk/code/libvterm/libvterm-0.3.3.tar.gz`
- Archive SHA-256: `09156f43dd2128bd347cbeebe50d9a571d32c64e0cf18d211197946aff7226e0`
- License: MIT
- Status: verified archive extracted under `vendor/libvterm/`; compiled directly as a C99 static library by `build.zig`.

### Primary VT migration status

- Ghostty upstream was downloaded from `https://github.com/ghostty-org/ghostty` at commit `246f702876b924a1cb7cade1e99274d1470302fc` into `vendor/libghostty-vt` for the requested primary-engine migration.
- Ghostty exposes the intended public `libghostty-vt` C headers and static-library build through `zig build -Demit-lib-vt`; it currently requires additional Zig 0.17 build-system porting in its own dependency packages (`libxml2`, `apple-sdk`, `translate-c`, and `aro`).
- The current ZeroWork build remains green on the validated libvterm fallback while this vendored Ghostty port is isolated. It is not claimed as integrated until the Ghostty static library builds with Zig 0.17 and the VtEngine adapter is switched and tested.

## Planned SSH dependencies

### libssh2

- Tag: `libssh2-1.11.1`
- Revision: `a312b43325e3383c865a87bb1d26cb52e3292641`
- License: BSD-3-Clause
- Status: verified official `libssh2-1.11.1.tar.xz` archive vendored under `vendor/libssh2/`.
- Official archive SHA-256: `9954cb54c4f548198a7cbebad248bdc87dd64bd26185708a294b2b50771e3769`

### Mbed TLS

- Tag: `v3.6.7` / release `mbedtls-3.6.7`
- Revision: `068ff080b369adfac81509f9b57b2afabaf82dc5`
- Official archive SHA-256: `a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6`
- License choice: Apache-2.0
- Status: verified official `mbedtls-3.6.7.tar.bz2` archive vendored under `vendor/mbedtls/`.
