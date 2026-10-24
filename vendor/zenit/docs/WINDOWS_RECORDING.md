# Windows app-window recording

D3D12 applications built with `-Dtest-mode=true` support the Harness
`/recording/start`, `/recording/status` and `/recording/stop` endpoints.
Use a new writable `.mp4` path and a target FPS from 1 to 120.
Existing files are not overwritten.

The recorder captures submitted application content before Present, including
the Harness virtual cursor. It excludes other windows, native titlebars,
the OS cursor and audio. Media Foundation encodes H.264; missing encoder
support returns a recording error without preventing normal GUI startup.

Frame submission uses a bounded queue. If encoding falls behind, frames can
be dropped; target FPS is best effort, and timestamps preserve elapsed time.
Stopping drains pending capture and finalizes the MP4. Closing the window also
stops recording.

Dimensions are fixed for one session. Odd dimensions receive a black padding
row or column. Resizing stops the recording with an explicit error; start a
new session for the new size. A zero-frame session fails.

## Validation

```sh
zig build windows-arm64-recording-contract -Dwindows-arch=x86_64 -Doptimize=fast
```

Run `zenit-windows-recording-contract.exe` on Windows. For ARM64, use
`-Dwindows-arch=aarch64`. The contract covers argument checks, padding,
backpressure, finalization, idempotent stop and no-overwrite behavior.

The [Windows batch](WINDOWS_BUILD.md) includes application recording tests for
asynchronous D3D12 capture, text changes, restart and resize behavior.
