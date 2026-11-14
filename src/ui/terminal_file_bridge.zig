const std = @import("std");
const identity = @import("../host/identity.zig");
const sessions = @import("../host/session_host.zig");
const files = @import("../host/terminal_files.zig");
const tools = @import("../ai/plugin_tools.zig");
const provider = @import("../ai/provider.zig");
const Job = @import("terminal_file_job.zig").Job;
const App = @import("application_host.zig").ApplicationHost;
const Exchange = struct {
    invocation: tools.Invocation,
    allocator: std.mem.Allocator,
    ready: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    result: ?tools.ToolResult = null,
    failure: ?anyerror = null,
};
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    capture: ?struct { owner: identity.SessionHandle, binding: sessions.ServiceHandle, cwd: ?[]const u8 } = null,
    mutex: std.atomic.Mutex = .unlocked,
    exchange: ?*Exchange = null,
    job: ?*Job = null,
    operation_id: ?u64 = null,
    fn lock(self: *Bridge) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn execute(self: *Bridge, invocation: tools.Invocation, a: std.mem.Allocator, cancel: ?*provider.CancelToken) !tools.ToolResult {
        var exchange: Exchange = .{ .invocation = invocation, .allocator = a };
        self.lock();
        if (self.capture == null or self.exchange != null or self.job != null or !self.capture.?.owner.eql(invocation.owner)) {
            self.mutex.unlock();
            return error.StaleBinding;
        }
        self.exchange = &exchange;
        self.mutex.unlock();
        while (!exchange.ready.load(.acquire)) {
            if (cancel) |token| if (token.isCancelled()) exchange.cancel.store(true, .release);
            var delay: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms * 5 };
            _ = std.c.nanosleep(&delay, null);
        }
        self.lock();
        self.exchange = null;
        self.mutex.unlock();
        if (exchange.failure) |err| return err;
        return exchange.result orelse error.ToolOutcomeUnknown;
    }
    pub fn pump(self: *Bridge, app: *App) void {
        self.lock();
        defer self.mutex.unlock();
        const current = self.exchange orelse {
            if (self.job) |job| {
                job.stop();
                job.tick(app);
                if (job.done) {
                    if (self.operation_id) |id| app.domain.operation_history.resourcesReleased(job.owner, id) catch {};
                    job.deinit();
                    self.job = null;
                    self.operation_id = null;
                }
            }
            return;
        };
        if (current.ready.load(.acquire)) return;
        if (self.job) |job| {
            if (current.cancel.load(.acquire)) job.stop();
            job.tick(app);
            if (!job.done) {
                if (job.reportable) {
                    current.result = result(current, job) catch |err| {
                        current.failure = err;
                        current.ready.store(true, .release);
                        return;
                    };
                    current.ready.store(true, .release);
                }
                return;
            }
            defer {
                job.deinit();
                self.job = null;
                self.operation_id = null;
            }
            current.result = result(current, job) catch |err| {
                current.failure = err;
                current.ready.store(true, .release);
                return;
            };
            current.ready.store(true, .release);
            return;
        }
        self.start(app, current) catch |err| {
            current.result = rejected(current, err) catch |allocation_error| {
                current.failure = allocation_error;
                current.ready.store(true, .release);
                return;
            };
            current.ready.store(true, .release);
        };
    }
    fn start(self: *Bridge, app: *App, current: *Exchange) !void {
        if (current.cancel.load(.acquire)) return error.CancelledBeforeDispatch;
        const captured = self.capture orelse return error.StaleBinding;
        if (!app.sessions.bindingIsLive(captured.binding)) return error.StaleBinding;
        const args = try std.json.parseFromSlice(@import("../ai/terminal_file_tools.zig").Arguments, self.allocator, current.invocation.arguments_json, .{});
        defer args.deinit();
        if (args.value.session_ids.len != 1 or args.value.session_ids[0] != @backingInt(captured.owner.session_id)) return error.TargetOutsideAssistant;
        const request = try @import("../ai/terminal_file_tools.zig").request(current.invocation.tool_id, args.value);
        self.job = try Job.start(self.allocator, app, captured.owner, request, captured.cwd);
        self.operation_id = current.invocation.operation_id;
    }
    pub fn stop(self: *Bridge) sessions.CloseReceipt {
        self.lock();
        defer self.mutex.unlock();
        if (self.exchange) |current| current.cancel.store(true, .release);
        if (self.job) |job| {
            job.stop();
            if (job.reportable and !job.done) return .unknown;
        }
        return if (self.exchange != null or self.job != null) .awaiting else .released;
    }
    pub fn busy(self: *Bridge) bool {
        self.lock();
        defer self.mutex.unlock();
        return self.exchange != null or self.job != null;
    }
    pub fn fingerprint(self: *Bridge, owner: identity.SessionHandle) u64 {
        self.lock();
        defer self.mutex.unlock();
        const captured = self.capture orelse return 0;
        if (!captured.owner.eql(owner)) return 0;
        return if (self.exchange) |current| current.invocation.operation_id else self.operation_id orelse 0;
    }
    pub fn clear(self: *Bridge) !void {
        if (self.busy()) return error.ToolCleanupPending;
        self.capture = null;
    }
    /// Exceptional teardown wakes the AI worker while retaining any still-live
    /// job. clear() keeps rejecting until its real cleanup has been consumed.
    pub fn shutdown(self: *Bridge, app: ?*App) void {
        _ = self.stop();
        if (app) |host| self.pump(host);
        self.lock();
        defer self.mutex.unlock();
        if (self.exchange) |current| if (!current.ready.load(.acquire)) {
            if (self.job) |job| {
                if (job.thread == null) {
                    job.result.failure = job.result.failure orelse error.ToolHostShuttingDown;
                    if (job.active != null and job.stage == .write and !job.result.committed) job.result.outcome_unknown = true;
                    current.result = result(current, job) catch |err| blk: {
                        current.failure = err;
                        break :blk null;
                    };
                } else current.failure = error.ToolOutcomeUnknown;
            } else current.result = rejected(current, error.CancelledBeforeDispatch) catch |err| blk: {
                current.failure = err;
                break :blk null;
            };
            current.ready.store(true, .release);
        };
    }
};
fn result(exchange: *Exchange, job: *Job) !tools.ToolResult {
    const a = exchange.allocator;
    var value = job.result;
    var text: []const u8 = "";
    var next: ?usize = null;
    if (job.request.kind == .read_text and value.failure == null) {
        if (job.request.expected_version.len != 0 and !std.mem.eql(u8, job.request.expected_version, &value.version)) value.failure = error.SourceChanged else if (job.request.offset > value.bytes.len) value.failure = error.InvalidFileOffset else {
            const begin = job.request.offset;
            if (!std.unicode.utf8ValidateSlice(value.bytes[0..begin])) value.failure = error.InvalidFileOffset else {
                var end = @min(value.bytes.len, begin + job.request.max_bytes);
                while (end > begin and !std.unicode.utf8ValidateSlice(value.bytes[begin..end])) end -= 1;
                text = value.bytes[begin..end];
                if (end < value.bytes.len) next = end;
            }
        }
    }
    const known_version: ?[]const u8 = if (value.version[0] == 0) null else &value.version;
    const body = try std.json.Stringify.valueAlloc(a, .{
        .path = job.request.path,
        .host = if (value.failure != null) job.ssh_host else null,
        .session_id = @backingInt(job.owner.session_id),
        .text = text,
        .version = known_version,
        .size = value.bytes.len,
        .next_offset = next,
        .truncated = next != null,
        .committed = value.committed,
        .verified = value.verified,
        .outcome_unknown = value.outcome_unknown,
        .error_code = if (value.failure) |err| @errorName(err) else null,
    }, .{});
    errdefer a.free(body);
    const blocks = try a.alloc(tools.ContentBlock, 1);
    blocks[0] = .{ .structured = body };
    return .{ .status = if (value.outcome_unknown) .outcome_unknown else if (value.failure != null) .failed else .succeeded, .blocks = blocks, .receipt = .{ .owner = job.owner, .operation_id = exchange.invocation.operation_id, .local_released = job.done, .remote_effect_unknown = value.outcome_unknown } };
}
fn rejected(exchange: *Exchange, err: anyerror) !tools.ToolResult {
    const a = exchange.allocator;
    const body = try std.json.Stringify.valueAlloc(a, .{ .error_code = @errorName(err), .committed = false, .verified = false, .outcome_unknown = false }, .{});
    errdefer a.free(body);
    const blocks = try a.alloc(tools.ContentBlock, 1);
    blocks[0] = .{ .structured = body };
    return .{ .status = .rejected, .blocks = blocks, .receipt = .{ .owner = exchange.invocation.owner, .operation_id = exchange.invocation.operation_id } };
}

test "terminal files shutdown preserves known commits and distinguishes an undispatched exchange" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    var current: Exchange = .{ .allocator = a, .invocation = .{ .owner = owner, .operation_id = 7, .tool_id = "file.write_text", .arguments = .null, .arguments_json = "{}", .arguments_hash = @splat(0) } };
    defer if (current.result) |*value| value.deinit(a);
    var job: Job = .{ .allocator = a, .arena = .init(a), .owner = owner, .binding = undefined, .request = .{ .kind = .write_text, .path = "/tmp/committed" }, .local = false, .started_ns = 0, .stage = .verify, .result = .{ .committed = true } };
    defer job.arena.deinit();
    var bridge: Bridge = .{ .allocator = a, .exchange = &current, .job = &job };
    bridge.shutdown(null);
    try std.testing.expect(current.ready.load(.acquire) and current.failure == null);
    try std.testing.expect(!current.result.?.receipt.remote_effect_unknown and !current.result.?.receipt.local_released);
    const facts = try std.json.parseFromSlice(std.json.Value, a, current.result.?.blocks[0].structured, .{});
    defer facts.deinit();
    try std.testing.expect(facts.value.object.get("committed").?.bool);
    try std.testing.expect(!facts.value.object.get("verified").?.bool);
    try std.testing.expect(facts.value.object.get("version").? == .null);
    try std.testing.expectError(error.ToolCleanupPending, bridge.clear());
    current.result.?.deinit(a);
    current.result = null;
    current.ready.store(false, .release);
    bridge.job = null;
    bridge.shutdown(null);
    try std.testing.expectEqual(tools.Status.rejected, current.result.?.status);
    try std.testing.expect(current.result.?.receipt.local_released and !current.result.?.receipt.remote_effect_unknown);
}

test "terminal files InvalidParent result identifies the SSH host and path with a settled failure" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(3), .generation = 1 };
    var current: Exchange = .{ .allocator = a, .invocation = .{ .owner = owner, .operation_id = 475, .tool_id = "file.write_text", .arguments = .null, .arguments_json = "{}", .arguments_hash = @splat(0) } };
    var job: Job = .{ .allocator = a, .arena = .init(a), .owner = owner, .binding = undefined, .request = .{ .kind = .write_text, .path = "/data/imgxfer/verify_inner.sh" }, .local = false, .ssh_host = "10.2.209.201", .started_ns = 0, .done = true, .result = .{ .failure = error.InvalidParent } };
    defer job.arena.deinit();
    var receipt = try result(&current, &job);
    defer receipt.deinit(a);
    try receipt.validate(owner, 475);
    try std.testing.expectEqual(tools.Status.failed, receipt.status);
    try std.testing.expect(receipt.receipt.local_released and !receipt.receipt.remote_effect_unknown);
    const facts = try std.json.parseFromSlice(std.json.Value, a, receipt.blocks[0].structured, .{});
    defer facts.deinit();
    try std.testing.expectEqualStrings("10.2.209.201", facts.value.object.get("host").?.string);
    try std.testing.expectEqualStrings(job.request.path, facts.value.object.get("path").?.string);
    try std.testing.expectEqualStrings("InvalidParent", facts.value.object.get("error_code").?.string);
    try std.testing.expect(!facts.value.object.get("committed").?.bool and !facts.value.object.get("outcome_unknown").?.bool);
}
