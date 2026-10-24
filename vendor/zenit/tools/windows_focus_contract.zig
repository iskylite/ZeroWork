//! Provider -> owner-thread drain -> live Cx focus, without native activation.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
extern fn zenit_windows_contract_focus(*anyopaque, u32) i32;
extern fn zenit_windows_contract_focus_redraw(*anyopaque, c_int) c_int;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern fn zenit_windows_contract_selection_operation(*anyopaque, u32, u32, c_int) i32;
extern fn zenit_windows_contract_scroll(*anyopaque, u32, u32, u32, c_int) i32;
extern fn zenit_windows_contract_caret(*anyopaque, u32, u32, *[4]u32, *[8]f32) c_int;
extern fn zenit_windows_contract_geometry(*anyopaque, u32, u32, *[4]u32, *[4]f32) c_int;
extern fn zenit_windows_contract_bounds(*anyopaque, u32, u32, u32, *[4]f64, *u32) i32;
extern fn zenit_windows_handle(*anyopaque) ?*anyopaque;
const NativePoint = extern struct { x: i32 = 0, y: i32 = 0 };
extern "user32" fn ClientToScreen(*anyopaque, *NativePoint) callconv(.winapi) c_int;
extern fn zenit_windows_contract_single_unit_select(*anyopaque, u32, u32, c_int) i32;
extern fn zenit_windows_contract_line_select(*anyopaque, u32, u32) i32;
extern fn zenit_windows_contract_logical_select(*anyopaque, u32, u32, c_int) i32;
extern fn zenit_windows_contract_move_select(*anyopaque, u32, u32, u32, c_int) i32;
extern fn zenit_windows_contract_character_select(*anyopaque, u32, u32) i32;
extern fn zenit_windows_contract_range_select(*anyopaque, u32, u32, u32) i32;
extern fn zenit_windows_contract_text_selection(*anyopaque, u32, u32, u32) i32;
extern fn zenit_windows_contract_point(*anyopaque, u32, f64, f64, *[2]u32) i32;
extern fn zenit_windows_contract_visible_ranges(*anyopaque, u32, *[3]u32) i32;
extern fn zenit_windows_contract_document_selection(*anyopaque, u32, *[4]u32) i32;
extern fn zenit_windows_contract_editable(*anyopaque, u32, *[8]u32) c_int;
var inputs: [2]*ui.Node = undefined;
var targets: [2]*ui.Node = undefined;
var textarea: struct { wrapper: *ui.Node, input: *ui.Node } = undefined;
var stage: []const u8 = "initial";
fn quotaGeometry(_: *anyopaque, _: std.mem.Allocator) ![]ui.A11yProps.TextGeometrySegment {
    return error.AccessibilityGeometryQuota;
}
fn pendingGeometry(_: *anyopaque, _: std.mem.Allocator) ![]ui.A11yProps.TextGeometrySegment {
    return error.AccessibilityLayoutPending;
}
fn pendingLines(_: *anyopaque, _: std.mem.Allocator) ![]u32 {
    return error.AccessibilityLayoutPending;
}
fn fixtureLines(context: *anyopaque, allocator: std.mem.Allocator) ![]u32 {
    const node: *ui.Node = @ptrCast(@alignCast(context));
    const value = node.behavior.interaction.a11y.?.value_text.?;
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(allocator);
    try lines.append(allocator, 0);
    // A visual wrap inside the first logical paragraph distinguishes reliable
    // Line boundaries from the Paragraph fallback while layout is pending.
    if (value.len > 1) try lines.append(allocator, 1);
    for (value, 0..) |char, i| if (char == '\n') {
        try lines.append(allocator, @intCast(i + 1));
    };
    if (lines.items[lines.items.len - 1] != value.len) try lines.append(allocator, @intCast(value.len));
    return lines.toOwnedSlice(allocator);
}
fn fixtureSelection(context: *anyopaque, start: u32, end: u32) bool {
    const node: *ui.Node = @ptrCast(@alignCast(context));
    const props = &node.behavior.interaction.a11y.?;
    if (start > props.value_text.?.len or end > props.value_text.?.len) return false;
    props.editable_text.?.selection_start = @min(start, end);
    props.editable_text.?.selection_end = @max(start, end);
    props.editable_text.?.caret = end;
    return true;
}
fn largeGeometry(_: *anyopaque, allocator: std.mem.Allocator) ![]ui.A11yProps.TextGeometrySegment {
    const pieces = try allocator.alloc(ui.A11yProps.TextGeometrySegment, ui.A11yProps.max_text_geometry_segments);
    @memset(pieces, .{ .start = 0, .end = 1, .rect = .{ .x = 1, .y = 1, .width = 1, .height = 1 } });
    return pieces;
}
fn noSelection(_: *anyopaque, _: u32, _: u32) bool {
    return false;
}
fn nodeGeometry(context: *anyopaque, allocator: std.mem.Allocator) ![]ui.A11yProps.TextGeometrySegment {
    const node: *ui.Node = @ptrCast(@alignCast(context));
    const rect = node.globalRect();
    const pieces = try allocator.alloc(ui.A11yProps.TextGeometrySegment, 1);
    pieces[0] = .{ .start = 0, .end = 1, .rect = .{ .x = rect.x, .y = rect.y, .width = rect.w, .height = rect.h } };
    return pieces;
}
fn wrapFixtureCarets(context: *anyopaque, allocator: std.mem.Allocator) ![]ui.A11yProps.TextCaretGeometry {
    const node: *ui.Node = @ptrCast(@alignCast(context));
    const origin = node.globalRect();
    const result = try allocator.dupe(ui.A11yProps.TextCaretGeometry, &.{
        .{ .offset = 0, .rect = .{ .x = 10, .y = 20, .width = 0, .height = 20 }, .downstream = false },
        .{ .offset = 4, .rect = .{ .x = 30, .y = 20, .width = 0, .height = 20 }, .downstream = false },
        .{ .offset = 4, .rect = .{ .x = 10, .y = 40, .width = 0, .height = 20 }, .downstream = true },
        .{ .offset = 8, .rect = .{ .x = 30, .y = 40, .width = 0, .height = 20 }, .downstream = true },
    });
    for (result) |*c| {
        c.rect.x += origin.x;
        c.rect.y += origin.y;
    }
    return result;
}
fn wrapFixtureGeometry(context: *anyopaque, allocator: std.mem.Allocator) ![]ui.A11yProps.TextGeometrySegment {
    const node: *ui.Node = @ptrCast(@alignCast(context));
    const origin = node.globalRect();
    return allocator.dupe(ui.A11yProps.TextGeometrySegment, &.{
        .{ .start = 0, .end = 4, .rect = .{ .x = origin.x + 10, .y = origin.y + 20, .width = 20, .height = 20 } },
        .{ .start = 4, .end = 8, .rect = .{ .x = origin.x + 10, .y = origin.y + 40, .width = 20, .height = 20 } },
    });
}
var geometry_context: u8 = 0;
const uia_not_supported: i32 = @bitCast(@as(u32, 0x80040204));
fn require(ok: bool) !void {
    if (!ok) {
        std.log.err("UIA selection stage failed: {s}", .{stage});
        return error.UiaFocusContractFailed;
    }
}
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const root = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .column }, .{});
    for (&targets) |*target| {
        target.* = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
        target.*.behavior.interaction.focusable = true;
        target.*.behavior.interaction.a11y = .{ .role = .button, .label = "Focus target" };
        try root.appendChild(cx.allocator, target.*);
    }
    for (&inputs, 0..) |*input, index| {
        const mounted = try ui.widgets.Input(.{ .value = "A中😀B", .width = 220, .input_type = @as(ui.widgets.InputType, if (index == 0) .text else .password) }).mountResult(scope, cx);
        input.* = mounted.input_container;
        try root.appendChild(cx.allocator, mounted.node);
    }
    const mounted_area = try ui.widgets.Textarea(.{ .value = (@as([("abcdefgh").len * (12)]u8, @bitCast(@as([12][("abcdefgh").len]u8, @splat(("abcdefgh").*)))) ++ ""), .width = 100, .rows = 2 }).mountResult(scope, cx);
    textarea = .{ .wrapper = mounted_area.wrapper, .input = mounted_area.input };
    try root.appendChild(cx.allocator, textarea.wrapper);
    return root;
}
pub fn run(io: std.Io) !void {
    const before = Window.liveWindowCount();
    const foreground = GetForegroundWindow();
    {
        const app = try App.init(std.heap.page_allocator, .{ .io = io, .window = .{ .width = 320, .height = 160 } });
        defer app.deinit();
        defer std.log.info("UIA integration teardown stage: {s}", .{stage});
        stage = "native D3D11 device handle interop and lifetime";
        try @import("windows_device_contract.zig").run(app);
        stage = "initial";
        try app.mount(mount);
        try app.frame();
        var metadata: [8]u32 = undefined;
        try require(zenit_windows_contract_editable(app.win.native, inputs[0].element_id_raw, &metadata) == 1);
        try require(metadata[0] == 1 and metadata[1] == 1 and metadata[2] == 5);
        stage = "owner shaped caret geometry preserves bidi visual order";
        const caret_edit = inputs[0].behavior.interaction.a11y.?.editable_text.?;
        try require(caret_edit.set_value.?(caret_edit.context, "A אב B"));
        app.cx.needs_redraw = true;
        try app.frame();
        const carets = try caret_edit.caret_geometry.?(caret_edit.context, app.cx.allocator);
        defer app.cx.allocator.free(carets);
        try require(carets.len > 2);
        var reversed_bytes = false;
        for (carets[1..], carets[0 .. carets.len - 1]) |right, left| {
            try require(right.rect.x >= left.rect.x and right.rect.width == 0 and right.rect.height > 0);
            if (right.offset < left.offset) reversed_bytes = true;
        }
        try require(reversed_bytes);
        try require(caret_edit.set_value.?(caret_edit.context, "A中😀B"));
        app.cx.needs_redraw = true;
        try app.frame();
        const drawable = app.win.getDrawableSize();
        const viewport_scale = app.win.getScaleFactor();
        const transformed_carets = (try app.cx.a11yTextCaretGeometryClipped(inputs[0].element_id_raw, "A中😀B", .{
            .x = 0,
            .y = 0,
            .w = @as(f32, @floatFromInt(drawable[0])) / viewport_scale,
            .h = @as(f32, @floatFromInt(drawable[1])) / viewport_scale,
        })).?;
        defer app.cx.allocator.free(transformed_carets);
        try require(transformed_carets.len >= 4);
        for (transformed_carets) |caret| {
            try require(caret.first.x == caret.last.x and caret.first.y < caret.last.y);
            try require(caret.offset == 0 or caret.offset == 1 or caret.offset == 4 or caret.offset == 8 or caret.offset == 9);
        }
        try require(zenit_windows_contract_editable(app.win.native, inputs[0].element_id_raw, &metadata) == 1);
        stage = "document and current selection read from owned view";
        var text_read: [4]u32 = undefined;
        try require(zenit_windows_contract_document_selection(app.win.native, inputs[0].element_id_raw, &text_read) == 0);
        try require(text_read[0] == 5 and text_read[1] == metadata[3] and text_read[2] == metadata[4]);
        try require(zenit_windows_contract_document_selection(app.win.native, inputs[1].element_id_raw, &text_read) == @as(i32, @bitCast(@as(u32, 0x80040201))));
        stage = "owned Input geometry UTF16 and shaped world placement";
        var geometry_metadata: [4]u32 = undefined;
        var geometry_rect: [4]f32 = undefined;
        const initial_edit = inputs[0].behavior.interaction.a11y.?.editable_text.?;
        const initial_geometry = try initial_edit.geometry_segments.?(initial_edit.context, app.cx.allocator);
        defer app.cx.allocator.free(initial_geometry);
        try require(initial_geometry.len > 0);
        for (initial_geometry, 0..) |piece, index| {
            try require(zenit_windows_contract_geometry(app.win.native, inputs[0].element_id_raw, @intCast(index), &geometry_metadata, &geometry_rect) == 1);
            try require(geometry_metadata[0] == 1 and geometry_metadata[1] == initial_geometry.len);
            const expected_start: u32 = switch (piece.start) {
                0 => 0,
                1 => 1,
                4 => 2,
                8 => 4,
                9 => 5,
                else => return error.ContractFailure,
            };
            const expected_end: u32 = switch (piece.end) {
                0 => 0,
                1 => 1,
                4 => 2,
                8 => 4,
                9 => 5,
                else => return error.ContractFailure,
            };
            try require(geometry_metadata[2] == expected_start and geometry_metadata[3] == expected_end);
            try require(@abs(geometry_rect[0] - piece.rect.x) < 0.01 and @abs(geometry_rect[1] - piece.rect.y) < 0.01);
            try require(@abs(geometry_rect[2] - piece.rect.width) < 0.01 and @abs(geometry_rect[3] - piece.rect.height) < 0.01);
        }
        try require(zenit_windows_contract_geometry(app.win.native, inputs[1].element_id_raw, 0, &geometry_metadata, &geometry_rect) == 0);
        stage = "COM emoji bounds use physical client origin and DPI";
        var screen_rect: [4]f64 = undefined;
        var rect_count: u32 = 0;
        try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 4, &screen_rect, &rect_count) == 0 and rect_count == 1);
        var origin: NativePoint = .{};
        try require(ClientToScreen(zenit_windows_handle(app.win.native).?, &origin) != 0);
        const scale: f64 = app.win.getScaleFactor();
        var found_emoji = false;
        var emoji_rect: ?ui.A11yRect = null;
        for (initial_geometry) |piece| {
            if (piece.start != 4 or piece.end != 8) continue;
            found_emoji = true;
            emoji_rect = piece.rect;
            try require(@abs(screen_rect[0] - (@as(f64, @floatFromInt(origin.x)) + piece.rect.x * scale)) < 0.01);
            try require(@abs(screen_rect[1] - (@as(f64, @floatFromInt(origin.y)) + piece.rect.y * scale)) < 0.01);
            try require(@abs(screen_rect[2] - piece.rect.width * scale) < 0.01 and @abs(screen_rect[3] - piece.rect.height * scale) < 0.01);
        }
        try require(found_emoji);
        try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 2, &screen_rect, &rect_count) == 0 and rect_count == 0);
        stage = "shared external clip reaches COM text bounds";
        const emoji = emoji_rect.?;
        app.cx.setNodeExternalClipRect(inputs[0].id, .{ emoji.x + emoji.width * 0.25, emoji.y, emoji.width * 0.5, emoji.height });
        app.cx.needs_redraw = true;
        try app.frame();
        const partly_visible = (try app.cx.a11yTextCaretCandidates(inputs[0].element_id_raw, "A中😀B", .{
            .x = 0,
            .y = 0,
            .w = @as(f32, @floatFromInt(drawable[0])) / viewport_scale,
            .h = @as(f32, @floatFromInt(drawable[1])) / viewport_scale,
        })).?;
        defer app.cx.allocator.free(partly_visible);
        try require(partly_visible.len == 2);
        try require(partly_visible[0].offset == 4 and partly_visible[1].offset == 8);
        try require(partly_visible[0].visible == null and partly_visible[1].visible == null);
        try require(@abs(partly_visible[0].first.x - emoji.x) < 0.01);
        try require(@abs(partly_visible[1].first.x - emoji.x - emoji.width) < 0.01);
        stage = "native snapshot owns both off-clip emoji caret edges";
        var caret_metadata: [4]u32 = undefined;
        var caret_line: [8]f32 = undefined;
        for (partly_visible, 0..) |candidate, index| {
            try require(zenit_windows_contract_caret(app.win.native, inputs[0].element_id_raw, @intCast(index), &caret_metadata, &caret_line) == 1);
            try require(caret_metadata[0] == 2 and caret_metadata[1] == (if (index == 0) @as(u32, 2) else 4));
            try require(caret_metadata[2] == @intFromBool(candidate.downstream) and caret_metadata[3] == 0);
            try require(@abs(caret_line[0] - candidate.first.x) < 0.01 and @abs(caret_line[1] - candidate.first.y) < 0.01);
            try require(@abs(caret_line[2] - candidate.last.x) < 0.01 and @abs(caret_line[3] - candidate.last.y) < 0.01);
        }
        try require(zenit_windows_contract_caret(app.win.native, inputs[1].element_id_raw, 0, &caret_metadata, &caret_line) == 0);
        stage = "screen point maps partly visible emoji to real UTF16 endpoints";
        var point_range: [2]u32 = undefined;
        for ([_]f64{ 0.4, 0.6 }, [_]u32{ 2, 4 }) |fraction, expected_offset| {
            const x = @as(f64, @floatFromInt(origin.x)) + (emoji.x + emoji.width * fraction) * scale;
            const y = @as(f64, @floatFromInt(origin.y)) + (emoji.y + emoji.height * 0.5) * scale;
            try require(zenit_windows_contract_point(app.win.native, inputs[0].element_id_raw, x, y, &point_range) == 0);
            try require(point_range[0] == expected_offset and point_range[1] == expected_offset);
        }
        try require(zenit_windows_contract_point(app.win.native, inputs[1].element_id_raw, @floatFromInt(origin.x), @floatFromInt(origin.y), &point_range) < 0);
        app.cx.setNodeExternalClipRect(inputs[0].id, .{ emoji.x + emoji.width * 0.5, emoji.y, emoji.width * 0.5, emoji.height });
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 4, &screen_rect, &rect_count) == 0 and rect_count == 1);
        try require(@abs(screen_rect[0] - (@as(f64, @floatFromInt(origin.x)) + (emoji.x + emoji.width * 0.5) * scale)) < 0.01);
        try require(@abs(screen_rect[2] - emoji.width * 0.5 * scale) < 0.01);
        var visible_read: [3]u32 = undefined;
        try require(zenit_windows_contract_visible_ranges(app.win.native, inputs[0].element_id_raw, &visible_read) == 0);
        try require(std.mem.eql(u32, &visible_read, &.{ 1, 2, 4 }));
        app.cx.setNodeExternalClipRect(inputs[0].id, .{ emoji.x - 1000, emoji.y, 1, emoji.height });
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 4, &screen_rect, &rect_count) == 0 and rect_count == 0);
        try require(zenit_windows_contract_editable(app.win.native, inputs[0].element_id_raw, &metadata) == 1);
        try require(zenit_windows_contract_visible_ranges(app.win.native, inputs[0].element_id_raw, &visible_read) == 0);
        try require(visible_read[0] == 1 and visible_read[1] == metadata[5] and visible_read[2] == metadata[5]);
        app.cx.setNodeExternalClipRect(inputs[0].id, null);
        app.cx.needs_redraw = true;
        try app.frame();
        stage = "nested scaled Input reaches COM screen bounds";
        const root_node = app.cx.root.?;
        const root_ext = root_node.style.ensureExtPanic(app.cx.allocator);
        const saved_root = root_ext.*;
        root_ext.scale_x = 1.1;
        root_ext.scale_y = 0.85;
        root_ext.transform_origin = @TypeOf(root_ext.transform_origin).topLeft();
        const input_ext = inputs[0].style.ensureExtPanic(app.cx.allocator);
        const saved_input = input_ext.*;
        input_ext.scale_y = 1.25;
        input_ext.transform_origin = @TypeOf(input_ext.transform_origin).centered();
        const raw_input = inputs[0].globalRect();
        const raw_root = root_node.globalRect();
        for ([_]f32{ 0.75, -0.75 }) |sx| {
            input_ext.scale_x = sx;
            root_node.markRenderDirty();
            inputs[0].markRenderDirty();
            app.cx.needs_redraw = true;
            try app.frame();
            try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 4, &screen_rect, &rect_count) == 0 and rect_count == 1);
            const local_x = if (sx > 0) emoji.x - raw_input.x else emoji.x + emoji.width - raw_input.x;
            const scaled_x = raw_input.x + raw_input.w * 0.5 * (1 - sx) + local_x * sx;
            const scaled_y = raw_input.y + raw_input.h * 0.5 * (1 - 1.25) + (emoji.y - raw_input.y) * 1.25;
            const expected_x = raw_root.x + (scaled_x - raw_root.x) * 1.1;
            const expected_y = raw_root.y + (scaled_y - raw_root.y) * 0.85;
            try require(@abs(screen_rect[0] - (@as(f64, @floatFromInt(origin.x)) + expected_x * scale)) < 0.01);
            try require(@abs(screen_rect[1] - (@as(f64, @floatFromInt(origin.y)) + expected_y * scale)) < 0.01);
            try require(@abs(screen_rect[2] - emoji.width * @abs(sx) * 1.1 * scale) < 0.01);
            try require(@abs(screen_rect[3] - emoji.height * 1.25 * 0.85 * scale) < 0.01);
        }
        stage = "rotated reflected Input uses four transformed emoji corners";
        input_ext.rotate = 0.25;
        inputs[0].markRenderDirty();
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 4, &screen_rect, &rect_count) == 0 and rect_count == 1);
        var low: [2]f64 = @splat(std.math.inf(f64));
        var high: [2]f64 = @splat(-std.math.inf(f64));
        const cx = @as(f64, raw_input.w) * 0.5;
        const cy = @as(f64, raw_input.h) * 0.5;
        for ([_]f64{ emoji.x - raw_input.x, emoji.x + emoji.width - raw_input.x }) |x| {
            for ([_]f64{ emoji.y - raw_input.y, emoji.y + emoji.height - raw_input.y }) |y| {
                const rx = cx + @cos(@as(f64, 0.25)) * (x - cx) - @sin(@as(f64, 0.25)) * (y - cy);
                const ry = cy + @sin(@as(f64, 0.25)) * (x - cx) + @cos(@as(f64, 0.25)) * (y - cy);
                const wx = raw_input.x + cx * 1.75 - rx * 0.75;
                const wy = raw_input.y - cy * 0.25 + ry * 1.25;
                const transformed = [2]f64{ raw_root.x + (wx - raw_root.x) * 1.1, raw_root.y + (wy - raw_root.y) * 0.85 };
                for (transformed, 0..) |p, axis| {
                    low[axis] = @min(low[axis], p);
                    high[axis] = @max(high[axis], p);
                }
            }
        }
        try require(@abs(screen_rect[0] - (@as(f64, @floatFromInt(origin.x)) + low[0] * scale)) < 0.01);
        try require(@abs(screen_rect[1] - (@as(f64, @floatFromInt(origin.y)) + low[1] * scale)) < 0.01);
        try require(@abs(screen_rect[2] - (high[0] - low[0]) * scale) < 0.01);
        try require(@abs(screen_rect[3] - (high[1] - low[1]) * scale) < 0.01);
        stage = "point mapping follows independently transformed reflected emoji carets";
        for ([_]f64{ emoji.x - raw_input.x, emoji.x + emoji.width - raw_input.x }, [_]u32{ 2, 4 }) |x, expected_offset| {
            const y = emoji.y + emoji.height * 0.5 - raw_input.y;
            const rx = cx + @cos(@as(f64, 0.25)) * (x - cx) - @sin(@as(f64, 0.25)) * (y - cy);
            const ry = cy + @sin(@as(f64, 0.25)) * (x - cx) + @cos(@as(f64, 0.25)) * (y - cy);
            const wx = raw_input.x + cx * 1.75 - rx * 0.75;
            const wy = raw_input.y - cy * 0.25 + ry * 1.25;
            const screen_x = @as(f64, @floatFromInt(origin.x)) + (raw_root.x + (wx - raw_root.x) * 1.1) * scale;
            const screen_y = @as(f64, @floatFromInt(origin.y)) + (raw_root.y + (wy - raw_root.y) * 0.85) * scale;
            try require(zenit_windows_contract_point(app.win.native, inputs[0].element_id_raw, screen_x, screen_y, &point_range) == 0);
            try require(point_range[0] == expected_offset and point_range[1] == expected_offset);
        }
        stage = "rotated emoji rejects clip overlap with only its bounding box";
        app.cx.setNodeExternalClipRect(inputs[0].id, .{ @floatCast(low[0] + 0.05), @floatCast(low[1] + 0.05), 0.2, 0.2 });
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 4, &screen_rect, &rect_count) == 0 and rect_count == 0);
        stage = "rotated emoji retains a central partial external clip";
        const clip_x: f32 = @floatCast((low[0] + high[0]) * 0.5 - 0.25);
        const clip_y: f32 = @floatCast((low[1] + high[1]) * 0.5 - 0.25);
        app.cx.setNodeExternalClipRect(inputs[0].id, .{ clip_x, clip_y, 0.5, 0.5 });
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 4, &screen_rect, &rect_count) == 0 and rect_count == 1);
        try require(@abs(screen_rect[0] - (@as(f64, @floatFromInt(origin.x)) + clip_x * scale)) < 0.01);
        try require(@abs(screen_rect[1] - (@as(f64, @floatFromInt(origin.y)) + clip_y * scale)) < 0.01);
        try require(@abs(screen_rect[2] - 0.5 * scale) < 0.01 and @abs(screen_rect[3] - 0.5 * scale) < 0.01);
        app.cx.setNodeExternalClipRect(inputs[0].id, null);
        root_ext.* = saved_root;
        input_ext.* = saved_input;
        root_node.markRenderDirty();
        inputs[0].markRenderDirty();
        app.cx.needs_redraw = true;
        try app.frame();
        stage = "duplicate wrap endpoints retain only the visible row";
        const wrap_node = try ui.box(app.cx, .{ .position = .absolute, .width = .{ .px = 50 }, .height = .{ .px = 80 } }, .{});
        const wrap_ext = try wrap_node.style.ensureExtFallible(app.cx.allocator);
        wrap_ext.inset = .{ .left = .{ .px = 260 }, .top = .{ .px = 0 } };
        wrap_ext.transform_origin = @TypeOf(wrap_ext.transform_origin).topLeft();
        wrap_node.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "😀😀", .editable_text = .{
            .context = wrap_node,
            .selection_start = 0,
            .selection_end = 0,
            .caret = 0,
            .set_selection = noSelection,
            .geometry_segments = wrapFixtureGeometry,
            .caret_geometry = wrapFixtureCarets,
        } };
        try root_node.appendChild(app.cx.allocator, wrap_node);
        app.cx.needs_redraw = true;
        try app.frame();
        const wrap_origin = wrap_node.globalRect();
        for ([_]bool{ false, true }) |rotated| {
            wrap_ext.rotate = if (rotated) std.math.pi / 2.0 else 0;
            app.cx.setNodeExternalClipRect(wrap_node.id, if (rotated)
                .{ wrap_origin.x - 55, wrap_origin.y + 18, 10, 4 }
            else
                .{ wrap_origin.x + 18, wrap_origin.y + 45, 4, 10 });
            wrap_node.markRenderDirty();
            app.cx.needs_redraw = true;
            try app.frame();
            for (0..2) |index| {
                try require(zenit_windows_contract_caret(app.win.native, wrap_node.element_id_raw, @intCast(index), &caret_metadata, &caret_line) == 1);
                try require(caret_metadata[0] == 2 and caret_metadata[1] == (if (index == 0) @as(u32, 2) else 4));
                try require(caret_metadata[2] == 1 and caret_metadata[3] == 0);
            }
            // Probe at the hidden previous-row endpoint. Its offset is shared
            // with the next row's start, but the nearest visible row ends at 4.
            const x = wrap_origin.x + (if (rotated) @as(f64, -30) else 30);
            const y = wrap_origin.y + 30;
            try require(zenit_windows_contract_point(app.win.native, wrap_node.element_id_raw, @as(f64, @floatFromInt(origin.x)) + x * scale, @as(f64, @floatFromInt(origin.y)) + y * scale, &point_range) == 0);
            try require(point_range[0] == 4 and point_range[1] == 4);
        }
        app.cx.setNodeExternalClipRect(wrap_node.id, null);
        wrap_node.behavior.interaction.a11y = null;
        wrap_node.markRenderDirty();
        app.cx.needs_redraw = true;
        try app.frame();
        stage = "rotated fixture AABB reaches client while its polygon does not";
        const client_node = try ui.box(app.cx, .{
            .position = .absolute,
            .width = .{ .px = 20 },
            .height = .{ .px = 20 },
            .rotate = std.math.pi / 4.0,
        }, .{});
        client_node.style.ensureExtPanic(app.cx.allocator).inset = .{ .left = .{ .px = -20 }, .top = .{ .px = -20 } };
        client_node.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "A", .editable_text = .{
            .context = client_node,
            .selection_start = 0,
            .selection_end = 1,
            .caret = 1,
            .set_selection = noSelection,
            .geometry_segments = nodeGeometry,
        } };
        try root_node.appendChild(app.cx.allocator, client_node);
        app.cx.needs_redraw = true;
        try app.frame();
        const client_raw = client_node.globalRect();
        try require(@abs(client_raw.x + 20) < 0.001 and @abs(client_raw.y + 20) < 0.001 and client_raw.w == 20 and client_raw.h == 20);
        try require(zenit_windows_contract_bounds(app.win.native, client_node.element_id_raw, 0, 1, &screen_rect, &rect_count) == 0 and rect_count == 0);
        stage = "rotated fixture triangle reaches actual client boundary";
        client_node.style.translate_x = 5;
        client_node.style.translate_y = 5;
        client_node.markRenderDirty();
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_bounds(app.win.native, client_node.element_id_raw, 0, 1, &screen_rect, &rect_count) == 0 and rect_count == 1);
        const triangle_extent = @sqrt(@as(f64, 200)) - 10;
        try require(@abs(screen_rect[0] - @as(f64, @floatFromInt(origin.x))) < 0.01);
        try require(@abs(screen_rect[1] - @as(f64, @floatFromInt(origin.y))) < 0.01);
        try require(@abs(screen_rect[2] - triangle_extent * scale) < 0.01 and @abs(screen_rect[3] - triangle_extent * scale) < 0.01);
        stage = "fractional logical client edge clips before physical projection";
        const original_size = app.win.getSize();
        try require(app.win.setSizeChecked(319, original_size[1]));
        const client_pixels = app.win.getDrawableSize();
        const edge_scale = app.win.getScaleFactor();
        const client_width = @as(f32, @floatFromInt(client_pixels[0])) / edge_scale;
        std.log.info("UIA client clip: pixels={any}, scale={d}, logical width={d:.6}", .{ client_pixels, edge_scale, client_width });
        client_node.style.translate_x = client_width + 15;
        client_node.markRenderDirty();
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_bounds(app.win.native, client_node.element_id_raw, 0, 1, &screen_rect, &rect_count) == 0 and rect_count == 1);
        try require(@abs(screen_rect[0] - (@as(f64, @floatFromInt(origin.x)) + (@as(f64, client_width) - triangle_extent) * edge_scale)) < 0.01);
        try require(@abs(screen_rect[1] - @as(f64, @floatFromInt(origin.y))) < 0.01);
        try require(@abs(screen_rect[2] - triangle_extent * edge_scale) < 0.01 and @abs(screen_rect[3] - triangle_extent * edge_scale) < 0.01);
        try require(screen_rect[0] + screen_rect[2] <= @as(f64, @floatFromInt(origin.x)) + @as(f64, @floatFromInt(client_pixels[0])) + 0.0001);
        try require(app.win.setSizeChecked(original_size[0], original_size[1]));
        client_node.behavior.interaction.a11y = null;
        app.cx.needs_redraw = true;
        try app.frame();
        const editable = inputs[0].behavior.interaction.a11y.?.editable_text.?;
        try require(editable.set_selection(editable.context, 1, 8));
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, inputs[0].element_id_raw, &metadata) == 1);
        try require(metadata[3] == 1 and metadata[4] == 4 and metadata[5] == 4);
        try require(metadata[6] <= metadata[7] and metadata[7] <= 5);
        stage = "geometry quota preserves current text selection and other controls";
        // A plain semantic fixture avoids the Input model refresh replacing
        // an injected callback before the publication boundary under test.
        const quota_node = try ui.box(app.cx, .{ .width = .{ .px = 1 }, .height = .{ .px = 1 } }, .{});
        quota_node.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "A", .editable_text = .{
            .context = quota_node,
            .selection_start = 0,
            .selection_end = 0,
            .caret = 0,
            .set_selection = fixtureSelection,
            .line_boundaries = fixtureLines,
            .geometry_segments = largeGeometry,
        } };
        try app.cx.root.?.appendChild(app.cx.allocator, quota_node);
        app.cx.needs_redraw = true;
        try app.frame();
        stage = "quota fixture initially has owned geometry";
        try require(zenit_windows_contract_geometry(app.win.native, quota_node.element_id_raw, 0, &geometry_metadata, &geometry_rect) == 1);
        quota_node.behavior.interaction.a11y.?.value_text = "AB";
        quota_node.behavior.interaction.a11y.?.editable_text.?.selection_end = 2;
        quota_node.behavior.interaction.a11y.?.editable_text.?.caret = 2;
        quota_node.behavior.interaction.a11y.?.editable_text.?.geometry_segments = quotaGeometry;
        app.cx.needs_redraw = true;
        try app.frame();
        stage = "quota fixture publishes changed text and selection";
        try require(zenit_windows_contract_editable(app.win.native, quota_node.element_id_raw, &metadata) == 1);
        try require(metadata[0] == 1 and metadata[2] == 2 and metadata[3] == 0 and metadata[4] == 2 and metadata[5] == 2);
        stage = "quota fixture geometry is unknown rather than known empty";
        try require(zenit_windows_contract_bounds(app.win.native, quota_node.element_id_raw, 0, 2, &screen_rect, &rect_count) == uia_not_supported);
        stage = "quota fixture preserves unrelated text and bounds";
        try require(zenit_windows_contract_editable(app.win.native, textarea.input.element_id_raw, &metadata) == 1 and metadata[0] == 1);
        try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 4, &screen_rect, &rect_count) == 0 and rect_count == 1);
        quota_node.behavior.interaction.a11y.?.editable_text.?.geometry_segments = largeGeometry;
        app.cx.needs_redraw = true;
        try app.frame();
        stage = "quota fixture geometry recovers";
        try require(zenit_windows_contract_geometry(app.win.native, quota_node.element_id_raw, 0, &geometry_metadata, &geometry_rect) == 1);
        stage = "pending visual lines preserve current text and selection";
        quota_node.behavior.interaction.a11y.?.value_text = "AB\nCD";
        quota_node.behavior.interaction.a11y.?.multiline = true;
        quota_node.behavior.interaction.a11y.?.editable_text.?.selection_start = 1;
        quota_node.behavior.interaction.a11y.?.editable_text.?.selection_end = 4;
        quota_node.behavior.interaction.a11y.?.editable_text.?.caret = 4;
        quota_node.behavior.interaction.a11y.?.editable_text.?.line_boundaries = pendingLines;
        quota_node.behavior.interaction.a11y.?.editable_text.?.geometry_segments = pendingGeometry;
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, quota_node.element_id_raw, &metadata) == 1);
        try require(metadata[2] == 5 and metadata[3] == 1 and metadata[4] == 4 and metadata[5] == 4);
        try require(zenit_windows_contract_bounds(app.win.native, quota_node.element_id_raw, 0, 5, &screen_rect, &rect_count) == uia_not_supported);
        try require(zenit_windows_contract_document_selection(app.win.native, quota_node.element_id_raw, &text_read) == 0);
        try require(std.mem.eql(u32, &text_read, &.{ 5, 1, 4, 3 }));
        try require(zenit_windows_contract_visible_ranges(app.win.native, quota_node.element_id_raw, &visible_read) == uia_not_supported);
        try require(zenit_windows_contract_bounds(app.win.native, inputs[0].element_id_raw, 2, 4, &screen_rect, &rect_count) == 0 and rect_count == 1);
        stage = "pending visual Line uses current Paragraph rather than stale lines";
        try require(zenit_windows_contract_line_select(app.win.native, quota_node.element_id_raw, 0) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, quota_node.element_id_raw, &metadata) == 1);
        try require(metadata[3] == 0 and metadata[4] == 3 and metadata[5] == 3);
        stage = "visual lines and geometry recover at the current layout";
        quota_node.behavior.interaction.a11y.?.editable_text.?.line_boundaries = fixtureLines;
        quota_node.behavior.interaction.a11y.?.editable_text.?.geometry_segments = largeGeometry;
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_line_select(app.win.native, quota_node.element_id_raw, 0) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, quota_node.element_id_raw, &metadata) == 1);
        try require(metadata[3] == 0 and metadata[4] == 1 and metadata[5] == 1);
        try require(zenit_windows_contract_geometry(app.win.native, quota_node.element_id_raw, 0, &geometry_metadata, &geometry_rect) == 1);
        quota_node.behavior.interaction.a11y = null;
        stage = "aggregate geometry budget preserves all six editable nodes";
        var large_nodes: [6]*ui.Node = undefined;
        for (&large_nodes) |*node| {
            node.* = try ui.box(app.cx, .{ .width = .{ .px = 1 }, .height = .{ .px = 1 } }, .{});
            node.*.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "A", .editable_text = .{
                .context = &geometry_context,
                .selection_start = 0,
                .selection_end = 1,
                .caret = 1,
                .set_selection = noSelection,
                .geometry_segments = largeGeometry,
            } };
            try app.cx.root.?.appendChild(app.cx.allocator, node.*);
        }
        app.cx.needs_redraw = true;
        try app.frame();
        for (large_nodes, 0..) |node, index| {
            try require(zenit_windows_contract_editable(app.win.native, node.element_id_raw, &metadata) == 1);
            try require(metadata[0] == 1 and metadata[2] == 1 and metadata[3] == 0 and metadata[4] == 1 and metadata[5] == 1);
            const found = zenit_windows_contract_geometry(app.win.native, node.element_id_raw, 0, &geometry_metadata, &geometry_rect);
            try require(found == @as(c_int, if (index < 5) 1 else 0));
        }
        stage = "aggregate geometry recovers after other nodes leave the snapshot";
        for (large_nodes[0..5]) |node| node.behavior.interaction.a11y = null;
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_geometry(app.win.native, large_nodes[5].element_id_raw, 0, &geometry_metadata, &geometry_rect) == 1);
        try require(geometry_metadata[0] == 1 and geometry_metadata[1] == ui.A11yProps.max_text_geometry_segments);
        for (large_nodes) |node| node.behavior.interaction.a11y = null;
        app.cx.needs_redraw = true;
        try app.frame();
        stage = "queued caret";
        const input_id = inputs[0].element_id_raw;
        try require(zenit_windows_contract_text_selection(app.win.native, input_id, 2, 2) == 0);
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1 and metadata[5] == 4);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        std.log.info("queued caret metadata={any}", .{metadata});
        try require(metadata[3] == 2 and metadata[4] == 2 and metadata[5] == 2);
        try require(zenit_windows_contract_text_selection(app.win.native, input_id, 3, 4) < 0); // Splits emoji surrogate pair.
        try require(zenit_windows_contract_text_selection(app.win.native, input_id, 0, 6) < 0);
        try require(zenit_windows_contract_text_selection(app.win.native, inputs[1].element_id_raw, 0, 0) < 0);
        try require(zenit_windows_contract_text_selection(app.win.native, input_id, 1, 4) == 0);
        stage = "readonly after acknowledgement";
        inputs[0].behavior.interaction.a11y.?.readonly = true; // Changed after queue acknowledgement.
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1 and metadata[5] == 2);
        try require(metadata[0] == 1 and metadata[1] == 0);
        try require(zenit_windows_contract_text_selection(app.win.native, input_id, 1, 4) < 0);
        inputs[0].behavior.interaction.a11y.?.readonly = false;
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_text_selection(app.win.native, input_id, 1, 4) == 0);
        stage = "changed text after acknowledgement";
        const live = inputs[0].behavior.interaction.a11y.?.editable_text.?;
        try require(live.set_value.?(live.context, "A中😁B")); // Same byte/unit length, different text.
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1 and metadata[5] == 5);
        stage = "reversed selection";
        try require(zenit_windows_contract_text_selection(app.win.native, input_id, 4, 1) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 1 and metadata[4] == 4 and metadata[5] == 1);
        stage = "queue quota";
        for (0..64) |_| try require(zenit_windows_contract_text_selection(app.win.native, input_id, 0, 0) == 0);
        try require(zenit_windows_contract_text_selection(app.win.native, input_id, 0, 0) < 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1 and metadata[5] == 0);
        stage = "COM TextRange Select to live Input";
        try require(zenit_windows_contract_range_select(app.win.native, input_id, 1, 4) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 1 and metadata[4] == 4 and metadata[5] == 4);
        stage = "shared Character boundaries to live Input";
        try require(zenit_windows_contract_character_select(app.win.native, input_id, 2) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 2 and metadata[4] == 4 and metadata[5] == 4);
        stage = "COM whole-range Move to live Input";
        try require(zenit_windows_contract_move_select(app.win.native, input_id, 0, 4, 1) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 1 and metadata[4] == 2 and metadata[5] == 2);
        stage = "shared Word boundaries to live Input";
        try require(zenit_windows_contract_logical_select(app.win.native, input_id, 2, 0) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 2 and metadata[4] == 4 and metadata[5] == 4);
        stage = "shared Paragraph boundaries to live Input";
        try require(zenit_windows_contract_logical_select(app.win.native, input_id, 2, 1) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 0 and metadata[4] == 5 and metadata[5] == 5);
        stage = "single Input visual Line";
        try require(zenit_windows_contract_line_select(app.win.native, input_id, 2) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 0 and metadata[4] == 5 and metadata[5] == 5);
        stage = "real Textarea blank row remains visible away from its caret";
        const row_window_size = app.win.getSize();
        try require(app.win.setSizeChecked(row_window_size[0], 480));
        const row_edit = textarea.input.behavior.interaction.a11y.?.editable_text.?;
        try require(row_edit.set_value.?(row_edit.context, "A\n\n"));
        app.cx.needs_redraw = true;
        try app.frame();
        try app.frame();
        const actual_rows = try row_edit.row_geometry.?(row_edit.context, app.cx.allocator);
        defer app.cx.allocator.free(actual_rows);
        var blank_row: ?ui.A11yProps.TextRowGeometry = null;
        for (actual_rows) |row| if (row.start == 2 and row.end == 3) {
            blank_row = row;
        };
        try require(blank_row != null);
        const blank_rect = blank_row.?.rect;
        stage = "native visible ranges include blank and trailing Textarea rows";
        var row_ranges: [3]u32 = undefined;
        app.cx.setNodeExternalClipRect(textarea.input.id, .{ blank_rect.x + blank_rect.width * 0.5, blank_rect.y + blank_rect.height * 0.25, 1, blank_rect.height * 0.5 });
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_visible_ranges(app.win.native, textarea.input.element_id_raw, &row_ranges) == 0);
        try require(row_ranges[0] == 1 and row_ranges[1] == 2 and row_ranges[2] == 3);
        var blank_point: [2]u32 = undefined;
        try require(zenit_windows_contract_point(app.win.native, textarea.input.element_id_raw, @as(f64, @floatFromInt(origin.x)) + (blank_rect.x + blank_rect.width * 0.5) * scale, @as(f64, @floatFromInt(origin.y)) + (blank_rect.y + blank_rect.height * 0.5) * scale, &blank_point) == 0);
        try require(blank_point[0] == 2 and blank_point[1] == 2);
        const middle_viewport = ui.ComputedRect.init(blank_rect.x + blank_rect.width * 0.5, blank_rect.y + blank_rect.height * 0.25, 1, blank_rect.height * 0.5);
        const visible_rows = (try app.cx.a11yTextRowGeometryClipped(textarea.input.element_id_raw, "A\n\n", middle_viewport)).?;
        defer app.cx.allocator.free(visible_rows);
        try require(visible_rows.len == 1 and visible_rows[0].start == 2 and visible_rows[0].end == 3);
        try require(@abs(visible_rows[0].rect.x - middle_viewport.x) < 0.01 and @abs(visible_rows[0].rect.width - 1) < 0.01);
        const no_caret_ink = (try app.cx.a11yTextCaretGeometryClipped(textarea.input.element_id_raw, "A\n\n", middle_viewport)).?;
        defer app.cx.allocator.free(no_caret_ink);
        try require(no_caret_ink.len == 0);
        app.cx.setNodeExternalClipRect(textarea.input.id, null);
        try require(row_edit.set_value.?(row_edit.context, (@as([("abcdefgh").len * (12)]u8, @bitCast(@as([12][("abcdefgh").len]u8, @splat(("abcdefgh").*)))) ++ "")));
        try require(app.win.setSizeChecked(row_window_size[0], row_window_size[1]));
        app.cx.needs_redraw = true;
        try app.frame();
        try app.frame();
        stage = "wrapped Textarea visual Line";
        const lines_query = textarea.input.behavior.interaction.a11y.?.editable_text.?;
        const narrow = try lines_query.line_boundaries.?(lines_query.context, app.cx.allocator);
        defer app.cx.allocator.free(narrow);
        try require(narrow.len > 2);
        const textarea_id = textarea.input.element_id_raw;
        try require(zenit_windows_contract_line_select(app.win.native, textarea_id, 1) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, textarea_id, &metadata) == 1);
        try require(metadata[3] == 0 and metadata[4] == narrow[1] and metadata[5] == narrow[1]);
        stage = "Textarea width reflow";
        textarea.wrapper.style.width = .{ .px = 220 };
        textarea.input.style.width = .{ .px = 220 };
        textarea.wrapper.markLayoutDirty();
        app.cx.needs_redraw = true;
        try app.frame();
        const wide = try lines_query.line_boundaries.?(lines_query.context, app.cx.allocator);
        defer app.cx.allocator.free(wide);
        try require(wide.len < narrow.len and wide[1] > narrow[1]);
        try require(zenit_windows_contract_line_select(app.win.native, textarea_id, 1) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, textarea_id, &metadata) == 1);
        try require(metadata[3] == 0 and metadata[4] == wide[1] and metadata[5] == wide[1]);
        stage = "plain Textarea Format span";
        try require(zenit_windows_contract_single_unit_select(app.win.native, textarea_id, 1, 0) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, textarea_id, &metadata) == 1);
        try require(metadata[3] == 0 and metadata[4] == 96 and metadata[5] == 96);
        for ([_]c_int{ 0, 1 }) |page| {
            stage = if (page == 0) "plain Input Format span" else "Input Page fallback";
            try require(zenit_windows_contract_single_unit_select(app.win.native, input_id, 2, page) == 0);
            try app.frame();
            try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
            try require(metadata[3] == 0 and metadata[4] == 5 and metadata[5] == 5);
        }
        stage = "Textarea Paragraph includes following empty rows";
        const area_edit = textarea.input.behavior.interaction.a11y.?.editable_text.?;
        try require(area_edit.set_value.?(area_edit.context, "A\n\nB\n\n"));
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_logical_select(app.win.native, textarea_id, 1, 1) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, textarea_id, &metadata) == 1);
        try require(metadata[2] == 6 and metadata[3] == 0 and metadata[4] == 3 and metadata[5] == 3);
        try require(zenit_windows_contract_logical_select(app.win.native, textarea_id, 4, 1) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, textarea_id, &metadata) == 1);
        try require(metadata[3] == 3 and metadata[4] == 6 and metadata[5] == 6);
        stage = "COM degenerate AddToSelection";
        try require(zenit_windows_contract_selection_operation(app.win.native, input_id, 2, 0) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 2 and metadata[4] == 2 and metadata[5] == 2);
        stage = "COM degenerate RemoveFromSelection";
        try require(zenit_windows_contract_selection_operation(app.win.native, input_id, 4, 1) == 0);
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 4 and metadata[4] == 4 and metadata[5] == 4);

        stage = "readonly Textarea ScrollIntoView preserves selection and focus";
        const scroll_edit = textarea.input.behavior.interaction.a11y.?.editable_text.?;
        try require(scroll_edit.set_value.?(scroll_edit.context, (@as([("row\n").len * (20)]u8, @bitCast(@as([20][("row\n").len]u8, @splat(("row\n").*)))) ++ "")));
        try require(scroll_edit.set_selection(scroll_edit.context, 0, 0));
        textarea.input.behavior.interaction.a11y.?.readonly = true;
        app.cx.needs_redraw = true;
        try app.frame();
        const focus_before_scroll = app.cx.focus_manager.getFocused();
        stage = "queue readonly Textarea scroll top";
        const top_result = zenit_windows_contract_scroll(app.win.native, textarea_id, 40, 44, 1);
        std.log.info("readonly scroll top HRESULT={x}", .{@as(u32, @bitCast(top_result))});
        try require(top_result == 0);
        try app.frame();
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, textarea_id, &metadata) == 1);
        stage = "readonly Textarea scroll top metadata";
        std.log.info("scroll top metadata={any} rect={any}", .{ metadata, textarea.input.rectFromWorldOrFallback() });
        try require(metadata[3] == 0 and metadata[4] == 0 and metadata[5] == 0 and metadata[6] == 40 and metadata[7] >= 44);
        try require(app.cx.focus_manager.getFocused() == focus_before_scroll);
        try require(zenit_windows_contract_scroll(app.win.native, textarea_id, 40, 44, 0) == 0);
        try app.frame();
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, textarea_id, &metadata) == 1);
        stage = "readonly Textarea scroll bottom metadata";
        std.log.info("scroll bottom metadata={any}", .{metadata});
        try require(metadata[3] == 0 and metadata[4] == 0 and metadata[5] == 0 and metadata[6] < 40 and metadata[7] >= 43);
        try require(app.cx.focus_manager.getFocused() == focus_before_scroll and GetForegroundWindow() == foreground);
        textarea.input.behavior.interaction.a11y.?.readonly = false;
        stage = "horizontal Input ScrollIntoView preserves caret";
        const horizontal_edit = inputs[0].behavior.interaction.a11y.?.editable_text.?;
        try require(horizontal_edit.set_value.?(horizontal_edit.context, (@as([("abcdefgh").len * (12)]u8, @bitCast(@as([12][("abcdefgh").len]u8, @splat(("abcdefgh").*)))) ++ "")));
        try require(horizontal_edit.set_selection(horizontal_edit.context, 0, 0));
        app.cx.needs_redraw = true;
        try app.frame();
        var before_scroll: ui.A11yRect = undefined;
        var after_scroll: ui.A11yRect = undefined;
        try require(horizontal_edit.frame_for_range.?(horizontal_edit.context, 90, 96, &before_scroll));
        try require(zenit_windows_contract_scroll(app.win.native, input_id, 90, 96, 0) == 0);
        try app.frame();
        try app.frame();
        try require(horizontal_edit.frame_for_range.?(horizontal_edit.context, 90, 96, &after_scroll));
        try require(after_scroll.x < before_scroll.x - 10);
        const input_rect = inputs[0].globalRect();
        try require(after_scroll.x >= input_rect.x and after_scroll.x + after_scroll.width <= input_rect.x + input_rect.w + 1);
        try require(zenit_windows_contract_editable(app.win.native, input_id, &metadata) == 1);
        try require(metadata[3] == 0 and metadata[4] == 0 and metadata[5] == 0 and app.cx.focus_manager.getFocused() == focus_before_scroll);
        try require(horizontal_edit.set_value.?(horizontal_edit.context, "A中😁B"));
        try require(horizontal_edit.set_selection(horizontal_edit.context, 8, 8));
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_editable(app.win.native, inputs[1].element_id_raw, &metadata) == 1);
        for (metadata) |value| try require(value == 0);
        stage = "focus";
        try require(app.cx.focus_manager.getFocused() == inputs[0]);
        try require(GetForegroundWindow() == foreground);
        app.cx.clearFocus();
        try app.frame();
        try require(app.cx.focus_manager.getFocused() == null);
        try require(zenit_windows_contract_focus_redraw(app.win.native, 1) == 1);
        try require(GetForegroundWindow() == foreground);
        try require(zenit_windows_contract_focus_redraw(app.win.native, 0) == 1);
        try require(GetForegroundWindow() == foreground);
        stage = "focus";
        try require(app.cx.focus_manager.getFocused() == null);
        try require(zenit_windows_contract_focus(app.win.native, targets[0].element_id_raw) == 0);
        stage = "focus";
        try require(app.cx.focus_manager.getFocused() == null); // RPC never mutates Cx.
        try app.frame();
        try require(app.cx.focus_manager.getFocused() == targets[0]);
        try require(zenit_windows_contract_focus(app.win.native, targets[1].element_id_raw) == 0);
        targets[1].behavior.interaction.a11y.?.disabled = true; // Change after acknowledgement.
        app.cx.needs_redraw = true;
        try app.frame();
        try require(app.cx.focus_manager.getFocused() == targets[0]);
        try require(zenit_windows_contract_focus(app.win.native, targets[1].element_id_raw) < 0);
        targets[1].behavior.interaction.a11y.?.disabled = false;
        targets[1].behavior.interaction.a11y.?.readonly = true;
        app.cx.needs_redraw = true;
        try app.frame();
        try require(zenit_windows_contract_focus(app.win.native, targets[1].element_id_raw) == 0);
        try app.frame();
        try require(app.cx.focus_manager.getFocused() == targets[1]);
        try require(GetForegroundWindow() == foreground);
    }
    try require(Window.liveWindowCount() == before and GetForegroundWindow() == foreground);
    std.log.info("Windows UIA focus: gain/loss message redraw, provider acknowledgement, owner-frame Cx routing, stale disable rejection and readonly focus, UTF-16 Input selection projection, queued caret selection, COM TextRange selection and Character/Word/Paragraph/visual Line navigation, Textarea width reflow, uniform Format and Page fallback, merged empty paragraph rows, readonly top/bottom and horizontal ScrollIntoView without caret/focus mutation, whole-range Move and single-selection operations, stale text/readonly rejection and password redaction PASS", .{});
}
