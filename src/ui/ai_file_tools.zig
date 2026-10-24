//! File-provider compatibility bridge. It owns no terminal or exec binding and
//! reads only the original FileBindingHost session through its bounded reader.
const std = @import("std");
const App = @import("application_host.zig").ApplicationHost;
const identity = @import("../host/identity.zig");
const sessions = @import("../host/session_host.zig");
const provider = @import("../ai/provider.zig");
const loop = @import("../ai/tool_loop.zig");
const scope = @import("../ai/tool_scope.zig");
const adapter = @import("../ai/legacy_adapter.zig");
const capture = @import("../host/ai_remote_file_snapshot.zig");
const bindings = @import("../host/file_binding_host.zig");
const projection = @import("ai_file_tool_result.zig");
const Capture = struct { owner: identity.SessionHandle, bindings: bindings.Bindings, target: []u8, cwd: ?[]const u8 = null };
const Exchange = struct { invocation: loop.Invocation, allocator: std.mem.Allocator, ready: std.atomic.Value(bool) = .init(false), cancel: std.atomic.Value(bool) = .init(false), outcome: ?loop.Outcome = null, failure: ?anyerror = null };
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    files: ?*@import("file_application_host.zig").Host = null,
    capture: ?Capture = null,
    delegated_owner: ?scope.Owner = null,
    exchange: ?*Exchange = null,
    reader: ?*capture.Reader = null,
    sequence: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,
    stopping: bool = false,
    pub fn init(a: std.mem.Allocator) Bridge {
        return .{ .allocator = a };
    }
    fn lock(self: *Bridge) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn prepare(self: *Bridge, app: *App, owner: identity.SessionHandle) !void {
        if (self.exchange != null or self.reader != null or self.capture != null) return error.ToolCleanupPending;
        const files = self.files orelse return error.FileSourceUnavailable;
        const source = try files.ensureReadonlySource(owner);
        if (!app.sessions.bindingIsLive(source.directory) or !app.sessions.bindingIsLive(source.file_read)) return error.StaleBinding;
        const id = app.legacyForHandle(owner) orelse return error.StaleSession;
        const tab = app.workspace.sessionTab(id) orelse return error.StaleSession;
        self.capture = .{ .owner = owner, .bindings = source, .target = try std.fmt.allocPrint(self.allocator, "文件 · {s}", .{tab.titleSlice()}) };
        self.stopping = false;
    }
    pub fn filesAvailable(self: *Bridge) bool {
        return self.files != null and self.capture != null;
    }
    pub fn preflight(self: *Bridge, app: *App, invocation: loop.Invocation) !void {
        const source = self.capture orelse return error.ServiceUnavailable;
        if (invocation.call.tool != .list_remote_files and invocation.call.tool != .read_remote_file) return error.UnsupportedTool;
        if (invocation.call.targets.len != 1 or invocation.call.targets.ids[0] != @backingInt(source.owner.session_id)) return error.TargetOutsideAssistant;
        if (!(self.delegated_owner orelse scope.Owner{ .session = @backingInt(source.owner.session_id) }).eql(invocation.key.owner)) return error.TargetOutsideAssistant;
        _ = try invocation.scope.validate(invocation.call.targets.slice());
        if (!app.sessions.bindingIsLive(source.bindings.directory) or !app.sessions.bindingIsLive(source.bindings.file_read) or app.legacyForHandle(source.owner) == null) return error.StaleBinding;
        const directory = switch (app.sessions.queryService(source.owner, .directory)) {
            .available => |binding| binding,
            else => return error.StaleBinding,
        };
        const file_read = switch (app.sessions.queryService(source.owner, .file_read)) {
            .available => |binding| binding,
            else => return error.StaleBinding,
        };
        if (!directory.eql(source.bindings.directory) or !file_read.eql(source.bindings.file_read)) return error.StaleBinding;
    }
    pub fn interface(self: *Bridge) loop.Host {
        return .{ .context = self, .execute = execute };
    }
    fn execute(raw: *anyopaque, invocation: loop.Invocation, a: std.mem.Allocator, cancel: ?*provider.CancelToken) !loop.Outcome {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        var exchange: Exchange = .{ .invocation = invocation, .allocator = a };
        self.lock();
        if (self.stopping or self.exchange != null) {
            self.mutex.unlock();
            return error.ToolHostUnavailable;
        }
        self.sequence = try identity.advance(self.sequence +| @intFromBool(self.sequence == 0));
        self.exchange = &exchange;
        self.mutex.unlock();
        defer {
            self.lock();
            self.exchange = null;
            self.mutex.unlock();
        }
        while (!exchange.ready.load(.acquire)) {
            if (cancel) |token| if (token.isCancelled()) exchange.cancel.store(true, .release);
            pause();
        }
        if (exchange.failure) |err| return err;
        return exchange.outcome orelse error.ToolOutcomeUnknown;
    }
    fn finish(self: *Bridge, result: loop.TargetResult) void {
        const current = self.exchange orelse return;
        if (current.ready.load(.acquire)) return;
        current.outcome = loop.Outcome.copy(current.allocator, &.{result}) catch |err| {
            current.failure = err;
            current.ready.store(true, .release);
            return;
        };
        current.ready.store(true, .release);
    }
    pub fn pump(self: *Bridge, app: *App) void {
        self.lock();
        defer self.mutex.unlock();
        const current = self.exchange orelse return;
        if (current.ready.load(.acquire) and self.reader == null) return;
        const source = self.capture orelse return;
        const valid = blk: {
            self.preflight(app, current.invocation) catch break :blk false;
            break :blk true;
        };
        const context: capture.Context = .{ .scope = current.invocation.scope, .source = .{ .session = source.owner, .revision = self.sequence, .bindings = source.bindings } };
        const cancelled = self.stopping or current.cancel.load(.acquire) or !valid;
        if (self.reader == null) {
            if (cancelled) {
                self.finish(.{ .session_id = @backingInt(source.owner.session_id), .status = if (valid) .cancelled else .rejected, .transport = .sftp, .error_code = if (valid) "CancelledBeforeDispatch" else "StaleBinding" });
                return;
            }
            const host = (self.files orelse return).file_host orelse return;
            self.reader = capture.Reader.start(self.allocator, host, context, current.invocation.call.path, if (current.invocation.call.tool == .list_remote_files) .{ .list = .{} } else .{ .read = .{ .max_bytes = current.invocation.call.max_bytes } }) catch |err| {
                self.finish(.{ .session_id = @backingInt(source.owner.session_id), .status = .failed, .transport = .sftp, .error_code = @errorName(err) });
                return;
            };
        }
        const reader = self.reader.?;
        if (cancelled) reader.cancel();
        _ = reader.poll(if (valid) context else null);
        if (reader.cleanupReceipt() == .unknown) {
            self.finish(.{ .session_id = @backingInt(source.owner.session_id), .status = .unknown, .transport = .sftp, .local_released = false, .error_code = "SftpCleanupUnknown" });
            return;
        }
        if (!reader.terminal or !reader.retired) return;
        var captured = reader.take() orelse return;
        defer captured.release();
        defer {
            reader.deinit() catch unreachable;
            self.reader = null;
        }
        const value = captured.value().?;
        if (value.body == .failure) {
            self.finish(.{ .session_id = @backingInt(source.owner.session_id), .status = if (value.body.failure == .cancelled) .cancelled else .failed, .transport = .sftp, .error_code = projection.failureCode(value.body.failure) });
            return;
        }
        const output = projection.project(current.allocator, value, @min(current.invocation.capture_bytes, 65536)) catch |err| {
            self.finish(.{ .session_id = @backingInt(source.owner.session_id), .status = .failed, .transport = .sftp, .error_code = @errorName(err) });
            return;
        };
        defer output.deinit(current.allocator);
        self.finish(.{ .session_id = @backingInt(source.owner.session_id), .status = .succeeded, .transport = .sftp, .stdout = output.stdout, .stderr = output.stderr, .truncated = output.truncated });
    }
    pub fn pendingApproval(_: *Bridge) ?adapter.Approval {
        return null;
    }
    pub fn decide(_: *Bridge, _: u64, _: [32]u8, _: bool) !void {
        return error.StaleApproval;
    }
    pub fn stopOwner(self: *Bridge, owner: identity.SessionHandle) sessions.CloseReceipt {
        self.lock();
        defer self.mutex.unlock();
        const source = self.capture orelse return .released;
        if (!source.owner.eql(owner)) return .released;
        self.stopping = true;
        if (self.exchange) |exchange| exchange.cancel.store(true, .release);
        if (self.reader) |reader| {
            reader.cancel();
            return .awaiting;
        }
        return if (self.exchange != null) .awaiting else .released;
    }
    pub fn writeRisk(_: *Bridge, _: identity.SessionHandle) bool {
        return false;
    }
    pub fn closeImpact(self: *Bridge, owner: identity.SessionHandle) @import("group_close_controller.zig").Impact {
        return .{ .ai = if (self.capture != null and self.capture.?.owner.eql(owner) and self.exchange != null) self.sequence else 0 };
    }
    pub fn shutdown(self: *Bridge, app: ?*App) void {
        if (self.capture) |source| _ = self.stopOwner(source.owner);
        if (app) |host| self.pump(host);
    }
    pub fn clear(self: *Bridge) !void {
        if (self.exchange != null or self.reader != null) return error.ToolCleanupPending;
        if (self.capture) |source| self.allocator.free(source.target);
        self.capture = null;
    }
    pub fn deinit(self: *Bridge) void {
        self.clear() catch unreachable;
        self.* = undefined;
    }
    pub fn assembleContext(a: std.mem.Allocator, raw: *anyopaque, owner: identity.SessionHandle, _: u32, redact: bool) !@import("../ai/assembler.zig").Assembled {
        const app: *App = @ptrCast(@alignCast(raw));
        const manifest = app.sessions.manifestFor(owner) orelse return error.StaleSession;
        const text = try std.fmt.allocPrint(a, "provider={s} session_id={d} generation={d}\nRemote file session. Only directory and bounded text-file tools are available.\n", .{ if (redact) "<redacted>" else manifest.display_name, @backingInt(owner.session_id), owner.generation });
        return .{ .text = text, .tokens = @import("../ai/card.zig").estimateTokens(text.len), .truncated = false };
    }
};
pub fn createAdapter(a: std.mem.Allocator) !adapter.Adapter {
    return adapter.Adapter.create(Bridge, App, a);
}
fn pause() void {
    var duration: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&duration, null);
}
