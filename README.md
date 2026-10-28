<p align="center">
  <a href="assets/macos/README.md"><img src="assets/macos/AppIcon.png" width="160" height="160" alt="ZeroWork Logo"></a>
</p>

# ZeroWork

[简体中文](README.zh-CN.md)

ZeroWork is an Apple Silicon macOS SSH terminal specified in [docs/SPEC/OVERALL_ARCHITECTURE.md](docs/SPEC/OVERALL_ARCHITECTURE.md). The implementation follows the [V0.1.1→V0.1.8 design roadmap](docs/DESIGN/README.md), with non-UI work followed by UI integration within each version.

## Current baseline

The current version is **0.2 (plugin host API 2)**. **Only the Figma prototype is confirmed aligned with V3; the App has not yet been synchronized with the full V3 design.** See the [current sanitized baseline](docs/DEVELOPMENT/V0.2_STATUS.md). The implementation and compatibility boundaries are recorded in [V0.2 implementation](docs/DEVELOPMENT/V0.2_IMPLEMENTATION.md); candidate-specific results, real SSH/AI evidence, and environment limitations are in [V0.2 live acceptance](docs/DEVELOPMENT/V0.2_LIVE_ACCEPTANCE.md).

- Zig 0.17.0 project baseline (managed with local zvm), locked to arm64 macOS 14+
- P0 configuration model and strict subset TOML loader
- Atomic configuration replacement with owner-only (0600) permissions
- Sauber renderer tokens, including overlay/AI state colors
- Apple Silicon/macOS platform contract
- Ghostty `libghostty-vt` is the sole VT parser through the Ghostty C ABI/render-state adapter; worker/kqueue contracts own the I/O boundary

Zenit is the native macOS UI layer and is attached from the authorized fixed GPL revision; ZeroWork does not add a separate Objective-C/Swift UI bridge. The app enters Zenit `App.runWith` and all production UI is built through Zenit public APIs. The historical isolated single-CAMetalLayer probe is retained only as documentation in [docs/DEVELOPMENT/P0_NATIVE_SPIKE.md](docs/DEVELOPMENT/P0_NATIVE_SPIKE.md); its source and build target have been removed.

ZeroWork is distributed under GPL-3.0-only while it links the GPL Zenit core; see [LICENSE](LICENSE) and [vendor/DEPENDENCIES.md](vendor/DEPENDENCIES.md).

## Source verification gate

Before committing, run `./scripts/verify_source_gate.sh`. It verifies the tracked Zenit vendor sources, rebuilds the local SSH static dependencies, and runs the full unit and contract tests with Zig 0.17. On success, it removes generated SSH dependency artifacts and `zig-pkg/`. The script does not make live SSH or AI provider requests.

## Build

The target platform is **Apple Silicon running macOS 14 or later**, using **Zig 0.17.0**. Install Xcode Command Line Tools and confirm that `xcrun --find clang` and `zig version` work. Run all commands below from the repository root.

### Local build and direct execution

Before the first build, or after the source verification script has cleaned the dependencies, build the vendored SSH static dependencies:

```sh
./scripts/build_ssh_deps.sh
zig build -j2
```

SSH-linked build targets verify the source/configuration/archive receipt on every
build. After changing vendored SSH sources or their build options, rerun
`./scripts/build_ssh_deps.sh`; `zig build verify-ssh-deps` checks the receipt
without building the application.

Focused SSH hardening checks (owned local peers, no remote credentials):

```sh
python3 scripts/test_verify_ssh_deps.py
sh scripts/test_ssh_native.sh
zig test src/proto/ssh/keepalive_watch.zig
zig build ssh-hardening-acceptance -j2
python3 e2e/ssh_connection_wait.py --runner zig-out/bin/ssh-connection-wait-runner --output /tmp/ssh-waits.json
python3 e2e/ssh_hardening.py --runner zig-out/bin/ssh-hardening-runner --output /tmp/ssh-hardening.json
zig build forward-acceptance -j2
python3 e2e/ssh_mixed_load.py --runner zig-out/bin/socks-worker-host-runner --out /tmp/ssh-mixed-load
python3 e2e/ssh_auth_loopback.py --runner zig-out/bin/ssh-auth-loopback-runner --output /tmp/ssh-auth.json
```

The mixed-load fixture uses one actual production WorkerThread/session for PTY
echo, a 256 KiB SFTP upload and cancelled download, 16 active forwards, and one
forward whose 32 KiB remote window is never replenished. It delays one close
acknowledgement and checks independent sibling cleanup, terminal response,
exact upload/forward bytes, partial-file removal, and listener-port reuse.
Results are local acceptance measurements, not remote-host performance claims.

Connection timeout is one network budget per hop, including DNS/TCP, opening
the next-hop tunnel, handshake, authentication exchanges and shell creation.
Human trust/authentication prompts retain their separate timeout. A stalled
system resolver may finish in the background after cancellation; at most 16
resolver workers may be outstanding, and each owns and releases its inputs
and eventual result. Active terminal sessions with keepalive enabled become
suspected after three keepalive intervals without authenticated inbound SSH
packets (effective interval is at least two seconds); terminal output itself
is not required. A replacement transport starts a fresh liveness window.

Initial SSH terminal connections retry transient transport/handshake failures
up to three total attempts, waiting 500 ms and 1000 ms before the two retries.
Each retry releases the previous graph and rebuilds the frozen route with a
fresh operation identity and per-hop timeout. Intermediate failures stay in
connection logs; only the final failure publishes a notification. Cancelling
also stops a pending retry. Authentication, host-key and algorithm/configuration
failures require user action and are not automatically retried by this policy.

The main executable is written to `zig-out/bin/zerowork`. The same directory contains `zw_ipc.so`, which is required for local shell integration. Run the application using either command:

```sh
# Run the executable directly
./zig-out/bin/zerowork

# Or build and run through Zig
zig build run -j2
```

Both methods open a native window directly. Neither creates an `.app` bundle or DMG, nor installs the application in Applications. A normal build uses the current account’s regular application data. Use the testing workflow below when data isolation is required.

For an optimized build, run:

```sh
zig build -j2 -Doptimize=ReleaseFast
```

### Tests and native window verification

The native window verification script also requires Node.js 26. No npm dependencies need to be installed.

```sh
# Run unit, UI, local terminal, and plugin fixture tests with isolated temporary data
./scripts/test_isolated.sh test
./scripts/test_isolated.sh test-ui test-local test-plugin-fixture

# Enable the Harness explicitly for automated native window interaction and screenshots
zig build -j2 -Dtest-mode=true -De2e-port=19818
node e2e/reported_ui_regressions.ts /tmp/zerowork-ui-check
```

This window verification script launches `zig-out/bin/zerowork` directly in a separate process with a temporary data directory. It checks the sidebar, status control, popovers, and terminal rendering using the real native window and a local PTY, then saves reports and screenshots to the specified directory. It does not install the application and does not validate DMG installation. See [e2e/README.md](e2e/README.md) for more Harness usage.

To return to a normal build after testing, run `zig build -j2` again. Do not use `-Dtest-mode=true` for release builds.

Diagnostic logging uses a dedicated writer with its own IO lifetime. Producers
copy records into a fixed 256-entry queue (at most 2 KiB per record); 32 entries
are reserved for warnings/errors. Full queues and lock contention drop records
without blocking producers, with counters exposed by `applog.snapshot()` and a
summary written by the owner. Oversized records carry a truncation marker.
`requestFlush`/`pollFlush` acknowledge accepted records only after file sync;
`flush(timeout_ms)` is for bounded CLI/test waits. `shutdownStep` stops admission
and polls actual resource release; final-process `shutdown` waits approximately
200 ms at most. A stuck IO retains its writer and prevents replacement writers
or data-directory deletion until a real release. Accepted records still queued
at the close deadline may be dropped and counted; the kernel call already in
progress cannot be forcibly cancelled. File errors disable disk retries and
stderr failures disable that mirror. Run focused regressions with
`zig test src/applog_tests.zig -lc`.

The isolated test wrapper creates a temporary canonical data directory and removes it on exit. Use it for test targets so recordings and configuration never enter the account’s real App data. Normal app data lives in `~/Library/Application Support/com.zerowork.app`, cache in `~/Library/Caches/com.zerowork.app`, and diagnostics in `~/Library/Logs/com.zerowork.app`; saved credentials use the app’s Keychain vault. Existing `~/.zerowork` is migrated on startup. Settings → Data & Logs → Export & Cleanup → Clear All Application Data… clears owned data and exits; deleting the `.app` alone keeps user data.

For developer-only verification, the disposable SSH integration gate is `scripts/ssh_smoke.sh`; its environment inputs do not configure or enable features in the installed App. Password mode reads `ZEROWORK_SSH_PASSWORD`; public-key mode additionally reads `ZEROWORK_SSH_KEY` and treats the password value as an optional key passphrase; agent mode sets `ZEROWORK_SSH_AGENT=1`. Credentials are never stored in the repository. The Zig-owned Session smoke is `src/ssh_session_smoke.zig`; it uses the same environment-only credentials and validates the formal libssh2 Session owner against the disposable VM.

The native Zenit app opens saved connections and Quick Connect targets through its UI. Configure AI providers, endpoints, models and API keys in Settings → AI; saved secrets use macOS Keychain. The installed App ignores application and framework environment overrides, uses the current macOS account’s standard data directories, and requires no shell setup or environment variables. Network connections begin only through the corresponding App action. Automated data isolation and framework diagnostics are compiled into explicit test-mode builds only.

## Native packaging

To create an installation image, run the packaging script separately:

```sh
# First use only: create and retain a local self-signed identity
python3 scripts/macos_signing.py setup

# Write to dist/ by default
sh scripts/package_macos.sh

# Or specify an output directory
sh scripts/package_macos.sh /absolute/path/to/output
```

The script checks the saved signing identity before building, verifies the Zenit vendor sources, builds the SSH static dependencies if needed, and creates `ZeroWork.app` from a `ReleaseFast` build with test mode disabled. It adds the icon and required resources, signs with the persistent local self-signed identity, and verifies both the signature and the DMG. The outputs are `ZeroWork-<version>-arm64.dmg` and its `.dmg.sha256` checksum file. The `.app` bundle is inside the DMG, and the temporary packaging directory is removed on exit. The script refuses to overwrite an existing DMG at the same path; remove the old image or use another output directory before repackaging.

The signing private key stays in the current user's Keychain; only the public certificate and fingerprint are stored in `~/Library/Application Support/com.zerowork.signing/`. Repeated setup reuses the same identity. If it is missing, restore the original identity instead of generating a replacement. macOS may request authorization during setup or signing. Packaging uses only the saved identity and does not fall back to ad-hoc signing. Saved application credentials continue to use Keychain. A stable signing identity does not guarantee that existing Keychain access will never require authorization again.

To verify installation, open the DMG, drag `ZeroWork.app` into Applications, eject the installation image, and launch the app from Applications. **Direct execution, successful packaging, and verification after installation are three separate checks.** Self-signing does not provide Developer ID signing or Apple notarization. Those steps and installation checks on a clean machine must be completed separately for distribution.

## Privacy and credentials

The installed App obtains SSH credentials through connection settings and authentication dialogs, using saved Keychain references, user-selected private keys, or the configured ssh-agent. It does not read passwords or API keys from environment variables. Independent smoke runners may accept caller-supplied test credentials; these are not installed-App startup requirements, and credentials are never committed. Session logs and checkpoints are written locally with owner-only (`0600`) permissions. Session context and approved tool results, including images, are sent to the user's configured AI provider when the assistant is invoked. Acceptance credentials are supplied through isolated private configuration and are excluded from repository evidence.
