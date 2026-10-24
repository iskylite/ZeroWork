# zenit examples

Fourteen applications demonstrating different facets of the framework. **Every one uses the public `ui` and `zenit_app` APIs through `build.zig` (Yix examples also import their generated view module)** — they double as the build-time fence that enforces the [open-source boundary](../docs/UI_OSS_BOUNDARY.md).

Most examples write their UI in Yix: `view.yix` holds the components and `styles.yss` holds their styles, `main.zig` only starts the app (and runs smoke assertions for the probes). `main.zig` imports its generated twin, `@import("_view.yix.zig")` (checked in; `zig build gen-yix` regenerates it). Exceptions: `zig_native` deliberately uses no Yix / YSS (components, controlled values, slots and recipes written in plain Zig with `ui.view` — the path for people who prefer Zig only), `counter_reactive` stays hand-written as the pixel reference for `yix_counter`, `interop_probe` wires raw node events below the template layer; Storybook uses a mix of Zig and Yix views.

| example | what it shows |
|---|---|
| [`hello_button/`](hello_button/) | Minimal Button + scoped state, ui.view and ui.on |
| [`counter_reactive/`](counter_reactive/) | Signal + computed text + cva variants in ui.view |
| [`zig_native/`](zig_native/) | Reusable components in plain Zig (no Yix / YSS): props, `Model` controlled value, slots, sva recipes, keyed list |
| [`virtual_list_perf/`](virtual_list_perf/) | 100k-row `VirtualList` (constant cost regardless of dataset size) |
| [`text_input/`](text_input/) | `Input` and `Textarea`, including IME (CJK) support — exercises `text_core` integration |
| [`multi_window/`](multi_window/) | Public `MultiWindowApp`: two native windows, isolated routing, single/last-window teardown |
| [`storybook/`](storybook/) | Complete component showcase and real-window E2E target |
| [`console_probe/`](console_probe/) | `ui.console` diagnostic Console + DevTools console panel verification target |
| [`devtools_probe/`](devtools_probe/) | DevTools performance panel real-window acceptance probe |
| [`interop_probe/`](interop_probe/) | Rich clipboard / drag-out real-system interop verification target |
| [`design_probe/`](design_probe/) | Pixel-accurate rebuild of a pencil design node, for numeric design-diff verification |
| [`yix_counter/`](yix_counter/) | Yix version of the reactive counter (styles in `styles.yss`) |
| [`window_chrome/`](window_chrome/) | Custom window Header per window backend (AppKit / Win32 / Wayland), native or application-drawn caption controls |
| [`adaptive_window/`](adaptive_window/) | One Header adapted to every desktop: caption layouts per preset, native fallback, fullscreen Header and a real window per preset |

Requires [Zig **0.17.0**](https://ziglang.org/download/). Yix/Yss workflow: [developer guide](../docs/YIX_YSS_GUIDE.md).

## Run them

The following commands run on macOS. For Windows x64/ARM64 executables, use [WINDOWS_BUILD.md](../docs/WINDOWS_BUILD.md).

```bash
zig build hello-button         # build .app bundle (ad-hoc signed)
zig build run-hello-button     # run unbundled
zig build window-chrome        # custom window Header example
zig build adaptive-window      # platform-adaptive window example

zig build yix-counter
zig build run-yix-counter
zig build zig-native
zig build run-zig-native
zig build counter-reactive
zig build run-counter-reactive

zig build virtual-list-perf
zig build run-virtual-list-perf

zig build text-input
zig build run-text-input

zig build multi-window
zig build run-multi-window

zig build storybook
zig build run-storybook

zig build console-probe
zig build run-console-probe
zig build devtools-probe
zig build run-devtools-probe
zig build interop-probe
zig build run-interop-probe
zig build design-probe
zig build run-design-probe
```

After building, each example produces `zig-out/<Display Name>.app` you can double-click.

## Why so small?

5–6 MB for a complete `.app` bundle that draws a window, lays out widgets, handles input, and renders via Metal. There's no language toolchain, no editor engine, no workspace persistence — just the GUI. That's the boundary: "I want a button" should not pull a language server.

## Why are the single-window examples so similar?

All single-window examples follow the same skeleton:

```zig
pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .title = "Example", .width = 640, .height = 480 },
    });
    defer app.deinit();

    try app.runWith(mountUI); // mountUI: fn(*ui.Cx, *ui.Scope) !*ui.Node
}
```

`App.init` does NSApplication setup + window creation + GPU surface + font
loading + UI Cx wiring in a single call. `App.runWith(mountUI)` then creates
the root reactive `Scope`, calls your `mountUI` to build the initial tree,
attaches it to `cx`, and runs the event loop until the window closes. The
differences between examples live entirely inside `mountUI()`.

Multi-window applications use `MultiWindowApp.createWindowWith` and one
application loop. It routes each native event/menu command to the matching
window and owns safe per-window teardown. Low-level `App` fields (`cx`, `sdk`,
`renderer`, `font_selector`, etc.) remain public for genuinely custom host loops.

For a real-window lifecycle smoke (requires a logged-in macOS WindowServer):

```bash
bash scripts/run_multiwindow_smoke.sh 120
```

## Adding a new example

1. Create `examples/your_example/main.zig`.
2. Add an entry to the `examples` array in `build.zig` (look for `"hello_button"`).
3. Run `bash scripts/check_oss_boundary.sh` to confirm the boundary is still intact.

Imports must stay limited to `@import("ui")` and `@import("zenit_app")`. If an example reaches for a language toolchain or a richer document model, it's application code, not framework code — keep it out of this directory.

## Application design system

All examples share [`theme.json`](theme.json), compiled automatically into a
provider for their own UI/App module graph. Library defaults use a separate
provider. The generated theme provider lives in the build cache. Yix/Yss generated twins (`_*.yix.zig`, `_*.yss.zig`) are checked in alongside their source files.

```zig
const TOKENS = ui.theme.refs;
const label = ui.css(.{ .font_size = TOKENS.font_size.counterValue });
const title = ui.css(.{ .typography = TOKENS.typography.counterTitle });
// Where computation is needed, style functions read t.tokens.*.
// Built-in recipes read the same semantic tokens directly.
cx.setTheme(&ui.theme.modes.dark);
```

Base and semantic tokens share this one namespace; duplicate paths are rejected.
Base scales live in `tokens` (for example `space50 = 2`, `space100 = 4`,
`space200 = 8`); semantic contains roles and typography aggregation. Component
size combinations belong in cva/sva recipes, not theme categories.
`counterValue` (18px) and `counterHeading` (24px) are application names, not
framework enum cases. `hello_button` demonstrates `ui.cva` with a Signal-backed
variant; both Counter implementations share the same token-based styles.
Component states and layout choices stay in Zig/Yix. Built-in recipes require
the semantic names they reference; there is no bindings table or implicit fallback.

See [build integration](../docs/design-system/TOOLING.md) for consuming this API
from a separate application.
