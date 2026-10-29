//! Product-owned BootstrapV1 plan. Only the host lifecycle worker constructs
//! this object, and only an exact second host approval may grant deployment.
const std = @import("std");
const identity = @import("../host/identity.zig");
const host = @import("host_tools.zig");
const approvals = @import("host_approval.zig");
pub const bootstrap = @import("../proto/ssh/bootstrap.zig");

/// Fixed command, submitted through the existing authenticated exec service.
/// Paths, flags and output format are host code, never model arguments. -f
/// bypasses zsh user startup files; no PTY or filesystem write is requested.
pub const probe_command = "LC_ALL=C; export LC_ALL; printf 'ZWBOOTSTRAP_PROBE_V1\n'; uname -s; uname -m; if [ -x /bin/zsh ]; then printf '/bin/zsh\n'; /bin/zsh -f -c 'printf \"%s\n\" \"$ZSH_VERSION\"'; elif [ -x /usr/bin/zsh ]; then printf '/usr/bin/zsh\n'; /usr/bin/zsh -f -c 'printf \"%s\n\" \"$ZSH_VERSION\"'; else exit 69; fi";

pub const Facts = struct {
    platform: enum { darwin_aarch64, linux_x86_64, linux_aarch64 },
    shell_path: enum { bin, usr_bin },
    pub fn parse(stdout: []const u8, stderr: []const u8, exit_code: ?i32, truncated: bool) !Facts {
        if (truncated or exit_code != 0 or stderr.len != 0 or stdout.len > 512) return error.BootstrapProbeFailed;
        var lines = std.mem.splitScalar(u8, stdout, '\n');
        if (!std.mem.eql(u8, lines.next() orelse "", "ZWBOOTSTRAP_PROBE_V1")) return error.BootstrapProbeFailed;
        const os = lines.next() orelse return error.BootstrapProbeFailed;
        const arch = lines.next() orelse return error.BootstrapProbeFailed;
        const shell = lines.next() orelse return error.BootstrapProbeFailed;
        if (!std.mem.eql(u8, lines.next() orelse "", "5.9") or !std.mem.eql(u8, lines.next() orelse "missing", "") or lines.next() != null) return error.UnsupportedBootstrapShell;
        const platform: Facts = .{
            .platform = if (std.mem.eql(u8, os, "Darwin") and std.mem.eql(u8, arch, "arm64")) .darwin_aarch64 else if (std.mem.eql(u8, os, "Linux") and std.mem.eql(u8, arch, "x86_64")) .linux_x86_64 else if (std.mem.eql(u8, os, "Linux") and (std.mem.eql(u8, arch, "aarch64") or std.mem.eql(u8, arch, "arm64"))) .linux_aarch64 else return error.UnsupportedBootstrapPlatform,
            .shell_path = if (std.mem.eql(u8, shell, "/bin/zsh")) .bin else if (std.mem.eql(u8, shell, "/usr/bin/zsh")) .usr_bin else return error.UnsupportedBootstrapShell,
        };
        // Only Darwin arm64 has passed the production private protocol and
        // cleanup runtime gate. Cross-built Linux candidates stay unavailable.
        if (platform.platform != .darwin_aarch64) return error.BootstrapPlatformNotValidated;
        return platform;
    }
    pub fn platformName(self: Facts) []const u8 {
        return switch (self.platform) {
            .darwin_aarch64 => "darwin-aarch64",
            .linux_x86_64 => "linux-x86_64",
            .linux_aarch64 => "linux-aarch64",
        };
    }
    pub fn probe(self: Facts) bootstrap.Probe {
        return .{ .os = if (self.platform == .darwin_aarch64) "Darwin" else "Linux", .arch = switch (self.platform) {
            .darwin_aarch64 => "arm64",
            .linux_x86_64 => "x86_64",
            .linux_aarch64 => "aarch64",
        }, .shell_path = if (self.shell_path == .bin) "/bin/zsh" else "/usr/bin/zsh", .shell_version = "5.9" };
    }
};

pub const Probed = struct {
    facts: Facts,
    endpoint: [1024]u8 = @splat(0),
    endpoint_len: usize = 0,
    pub fn init(facts: Facts, user: []const u8, hostname: []const u8, port: u16) !Probed {
        var self: Probed = .{ .facts = facts };
        const text = try std.fmt.bufPrint(&self.endpoint, "{s}@{s}:{d}", .{ user, hostname, port });
        self.endpoint_len = text.len;
        return self;
    }
    pub fn target(self: *const Probed) []const u8 {
        return self.endpoint[0..self.endpoint_len];
    }
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    context: host.Context,
    operation: identity.HostOperationId,
    source: identity.SessionHandle,
    target: [1024]u8,
    target_len: usize,
    package: bootstrap.Package,
    plan: bootstrap.Plan,
    pub fn create(a: std.mem.Allocator, io: std.Io, context: host.Context, operation: identity.HostOperationId, source: identity.SessionHandle, owner: identity.SessionHandle, probed: Probed) !*Prepared {
        const facts = probed.facts;
        var package = try bootstrap.Package.loadBundled(a, io, facts.platformName());
        errdefer package.deinit();
        return createWithPackage(a, context, operation, source, owner, probed, package);
    }
    /// Package ownership transfers only on success. Production uses the bundled
    /// loader above; this seam also permits resource-free unit fixtures.
    pub fn createWithPackage(a: std.mem.Allocator, context: host.Context, operation: identity.HostOperationId, source: identity.SessionHandle, owner: identity.SessionHandle, probed: Probed, package: bootstrap.Package) !*Prepared {
        const facts = probed.facts;
        try context.validate();
        if (probed.endpoint_len == 0 or probed.endpoint_len > probed.endpoint.len) return error.InvalidBootstrapTarget;
        if (!operation.valid() or source.eql(owner)) return error.InvalidBootstrapOwner;
        if (facts.platform != .darwin_aarch64) return error.BootstrapPlatformNotValidated;
        const self = try a.create(Prepared);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .context = context, .operation = operation, .source = source, .target = probed.endpoint, .target_len = probed.endpoint_len, .package = package, .plan = undefined };
        self.plan = try bootstrap.Plan.prepare(owner, context.task_id, &self.package, facts.probe(), true);
        return self;
    }
    pub fn retain(self: *Prepared) *Prepared {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *Prepared) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.package.deinit();
        self.allocator.destroy(self);
    }
    pub fn matches(self: *const Prepared, context: host.Context, operation: identity.HostOperationId, owner: identity.SessionHandle, source: identity.SessionHandle) bool {
        return self.context.eql(context) and self.operation.eql(operation) and self.source.eql(source) and self.plan.owner.eql(owner) and self.plan.task_id.eql(context.task_id);
    }
    pub fn subject(self: *const Prepared, a: std.mem.Allocator) !approvals.Subject {
        return .{ .kind = .lifecycle, .target = "SSH BootstrapV1：本次临时 helper 部署", .detail = try self.detail(a), .impact = "明确允许通过现有 SFTP 仅写入所列任务目录与三个已校验资源，再启动本次新 owned PTY。运行结束删除精确资源；清理无法确认时保留 cleanup_pending 回执。此授权不执行用户命令，不修改用户启动配置。" };
    }
    /// The grant is derived from the broker's exact live approved subject, never
    /// from a caller-supplied bool or a prior creation/route approval.
    pub fn approve(self: *Prepared, broker: *approvals.Broker, permit: approvals.Permit, invocation: host.Invocation, policy_revision: u64, now_ms: i64, a: std.mem.Allocator) !void {
        if (!self.context.eql(invocation.context)) return error.StaleBootstrapAuthorization;
        const exact = try self.subject(a);
        defer a.free(exact.detail);
        const expires_at = broker.authorizedSubjectExpiry(permit, invocation, exact, policy_revision) orelse return error.StaleBootstrapAuthorization;
        if (expires_at <= now_ms or expires_at - now_ms > 120_000) return error.StaleBootstrapAuthorization;
        self.plan.permit = .{ .owner = self.plan.owner, .task_id = invocation.context.task_id, .plan_hash = self.plan.hash(), .expires_at = expires_at };
        try self.plan.validate(self.plan.owner, now_ms);
    }
    pub fn detail(self: *const Prepared, a: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "临时部署 BootstrapV1 到本次新工作终端。\n目标={s}\nCID={s}\nTask={s}\nOperation={s}\n来源 SID={d}, generation={d}\n新目标 SID={d}, generation={d}\n平台={s}; shell={s} 5.9\n任务独享目录={s} (0700)\nmanifest SHA-256={s}\nbootstrap SHA-256={s} (0700)\nzw_execution.so SHA-256={s} (0600)\nexecution.zsh SHA-256={s} (0600)\nPlan SHA-256={s}", .{ self.target[0..self.target_len], std.fmt.bytesToHex(self.context.conversation_id.bytes, .lower), std.fmt.bytesToHex(self.context.task_id.bytes, .lower), std.fmt.bytesToHex(self.operation.bytes, .lower), @backingInt(self.source.session_id), self.source.generation, @backingInt(self.plan.owner.session_id), self.plan.owner.generation, self.package.platform, if (self.plan.shell_path == .bin) "/bin/zsh" else "/usr/bin/zsh", self.plan.directory, std.fmt.bytesToHex(self.package.manifest_hash, .lower), std.fmt.bytesToHex(self.package.hashes[0], .lower), std.fmt.bytesToHex(self.package.hashes[1], .lower), std.fmt.bytesToHex(self.package.hashes[2], .lower), std.fmt.bytesToHex(self.plan.hash(), .lower) });
    }
};

test "bootstrap product parses exact read-only probe and rejects unvalidated platforms and startup noise" {
    const facts = try Facts.parse("ZWBOOTSTRAP_PROBE_V1\nDarwin\narm64\n/bin/zsh\n5.9\n", "", 0, false);
    try std.testing.expectEqualStrings("darwin-aarch64", facts.platformName());
    try std.testing.expectError(error.BootstrapPlatformNotValidated, Facts.parse("ZWBOOTSTRAP_PROBE_V1\nLinux\nx86_64\n/bin/zsh\n5.9\n", "", 0, false));
    try std.testing.expectError(error.BootstrapProbeFailed, Facts.parse("user startup\nZWBOOTSTRAP_PROBE_V1\nDarwin\narm64\n/bin/zsh\n5.9\n", "", 0, false));
    try std.testing.expectError(error.UnsupportedBootstrapShell, Facts.parse("ZWBOOTSTRAP_PROBE_V1\nDarwin\narm64\n/bin/zsh\n5.8\n", "", 0, false));
}

fn testPrepared() !*Prepared {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const bytes = [_][]const u8{ "launcher fixture", "module fixture", "zsh fixture" };
    var package: bootstrap.Package = .{ .arena = arena, .platform = "darwin-aarch64", .manifest_hash = @splat(7), .files = bytes, .hashes = undefined };
    for (bytes, &package.hashes) |value, *hash| std.crypto.hash.sha2.Sha256.hash(value, hash, .{});
    const context: host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = 7 }, .binding_revision = 2, .grant_revision = 3 };
    const source: identity.SessionHandle = .{ .session_id = @fromBackingInt(10), .generation = 4 };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(11), .generation = 1 };
    return Prepared.createWithPackage(a, context, identity.HostOperationId.generate(), source, owner, try Probed.init(.{ .platform = .darwin_aarch64, .shell_path = .bin }, "fixture", "controlled.test", 2222), package);
}

test "bootstrap product exact second approval owns target hash and cannot reuse creation or changed plan" {
    const a = std.testing.allocator;
    const prepared = try testPrepared();
    defer prepared.release();
    try std.testing.expectError(error.BootstrapDeploymentAuthorizationRequired, prepared.plan.validate(prepared.plan.owner, 100));
    var clock: i64 = 100;
    const Clock = struct {
        fn now(raw: ?*anyopaque) i64 {
            const value: *i64 = @ptrCast(@alignCast(raw.?));
            return value.*;
        }
    };
    var broker: approvals.Broker = .{ .clock_context = &clock, .clock = Clock.now };
    try broker.configure(prepared.context, 9);
    const json = "{\"request_key\":\"bootstrap-fixture\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &hash, .{});
    const invocation: host.Invocation = .{ .context = prepared.context, .authority = .lifecycle, .operation_id = 1, .turn_id = 1, .call_id = "bootstrap-fixture", .tool_id = "host.open_session", .arguments = parsed.value, .arguments_json = json, .arguments_hash = hash, .canonical_arguments_hash = try @import("canonical_arguments.zig").digest(a, parsed.value) };
    const creation = try broker.beginSubject(invocation, .{ .kind = .lifecycle, .target = "host.open_session", .detail = json, .impact = "create shell" }, 9, a);
    try broker.decide(creation.sequence, creation.arguments_hash, true);
    try std.testing.expectError(error.StaleBootstrapAuthorization, prepared.approve(&broker, creation, invocation, 9, clock, a));
    try std.testing.expect(prepared.plan.permit == null);
    broker.finish(creation);
    const exact = try prepared.subject(a);
    defer a.free(exact.detail);
    try std.testing.expect(std.mem.indexOf(u8, exact.detail, "fixture@controlled.test:2222") != null);
    try std.testing.expect(std.mem.indexOf(u8, exact.detail, &prepared.plan.directory) != null);
    const approval = try broker.beginSubject(invocation, exact, 9, a);
    try std.testing.expectError(error.StaleBootstrapAuthorization, prepared.approve(&broker, approval, invocation, 9, clock, a));
    try broker.decide(approval.sequence, approval.arguments_hash, true);
    try prepared.approve(&broker, approval, invocation, 9, clock, a);
    try prepared.plan.validate(prepared.plan.owner, clock);
    const retained = prepared.retain();
    retained.release();
    var other = prepared.context;
    other.task_id = identity.TaskId.generate();
    try std.testing.expect(!prepared.matches(other, prepared.operation, prepared.plan.owner, prepared.source));
    other = prepared.context;
    other.conversation_id = identity.ConversationId.generate();
    try std.testing.expect(!prepared.matches(other, prepared.operation, prepared.plan.owner, prepared.source));
    prepared.plan.directory[52] = if (prepared.plan.directory[52] == '0') '1' else '0';
    try std.testing.expectError(error.StaleBootstrapAuthorization, prepared.plan.validate(prepared.plan.owner, clock));
    try std.testing.expectError(error.StaleBootstrapAuthorization, prepared.approve(&broker, approval, invocation, 9, clock, a));
}

test "bootstrap product expiry and source generations fence the retained plan" {
    const a = std.testing.allocator;
    const prepared = try testPrepared();
    defer prepared.release();
    const detail = try prepared.detail(a);
    defer a.free(detail);
    var stale = prepared.source;
    stale.generation += 1;
    try std.testing.expect(!prepared.matches(prepared.context, prepared.operation, prepared.plan.owner, stale));
    var owner = prepared.plan.owner;
    owner.generation += 1;
    prepared.plan.permit = .{ .owner = prepared.plan.owner, .task_id = prepared.context.task_id, .plan_hash = prepared.plan.hash(), .expires_at = 200 };
    try std.testing.expectError(error.StaleBootstrapOwner, prepared.plan.validate(owner, 100));
    try std.testing.expectError(error.StaleBootstrapAuthorization, prepared.plan.validate(prepared.plan.owner, 200));
}
