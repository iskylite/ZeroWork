/// counter_reactive: showcases zenit's reactive system + `ui.view` declarative view tree
///
/// Minimal declarative example extending hello_button:
///   - Signal + Memo + `ui.view`: declare data flow and UI structure, framework syncs UI.
///
/// Highlights:
///   - `v.text(.., v.fmt("count = {d}", .{count}))`: reactive text, one-liner;
///   - `ui.on.update / ui.on.set`: button events write the signal directly, no Bindings struct;
///   - `ui.css(...)` style objects: unified `TOKENS` reference JSON material, `_hover` in
///     styles;
///   - `S.Badge.of(.{ .even = even })`: reactive variant, fields auto-reset on cancel;
///   - `v.show(...).fallback(...)`: conditional content stays at its declared position.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

const v = ui.view;
const W = ui.widgets;

/// Stylesheet: named style objects (`ui.css`), separate from UI structure.
const S = @import("styles.zig");

fn inc(n: u32) u32 {
    return n + 1;
}

fn isEven(n: u32) bool {
    return n % 2 == 0;
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const count = try scope.createSignal(u32, 0);
    const doubled = try scope.createMemo(u32, .{ .count = count }, struct {
        fn compute(ctx: anytype) u32 {
            return ctx.count.get() * 2;
        }
    }.compute);
    const even = ui.map(count, isEven);

    return v.render(scope, cx, v.col(.{ .style = S.root }, .{
        v.text(.{ .style = S.title }, "Reactive Counter"),
        v.text(.{ .style = S.counterText }, v.fmt("count = {d}", .{count})),
        v.text(.{ .style = S.derivedText }, v.fmt("doubled = {d}", .{doubled})),

        v.row(.{ .style = S.Badge.of(.{ .even = even }) }, .{
            v.show(even, .{v.text(.{ .style = S.badgeText }, "even")})
                .fallback(.{v.text(.{ .style = S.badgeText }, "odd")}),
        }),

        v.row(.{ .style = S.buttonRow }, .{
            W.Button(.{ .label = "+1", .variant = .primary, .on_click = ui.on.update(count, inc) }),
            W.Button(.{ .label = "Reset", .variant = .secondary, .on_click = ui.on.set(count, 0) }),
        }),
    }));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 480, .height = 400, .title = "Reactive Counter" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
