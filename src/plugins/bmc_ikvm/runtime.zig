//! A heap-stable session owner. Main-thread calls prepare, publish bindings and
//! drain challenge mailboxes; the controller's detached worker owns native IO.
const std = @import("std");
const builtin = @import("builtin");
const sessions = @import("../../host/session_host.zig");
const contexts = @import("../../host/host_context.zig");
const typed = @import("../../host/plugin_services.zig");
const challenges = @import("../../host/challenge_host.zig");
const tls = @import("../../host/tls_trust.zig");
const budgets = @import("../../host/frame_budget.zig");
const controller = @import("controller.zig");
const native = @import("native_driver.zig");
const model = @import("model.zig");
const console = @import("console_service.zig");
const svc = @import("services.zig");
const auth = @import("protocol/auth.zig");
const ledger = @import("management_journal.zig");
const notifications = @import("../../host/notification_coordinator.zig");
const content = @import("../../host/content_context.zig");
const ai = @import("ai_control.zig");

pub const lifecycle_key: typed.ServiceKey = .{ .name = "lifecycle", .major = 1 };
pub const lifecycle_definition = typed.Definition.of(sessions.Adapter.VTable, lifecycle_key);

/// Worker callbacks never touch ChallengeHost. This mailbox transfers only
/// public trust material or a wipeable one-shot secret to/from the main drain.
pub const ChallengeBridge = struct {
    const Request = union(enum) { trust: tls.Challenge, password };
    const Response = union(enum) { trust: tls.TrustChoice, password: auth.Secret };
    allocator: std.mem.Allocator,
    owner: svc.identity.SessionHandle,
    operation: svc.OperationKey,
    host: ?*challenges.Host,
    mutex: std.atomic.Mutex = .unlocked,
    stopped: bool = false,
    state: enum { idle, pending, answered, cancelled } = .idle,
    request: ?Request = null,
    response: ?Response = null,
    request_id: u64 = 0,
    deadline: u64 = 0,
    offered: bool = false,
    management_policy: svc.ManagementPolicy = .read_only,

    pub fn init(a: std.mem.Allocator, owner: svc.identity.SessionHandle, operation: svc.OperationKey, host: ?*challenges.Host) ChallengeBridge {
        return .{ .allocator = a, .owner = owner, .operation = operation, .host = host };
    }
    pub fn callbacks(self: *ChallengeBridge) native.Callbacks {
        return .{ .context = self, .trust_reply = trustReply, .password_reply = passwordReply, .capability = managementCapability };
    }
    pub fn cancel(self: *ChallengeBridge) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.stopped = true;
        if (self.offered) if (self.host) |host| host.retire(self.owner, self.request_id, self.owner.generation);
        self.offered = false;
        if (self.response) |*response| if (response.* == .password) response.password.deinit();
        self.response = null;
        self.state = .cancelled;
    }
    pub fn deinit(self: *ChallengeBridge) void {
        self.cancel();
    }
    pub fn poll(self: *ChallengeBridge) !bool {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.state != .pending) return false;
        const host = self.host orelse {
            self.state = .cancelled;
            return true;
        };
        if (self.stopped or monotonicMs() >= self.deadline) {
            if (self.offered) host.retire(self.owner, self.request_id, self.owner.generation);
            self.offered = false;
            self.state = .cancelled;
            return true;
        }
        var changed = false;
        if (!self.offered) {
            const request = self.request.?;
            switch (request) {
                .password => try host.offer(self.owner, self.request_id, self.owner.generation, .secret_input, .{ .title = "BMC · 本次连接密码", .detail = "密码仅用于本次 BMC 认证，不写入连接配置。", .source_name = "BMC · iKVM" }, self.deadline),
                .trust => |challenge| {
                    const material = try trustMaterial(self.allocator, challenge);
                    defer self.allocator.free(material);
                    const authority = if (std.mem.indexOfScalar(u8, challenge.authority.host(), ':') != null)
                        try std.fmt.allocPrint(self.allocator, "[{s}]:{d}", .{ challenge.authority.host(), challenge.authority.port })
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ challenge.authority.host(), challenge.authority.port });
                    defer self.allocator.free(authority);
                    const starts = try utcDate(self.allocator, challenge.verification.not_before_unix);
                    defer self.allocator.free(starts);
                    const ends = try utcDate(self.allocator, challenge.verification.not_after_unix);
                    defer self.allocator.free(ends);
                    const failures = try trustFailures(self.allocator, challenge.verification.failures);
                    defer self.allocator.free(failures);
                    try host.offer(self.owner, self.request_id, self.owner.generation, .choice, .{
                        .title = "信任 BMC 证书",
                        .detail = "通过可信渠道核对原始 BMC 目标和指纹后，再选择信任范围。\n拒绝会停止连接，且不会发送 BMC 凭据。",
                        .source_name = "BMC · iKVM",
                        .material = material,
                        .certificate_trust = .{ .authority = authority, .leaf_fingerprint = challenge.verification.leaf_fingerprint, .chain_fingerprint = challenge.verification.chain_fingerprint, .subject = challenge.verification.subjectText(), .issuer = challenge.verification.issuerText(), .valid_from = starts, .valid_until = ends, .failures = failures, .scope_changed = challenge.scope_changed },
                        .choices = &.{ .{ .value = "reject", .label = "拒绝连接" }, .{ .value = "once", .label = "仅本次信任" }, .{ .value = "persistent", .label = "保存并继续" } },
                    }, self.deadline);
                },
            }
            self.offered = true;
            changed = true;
        }
        if (host.takeAnswer(self.owner, self.request_id, self.owner.generation)) |incoming| {
            var answer = incoming;
            defer answer.deinit();
            self.offered = false;
            self.response = switch (self.request.?) {
                .trust => .{ .trust = if (answer.value == .choice and std.mem.eql(u8, answer.value.choice, "once")) .once else if (answer.value == .choice and std.mem.eql(u8, answer.value.choice, "persistent")) .persistent else .reject },
                .password => if (answer.value == .secret_input and answer.value.secret_input.len != 0) .{ .password = try auth.Secret.init(self.allocator, answer.value.secret_input) } else null,
            };
            self.state = if (self.response != null) .answered else .cancelled;
            return true;
        }
        const state = host.stateFor(self.owner, self.request_id, self.owner.generation);
        if (state == null or state == .withdrawn or state == .timed_out or state == .cancelled) {
            host.retire(self.owner, self.request_id, self.owner.generation);
            self.offered = false;
            self.state = .cancelled;
            return true;
        }
        return changed;
    }
    fn waitFor(self: *ChallengeBridge, request: Request, cancel_value: *const std.atomic.Value(bool)) !Response {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        if (self.stopped or cancel_value.load(.acquire)) {
            self.mutex.unlock();
            return error.Cancelled;
        }
        if (self.state != .idle or self.host == null) {
            self.mutex.unlock();
            return error.ChallengeHostUnavailable;
        }
        self.request_id = if (self.request_id == 0) 1 else svc.identity.advance(self.request_id) catch {
            self.mutex.unlock();
            return error.ChallengeIdentityExhausted;
        };
        self.request = request;
        self.deadline = monotonicMs() + 300_000;
        self.state = .pending;
        self.mutex.unlock();
        while (true) {
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
            if (self.stopped or cancel_value.load(.acquire) or self.state == .cancelled or monotonicMs() >= self.deadline) {
                self.mutex.unlock();
                return error.Cancelled;
            }
            if (self.state == .answered) {
                const response = self.response.?;
                self.response = null;
                self.request = null;
                self.state = .idle;
                self.mutex.unlock();
                return response;
            }
            self.mutex.unlock();
            var fds: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&fds, 0, 5);
        }
    }
    pub fn trustReply(raw: *anyopaque, challenge: tls.Challenge, cancel_value: *const std.atomic.Value(bool)) !tls.TrustChoice {
        const self: *ChallengeBridge = @ptrCast(@alignCast(raw));
        if (!self.owner.eql(challenge.owner) or !self.operation.eql(challenge.operation)) return error.WrongOwner;
        const response = try self.waitFor(.{ .trust = challenge }, cancel_value);
        return switch (response) {
            .trust => |choice| choice,
            .password => error.ChallengeKindMismatch,
        };
    }
    pub fn passwordReply(raw: *anyopaque, owner: svc.identity.SessionHandle, operation: svc.OperationKey, cancel_value: *const std.atomic.Value(bool), a: std.mem.Allocator) !auth.Secret {
        const self: *ChallengeBridge = @ptrCast(@alignCast(raw));
        if (!self.owner.eql(owner) or !self.operation.eql(operation)) return error.WrongOwner;
        var response = try self.waitFor(.password, cancel_value);
        if (response != .password) return error.ChallengeKindMismatch;
        defer response.password.deinit();
        return auth.Secret.init(a, response.password.bytes);
    }
    fn managementCapability(raw: *anyopaque, _: *const @import("protocol/redfish.zig").Discovery) !svc.Capability {
        const self: *ChallengeBridge = @ptrCast(@alignCast(raw));
        return .{ .binding_generation = self.owner.generation, .write_granted = false, .write_requestable = self.management_policy == .user_approved };
    }
};

fn trustMaterial(a: std.mem.Allocator, challenge: tls.Challenge) ![]u8 {
    const verification = challenge.verification;
    const starts = try utcDate(a, verification.not_before_unix);
    defer a.free(starts);
    const ends = try utcDate(a, verification.not_after_unix);
    defer a.free(ends);
    var material: std.Io.Writer.Allocating = .init(a);
    defer material.deinit();
    try material.writer.print("目标：{s}:{d}\n证书 SHA-256：{s}\n证书链 SHA-256：{s}\nSubject：{s}\nIssuer：{s}\n有效期开始：{s}\n有效期结束：{s}\n验证失败原因：\n", .{ challenge.authority.host(), challenge.authority.port, std.fmt.bytesToHex(verification.leaf_fingerprint, .lower), std.fmt.bytesToHex(verification.chain_fingerprint, .lower), verification.subjectText(), verification.issuerText(), starts, ends });
    const failures = try trustFailures(a, verification.failures);
    defer a.free(failures);
    try material.writer.print("{s}\n证书或例外变化：{s}", .{ failures, if (challenge.scope_changed) "是" else "否" });
    return material.toOwnedSlice();
}

fn trustFailures(a: std.mem.Allocator, failures: tls.FailureSet) ![]u8 {
    var material: std.Io.Writer.Allocating = .init(a);
    defer material.deinit();
    if (failures.untrusted_issuer) try material.writer.writeAll("- 证书颁发者不受信任（可能为自签名证书或未知 CA）\n");
    if (failures.expired) try material.writer.writeAll("- 证书已过期\n");
    if (failures.not_yet_valid) try material.writer.writeAll("- 证书尚未生效\n");
    if (failures.hostname_mismatch) try material.writer.writeAll("- 证书主机名与目标不匹配\n");
    if (failures.excessive_validity) try material.writer.writeAll("- 证书总有效期超过系统允许上限\n");
    if (failures.revoked) try material.writer.writeAll("- 证书已被吊销（不允许例外）\n");
    if (failures.invalid_chain) try material.writer.writeAll("- 证书链无效（不允许例外）\n");
    if (failures.evaluation_unavailable) try material.writer.writeAll("- 系统证书验证不可用（不允许例外）\n");
    if (failures.reserved != 0) try material.writer.writeAll("- 未知证书验证失败（不允许例外）\n");
    if (failures.empty()) try material.writer.writeAll("- 无\n");
    if (material.written().len != 0 and material.written()[material.written().len - 1] == '\n') material.writer.end -= 1;
    return material.toOwnedSlice();
}

fn utcDate(a: std.mem.Allocator, seconds: i64) ![]u8 {
    // Keep malformed/out-of-range certificate metadata honest. A 400-year
    // Gregorian cycle lets the unsigned epoch API also format pre-1970 dates.
    if (seconds < -62135596800 or seconds > 253402300799) return std.fmt.allocPrint(a, "超出可显示的 UTC 日期范围（Unix 秒：{d}）", .{seconds});
    const cycle_seconds = 146097 * @as(i64, std.time.epoch.secs_per_day);
    const cycles = if (seconds < 0) @divFloor(seconds, cycle_seconds) else 0;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds - cycles * cycle_seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    const year: u16 = @intCast(@as(i64, year_day.year) + cycles * 400);
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ year, @backingInt(month_day.month), month_day.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}

pub const Resources = struct { frame_budget: *budgets.Budget, journal: *ledger.Journal, management_policy: svc.ManagementPolicy = .user_approved };
pub const Runtime = struct {
    const Review = struct {
        request: svc.Owned(svc.ManagementRequest),
        fingerprint: [32]u8,
        result: svc.Result,
        deadline_ms: u64,
        delegated: bool = false,
        offered: bool = false,
    };
    allocator: std.mem.Allocator,
    owner: svc.identity.SessionHandle,
    operation: svc.OperationKey,
    context: contexts.HostContext,
    name: []u8,
    target: []u8,
    route_summary: []u8,
    controller: *controller.Controller,
    ai_control: ai.Service,
    previous_content_consumer: ?content.Consumer = null,
    content_consumer_installed: bool = false,
    backend: ?*native.NativeDriver = null,
    bridge: ChallengeBridge,
    management_policy: svc.ManagementPolicy,
    management_review: ?Review = null,
    published: bool = false,
    stopping: bool = false,
    stale: bool = false,
    retry_requested: bool = false,
    cancel_requested: bool = false,
    cancelled_by_user: bool = false,
    retry_disabled: bool = false,
    close_operation: ?svc.OperationKey = null,
    last_receipt: sessions.CloseReceipt = .awaiting,
    reported_create_receipt: ?sessions.CloseReceipt = null,
    reported_close_receipt: ?sessions.CloseReceipt = null,
    last_width: u32 = 0,
    last_height: u32 = 0,
    last_sequence: u64 = 0,
    last_generation: u64 = 0,
    notification_revision: u64 = 0,
    notified_streaming: bool = false,
    notified_failure: bool = false,
    remote_web_logout: native.RemoteRelease = .not_created,
    remote_kvm_logout: native.RemoteRelease = .not_created,
    remote_logout_diagnostics: ?native.LogoutDiagnostics = null,
    last_progress_revision: u64 = 0,
    last_progress_second: u64 = 0,

    /// Submission failure is fully retired through discardPrepared, without
    /// native cleanup/join on the configuration thread.
    pub fn prepare(a: std.mem.Allocator, request: sessions.CreateRequest, resources: Resources) !*Runtime {
        return prepareNative(a, request, resources, null);
    }
    /// Only the loopback acceptance tests may substitute an ephemeral reviewed
    /// profile. Factory policy, callbacks, controller and native IO are shared
    /// with prepare; there is no application path to this profile override.
    pub fn prepareNativeForTest(a: std.mem.Allocator, request: sessions.CreateRequest, resources: Resources, selected: @import("protocol/profile.zig").Profile) !*Runtime {
        if (!builtin.is_test or !selected.synthetic) return error.TestDriverForbidden;
        return prepareNative(a, request, resources, selected);
    }
    fn prepareNative(a: std.mem.Allocator, request: sessions.CreateRequest, resources: Resources, selected: ?@import("protocol/profile.zig").Profile) !*Runtime {
        const self = try prepareMemory(a, request, resources);
        errdefer self.destroyUnstarted();
        self.backend = try native.NativeDriver.prepare(a, self.context, self.controller.config.value, &self.controller.plan, &self.controller.cancel_requested, .{ .selected = selected, .callbacks = self.bridge.callbacks(), .management_adapter = &self.controller.manager, .progress = &self.controller.connection_progress, .management_policy = self.management_policy });
        errdefer {
            self.backend.?.discardPrepared() catch unreachable;
            self.backend = null;
        }
        try self.controller.startPrepared(self.backend.?.driver());
        return self;
    }
    /// Explicit test driver injection; absent from the production plugin path.
    pub fn prepareForTest(a: std.mem.Allocator, request: sessions.CreateRequest, resources: Resources, driver: controller.Driver) !*Runtime {
        if (!builtin.is_test) return error.TestDriverForbidden;
        const self = try prepareMemory(a, request, resources);
        errdefer self.destroyUnstarted();
        try self.controller.startPrepared(driver);
        return self;
    }
    fn prepareMemory(a: std.mem.Allocator, request: sessions.CreateRequest, resources: Resources) !*Runtime {
        const context = request.context orelse return error.HostContextUnavailable;
        try context.requireOwner(request.handle);
        if (!context.operation.eql(request.key)) return error.StaleHostContext;
        if (context.challenges == null) return error.ChallengeHostUnavailable;
        const envelope = switch (request.spec) {
            .plugin => |value| value,
            else => return error.InvalidBmcRequest,
        };
        if (!std.mem.eql(u8, envelope.protocol_id, model.protocol_id) or envelope.payload_version != model.payload_version) return error.UnsupportedProtocol;
        try envelope.validate();
        var parsed = try model.parse(a, envelope.payload);
        defer parsed.deinit();
        const policy: svc.ManagementPolicy = if (parsed.value().display.read_only_requested) .read_only else resources.management_policy;
        const control = try controller.Controller.createWithPolicy(a, request.handle, request.key, parsed.value(), context.connection_configs, resources.frame_budget, resources.journal, context.resource_actions, policy);
        errdefer control.deinit() catch unreachable;
        // The initial unavailable management snapshots use the real owner
        // generation too; retry generations must not look like stale calls.
        const capability: svc.Capability = .{ .binding_generation = request.handle.generation, .write_granted = false };
        try control.manager.setSnapshots(.{ .capability = capability }, .{ .capability = capability }, false);
        const name = try a.dupe(u8, envelope.name);
        errdefer a.free(name);
        const target = try std.fmt.allocPrint(a, "{s}:{d}", .{ parsed.value().endpoint.host, parsed.value().endpoint.https_port });
        errdefer a.free(target);
        var summary: std.Io.Writer.Allocating = .init(a);
        defer summary.deinit();
        try summary.writer.writeAll("本机");
        for (control.plan.route.hops) |hop| try summary.writer.print(" → {s}:{d}", .{ hop.nonsecret_config.host, hop.nonsecret_config.port });
        try summary.writer.print(" → {s}", .{target});
        const route_summary = try summary.toOwnedSlice();
        errdefer a.free(route_summary);
        const self = try a.create(Runtime);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .owner = request.handle, .operation = request.key, .context = context, .name = name, .target = target, .route_summary = route_summary, .controller = control, .ai_control = ai.Service.init(request.handle, &control.framebuffer, &control.remote_input), .bridge = ChallengeBridge.init(a, request.handle, request.key, context.challenges), .management_policy = policy };
        self.bridge.management_policy = policy;
        self.ai_control.refresh = .{ .context = self, .request = requestAiRefresh };
        self.ai_control.asynchronous_encoding = true;
        self.ai_control.on_stop = .{ .context = self, .revoke_lease = revokeAiLease };
        if (context.presentation.input) |input_context| {
            if (!input_context.owner.eql(request.handle)) return error.StaleHostContext;
            const previous = input_context.consumer;
            try input_context.setConsumer(.{ .context = self, .consume = consumeContentInput });
            self.previous_content_consumer = previous;
            self.content_consumer_installed = true;
        }
        return self;
    }
    fn destroyUnstarted(self: *Runtime) void {
        self.restoreContentConsumer();
        self.ai_control.close();
        self.controller.deinit() catch unreachable;
        self.bridge.deinit();
        self.freeMemory();
    }
    pub fn deinit(self: *Runtime) !void {
        if (self.close() != .released) return error.BmcCleanupPending;
        try self.controller.deinit();
        self.bridge.deinit();
        self.freeMemory();
    }
    fn freeMemory(self: *Runtime) void {
        const a = self.allocator;
        if (self.management_review) |*review| review.request.deinit();
        a.free(self.name);
        a.free(self.target);
        a.free(self.route_summary);
        a.destroy(self);
    }
    pub fn close(self: *Runtime) sessions.CloseReceipt {
        if (!self.stopping) {
            self.stopping = true;
            self.retireManagementReview();
            // Host stop/focus/permission revocation uses the same content lease
            // as every other plugin. Clear its proof before retiring this owner.
            if (self.context.presentation.input) |input_context| input_context.takeHumanControl();
            self.restoreContentConsumer();
            self.ai_control.close();
            self.bridge.cancel();
            self.controller.cancel();
        }
        return self.receipt();
    }
    pub fn receipt(self: *Runtime) sessions.CloseReceipt {
        const image_released = if (self.stopping) self.ai_control.drainEncoding() else true;
        const state = self.controller.poll();
        const current_receipt: sessions.CloseReceipt = if (state.worker_exited and state.cleanup == .released and image_released) .released else if (state.cleanup == .unknown) .unknown else .awaiting;
        if (current_receipt == .released) if (self.backend) |backend| {
            // Worker exit is the acquire barrier for native diagnostics.
            self.remote_web_logout = backend.diagnostics.web_logout;
            self.remote_kvm_logout = backend.diagnostics.kvm_logout;
            self.remote_logout_diagnostics = backend.logoutDiagnostics();
            backend.deinit() catch return .unknown;
            self.backend = null;
        };
        return current_receipt;
    }
    pub fn poll(self: *Runtime) !bool {
        var changed = try self.bridge.poll();
        changed = (try self.pollManagement()) or changed;
        changed = (try self.ai_control.poll()) or changed;
        const state = self.controller.poll();
        const progress_second = state.progress.elapsed_ms / 1000;
        if (state.progress.revision != self.last_progress_revision or progress_second != self.last_progress_second) {
            self.last_progress_revision = state.progress.revision;
            self.last_progress_second = progress_second;
            changed = true;
        }
        if (!self.stopping) {
            const acquired = self.controller.framebuffer.acquireLatest(self.controller.framebuffer.binding(), self.last_sequence);
            if (acquired == .frame) {
                var lease = acquired.frame;
                self.last_width = lease.snapshot.width;
                self.last_height = lease.snapshot.height;
                self.last_sequence = lease.snapshot.sequence;
                self.last_generation = lease.snapshot.frame_generation;
                lease.release();
                changed = true;
            }
            if (self.context.presentation.frame_sink) |sink| _ = self.controller.framebuffer.publishToSink(sink) catch |err| switch (err) {
                error.FrameQueueFull => false,
                else => return err,
            };
        }
        if (state.video == .streaming and !self.notified_streaming) {
            self.notified_streaming = true;
            try self.notify(.succeeded, "BMC 画面已连接");
            changed = true;
        }
        if (state.failure != null and !self.notified_failure and !self.stopping) {
            self.notified_failure = true;
            try self.notify(.failed, "BMC 控制台连接失败，可查看当前阶段后重连");
            changed = true;
        }
        const current = self.receipt();
        if (current != self.last_receipt) {
            self.last_receipt = current;
            changed = true;
        }
        return changed;
    }
    pub fn bindings(self: *Runtime, factory_context: *anyopaque, factory: *const sessions.Adapter.VTable) [7]typed.Binding {
        return .{
            typed.Binding.init(sessions.Adapter.VTable, lifecycle_key, factory_context, factory, self.owner, 1),
            self.consoleBinding(),
            self.controller.framebufferBinding(),
            self.controller.inputBinding(),
            self.powerBinding(),
            self.bootBinding(),
            self.aiBinding(),
        };
    }
    pub fn consoleBinding(self: *Runtime) typed.Binding {
        return typed.Binding.init(console.Interface, console.key, self, &console_vtable, self.owner, 1);
    }
    pub fn powerBinding(self: *Runtime) typed.Binding {
        return typed.Binding.init(svc.PowerService, svc.power_key, self, &power_vtable, self.owner, 1);
    }
    pub fn bootBinding(self: *Runtime) typed.Binding {
        return typed.Binding.init(svc.BootService, svc.boot_key, self, &boot_vtable, self.owner, 1);
    }
    pub fn aiBinding(self: *Runtime) typed.Binding {
        return self.ai_control.binding();
    }
    fn requestAiRefresh(raw: *anyopaque) !void {
        const self = from(raw);
        if (!self.published or self.stale or self.stopping) return error.StaleBinding;
        try self.controller.requestFullRefresh();
    }
    fn revokeAiLease(raw: *anyopaque) void {
        if (from(raw).context.presentation.input) |input_context| input_context.takeHumanControl();
    }
    fn restoreContentConsumer(self: *Runtime) void {
        if (!self.content_consumer_installed) return;
        if (self.context.presentation.input) |input_context| {
            if (input_context.consumer.context == @as(*anyopaque, @ptrCast(self)) and input_context.consumer.consume == consumeContentInput) {
                if (self.previous_content_consumer) |previous| input_context.consumer = previous;
            }
        }
        self.content_consumer_installed = false;
        self.previous_content_consumer = null;
    }
    fn consumeContentInput(raw: *anyopaque, event: content.Input) !void {
        const self = from(raw);
        // Native human events and typed AI actions retain their own validation.
        // This shared callback is the immediate host lease-revocation barrier.
        if (event != .release_all) return error.TypedInputRequired;
        _ = self.controller.remote_input.releaseAll(self.controller.remote_input.binding(), .released);
    }
    pub fn notify(self: *Runtime, phase: notifications.Phase, detail: []const u8) !void {
        const facade = self.context.notifications orelse return;
        self.notification_revision = if (self.notification_revision == 0) 1 else try svc.identity.advance(self.notification_revision);
        _ = try facade.publish(.{ .definition_id = "bmc_ikvm.connection", .owner = facade.owner, .operation_id = self.operation.operation_id, .attempt_id = self.operation.attempt_id, .event_revision = self.notification_revision, .phase = phase, .title = "BMC 控制台", .detail = detail, .owner_name = self.name, .object_name = self.target });
    }
    fn from(raw: *anyopaque) *Runtime {
        return @ptrCast(@alignCast(raw));
    }
    fn validate(self: *Runtime, binding: typed.Binding) !void {
        _ = try binding.borrow(console.Interface, console.key, self.owner);
        if (binding.context != @as(*anyopaque, self) or binding.vtable != @as(*const anyopaque, &console_vtable)) return error.StaleBinding;
        if (!self.published or self.stale) return error.StaleBinding;
    }
    fn validateCall(self: *Runtime, call: svc.Call) !void {
        if (!call.owner.eql(self.owner) or call.binding_generation != self.owner.generation or !self.published or self.stale) return error.StaleBinding;
        if (self.stopping) return error.OwnerClosed;
    }
    pub fn snapshot(self: *Runtime, a: std.mem.Allocator) !console.OwnedSnapshot {
        const state = self.controller.poll();
        return console.OwnedSnapshot.init(a, .{ .owner = self.owner, .operation = self.operation, .name = self.name, .target = self.target, .route_summary = self.route_summary, .route = @fromBackingInt(@intCast(@backingInt(state.route))), .video = @fromBackingInt(@intCast(@backingInt(state.video))), .management = @fromBackingInt(@intCast(@backingInt(state.management))), .cleanup = @fromBackingInt(@intCast(@backingInt(state.cleanup))), .input = state.input, .control = @fromBackingInt(@intCast(@backingInt(state.control))), .control_request = state.control_request, .failure_stage = if (state.failure) |err| failureStage(err) else null, .failure_code = if (state.failure) |err| @errorName(err) else null, .progress = state.progress, .width = self.last_width, .height = self.last_height, .stride = @as(usize, self.last_width) * 4, .frame_sequence = self.last_sequence, .decoded_frames = state.published_frames, .frame_generation = self.last_generation, .rfb_ready = state.rfb_ready, .read_only_requested = self.controller.config.value.display.read_only_requested, .remote_web_logout = @fromBackingInt(@intCast(@backingInt(self.remote_web_logout))), .remote_kvm_logout = @fromBackingInt(@intCast(@backingInt(self.remote_kvm_logout))) });
    }
    fn snapshotFrom(raw: *anyopaque, binding: typed.Binding, a: std.mem.Allocator) !console.OwnedSnapshot {
        const self = from(raw);
        try self.validate(binding);
        return self.snapshot(a);
    }
    fn requestControl(raw: *anyopaque, binding: typed.Binding) !void {
        const self = from(raw);
        try self.validate(binding);
        if (self.stopping) return error.OwnerClosed;
        try self.controller.requestControl();
    }
    fn replyControl(raw: *anyopaque, binding: typed.Binding, context: [4]u8, reply: console.ControlReply) !void {
        const self = from(raw);
        try self.validate(binding);
        if (self.stopping) return error.OwnerClosed;
        try self.controller.replyControl(context, switch (reply) {
            .full_control => .full_control,
            .video_only => .video_only,
            .reject => .reject,
        });
    }
    fn refresh(raw: *anyopaque, binding: typed.Binding) !void {
        const self = from(raw);
        try self.validate(binding);
        if (self.stopping) return error.OwnerClosed;
        try self.controller.requestFullRefresh();
    }
    fn setFocus(raw: *anyopaque, binding: typed.Binding, focused: bool) !void {
        const self = from(raw);
        try self.validate(binding);
        if (self.stopping and focused) return error.OwnerClosed;
        if (focused) if (self.context.presentation.input) |input_context| input_context.takeHumanControl();
        self.controller.remote_input.setFocus(focused);
    }
    fn retry(raw: *anyopaque, binding: typed.Binding) !void {
        const self = from(raw);
        try self.validate(binding);
        if (self.retry_disabled or self.close_operation != null or (self.stopping and !self.cancelled_by_user)) return error.OwnerClosed;
        self.retry_requested = true;
    }
    fn cancelConnection(raw: *anyopaque, binding: typed.Binding) !void {
        const self = from(raw);
        try self.validate(binding);
        if (self.retry_disabled or self.close_operation != null) return error.OwnerClosed;
        if (self.stopping) {
            if (self.cancelled_by_user) return;
            return error.OwnerClosed;
        }
        self.cancel_requested = true;
    }
    fn powerSnapshot(raw: *anyopaque, call: svc.Call, a: std.mem.Allocator) !svc.OwnedPowerSnapshot {
        const self = from(raw);
        try self.validateCall(call);
        const binding = self.controller.powerBinding();
        const iface = try binding.borrow(svc.PowerService, svc.power_key, self.owner);
        var value = try iface.snapshot(binding.context, call, a);
        value.value.capability.write_granted = false;
        value.value.capability.write_requestable = value.value.capability.write_requestable and self.management_policy == .user_approved and self.context.resource_actions != null;
        return value;
    }
    fn bootSnapshot(raw: *anyopaque, call: svc.Call, a: std.mem.Allocator) !svc.OwnedBootSnapshot {
        const self = from(raw);
        try self.validateCall(call);
        const binding = self.controller.bootBinding();
        const iface = try binding.borrow(svc.BootService, svc.boot_key, self.owner);
        var value = try iface.snapshot(binding.context, call, a);
        value.value.capability.write_granted = false;
        value.value.capability.write_requestable = value.value.capability.write_requestable and self.management_policy == .user_approved and self.context.resource_actions != null;
        return value;
    }
    fn denyPower(raw: *anyopaque, request: svc.PowerExecutionRequest) svc.RequestResult {
        from(raw).validateCall(request.execution.call) catch return .{ .rejected = .stale_binding };
        return .{ .rejected = .permission_denied };
    }
    fn denyBoot(raw: *anyopaque, request: svc.BootExecutionPatch) svc.RequestResult {
        from(raw).validateCall(request.execution.call) catch return .{ .rejected = .stale_binding };
        return .{ .rejected = .permission_denied };
    }
    fn requestManagement(raw: *anyopaque, binding: typed.Binding, request: svc.ManagementRequest) svc.RequestResult {
        const self = from(raw);
        self.validate(binding) catch return .{ .rejected = .stale_binding };
        const execution = request.execution();
        self.validateCall(execution.call) catch return .{ .rejected = .stale_binding };
        if (self.management_policy == .read_only) return .{ .rejected = .permission_denied };
        if (self.context.resource_actions == null) return .{ .rejected = .unavailable };
        if (execution.operation.owner != .session or !execution.operation.owner.session.eql(self.owner) or execution.operation.operation_id == 0 or std.mem.allEqual(u8, &execution.nonce, 0)) return .{ .rejected = .stale_binding };
        var power_snapshot = powerSnapshot(raw, execution.call, self.allocator) catch return .{ .rejected = .unavailable };
        defer power_snapshot.deinit();
        const p = power_snapshot.value;
        const cap = p.capability;
        if (!std.mem.eql(u8, execution.system_uri, p.system_uri)) return .{ .rejected = .stale_binding };
        if (execution.capability_revision != cap.revision or execution.grant_revision != cap.grant_revision) return .{ .rejected = .stale_capability };
        if (!cap.system_mapping_verified) return .{ .rejected = .mapping_unverified };
        if (!cap.write_requestable) return .{ .rejected = .permission_denied };
        if (cap.secondary_auth == .unknown or !cap.secondary_auth_evidence.permitsWrite()) return .{ .rejected = .secondary_auth_unknown };
        if (cap.secondary_auth == .required) return .{ .rejected = .secondary_auth_required };
        switch (request) {
            .power => |value| {
                if (p.reset_target == null or !p.state.evidence.permitsWrite() or !p.reset_types.evidence.permitsWrite() or !svc.contains(p.reset_types.value orelse &.{}, value.action.redfish())) return .{ .rejected = .unsupported };
                if (p.state.value != (if (value.action == .on) svc.PowerState.off else svc.PowerState.on)) return .{ .rejected = .invalid_request };
            },
            .boot => |value| {
                var b = bootSnapshot(raw, execution.call, self.allocator) catch return .{ .rejected = .unavailable };
                defer b.deinit();
                if (b.value.write_uri == null) return .{ .rejected = .unsupported };
                var arena: std.heap.ArenaAllocator = .init(self.allocator);
                defer arena.deinit();
                _ = @import("protocol/boot.zig").prepare(arena.allocator(), b.value, value) catch |err| return .{ .rejected = @import("protocol/power.zig").rejection(err) };
            },
        }
        const fingerprint = svc.requestFingerprint(self.allocator, request, self.controller.manager.engine.origin.authority, p.system_identity) catch return .{ .rejected = .unavailable };
        if (self.management_review) |*old| {
            if (old.result.operation.eql(execution.operation) or std.mem.eql(u8, &old.request.value.execution().nonce, &execution.nonce)) {
                if (!std.mem.eql(u8, &old.fingerprint, &fingerprint)) return .{ .rejected = .conflict };
                return .{ .accepted = execution.operation };
            }
            if (!old.result.terminal() or old.result.phase == .outcome_unknown) return .{ .rejected = .busy };
            old.request.deinit();
            self.management_review = null;
        }
        const copy = svc.Owned(svc.ManagementRequest).init(self.allocator, request) catch return .{ .rejected = .unavailable };
        self.management_review = .{ .request = copy, .fingerprint = fingerprint, .result = .{ .operation = execution.operation, .phase = .awaiting_approval }, .deadline_ms = monotonicMs() +| 120_000 };
        return .{ .accepted = execution.operation };
    }
    fn retireManagementReview(self: *Runtime) void {
        const review = if (self.management_review) |*value| value else return;
        if (review.offered) if (self.context.challenges) |host| {
            const key = review.result.operation;
            host.retire(key, key.operation_id, key.attempt_id orelse 1);
        };
        review.offered = false;
        if (!review.delegated and !review.result.terminal()) {
            review.result.phase = .cancelled_unsent;
            review.result.reason = .cancelled;
        }
    }
    fn pollManagement(self: *Runtime) !bool {
        const review = if (self.management_review) |*value| value else return false;
        if (review.delegated) {
            const binding = self.controller.powerBinding();
            const table = try binding.borrow(svc.PowerService, svc.power_key, self.owner);
            var current = try table.result(binding.context, review.request.value.execution().call, review.result.operation, self.allocator);
            defer current.deinit();
            const changed = review.result.phase != current.value.phase or review.result.reason != current.value.reason;
            review.result.phase = current.value.phase;
            review.result.reason = current.value.reason;
            return changed;
        }
        if (review.result.terminal()) return false;
        if (self.stopping or self.stale or self.management_policy == .read_only or monotonicMs() >= review.deadline_ms) {
            self.retireManagementReview();
            return true;
        }
        const host = self.context.challenges orelse return error.ChallengeHostUnavailable;
        const key = review.result.operation;
        const generation = key.attempt_id orelse 1;
        if (!review.offered) {
            const material = try self.managementMaterial(review.request.value);
            defer self.allocator.free(material);
            try host.offer(key, key.operation_id, generation, .choice, .{ .title = "确认 BMC 管理操作", .detail = "核对目标与本次更改后批准。该批准仅适用于当前操作；选择草稿不会执行。", .source_name = self.name, .material = material, .choices = &.{ .{ .value = "cancel", .label = "取消" }, .{ .value = "approve", .label = "批准本次操作" } } }, review.deadline_ms);
            review.offered = true;
            return true;
        }
        if (host.takeAnswer(key, key.operation_id, generation)) |incoming| {
            var answer = incoming;
            defer answer.deinit();
            review.offered = false;
            if (answer.value != .choice or !std.mem.eql(u8, answer.value.choice, "approve")) {
                review.result.phase = .cancelled_unsent;
                review.result.reason = .cancelled;
                return true;
            }
            // Adapter rechecks the live binding, mapping and both revisions.
            // The original owned request is the sole source of queued bytes.
            switch (self.controller.manager.approve(review.request.value)) {
                .accepted => review.delegated = true,
                .rejected => |reason| {
                    review.result.phase = .failed;
                    review.result.reason = reason;
                },
            }
            return true;
        }
        const state = host.stateFor(key, key.operation_id, generation);
        if (state == null or state == .withdrawn or state == .cancelled or state == .timed_out) {
            self.retireManagementReview();
            return true;
        }
        return false;
    }
    fn managementMaterial(self: *Runtime, request: svc.ManagementRequest) ![]u8 {
        return switch (request) {
            .power => |value| std.fmt.allocPrint(self.allocator, "目标：{s}\n管理资源：{s}\n操作：{s}{s}", .{ self.target, value.execution.system_uri, @import("view_model.zig").powerLabel(value.action), if (value.action == .force_off or value.action == .force_restart or value.action == .power_cycle) "\n强制动作可能造成数据丢失。" else "" }),
            .boot => |value| std.fmt.allocPrint(self.allocator, "目标：{s}\n管理资源：{s}\n当前：{s} · {s} · {s}\n本次设置：{s} · {s} · {s}\n仅设置启动覆盖，不会自动重启。", .{ self.target, value.execution.system_uri, value.baseline.enabled orelse "未知有效期", value.baseline.target orelse "未知设备", value.baseline.mode orelse "未知模式", value.enabled orelse value.baseline.enabled orelse "未知有效期", value.target orelse value.baseline.target orelse "未知设备", value.mode orelse value.baseline.mode orelse "未知模式" }),
        };
    }
    fn cancelWrite(raw: *anyopaque, call: svc.Call, key: svc.OperationKey) svc.CancelResult {
        const self = from(raw);
        self.validateCall(call) catch return .stale_operation;
        if (self.management_review) |review| if (review.result.operation.eql(key) and !review.delegated) {
            if (review.result.terminal()) return .already_terminal;
            self.retireManagementReview();
            return .cancelled_unsent;
        };
        const binding = self.controller.powerBinding();
        const table = binding.borrow(svc.PowerService, svc.power_key, self.owner) catch return .stale_operation;
        return table.cancel(binding.context, call, key);
    }
    fn result(raw: *anyopaque, call: svc.Call, key: svc.OperationKey, allocator: std.mem.Allocator) !svc.Owned(svc.Result) {
        const self = from(raw);
        try self.validateCall(call);
        if (self.management_review) |review| if (review.result.operation.eql(key) and !review.delegated) return svc.Owned(svc.Result).init(allocator, review.result);
        const binding = self.controller.powerBinding();
        const table = try binding.borrow(svc.PowerService, svc.power_key, self.owner);
        return table.result(binding.context, call, key, allocator);
    }
    fn query(raw: *anyopaque, call: svc.Call, key: svc.OperationKey) !void {
        const self = from(raw);
        try self.validateCall(call);
        const binding = self.controller.powerBinding();
        const table = try binding.borrow(svc.PowerService, svc.power_key, self.owner);
        try (table.query orelse return error.QueryUnavailable)(binding.context, call, key);
    }
    const console_vtable: console.Interface = .{ .snapshot = snapshotFrom, .request_control = requestControl, .reply_control = replyControl, .refresh = refresh, .set_focus = setFocus, .retry = retry, .cancel = cancelConnection, .request_management = requestManagement };
    const power_vtable: svc.PowerService = .{ .snapshot = powerSnapshot, .request = denyPower, .cancel = cancelWrite, .result = result, .query = query };
    const boot_vtable: svc.BootService = .{ .snapshot = bootSnapshot, .apply = denyBoot, .cancel = cancelWrite, .result = result, .query = query };
};

fn failureStage(err: anyerror) console.FailureStage {
    const name = @errorName(err);
    if (std.mem.indexOf(u8, name, "Profile") != null or std.mem.indexOf(u8, name, "Identity") != null) return .identity;
    if (std.mem.indexOf(u8, name, "Trust") != null or std.mem.indexOf(u8, name, "Tls") != null or std.mem.indexOf(u8, name, "Certificate") != null) return .trust;
    if (std.mem.indexOf(u8, name, "Auth") != null or std.mem.indexOf(u8, name, "Password") != null or std.mem.indexOf(u8, name, "Secret") != null or err == error.Cancelled) return .authentication;
    if (std.mem.indexOf(u8, name, "Transport") != null or std.mem.indexOf(u8, name, "Connect") != null or std.mem.indexOf(u8, name, "Route") != null) return .route;
    return .video;
}
pub fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}
