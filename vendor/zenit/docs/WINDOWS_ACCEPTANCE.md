# Windows 11 batch acceptance

Use Zig 0.17.0 and Bun on the build host. The acceptance worker must run in an
interactive Windows desktop with PowerShell/.NET. VM deployment credentials and
machine addresses belong in local configuration, outside this repository.

Build every executable before submitting the batch:

```sh
zig build windows-arm64-storybook windows-arm64-text-input windows-arm64-render-gallery \
  -Dwindows-arch=aarch64 -Dtest-mode=true -Dgpu-backend=d3d12 -Doptimize=fast \
  --prefix /tmp/zenit-windows
zig build windows-arm64-gpu-resources-contract -Dwindows-arch=aarch64 \
  -Dwindows-gpu-contract-scope=all -Doptimize=fast --prefix /tmp/zenit-windows
python3 tools/windows_batch.py --arch aarch64 --skip-build \
  --artifact-dir /tmp/zenit-windows/bin --require-a11y \
  --prepare-only --output-dir /tmp/zenit-windows-payload
```

The prepared payload contains four PE executables, 30 bundled suites, a stage
manifest and a matching Windows x64 baseline Bun runtime (usable under Windows
on Arm emulation). No queue token or VM contact is needed for preparation.
For an x64 guest, use `x86_64` consistently in build and batch commands.

With an authenticated worker connected, submit one batch:

```sh
python3 tools/windows_batch.py --base "$ZENIT_VM_BASE" --arch aarch64 \
  --skip-build --artifact-dir /tmp/zenit-windows/bin --require-a11y
```

The tool prepares all artifacts before its single job submission. The worker
runs each suite alongside its application, using guest-local file RPC; individual
harness calls do not cross the host connection. It returns stage evidence after
executing the full plan. Stage archives travel in 512 KiB parts, with each part
and the assembled archive checked by SHA-256. Retries preserve completed parts;
no test RPC crosses the host connection during execution. Require the batch
completion status and every row of `batch-report.json` to pass. Install the worker
and host queue from the same revision; batch evidence uses the part-upload
protocol rather than the legacy whole-file upload endpoint.

The 31-stage plan covers 13 shared render/input gates, the complete render-gallery
suite (including texture replacement), nine native feature suites, the complete
native GPU contract probe, and seven UI Automation suites. Native feature suites
check optical glass, quality fallback, submitted screenshots, local frame actions,
timed capture, repeated text editing, recording, and CPU/GPU timing contracts. Modal, Sheet and Notification
submitted-frame archives receive separate audits. This plan excludes manual
hardware/foreground experiments and does not establish real GPU hardware acceptance
when run in a VM. Without `--require-a11y`, accessibility failures are only reported;
use the strict option for acceptance. `zig build test-windows-batch` verifies offline
preparation and fail-closed option contracts without starting a VM.
