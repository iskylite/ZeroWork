//! Nested registered editors reuse the same host shell and asset transaction.
//! Opening is deferred until the event handler has returned; the parent editor
//! and all its unsaved fields remain mounted underneath the child modal.
const std = @import("std");
const ui = @import("ui");
const wizard_mod = @import("wizard.zig");
const registry = @import("../host/plugin_registry.zig");
const context = @import("../host/content_context.zig");
const envelopes = @import("../config/connection_envelope.zig");
const identity = @import("../host/identity.zig");

pub const SaveAsset = struct {
    context: *anyopaque,
    save: *const fn (*anyopaque, envelopes.Envelope) anyerror!identity.AssetOwner,
};
pub const Host = struct {
    cx: *ui.Cx,
    parent: *wizard_mod.Wizard,
    child: wizard_mod.Wizard = .{},
    facade: context.EditorHost,
    save_asset: SaveAsset,
    queued: ?u64 = null,
    active: ?context.ChildRequest = null,
    tick_context: ?*TickContext = null,
    const TickContext = struct { host: *Host };
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *wizard_mod.Wizard, source: registry.Registry, save_asset: SaveAsset) !struct { host: *Host, root: *ui.Node } {
        const self = try scope.createState(Host, .{ .cx = cx, .parent = parent, .save_asset = save_asset, .facade = .{ .allocator = cx.allocator, .context = undefined, .open_registered = queue } });
        self.facade.context = self;
        try scope.onCleanup(Host, self, cleanup);
        self.child.setRegistry(source);
        self.child.connection_configs = parent.connection_configs;
        self.child.on_cancel = cancelled;
        self.child.cancel_context = self;
        self.child.on_envelope = submitEnvelope;
        self.child.envelope_context = self;
        self.child.editor_host = &self.facade;
        const root = try self.child.mount(cx, scope);
        // Zig may place the embedded child Wizard at offset zero. Zenit keys
        // hooks by context address, so registering self would collide with the
        // child's viewport hook and silently omit this queue consumer.
        const tick_context = try cx.allocator.create(TickContext);
        self.tick_context = tick_context;
        tick_context.* = .{ .host = self };
        try cx.addAfterLayoutHook(tick_context, tick);
        parent.editor_host = &self.facade;
        return .{ .host = self, .root = root };
    }
    fn cleanup(self: *Host) void {
        if (self.tick_context) |tick_context| {
            self.cx.removeAfterLayoutHook(tick_context);
            self.cx.allocator.destroy(tick_context);
            self.tick_context = null;
        }
        self.parent.editor_host = null;
        self.facade.deinit();
    }
    fn queue(raw: *anyopaque, request: context.ChildRequest) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.queued != null or self.active != null) return error.ChildEditorAlreadyOpen;
        const contribution = self.parent.plugin_registry.find(request.contribution_id) orelse return error.UnknownPlugin;
        if (contribution.connection == null) return error.ConnectionEditorUnavailable;
        self.queued = request.request_id;
        self.cx.requestRedraw();
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const token: *TickContext = @ptrCast(@alignCast(raw));
        const self = token.host;
        const request_id = self.queued orelse return .done;
        self.queued = null;
        // Parent destruction releases its pending request strings. Keep only
        // the request ID across the deferred boundary and reacquire a current
        // request before touching its contribution ID.
        const request = blk: {
            for (self.facade.pending.items) |pending| if (pending.request_id == request_id) {
                for (self.facade.parents.items) |parent| if (parent.id == pending.parent_editor_id and parent.revision == pending.draft_revision) break :blk pending;
            };
            _ = self.facade.complete(request_id, .cancelled, self, deliver) catch false;
            return .done;
        };
        self.active = request;
        self.child.reset() catch |err| {
            self.complete(.{ .failed = @errorName(err) });
            return .done;
        };
        self.child.selectContribution(request.contribution_id) catch |err| {
            self.complete(.{ .failed = @errorName(err) });
            return .done;
        };
        self.child.show();
        return .needs_layout;
    }
    fn deliver(raw: *anyopaque, completion: context.ChildCompletion) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.parent.deliverChild(completion);
    }
    fn complete(self: *Host, result_value: context.ChildResult) void {
        const active = self.active orelse return;
        self.active = null;
        _ = self.facade.complete(active.request_id, result_value, self, deliver) catch {};
    }
    fn cancelled(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.complete(.cancelled);
    }
    fn submitEnvelope(raw: *anyopaque, value: envelopes.Envelope, intent: @import("../host/plugin_ui_contract.zig").SubmitIntent) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (intent == .probe or intent == .temporary) return error.ChildEditorSaveRequired;
        const owner = try self.save_asset.save(self.save_asset.context, value);
        self.complete(.{ .saved = .{ .asset_id = owner.id, .revision = owner.revision } });
    }
};
