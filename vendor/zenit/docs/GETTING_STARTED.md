# Getting Started with zenit

This guide walks through building a real, runnable zenit application in a
fresh project, independent of the zenit repository.

If you only want to play with the bundled examples, skip ahead to the
"Running the bundled examples" section at the end.

Prerequisite: Zig **0.17.0**. This guide's `.app` commands target macOS.
For Windows x64/ARM64 builds and batch acceptance, use [WINDOWS_BUILD.md](WINDOWS_BUILD.md).
For Yix components and Yss styles, use [YIX_YSS_GUIDE.md](YIX_YSS_GUIDE.md).

## 1. Create a project

```bash
mkdir myapp && cd myapp
```

Copy the [`templates/minimal-app/`](../templates/minimal-app/) directory from
zenit into your project root. It contains:

```
myapp/
├── build.zig          # uses zenit.attach()
├── build.zig.zon      # declares zenit dep
├── e2e/record-demo.ts # optional Harness recording example
└── src/
    ├── main.zig      # counter app
    └── styles.zig    # token-based css objects
```

After copying, adjust the `.path` in `build.zig.zon` to wherever your zenit
checkout actually lives relative to the new location, e.g. if `myapp/` sits
next to the zenit checkout, use `.path = "../zenit"`.

## 2. Wire the dependency

In `build.zig.zon`:

```zig
.dependencies = .{
    // Local dev against a working copy of zenit (recommended while the
    // upstream API is unstable):
    .zenit = .{ .path = "../zenit" },

    // Or pin a specific revision (replace <fork> and <rev>; the easiest way
    // to get the hash is `zig fetch --save=zenit <url>` after pushing):
    // .zenit = .{
    //     .url = "https://github.com/<fork>/zenit/archive/<rev>.tar.gz",
    //     .hash = "...",
    // },
},
```

`zig build` will resolve the dependency and cache it.

## 3. Wire the build

zenit's root `build.zig` is a public build API: once `.zenit` is declared in
your `build.zig.zon`, `const zenit = @import("zenit");` works at the top of
your `build.zig` (Zig 0.17.0), and a single `zenit.attach(zenit_dep, exe)`
call wires everything: the `ui` / `zenit_app` module imports, the five macOS
native ObjC bridges, and the system frameworks:

```zig
const std = @import("std");
const zenit = @import("zenit");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_mode = b.option(bool, "test-mode", "Enable the Zenit automation harness") orelse false;
    const e2e_port = b.option(u16, "e2e-port", "Zenit Harness RPC directory suffix") orelse 19816;

    const zenit_dep = b.dependency("zenit", .{
        .target = target,
        .optimize = optimize,
        .@"test-mode" = test_mode,
        .@"e2e-port" = e2e_port,
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    zenit.attach(zenit_dep, exe);
    zenit.installHarnessClient(b, zenit_dep);

    b.installArtifact(exe);
}
```

This public setup defaults to the ISC-licensed Lucide provider. Icon selection
is part of the dependency build graph and never rewrites Zenit source files.
Reusable framework/package code should use `ui.system_icons.<semantic_name>`;
application artwork can use the complete Lucide catalog through `ui.icons`.

If you want to see (or customize) the manual wiring, read `attach` /
`addNativeLibs` in zenit's `build.zig`. It is the same boilerplate this
helper replaces.

The forwarded Harness options default to disabled and do not affect production
builds. `installHarnessClient` puts the optional TypeScript controller at a
stable path under `zig-out`; see [`HARNESS.md`](HARNESS.md) for automated input,
virtual cursor, screenshot, and application-surface recording examples.

## 4. Application code

Two `@import` lines and a `mountUI` callback. The UI is one declarative tree
built with `ui.view` (the recommended application API; reference in
[`VIEW_DSL.md`](VIEW_DSL.md)):

```zig
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

const v = ui.view;

const S = struct {
    const root = ui.css(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center });
    const title = ui.css(.{ .font_size = .xxxl, .color = .fg_primary });
};

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.root }, .{
        v.text(.{ .style = S.title }, "Hello, zenit!"),
    }));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 640, .height = 480, .title = "myapp" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
```

`App.runWith(mountUI)` covers:
- Creating the root reactive `Scope` and binding it to the `Cx`
- Calling your `mountUI` once to build the initial tree
- Setting `cx.root` and `cx.is_mounted`
- Running the event loop until the window closes

You only ever write `mountUI`. Anything imperative (cursor, focus, drawing,
GPU surface configuration, font fallback) is internalized.

Keep named `ui.css` objects in `styles.zig`; tokens resolve against the application theme.
Use `ui.cva` for finite states and `ui.sva` when several slots share variants. Pass them
as `.style = S.Card.of(.{ .selected = signal })`. Continuous calculations can use
`v.styleBy(signal, S.sized)` or theme-aware functions. See [STYLING.md](STYLING.md).

Inline sizes accept numbers, `.fill`, `.fit`, and size tokens; use a typed `ui.Sizing`
value for other sizing forms. Base and semantic materials share `ui.theme.refs`,
usually aliased to `TOKENS`; resolved function values live under `t.tokens.*`.

## 5. State and event handlers

State is a `Signal` created through the scope; handlers write it directly with
`ui.on`, so there is no handler struct to declare:

```zig
fn inc(n: u32) u32 {
    return n + 1;
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const count = try scope.createSignal(u32, 0);
    const open = try scope.createSignal(bool, false);

    return v.render(scope, cx, v.col(.{}, .{
        ui.widgets.Button(.{ .label = "+1", .on_click = ui.on.update(count, inc) }),
        ui.widgets.Button(.{ .label = "Reset", .on_click = ui.on.set(count, 0) }),
        ui.widgets.Button(.{ .label = "Details", .on_click = ui.on.toggle(open) }),
        v.text(.{}, v.fmt("Clicked {d} times", .{count})),
        v.show(open, .{v.text(.{}, "Details go here")}),
    }));
}
```

| Combinator | Effect | Allocates |
|---|---|---|
| `ui.on.set(sig, value)` | set to a compile-time value | no |
| `ui.on.toggle(sig)` | flip a bool | no |
| `ui.on.update(sig, f)` | `sig = f(sig)` | no |
| `ui.on.assign(sig)` | write a value event (`on_change`) into the signal | no |
| `ui.on.call(state, method)` | call `method(state)` / `method(state, value)` | no |
| `ui.on.bind(scope, ctx, f)` | capture runtime values (a row id…) | once, freed with the scope |

When several handlers share state, put it in a struct and use `ui.on.call`.
`cx.bindState(T, init)` allocates a stable `*T` for that:

```zig
const Editor = struct {
    text: *ui.Signal([]const u8),
    fn save(self: *Editor) void { ... }
};
const editor = try cx.bindState(Editor, .{ .text = try scope.createText("", .{}) });
// ... W.Button(.{ .label = "Save", .on_click = ui.on.call(editor, Editor.save) })
```

**Lifetime caveat**: the framework frees the `T` allocation itself, but it does
**not** call `T.deinit()`. If your state owns heap resources (ArrayList,
HashMap, allocated buffers), register cleanup explicitly or they will leak:

```zig
const Canvas = struct {
    items: std.ArrayList(Item) = .empty,
    pub fn deinit(self: *Canvas) void { self.items.deinit(my_allocator); }
};
const canvas = try cx.bindState(Canvas, .{});
try scope.onCleanup(Canvas, canvas, Canvas.deinit); // ← without this, `items` leaks
```

## 6. Reactive state (Signal / Memo / Effect)

Derived values are memos or inline derivations; the view binds to them:

```zig
const count = try scope.createSignal(u32, 0);
const doubled = try scope.createMemo(u32, .{ .count = count }, struct {
    fn compute(ctx: anytype) u32 { return ctx.count.get() * 2; }
}.compute);
const even = ui.map(count, isEven); // inline, allocation-free derivation

return v.render(scope, cx, v.col(.{}, .{
    v.text(.{}, v.fmt("count = {d}", .{count})),
    v.text(.{}, v.fmt("doubled = {d}", .{doubled})),
    v.box(.{ .style = S.Badge.of(.{ .even = even }) }, .{"parity"}),
}));
```

Whenever `count.set(...)` runs, the bound text and the conditional style update
automatically. This is the pattern in
[`examples/counter_reactive/`](../examples/counter_reactive/).

Lists use `v.each(items_signal, .id, row)`: rows are keyed, so changing the
slice only creates and destroys the rows whose key changed, and the list stays
where it is written in the tree even when siblings toggle.

## 7. Bundling (.app on macOS)

`zenit.bundleApp` produces a complete `.app`:

```zig
if (target.result.os.tag == .macos) {
    const bundle = zenit.bundleApp(b, .{
        .exe = exe,
        .display_name = "My App",
        .bundle_id = "com.example.myapp",
        .version = "0.1.0",
        .signing = .ad_hoc,
        .clear_quarantine = true,
    });
    const app_step = b.step("app", "Build .app bundle");
    app_step.dependOn(bundle.final_step);
}
```

Ad-hoc signing works out of the box; Developer ID signing / notarization
docs are planned.

## 8. Inspecting your UI

When something doesn't look the way you expect, the inspector overlay is
the fastest way to see why. One line in your `mountUI` turns it on:

```zig
fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const root = try v.render(scope, cx, v.col(.{ .style = S.root }, .{ ... }));

    // Optional, dev only: dashed-rect hover highlighting + dimension label.
    _ = try ui.devtools.overlay.attach(cx, scope, root, .{});

    return root;
}
```

Now hovering over any node draws a cyan dashed rectangle around it and
shows `120 × 32  Button` (dimensions and component name) just above. The
overlay does not intercept pointer events (`hit_behavior = .pass_through`),
so clicks/scrolls go through to the real node.

Common uses:

- **"Why isn't this aligned?"**: hover at the suspect spot and read the
  rect. Often the parent's padding/gap is off, not the child.
- **"What component am I looking at?"**: the label shows
  `component_name`, which widget builders set automatically (`"Button"`,
  `"Popover"`, `"DatePicker"`, ...).
- **"Why is this huge invisible area capturing clicks?"**: hover over it.
  An overflow node or absolute-positioned overlay will become obvious.

You can pass a custom config:

```zig
_ = try ui.devtools.overlay.attach(cx, scope, root, .{
    .border_color = ui.Color.rgba(255, 80, 80, 220), // red instead of cyan
    .border_width = 2.0,
    .label_bg = ui.Color.rgba(0, 0, 0, 230),
});
```

For the heavier "elements / components / performance" tabs (a separate
window with state inspection), use `ui.devtools.mountPanel` instead; it's
designed to live in a second window mounted alongside the app you're
debugging.

## Running the bundled examples

If you cloned the zenit repo itself and just want to see things move:

```bash
zig build run-hello-button
zig build run-counter-reactive
zig build run-virtual-list-perf
zig build run-text-input
```

Or build a signed `.app`:

```bash
zig build hello-button
open "zig-out/Hello Button.app"
```

Each of the four examples is wired in `build.zig` with **only** `ui` and
`zenit_app` as imports, so they double as the build-time fence enforcing the
[open-source boundary](UI_OSS_BOUNDARY.md).

## Troubleshooting

### Build / setup

| Symptom | Likely cause / fix |
|---|---|
| `zig version too old` | zenit needs `0.17.0`; check `build.zig.zon`. |
| `framework not found: Cocoa` | Install Xcode Command Line Tools (`xcode-select --install`). |
| `error: import of file outside module path` running `zig test` on a single file | zenit modules use relative `@import("../X.zig")` paths. Run tests via `zig build test-ui` (or whichever step), not standalone `zig test`. |
| `@import("zenit")` fails in your `build.zig` | Works on Zig 0.17.0, but only when `.zenit` is declared in your `build.zig.zon` dependencies. Check the dep is named exactly `zenit` and the `.path`/`.url` resolves. See [`templates/minimal-app/build.zig`](../templates/minimal-app/build.zig). |
| `error: expected path relative to build root; found absolute path` | `.path` in `build.zig.zon` must be relative to that file. Convert your absolute path. |
| `invalid fingerprint: 0x0` | Replace the placeholder with a unique value. Easiest: delete the `.fingerprint` line, run `zig build` once. Zig prints the value to paste back. |

### Runtime / visuals

| Symptom | Likely cause / fix |
|---|---|
| Black window / no text | Default font fallback chain (Helvetica Neue -> Arial -> Helvetica -> Inter -> Menlo) missed. Override via `App.init(.{ .font = .{ .fallback_families = &.{"YourFont"} } })`. |
| Layout looks wrong / element in unexpected position | Use the inspector overlay (see "Inspecting your UI" above). The dashed rect + dimension label nearly always reveals the issue. |
| Click goes to the wrong node | Same: hover overlay shows you the actual hit-test target. If a transparent ancestor is capturing clicks, set `hit_behavior = .pass_through` on it via `style.ensureExt(allocator).hit_behavior`. |
| Hover/pressed state never resets | Make sure you're calling `app.processEvents()` each frame (or using `app.run()` / `app.runWith()`, which does it for you). |
| Text appears clipped to a wrong line count | `text(...)` defaults to single-line. Pass `.wrap = .word` and an explicit `width` (or grow). |
| Frame rate drops on large lists | Use `ui.widgets.VirtualList`. Plain `box` with thousands of children layouts every node every frame. |

### Reactive / state

| Symptom | Likely cause / fix |
|---|---|
| `error: StateNotFound` from `cx.handler(...)` | You used the explicit-id form without a prior `cx.state(T, id, init)`. Use `ui.on.*` (or `cx.bindState(T, init)` + `ui.on.call(ptr, T.method)`); no id needed. |
| `type '@Type(.enum_literal)' not a function` in a style | `.fill()` / `.fixed(n)` inside an inline style literal. Move it into a style function or write `.{ .px = n }`. |
| Text shows garbage after the parent re-renders a `show` / `each` | The element captured a slice that pointed into a stack buffer. Strings in elements must outlive the region (literals, scope-owned data), or use `v.fmt`. |
| Effect never re-runs after `signal.set(...)` | Effects only track signals **read inside the compute closure** during their first run. Make sure `signal.get()` is on the read path, not stashed in a captured local. |
| Memo recomputes every frame | Same: the memo's compute fn must read its inputs via `.get()`. If you accidentally captured a value snapshot, dependency tracking can't see the read. |

### Quarantined tests / known issues

If `zig build test-ui` reports skips, see the [issue tracker](https://github.com/version-next/zenit/issues) for the
list of currently-quarantined tests and their failure modes. None of them
affect the four bundled examples.

If you hit something not listed, please file an issue. Repro snippets are
welcome; the smaller, the better.

### Linux multi-window GPU ownership

`MultiWindowConfig.shared_gpu = true` uses a shared device and image store on macOS
and Windows. Linux Vulkan/OpenGL devices currently bind to one Wayland surface,
so Linux deliberately uses an independent GPU for each window and logs one warning
per application. `App.sharedImageStore()` returns `null` on Linux; load images into
each window's renderer and keep texture ids local to that window.
