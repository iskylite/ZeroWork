# zenit

A Zig GUI framework for native desktop apps. GPU-rendered (Metal), retained node
tree, reactive state, flexbox-style layout, and a component library.

Manual and component gallery: [ui.surf/zenit](https://ui.surf/zenit/)

This development branch targets Zig **0.17.0** and includes a compatible ZLS source
dependency. See [the compatibility guide](docs/ZIG_0_17_COMPAT.md) for setup,
validation commands and protocol limits.

## Status

| | |
|---|---|
| **Maturity** | Alpha (`0.1.0-alpha`). The API will break before v1, so pin a revision. |
| **Platforms** | macOS (Metal); experimental Windows x64/ARM64 (D3D12 or D3D11), see [Windows build](docs/WINDOWS_BUILD.md); experimental Linux Wayland (Vulkan, or OpenGL with `-Dgpu-backend=opengl`). |
| **Accessibility** | Not supported. See [Accessibility](#accessibility). |
| **Zig** | `0.17.0` |

## How zenit is built

Most of the code, docs and tests in this repo were written with AI coding
agents. Architecture, review and acceptance are done by a human. We say this up
front so nobody has to guess.

Because of that, we don't treat "it compiles and looks right" as evidence. What
CI actually checks:

- About 2,700 deterministic unit tests (`zig build test`), plus a separate run
  on a null GPU backend and one against a real Metal device.
- An allocation-failure campaign (`zig build test-allocation-campaign`) that
  fails each allocation in turn and checks for leaks and broken state, not just
  the happy path.
- Real-window E2E against the storybook: screenshots are compared as pixels,
  not only node trees.
- Module boundary, API-removal and formatting ratchets that fail the build.
- Benchmarks compared against the `main` baseline on every run.

If you find a bug, a design problem or a security issue, please
[open an issue](https://github.com/version-next/zenit/issues) (or use
[`SECURITY.md`](SECURITY.md) for security). Concrete reports are the most
useful thing you can send.

## Developing with AI agents

Start with [SKILL.md](SKILL.md) for Zenit application development. It is a
repository-local guide for Claude, Codex and other coding agents, with current
API rules and references for Yix/Yss, lifecycle, platform builds and E2E.
When using Zenit as a dependency, point your project's agent instructions to
that checkout's `SKILL.md`.

## Prerequisites

- macOS (Apple Silicon recommended), or Windows for the dedicated Windows build targets
- [Zig `0.17.0`](https://ziglang.org/download/) on `PATH` (or `ZIG=/path/to/zig` for repo scripts)
- macOS: Xcode Command Line Tools, `xcode-select --install`
- `bun`, only if you run the E2E suite

Windows commands: [WINDOWS_BUILD.md](docs/WINDOWS_BUILD.md). Yix/Yss workflow: [YIX_YSS_GUIDE.md](docs/YIX_YSS_GUIDE.md).

## Quick start

```zig
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

const v = ui.view;

// Typed style objects resolve application tokens and follow theme changes.
const S = struct {
    const root = ui.css(.{ .width = .fill, .height = .fill, .gap = .space400, .align_items = .center, .justify = .center });
    const title = ui.css(.{ .font_size = .xxxl, .color = .fg_primary });
};

fn inc(n: u32) u32 {
    return n + 1;
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    // State is a Signal owned by the mount scope; it is freed with the scope.
    const count = try scope.createSignal(u32, 0);

    // The UI is one declarative tree. Elements are values; `render` mounts them
    // once, and only fine-grained effects run afterwards (no virtual DOM).
    return v.render(scope, cx, v.col(.{ .style = S.root }, .{
        v.text(.{ .style = S.title }, "Hello, zenit!"),
        ui.widgets.Button(.{ .label = "Click me", .on_click = ui.on.update(count, inc) }),
        // Bound to `count`: re-formats and repaints on every `set()`.
        v.text(.{}, v.fmt("Clicked {d} times", .{count})),
    }));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .title = "Hello", .width = 640, .height = 480 },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
```

The full example, with a derived `Memo`, conditional styles and `show` /
`fallback`, is in [`examples/counter_reactive/`](examples/counter_reactive/):

```bash
zig build counter-reactive       # .app bundle, ad-hoc signed
zig build run-counter-reactive   # run unbundled
```

To explore components and DevTools on macOS:

```sh
zig build run-storybook
```

See [all examples and probes](examples/README.md) for the complete command list.
On Windows, use the [dedicated Storybook target](docs/WINDOWS_BUILD.md).

### The view tree (`ui.view`)

`ui.view` is the one way to build UI. A short tour (full reference in
[`docs/VIEW_DSL.md`](docs/VIEW_DSL.md)):

| Write | For |
|---|---|
| `v.box / v.row / v.col(props, .{ children })` | containers |
| `v.text(props, "literal" / v.fmt(...) / text_signal)` | text |
| `v.icon(.{ .style, .tint }, asset)` | icons |
| `W.Button(.{ ... })` (any widget builder) | components are children as-is |
| `v.with(W.ScrollArea(...), .{ children })` | put children into a component's slot |
| `v.show(cond, .{...}).fallback(.{...})` / `v.match(enum, .{...})` / `v.each(items, .id, row)` | control flow, anchored where it is written |
| `v.list(array, f)` | expand a static array |
| `.style = S.Card.of(.{ .selected = selected })` | composed, conditional, theme-following styles |
| `ui.on.set / toggle / update / assign / call / bind` | event handlers without boilerplate |
| `v.attrs(.{ .test_id, .style }, W.Button(...))` | extra attributes on a component root |

### Reactivity rules

- **Create reactive state through a `Scope`**: `scope.createSignal`,
  `scope.createMemo`, `scope.createEffect`. Everything is released when the
  scope is disposed (the mount scope is disposed on unmount). There is no
  second, unscoped path on `Cx`.
- **Event handlers, timers and animation ticks are batched.** If a handler sets
  several signals, every effect that depends on them runs once, after the
  handler returns, and sees the final values. Outside those entry points (for
  example, in tests) wrap multi-signal writes in `owner.batch(...)` yourself.
- **Bind, don't push.** Show a value through the view tree (`v.fmt`, a text
  signal, `v.show`, `v.each`, `v.when` styles) instead of writing to nodes and
  calling `markRenderDirty()`. Node-level code belongs inside components (and
  in `v.setup`, the explicit escape hatch).
- **Component props.** Anything that can change is a signal-friendly prop: pass
  a literal for a fixed value, or a `*Signal(T)`, `*Memo(T)` or derived value
  (`ui.not(busy)`, `ui.map(count, f)`) to keep it in sync. Values the user can
  change, such as `checked`, are a `Model` (a controlled value): a plain value
  keeps the state inside the component, a `*Signal(T)` makes your signal the
  source that interactions write to, and `ui.split(read, on_write)` lets the
  parent accept, transform or reject each change. There is one source of truth:
  the component only proposes, the view follows the source, and `on_change`
  reports the value that actually landed (see `docs/SIGNAL_API_DESIGN.md`).

## Using zenit in your project

Add the dependency:

```zig
// build.zig.zon
.dependencies = .{
    .zenit = .{ .path = "../path/to/zenit" },
},
```

Then attach it to your executable. This adds the `ui` and `zenit_app` modules,
the macOS ObjC bridges and the system frameworks:

```zig
// build.zig
const zenit = @import("zenit");

const zenit_dep = b.dependency("zenit", .{ .target = target, .optimize = optimize });
const exe = b.addExecutable(.{ ... });
zenit.attach(zenit_dep, exe);
```

The quickest start is copying [`templates/minimal-app/`](templates/minimal-app/).
The full walkthrough is [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md).
Icons default to [Lucide](https://lucide.dev); `zenit.attachWithOptions` lets
you plug in another provider.

## What's in it

`ui.X` holds the ~50 names every app uses: `Cx`, `Node`, `Scope`, `Style`,
builders (`box`, `text`, `image`, `icon`, `grid`, ...), reactive primitives
(`Signal`, `Memo`; created through `Scope`), and control flow (`Show`, `For`, `Match`).

Everything else is grouped by namespace:

| namespace | contents |
|---|---|
| `ui.widgets` | Components: `Button`, `Input`, `Modal`, `Tabs`, `VirtualList`, `Calendar`, `Form`, ... |
| `ui.fx` | Animation and transitions: `Tween`, `Spring`, `AnimatedValue`, `Easing`, `Router`, ... |
| `ui.events` | Event enum and payloads |
| `ui.hooks` | `useHover`, `useFocusRing`, `useToggle`, `onMount`, `onCleanup`, ... |
| `ui.reactive` | `Context`, `Store`, `SignalOwner` |
| `ui.focus`, `ui.actions` | Focus scopes and tab order; actions and key bindings |
| `ui.theme`, `ui.arb` | Theme tokens; escape hatches for off-token values ([`docs/STYLING.md`](docs/STYLING.md)) |
| `ui.icons`, `ui.system_icons` | Full icon catalog; the semantic subset components use |
| `ui.hit`, `ui.path`, `ui.gesture` | Hit testing, path geometry, gesture recognition |
| `ui.console`, `ui.devtools` | Diagnostics console and inspector ([`CONSOLE.md`](docs/CONSOLE.md), [`DEVTOOLS.md`](docs/DEVTOOLS.md)) |

Modules under `core/`, `reactive/`, `i18n/` etc. are internal and unstable.

`zenit_app` provides the native window, the Metal surface and renderers, IME,
clipboard, file dialogs, and `.app` bundling.

### Module layout

```
your app
  └─ zenit_app        App runtime, UI commands to GPU
       ├─ ui          node tree, reactivity, layout, components, animation
       ├─ system_sdk  platform layer (NSWindow / Metal / IME on macOS)
       ├─ render      SDF, text and image renderers
       ├─ gpu         thin Metal wrapper
       └─ text        font loading and shaping
            └─ text_core, icon_ir
```

`ui` produces a flat display list and contains no GPU code.

## Out of scope

zenit is a GUI framework. Language tooling (tree-sitter, LSP, regex), editor
surfaces, document models and app shells (sidebars, palettes, file trees)
belong in applications. The `hello-button` example only links `ui` and
`zenit_app`, so a forbidden import fails the build.
[`scripts/check_oss_boundary.sh`](scripts/check_oss_boundary.sh) runs the
stricter check. Details: [`docs/UI_OSS_BOUNDARY.md`](docs/UI_OSS_BOUNDARY.md).

## Accessibility

Not supported in this release. There is an accessibility tree, roles on
components and an NSAccessibility bridge, with tests that simulate bridge calls.
None of the 61 components has been tested with VoiceOver by a person, and we
make no WCAG claim. Don't use zenit where accessibility is a requirement yet.

VoiceOver test notes for any single component are a very welcome contribution.

## Multiple windows

`MultiWindowApp` gives each window its own `Cx`, Metal surface, renderer, event
route and IME context:

Pass `init.io` from `main(init: std.process.Init)` to each window configuration
(`io` in the snippet below).

```zig
var application = zenit_app.MultiWindowApp.init(allocator, .{});
defer application.deinit();

const editor = try application.createWindowWith(.{
    .io = io,
    .window = .{ .width = 900, .height = 700, .title = "Editor" },
}, mountEditor);
_ = try application.createWindowWith(.{
    .io = io,
    .window = .{ .width = 480, .height = 700, .title = "Preview" },
}, mountPreview);

_ = application.activateWindow(editor.windowId());
try application.run();
```

Up to 16 windows (`error.TooManyWindows` beyond that). `closeWindow(id)` is safe
inside callbacks; teardown happens at the end of the iteration. See
[`examples/multi_window/`](examples/multi_window/).

For a custom loop, `App.run()` is just `pump` / `processEvents` / `frame`, and
all `App` fields are public.

## Bundling

```zig
_ = zenit.bundleApp(b, .{
    .exe = my_exe,
    .display_name = "My App",
    .bundle_id = "com.acme.myapp",
    .version = "1.0.0",
    .signing = .ad_hoc, // .none / .ad_hoc / .developer_id
    .icon = b.path("assets/icon.icns"),
});
```

This generates `Info.plist`, copies resources and signs the bundle. Developer ID
signing and notarization are available through `.developer_id` and
`zenit.notarizeBundle`. DMG, auto-update and crash reporting are not included.

## Performance

The target is 60 fps in Debug builds for basic interaction (typing, cursor
movement, scrolling) on M-series Macs, including virtual lists with tens of
thousands of rows. This relies on triple-buffered GPU instances, subtree
caching of the display list, layout isolation boundaries, and splitting heavy
work across frames.

## License

GPL-3.0-only, or a commercial license for closed-source use (contact
zongyi.xzy@gmail.com). `templates/` and `examples/` are also 0BSD. See
[LICENSING.md](LICENSING.md).

## Stability

`ui.X`, the namespaces listed above and `zenit_app.App` are the proposed v1
surface. Until `v1.0.0`, breaking changes can land in minor releases and are
recorded in [`docs/MIGRATION.md`](docs/MIGRATION.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the gates a PR has to pass. Open
render bugs in the [issue tracker](https://github.com/version-next/zenit/issues)
are a good place to start. Designers are welcome too: component visuals, motion
timing and interaction details all need review.

Security issues go through [`SECURITY.md`](SECURITY.md).
[Code of Conduct](CODE_OF_CONDUCT.md).
