//! Generic v0.3 host seams, exercised by a synthetic read-only provider.
const std = @import("std");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const typed = @import("host/plugin_services.zig");
const identity = @import("host/identity.zig");
const operations = @import("host/operation.zig");
const probes = @import("host/probe_contract.zig");
const probe_host = @import("host/probe_host.zig");
const envelopes = @import("config/connection_envelope.zig");
const content = @import("host/content_context.zig");

const Read = struct { read: *const fn (*anyopaque, typed.Binding) anyerror!u64 };
const WrongRead = struct { read: *const fn (*anyopaque) void };
const read_key: typed.ServiceKey = .{ .name = "synthetic.read" };
const read_definition = typed.Definition.of(Read, read_key);
const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };

const Fixture = struct {
    allocator: std.mem.Allocator,
    host: ?*sessions.SessionHost = null,
    jobs: [probe_host.Host.capacity + 16]Job = undefined,
    job_count: usize = 0,
    ordinary_creates: usize = 0,
    ordinary_cancels: usize = 0,
    ordinary_stale_releases: usize = 0,
    last_create: ?sessions.CreateRequest = null,
    acquired: usize = 0,
    released: usize = 0,
    cancel_receipt: probes.CloseReceipt = .released,
    defer_result_cleanup: bool = false,
    begin_failure: bool = false,
    last_message: [64]u8 = @splat(0),
    const Job = struct {
        request: probes.ProbeRequest,
        step: u8 = 0,
        resources: std.ArrayList([]u8) = .empty,
        cancelled: bool = false,
        result_sent: bool = false,
        late_release: bool = false,
        late_success: bool = false,
    };
    fn manifest(self: *Fixture, with_probe: bool) plugins.PluginManifest {
        return .{
            .id = "synthetic.probe",
            .display_name = "Synthetic read-only probe",
            .connection = .{ .create_kind = .saved_or_temporary, .editor_factory = .{ .shared_editor = "synthetic.editor" }, .validate_payload = validate, .encode = codec, .decode = codec, .migrate = migrate, .probe_factory = if (with_probe) .{ .context = self, .begin = begin, .poll = poll, .cancel = cancel } else null },
            .session_factory = .{ .context = self, .vtable = &.{ .create = create, .cancel = cancelOrdinary, .close = closeOrdinary, .release_stale = stale } },
            .workspace_kind = "synthetic.renderer",
            .content_renderer = "synthetic.renderer",
            .services = &.{read_definition},
            .required_services = &.{read_definition},
        };
    }
    fn renderer() plugins.RendererDefinition {
        return .{ .kind = "synthetic.renderer", .shared_renderer = true };
    }
    fn envelope(payload: []const u8) envelopes.Envelope {
        return .{ .protocol_id = "synthetic.probe", .name = "Synthetic", .payload = payload };
    }
    fn validate(payload: []const u8) !void {
        if (!std.mem.eql(u8, payload, "ok") and !std.mem.eql(u8, payload, "fail")) return error.InvalidSyntheticPayload;
    }
    fn codec(a: std.mem.Allocator, value: envelopes.Envelope) !envelopes.Envelope {
        try validate(value.payload);
        return value.clone(a);
    }
    fn migrate(a: std.mem.Allocator, value: envelopes.Envelope, version: u32) !envelopes.Envelope {
        if (version != 1) return error.UnsupportedPayloadVersion;
        return codec(a, value);
    }
    fn create(raw: *anyopaque, request: sessions.CreateRequest) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.ordinary_creates += 1;
        self.last_create = request;
    }
    fn cancelOrdinary(raw: *anyopaque, _: operations.OperationKey) sessions.CloseReceipt {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.ordinary_cancels += 1;
        return .released;
    }
    fn closeOrdinary(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(raw: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.ordinary_stale_releases += 1;
    }
    fn binding(self: *Fixture, owner: identity.SessionHandle) typed.Binding {
        return typed.Binding.init(Read, read_key, self, &.{ .read = read }, owner, 1);
    }
    fn read(raw: *anyopaque, binding_value: typed.Binding) !u64 {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (!self.host.?.typedBindingIsLive(binding_value)) return error.StaleBinding;
        return 42;
    }
    fn begin(raw: *anyopaque, request: probes.ProbeRequest) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.begin_failure) return error.SyntheticSubmissionRejected;
        if (self.job_count == self.jobs.len) return error.SyntheticCapacity;
        try request.restricted_context.requireOwner(request.handle, request.operation);
        if (!request.token.handle.eql(request.handle) or !request.token.operation.eql(request.operation)) return error.SyntheticIdentityMismatch;
        self.jobs[self.job_count] = .{ .request = request };
        self.job_count += 1;
    }
    fn acquire(self: *Fixture, job: *Job) !void {
        const resource = try self.allocator.alloc(u8, 8);
        errdefer self.allocator.free(resource);
        try job.resources.append(self.allocator, resource);
        self.acquired += 1;
    }
    fn release(self: *Fixture, job: *Job) void {
        for (job.resources.items) |resource| {
            self.allocator.free(resource);
            self.released += 1;
        }
        job.resources.clearRetainingCapacity();
    }
    fn find(self: *Fixture, key: operations.OperationKey) ?*Job {
        for (self.jobs[0..self.job_count]) |*job| if (job.request.operation.eql(key)) return job;
        return null;
    }
    fn poll(raw: *anyopaque, key: operations.OperationKey) !?probes.ProbeUpdate {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        const job = self.find(key) orelse return error.UnknownSyntheticProbe;
        if (job.late_release) {
            self.release(job);
            job.late_release = false;
            if (job.late_success) return .{ .result = .{ .outcome = .succeeded, .safe_message = "late success", .cleanup = .released } };
            return .{ .cleanup = .released };
        }
        if (job.cancelled or job.result_sent) return null;
        const stages = [_]probes.Stage{ .transport, .trust, .authentication, .discovery };
        if (job.step < stages.len) {
            try self.acquire(job);
            const stage = stages[job.step];
            job.step += 1;
            const message = try std.fmt.bufPrint(&self.last_message, "synthetic {s}", .{@tagName(stage)});
            return .{ .progress = .{ .stage = stage, .safe_message = message } };
        }
        job.result_sent = true;
        const receipt: probes.CloseReceipt = if (self.defer_result_cleanup) .unknown else .released;
        if (receipt == .released) self.release(job);
        return .{ .result = .{ .outcome = if (std.mem.eql(u8, job.request.envelope.payload, "fail")) .failed else .succeeded, .safe_message = if (std.mem.eql(u8, job.request.envelope.payload, "fail")) "synthetic discovery failed" else "management discovery verified", .cleanup = receipt } };
    }
    fn cancel(raw: *anyopaque, key: operations.OperationKey) probes.CloseReceipt {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        const job = self.find(key) orelse return .released;
        job.cancelled = true;
        if (!job.request.restricted_context.cancelled()) return .unknown;
        if (self.cancel_receipt == .released) self.release(job);
        return self.cancel_receipt;
    }
    fn deinit(self: *Fixture) void {
        for (self.jobs[0..self.job_count]) |*job| {
            self.release(job);
            job.resources.deinit(self.allocator);
        }
    }
};

test "BMC probe service access freezes owner type thread authorization and reconnect generation" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{ .allocator = a };
    defer fixture.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{fixture.manifest(true)}, &.{Fixture.renderer()});
    defer host.deinit();
    fixture.host = &host;
    const accepted = try host.open(Fixture.envelope("ok"), .{ .request_key = 1, .target = target });
    const access = try host.serviceAccess(accepted.handle);
    try std.testing.expectError(error.ServiceNotReady, access.lookupCurrent(read_definition));
    const wrong_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(999) };
    try std.testing.expectError(error.OwnerMismatch, access.lookup(wrong_owner, read_definition));
    var forged = access;
    forged.owner = wrong_owner;
    try std.testing.expectError(error.OwnerMismatch, forged.lookupCurrent(read_definition));
    try std.testing.expect(try host.readyPlugin(accepted.handle, accepted.operation, &.{fixture.binding(accepted.handle)}));
    const binding = (try access.lookupCurrent(read_definition)).?;
    const service = try binding.borrow(Read, read_key, accepted.handle);
    try std.testing.expectEqual(@as(u64, 42), try service.read(binding.context, binding));
    try std.testing.expectError(error.ServiceTypeMismatch, access.lookupCurrent(typed.Definition.of(WrongRead, read_key)));
    try std.testing.expect((try access.lookupCurrent(typed.Definition.of(Read, .{ .name = "synthetic.unsupported" }))) == null);
    try std.testing.expect((try access.lookupCurrent(typed.Definition.of(Read, .{ .name = read_key.name, .major = 2 }))) == null);
    try host.authorizeService(accepted.handle, read_key, false);
    try std.testing.expectError(error.ServiceDenied, access.lookupCurrent(read_definition));
    try std.testing.expectError(error.StaleBinding, service.read(binding.context, binding));
    try host.authorizeService(accepted.handle, read_key, true);
    try std.testing.expectError(error.StaleBinding, service.read(binding.context, binding));
    const fresh = (try access.lookupCurrent(read_definition)).?;
    try std.testing.expect(fresh.revision > binding.revision);
    const ThreadCheck = struct {
        access: @import("host/session_service_access.zig").SessionServiceAccess,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            _ = self.access.lookupCurrent(read_definition) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var check: ThreadCheck = .{ .access = access };
    const thread = try std.Thread.spawn(.{}, ThreadCheck.run, .{&check});
    thread.join();
    try std.testing.expectEqual(error.ServiceLookupOffMainThread, check.failure.?);
    try std.testing.expect(try host.failed(accepted.handle, accepted.operation, .{ .domain = .transport, .code = "synthetic_disconnect", .cleanup = .released, .safe_message = "disconnected" }));
    const reconnected = try host.retry(accepted.handle);
    try std.testing.expectEqual(accepted.handle.session_id, reconnected.handle.session_id);
    try std.testing.expectEqual(accepted.handle.generation + 1, reconnected.handle.generation);
    try std.testing.expectError(error.StaleSession, access.lookupCurrent(read_definition));
    try std.testing.expect(!host.typedBindingIsLive(fresh));
    const next_access = try host.serviceAccess(reconnected.handle);
    try std.testing.expectError(error.ServiceNotReady, next_access.lookupCurrent(read_definition));
    try std.testing.expect(try host.readyPlugin(reconnected.handle, reconnected.operation, &.{fixture.binding(reconnected.handle)}));
    _ = (try next_access.lookupCurrent(read_definition)).?;
}

test "BMC probe uses actual unified IDs child operations frozen envelope and cannot attach export or render" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{ .allocator = a };
    defer fixture.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{fixture.manifest(true)}, &.{Fixture.renderer()});
    defer host.deinit();
    fixture.host = &host;
    host.session_ids.next_value = 70;
    var probes_host = probe_host.Host.init(a, &host);
    defer probes_host.deinit() catch unreachable;
    const parent = try host.journal.begin(.app, null);
    const editor = try probes_host.bindEditor(1, parent, 7);
    var payload = [_]u8{ 'o', 'k' };
    const token = try editor.begin(Fixture.envelope(&payload), 7);
    payload[0] = 'X';
    try std.testing.expectEqual(@as(u64, 70), @backingInt(token.handle.session_id));
    try std.testing.expectEqual(token.handle, token.operation.owner.session);
    try std.testing.expect(!token.operation.eql(parent));
    try std.testing.expectEqual(parent, fixture.jobs[0].request.parent_editor_operation);
    try std.testing.expectEqualStrings("ok", fixture.jobs[0].request.envelope.payload);
    try std.testing.expectEqual(token.handle, fixture.jobs[0].request.restricted_context.owner);
    try std.testing.expectEqual(token.operation, fixture.jobs[0].request.restricted_context.operation);
    try std.testing.expect(!@hasField(probes.ProbeContext, "presentation"));
    try std.testing.expect(!@hasField(probes.ProbeContext, "resource_actions"));
    try std.testing.expect(!@hasField(probes.ProbeContext, "input"));
    try std.testing.expect(!@hasField(probes.ProbeContext, "frame_sink"));
    const state = host.queryState(token.handle).?;
    try std.testing.expectEqual(sessions.PresentationPolicy.probe, state.presentation_policy);
    try std.testing.expectEqual(sessions.SessionPurpose.interactive, state.purpose);
    try std.testing.expect(state.attachment == null);
    try std.testing.expect(!host.allowsContent(token.handle));
    try std.testing.expect(!try host.attached(token.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }));
    try std.testing.expect(host.typedBindingsFor(token.handle) == null);
    try std.testing.expect(host.queryService(token.handle, .lifecycle) == .unsupported);
    try std.testing.expect(host.queryTypedService(token.handle, Read, read_key) == .unsupported);
    try std.testing.expectError(error.ContentPresentationForbidden, host.queryBinding(token.handle, read_definition));
    try std.testing.expectError(error.ContentPresentationForbidden, host.serviceAccess(token.handle));
    try std.testing.expectError(error.ContentPresentationForbidden, host.readyPlugin(token.handle, token.operation, &.{fixture.binding(token.handle)}));
    try std.testing.expect(!try host.readyPlugin(try token.handle.nextGeneration(), token.operation, &.{}));
    try std.testing.expectEqual(@as(usize, 0), fixture.ordinary_stale_releases);
    try std.testing.expectError(error.ContentPresentationForbidden, host.bindTypedService(token.handle, token.operation, fixture.binding(token.handle)));
    try std.testing.expectError(error.ProbeHostRequired, host.requestClose(token.handle, .{}));
    const capabilities = (try host.capabilitySnapshot(token.handle)).?;
    try std.testing.expect(!capabilities.services[0].declared and !capabilities.services[0].available);
    try std.testing.expectEqual(@as(usize, 0), fixture.ordinary_creates);
    var forged_token = token;
    forged_token.operation = parent;
    try std.testing.expectError(error.StaleProbeToken, editor.cancel(forged_token));
    const another_parent = try host.journal.begin(.app, null);
    const another_editor = try probes_host.bindEditor(2, another_parent, 7);
    try std.testing.expectError(error.ProbeOwnerMismatch, another_editor.snapshot(token, a));
    const normal = try host.open(Fixture.envelope("ok"), .{ .request_key = 1, .target = target });
    try std.testing.expectEqual(@as(u64, 71), @backingInt(normal.handle.session_id));
    try std.testing.expectEqual(@as(usize, 1), fixture.ordinary_creates);
    try std.testing.expectEqual(probes.CloseReceipt.released, try editor.cancel(token));
    try std.testing.expectEqual(sessions.Lifecycle.closed, host.queryState(token.handle).?.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), fixture.ordinary_cancels);
}

test "BMC probe success and failure publish only after release with owned snapshots" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{ .allocator = a, .defer_result_cleanup = true };
    defer fixture.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{fixture.manifest(true)}, &.{Fixture.renderer()});
    defer host.deinit();
    var probes_host = probe_host.Host.init(a, &host);
    defer probes_host.deinit() catch unreachable;
    const editor = try probes_host.bindEditor(1, try host.journal.begin(.app, null), 1);
    const token = try editor.begin(Fixture.envelope("ok"), 1);
    try std.testing.expectEqual(@as(usize, 0), fixture.acquired);
    try std.testing.expect(try probes_host.poll());
    var progress = try editor.snapshot(token, a);
    defer progress.deinit();
    try std.testing.expectEqualStrings("synthetic transport", progress.value.safe_message);
    @memset(&fixture.last_message, 'X');
    try std.testing.expectEqualStrings("synthetic transport", progress.value.safe_message);
    for (0..4) |_| _ = try probes_host.poll();
    var pending = try editor.snapshot(token, a);
    defer pending.deinit();
    try std.testing.expect(!pending.value.complete and pending.value.outcome == null);
    try std.testing.expectEqual(probes.CloseReceipt.unknown, pending.value.cleanup);
    try std.testing.expect(!host.journal.isTerminal(token.operation));
    fixture.find(token.operation).?.late_release = true;
    _ = try probes_host.poll();
    var finished = try editor.snapshot(token, a);
    defer finished.deinit();
    try std.testing.expect(finished.value.complete and finished.value.applies_to_draft);
    try std.testing.expectEqual(probes.Outcome.succeeded, finished.value.outcome.?);
    try std.testing.expectEqualStrings("management discovery verified", finished.value.safe_message);
    try std.testing.expect(host.journal.isTerminal(token.operation));
    fixture.defer_result_cleanup = false;
    const failed = try editor.begin(Fixture.envelope("fail"), 1);
    for (0..5) |_| _ = try probes_host.poll();
    var failure = try editor.snapshot(failed, a);
    defer failure.deinit();
    try std.testing.expectEqual(probes.Outcome.failed, failure.value.outcome.?);
    try std.testing.expectEqualStrings("synthetic discovery failed", failure.value.safe_message);
    try std.testing.expect(failure.value.complete);
    try std.testing.expectEqual(fixture.acquired, fixture.released);
}

test "BMC probe cancellation releases each stage and rejected submission closes its real scope" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{ .allocator = a };
    defer fixture.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{fixture.manifest(true)}, &.{Fixture.renderer()});
    defer host.deinit();
    var probes_host = probe_host.Host.init(a, &host);
    defer probes_host.deinit() catch unreachable;
    const editor = try probes_host.bindEditor(1, try host.journal.begin(.app, null), 1);
    const stages = [_]probes.Stage{ .accepted, .transport, .trust, .authentication, .discovery };
    for (stages, 0..) |stage, steps| {
        const token = try editor.begin(Fixture.envelope("ok"), 1);
        for (0..steps) |_| _ = try probes_host.poll();
        var before = try editor.snapshot(token, a);
        defer before.deinit();
        try std.testing.expectEqual(stage, before.value.stage);
        try std.testing.expectEqual(probes.CloseReceipt.released, try editor.cancel(token));
        try std.testing.expectEqual(probes.CloseReceipt.released, try editor.cancel(token));
        var after = try editor.snapshot(token, a);
        defer after.deinit();
        try std.testing.expect(after.value.complete);
        try std.testing.expectEqual(probes.Outcome.cancelled, after.value.outcome.?);
        try std.testing.expectEqual(@as(usize, 0), fixture.find(token.operation).?.resources.items.len);
        try std.testing.expectEqual(sessions.Lifecycle.closed, host.queryState(token.handle).?.lifecycle);
    }
    fixture.begin_failure = true;
    const rejected = try editor.begin(Fixture.envelope("ok"), 1);
    var failure = try editor.snapshot(rejected, a);
    defer failure.deinit();
    try std.testing.expect(failure.value.complete);
    try std.testing.expectEqual(probes.Outcome.failed, failure.value.outcome.?);
    try std.testing.expectEqualStrings("SyntheticSubmissionRejected", failure.value.safe_message);
    try std.testing.expectEqual(sessions.Lifecycle.closed, host.queryState(rejected.handle).?.lifecycle);
    try std.testing.expectEqual(fixture.acquired, fixture.released);
}

test "BMC probe older drafts and destroyed editors retain unknown cleanup without late backfill" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{ .allocator = a, .cancel_receipt = .unknown };
    defer fixture.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{fixture.manifest(true)}, &.{Fixture.renderer()});
    defer host.deinit();
    var probes_host = probe_host.Host.init(a, &host);
    defer probes_host.deinit() catch unreachable;
    const editor = try probes_host.bindEditor(9, try host.journal.begin(.app, null), 1);
    const Driver = struct {
        fn open(_: *anyopaque, _: content.ChildRequest) !void {}
    };
    var driver: u8 = 0;
    var editor_host: content.EditorHost = .{ .allocator = a, .context = &driver, .open_registered = Driver.open, .probes = editor };
    defer editor_host.deinit();
    try editor_host.setParentRevision(9, 1);
    const stale = try editor_host.probes.?.begin(Fixture.envelope("ok"), 1);
    try editor_host.setParentRevision(9, 2);
    try std.testing.expectError(error.StaleDraft, editor.begin(Fixture.envelope("ok"), 1));
    const current = try editor.begin(Fixture.envelope("ok"), 2);
    for (0..5) |_| _ = try probes_host.poll();
    var old_result = try editor.snapshot(stale, a);
    defer old_result.deinit();
    var new_result = try editor.snapshot(current, a);
    defer new_result.deinit();
    try std.testing.expect(old_result.value.complete and !old_result.value.applies_to_draft);
    try std.testing.expect(new_result.value.complete and new_result.value.applies_to_draft);
    const pending = try editor.begin(Fixture.envelope("ok"), 2);
    for (0..3) |_| _ = try probes_host.poll();
    editor_host.destroyParent(9);
    try std.testing.expectEqual(sessions.Lifecycle.cleanup_unknown, host.queryState(pending.handle).?.lifecycle);
    var unknown = try editor.snapshot(pending, a);
    defer unknown.deinit();
    try std.testing.expect(!unknown.value.complete and !unknown.value.applies_to_draft and unknown.value.outcome == null);
    try std.testing.expectError(error.ProbeEditorDestroyed, editor.begin(Fixture.envelope("ok"), 2));
    try std.testing.expectError(error.ProbeCleanupPending, probes_host.deinit());
    const job = fixture.find(pending.operation).?;
    job.late_release = true;
    job.late_success = true;
    _ = try probes_host.poll();
    var late = try editor.snapshot(pending, a);
    defer late.deinit();
    try std.testing.expect(late.value.complete and !late.value.applies_to_draft);
    try std.testing.expectEqual(probes.Outcome.cancelled, late.value.outcome.?);
    try std.testing.expectEqual(sessions.Lifecycle.closed, host.queryState(pending.handle).?.lifecycle);
    try std.testing.expect(host.queryState(pending.handle).?.attachment == null);
    try std.testing.expectEqual(fixture.acquired, fixture.released);
}

test "BMC probe optional factory leaves older ordinary connection behavior intact" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{ .allocator = a };
    defer fixture.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{fixture.manifest(false)}, &.{Fixture.renderer()});
    defer host.deinit();
    var probes_host = probe_host.Host.init(a, &host);
    defer probes_host.deinit() catch unreachable;
    const editor = try probes_host.bindEditor(1, try host.journal.begin(.app, null), 1);
    try std.testing.expectError(error.ProbeNotSupported, editor.begin(Fixture.envelope("ok"), 1));
    try std.testing.expectEqual(@as(usize, 0), host.sessions.items.len);
    const accepted = try host.open(Fixture.envelope("ok"), .{ .request_key = 1, .target = target });
    try std.testing.expectEqual(@as(usize, 1), fixture.ordinary_creates);
    try std.testing.expect(try host.readyPlugin(accepted.handle, accepted.operation, &.{fixture.binding(accepted.handle)}));
    try std.testing.expect(try host.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }));
    try std.testing.expectEqual(sessions.Lifecycle.attached, host.queryState(accepted.handle).?.lifecycle);
}

test "BMC probe capacity recycles destroyed editor slots and safely rejects old facades" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{ .allocator = a };
    defer fixture.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{fixture.manifest(true)}, &.{Fixture.renderer()});
    defer host.deinit();
    var probes_host = probe_host.Host.init(a, &host);
    defer probes_host.deinit() catch unreachable;
    const parent = try host.journal.begin(.app, null);
    const original = try probes_host.bindEditor(1, parent, 1);
    original.destroy();
    for (0..probe_host.Host.capacity + 8) |_| {
        // Reuse the public ID, operation and draft, so only the host ticket
        // distinguishes the current editor from an arbitrarily old facade.
        const editor = try probes_host.bindEditor(1, parent, 1);
        try std.testing.expect(editor.ticket != original.ticket);
        try std.testing.expectError(error.StaleProbeEditor, original.begin(Fixture.envelope("ok"), 1));
        editor.destroy();
    }
    try std.testing.expectEqual(@as(usize, 1), probes_host.editors.items.len);
    const current = try probes_host.bindEditor(1, parent, 1);
    const token = try current.begin(Fixture.envelope("ok"), 1);
    try std.testing.expectError(error.StaleProbeEditor, original.snapshot(token, a));
    try std.testing.expectError(error.StaleProbeEditor, original.cancel(token));
    try std.testing.expectError(error.StaleProbeEditor, original.setDraftRevision(2));
    original.destroy();
    try current.setDraftRevision(2);
    var live = try current.snapshot(token, a);
    defer live.deinit();
    try std.testing.expect(!live.value.complete);
    try std.testing.expectEqual(probes.CloseReceipt.released, try current.cancel(token));
}

test "BMC probe capacity reclaims completed history across more than 128 sequential completions" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{ .allocator = a };
    defer fixture.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{fixture.manifest(true)}, &.{Fixture.renderer()});
    defer host.deinit();
    var probes_host = probe_host.Host.init(a, &host);
    defer probes_host.deinit() catch unreachable;
    const editor = try probes_host.bindEditor(1, try host.journal.begin(.app, null), 1);
    var oldest: ?probes.ProbeToken = null;
    for (0..probe_host.Host.capacity + 8) |_| {
        const token = try editor.begin(Fixture.envelope("ok"), 1);
        if (oldest == null) oldest = token;
        for (0..5) |_| _ = try probes_host.poll();
        var completed = try editor.snapshot(token, a);
        defer completed.deinit();
        try std.testing.expect(completed.value.complete);
        try std.testing.expectEqual(probes.Outcome.succeeded, completed.value.outcome.?);
        try std.testing.expect(probes_host.entries.items.len <= probe_host.Host.capacity);
    }
    try std.testing.expectError(error.StaleProbeToken, editor.snapshot(oldest.?, a));
    try std.testing.expectError(error.StaleProbeToken, editor.cancel(oldest.?));
    try std.testing.expectEqual(fixture.acquired, fixture.released);
}

test "BMC probe capacity keeps unknown cleanup pinned until release before reusing its editor" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{ .allocator = a, .cancel_receipt = .unknown };
    defer fixture.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{fixture.manifest(true)}, &.{Fixture.renderer()});
    defer host.deinit();
    var probes_host = probe_host.Host.init(a, &host);
    defer probes_host.deinit() catch unreachable;
    const parent = try host.journal.begin(.app, null);
    const original = try probes_host.bindEditor(1, parent, 1);
    var oldest: ?probes.ProbeToken = null;
    for (0..probe_host.Host.capacity) |_| {
        const token = try original.begin(Fixture.envelope("ok"), 1);
        if (oldest == null) oldest = token;
        try std.testing.expectEqual(probes.CloseReceipt.unknown, try original.cancel(token));
    }
    original.destroy();
    const current = try probes_host.bindEditor(1, parent, 1);
    try std.testing.expectEqual(@as(usize, 2), probes_host.editors.items.len);
    try std.testing.expectError(error.ProbeCapacity, current.begin(Fixture.envelope("ok"), 1));
    var pending = try original.snapshot(oldest.?, a);
    defer pending.deinit();
    try std.testing.expect(!pending.value.complete);
    fixture.find(oldest.?.operation).?.late_release = true;
    _ = try probes_host.poll();
    const replacement = try current.begin(Fixture.envelope("ok"), 1);
    try std.testing.expectError(error.StaleProbeToken, original.snapshot(oldest.?, a));
    try std.testing.expectEqual(probes.CloseReceipt.unknown, try current.cancel(replacement));
    for (fixture.jobs[0..fixture.job_count]) |*job| job.late_release = true;
    _ = try probes_host.poll();
    const recycled = try probes_host.bindEditor(2, parent, 1);
    try std.testing.expectEqual(@as(usize, 2), probes_host.editors.items.len);
    try std.testing.expectError(error.StaleProbeEditor, original.setDraftRevision(2));
    original.destroy();
    try recycled.setDraftRevision(2);
    try current.setDraftRevision(2);
}
