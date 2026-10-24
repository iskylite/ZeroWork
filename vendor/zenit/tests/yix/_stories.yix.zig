// GENERATED FILE, do not edit: generated from stories.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const std = @import("std");
const ui = @import("ui");
const Button = ui.widgets.Button;
const W = ui.widgets;
const States = @import("_states.yss.zig");
const Tab = enum { home, settings };
pub const Item = struct { id: u32, title: []const u8 };
const items = [_]Item{ .{ .id = 1, .title = "first" }, .{ .id = 2, .title = "second" } };
pub var batch_updates: usize = 0;
pub var batch_values: [8]i32 = @splat(-1);
fn observeBatch(value: i32) i32 {
    batch_values[batch_updates] = value;
    batch_updates += 1;
    return value;
}

// M0 samples corresponding to storybook: layout, button, card, controlled
// visibility, tabs, keyed rows, and a component receiving reactive props.
pub fn Layout(args: anytype) ui.view.ComponentOf(__yix_Layout) {
    return ui.view.component(__yix_Layout, ui.reactive.props.coerce(LayoutProps, args));
}
pub const LayoutProps = struct {
};
fn __yix_Layout(__yix_props: LayoutProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = .{ .gap = .space200 }, }, .{
            ui.view.templateAttrs(.{ .parts = .{ .content = .{ .style = ui.css(.{ .gap = 21 }) } }, }, ui.view.with(W.ScrollArea(.{ }), .{
                ui.view.text(.{ }, ui.view.fmt("Before", .{ })),
            })),
            ui.view.spacer(),
            ui.view.text(.{ }, ui.view.fmt("After", .{ })),
        }));
    __yix_root.meta.ownership.meta.component_name = "Layout";
    return __yix_root;

}
pub fn ButtonStory(args: anytype) ui.view.ComponentOf(__yix_ButtonStory) {
    return ui.view.component(__yix_ButtonStory, ui.reactive.props.coerce(ButtonStoryProps, args));
}
pub const ButtonStoryProps = struct {
};
fn __yix_ButtonStory(__yix_props: ButtonStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const count = try scope.createSignalFor(i32, 0);
    const double = __yix_d1: {
        const __yix_T = @TypeOf(count.peek() * 2);
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .count = count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.count.get() * 2;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("Count " ++ ui.view.yixFormat(@TypeOf(count), "") ++ "; double " ++ ui.view.yixFormat(@TypeOf(double), ""), .{ count, double, })),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .count = count, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run)), }, "Increment", .{
                ui.view.text(.{}, ui.view.fmt("Increment", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "ButtonStory";
    return __yix_root;

}
pub fn CardStory(args: anytype) ui.view.ComponentOf(__yix_CardStory) {
    return ui.view.component(__yix_CardStory, ui.reactive.props.coerce(CardStoryProps, args));
}
pub const CardStoryProps = struct {
};
fn __yix_CardStory(__yix_props: CardStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.templateAttrs(.{ .style = ui.css(.{ .opacity = 0.5 }), }, ui.view.with(ui.widgets.Card(.{ }), .{
            ui.view.text(.{ }, ui.view.fmt("Card body", .{ })),
        })));
    __yix_root.meta.ownership.meta.component_name = "CardStory";
    return __yix_root;

}
pub fn BranchStory(args: anytype) ui.view.ComponentOf(__yix_BranchStory) {
    return ui.view.component(__yix_BranchStory, ui.reactive.props.coerce(BranchStoryProps, args));
}
pub const BranchStoryProps = struct {
};
fn __yix_BranchStory(__yix_props: BranchStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const expanded = try scope.createSignalFor(bool, false);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .expanded = expanded, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.expanded.set(!__yix_ctx.expanded.peek());  } }.__yix_run)), }, "Toggle", .{
                ui.view.text(.{}, ui.view.fmt("Toggle", .{ })),
            }),
            ui.view.lazyIf(expanded, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("Expanded", .{ })) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ }, ui.view.fmt("Collapsed", .{ })) }); } }.__yix_b),
        }));
    __yix_root.meta.ownership.meta.component_name = "BranchStory";
    return __yix_root;

}
pub fn TabsStory(args: anytype) ui.view.ComponentOf(__yix_TabsStory) {
    return ui.view.component(__yix_TabsStory, ui.reactive.props.coerce(TabsStoryProps, args));
}
pub const TabsStoryProps = struct {
};
fn __yix_TabsStory(__yix_props: TabsStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const tab = try scope.createSignalFor(Tab, .home);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .tab = tab, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.tab.set(.settings);  } }.__yix_run)), }, "Settings", .{
                ui.view.text(.{}, ui.view.fmt("Settings", .{ })),
            }),
            ui.view.lazySwitch(tab, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bt1_0: anytype, __yix_bv1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; _ = __yix_bv1_0; switch (__yix_bt1_0) { .home => { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("Home", .{ })) }); }, .settings => { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("Settings body", .{ })) }); }, } } }.__yix_b),
        }));
    __yix_root.meta.ownership.meta.component_name = "TabsStory";
    return __yix_root;

}
pub fn ListStory(args: anytype) ui.view.ComponentOf(__yix_ListStory) {
    return ui.view.component(__yix_ListStory, ui.reactive.props.coerce(ListStoryProps, args));
}
pub const ListStoryProps = struct {
};
fn __yix_ListStory(__yix_props: ListStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazyIf(__yix_d2: {
        const __yix_T = @TypeOf(rows.peek().len != 0);
        break :__yix_d2 try scope.createMemo(__yix_T, .{ .rows = rows, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.rows.get().len != 0;
        } }.__yix_compute);
    }, .{ .rows = rows, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ __yix_e1: { const __yix_items_1 = __yix_b1_0.rows; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, }))); } }.__yix_row); } }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ }, ui.view.fmt("Empty", .{ })) }); } }.__yix_b),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .rows = rows, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.rows.set(&.{});  } }.__yix_run)), }, "Clear", .{
                ui.view.text(.{}, ui.view.fmt("Clear", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "ListStory";
    return __yix_root;

}
/// Local variable shares name with generated function (b / row / k / run / compute): branch/row
/// references cannot corrupt generated function names.
pub fn GeneratedNameStory(args: anytype) ui.view.ComponentOf(__yix_GeneratedNameStory) {
    return ui.view.component(__yix_GeneratedNameStory, ui.reactive.props.coerce(GeneratedNameStoryProps, args));
}
pub const GeneratedNameStoryProps = struct {
};
fn __yix_GeneratedNameStory(__yix_props: GeneratedNameStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const b = try scope.createSignalFor(i32, 1);
    const row = try scope.createSignalFor(i32, 2);
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(b.peek() > 0);
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .b = b, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.b.get() > 0;
        } }.__yix_compute);
    }, .{ .b = b, .row = row, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("b=" ++ ui.view.yixFormat(@TypeOf(__yix_b1_0.b), "") ++ " row=" ++ ui.view.yixFormat(@TypeOf(__yix_b1_0.row), ""), .{ __yix_b1_0.b, __yix_b1_0.row, })) }); } }.__yix_b, null),
            __yix_e2: { const __yix_items_2 = rows; break :__yix_e2 ui.view.eachWith(.{ .b = b, .row = row, }, __yix_items_2, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_2))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), "") ++ ui.view.yixFormat(@TypeOf(__yix_row_1.b), "") ++ ui.view.yixFormat(@TypeOf(__yix_row_1.row), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, __yix_row_1.b, __yix_row_1.row, }))); } }.__yix_row); },
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .b = b, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.b.set(__yix_ctx.b.peek() + (1));  } }.__yix_run)), }, "bump", .{
                ui.view.text(.{}, ui.view.fmt("bump", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "GeneratedNameStory";
    return __yix_root;

}
/// Controlled (read-only): list row fields drive Checkbox; click only fires onChange, parent
/// updates data.
pub const Task = struct { id: u32, title: []const u8, done: bool };
const tasks0 = [_]Task{ .{ .id = 1, .title = "a", .done = false }, .{ .id = 2, .title = "b", .done = true } };
pub var task_store: [2]Task = tasks0;
pub var toggles: usize = 0;
fn toggleTask(id: u32) []const Task {
    toggles += 1;
    for (&task_store) |*t| if (t.id == id) { t.done = !t.done; };
    return &task_store;
}
pub fn ControlledStory(args: anytype) ui.view.ComponentOf(__yix_ControlledStory) {
    return ui.view.component(__yix_ControlledStory, ui.reactive.props.coerce(ControlledStoryProps, args));
}
pub const ControlledStoryProps = struct {
};
fn __yix_ControlledStory(__yix_props: ControlledStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const list = try scope.createSignalFor([]const Task, &task_store);
    const frozen = try scope.createSignalFor(bool, false);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            __yix_e1: { const __yix_items_1 = list; break :__yix_e1 ui.view.eachWith(.{ .list = list, .frozen = frozen, }, __yix_items_1, struct { fn __yix_k(task: ui.view.yixItem(@TypeOf(__yix_items_1))) u64 { return ui.view.keyOf(task.id); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, task: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, W.Checkbox(.{ .label = __yix_d1: {
        const __yix_T = if (ui.view.attrType(W.Checkbox, "label")) |__yix_A| __yix_A else @TypeOf(task.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .task = task, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.task.get().title;
        } }.__yix_compute);
    }, .checked = __yix_d2: {
        const __yix_T = if (ui.view.attrType(W.Checkbox, "checked")) |__yix_A| __yix_A else @TypeOf(task.peek().done);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .task = task, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.task.get().done;
        } }.__yix_compute);
    }, .on_change = ui.view.eventProp(W.Checkbox, "on_change", try ui.on.bindAny(__yix_scope_1, .{ .frozen = __yix_row_1.frozen, .list = __yix_row_1.list, .task = task, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.frozen.peek()) { __yix_ctx.list.set(toggleTask(__yix_ctx.task.peek().id)); }  } }.__yix_run)), })); } }.__yix_row); },
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .frozen = frozen, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.frozen.set(!__yix_ctx.frozen.peek());  } }.__yix_run)), }, "freeze", .{
                ui.view.text(.{}, ui.view.fmt("freeze", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "ControlledStory";
    return __yix_root;

}
/// Typed events on component element: installed in component root's capture slot, fire before
/// component's own handlers; consume blocks component default behavior.
pub fn ComponentKeys(args: anytype) ui.view.ComponentOf(__yix_ComponentKeys) {
    return ui.view.component(__yix_ComponentKeys, ui.reactive.props.coerce(ComponentKeysProps, args));
}
pub const ComponentKeysProps = struct {
};
fn __yix_ComponentKeys(__yix_props: ComponentKeysProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const text = try scope.createSignalFor([]const u8, "ab");
    const keys = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.templateAttrs(.{ .test_id = "field", .on_key_down = try ui.on.bindAny(scope, .{ .keys = keys, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, e: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (e.key == .delete and __yix_ctx.keys.peek() == 0) { __yix_ctx.keys.set(__yix_ctx.keys.peek() + (1)); e.consume(); } else { __yix_ctx.keys.set(__yix_ctx.keys.peek() + (10)); }  } }.__yix_run), }, W.Input(.{ .value = text, })),
            ui.view.text(.{ }, ui.view.fmt("keys " ++ ui.view.yixFormat(@TypeOf(keys), "") ++ " text " ++ ui.view.yixFormat(@TypeOf(text), ""), .{ keys, text, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "ComponentKeys";
    return __yix_root;

}
/// Component root's typed events toggle mount/unmount across branches (table freed with component
/// scope, no dangling pointers).
pub fn ToggledKeys(args: anytype) ui.view.ComponentOf(__yix_ToggledKeys) {
    return ui.view.component(__yix_ToggledKeys, ui.reactive.props.coerce(ToggledKeysProps, args));
}
pub const ToggledKeysProps = struct {
};
fn __yix_ToggledKeys(__yix_props: ToggledKeysProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const show = try scope.createSignalFor(bool, true);
    const keys = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazyIf(show, .{ .keys = keys, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateAttrs(.{ .test_id = "tfield", .on_key_down = try ui.on.bindAny(__yix_bs1_0, .{ .keys = __yix_b1_0.keys, .__yix_owner = __yix_bs1_0.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.keys.set(__yix_ctx.keys.peek() + (1));  } }.__yix_run), }, W.Input(.{ })) }); } }.__yix_b, null),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .show = show, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.show.set(!__yix_ctx.show.peek());  } }.__yix_run)), }, "toggle", .{
                ui.view.text(.{}, ui.view.fmt("toggle", .{ })),
            }),
            ui.view.text(.{ }, ui.view.fmt("tk " ++ ui.view.yixFormat(@TypeOf(keys), ""), .{ keys, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "ToggledKeys";
    return __yix_root;

}
/// Controlled rewrite: read-only value + onChange normalized by props into split; Input corrects
/// buffer in-place per rewritten value.
var upper_buf: [64]u8 = undefined;
fn upper(v: []const u8) []const u8 {
    const n = @min(v.len, upper_buf.len);
    for (v[0..n], 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);
    return upper_buf[0..n];
}
pub fn UpperInput(args: anytype) ui.view.ComponentOf(__yix_UpperInput) {
    return ui.view.component(__yix_UpperInput, ui.reactive.props.coerce(UpperInputProps, args));
}
pub const UpperInputProps = struct {
};
fn __yix_UpperInput(__yix_props: UpperInputProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const code = try scope.createSignalFor([]const u8, "AB");
    const shown = __yix_d1: {
        const __yix_T = @TypeOf(code.peek());
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .code = code, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.code.get();
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.templateAttrs(.{ .test_id = "up", }, W.Input(.{ .value = shown, .on_change = ui.view.eventProp(W.Input, "on_change", try ui.on.bindAny(scope, .{ .code = code, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, v: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.code.set(upper(v));  } }.__yix_run)), })),
            ui.view.text(.{ }, ui.view.fmt("code " ++ ui.view.yixFormat(@TypeOf(code), ""), .{ code, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "UpperInput";
    return __yix_root;

}
/// Component property branch expressions typed by property type: enum literals, unequal-length
/// string literals, `[]const u8` in type.
pub fn TypedAttrStory(args: anytype) ui.view.ComponentOf(__yix_TypedAttrStory) {
    return ui.view.component(__yix_TypedAttrStory, ui.reactive.props.coerce(TypedAttrStoryProps, args));
}
pub const TypedAttrStoryProps = struct {
};
fn __yix_TypedAttrStory(__yix_props: TypedAttrStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const on = try scope.createSignalFor(bool, false);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            Button(.{ .variant = __yix_d1: {
        const __yix_T = if (ui.view.attrType(Button, "variant")) |__yix_A| __yix_A else @TypeOf(if (on.peek()) .primary else .ghost);
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .on = on, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.on.get()) .primary else .ghost;
        } }.__yix_compute);
    }, .label = __yix_d2: {
        const __yix_T = if (ui.view.attrType(Button, "label")) |__yix_A| __yix_A else @TypeOf(if (on.peek()) "done" else "todo");
        break :__yix_d2 try scope.createMemo(__yix_T, .{ .on = on, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.on.get()) "done" else "todo";
        } }.__yix_compute);
    }, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .on = on, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.on.set(!__yix_ctx.on.peek());  } }.__yix_run)), }),
            Button(.{ .label = __yix_d3: {
        const __yix_T = if (ui.view.attrType(Button, "label")) |__yix_A| __yix_A else @TypeOf(if (on.peek()) @as([]const u8, "yes") else "no");
        break :__yix_d3 try scope.createMemo(__yix_T, .{ .on = on, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.on.get()) @as([]const u8, "yes") else "no";
        } }.__yix_compute);
    }, }),
        }));
    __yix_root.meta.ownership.meta.component_name = "TypedAttrStory";
    return __yix_root;

}
pub fn Label(args: anytype) ui.view.ComponentOf(__yix_Label) {
    return ui.view.component(__yix_Label, ui.reactive.props.coerce(LabelProps, args));
}
pub const LabelProps = struct {
    count: ui.Source(i32) = .{ .value = 0 },
};
fn __yix_Label(__yix_props: LabelProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const count = __yix_props.count;
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt("Prop " ++ ui.view.yixFormat(@TypeOf(count), ""), .{ count, })));
    __yix_root.meta.ownership.meta.component_name = "Label";
    return __yix_root;

}
pub fn PropsStory(args: anytype) ui.view.ComponentOf(__yix_PropsStory) {
    return ui.view.component(__yix_PropsStory, ui.reactive.props.coerce(PropsStoryProps, args));
}
pub const PropsStoryProps = struct {
};
fn __yix_PropsStory(__yix_props: PropsStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const count = try scope.createSignalFor(i32, 3);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            Label(.{ .count = count, }),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .count = count, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run)), }, "Increment prop", .{
                ui.view.text(.{}, ui.view.fmt("Increment prop", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "PropsStory";
    return __yix_root;

}
pub fn BatchStory(args: anytype) ui.view.ComponentOf(__yix_BatchStory) {
    return ui.view.component(__yix_BatchStory, ui.reactive.props.coerce(BatchStoryProps, args));
}
pub const BatchStoryProps = struct {
};
fn __yix_BatchStory(__yix_props: BatchStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const a = try scope.createSignalFor(i32, 0);
    const b = try scope.createSignalFor(i32, 0);
    const total = __yix_d1: {
        const __yix_T = @TypeOf(observeBatch(a.peek() + b.peek()));
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .a = a, .b = b, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return observeBatch(__yix_ctx.a.get() + __yix_ctx.b.get());
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(total), ""), .{ total, })),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .a = a, .b = b, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.a.set(__yix_ctx.a.peek() + (1)); __yix_ctx.b.set(__yix_ctx.b.peek() + (2));  } }.__yix_run)), }, "Batch", .{
                ui.view.text(.{}, ui.view.fmt("Batch", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "BatchStory";
    return __yix_root;

}
pub fn UnicodeStory(args: anytype) ui.view.ComponentOf(__yix_UnicodeStory) {
    return ui.view.component(__yix_UnicodeStory, ui.reactive.props.coerce(UnicodeStoryProps, args));
}
pub const UnicodeStoryProps = struct {
};
fn __yix_UnicodeStory(__yix_props: UnicodeStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const show = try scope.createSignalFor(bool, true);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazyIf(show, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("中文 😀", .{ })) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ }, ui.view.fmt("空", .{ })) }); } }.__yix_b),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .show = show, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.show.set(false);  } }.__yix_run)), }, "隐藏", .{
                ui.view.text(.{}, ui.view.fmt("隐藏", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "UnicodeStory";
    return __yix_root;

}
pub fn RowCaptureStory(args: anytype) ui.view.ComponentOf(__yix_RowCaptureStory) {
    return ui.view.component(__yix_RowCaptureStory, ui.reactive.props.coerce(RowCaptureStoryProps, args));
}
pub const RowCaptureStoryProps = struct {
};
fn __yix_RowCaptureStory(__yix_props: RowCaptureStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const rows = try scope.createSignalFor([]const Item, &items);
    const selected = try scope.createSignalFor(u32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("Selected " ++ ui.view.yixFormat(@TypeOf(selected), ""), .{ selected, })),
            __yix_e1: { const __yix_items_1 = rows; break :__yix_e1 ui.view.eachWith(.{ .selected = selected, }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.row(.{ }, .{
                    ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), "") ++ ": " ++ ui.view.yixFormat(@TypeOf(__yix_row_1.selected), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, __yix_row_1.selected, })),
                    Button(.{ .label = __yix_d2: {
        const __yix_T = if (ui.view.attrType(Button, "label")) |__yix_A| __yix_A else @TypeOf(item.peek().title);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_scope_1, .{ .selected = __yix_row_1.selected, .item = item, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.selected.set(__yix_ctx.item.peek().id);  } }.__yix_run)), }),
                })); } }.__yix_row); },
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .rows = rows, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.rows.set(&.{ items[1], items[0] });  } }.__yix_run)), }, "Reverse", .{
                ui.view.text(.{}, ui.view.fmt("Reverse", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "RowCaptureStory";
    return __yix_root;

}

pub fn TextSignalStory(args: anytype) ui.view.ComponentOf(__yix_TextSignalStory) {
    return ui.view.component(__yix_TextSignalStory, ui.reactive.props.coerce(TextSignalStoryProps, args));
}
pub const TextSignalStoryProps = struct {
};
fn __yix_TextSignalStory(__yix_props: TextSignalStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const message = try scope.createSignalFor([]const u8, "before");
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(message), ""), .{ message, })),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .message = message, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.message.set("after");  } }.__yix_run)), }, "Change text", .{
                ui.view.text(.{}, ui.view.fmt("Change text", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "TextSignalStory";
    return __yix_root;

}

pub fn Doubled(args: anytype) ui.view.ComponentOf(__yix_Doubled) {
    return ui.view.component(__yix_Doubled, ui.reactive.props.coerce(DoubledProps, args));
}
pub const DoubledProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
};
fn __yix_Doubled(__yix_props: DoubledProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    const d = __yix_d1: {
        const __yix_T = @TypeOf(n.peek() * 2);
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() * 2;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt("double " ++ ui.view.yixFormat(@TypeOf(d), ""), .{ d, })));
    __yix_root.meta.ownership.meta.component_name = "Doubled";
    return __yix_root;

}

pub fn Panel(args: anytype) ui.view.SlottedOf(__yix_Panel) {
    return ui.view.slotted(__yix_Panel, ui.reactive.props.coerce(PanelProps, args));
}
pub const PanelProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
};
fn __yix_Panel(__yix_props: PanelProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const title = __yix_props.title;
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(title), ""), .{ title, })),
            ui.view.slotEnd(&__yix_slot_children, ui.view.col(.{ }, .{ })),
        }));
    __yix_root.meta.ownership.meta.component_name = "Panel";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ });

}
pub fn PanelUse(args: anytype) ui.view.ComponentOf(__yix_PanelUse) {
    return ui.view.component(__yix_PanelUse, ui.reactive.props.coerce(PanelUseProps, args));
}
pub const PanelUseProps = struct {
};
fn __yix_PanelUse(__yix_props: PanelUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const n = try scope.createSignalFor(i32, 1);
    const __yix_root = try ui.view.render(scope, cx, ui.view.with(Panel(.{ .title = "Settings", }), .{
            ui.view.text(.{ }, ui.view.fmt("value " ++ ui.view.yixFormat(@TypeOf(n), ""), .{ n, })),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), }, "More", .{
                ui.view.text(.{}, ui.view.fmt("More", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "PanelUse";
    return __yix_root;

}

pub fn Closable(args: anytype) ui.view.ComponentOf(__yix_Closable) {
    return ui.view.component(__yix_Closable, ui.reactive.props.coerce(ClosableProps, args));
}
pub const ClosableProps = struct {
    label: ui.Source([]const u8) = .{ .value = "" },
    on_close: ?ui.Handler(void) = null,
};
fn __yix_Closable(__yix_props: ClosableProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const onClose = __yix_props.on_close;
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(label), ""), .{ label, })),
            Button(.{ .label = "x", .on_click = if (comptime ui.view.isEventProp(Button, "on_click")) onClose else onClose, }),
        }));
    __yix_root.meta.ownership.meta.component_name = "Closable";
    return __yix_root;

}
pub fn ClosableUse(args: anytype) ui.view.ComponentOf(__yix_ClosableUse) {
    return ui.view.component(__yix_ClosableUse, ui.reactive.props.coerce(ClosableUseProps, args));
}
pub const ClosableUseProps = struct {
};
fn __yix_ClosableUse(__yix_props: ClosableUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const closed = try scope.createSignalFor(bool, false);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            Closable(.{ .label = "tab", .on_close = ui.view.eventProp(Closable, "on_close", try ui.on.bindAny(scope, .{ .closed = closed, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.closed.set(true);  } }.__yix_run)), }),
            ui.view.lazyIf(closed, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("closed", .{ })) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ }, ui.view.fmt("open", .{ })) }); } }.__yix_b),
        }));
    __yix_root.meta.ownership.meta.component_name = "ClosableUse";
    return __yix_root;

}

pub fn Stars(args: anytype) ui.view.ComponentOf(__yix_Stars) {
    return ui.view.component(__yix_Stars, ui.reactive.props.coerce(StarsProps, args));
}
pub const StarsProps = struct {
    total: ui.Source(usize) = .{ .value = 5 },
};
fn __yix_Stars(__yix_props: StarsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const lit = try scope.createSignalFor(usize, 2);
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ }, .{
            ui.view.repeat(.{ .lit = lit, }, @as(usize, 5), struct { fn __yix_row(__yix_row_1: anytype, i: usize, __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(i), "") ++ "/" ++ ui.view.yixFormat(@TypeOf(__yix_row_1.lit), ""), .{ i, __yix_row_1.lit, }))); } }.__yix_row),
            ui.view.repeat(.{ }, @as(usize, 3), struct { fn __yix_row(__yix_row_1: anytype, _: usize, __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.spacer()); } }.__yix_row),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .lit = lit, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.lit.set(__yix_ctx.lit.peek() + (1));  } }.__yix_run)), }, "More", .{
                ui.view.text(.{}, ui.view.fmt("More", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "Stars";
    return __yix_root;

}

pub fn GrowingStars(args: anytype) ui.view.ComponentOf(__yix_GrowingStars) {
    return ui.view.component(__yix_GrowingStars, ui.reactive.props.coerce(GrowingStarsProps, args));
}
pub const GrowingStarsProps = struct {
    total: ui.Source(usize) = .{ .value = 2 },
};
fn __yix_GrowingStars(__yix_props: GrowingStarsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const total = __yix_props.total;
    const extra = try scope.createSignalFor(usize, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ }, .{
            ui.view.repeat(.{ }, __yix_d1: {
        const __yix_T = @TypeOf(total.peek() + extra.peek());
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .total = total, .extra = extra, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.total.get() + __yix_ctx.extra.get();
        } }.__yix_compute);
    }, struct { fn __yix_row(__yix_row_1: anytype, i: usize, __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.text(.{ }, ui.view.fmt("star " ++ ui.view.yixFormat(@TypeOf(i), ""), .{ i, }))); } }.__yix_row),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .extra = extra, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.extra.set(__yix_ctx.extra.peek() + (1));  } }.__yix_run)), }, "Add", .{
                ui.view.text(.{}, ui.view.fmt("Add", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "GrowingStars";
    return __yix_root;

}

pub fn Forward(args: anytype) ui.view.ComponentOf(__yix_Forward) {
    return ui.view.component(__yix_Forward, ui.reactive.props.coerce(ForwardProps, args));
}
pub const ForwardProps = struct {
    disabled: ui.Source(bool) = .{ .value = false },
    on_press: ?ui.Handler(void) = null,
    on_pick: ?ui.Handler(i32) = null,
};
fn __yix_Forward(__yix_props: ForwardProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const disabled = __yix_props.disabled;
    const onPress = __yix_props.on_press;
    const onPick = __yix_props.on_pick;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.textChild(Button, .{ .on_click = if (comptime ui.view.isEventProp(Button, "on_click")) try ui.on.bindAny(scope, .{ .disabled = disabled, .onPress = onPress, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek()) { ui.on.fire(__yix_ctx.onPress, .{}); }  } }.__yix_run) else __yix_d1: {
        const __yix_T = if (ui.view.attrType(Button, "on_click")) |__yix_A| __yix_A else @TypeOf(if (!disabled.peek()) onPress);
        break :__yix_d1 try scope.derive(__yix_T, .{ .disabled = disabled, .onPress = onPress, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (!__yix_ctx.disabled.get()) __yix_ctx.onPress;
        } }.__yix_compute);
    }, }, "Go", .{
                ui.view.text(.{}, ui.view.fmt("Go", .{ })),
            }),
            ui.view.textChild(Button, .{ .on_click = if (comptime ui.view.isEventProp(Button, "on_click")) try ui.on.bindAny(scope, .{ .onPick = onPick, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); ui.on.fire(__yix_ctx.onPick, .{7});  } }.__yix_run) else __yix_call3: {
        const __yix_Raw = @TypeOf(onPick(7));
        break :__yix_call3 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) onPick(7) else __yix_d2: {
        const __yix_T = if (ui.view.attrType(Button, "on_click")) |__yix_A| __yix_A else @TypeOf(onPick(7));
        break :__yix_d2 try scope.derive(__yix_T, .{ .onPick = onPick, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.onPick(7);
        } }.__yix_compute);
    };
    }, }, "Seven", .{
                ui.view.text(.{}, ui.view.fmt("Seven", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "Forward";
    return __yix_root;

}

pub fn ForwardUse(args: anytype) ui.view.ComponentOf(__yix_ForwardUse) {
    return ui.view.component(__yix_ForwardUse, ui.reactive.props.coerce(ForwardUseProps, args));
}
pub const ForwardUseProps = struct {
};
fn __yix_ForwardUse(__yix_props: ForwardUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const n = try scope.createSignalFor(i32, 0);
    const off = try scope.createSignalFor(bool, false);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            Forward(.{ .disabled = off, .on_press = ui.view.eventProp(Forward, "on_press", try ui.on.bindAny(scope, .{ .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), .on_pick = ui.view.eventProp(Forward, "on_pick", try ui.on.bindAny(scope, .{ .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, v: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(v);  } }.__yix_run)), }),
            ui.view.text(.{ }, ui.view.fmt("presses " ++ ui.view.yixFormat(@TypeOf(n), ""), .{ n, })),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .off = off, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.off.set(!__yix_ctx.off.peek());  } }.__yix_run)), }, "Lock", .{
                ui.view.text(.{}, ui.view.fmt("Lock", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "ForwardUse";
    return __yix_root;

}

pub fn Numbered(args: anytype) ui.view.ComponentOf(__yix_Numbered) {
    return ui.view.component(__yix_Numbered, ui.reactive.props.coerce(NumberedProps, args));
}
pub const NumberedProps = struct {
};
fn __yix_Numbered(__yix_props: NumberedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            __yix_e1: { const __yix_items_1 = rows; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(i), "") ++ ". " ++ ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ i, __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, }))); } }.__yix_row); },
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .rows = rows, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.rows.set(&.{ items[1], items[0] });  } }.__yix_run)), }, "Reverse", .{
                ui.view.text(.{}, ui.view.fmt("Reverse", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "Numbered";
    return __yix_root;

}

pub fn NestedFlow(args: anytype) ui.view.ComponentOf(__yix_NestedFlow) {
    return ui.view.component(__yix_NestedFlow, ui.reactive.props.coerce(NestedFlowProps, args));
}
pub const NestedFlowProps = struct {
};
fn __yix_NestedFlow(__yix_props: NestedFlowProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const shown = try scope.createSignalFor(bool, true);
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazyIf(shown, .{ .rows = rows, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ __yix_e2: { const __yix_items_2 = __yix_b1_0.rows; break :__yix_e2 ui.view.eachWith(.{ }, __yix_items_2, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_2))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.text(.{ }, ui.view.fmt("row " ++ ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, }))); } }.__yix_row); } }); } }.__yix_b, null),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .shown = shown, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shown.set(!__yix_ctx.shown.peek());  } }.__yix_run)), }, "Hide", .{
                ui.view.text(.{}, ui.view.fmt("Hide", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "NestedFlow";
    return __yix_root;

}

pub fn Toggle(args: anytype) ui.view.ComponentOf(__yix_Toggle) {
    return ui.view.component(__yix_Toggle, ui.reactive.props.coerce(ToggleProps, args));
}
pub const ToggleProps = struct {
    on: ui.Model(bool) = .{ .local = false },
    on_change: ?ui.Handler(bool) = null,
};
fn __yix_Toggle(__yix_props: ToggleProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const onChange = __yix_props.on_change;
    const __yix_model_on = try ui.reactive.resolveModelFor(bool, scope, __yix_props.on);
    const on = __yix_model_on.read;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazyIf(on, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("on", .{ })) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ }, ui.view.fmt("off", .{ })) }); } }.__yix_b),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .on = on, .__yix_model_on = __yix_model_on, .onChange = onChange, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.__yix_model_on.propose(!__yix_ctx.on.peek(), __yix_ctx.onChange);  } }.__yix_run)), }, "Flip", .{
                ui.view.text(.{}, ui.view.fmt("Flip", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "Toggle";
    return __yix_root;

}
pub fn ToggleBound(args: anytype) ui.view.ComponentOf(__yix_ToggleBound) {
    return ui.view.component(__yix_ToggleBound, ui.reactive.props.coerce(ToggleBoundProps, args));
}
pub const ToggleBoundProps = struct {
};
fn __yix_ToggleBound(__yix_props: ToggleBoundProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const flag = try scope.createSignalFor(bool, true);
    const changes = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("flag " ++ ui.view.yixFormat(@TypeOf(flag), "") ++ " changes " ++ ui.view.yixFormat(@TypeOf(changes), ""), .{ flag, changes, })),
            Toggle(.{ .on = flag, .on_change = ui.view.eventProp(Toggle, "on_change", try ui.on.bindAny(scope, .{ .changes = changes, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.changes.set(__yix_ctx.changes.peek() + (1));  } }.__yix_run)), }),
        }));
    __yix_root.meta.ownership.meta.component_name = "ToggleBound";
    return __yix_root;

}
pub fn ToggleEcho(args: anytype) ui.view.ComponentOf(__yix_ToggleEcho) {
    return ui.view.component(__yix_ToggleEcho, ui.reactive.props.coerce(ToggleEchoProps, args));
}
pub const ToggleEchoProps = struct {
};
fn __yix_ToggleEcho(__yix_props: ToggleEchoProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const last = try scope.createSignalFor(bool, false);
    const count = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("last " ++ ui.view.yixFormat(@TypeOf(last), "") ++ " count " ++ ui.view.yixFormat(@TypeOf(count), ""), .{ last, count, })),
            Toggle(.{ .on_change = ui.view.eventProp(Toggle, "on_change", try ui.on.bindAny(scope, .{ .last = last, .count = count, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, v: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.last.set(v); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run)), }),
        }));
    __yix_root.meta.ownership.meta.component_name = "ToggleEcho";
    return __yix_root;

}
pub fn Guarded(args: anytype) ui.view.ComponentOf(__yix_Guarded) {
    return ui.view.component(__yix_Guarded, ui.reactive.props.coerce(GuardedProps, args));
}
pub const GuardedProps = struct {
    locked: ui.Source(bool) = .{ .value = false },
};
fn __yix_Guarded(__yix_props: GuardedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const locked = __yix_props.locked;
    const n = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("n " ++ ui.view.yixFormat(@TypeOf(n), ""), .{ n, })),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .locked = locked, .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.locked.peek()) { __yix_ctx.n.set(__yix_ctx.n.peek() + (1)); if (__yix_ctx.n.peek() > 2) { __yix_ctx.n.set(0); } } else { __yix_ctx.n.set(-1); }  } }.__yix_run)), }, "Step", .{
                ui.view.text(.{}, ui.view.fmt("Step", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "Guarded";
    return __yix_root;

}
pub fn EventForms(args: anytype) ui.view.ComponentOf(__yix_EventForms) {
    return ui.view.component(__yix_EventForms, ui.reactive.props.coerce(EventFormsProps, args));
}
pub const EventFormsProps = struct {
};
fn __yix_EventForms(__yix_props: EventFormsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const a = try scope.createSignalFor(i32, 0);
    const b = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("a " ++ ui.view.yixFormat(@TypeOf(a), "") ++ " b " ++ ui.view.yixFormat(@TypeOf(b), ""), .{ a, b, })),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .a = a, .b = b, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (__yix_ctx.a.peek() == 0) { __yix_ctx.a.set(1); } else { __yix_ctx.a.set(2); } __yix_ctx.b.set(if (__yix_ctx.a.peek() > 1) 10 else 20);  } }.__yix_run)), }, "Go", .{
                ui.view.text(.{}, ui.view.fmt("Go", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "EventForms";
    return __yix_root;

}
pub fn FieldNamedLikeProp(args: anytype) ui.view.ComponentOf(__yix_FieldNamedLikeProp) {
    return ui.view.component(__yix_FieldNamedLikeProp, ui.reactive.props.coerce(FieldNamedLikePropProps, args));
}
pub const FieldNamedLikePropProps = struct {
    title: ui.Source([]const u8) = .{ .value = "prop" },
};
fn __yix_FieldNamedLikeProp(__yix_props: FieldNamedLikePropProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = __yix_props.title;
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(title), ""), .{ title, })),
            __yix_e1: { const __yix_items_1 = rows; break :__yix_e1 ui.view.eachWith(.{ .title = title, }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), "") ++ "-" ++ ui.view.yixFormat(@TypeOf(__yix_row_1.title), "") ++ " " ++ ui.view.yixFormat(@TypeOf(__yix_d2: {
        const __yix_T = @TypeOf(item.peek().title.len + __yix_row_1.title.peek().len);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .item = item, .title = __yix_row_1.title, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title.len + __yix_ctx.title.get().len;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, __yix_row_1.title, __yix_d2: {
        const __yix_T = @TypeOf(item.peek().title.len + __yix_row_1.title.peek().len);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .item = item, .title = __yix_row_1.title, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title.len + __yix_ctx.title.get().len;
        } }.__yix_compute);
    }, }))); } }.__yix_row); },
        }));
    __yix_root.meta.ownership.meta.component_name = "FieldNamedLikeProp";
    return __yix_root;

}
const Choice = struct { value: []const u8, label: []const u8 };
const choices = [_]Choice{ .{ .value = "a", .label = "Apple" }, .{ .value = "b", .label = "Banana" } };
fn isPicked(value: ?[]const u8, v: []const u8) bool {
    return if (value) |x| std.mem.eql(u8, x, v) else false;
}
pub fn Picker(args: anytype) ui.view.ComponentOf(__yix_Picker) {
    return ui.view.component(__yix_Picker, ui.reactive.props.coerce(PickerProps, args));
}
pub const PickerProps = struct {
    options: ui.Source([]const Choice) = .{ .value = &choices },
    value: ui.Model(?[]const u8) = .{ .local = null },
    on_change: ?ui.Handler([]const u8) = null,
};
fn __yix_Picker(__yix_props: PickerProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const options = __yix_props.options;
    const onChange = __yix_props.on_change;
    const __yix_model_value = try ui.reactive.resolveModelFor(?[]const u8, scope, __yix_props.value);
    const value = __yix_model_value.read;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            __yix_e1: { const __yix_items_1 = options; break :__yix_e1 ui.view.eachWith(.{ .value = value, .onChange = onChange, .__yix_model_value = __yix_model_value, }, __yix_items_1, struct { fn __yix_k(opt: ui.view.yixItem(@TypeOf(__yix_items_1))) u64 { return ui.view.keyOf(opt.value); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, opt: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.row(.{ }, .{
                    ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(opt.peek().label);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.opt.get().label;
        } }.__yix_compute);
    }), "") ++ " " ++ ui.view.yixFormat(@TypeOf(__yix_d2: {
        const __yix_T = @TypeOf(isPicked(__yix_row_1.value.peek(), opt.peek().value));
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .value = __yix_row_1.value, .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return isPicked(__yix_ctx.value.get(), __yix_ctx.opt.get().value);
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(opt.peek().label);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.opt.get().label;
        } }.__yix_compute);
    }, __yix_d2: {
        const __yix_T = @TypeOf(isPicked(__yix_row_1.value.peek(), opt.peek().value));
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .value = __yix_row_1.value, .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return isPicked(__yix_ctx.value.get(), __yix_ctx.opt.get().value);
        } }.__yix_compute);
    }, })),
                    Button(.{ .label = __yix_d3: {
        const __yix_T = if (ui.view.attrType(Button, "label")) |__yix_A| __yix_A else @TypeOf(opt.peek().label);
        break :__yix_d3 try __yix_scope_1.derive(__yix_T, .{ .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.opt.get().label;
        } }.__yix_compute);
    }, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_scope_1, .{ .value = __yix_row_1.value, .opt = opt, .__yix_model_value = __yix_row_1.__yix_model_value, .onChange = __yix_row_1.onChange, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.__yix_model_value.propose(__yix_ctx.opt.peek().value, __yix_ctx.onChange);  } }.__yix_run)), }),
                })); } }.__yix_row); },
        }));
    __yix_root.meta.ownership.meta.component_name = "Picker";
    return __yix_root;

}
pub fn PickerUse(args: anytype) ui.view.ComponentOf(__yix_PickerUse) {
    return ui.view.component(__yix_PickerUse, ui.reactive.props.coerce(PickerUseProps, args));
}
pub const PickerUseProps = struct {
};
fn __yix_PickerUse(__yix_props: PickerUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const picked = try scope.createSignalFor(?[]const u8, null);
    const count = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("count " ++ ui.view.yixFormat(@TypeOf(count), ""), .{ count, })),
            Picker(.{ .value = picked, .on_change = ui.view.eventProp(Picker, "on_change", try ui.on.bindAny(scope, .{ .count = count, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, v: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1)); _ = v;  } }.__yix_run)), }),
        }));
    __yix_root.meta.ownership.meta.component_name = "PickerUse";
    return __yix_root;

}

// B1: static lifting shrinks to actual dependencies. External store read via function call; static
// params must follow.
pub var external_count: ?*ui.Signal(i32) = null;
fn externalCount() i32 {
    return if (external_count) |s| s.get() else 0;
}
pub fn ExternalSum(args: anytype) ui.view.ComponentOf(__yix_ExternalSum) {
    return ui.view.component(__yix_ExternalSum, ui.reactive.props.coerce(ExternalSumProps, args));
}
pub const ExternalSumProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
};
fn __yix_ExternalSum(__yix_props: ExternalSumProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    const total = __yix_d1: {
        const __yix_T = @TypeOf(n.peek() + externalCount());
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() + externalCount();
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt("sum " ++ ui.view.yixFormat(@TypeOf(total), ""), .{ total, })));
    __yix_root.meta.ownership.meta.component_name = "ExternalSum";
    return __yix_root;

}
pub fn StaticTwice(args: anytype) ui.view.ComponentOf(__yix_StaticTwice) {
    return ui.view.component(__yix_StaticTwice, ui.reactive.props.coerce(StaticTwiceProps, args));
}
pub const StaticTwiceProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
};
fn __yix_StaticTwice(__yix_props: StaticTwiceProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    const twice = __yix_d1: {
        const __yix_T = @TypeOf(n.peek() * 2);
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() * 2;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt("twice " ++ ui.view.yixFormat(@TypeOf(twice), ""), .{ twice, })));
    __yix_root.meta.ownership.meta.component_name = "StaticTwice";
    return __yix_root;

}
/// Text child elements determined by component parameter type, not name: aliased Buttons still
/// treat text as label.
const Btn = W.Button;
pub fn AliasLabel(args: anytype) ui.view.ComponentOf(__yix_AliasLabel) {
    return ui.view.component(__yix_AliasLabel, ui.reactive.props.coerce(AliasLabelProps, args));
}
pub const AliasLabelProps = struct {
};
fn __yix_AliasLabel(__yix_props: AliasLabelProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const n = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("n " ++ ui.view.yixFormat(@TypeOf(n), ""), .{ n, })),
            ui.view.textChild(Btn, .{ .on_click = ui.view.eventProp(Btn, "on_click", try ui.on.bindAny(scope, .{ .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), }, "Aliased", .{
                ui.view.text(.{}, ui.view.fmt("Aliased", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "AliasLabel";
    return __yix_root;

}
/// Components without label parameter (with slots): text remains child element.
pub fn TextIntoSlot(args: anytype) ui.view.ComponentOf(__yix_TextIntoSlot) {
    return ui.view.component(__yix_TextIntoSlot, ui.reactive.props.coerce(TextIntoSlotProps, args));
}
pub const TextIntoSlotProps = struct {
};
fn __yix_TextIntoSlot(__yix_props: TextIntoSlotProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.textChild(Panel, .{ .title = "p", }, "plain words", .{
            ui.view.text(.{}, ui.view.fmt("plain words", .{ })),
        }));
    __yix_root.meta.ownership.meta.component_name = "TextIntoSlot";
    return __yix_root;

}
/// No default value means required (for data parameters and Handlers).
pub fn Required(args: anytype) ui.view.ComponentOf(__yix_Required) {
    return ui.view.component(__yix_Required, ui.reactive.props.coerce(RequiredProps, args));
}
pub const RequiredProps = struct {
    title: ui.Source([]const u8),
    on_go: ui.Handler(void),
};
fn __yix_Required(__yix_props: RequiredProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = __yix_props.title;
    const onGo = __yix_props.on_go;
    const __yix_root = try ui.view.render(scope, cx, Button(.{ .label = title, .on_click = if (comptime ui.view.isEventProp(Button, "on_click")) onGo else onGo, }));
    __yix_root.meta.ownership.meta.component_name = "Required";
    return __yix_root;

}
pub fn RequiredUse(args: anytype) ui.view.ComponentOf(__yix_RequiredUse) {
    return ui.view.component(__yix_RequiredUse, ui.reactive.props.coerce(RequiredUseProps, args));
}
pub const RequiredUseProps = struct {
};
fn __yix_RequiredUse(__yix_props: RequiredUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const n = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("went " ++ ui.view.yixFormat(@TypeOf(n), ""), .{ n, })),
            Required(.{ .title = "Go there", .on_go = ui.view.eventProp(Required, "on_go", try ui.on.bindAny(scope, .{ .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), }),
        }));
    __yix_root.meta.ownership.meta.component_name = "RequiredUse";
    return __yix_root;

}
/// I6: optional value capture. Value changes within the same branch update only text, branch does
/// not rebuild.
pub fn PickedName(args: anytype) ui.view.ComponentOf(__yix_PickedName) {
    return ui.view.component(__yix_PickedName, ui.reactive.props.coerce(PickedNameProps, args));
}
pub const PickedNameProps = struct {
};
fn __yix_PickedName(__yix_props: PickedNameProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const picked = try scope.createSignalFor(?[]const u8, null);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazyIfSome(picked, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, name: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("picked " ++ ui.view.yixFormat(@TypeOf(name), ""), .{ name, })) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ }, ui.view.fmt("none", .{ })) }); } }.__yix_b),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .picked = picked, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.picked.set("a");  } }.__yix_run)), }, "A", .{
                ui.view.text(.{}, ui.view.fmt("A", .{ })),
            }),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .picked = picked, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.picked.set("b");  } }.__yix_run)), }, "B", .{
                ui.view.text(.{}, ui.view.fmt("B", .{ })),
            }),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .picked = picked, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.picked.set(null);  } }.__yix_run)), }, "Clear", .{
                ui.view.text(.{}, ui.view.fmt("Clear", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "PickedName";
    return __yix_root;

}
pub const Shape = union(enum) { circle: i32, square: i32, none };
/// I6: payload capture with tagged union.
pub fn ShapeLabel(args: anytype) ui.view.ComponentOf(__yix_ShapeLabel) {
    return ui.view.component(__yix_ShapeLabel, ui.reactive.props.coerce(ShapeLabelProps, args));
}
pub const ShapeLabelProps = struct {
};
fn __yix_ShapeLabel(__yix_props: ShapeLabelProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const shape = try scope.createSignalFor(Shape, .{ .circle = 1 });
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazySwitch(shape, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bt1_0: anytype, __yix_bv1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; switch (__yix_bt1_0) { .circle => { const r = try ui.view.branchValue(__yix_bs1_0, __yix_bv1_0, ui.view.payloadOf(@TypeOf(__yix_bv1_0.peek()), .circle)); return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("circle " ++ ui.view.yixFormat(@TypeOf(r), ""), .{ r, })) }); }, .square => { const w = try ui.view.branchValue(__yix_bs1_0, __yix_bv1_0, ui.view.payloadOf(@TypeOf(__yix_bv1_0.peek()), .square)); return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("square " ++ ui.view.yixFormat(@TypeOf(w), ""), .{ w, })) }); }, .none => { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("no shape", .{ })) }); }, } } }.__yix_b),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .shape = shape, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shape.set(.{ .circle = 2 });  } }.__yix_run)), }, "Grow", .{
                ui.view.text(.{}, ui.view.fmt("Grow", .{ })),
            }),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .shape = shape, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shape.set(.{ .square = 5 });  } }.__yix_run)), }, "Square", .{
                ui.view.text(.{}, ui.view.fmt("Square", .{ })),
            }),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .shape = shape, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shape.set(.none);  } }.__yix_run)), }, "None", .{
                ui.view.text(.{}, ui.view.fmt("None", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "ShapeLabel";
    return __yix_root;

}
pub const ParseError = error{Bad};
/// I6: value / error capture from error union.
pub fn Parsed(args: anytype) ui.view.ComponentOf(__yix_Parsed) {
    return ui.view.component(__yix_Parsed, ui.reactive.props.coerce(ParsedProps, args));
}
pub const ParsedProps = struct {
    result: ui.Source(ParseError!i32),
};
fn __yix_Parsed(__yix_props: ParsedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const result = __yix_props.result;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazyIfSome(result, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, v: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt("value " ++ ui.view.yixFormat(@TypeOf(v), ""), .{ v, })) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, e: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ }, ui.view.fmt("error " ++ ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(@errorName(e.peek()));
        break :__yix_d1 try __yix_bs1_1.derive(__yix_T, .{ .e = e, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return @errorName(__yix_ctx.e.get());
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(@errorName(e.peek()));
        break :__yix_d1 try __yix_bs1_1.derive(__yix_T, .{ .e = e, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return @errorName(__yix_ctx.e.get());
        } }.__yix_compute);
    }, })) }); } }.__yix_b),
        }));
    __yix_root.meta.ownership.meta.component_name = "Parsed";
    return __yix_root;

}
/// I12: lazy branch construction. Hidden branches do not construct derived values inside.
pub fn LazyBranch(args: anytype) ui.view.ComponentOf(__yix_LazyBranch) {
    return ui.view.component(__yix_LazyBranch, ui.reactive.props.coerce(LazyBranchProps, args));
}
pub const LazyBranchProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
};
fn __yix_LazyBranch(__yix_props: LazyBranchProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    const shown = try scope.createSignalFor(bool, false);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.lazyIf(shown, .{ .n = n, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_b1_0.n.peek() * 2 + 1);
        break :__yix_d1 try __yix_bs1_0.derive(__yix_T, .{ .n = __yix_b1_0.n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() * 2 + 1;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(__yix_b1_0.n.peek() * 2 + 1);
        break :__yix_d1 try __yix_bs1_0.derive(__yix_T, .{ .n = __yix_b1_0.n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() * 2 + 1;
        } }.__yix_compute);
    }, })) }); } }.__yix_b, null),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .shown = shown, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shown.set(!__yix_ctx.shown.peek());  } }.__yix_run)), }, "Toggle", .{
                ui.view.text(.{}, ui.view.fmt("Toggle", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "LazyBranch";
    return __yix_root;

}
/// B2: host element typed events (keyboard / pointer / scroll); e.consume() prevents default
/// behavior.
pub fn KeyPad(args: anytype) ui.view.ComponentOf(__yix_KeyPad) {
    return ui.view.component(__yix_KeyPad, ui.reactive.props.coerce(KeyPadProps, args));
}
pub const KeyPadProps = struct {
};
fn __yix_KeyPad(__yix_props: KeyPadProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const last = try scope.createSignalFor([]const u8, "none");
    const px = try scope.createSignalFor(f32, 0);
    const moves = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.box(.{ .test_id = "pad", .focusable = true, .on_key_down = try ui.on.bindAny(scope, .{ .last = last, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, e: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (e.key == .escape) { __yix_ctx.last.set("escape"); e.consume(); } else { __yix_ctx.last.set("other"); }  } }.__yix_run), .on_pointer_down = try ui.on.bindAny(scope, .{ .px = px, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, e: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.px.set(e.x);  } }.__yix_run), .on_pointer_move = try ui.on.bindAny(scope, .{ .moves = moves, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.moves.set(__yix_ctx.moves.peek() + (1));  } }.__yix_run), .on_scroll = try ui.on.bindAny(scope, .{ .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, e: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); e.stop();  } }.__yix_run), }, .{ }),
            ui.view.text(.{ }, ui.view.fmt("key " ++ ui.view.yixFormat(@TypeOf(last), ""), .{ last, })),
            ui.view.text(.{ }, ui.view.fmt("x " ++ ui.view.yixFormat(@TypeOf(px), ""), .{ px, })),
            ui.view.text(.{ }, ui.view.fmt("moves " ++ ui.view.yixFormat(@TypeOf(moves), ""), .{ moves, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "KeyPad";
    return __yix_root;

}
pub var lifecycle_log: [8]i32 = @splat(0);
pub var lifecycle_len: usize = 0;
fn logLifecycle(v: i32) void {
    lifecycle_log[lifecycle_len] = v;
    lifecycle_len += 1;
}
fn mounted(r: anytype) i32 {
    return if (r.get() != null) 1 else 0;
}
/// B2: effects follow source; ref attached at onMount; onUnmount executes during unmount.
pub fn Lifecycle(args: anytype) ui.view.ComponentOf(__yix_Lifecycle) {
    return ui.view.component(__yix_Lifecycle, ui.reactive.props.coerce(LifecycleProps, args));
}
pub const LifecycleProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
};
fn __yix_Lifecycle(__yix_props: LifecycleProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    const doubled = try scope.createSignalFor(i32, 0);
    const root = try ui.view.createRef(scope, *ui.Node);
    try scope.createEffect(.{ .doubled = doubled, .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.doubled.set(__yix_ctx.n.get() * 2);  } }.__yix_run);
    {
        const __yix_cleanup_ctx = .{ .__yix_owner = scope.owner, };
        const __YixCleanup = @TypeOf(__yix_cleanup_ctx);
        const __yix_cleanup = try scope.createState(__YixCleanup, __yix_cleanup_ctx);
        try scope.onCleanup(__YixCleanup, __yix_cleanup, struct { fn __yix_run(__yix_c: *__YixCleanup) void { (struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); logLifecycle(-1);  } }.__yix_run)(__yix_c.*); } }.__yix_run);
    }
    const __yix_root = try ui.view.render(scope, cx, ui.view.ref(root, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("doubled " ++ ui.view.yixFormat(@TypeOf(doubled), ""), .{ doubled, })),
        })));
    __yix_root.meta.ownership.meta.component_name = "Lifecycle";
    struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); logLifecycle(mounted(__yix_ctx.root));  } }.__yix_run(.{ .root = root, .__yix_owner = scope.owner, });
    return __yix_root;

}
fn mayFail(ok: bool) !i32 {
    if (!ok) return error.Nope;
    return 5;
}
/// B2: try in event (failure reported via ui.on.reportError, following statements don't execute)
/// and const locals.
pub fn TryEvent(args: anytype) ui.view.ComponentOf(__yix_TryEvent) {
    return ui.view.component(__yix_TryEvent, ui.reactive.props.coerce(TryEventProps, args));
}
pub const TryEventProps = struct {
};
fn __yix_TryEvent(__yix_props: TryEventProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const n = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ }, ui.view.fmt("n " ++ ui.view.yixFormat(@TypeOf(n), ""), .{ n, })),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { body(__yix_ctx) catch |err| ui.on.reportError("onClick", err); } fn body(__yix_ctx: anytype) anyerror!void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); const v = try mayFail(true); __yix_ctx.n.set(__yix_ctx.n.peek() + (v));  } }.__yix_run)), }, "Ok", .{
                ui.view.text(.{}, ui.view.fmt("Ok", .{ })),
            }),
            ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { body(__yix_ctx) catch |err| ui.on.reportError("onClick", err); } fn body(__yix_ctx: anytype) anyerror!void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); const v = try mayFail(false); __yix_ctx.n.set(__yix_ctx.n.peek() + (v));  } }.__yix_run)), }, "Fail", .{
                ui.view.text(.{}, ui.view.fmt("Fail", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "TryEvent";
    return __yix_root;

}
/// P3a: :focus (click) / :focus-visible (keyboard) / :disabled (from a11y.disabled) on plain box.
pub fn StateBox(args: anytype) ui.view.ComponentOf(__yix_StateBox) {
    return ui.view.component(__yix_StateBox, ui.reactive.props.coerce(StateBoxProps, args));
}
pub const StateBoxProps = struct {
    disabled: ui.Source(bool) = .{ .value = false },
};
fn __yix_StateBox(__yix_props: StateBoxProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const disabled = __yix_props.disabled;
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .test_id = "sb", .focusable = true, .style = States.field, .a11y = .{ .role = .button, .disabled = disabled }, }, .{ }));
    __yix_root.meta.ownership.meta.component_name = "StateBox";
    return __yix_root;

}
/// P3b: named slots; {children} need not be the last child.
pub fn Frame(args: anytype) ui.view.SlottedOf(__yix_Frame) {
    return ui.view.slotted(__yix_Frame, ui.reactive.props.coerce(FrameProps, args));
}
pub const FrameProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
};
fn __yix_Frame(__yix_props: FrameProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const title = __yix_props.title;
    var __yix_slot_header: ?ui.view.SlotPoint = null;
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    var __yix_slot_footer: ?ui.view.SlotPoint = null;
    const __yix_root = try ui.view.render(scope, cx, ui.view.slotEnd(&__yix_slot_footer, ui.view.col(.{ }, .{
            ui.view.row(.{ }, .{
                ui.view.slotMark(&__yix_slot_header),
                ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(title), ""), .{ title, })),
            }),
            ui.view.col(.{ }, .{
                ui.view.slotMark(&__yix_slot_children),
                ui.view.text(.{ }, ui.view.fmt("after body", .{ })),
            }),
        })));
    __yix_root.meta.ownership.meta.component_name = "Frame";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ .header = __yix_slot_header, .footer = __yix_slot_footer, });

}
pub fn FrameUse(args: anytype) ui.view.ComponentOf(__yix_FrameUse) {
    return ui.view.component(__yix_FrameUse, ui.reactive.props.coerce(FrameUseProps, args));
}
pub const FrameUseProps = struct {
};
fn __yix_FrameUse(__yix_props: FrameUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const n = try scope.createSignalFor(i32, 0);
    const __yix_root = try ui.view.render(scope, cx, ui.view.with(Frame(.{ .title = "T", }), .{
            ui.view.text(.{ }, ui.view.fmt("body " ++ ui.view.yixFormat(@TypeOf(n), ""), .{ n, })),
        }).slots(.{ .header = ui.view.text(.{ }, ui.view.fmt("head", .{ })), .footer = ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(scope, .{ .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), }, "More", .{
                ui.view.text(.{}, ui.view.fmt("More", .{ })),
            }), }));
    __yix_root.meta.ownership.meta.component_name = "FrameUse";
    return __yix_root;

}
/// P4: icon-color toggles with flag; reverts to mount-time tint on undo.
pub fn GlyphBox(args: anytype) ui.view.ComponentOf(__yix_GlyphBox) {
    return ui.view.component(__yix_GlyphBox, ui.reactive.props.coerce(GlyphBoxProps, args));
}
pub const GlyphBoxProps = struct {
    hot: ui.Source(bool) = .{ .value = false },
};
fn __yix_GlyphBox(__yix_props: GlyphBoxProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const hot = __yix_props.hot;
    const __yix_root = try ui.view.render(scope, cx, ui.view.icon(.{ .test_id = "glyph", .style = States.Glyph.of(.{ .hot = hot }), }, ui.icons.check));
    __yix_root.meta.ownership.meta.component_name = "GlyphBox";
    return __yix_root;

}
pub fn GlyphTinted(args: anytype) ui.view.ComponentOf(__yix_GlyphTinted) {
    return ui.view.component(__yix_GlyphTinted, ui.reactive.props.coerce(GlyphTintedProps, args));
}
pub const GlyphTintedProps = struct {
    hot: ui.Source(bool) = .{ .value = false },
};
fn __yix_GlyphTinted(__yix_props: GlyphTintedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const hot = __yix_props.hot;
    const __yix_root = try ui.view.render(scope, cx, ui.view.icon(.{ .test_id = "glyph", .style = States.GlyphOnHot.of(.{ .hot = hot }), }, ui.icons.check));
    __yix_root.meta.ownership.meta.component_name = "GlyphTinted";
    return __yix_root;

}
pub fn LinkText(args: anytype) ui.view.ComponentOf(__yix_LinkText) {
    return ui.view.component(__yix_LinkText, ui.reactive.props.coerce(LinkTextProps, args));
}
pub const LinkTextProps = struct {
};
fn __yix_LinkText(__yix_props: LinkTextProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ .test_id = "link", .style = States.link, }, ui.view.fmt("Open docs", .{ })),
        }));
    __yix_root.meta.ownership.meta.component_name = "LinkText";
    return __yix_root;

}
pub fn PillText(args: anytype) ui.view.ComponentOf(__yix_PillText) {
    return ui.view.component(__yix_PillText, ui.reactive.props.coerce(PillTextProps, args));
}
pub const PillTextProps = struct {
};
fn __yix_PillText(__yix_props: PillTextProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.text(.{ .test_id = "pill", .style = States.pill, }, ui.view.fmt("Beta", .{ })),
        }));
    __yix_root.meta.ownership.meta.component_name = "PillText";
    return __yix_root;

}
/// P5: in-place list row update -- same key, changed content does not rebuild row (focus/local
/// state preserved); event reads latest data.
pub var picked_title: []const u8 = "";
fn pick(title: []const u8) void {
    picked_title = title;
}
pub fn EditableRows(args: anytype) ui.view.ComponentOf(__yix_EditableRows) {
    return ui.view.component(__yix_EditableRows, ui.reactive.props.coerce(EditableRowsProps, args));
}
pub const EditableRowsProps = struct {
    rows: ui.Source([]const Item) = .{ .value = &.{} },
};
fn __yix_EditableRows(__yix_props: EditableRowsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const rows = __yix_props.rows;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            __yix_e1: { const __yix_items_1 = rows; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.row(.{ .test_id = "row", .focusable = true, .on_click = try ui.on.bind(__yix_scope_1, .{ .item = item, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); pick(__yix_ctx.item.peek().title);  } }.__yix_run), }, .{
                    ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(i), "") ++ ":" ++ ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ i, __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, })),
                })); } }.__yix_row); },
        }));
    __yix_root.meta.ownership.meta.component_name = "EditableRows";
    return __yix_root;

}
/// Data parameters named on* (e.g., onTop: bool) pass by value; event params receiving identifier
/// call it.
pub var saved_count: u32 = 0;
fn save() void {
    saved_count += 1;
}
fn Pin(args: anytype) ui.view.ComponentOf(__yix_Pin) {
    return ui.view.component(__yix_Pin, ui.reactive.props.coerce(PinProps, args));
}
const PinProps = struct {
    on_top: ui.Source(bool) = .{ .value = false },
    on_save: ?ui.Handler(void) = null,
};
fn __yix_Pin(__yix_props: PinProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const onTop = __yix_props.on_top;
    const onSave = __yix_props.on_save;
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .test_id = "pin", .visible = onTop, .on_click = onSave, }, .{ }));
    __yix_root.meta.ownership.meta.component_name = "Pin";
    return __yix_root;

}
pub fn PinBoard(args: anytype) ui.view.ComponentOf(__yix_PinBoard) {
    return ui.view.component(__yix_PinBoard, ui.reactive.props.coerce(PinBoardProps, args));
}
pub const PinBoardProps = struct {
    pinned: ui.Source(bool) = .{ .value = false },
};
fn __yix_PinBoard(__yix_props: PinBoardProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const pinned = __yix_props.pinned;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            Pin(.{ .on_top = ui.view.valueProp(Pin, "on_top", true), }),
            Pin(.{ .on_top = if (comptime ui.view.isEventProp(Pin, "on_top")) try ui.on.bindAny(scope, .{ .pinned = pinned, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.pinned.peek()();  } }.__yix_run) else pinned, .on_save = if (comptime ui.view.isEventProp(Pin, "on_save")) try ui.on.bindAny(scope, .{ .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); save();  } }.__yix_run) else save, }),
            Pin(.{ .on_top = if (comptime ui.view.isEventProp(Pin, "on_top")) try ui.on.bindAny(scope, .{ .pinned = pinned, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); !__yix_ctx.pinned.peek();  } }.__yix_run) else __yix_d1: {
        const __yix_T = if (ui.view.attrType(Pin, "on_top")) |__yix_A| __yix_A else @TypeOf(!pinned.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .pinned = pinned, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return !__yix_ctx.pinned.get();
        } }.__yix_compute);
    }, .on_save = if (comptime ui.view.isEventProp(Pin, "on_save")) try ui.on.bindAny(scope, .{ .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); save();  } }.__yix_run) else __yix_call3: {
        const __yix_Raw = @TypeOf(save());
        break :__yix_call3 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) save() else __yix_d2: {
        const __yix_T = if (ui.view.attrType(Pin, "on_save")) |__yix_A| __yix_A else @TypeOf(save());
        break :__yix_d2 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return save();
        } }.__yix_compute);
    };
    }, }),
        }));
    __yix_root.meta.ownership.meta.component_name = "PinBoard";
    return __yix_root;

}
/// Text child elements into component declaration's Text parameter (regardless of param name);
/// components without Text param collect as children.
fn Caption(args: anytype) ui.view.ComponentOf(__yix_Caption) {
    return ui.view.component(__yix_Caption, ui.reactive.props.coerce(CaptionProps, args));
}
const CaptionProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "title";
};
fn __yix_Caption(__yix_props: CaptionProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = __yix_props.title;
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ .test_id = "caption", }, ui.view.fmt(ui.view.yixFormat(@TypeOf(title), ""), .{ title, })));
    __yix_root.meta.ownership.meta.component_name = "Caption";
    return __yix_root;

}
pub fn Captions(args: anytype) ui.view.ComponentOf(__yix_Captions) {
    return ui.view.component(__yix_Captions, ui.reactive.props.coerce(CaptionsProps, args));
}
pub const CaptionsProps = struct {
};
fn __yix_Captions(__yix_props: CaptionsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            ui.view.textChild(Caption, .{ }, "Hello", .{
                ui.view.text(.{}, ui.view.fmt("Hello", .{ })),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "Captions";
    return __yix_root;

}
/// Nested for: inner row references outer row fields.
pub const Group = struct { id: u64, name: []const u8, members: []const Item };
pub fn Groups(args: anytype) ui.view.ComponentOf(__yix_Groups) {
    return ui.view.component(__yix_Groups, ui.reactive.props.coerce(GroupsProps, args));
}
pub const GroupsProps = struct {
    groups: ui.Source([]const Group) = .{ .value = &.{} },
};
fn __yix_Groups(__yix_props: GroupsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const groups = __yix_props.groups;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ }, .{
            __yix_e1: { const __yix_items_1 = groups; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, g: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.col(.{ }, .{
                    ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(g.peek().name);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .g = g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().name;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(g.peek().name);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .g = g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().name;
        } }.__yix_compute);
    }, })),
                    __yix_e2: { const __yix_items_2 = __yix_d3: {
        const __yix_T = @TypeOf(g.peek().members);
        break :__yix_d3 try __yix_scope_1.derive(__yix_T, .{ .g = g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().members;
        } }.__yix_compute);
    }; break :__yix_e2 ui.view.eachWith(.{ .g = g, }, __yix_items_2, .id, struct { fn __yix_row(__yix_row_2: anytype, m: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_2))), __yix_scope_2: *ui.Scope, __yix_cx_2: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_2, __yix_cx_2, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_row_2.g.peek().name);
        break :__yix_d1 try __yix_scope_2.derive(__yix_T, .{ .g = __yix_row_2.g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().name;
        } }.__yix_compute);
    }), "") ++ "/" ++ ui.view.yixFormat(@TypeOf(__yix_d2: {
        const __yix_T = @TypeOf(m.peek().title);
        break :__yix_d2 try __yix_scope_2.derive(__yix_T, .{ .m = m, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.m.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(__yix_row_2.g.peek().name);
        break :__yix_d1 try __yix_scope_2.derive(__yix_T, .{ .g = __yix_row_2.g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().name;
        } }.__yix_compute);
    }, __yix_d2: {
        const __yix_T = @TypeOf(m.peek().title);
        break :__yix_d2 try __yix_scope_2.derive(__yix_T, .{ .m = m, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.m.get().title;
        } }.__yix_compute);
    }, }))); } }.__yix_row); },
                })); } }.__yix_row); },
        }));
    __yix_root.meta.ownership.meta.component_name = "Groups";
    return __yix_root;

}
/// Reactive name in type position.
pub fn TypeOfProbe(args: anytype) ui.view.ComponentOf(__yix_TypeOfProbe) {
    return ui.view.component(__yix_TypeOfProbe, ui.reactive.props.coerce(TypeOfProbeProps, args));
}
pub const TypeOfProbeProps = struct {
    n: ui.Source(u32) = .{ .value = 0 },
};
fn __yix_TypeOfProbe(__yix_props: TypeOfProbeProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    const doubled = __yix_d1: {
        const __yix_T = @TypeOf(@as(@TypeOf(n.peek()), n.peek() * 2));
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return @as(@TypeOf(__yix_ctx.n.get()), __yix_ctx.n.get() * 2);
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(doubled), ""), .{ doubled, })));
    __yix_root.meta.ownership.meta.component_name = "TypeOfProbe";
    return __yix_root;

}

//# yix-map-data [[687,682],[1510,898],[3014,1114],[3667,1248],[5304,1461],[6850,1684],[9803,2047],[13328,2848],[16291,3355],[17749,3787],[19912,4386],[21413,4745],[23527,4998],[24123,5074],[25201,5228],[26734,5458],[28334,5652],[31477,6015],[32651,6200],[33516,6304],[34340,6482],[35452,6643],[36324,6806],[37832,7003],[39516,7206],[41260,7403],[43844,7632],[45643,7877],[47722,8093],[50078,8334],[51895,8526],[53066,8735],[54251,8945],[55524,9147],[56816,9370],[59777,9888],[63504,10202],[64869,10670],[65802,10796],[66852,11053],[68027,11268],[68734,11420],[69424,11537],[70557,11799],[73174,12280],[76132,12832],[78004,13078],[80099,13371],[82606,14315],[84631,14776],[86517,15179],[87252,15402],[88484,15671],[89728,15934],[90350,16076],[91001,16226],[91602,16333],[92442,16679],[94656,17156],[95303,17294],[98113,17671],[98852,17763],[99618,17972],[103094,18315]]

//# yix-map stories.yix
