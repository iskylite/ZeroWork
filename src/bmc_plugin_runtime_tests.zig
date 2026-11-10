const std = @import("std");
const T = std.testing;
const a = T.allocator;
const plugin_api = @import("plugins/bmc_ikvm/plugin.zig");
const runtime_api = @import("plugins/bmc_ikvm/runtime.zig");
const console = @import("plugins/bmc_ikvm/console_service.zig");
const controller = @import("plugins/bmc_ikvm/controller.zig");
const framebuffer = @import("plugins/bmc_ikvm/framebuffer.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const sessions = @import("host/session_host.zig");
const contexts = @import("host/host_context.zig");
const challenges = @import("host/challenge_host.zig");
const budgets = @import("host/frame_budget.zig");
const journal = @import("plugins/bmc_ikvm/management_journal.zig");
const tls = @import("host/tls_trust.zig");
const tools = @import("plugins/bmc_ikvm/tools.zig");
const ai = @import("ai/plugin_tools.zig");
const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(21), .workspace_id = @fromBackingInt(8) };
const envelope: @import("config/connection_envelope.zig").Envelope = .{ .protocol_id = "bmc_ikvm", .name = "fixture BMC", .payload = "{\"endpoint\":{\"host\":\"bmc.invalid\"},\"username\":\"fixture\"}" };

fn pause() void {
    var fds: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&fds, 0, 1);
}
fn packet(payload: []const u8) ![]u8 {
    if (payload.len >= 126) return error.FixtureTooLarge;
    const bytes = try a.alloc(u8, payload.len + 2);
    bytes[0] = 0x82;
    bytes[1] = @intCast(payload.len);
    @memcpy(bytes[2..], payload);
    return bytes;
}
fn helloPacket() ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, "RFB 003.008\n");
    try bytes.appendSlice(a, &.{ 105, 1, 0, 99, 104, 0, 0, 0, 1, 1, 0, 0, 0, 0 });
    try bytes.appendSlice(a, &.{ 0, 1, 0, 1 });
    var format: [16]u8 = undefined;
    (controller.video.rfb.raw.PixelFormat{}).write(&format);
    try bytes.appendSlice(a, &format);
    try bytes.appendSlice(a, &.{ 0, 0, 0, 0 });
    return packet(bytes.items);
}
const Fixture = struct {
    runtime: ?*runtime_api.Runtime = null,
    creator: std.Thread.Id,
    allow_begin: std.atomic.Value(bool) = .init(false),
    began: std.atomic.Value(bool) = .init(false),
    allow_frame: std.atomic.Value(bool) = .init(false),
    cleanup_unknown: std.atomic.Value(bool) = .init(false),
    cleanup_calls: std.atomic.Value(usize) = .init(0),
    credential_calls: std.atomic.Value(usize) = .init(0),
    aborted: std.atomic.Value(bool) = .init(false),
    abort_calls: std.atomic.Value(usize) = .init(0),
    trust_challenge: bool = false,
    trust_verification: tls.VerificationResult = .{ .failures = .{ .untrusted_issuer = true } },
    hello: []u8,
    frame: []u8,
    hello_offset: usize = 0,
    frame_offset: usize = 0,
    fn init() !Fixture {
        const hello = try helloPacket();
        errdefer a.free(hello);
        return .{ .creator = std.Thread.getCurrentId(), .hello = hello, .frame = try packet(&.{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 2, 3, 0 }) };
    }
    fn deinit(self: *Fixture) void {
        a.free(self.hello);
        a.free(self.frame);
    }
    fn begin(raw: *anyopaque, _: *const controller.model.Payload, plan: *const controller.route.Plan, operation: svc.OperationKey, cancel: *const std.atomic.Value(bool)) !controller.video.rfb.Authenticated {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (std.Thread.getCurrentId() == self.creator) return error.NativeIoOnConfigurationThread;
        self.began.store(true, .release);
        // Deliberately permit a late successful completion after cancellation.
        while (!self.allow_begin.load(.acquire)) pause();
        if (self.trust_challenge) {
            const runtime = self.runtime.?;
            const choice = try runtime_api.ChallengeBridge.trustReply(&runtime.bridge, .{ .id = 71, .owner = plan.owner, .operation = operation, .authority = try tls.canonicalize(.{ .host = "bmc.invalid" }), .verification = self.trust_verification }, cancel);
            if (choice == .reject) return error.TrustRejected;
            _ = self.credential_calls.fetchAdd(1, .acq_rel);
            var password = try runtime_api.ChallengeBridge.passwordReply(&runtime.bridge, plan.owner, operation, cancel, a);
            password.deinit();
        }
        return .{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true };
    }
    fn read(raw: *anyopaque, bytes: []u8) !usize {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.hello_offset < self.hello.len) {
            const n = @min(bytes.len, self.hello.len - self.hello_offset);
            @memcpy(bytes[0..n], self.hello[self.hello_offset..][0..n]);
            self.hello_offset += n;
            return n;
        }
        if (self.allow_frame.load(.acquire) and self.frame_offset < self.frame.len) {
            const n = @min(bytes.len, self.frame.len - self.frame_offset);
            @memcpy(bytes[0..n], self.frame[self.frame_offset..][0..n]);
            self.frame_offset += n;
            return n;
        }
        return error.WouldBlock;
    }
    fn write(_: *anyopaque, bytes: []const u8) !usize {
        return bytes.len;
    }
    fn abort(raw: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.aborted.store(true, .release);
        _ = self.abort_calls.fetchAdd(1, .acq_rel);
    }
    fn cleanup(raw: *anyopaque) controller.Cleanup {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        _ = self.cleanup_calls.fetchAdd(1, .acq_rel);
        return if (self.cleanup_unknown.load(.acquire)) .unknown else .released;
    }
    fn wait(_: *anyopaque, _: u32) void {
        pause();
    }
    fn now(_: *anyopaque) u64 {
        return runtime_api.monotonicMs() * std.time.ns_per_ms;
    }
    fn driver(self: *Fixture) controller.Driver {
        return .{ .context = self, .begin = begin, .read = read, .write = write, .abort = abort, .cleanup = cleanup, .wait = wait, .now_ns = now };
    }
};
const Harness = struct {
    budget: budgets.Budget,
    backend: journal.MemoryBackend,
    challenge_host: challenges.Host,
    fixture: Fixture,
    plugin: *plugin_api.Plugin,
    host: sessions.SessionHost,
    accepted: sessions.Accepted,
    fn create() !*Harness {
        const self = try a.create(Harness);
        errdefer a.destroy(self);
        self.budget = budgets.Budget.init(budgets.application_bytes);
        self.backend = .{ .allocator = a };
        self.challenge_host = challenges.Host.init(a);
        self.fixture = try Fixture.init();
        errdefer self.fixture.deinit();
        self.plugin = try plugin_api.Plugin.init(a, .{ .frame_budget = &self.budget, .journal_backend = self.backend.backend(), .probe_challenges = &self.challenge_host });
        errdefer self.plugin.deinit() catch unreachable;
        self.plugin.test_driver = self.fixture.driver();
        var manifest = self.plugin.manifest();
        // This fixture deliberately injects only its local HostContext. The
        // production declaration is checked separately below.
        manifest.dependencies = &.{.{ .id = "host", .major = 2 }};
        self.host = try sessions.SessionHost.initPlugins(a, &.{manifest}, &.{self.plugin.renderer()});
        errdefer self.host.deinit();
        self.host.setContextFactory(.{ .context = self, .create = context });
        self.accepted = try self.host.open(envelope, .{ .request_key = 1, .target = target });
        self.fixture.runtime = self.plugin.runtimeFor(self.accepted.handle) orelse return error.MissingRuntime;
        return self;
    }
    fn context(raw: *anyopaque, owner: svc.identity.SessionHandle, key: svc.OperationKey, destination: contexts.Target) !contexts.HostContext {
        const self: *Harness = @ptrCast(@alignCast(raw));
        return .{ .owner = owner, .operation = key, .target = destination, .challenges = &self.challenge_host };
    }
    fn destroy(self: *Harness) void {
        self.fixture.allow_begin.store(true, .release);
        self.fixture.cleanup_unknown.store(false, .release);
        const deadline = runtime_api.monotonicMs() + 5000;
        while (true) {
            self.plugin.deinit() catch |err| {
                if (err != error.BmcCleanupPending or runtime_api.monotonicMs() >= deadline) @panic("BMC fixture cleanup did not release");
                _ = self.host.pollControllers() catch false;
                pause();
                continue;
            };
            break;
        }
        self.host.deinit();
        self.fixture.deinit();
        self.challenge_host.deinit();
        self.backend.deinit();
        self.budget.deinit() catch @panic("BMC fixture leaked frame reservation");
        a.destroy(self);
    }
    fn runtime(self: *Harness) *runtime_api.Runtime {
        return self.fixture.runtime.?;
    }
    fn pollUntil(self: *Harness, comptime predicate: fn (*Harness) bool) !void {
        const deadline = runtime_api.monotonicMs() + 3000;
        while (!predicate(self)) {
            if (runtime_api.monotonicMs() >= deadline) return error.FixtureTimeout;
            _ = try self.host.pollControllers();
            pause();
        }
    }
};
fn workerBegan(h: *Harness) bool {
    return h.fixture.began.load(.acquire);
}
fn gotFrame(h: *Harness) bool {
    return h.runtime().last_sequence > 0;
}
fn workerExited(h: *Harness) bool {
    return h.runtime().controller.poll().worker_exited;
}
fn gotChallenge(h: *Harness) bool {
    return h.challenge_host.snapshot(0, h.accepted.handle) != null;
}
fn cleanupUnknown(h: *Harness) bool {
    return h.runtime().receipt() == .unknown;
}
fn waitingFirstFrame(h: *Harness) bool {
    return h.runtime().controller.poll().video == .awaiting_frame;
}

test "BMC efficiency runtime close drains its encoder before releasing frame ownership" {
    const h = try Harness.create();
    defer h.destroy();
    h.fixture.allow_begin.store(true, .release);
    h.fixture.allow_frame.store(true, .release);
    try h.pollUntil(gotFrame);
    const runtime = h.runtime();
    try T.expect(runtime.ai_control.asynchronous_encoding);
    try T.expectError(error.ImageEncodingPending, runtime.ai_control.screenshot(runtime.aiBinding(), a, .{}));
    const next_observation = runtime.ai_control.next_observation;
    _ = runtime.close();
    const deadline = runtime_api.monotonicMs() + 3000;
    while (runtime.receipt() != .released) {
        if (runtime_api.monotonicMs() >= deadline) return error.FixtureTimeout;
        pause();
    }
    try T.expect(runtime.ai_control.encoding == null);
    try T.expect(runtime.ai_control.cached_image.snapshot == null);
    try T.expectEqual(next_observation, runtime.ai_control.next_observation);
    // Harness.destroy checks all frame-budget reservations are released.
}

test "BMC plugin runtime publishes bindings before authentication and first frame" {
    const h = try Harness.create();
    defer h.destroy();
    try h.pollUntil(workerBegan);
    _ = try h.host.pollControllers();
    try T.expectEqual(sessions.Lifecycle.ready, h.host.queryState(h.accepted.handle).?.lifecycle);
    const access = try h.host.serviceAccess(h.accepted.handle);
    const binding = (try access.lookup(h.accepted.handle, console.definition)).?;
    const interface = try binding.borrow(console.Interface, console.key, h.accepted.handle);
    var before = try interface.snapshot(binding.context, binding, a);
    defer before.deinit();
    try T.expect(before.value.video != .streaming);
    try T.expectEqual(@as(u32, 0), before.value.width);
    try T.expectEqualStrings("fixture BMC", before.value.name);
    try T.expectEqual(console.progress.Stage.route, before.value.progress.stage);
    h.fixture.allow_begin.store(true, .release);
    try h.pollUntil(waitingFirstFrame);
    var waiting = try interface.snapshot(binding.context, binding, a);
    defer waiting.deinit();
    try T.expectEqual(console.progress.Stage.awaiting_first_frame, waiting.value.progress.stage);
    try T.expect(waiting.value.progress.failure_code == null);
    try T.expectEqual(@as(u32, 0), waiting.value.width);
    h.fixture.allow_frame.store(true, .release);
    try h.pollUntil(gotFrame);
    var after = try interface.snapshot(binding.context, binding, a);
    defer after.deinit();
    try T.expectEqual(console.VideoState.streaming, after.value.video);
    try T.expectEqual(console.progress.Stage.streaming, after.value.progress.stage);
    try T.expectEqual(@as(u32, 1), after.value.width);
    try T.expectEqual(@as(u32, 1), after.value.height);
    try T.expectEqual(@as(u32, 0), before.value.width);
    try T.expectEqual(console.progress.Stage.route, before.value.progress.stage);
}

test "BMC plugin runtime queued user cancellation keeps logs and waits for release before retry with a new owner" {
    const h = try Harness.create();
    defer h.destroy();
    try h.pollUntil(workerBegan);
    _ = try h.host.pollControllers();
    try T.expect(try h.host.attached(h.accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(52) }));
    const previous = h.runtime();
    const binding = previous.consoleBinding();
    const interface = try binding.borrow(console.Interface, console.key, previous.owner);
    const cancel = interface.cancel orelse return error.MissingCancel;
    var foreign = binding;
    foreign.owner = try previous.owner.nextGeneration();
    foreign.generation = foreign.owner.generation;
    try T.expectError(error.StaleBinding, cancel(binding.context, foreign));
    h.fixture.cleanup_unknown.store(true, .release);
    try cancel(binding.context, binding);
    try cancel(binding.context, binding);
    // The service callback queues memory only; Plugin.poll owns close.
    try T.expect(previous.cancel_requested and !previous.stopping);
    try T.expectEqual(@as(usize, 0), h.fixture.abort_calls.load(.acquire));
    _ = try h.host.pollControllers();
    try T.expect(previous.stopping and previous.cancelled_by_user);
    try T.expect(!previous.cancel_requested and previous.close_operation == null);
    try interface.retry(binding.context, binding);
    const next = try previous.owner.nextGeneration();
    _ = try h.host.pollControllers();
    try T.expect(h.plugin.runtimeFor(next) == null);
    h.fixture.allow_begin.store(true, .release);
    try h.pollUntil(cleanupUnknown);
    var pending = try interface.snapshot(binding.context, binding, a);
    defer pending.deinit();
    try T.expectEqual(console.Cleanup.unknown, pending.value.cleanup);
    try T.expectEqual(console.progress.Stage.cleanup, pending.value.progress.stage);
    try T.expect(pending.value.progress.event_count > 0);
    try T.expect(h.host.typedBindingsFor(previous.owner) != null);
    try T.expect(h.plugin.runtimeFor(next) == null);
    try cancel(binding.context, binding);
    _ = try h.host.pollControllers();
    try T.expect(!previous.cancel_requested);
    try T.expectEqual(@as(usize, 1), h.fixture.abort_calls.load(.acquire));
    h.fixture.cleanup_unknown.store(false, .release);
    const deadline = runtime_api.monotonicMs() + 3000;
    while (h.plugin.runtimeFor(next) == null) {
        if (runtime_api.monotonicMs() >= deadline) return error.FixtureTimeout;
        _ = try h.host.pollControllers();
        pause();
    }
    try T.expectEqual(sessions.CloseReceipt.released, previous.receipt());
    try T.expectEqual(console.progress.Stage.cancelled, previous.controller.poll().progress.stage);
    try T.expect(previous.stale);
    try T.expectError(error.StaleBinding, interface.snapshot(binding.context, binding, a));
    try T.expectError(error.StaleBinding, interface.retry(binding.context, binding));
    try T.expectError(error.StaleBinding, cancel(binding.context, binding));
    h.fixture.runtime = h.plugin.runtimeFor(next).?;
    _ = try h.host.pollControllers();
    var fresh = try h.runtime().snapshot(a);
    defer fresh.deinit();
    try T.expect(fresh.value.owner.eql(next));
    try T.expect(fresh.value.progress.failure_code == null);
    try T.expectEqual(@as(usize, 0), h.backend.writes);
}

test "BMC plugin runtime real tab close and plugin shutdown reject queued reconnect" {
    const h = try Harness.create();
    defer h.destroy();
    try h.pollUntil(workerBegan);
    _ = try h.host.pollControllers();
    const binding = h.runtime().consoleBinding();
    const interface = try binding.borrow(console.Interface, console.key, h.accepted.handle);
    try T.expect(try h.host.attached(h.accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(53) }));
    _ = try h.host.requestClose(h.accepted.handle, .{});
    try T.expect(h.runtime().close_operation != null);
    try T.expectError(error.OwnerClosed, interface.retry(binding.context, binding));
    try T.expectError(error.OwnerClosed, interface.cancel.?(binding.context, binding));
    try T.expectError(error.BmcCleanupPending, h.plugin.deinit());
    try T.expect(h.plugin.shutting_down);
    try T.expectError(error.OwnerClosed, interface.retry(binding.context, binding));
    try T.expect(!h.runtime().retry_requested);
}

test "BMC plugin runtime trust rejection consumes no credentials and retires challenge" {
    const h = try Harness.create();
    defer h.destroy();
    h.fixture.trust_challenge = true;
    h.fixture.trust_verification = .{ .failures = .{ .untrusted_issuer = true, .hostname_mismatch = true, .excessive_validity = true }, .not_before_unix = 1604102400, .not_after_unix = 1919462400 };
    h.fixture.allow_begin.store(true, .release);
    try h.pollUntil(gotChallenge);
    const challenge = h.challenge_host.snapshot(0, h.accepted.handle).?;
    try T.expectEqual(challenges.Kind.choice, challenge.kind);
    const certificate = challenge.payload.certificate_trust.?;
    try T.expectEqualStrings("bmc.invalid:443", certificate.authority);
    try T.expectEqualStrings("2020-10-31 00:00:00 UTC", certificate.valid_from);
    try T.expectEqualStrings("2030-10-29 00:00:00 UTC", certificate.valid_until);
    try T.expectEqualSlices(u8, &h.fixture.trust_verification.leaf_fingerprint, &certificate.leaf_fingerprint);
    try T.expectEqualSlices(u8, &h.fixture.trust_verification.chain_fingerprint, &certificate.chain_fingerprint);
    try T.expect(std.mem.indexOf(u8, certificate.failures, "证书总有效期超过系统允许上限") != null);
    const material = challenge.payload.material;
    for ([_][]const u8{ "目标：bmc.invalid:443", "有效期开始：2020-10-31 00:00:00 UTC", "有效期结束：2030-10-29 00:00:00 UTC", "证书颁发者不受信任", "自签名证书或未知 CA", "证书主机名与目标不匹配", "证书总有效期超过系统允许上限", "证书 SHA-256：", "证书链 SHA-256：" }) |expected| {
        if (std.mem.indexOf(u8, material, expected) == null) {
            std.debug.print("missing TLS challenge text: {s}\nactual material:\n{s}\n", .{ expected, material });
            return error.TestUnexpectedResult;
        }
    }
    try T.expect(std.mem.indexOf(u8, material, "证书已过期") == null);
    try T.expect(std.mem.indexOf(u8, material, "证书尚未生效") == null);
    try T.expect(std.mem.indexOf(u8, material, "有效期 Unix：") == null);
    try h.challenge_host.submitAnswer(challenge.owner, challenge.request_id, challenge.generation, .{ .choice = "reject" }, runtime_api.monotonicMs());
    try h.pollUntil(workerExited);
    try T.expectEqual(@as(usize, 0), h.fixture.credential_calls.load(.acquire));
    try T.expectEqual(error.TrustRejected, h.runtime().controller.poll().failure.?);
    try T.expect(h.challenge_host.snapshot(0, h.accepted.handle) == null);
    try T.expectEqual(@as(usize, 0), h.budget.usedBytes());
}

test "BMC plugin runtime trust material separates validity and unexceptable failures" {
    const h = try Harness.create();
    defer h.destroy();
    h.fixture.trust_challenge = true;
    h.fixture.trust_verification = .{ .failures = .{ .expired = true, .not_yet_valid = true, .revoked = true, .invalid_chain = true, .evaluation_unavailable = true, .reserved = 1 }, .not_before_unix = -1, .not_after_unix = 0 };
    h.fixture.allow_begin.store(true, .release);
    try h.pollUntil(gotChallenge);
    const challenge = h.challenge_host.snapshot(0, h.accepted.handle).?;
    const material = challenge.payload.material;
    for ([_][]const u8{ "1969-12-31 23:59:59 UTC", "1970-01-01 00:00:00 UTC", "证书已过期", "证书尚未生效", "证书已被吊销（不允许例外）", "证书链无效（不允许例外）", "系统证书验证不可用（不允许例外）", "未知证书验证失败（不允许例外）" }) |expected| {
        if (std.mem.indexOf(u8, material, expected) == null) {
            std.debug.print("missing TLS challenge text: {s}\nactual material:\n{s}\n", .{ expected, material });
            return error.TestUnexpectedResult;
        }
    }
    try T.expect(std.mem.indexOf(u8, material, "证书总有效期超过系统允许上限") == null);
    try h.challenge_host.submitAnswer(challenge.owner, challenge.request_id, challenge.generation, .{ .choice = "reject" }, runtime_api.monotonicMs());
    try h.pollUntil(workerExited);
    try T.expectEqual(@as(usize, 0), h.fixture.credential_calls.load(.acquire));
}

test "BMC plugin runtime late cancelled completion cannot reattach or publish a frame" {
    const h = try Harness.create();
    defer h.destroy();
    try h.pollUntil(workerBegan);
    _ = try h.host.pollControllers();
    try T.expect(try h.host.cancel(h.accepted.operation));
    try T.expect(h.runtime().receipt() == .awaiting);
    h.fixture.allow_frame.store(true, .release);
    h.fixture.allow_begin.store(true, .release);
    try h.pollUntil(workerExited);
    _ = try h.host.pollControllers();
    try T.expectEqual(sessions.Lifecycle.failed, h.host.queryState(h.accepted.handle).?.lifecycle);
    try T.expectEqual(@as(u64, 0), h.runtime().controller.poll().published_frames);
    try T.expect(h.host.typedBindingsFor(h.accepted.handle) == null);
    try T.expectEqual(@as(usize, 0), h.budget.usedBytes());
}

test "BMC plugin runtime close waits for immutable FrameLease and preserves unknown cleanup" {
    const h = try Harness.create();
    defer h.destroy();
    h.fixture.allow_begin.store(true, .release);
    h.fixture.allow_frame.store(true, .release);
    try h.pollUntil(gotFrame);
    try T.expect(try h.host.attached(h.accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(42) }));
    const frame_binding = h.runtime().controller.framebufferBinding();
    const interface = try frame_binding.borrow(framebuffer.Interface, framebuffer.key, h.accepted.handle);
    var lease = switch (interface.acquire_latest(frame_binding.context, frame_binding, 0)) {
        .frame => |value| value,
        else => return error.MissingFrame,
    };
    defer lease.release();
    h.fixture.cleanup_unknown.store(true, .release);
    _ = try h.host.requestClose(h.accepted.handle, .{});
    try T.expect(h.runtime().receipt() != .released);
    try h.pollUntil(cleanupUnknown);
    try T.expectError(error.BmcCleanupPending, h.plugin.deinit());
    try T.expect(h.budget.usedBytes() > 0);
    h.fixture.cleanup_unknown.store(false, .release);
    pause();
    try T.expect(h.runtime().receipt() != .released);
    try T.expectEqual(@as(u8, 3), lease.snapshot.pixels[0]);
    lease.release();
    try h.pollUntil(workerExited);
    _ = try h.host.pollControllers();
    try T.expectEqual(sessions.CloseReceipt.released, h.runtime().receipt());
    try T.expectEqual(sessions.Lifecycle.closed, h.host.queryState(h.accepted.handle).?.lifecycle);
    try T.expectEqual(@as(usize, 0), h.budget.usedBytes());
}

test "BMC plugin runtime rejects foreign owners before changing focus or cleanup" {
    const h = try Harness.create();
    defer h.destroy();
    _ = try h.host.pollControllers();
    const binding = h.runtime().consoleBinding();
    const interface = try binding.borrow(console.Interface, console.key, h.accepted.handle);
    var foreign = binding;
    foreign.owner = try h.accepted.handle.nextGeneration();
    foreign.generation = foreign.owner.generation;
    try T.expectError(error.StaleBinding, interface.snapshot(binding.context, foreign, a));
    try T.expectError(error.StaleBinding, interface.set_focus(binding.context, foreign, true));
    try T.expect(!(try h.runtime().controller.remote_input.snapshot(h.runtime().controller.inputBinding())).focused);
    const factory = h.plugin.manifest().session_factory.?;
    try T.expectError(error.WrongOwner, factory.vtable.close(factory.context, foreign.owner, h.accepted.operation));
    try T.expect(!h.runtime().stopping);
}

test "BMC plugin runtime manual retry releases the attached generation before creating another" {
    const h = try Harness.create();
    defer h.destroy();
    h.fixture.allow_begin.store(true, .release);
    h.fixture.allow_frame.store(true, .release);
    try h.pollUntil(gotFrame);
    try T.expect(try h.host.attached(h.accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(51) }));
    const previous = h.runtime();
    const binding = previous.consoleBinding();
    const interface = try binding.borrow(console.Interface, console.key, previous.owner);
    try interface.retry(binding.context, binding);
    const next = try previous.owner.nextGeneration();
    const deadline = runtime_api.monotonicMs() + 3000;
    while (h.plugin.runtimeFor(next) == null) {
        if (runtime_api.monotonicMs() >= deadline) return error.FixtureTimeout;
        _ = try h.host.pollControllers();
        pause();
    }
    try T.expect(previous.controller.poll().worker_exited);
    try T.expectEqual(sessions.CloseReceipt.released, previous.receipt());
    try T.expect(h.host.queryState(previous.owner) == null);
    h.fixture.runtime = h.plugin.runtimeFor(next).?;
    _ = try h.host.pollControllers();
    try T.expectEqual(sessions.Lifecycle.ready, h.host.queryState(next).?.lifecycle);
    const power_snapshot = try h.fixture.runtime.?.powerBinding().borrow(svc.PowerService, svc.power_key, next);
    // The initial unavailable snapshot uses generation 2 rather than the
    // default generation 1, even before its management discovery completes.
    const power_binding = h.fixture.runtime.?.powerBinding();
    var snapshot = try power_snapshot.snapshot(power_binding.context, .{ .owner = next, .binding_generation = next.generation }, a);
    defer snapshot.deinit();
    try T.expectEqual(next.generation, snapshot.value.capability.binding_generation);
}

test "BMC plugin runtime preserves read tools and cannot enable management writes through backend grants" {
    const h = try Harness.create();
    defer h.destroy();
    _ = try h.host.pollControllers();
    const runtime = h.runtime();
    const capability: svc.Capability = .{ .binding_generation = runtime.owner.generation, .system_mapping_verified = true, .write_granted = true, .secondary_auth = .disabled };
    try runtime.controller.manager.setSnapshots(.{ .capability = capability }, .{ .capability = capability }, true);
    const call: svc.Call = .{ .owner = runtime.owner, .binding_generation = runtime.owner.generation };
    const p = runtime.powerBinding();
    const power = try p.borrow(svc.PowerService, svc.power_key, runtime.owner);
    var snapshot = try power.snapshot(p.context, call, a);
    defer snapshot.deinit();
    try T.expect(!snapshot.value.capability.write_granted);
    const execution: svc.Execution = .{ .call = call, .operation = runtime.operation, .nonce = @splat(1), .system_uri = "/redfish/v1/Systems/one", .capability_revision = 1, .grant_revision = 1 };
    try T.expectEqual(svc.Reason.permission_denied, power.request(p.context, .{ .execution = execution, .action = .force_off }).rejected);
    const b = runtime.bootBinding();
    const boot = try b.borrow(svc.BootService, svc.boot_key, runtime.owner);
    try T.expectEqual(svc.Reason.permission_denied, boot.apply(b.context, .{ .execution = execution, .baseline = .{}, .target = "Pxe" }).rejected);
    const manifest = h.plugin.manifest();
    try T.expectEqual(tools.definitions.len, manifest.tools.len);
    for (manifest.tool_definitions, 0..) |definition, index| {
        try ai.validateDefinition(definition);
        if (index < 3) {
            try T.expectEqual(ai.Effect.read_state, definition.effect);
            try T.expectEqual(ai.ApprovalPolicy.read_only, definition.approval_policy);
        }
        try T.expect(definition.effect != .resource_write);
        var name: [128]u8 = undefined;
        _ = try ai.encodeName(&name, definition.id);
    }
    const args = try std.fmt.allocPrint(a, "{{\"session_ids\":[{d}]}}", .{@backingInt(runtime.owner.session_id)});
    defer a.free(args);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, args, .{});
    defer parsed.deinit();
    var invocation: ai.Invocation = .{ .owner = runtime.owner, .operation_id = 83, .tool_id = "bmc_ikvm.describe_frame", .arguments = parsed.value, .arguments_json = args, .arguments_hash = @splat(0) };
    var result = try plugin_api.Plugin.tool(h.plugin, invocation, a);
    defer result.deinit(a);
    try result.validate(runtime.owner, invocation.operation_id);
    try T.expect(result.blocks[0] == .structured);
    try T.expect(std.mem.indexOf(u8, result.blocks[0].structured, "\"pixel_access\":false") != null);
    try T.expect(std.mem.indexOf(u8, result.blocks[0].structured, "\"pixels\"") == null);
    try T.expect(std.mem.indexOf(u8, result.blocks[0].structured, "PowerState") == null);
    invocation.effect = .remote_input;
    try T.expectError(error.ToolPermissionDenied, plugin_api.Plugin.tool(h.plugin, invocation, a));
    invocation.effect = .read_state;
    invocation.tool_id = "bmc_ikvm.write_power";
    try T.expectError(error.UnknownTool, plugin_api.Plugin.tool(h.plugin, invocation, a));
    try T.expectEqual(@as(usize, 0), h.backend.writes);
    try T.expectEqual(@as(usize, 7), manifest.dependencies.len);
    try T.expect(!h.plugin.renderer().supports_window_transfer);
    _ = tools.definitions;
}
