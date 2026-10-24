//! zig_native: pure Zig + native `ui.view` for UI and components (no Yix / YSS).
//!
//! Complete pure-Zig pattern: components in components.zig, styles in styles.zig, UI here.
//! Same runtime as Yix (Yix compiles to these calls); both styles can mix and share components.
//!
//! Highlights:
//!   - Signals and derivation: `scope.createSignalFor` / `ui.map`, text `v.fmt("{d}", .{src})`
//!     follows changes;
//!   - Lists: `v.eachWith(ctx, src, .id, row_fn)` reconciles by key, same-key rows update in place;
//!   - Conditionals: `v.show(src, .{...}).fallback(.{...})`;
//!   - Events: `ui.on.set / update / bind`: change a signal in the handler, UI auto-syncs.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const v = ui.view;
const W = ui.widgets;
const S = @import("styles.zig");
const C = @import("components.zig");

const Task = struct { id: u32, title: []const u8, done: bool };
const max_tasks = 16;
const samples = [_][]const u8{ "Write the release notes", "Review the layout pass", "Profile the text shaper", "Try the Zig-only example" };

const initial = [_]Task{
    .{ .id = 1, .title = "Read docs/VIEW_DSL.md", .done = true },
    .{ .id = 2, .title = "Write a component in Zig", .done = false },
    .{ .id = 3, .title = "Compose it with widgets", .done = false },
};

/// List signal holds own copy: handler builds new array on stack then set
fn toggled(list: []const Task, id: u32, buf: *[max_tasks]Task) []const Task {
    for (list, 0..) |t, i| {
        buf[i] = t;
        if (t.id == id) buf[i].done = !t.done;
    }
    return buf[0..list.len];
}

fn without(list: []const Task, id: u32, buf: *[max_tasks]Task) []const Task {
    var n: usize = 0;
    for (list) |t| if (t.id != id) {
        buf[n] = t;
        n += 1;
    };
    return buf[0..n];
}

fn doneCount(list: []const Task) usize {
    var n: usize = 0;
    for (list) |t| n += @intFromBool(t.done);
    return n;
}

fn doneRatio(list: []const Task) f32 {
    if (list.len == 0) return 0;
    return @as(f32, @floatFromInt(doneCount(list))) / @as(f32, @floatFromInt(list.len));
}

fn isEmpty(list: []const Task) bool {
    return list.len == 0;
}

fn toneOf(level: i32) S.Tone {
    return if (level >= 4) .success else if (level >= 2) .accent else .neutral;
}

const Board = struct { tasks: *ui.Signal([]const Task) };

/// Row function: each row gets subscope; item is data source for this row (updates in place
/// for same key)
fn taskRow(board: Board, item: ui.Source(Task), scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const Row = struct { tasks: *ui.Signal([]const Task), item: ui.Source(Task) };
    const ctx: Row = .{ .tasks = board.tasks, .item = item };
    const toggle = try ui.on.bind(scope, ctx, struct {
        fn run(c: Row) void {
            var buf: [max_tasks]Task = undefined;
            c.tasks.set(toggled(c.tasks.peek(), c.item.peek().id, &buf));
        }
    }.run);
    const remove = try ui.on.bind(scope, ctx, struct {
        fn run(c: Row) void {
            var buf: [max_tasks]Task = undefined;
            c.tasks.set(without(c.tasks.peek(), c.item.peek().id, &buf));
        }
    }.run);
    // Derive parameters from row data: memo tracks item, updates only affected parts when row
    // content changes for same key
    const title = try scope.createMemo([]const u8, .{ .item = item }, struct {
        fn compute(c: anytype) []const u8 {
            return c.item.get().title;
        }
    }.compute);
    const done = try scope.createMemo(bool, .{ .item = item }, struct {
        fn compute(c: anytype) bool {
            return c.item.get().done;
        }
    }.compute);
    return v.render(scope, cx, C.TaskRow(.{ .title = title, .done = done, .on_toggle = toggle, .on_remove = remove }));
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const tasks = try scope.createSignalFor([]const Task, &initial);
    const next_id = try scope.createSignal(u32, initial.len + 1);
    const level = try scope.createSignal(i32, 3);

    const Add = struct { tasks: *ui.Signal([]const Task), next_id: *ui.Signal(u32) };
    const add = try ui.on.bind(scope, Add{ .tasks = tasks, .next_id = next_id }, struct {
        fn run(c: Add) void {
            const list = c.tasks.peek();
            if (list.len == max_tasks) return;
            var buf: [max_tasks]Task = undefined;
            @memcpy(buf[0..list.len], list);
            const id = c.next_id.peek();
            buf[list.len] = .{ .id = id, .title = samples[id % samples.len], .done = false };
            c.tasks.set(buf[0 .. list.len + 1]);
            c.next_id.set(id + 1);
        }
    }.run);

    return v.render(scope, cx, v.col(.{ .style = S.root }, .{
        v.row(.{ .style = S.row }, .{
            v.text(.{ .style = S.title }, "Zig-native components"),
            C.Pill(.{ .label = "no Yix", .tone = .accent }),
            C.Pill(.{ .label = "no YSS", .tone = .accent }),
        }),

        v.with(C.Section(.{ .title = "Tasks" }), .{
            v.eachWith(Board{ .tasks = tasks }, tasks, .id, taskRow),
            v.show(ui.map(tasks, isEmpty), .{v.text(.{ .style = S.caption }, "Nothing left. Add one below.")}),
            v.row(.{ .style = S.row }, .{
                W.Button(.{ .label = "Add task", .variant = .primary, .size = .sm, .on_click = add }),
                v.text(.{ .style = S.caption }, v.fmt("{d} of {d} done", .{ ui.map(tasks, doneCount), ui.map(tasks, listLen) })),
            }),
            v.box(.{ .style = S.progress_track }, .{v.box(.{ .style = v.styleBy(ui.map(tasks, doneRatio), S.progressFill) }, .{})}),
        }),

        v.with(C.Section(.{ .title = "Priority (a controlled value)" }), .{
            v.row(.{ .style = S.row }, .{
                // value bound to level signal: component changes it, outside reads it; tone derived
                // from
                // level
                C.Stepper(.{ .value = level, .max = 5 }),
                v.text(.{ .style = S.caption }, v.fmt("level {d}", .{level})),
                C.Pill(.{ .label = "priority", .tone = ui.map(level, toneOf) }),
                W.Button(.{ .label = "Reset", .variant = .ghost, .size = .sm, .on_click = ui.on.set(level, 0) }),
            }),
        }),
    }));
}

fn listLen(list: []const Task) usize {
    return list.len;
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 560, .height = 560, .title = "Zig-native components" },
    });
    defer app.deinit();
    try app.runWith(mountUI);
}
