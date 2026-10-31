//! Real zenit layout/Button events with fabricated requests and the production
//! broker. No native window, terminal, network or application data is touched.
const std = @import("std");
const ui = @import("ui");
const View = @import("ui/ai_inventory_grant_view.zig");
const approval = @import("ai/inventory_approval.zig");
const grants = @import("ai/inventory_grants.zig");
const host = @import("ai/host_tools.zig");
const identity = @import("host/identity.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *View.View,
    broker: approval.Broker = .{},
    context: host.Context,
    selection: grants.Selection,
    decisions: usize = 0,
    attempts: usize = 0,
    last_decision: ?approval.Decision = null,

    fn init(self: *Fixture, width: f32) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined, .context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 4 }, .binding_revision = 1, .grant_revision = 1 }, .selection = try grants.captureSelection(a, &.{.{ .session_id = @fromBackingInt(4), .generation = 2 }}, &.{}) };
        self.cx.setViewport(width, 360);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .padding = ui.Padding.all(14) }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try View.View.mount(self.cx, self.scope, .{ .context = self, .on_decision = action });
        try self.cx.root.?.appendChild(a, self.view.root);
        try self.view.update(.{});
        self.settle();
    }
    fn deinit(self: *Fixture) void {
        self.broker.clear();
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
    }
    fn action(raw: *anyopaque, ticket: approval.Ticket, value: approval.Decision) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.attempts += 1;
        try self.broker.decide(ticket, value);
        self.decisions += 1;
        self.last_decision = value;
    }
    fn request(self: *Fixture) !void {
        self.context.task_id.bytes[0] +%= 1;
        try self.broker.configure(self.context, 1);
        const json = "{\"scope\":\"workspace\"}";
        const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer parsed.deinit();
        var raw_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(json, &raw_hash, .{});
        const invocation: host.Invocation = .{ .context = self.context, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "inventory-ui-fixture", .tool_id = "host.list_sessions", .arguments = parsed.value, .arguments_json = json, .arguments_hash = raw_hash, .canonical_arguments_hash = try @import("ai/canonical_arguments.zig").digest(a, parsed.value) };
        _ = try self.broker.begin(invocation, self.selection, 1, a);
        try self.refresh();
    }
    fn refresh(self: *Fixture) !void {
        try self.view.update(.{ .pending = self.broker.snapshot() });
        self.settle();
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..4) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn node(self: *Fixture, id: []const u8) *ui.Node {
        return find(self.view.root, id) orelse @panic("missing inventory test node");
    }
    fn click(self: *Fixture, target: *ui.Node) void {
        const r = target.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        self.settle();
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |found| return found;
    return null;
}
fn text(node: *ui.Node) []const u8 {
    return node.getText().?.content;
}

test "inventory view is absent until an actual request and offers exact deny once conversation decisions" {
    for ([_]approval.Decision{ .deny, .allow_once, .allow_conversation }) |decision| {
        var f: Fixture = undefined;
        try f.init(600);
        defer f.deinit();
        try std.testing.expect(f.view.root.style.display == .none);
        try std.testing.expect(f.view.ticket == null);
        try f.request();
        const ticket = f.view.ticket.?;
        try std.testing.expect(f.view.root.style.display == .flex);
        try std.testing.expectEqualStrings(View.explanation, text(f.view.detail));
        f.click(switch (decision) {
            .deny => f.view.deny,
            .allow_once => f.view.allow_once,
            .allow_conversation => f.view.allow_conversation,
        });
        try std.testing.expectEqual(@as(usize, 1), f.decisions);
        try std.testing.expectEqual(decision, f.last_decision.?);
        if (decision == .deny) try std.testing.expectError(error.InventoryApprovalDenied, f.broker.poll(ticket)) else try std.testing.expect(try f.broker.poll(ticket));
        try std.testing.expectEqual(decision == .allow_conversation, f.broker.continuousAllowed());
        f.click(f.view.allow_once);
        try std.testing.expectEqual(@as(usize, 1), f.attempts);
        try f.refresh();
        try std.testing.expect(f.view.root.style.display == .none);
        try std.testing.expect(!f.broker.stopped);
    }
}
test "inventory view keyboard decision uses the same exact ticket" {
    var f: Fixture = undefined;
    try f.init(600);
    defer f.deinit();
    try f.request();
    f.cx.setFocus(f.view.allow_once);
    f.cx.handleKeyDown(.@"return", .{});
    f.settle();
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
    try std.testing.expectEqual(approval.Decision.allow_once, f.last_decision.?);
}
test "inventory view stale callback gives safe feedback and disables repeat decisions" {
    var f: Fixture = undefined;
    try f.init(600);
    defer f.deinit();
    try f.request();
    f.broker.stop();
    f.click(f.view.allow_conversation);
    try std.testing.expectEqual(@as(usize, 0), f.decisions);
    try std.testing.expectEqualStrings("请求已失效，请等待新的请求", text(f.view.feedback));
    try std.testing.expect(f.view.disabled.peek());
    // Native Button background transitions take 150ms; inspect the settled paint.
    for (0..3) |_| f.settle();
    try std.testing.expect(ui.Color.eql(theme.popupAction(), f.view.allow_once.getBackground()));
    const disabled_gradient = f.view.allow_once.style.gradient().?;
    try std.testing.expect(ui.Color.eql(theme.popupAction(), disabled_gradient.from));
    try std.testing.expect(ui.Color.eql(theme.popupAction(), disabled_gradient.to));
    try std.testing.expectEqual(@as(f32, 1), f.view.allow_once.getOpacity());
    f.click(f.view.deny);
    try std.testing.expectEqual(@as(usize, 1), f.attempts);
    try f.refresh();
    try std.testing.expect(f.view.root.style.display == .none);
}
test "inventory view absent and explicitly disabled requests do not dispatch" {
    var f: Fixture = undefined;
    try f.init(600);
    defer f.deinit();
    f.click(f.view.allow_once);
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
    try f.request();
    try f.view.update(.{ .pending = f.broker.snapshot(), .enabled = false, .unavailable_reason = "请求暂时不可用" });
    f.settle();
    for ([_]*ui.Node{ f.view.deny, f.view.allow_once, f.view.allow_conversation }) |button| f.click(button);
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
    try std.testing.expectEqualStrings("请求暂时不可用", text(f.view.feedback));
    try f.refresh();
    try std.testing.expectEqual(.none, f.view.feedback.style.display);
    try std.testing.expect(!f.view.disabled.peek());
}
test "inventory view replacement cancels a captured pointer press" {
    var f: Fixture = undefined;
    try f.init(600);
    defer f.deinit();
    try f.request();
    const r = f.view.allow_once.globalRect();
    f.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
    try f.request();
    f.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
    f.settle();
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
    f.click(f.view.allow_once);
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
}
test "inventory view three themes retain inline title readable copy and all actions at minimum width" {
    defer theme.select(.dark);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        for ([_]f32{ 600, 320 }) |width| {
            var f: Fixture = undefined;
            try f.init(width);
            defer f.deinit();
            try f.request();
            const root = f.view.root.globalRect();
            const title = f.node("ai.inventory_grant.title").globalRect();
            const icon = f.node("ai.inventory_grant.icon").globalRect();
            try std.testing.expectApproxEqAbs(icon.y + icon.h / 2, title.y + title.h / 2, 0.1);
            try std.testing.expect(title.x >= icon.x + icon.w + 5.9);
            const hint = f.node("ai.inventory_grant.hint").globalRect();
            const detail = f.view.detail.globalRect();
            try std.testing.expect(detail.w > 240 and detail.h >= 18);
            try std.testing.expect(hint.y >= detail.y + detail.h);
            for ([_]*ui.Node{ f.view.deny, f.view.allow_once, f.view.allow_conversation }) |button| {
                const r = button.globalRect();
                try std.testing.expect(r.w >= 76 and r.h >= 26);
                try std.testing.expect(r.x >= root.x and r.x + r.w <= root.x + root.w + 0.1);
                try std.testing.expect(r.y >= hint.y + hint.h and r.y + r.h <= root.y + root.h + 0.1);
            }
            const deny = f.view.deny.globalRect();
            const once = f.view.allow_once.globalRect();
            const conversation = f.view.allow_conversation.globalRect();
            try std.testing.expect(deny.x + deny.w + 5.9 <= once.x);
            try std.testing.expect(once.x + once.w + 5.9 <= conversation.x);
            try std.testing.expectApproxEqAbs(root.x + root.w - 11, conversation.x + conversation.w, 0.1);
            try std.testing.expect(root.y + root.h <= 360);
            try std.testing.expectEqual(@as(f32, 0), f.view.root.style.border.width);
        }
    }
}

test "inventory listed cross binding reference cannot upgrade legacy execution or host content authority" {
    const tools = @import("ai/plugin_tools.zig");
    const scope = @import("ai/tool_scope.zig");
    const queries = @import("ai/host_queries.zig");
    const context: host.Context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 4 }, .binding_revision = 1, .grant_revision = 1 };
    const bound: identity.SessionHandle = .{ .session_id = @fromBackingInt(4), .generation = 2 };
    const outside: identity.SessionHandle = .{ .session_id = @fromBackingInt(8), .generation = 1 };
    const selection = try grants.captureSelection(a, &.{ bound, outside }, &.{});
    var controller: grants.Controller = .{};
    const grant = try controller.allowFromUi(try controller.capture(context, selection, 100), context, selection, 100);
    const listed = try queries.sessionRef(a, grant.context, outside);
    defer a.free(listed);
    const snapshot: queries.Snapshot = .{ .context = grant.context, .initial_binding = context.binding, .execution_policy = .{ .execution_mode = .auto, .session_retention = .ask }, .permission_mode = .confirm, .observed_at = 100, .source_revision = selection.revision(), .cursor_key = @splat(3), .sessions = &.{ .{ .handle = bound, .title = "bound", .protocol = "local", .state = "ready", .ready = true }, .{ .handle = outside, .title = "other", .protocol = "ssh", .state = "failed", .ready = false, .current_member = false } }, .groups = &.{}, .inventory_grant = grant };
    try std.testing.expectError(error.TargetNotAuthorized, queries.resolveSession(snapshot, listed));
    const captured: scope.Scope = .{ .owner = context.binding, .members = .{ .ids = .{4} ++ @as([15]u64, @splat(0)), .len = 1 } };
    const Stub = struct {
        fn handler(_: *anyopaque, _: tools.Invocation, _: std.mem.Allocator) !tools.ToolResult {
            return error.UnexpectedHostDispatch;
        }
    };
    var stub: u8 = 0;
    const bindings = [_]tools.ToolBinding{ .{ .plugin_id = "fixture", .definition_id = "run_command", .handler = Stub.handler }, .{ .plugin_id = "fixture", .definition_id = "read_terminal", .handler = Stub.handler } };
    var table = try tools.RequestTable.init(a, captured, @import("ai/legacy_adapter.zig").builtin_definitions[0..2], &.{.{ .owner = bound, .plugin_id = "fixture", .context = &stub, .bindings = &bindings }});
    defer table.deinit();
    try std.testing.expectError(error.ToolCapabilityUnavailable, table.parse(a, "run_command", "{\"session_ids\":[8],\"command\":\"pwd\"}"));
    try std.testing.expectError(error.ToolCapabilityUnavailable, table.parse(a, "read_terminal", "{\"session_ids\":[8]}"));
    const arguments = try std.json.Stringify.valueAlloc(a, .{ .session_ref = listed }, .{});
    defer a.free(arguments);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, arguments, .{});
    defer parsed.deinit();
    // The production content gate must reject before it can access this app.
    // Deliberately no ApplicationHost is initialized and no service is held.
    var unavailable_app: @import("ui/application_host.zig").ApplicationHost = undefined;
    const invocation: host.Invocation = .{ .context = grant.context, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "inventory-isolation", .tool_id = "host.read_terminal", .arguments = parsed.value, .arguments_json = arguments, .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
    try std.testing.expectError(error.TargetNotAuthorized, @import("ui/ai_host_terminal_queries.zig").execute(&unavailable_app, null, .{ .captured_scope = captured, .captured_handles = &.{bound} }, @splat(3), invocation, a));
}

comptime {
    _ = @import("ui/ai_inventory_context.zig");
}
