//! Isolated production inventory approval view/broker. Fabricated requests
//! only: never constructs ApplicationHost, connects, executes or reads data.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const approval = @import("ai/inventory_approval.zig");
const grants = @import("ai/inventory_grants.zig");
const host = @import("ai/host_tools.zig");
const theme = @import("ui/app_theme.zig");
const Card = @import("ui/ai_inventory_grant_view.zig");
const Composer = @import("ui/ai_composer_controls_view.zig");
var preview_theme: theme.Name = .dark;
var preview_transparency: f32 = 0;
const Preview = struct {
    cx: *ui.Cx,
    broker: approval.Broker = .{},
    authority: host.Context,
    selection: grants.Selection,
    view: ?*Card.View = null,
    composer: ?*Composer.View = null,
    panel: *ui.Node,
    result: *ui.Node,
    pending_refresh: bool = false,
    enabled: bool = true,
    decisions: usize = 0,

    fn decide(raw: *anyopaque, ticket: approval.Ticket, decision: approval.Decision) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        try self.broker.decide(ticket, decision);
        self.decisions += 1;
        const summary = try std.fmt.allocPrint(self.cx.allocator, "{s} · decisions {d} · content 0 · execution 0 · lifecycle 0 · stopped false", .{ @tagName(decision), self.decisions });
        defer self.cx.allocator.free(summary);
        try self.result.setTextContent(self.cx.allocator, summary);
        self.pending_refresh = true;
        self.cx.requestRedraw();
    }
    fn composerAction(raw: *anyopaque, envelope: Composer.Envelope) !void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        switch (envelope.action) {
            .revoke_inventory => |conversation_id| {
                if (!conversation_id.eql(self.authority.conversation_id)) return error.ScopeChanged;
                self.revoke();
            },
            else => return error.ForbiddenFixtureAction,
        }
    }
    fn refresh(self: *Preview) !void {
        const pending = self.broker.snapshot();
        self.panel.setDisplay(if (pending == null) .none else .flex);
        if (self.view) |view| try view.update(.{ .pending = pending, .enabled = self.enabled, .unavailable_reason = if (self.enabled) null else "请求暂时不可用" });
        if (self.composer) |composer| try composer.update(.{ .owner = self.authority.binding, .revision = 1, .editable = false, .inventory_authorized = self.broker.continuousAllowed(), .inventory_conversation_id = self.authority.conversation_id });
    }
    fn request(self: *Preview) void {
        if (self.broker.continuousAllowed()) {
            self.result.setTextContent(self.cx.allocator, "当前对话已持续允许，无需再次审批") catch {};
            self.cx.requestRedraw();
            return;
        }
        self.beginRequest() catch |err| {
            self.result.setTextContent(self.cx.allocator, @errorName(err)) catch {};
        };
        self.cx.requestRedraw();
    }
    fn beginRequest(self: *Preview) !void {
        self.authority.task_id.bytes[0] +%= 1;
        try self.broker.configure(self.authority, 1);
        const json = "{\"scope\":\"workspace\"}";
        const parsed = try std.json.parseFromSlice(std.json.Value, self.cx.allocator, json, .{});
        defer parsed.deinit();
        var raw_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(json, &raw_hash, .{});
        const invocation: host.Invocation = .{ .context = self.authority, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "inventory-preview", .tool_id = "host.list_sessions", .arguments = parsed.value, .arguments_json = json, .arguments_hash = raw_hash, .canonical_arguments_hash = try @import("ai/canonical_arguments.zig").digest(self.cx.allocator, parsed.value) };
        _ = try self.broker.begin(invocation, self.selection, 1, self.cx.allocator);
        self.enabled = true;
        try self.result.setTextContent(self.cx.allocator, "AI 已请求查看其他会话");
        try self.refresh();
    }
    fn toggleEnabled(self: *Preview) void {
        self.enabled = !self.enabled;
        self.refresh() catch {};
        self.cx.requestRedraw();
    }
    fn expire(self: *Preview) void {
        self.broker.stop();
        // Keep the captured view to exercise an expired UI callback.
        self.result.setTextContent(self.cx.allocator, "本次请求已失效") catch {};
        self.cx.requestRedraw();
    }
    fn revoke(self: *Preview) void {
        self.broker.revoke();
        self.result.setTextContent(self.cx.allocator, "已撤销当前对话的持续允许") catch {};
        self.refresh() catch {};
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Preview = @ptrCast(@alignCast(raw));
        if (!self.pending_refresh) return .done;
        self.pending_refresh = false;
        self.refresh() catch {};
        return .needs_layout;
    }
    fn cleanup(self: *Preview) void {
        self.broker.clear();
        self.view = null;
        self.cx.removeAfterLayoutHook(self);
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(preview_theme);
    _ = theme.setMaterialParameters(preview_transparency, 0);
    cx.setTheme(theme.widgetTheme(preview_theme));
    try @import("ui/layer_materials.zig").Policy.mount(cx, scope);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 8, .background = theme.baseColors().app, .padding = .{ .top = 40 } }, .{});
    root.meta.ownership.meta.test_id = "inventory_grant.preview";
    const panel = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = 14, .right = 14, .top = 9, .bottom = 9 }, .background = theme.layerBackground(1), .corner_radius = 11, .flex_shrink = 0 }, .{});
    panel.meta.ownership.meta.test_id = "inventory_grant.preview.panel";
    try root.appendChild(cx.allocator, panel);
    const result = try ui.text(cx, "尚无读取请求", .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = theme.current().fg_2, .wrap = .word });
    result.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
    result.meta.ownership.meta.test_id = "inventory_grant.preview.result";
    const state = try scope.createState(Preview, .{ .cx = cx, .authority = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 4 }, .binding_revision = 1, .grant_revision = 1 }, .selection = try grants.captureSelection(cx.allocator, &.{ .{ .session_id = @fromBackingInt(4), .generation = 2 }, .{ .session_id = @fromBackingInt(8), .generation = 1 } }, &.{.{ .id = 7, .membership_revision = 1, .members = &.{} }}), .panel = panel, .result = result });
    try scope.onCleanup(Preview, state, Preview.cleanup);
    state.view = try Card.View.mount(cx, scope, .{ .context = state, .on_decision = Preview.decide });
    try state.refresh();
    try panel.appendChild(cx.allocator, state.view.?.root);
    const controls = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .flex_wrap = .wrap, .gap = 6, .padding = .{ .left = 14, .right = 14 }, .flex_shrink = 0 }, .{});
    controls.meta.ownership.meta.test_id = "inventory_grant.preview.controls";
    inline for (.{ .{ "触发读取请求", "request", Preview.request }, .{ "切换不可用", "disable", Preview.toggleEnabled }, .{ "使请求失效", "expire", Preview.expire }, .{ "撤销持续允许", "revoke", Preview.revoke } }) |item| {
        const button = try ui.widgets.Button(.{ .variant = .secondary, .label = item[0], .base_style = @import("ui/ai_tool_approval_styles.zig").iconButton(false), .on_click = cx.on(Preview, state, item[2]) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = "inventory_grant.preview." ++ item[1];
        try controls.appendChild(cx.allocator, button);
    }
    try root.appendChild(cx.allocator, controls);
    try root.appendChild(cx.allocator, result);
    const composer_holder = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .left = 14, .right = 14 }, .flex_shrink = 0 }, .{});
    state.composer = try Composer.View.mount(cx, scope, .{ .context = state, .action = Preview.composerAction });
    try composer_holder.appendChild(cx.allocator, state.composer.?.root);
    try root.appendChild(cx.allocator, composer_holder);
    try state.refresh();
    try cx.addAfterLayoutHook(state, Preview.afterLayout);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--theme=")) preview_theme = std.meta.stringToEnum(theme.Name, arg[8..]) orelse return error.InvalidPreviewTheme else if (std.mem.startsWith(u8, arg, "--transparency=")) {
            preview_transparency = try std.fmt.parseFloat(f32, arg[15..]);
            if (!std.math.isFinite(preview_transparency) or preview_transparency < 0 or preview_transparency > 100) return error.InvalidPreviewTransparency;
        } else return error.InvalidOption;
    }
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 600, .height = 420, .title = "ZeroWork Inventory Approval Preview", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
