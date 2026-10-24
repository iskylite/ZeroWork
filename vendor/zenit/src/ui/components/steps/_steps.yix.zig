// GENERATED FILE, do not edit: generated from steps.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Steps view. Styling in styles.yss; public types and tests in mod.zig.
const std = @import("std");
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const StepItem = mod.StepItem;

/// Text in circle: done is "v", otherwise number (starting from 1)
const CircleLabel = struct {
    completed: bool,
    n: usize,
    pub fn format(self: CircleLabel, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.completed) return w.writeAll("v");
        try w.print("{d}", .{self.n});
    }
};

/// Circle displays number / checkmark, purely visual signals: explicitly state three
/// states -- selected = current step ("you are here"), checked = done, disabled = not
/// yet reached.
fn a11yOf(item: StepItem, completed: bool, active: bool) ui.A11yProps {
    return .{ .role = .listitem, .label = item.title, .description = item.description, .selected = active, .checked = completed, .disabled = !completed and !active };
}

/// Row key: content + borrow string address (row borrows title / description)
fn rowKey(it: StepItem) u64 {
    var h = std.hash.Wyhash.init(0);
    for ([_]?[]const u8{ it.title, it.description }) |field| {
        const f = field orelse "";
        h.update(&[_]u8{@intFromBool(field != null)});
        h.update(std.mem.asBytes(&f.len));
        h.update(f);
        h.update(std.mem.asBytes(&@intFromPtr(f.ptr)));
    }
    return h.final();
}

// Circle: number text is the circle node itself (text_align = center, excludes
// children); with checkmark icon, done step becomes circle with icon (icon =
// checkmark when done, else null).

/// Horizontal step: equal-width column (circle + title + description)
fn HStep(args: anytype) ui.view.ComponentOf(__yix_HStep) {
    return ui.view.component(__yix_HStep, ui.reactive.props.coerce(HStepProps, args));
}
const HStepProps = struct {
    item: ui.Source(StepItem),
    index: ui.Source(usize),
    current: ui.Source(usize),
    check: ui.Source(?ui.SvgAsset),
};
fn __yix_HStep(__yix_props: HStepProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const item = __yix_props.item;
    const index = __yix_props.index;
    const current = __yix_props.current;
    const check = __yix_props.check;
    const completed = __yix_d1: {
        const __yix_T = @TypeOf(index.peek() < current.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() < __yix_ctx.current.get();
        } }.__yix_compute);
    };
    const active = __yix_d2: {
        const __yix_T = @TypeOf(index.peek() == current.peek());
        break :__yix_d2 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() == __yix_ctx.current.get();
        } }.__yix_compute);
    };
    const p = ui.view.slotParts(S.Step, .{ .completed = completed, .active = active });
    const semantics = __yix_d3: {
        const __yix_T = @TypeOf(a11yOf(item.peek(), index.peek() < current.peek(), index.peek() == current.peek()));
        break :__yix_d3 try scope.derive(__yix_T, .{ .item = item, .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return a11yOf(__yix_ctx.item.get(), __yix_ctx.index.get() < __yix_ctx.current.get(), __yix_ctx.index.get() == __yix_ctx.current.get());
        } }.__yix_compute);
    };
    const label = __yix_d4: {
        const __yix_T = @TypeOf(CircleLabel{ .completed = index.peek() < current.peek(), .n = index.peek() + 1 });
        break :__yix_d4 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return CircleLabel{ .completed = __yix_ctx.index.get() < __yix_ctx.current.get(), .n = __yix_ctx.index.get() + 1 };
        } }.__yix_compute);
    };
    const icon = __yix_d5: {
        const __yix_T = @TypeOf(if (index.peek() < current.peek()) check.peek() else null);
        break :__yix_d5 try scope.derive(__yix_T, .{ .index = index, .current = current, .check = check, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.index.get() < __yix_ctx.current.get()) __yix_ctx.check.get() else null;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = S.h_step, .a11y = semantics, }, .{
            ui.view.lazyIfSome(icon, .{ .p = p, .label = label, }, struct { fn __yix_b(__yix_b1_0: anytype, asset: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.box(.{ .style = __yix_b1_0.p.circle, }, .{
                    ui.view.icon(.{ .style = __yix_b1_0.p.icon, }, asset),
                }) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ .style = __yix_b1_1.p.num, .box = __yix_b1_1.p.circle, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_1.label), ""), .{ __yix_b1_1.label, })) }); } }.__yix_b),
            ui.view.text(.{ .style = p.title, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d6: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d6 try scope.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d6: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d6 try scope.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, })),
            ui.view.lazyIfSome(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().description);
        break :__yix_d1 try scope.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().description;
        } }.__yix_compute);
    }, .{ }, struct { fn __yix_b(__yix_b2_0: anytype, desc: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { _ = __yix_b2_0; return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.text(.{ .style = S.desc, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(desc), ""), .{ desc, })) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "HStep";
    return __yix_root;

}

/// Vertical step: indicator column (circle + connector to next step) + text column
fn VStep(args: anytype) ui.view.ComponentOf(__yix_VStep) {
    return ui.view.component(__yix_VStep, ui.reactive.props.coerce(VStepProps, args));
}
const VStepProps = struct {
    item: ui.Source(StepItem),
    index: ui.Source(usize),
    current: ui.Source(usize),
    count: ui.Source(usize),
    check: ui.Source(?ui.SvgAsset),
};
fn __yix_VStep(__yix_props: VStepProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const item = __yix_props.item;
    const index = __yix_props.index;
    const current = __yix_props.current;
    const count = __yix_props.count;
    const check = __yix_props.check;
    const completed = __yix_d1: {
        const __yix_T = @TypeOf(index.peek() < current.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() < __yix_ctx.current.get();
        } }.__yix_compute);
    };
    const active = __yix_d2: {
        const __yix_T = @TypeOf(index.peek() == current.peek());
        break :__yix_d2 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() == __yix_ctx.current.get();
        } }.__yix_compute);
    };
    const p = ui.view.slotParts(S.Step, .{ .completed = completed, .active = active });
    const semantics = __yix_d3: {
        const __yix_T = @TypeOf(a11yOf(item.peek(), index.peek() < current.peek(), index.peek() == current.peek()));
        break :__yix_d3 try scope.derive(__yix_T, .{ .item = item, .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return a11yOf(__yix_ctx.item.get(), __yix_ctx.index.get() < __yix_ctx.current.get(), __yix_ctx.index.get() == __yix_ctx.current.get());
        } }.__yix_compute);
    };
    const label = __yix_d4: {
        const __yix_T = @TypeOf(CircleLabel{ .completed = index.peek() < current.peek(), .n = index.peek() + 1 });
        break :__yix_d4 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return CircleLabel{ .completed = __yix_ctx.index.get() < __yix_ctx.current.get(), .n = __yix_ctx.index.get() + 1 };
        } }.__yix_compute);
    };
    const icon = __yix_d5: {
        const __yix_T = @TypeOf(if (index.peek() < current.peek()) check.peek() else null);
        break :__yix_d5 try scope.derive(__yix_T, .{ .index = index, .current = current, .check = check, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.index.get() < __yix_ctx.current.get()) __yix_ctx.check.get() else null;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = S.v_step, .a11y = semantics, }, .{
            ui.view.box(.{ .style = S.v_indicator, }, .{
                ui.view.lazyIfSome(icon, .{ .p = p, .label = label, }, struct { fn __yix_b(__yix_b1_0: anytype, asset: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.box(.{ .style = __yix_b1_0.p.circle, }, .{
                        ui.view.icon(.{ .style = __yix_b1_0.p.icon, }, asset),
                    }) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.text(.{ .style = __yix_b1_1.p.num, .box = __yix_b1_1.p.circle, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_1.label), ""), .{ __yix_b1_1.label, })) }); } }.__yix_b),
                ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(index.peek() + 1 < count.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .index = index, .count = count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() + 1 < __yix_ctx.count.get();
        } }.__yix_compute);
    }, .{ .p = p, }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.box(.{ .style = __yix_b2_0.p.connector, }, .{ }) }); } }.__yix_b, null),
            }),
            ui.view.box(.{ .style = S.vText, }, .{
                ui.view.text(.{ .style = p.title, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d6: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d6 try scope.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d6: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d6 try scope.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, })),
                ui.view.lazyIfSome(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().description);
        break :__yix_d1 try scope.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().description;
        } }.__yix_compute);
    }, .{ }, struct { fn __yix_b(__yix_b3_0: anytype, desc: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { _ = __yix_b3_0; return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.text(.{ .style = S.desc, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(desc), ""), .{ desc, })) }); } }.__yix_b, null),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "VStep";
    return __yix_root;

}

/// Steps control: `W.Steps(.{ .items = &items, .current = step })`. Steps before
/// current are done; >= step count means all done. Horizontal: each step gets an equal
/// column; connector spans first circle center to last, done segment stops at the current
/// circle center. Vertical: one row per step, connector reaches next circle.
/// items/current can come from signals (reconcile by row key; state only changes
/// appearance).
pub fn Steps(args: anytype) ui.view.ComponentOf(__yix_Steps) {
    return ui.view.component(__yix_Steps, ui.reactive.props.coerce(StepsProps, args));
}
pub const StepsProps = struct {
    items: ui.Source([]const StepItem) = .{ .value = &.{} },
    current: ui.Source(usize) = .{ .value = 0 },
    direction: ui.Source(mod.StepsDirection) = .{ .value = .horizontal },
    check_icon_asset: ui.Source(?ui.SvgAsset) = .{ .value = null },
};
fn __yix_Steps(__yix_props: StepsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const items = __yix_props.items;
    const current = __yix_props.current;
    const direction = __yix_props.direction;
    const checkIconAsset = __yix_props.check_icon_asset;
    const horizontal = __yix_d1: {
        const __yix_T = @TypeOf(direction.peek() == .horizontal);
        break :__yix_d1 try scope.derive(__yix_T, .{ .direction = direction, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.direction.get() == .horizontal;
        } }.__yix_compute);
    };
    const count = __yix_d2: {
        const __yix_T = @TypeOf(items.peek().len);
        break :__yix_d2 try scope.derive(__yix_T, .{ .items = items, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.items.get().len;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = S.Container.of(.{ .horizontal = horizontal }), .a11y = .{ .role = .list, .label = "Steps" }, }, .{
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(direction.peek() == .horizontal and items.peek().len > 1);
        break :__yix_d1 try scope.derive(__yix_T, .{ .direction = direction, .items = items, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.direction.get() == .horizontal and __yix_ctx.items.get().len > 1;
        } }.__yix_compute);
    }, .{ .count = count, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.box(.{ .style = S.track.of(.{ .steps = __yix_b1_0.count }), }, .{ }) }); } }.__yix_b, null),
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(direction.peek() == .horizontal and items.peek().len > 1);
        break :__yix_d1 try scope.derive(__yix_T, .{ .direction = direction, .items = items, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.direction.get() == .horizontal and __yix_ctx.items.get().len > 1;
        } }.__yix_compute);
    }, .{ .current = current, .count = count, }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.box(.{ .style = S.progress.of(.{ .steps = __yix_b2_0.count, .current = __yix_b2_0.current }), }, .{ }) }); } }.__yix_b, null),
            ui.view.lazyIf(horizontal, .{ .items = items, .current = current, .checkIconAsset = checkIconAsset, }, struct { fn __yix_b(__yix_b3_0: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ __yix_e4: { const __yix_items_4 = __yix_b3_0.items; break :__yix_e4 ui.view.eachWith(.{ .current = __yix_b3_0.current, .checkIconAsset = __yix_b3_0.checkIconAsset, }, __yix_items_4, struct { fn __yix_k(item: ui.view.yixItem(@TypeOf(__yix_items_4))) u64 { return ui.view.keyOf(rowKey(item)); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_4))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, HStep(.{ .item = item, .index = i, .current = __yix_row_1.current, .check = __yix_row_1.checkIconAsset, })); } }.__yix_row); } }); } }.__yix_b, null),
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(direction.peek() == .vertical);
        break :__yix_d1 try scope.derive(__yix_T, .{ .direction = direction, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.direction.get() == .vertical;
        } }.__yix_compute);
    }, .{ .items = items, .current = current, .checkIconAsset = checkIconAsset, .count = count, }, struct { fn __yix_b(__yix_b5_0: anytype, __yix_bs5_0: *ui.Scope, __yix_bc5_0: *ui.Cx, __yix_bk5_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs5_0, __yix_bc5_0, __yix_bk5_0, .{ __yix_e6: { const __yix_items_6 = __yix_b5_0.items; break :__yix_e6 ui.view.eachWith(.{ .current = __yix_b5_0.current, .checkIconAsset = __yix_b5_0.checkIconAsset, .count = __yix_b5_0.count, }, __yix_items_6, struct { fn __yix_k(item: ui.view.yixItem(@TypeOf(__yix_items_6))) u64 { return ui.view.keyOf(rowKey(item)); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_6))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, VStep(.{ .item = item, .index = i, .current = __yix_row_1.current, .count = __yix_row_1.count, .check = __yix_row_1.checkIconAsset, })); } }.__yix_row); } }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Steps";
    return __yix_root;

}

//# yix-map-data [[1704,1699],[6826,2642],[13176,4150]]

//# yix-map steps.yix
