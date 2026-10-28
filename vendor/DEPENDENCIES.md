# Vendored dependencies

## Zenit

- Upstream: https://github.com/version-next/zenit
- Revision: `9c1ba9bfea58210404e447b04b6ff25b6442f0ff`
- Package: `zenit` (`dev/zig-0.17.0`, complete source snapshot tracked by ZeroWork)
- Local patch revision: `2026-10-27-terminal-idle-capacity` (upstream revision and license unchanged)
- Minimum Zig: `0.17.0`
- License: GPL-3.0-only (commercial alternative documented upstream)
- Canonical source files: `3505` (tracked sources plus declared working-tree additions)
- Canonical tracked-tree SHA-256: `e83da1af280a16df2aaf5bb2494813d26124c950c139b2763e4686f542b0cc0d`
- Hash algorithm: sort and deduplicate `git ls-files --cached --others --exclude-standard vendor/zenit`; for each path hash big-endian u64 path length, path relative to `vendor/zenit`, big-endian u64 content length, then raw content bytes
- Project decision: GPL-3.0-only use authorized for current development; distribution obligations remain active.

The upstream `LICENSE`, `LICENSING.md`, source, and package metadata are retained under `vendor/zenit/`. Do not update this tree without recording a new fixed revision and reviewing its license and build contract.

Latest local patch adds `Cx.trimIdleRenderCapacity` for idle windows: it releases spare display-item capacity, defers arena shrinking until the normal frame boundary, and preserves live replay payloads and reusable font/GPU caches. Frame and display-list scratch use page-backed allocation. Opt-in frame profiling also attributes after-layout callbacks and renderer setup/text warming; formal builds retain the existing automation boundary.

The preceding local patch drains continuous native mouse-drag motion in the same bounded event batch as hover motion, preventing one rendered frame per queued drag position. Button, key and text boundaries retain native order. No API, toolchain or license changes.

The preceding local patch synchronizes single-line input caret, selection and hit testing with the inherited font size and weight used by rendering, including explicitly selected font families, monospace and italic faces. Multiline editable rows pin the font size, weight and line height used by caret measurement; wrapping and virtual row pitch follow programmatic metric changes. No API, toolchain or license changes.

The previous local patch keeps placeholders visually neutral for required-but-empty inputs; existing mouse-move hit-count accounting before drag callbacks is retained. No API, toolchain or license changes.

Local adaptations are included in the canonical hash: bounded/wrapping Tooltip content through public optional properties (defaults preserve the existing API and behavior), native close confirmation/commit/completion and IME handling, rendering and hit-test fixes, idle interaction-geometry drainage, material subtree cache ranges, safe focus cleanup, legacy hidden-control window configuration, fixed ASCII grid positioning for explicitly configured terminal faces, and the compile-time automation boundary that removes all process environment overrides from formal macOS App builds. The upstream repository metadata is not required for building this snapshot. Run `python3 scripts/verify_vendor_zenit.py` to verify the exact vendored tree.

Terminal acceptance additionally extends only the compile-time test Harness: mouse requests can specify left/middle/right buttons and key names resolve the existing KeyCode enum, allowing F1–F12 and editing keys through the production dispatcher. No VT injection or screen-state override is added; formal builds retain their existing automation boundary. No toolchain or license changes.

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

Local patch `2026-10-27-independent-forward-opens` adds ZeroWork's opaque
direct-tcpip open contexts in `src/channel.c`, and keeps replies for other
channels queued while matching a response in `src/packet.c`. Each pending target retains its
own channel-open/reply state; the transport, native channel registry and IO
thread remain shared. This prevents an unresponsive target from blocking other
forwarding targets or RTT samples. Context buffers remain owned until native
completion or the parent Session's actual release. The upstream revision,
crypto backend and license are unchanged; `scripts/build_ssh_deps.sh` rebuilds
the patched source into the static library.

Local patch `2026-10-28-channel-close-reply` keeps `_libssh2_channel_close`
reading after unrelated positive packet results until the matching channel's
CLOSE arrives or transport IO would block. An EOF or a sibling's data packet
must not be treated as the close acknowledgement and release ownership early.
The delayed-close RTT fixture covers this together with preserving the measured
RTT while native cleanup is still pending.

Local patch `2026-10-28-bounded-channel-dispatch` caps each channel
read/write/forward-accept input drain and close-acknowledgement drain at 32
transport packets. At the limit it yields EAGAIN, retaining queued packets
and the pending close state. A continuously readable sibling cannot monopolize
the shared IO owner. `scripts/test_ssh_native.sh` feeds an endless stream of
valid IGNORE packets through these native entry points and verifies bounded
return without falsely acknowledging close. A read-only native write-state query
distinguishes a pinned send from a zero-window wait, allowing cancelled forwards
to close without waiting for the peer to grant more data window. The production mixed-load fixture
is `e2e/ssh_mixed_load.py` (PTY + SFTP + 16 forwarded channels, delayed close).

Local patch `2026-10-28-ssh-hardening`:

- Backports the READLINK/REALPATH string-length bound from upstream
  [2dae3024897e1898d389835151f4e9606227721d](https://github.com/libssh2/libssh2/commit/2dae3024897e1898d389835151f4e9606227721d)
  into the existing 1.11.1 parser (its minimum packet-size guard is retained).
- Backports the full-packet cipher length bound from upstream
  [97acf3dfda80c91c3a8c9f2372546301d4a1a7a8](https://github.com/libssh2/libssh2/commit/97acf3dfda80c91c3a8c9f2372546301d4a1a7a8).
- Corrects the Mbed TLS cipher encrypt/decrypt direction and disables its PKCS#7 padding for SSH CBC, which already has protocol
  padding; rejects any cipher output length different from the input buffer.
  This local correction is covered by NIST CBC known-answer/segmented roundtrip and actual
  loopback CBC-only negotiation, as well as normal CTR peers.
- Exposes a read-only authenticated packet sequence accessor to the owning
  worker for liveness detection. No payload, new crypto backend or library
  replacement is introduced.

`scripts/build_ssh_deps.sh` writes an ignored local receipt binding vendored
source content, build scripts, compiler/SDK, environment options, generated
configuration and both static archives. Every application/test/runner link
against SSH depends on `scripts/verify_ssh_deps.py`; stale or missing artifacts
fail with a rebuild instruction. `zig build verify-ssh-deps` checks explicitly.

### Mbed TLS

- Tag: `v3.6.7` / release `mbedtls-3.6.7`
- Revision: `068ff080b369adfac81509f9b57b2afabaf82dc5`
- Official archive SHA-256: `a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6`
- License choice: Apache-2.0
- Status: verified official `mbedtls-3.6.7.tar.bz2` archive vendored under `vendor/mbedtls/`.
