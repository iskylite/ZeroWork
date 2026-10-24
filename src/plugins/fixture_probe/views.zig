//! Only host-owned editor/content slots are touched. Uses existing Vanta styles.
const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const content = @import("../../host/content_context.zig");
const frames = @import("../../host/frame_texture_sink.zig");
const model = @import("model.zig");
const plugin = @import("plugin.zig");
const styles = @import("styles.zig");
const S = styles.host;

const EditorView = struct {
    mount: contract.EditorMount,
    draft: ?model.Editor = null,
    routed: ?*ui.Node = null,
    message: ?*ui.Node = null,
    child_request: ?u64 = null,
    pub fn deinit(self: *EditorView) void {
        self.release();
    }
    fn release(self: *EditorView) void {
        if (self.draft == null) return;
        if (self.mount.editor_host) |host| host.destroyParent(self.mount.editor_id);
        if (self.draft) |*draft| draft.deinit();
        self.draft = null;
        self.routed = null;
        self.message = null;
    }
    fn changed(self: *EditorView) void {
        if (self.mount.editor_host) |host| host.setParentRevision(self.mount.editor_id, self.draft.?.revision) catch {};
        self.mount.events.changed(self.mount.events.context);
    }
    fn name(self: *EditorView, value: []const u8) void {
        self.draft.?.changeName(value) catch return;
        self.changed();
    }
    fn destination(self: *EditorView, value: []const u8) void {
        const draft = &self.draft.?;
        draft.value.destination = draft.arena.allocator().dupe(u8, value) catch return;
        draft.revision = @import("../../host/identity.zig").advance(draft.revision) catch return;
        self.changed();
    }
    fn secret(self: *EditorView, value: []const u8) void {
        self.draft.?.setSecret(value) catch return;
    }
    fn route(self: *EditorView) void {
        const draft = &self.draft.?;
        draft.setRouted(!draft.value.routed) catch return;
        self.routed.?.setDisplay(if (draft.value.routed) .flex else .none);
        self.changed();
    }
    fn child(self: *EditorView) void {
        const host = self.mount.editor_host orelse {
            self.feedback("SSH 子编辑器尚未挂载");
            return;
        };
        self.child_request = host.openChild(self.mount.editor_id, self.draft.?.revision, "ssh", .create) catch |err| {
            self.feedback(@errorName(err));
            return;
        };
    }
    pub fn childCompleted(ptr: *anyopaque, completion: content.ChildCompletion) void {
        const self: *EditorView = @ptrCast(@alignCast(ptr));
        if (self.draft) |*draft| switch (completion.result) {
            .saved => |asset| {
                if (draft.applyChild(completion.request.draft_revision, asset.asset_id, asset.revision) catch false) {
                    self.changed();
                    self.feedback("SSH 配置已引用");
                }
            },
            .cancelled => self.feedback("已取消 SSH 编辑"),
            .failed => |reason| self.feedback(reason),
        };
    }
    fn saved(self: *EditorView) void {
        self.submit(.save);
    }
    fn temporary(self: *EditorView) void {
        self.submit(.temporary);
    }
    fn probe(self: *EditorView) void {
        _ = self.draft.?.beginProbe();
        self.submit(.probe);
    }
    fn submit(self: *EditorView, intent: contract.SubmitIntent) void {
        var arena: std.heap.ArenaAllocator = .init(self.mount.cx.allocator);
        defer arena.deinit();
        const draft_envelope = self.draft.?.snapshot(arena.allocator()) catch |err| {
            self.feedback(@errorName(err));
            return;
        };
        self.mount.events.submit(self.mount.events.context, draft_envelope, intent) catch |err| {
            self.feedback(@errorName(err));
            return;
        };
        self.feedback(if (intent == .save) "已离线保存" else if (intent == .temporary) "已提交临时连接" else "已提交探测");
    }
    fn feedback(self: *EditorView, value: []const u8) void {
        if (self.message) |node| node.setTextContent(self.mount.cx.allocator, value) catch {};
    }
    fn snapshot(ptr: *anyopaque, a: std.mem.Allocator) !@import("../../config/connection_envelope.zig").Envelope {
        const self: *EditorView = @ptrCast(@alignCast(ptr));
        if (self.draft.?.value.routed) {
            const configs = self.mount.connection_configs orelse return error.ConfigurationResolverUnavailable;
            var frozen_route = try self.draft.?.freezeRoute(configs, a);
            defer frozen_route.deinit();
        }
        return self.draft.?.snapshot(a);
    }
    fn clear(ptr: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(ptr));
        if (self.draft) |*draft| draft.clearSecrets();
    }
    fn unmount(ptr: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(ptr));
        self.release();
    }
};
pub fn mountEditor(_: ?*anyopaque, mount: contract.EditorMount) !contract.EditorInstance {
    const cx = mount.cx;
    const state = try cx.bindState(EditorView, .{ .mount = mount });
    state.draft = model.Editor.init(cx.allocator);
    state.draft.?.revision = mount.draft_revision;
    if (mount.editor_host) |host| {
        try host.setParentRevision(mount.editor_id, mount.draft_revision);
        try host.setParentDelivery(mount.editor_id, state, EditorView.childCompleted);
    }
    if (mount.initial) |initial| {
        const decoded = try std.json.parseFromSlice(model.Payload, state.draft.?.arena.allocator(), initial.payload, .{ .allocate = .alloc_always });
        state.draft.?.value = decoded.value;
        state.draft.?.asset_id = initial.id;
        state.draft.?.asset_revision = initial.revision;
        state.draft.?.group_id = initial.group_id;
        state.draft.?.name = try state.draft.?.arena.allocator().dupe(u8, initial.name);
    }
    const root = try ui.boxStyled(cx, S.stack, .{});
    root.meta.ownership.meta.test_id = "fixture.editor";
    try mount.slot.appendChild(cx.allocator, root);
    try root.appendChild(cx.allocator, try ui.textStyled(cx, S.title, "合成画面配置"));
    try field(state, root, "名称", "fixture.name", state.draft.?.name, false, EditorView.name);
    try field(state, root, "目标", "fixture.destination", state.draft.?.value.destination, false, EditorView.destination);
    try root.appendChild(cx.allocator, try ui.textStyled(cx, S.hint, "密码在连接时由宿主请求，不随配置保存"));
    try button(state, root, "SSH 路由选项", "fixture.route", EditorView.route);
    state.routed = try ui.boxStyled(cx, S.stack, .{});
    try root.appendChild(cx.allocator, state.routed.?);
    state.routed.?.setDisplay(if (state.draft.?.value.routed) .flex else .none);
    try state.routed.?.appendChild(cx.allocator, try ui.textStyled(cx, S.hint, "选择已保存的 SSH 配置，或在宿主子编辑器中创建"));
    try button(state, state.routed.?, "新建 SSH 配置", "fixture.child_ssh", EditorView.child);
    state.message = try ui.textStyled(cx, S.hint, "基础模式仅需生命周期服务");
    try root.appendChild(cx.allocator, state.message.?);
    return .{ .context = state, .vtable = &.{ .snapshot = EditorView.snapshot, .clear_secrets = EditorView.clear, .unmount = EditorView.unmount, .child_completed = EditorView.childCompleted } };
}
fn field(state: *EditorView, parent: *ui.Node, label: []const u8, id: []const u8, value: []const u8, secret: bool, comptime changed: *const fn (*EditorView, []const u8) void) !void {
    const mount = state.mount;
    try parent.appendChild(mount.cx.allocator, try ui.textStyled(mount.cx, S.label, label));
    const initial = try mount.scope.createText(value, .{});
    const input = try ui.widgets.Input(.{ .value = initial, .input_type = @as(ui.widgets.input.InputType, if (secret) .password else .text), .on_change = mount.cx.on(EditorView, state, changed) }).mountResult(mount.scope, mount.cx);
    input.node.setStyleInline(mount.cx.allocator, styles.inputSlot());
    input.input_container.setStyleInline(mount.cx.allocator, S.input());
    input.node.meta.ownership.meta.test_id = id;
    try parent.appendChild(mount.cx.allocator, input.node);
}
fn button(state: *EditorView, parent: *ui.Node, label: []const u8, id: []const u8, comptime action: *const fn (*EditorView) void) !void {
    const mount = state.mount;
    const base = try mount.scope.createSignal(ui.BoxStyle, S.disclosure());
    const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = label, .base_style = base, .on_click = mount.cx.on(EditorView, state, action) }).mount(mount.scope, mount.cx);
    node.meta.ownership.meta.test_id = id;
    try node.appendChild(mount.cx.allocator, try ui.textStyled(mount.cx, S.title, label));
    try parent.appendChild(mount.cx.allocator, node);
}

const ContentView = struct {
    mount: contract.ContentMount,
    runtime: *plugin.Runtime,
    label: *ui.Node,
    closed: bool = false,
    image: ?*ui.Node = null,
    fn refresh(self: *ContentView) !void {
        if (self.mount.frame_sink) |sink| {
            if (sink.revision >= self.runtime.frame.revision) return;
            var frame = try self.runtime.copyFrame(self.mount.cx.allocator);
            sink.submit(frame) catch |err| {
                frame.deinit();
                return err;
            };
            _ = try sink.drain();
            if (self.image) |node| {
                node.setImage(.{ .texture_id = sink.texture.? });
                node.markRenderDirty();
            }
        }
    }
    fn update(ptr: *anyopaque, snapshot_update: contract.ContentUpdate) !void {
        const self: *ContentView = @ptrCast(@alignCast(ptr));
        if (self.closed or !self.mount.owner.eql(snapshot_update.owner)) return error.StaleBinding;
        try self.label.setTextContent(self.mount.cx.allocator, snapshot_update.status);
        try self.refresh();
    }
    fn focus(ptr: *anyopaque, focused: bool) void {
        const self: *ContentView = @ptrCast(@alignCast(ptr));
        if (self.closed) return;
        if (self.mount.content_context) |input| input.setFocus(focused, focused);
    }
    fn unmount(ptr: *anyopaque) void {
        const self: *ContentView = @ptrCast(@alignCast(ptr));
        self.closed = true;
        if (self.mount.content_context) |input| input.close();
        if (self.runtime.input == self.mount.content_context) self.runtime.input = null;
        if (self.runtime.frame_sink == self.mount.frame_sink) self.runtime.frame_sink = null;
        if (self.mount.frame_sink) |sink| sink.close() catch {};
    }
};
pub fn mountContent(ptr: ?*anyopaque, mount: contract.ContentMount) !contract.RendererInstance {
    const self: *plugin.Plugin = @ptrCast(@alignCast(ptr.?));
    const runtime = self.runtimeFor(mount.owner) orelse return error.FixtureNotReady;
    if (mount.content_context) |input| input.consumer = .{ .context = runtime, .consume = plugin.Runtime.consume };
    const root = try ui.boxStyled(mount.cx, S.stack, .{});
    root.meta.ownership.meta.test_id = "fixture.canvas";
    try mount.slot.appendChild(mount.cx.allocator, root);
    try root.appendChild(mount.cx.allocator, try ui.textStyled(mount.cx, S.title, "非终端 · 合成工作区"));
    const label = try ui.textStyled(mount.cx, S.hint, "64 × 40 RGBA · 独立生命周期");
    try root.appendChild(mount.cx.allocator, label);
    const state = try mount.cx.bindState(ContentView, .{ .mount = mount, .runtime = runtime, .label = label });
    if (mount.frame_sink) |sink| {
        try state.refresh();
        state.image = try ui.image(mount.cx, sink.texture.?, styles.canvas());
        state.image.?.meta.ownership.meta.test_id = "fixture.rgba";
        try root.appendChild(mount.cx.allocator, state.image.?);
    }
    return .{ .context = state, .vtable = &.{ .update = ContentView.update, .focus_changed = ContentView.focus, .unmount = ContentView.unmount } };
}
