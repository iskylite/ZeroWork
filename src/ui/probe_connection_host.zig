//! Presents test authentication without borrowing a terminal session or sending
//! challenge answers through VT. The controller keeps the original app key.
const std = @import("std");
const ui = @import("ui");
const Probe = @import("wizard_probe.zig");
const remote_editor = @import("../plugins/remote/editor_factory.zig");
const Wizard = @import("wizard.zig").Wizard;
const RemoteEditor = @import("../plugins/remote/editor.zig").RemoteEditor;
const Bridge = @import("../plugins/remote/challenge_bridge.zig");
const Shared = @import("challenge_window_host.zig").Services;
const Presenter = @import("plugin_challenge_presenter.zig").Presenter;
const TestProgress = @import("wizard_test_progress.zig");
const auth = @import("../proto/ssh/auth_challenge.zig");
const applog = @import("../platform/applog.zig");

pub const Host = struct {
    cx: *ui.Cx,
    controller: *Probe.Controller,
    wizard: ?*Wizard = null,
    remote: ?*RemoteEditor = null,
    authentication: *Presenter,
    challenges: *Shared,
    bridge: Bridge.Bridge = .{},
    last_error: ?anyerror = null,
    totp_clock: @import("../proto/ssh/totp_prefill.zig").Clock = .{},

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, controller: *Probe.Controller, wizard: *Wizard, _: *ui.Node) !*Host {
        return mountOwner(cx, scope, controller, wizard, null);
    }
    /// The existing real-probe tests mount the provider's editor directly.
    pub fn mountRemote(cx: *ui.Cx, scope: *ui.Scope, controller: *Probe.Controller, remote_view: *RemoteEditor, _: *ui.Node) !*Host {
        return mountOwner(cx, scope, controller, null, remote_view);
    }
    fn mountOwner(cx: *ui.Cx, scope: *ui.Scope, controller: *Probe.Controller, wizard: ?*Wizard, remote: ?*RemoteEditor) !*Host {
        const self = try cx.allocator.create(Host);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        const shared = try Shared.mount(cx, scope);
        self.* = .{ .cx = cx, .controller = controller, .wizard = wizard, .remote = remote, .authentication = shared.view, .challenges = shared };
        try scope.onCleanup(Host, self, cleanup);
        registered = true;
        try cx.addAfterLayoutHook(self, hook);
        controller.setInteractionSink(.{ .context = self, .consume = consume });
        return self;
    }
    fn editor(self: *Host) ?*RemoteEditor {
        if (self.remote) |remote| return remote;
        const wizard = self.wizard orelse return null;
        return if (remote_editor.current(wizard)) |current| &current.editor else null;
    }
    fn visible(self: *Host) bool {
        return if (self.wizard) |wizard| wizard.isVisible() else if (self.remote) |remote| remote.isVisible() else false;
    }

    pub fn blocksGlobalActions(self: *const Host) bool {
        return self.bridge.visible();
    }

    fn consume(raw: *anyopaque, _: *Probe.Job) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.cx.requestRedraw();
    }

    fn hook(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.refresh() catch |err| {
            if (self.last_error == null or self.last_error.? != err) applog.warn(.ui, "test authentication presentation failed: {s}", .{@errorName(err)});
            self.last_error = err;
            return .done;
        };
        self.last_error = null;
        return .done;
    }

    fn refresh(self: *Host) !void {
        const current_editor = self.editor() orelse {
            self.controller.cancelAll();
            self.bridge.clear();
            return;
        };
        current_editor.on_cancel_test = cancelTest;
        current_editor.cancel_test_ctx = self;
        try self.presentProgress();
        const request = self.controller.pendingAuthentication() orelse {
            self.bridge.clear();
            return;
        };
        const progress = self.controller.connectionProgress(request.identity.key) orelse return error.StaleAuthentication;
        if (!self.visible() or progress.generation != current_editor.test_generation or progress.draft_id != current_editor.draft_id or progress.draft_revision != current_editor.draft_revision) {
            _ = self.controller.cancelAuthentication(request.identity);
            self.bridge.clear();
            return;
        }
        if (current_editor.test_source) |source| if (!source.value.key.eql(request.identity.key)) {
            self.bridge.clear();
            return;
        };
        const host = self.controller.authenticationHostFor(request.identity) orelse return error.StaleAuthentication;
        const ns = @import("../platform/realtime.zig").monotonicNs();
        try self.bridge.sync(&self.challenges.host, request, .{ .display_name = host.name, .private_key_path = host.identity_file orelse "", .host_key = self.controller.authenticationHostKey(request.identity) }, .{ .context = self, .submit = submit, .cancel = cancel }, @intCast(@max(0, ns) / std.time.ns_per_ms));
        if (self.controller.authenticationTotp(request.identity, self.totp_clock.now()) catch null) |proposed| {
            var value = proposed;
            defer value.deinit();
            if (value.validAt(self.totp_clock.now())) _ = try self.authentication.prefill(Bridge.Bridge.owner(request.identity), request.identity.request_id, Bridge.Bridge.generation(request.identity), value.code.slice(), value.window, value.expires_at_ns, .{ .context = self, .valid = prefillValid });
        }
        self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
    }

    /// Called before Controller.poll may retire a finished Job, so the final
    /// released result remains visible after its protocol owner is destroyed.
    pub fn presentProgress(self: *Host) !void {
        for (self.controller.jobs.items) |job| {
            try self.presentJob(job);
        }
    }

    /// Also call immediately after Controller.poll returns .finished and before
    /// retire. That poll may have completed the final native resource drain.
    pub fn presentJob(self: *Host, job: *Probe.Job) !void {
        const current_editor = self.editor() orelse return;
        const source = job.connectionProgress();
        if (source.generation != current_editor.test_generation or source.draft_id != current_editor.draft_id or source.draft_revision != current_editor.draft_revision) return;
        var hops: [9]TestProgress.Hop = undefined;
        for (source.hops[0..source.hop_count], hops[0..source.hop_count]) |hop, *copy| copy.* = .{ .name = hop.name, .host = hop.host, .user = hop.user, .port = hop.port };
        _ = try current_editor.setTestSnapshot(.{ .protocol = source.protocol, .key = source.key, .generation = source.generation, .draft_id = source.draft_id, .draft_revision = source.draft_revision, .hops = hops[0..source.hop_count], .journal = source.journal, .resources = source.resources, .finished = source.finished, .cancelled = source.cancelled, .failure = source.failure, .cleanup = source.cleanup });
    }

    fn cancelTest(raw: *anyopaque, key: TestProgress.operations.OperationKey) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        const current_editor = self.editor() orelse return;
        const source = self.controller.connectionProgress(key) orelse return;
        if (source.generation != current_editor.test_generation or source.draft_id != current_editor.draft_id or source.draft_revision != current_editor.draft_revision) return;
        _ = self.controller.cancel(key);
        self.cx.requestRedraw();
    }

    fn prefillValid(raw: *anyopaque, window: u64, expires_ns: ?i128) bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        const now = self.totp_clock.now();
        return now.unix_seconds / @import("../proto/ssh/totp.zig").period_seconds == window and (if (expires_ns) |expiry| now.monotonic_ns < expiry else true);
    }
    fn submit(raw: *anyopaque, request: auth.RequestIdentity, reply: auth.Reply) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        try self.controller.submitAuthentication(request, reply);
        self.cx.requestRedraw();
    }

    fn cancel(raw: *anyopaque, request: auth.RequestIdentity) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        _ = self.controller.cancelAuthentication(request);
        self.cx.requestRedraw();
    }

    fn cleanup(self: *Host) void {
        self.controller.setInteractionSink(null);
        self.bridge.clear();
        if (self.editor()) |current_editor| if (current_editor.cancel_test_ctx == @as(?*anyopaque, @ptrCast(self))) {
            current_editor.on_cancel_test = null;
            current_editor.cancel_test_ctx = null;
        };
        self.cx.removeAfterLayoutHook(self);
        self.cx.allocator.destroy(self);
    }
};
