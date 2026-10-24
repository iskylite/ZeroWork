# Zig 0.17 development branch

`dev/zig-0.17.0` is the development branch for the released Zig **0.17.0**.
It does not change the Zenit package version or announce a stable Zenit release.

```sh
zig version                         # must report 0.17.0
zig build dev-tools                  # yix-lsp and zenit-zls
zig build test-all -Dyix-gen=check
zig build test-zls yix-lsp-smoke
zig build test-package-consumer
cd editors/vscode-yix && npm ci && npm test
```

Run native window gates sequentially, after other native tests have exited:

```sh
bash scripts/run_storybook_e2e.sh
ZENIT_E2E_TEST_FILE=e2e/interaction-lifecycle.test.ts bash scripts/run_storybook_e2e.sh
```

The public CI also runs the 11 focused window regression files. These gates
require a macOS desktop session and Metal; cross-compilation is not a substitute
for Windows runtime acceptance. OS input can influence idle-frame measurements.
See [Windows batch acceptance](WINDOWS_ACCEPTANCE.md) for guest-local one-job execution.

## Bundled ZLS

The source in `vendor/zls` is a lazy, separately built development dependency.
Ordinary GUI builds do not compile or link ZLS. Zig may resolve package metadata;
the tooling build fetches its hash-pinned transitive dependencies as needed. Its MIT license,
upstream base, PR provenance, local fixes and real build-protocol regression are
included; see [PROVENANCE.md](../vendor/zls/PROVENANCE.md) and
[ZIG017.md](../vendor/zls/ZIG017.md). All transitive Zig dependencies are hash-pinned.
The Yix extension selects the workspace `zenit-zls`; other Zig editors can configure
its absolute path. Explicit editor configuration remains authoritative.

Zig 0.17's build protocol has limits for uncompiled exported modules, build-script-only
dependencies, dotted dependency aliases and install-prefix-relative lazy paths;
see the dependency documentation before relying on these cases.

## Public source policy

The export uses the package allowlist and contains source, reproducible tests,
reference documentation and third-party license notices. Private icon packs,
internal planning/audit documents, machine-specific calibration captures,
private host automation, caches, credentials and generated build outputs are excluded.
The public Git repository additionally includes CI and ignore rules; these are not
required in a fetched Zig package. Run `bash scripts/check_public_source.sh` before
publishing a source snapshot.

## Performance gate

Benchmarks are compared against `src/bench/baselines/main.json` with a 15%
regression threshold. The baseline uses Zig 0.15.2 / `CLOCK_REALTIME`; this branch
uses Zig 0.17.0 / `CLOCK_UPTIME_RAW` through `std.Io.Clock.awake`. Timings depend
on the host and are not universal performance guarantees.

The Select benchmark measures the navigation state machine and open-dropdown
frame workload. Full keyboard dispatch is covered separately by window tests.

```sh
ZENIT_BENCH_COMMIT="$(git rev-parse HEAD)" \
ZENIT_BENCH_HOST="$(uname -m)-$(sw_vers -productVersion)" \
zig build bench -- json=/tmp/zenit-bench.json
BENCH_RERUN_CMD='zig build bench -- json=%OUT%' \
bash scripts/check_bench_regression.sh src/bench/baselines/main.json /tmp/zenit-bench.json 15
```
