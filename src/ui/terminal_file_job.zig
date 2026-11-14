//! Main-thread terminal file operation. Workers own only immutable input/bytes.
const std = @import("std");
const applog = @import("../platform/applog.zig");
const files = @import("../host/terminal_files.zig");
const identity = @import("../host/identity.zig");
const sessions = @import("../host/session_host.zig");
const exec = @import("../ai/execbridge.zig");
const App = @import("application_host.zig").ApplicationHost;
const images = @import("../ai/image_attachments.zig");
// A single writer is sufficient for these bounded operations and serializes
// this application's own competing Local/SSH file commits.
var mutation_mutex: std.atomic.Mutex = .unlocked;
pub const Job = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    owner: identity.SessionHandle,
    binding: sessions.ServiceHandle,
    request: files.Request,
    local: bool,
    ssh_host: ?[]const u8 = null,
    result: files.Result = .{},
    image: images.ContentRef = .{},
    cancel: @import("../ai/provider.zig").CancelToken = .{},
    worker_done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    done: bool = false,
    reportable: bool = false,
    started_ns: i128,
    stage: enum { read, write, verify } = .read,
    command: ?[]const u8 = null,
    input: ?[]const u8 = null,
    active: ?struct { facade: exec.ExecBridge, handle: exec.ExecHandle, key: sessions.OperationKey } = null,
    before: []const u8 = "",
    after: []const u8 = "",
    stamp: []const u8 = "",
    stale: bool = false,
    mutation_locked: bool = false,

    pub fn start(a: std.mem.Allocator, app: *App, owner: identity.SessionHandle, request: files.Request, cwd: ?[]const u8) !*Job {
        const tab = app.workspace.sessionTab(app.legacyForHandle(owner) orelse return error.StaleSession) orelse return error.StaleSession;
        const manifest = app.sessions.manifestFor(owner) orelse return error.StaleSession;
        if (!std.mem.eql(u8, manifest.id, "local") and !std.mem.eql(u8, manifest.id, "ssh")) return error.UnsupportedFileTarget;
        const binding = switch (app.sessions.queryService(owner, .exec)) {
            .available => |value| value,
            else => return error.ServiceUnavailable,
        };
        if (tab.closing or tab.failed or tab.archived or !app.sessions.bindingIsLive(binding)) return error.StaleBinding;
        const self = try a.create(Job);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .arena = .init(a), .owner = owner, .binding = binding, .request = request, .local = tab.local, .started_ns = @import("../platform/realtime.zig").monotonicNs() };
        errdefer self.arena.deinit();
        if (request.kind == .write_text or request.kind == .edit_text) {
            if (!mutation_mutex.tryLock()) return error.FileBusy;
            self.mutation_locked = true;
        }
        errdefer if (self.mutation_locked) mutation_mutex.unlock();
        const storage = self.arena.allocator();
        const json = try std.json.Stringify.valueAlloc(storage, request, .{});
        self.request = try std.json.parseFromSliceLeaky(files.Request, storage, json, .{});
        var scope_hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&scope_hash, binding.binding_id);
        std.hash.autoHash(&scope_hash, binding.binding_generation);
        self.request.version_scope = scope_hash.final();
        if (!self.local) {
            const remote = tab.host_snapshot orelse return error.ServiceUnavailable;
            self.ssh_host = try storage.dupe(u8, remote.value.host);
            if (request.path.len > 0 and request.path[0] != '/') {
                const runtime = tab.runtime orelse return error.ServiceUnavailable;
                const shell = try (try runtime.terminalService()).executionSnapshot();
                // A cwd reported by a nested PTY shell does not belong to SSH exec.
                if (shell.shell.depth != 0 or shell.shell_switch.pending) return error.SshFileAbsolutePathRequired;
            }
        }
        self.request.path = try files.pathFor(storage, request.path, cwd);
        if (self.local) {
            const paths = try @import("../config/paths.zig").Paths.forApplication(storage);
            self.request.app_data_root = paths.directory;
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }
        return self;
    }
    fn run(self: *Job) void {
        defer self.worker_done.store(true, .release);
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        defer threaded.deinit();
        if (self.local) files.local(self.arena.allocator(), threaded.io(), self.owner, self.request, &self.cancel, &self.result) catch |err| {
            self.result.failure = err;
        };
        if (self.request.kind == .read_image and self.result.failure == null and !self.cancel.isCancelled()) {
            self.image = images.ContentRef.create(self.allocator, self.request.path, self.result.bytes, @import("../platform/realtime.zig").milliseconds(undefined), .{}) catch |err| {
                self.result.failure = err;
                return;
            };
        }
    }
    pub fn stop(self: *Job) void {
        self.cancel.cancel();
    }
    fn valid(self: *Job, app: *App) bool {
        if (!app.sessions.bindingIsLive(self.binding)) return false;
        const tab = app.workspace.sessionTab(app.legacyForHandle(self.owner) orelse return false) orelse return false;
        return tab.content_owner.eql(.{ .session = self.owner }) and !tab.closing and !tab.failed and !tab.archived;
    }
    pub fn tick(self: *Job, app: *App) void {
        if (self.done) return;
        if (!self.valid(app)) {
            self.stale = true;
            self.stop();
        }
        if (@import("../platform/realtime.zig").monotonicNs() - self.started_ns > 30 * std.time.ns_per_s) self.stop();
        if (self.thread) |thread| {
            if (!self.worker_done.load(.acquire)) return;
            thread.join();
            self.thread = null;
            self.done = true;
            if (self.stale and !self.result.committed) self.result.failure = error.StaleBinding;
            return;
        }
        if (self.active) |active| {
            var snapshot = active.facade.snapshot(active.handle, self.allocator) catch |err| {
                if (err != error.WorkerBusy) {
                    self.result.failure = err;
                    self.result.outcome_unknown = self.stage == .write and !self.result.committed;
                    self.reportable = true;
                }
                return;
            };
            defer snapshot.deinit();
            const value = snapshot.value;
            const original_call = value.key != null and value.key.?.eql(active.key) and value.service_binding != null and value.service_binding.?.eql(self.binding);
            if (!original_call) {
                self.stale = true;
                self.stop();
                self.result.failure = error.StaleBinding;
                self.reportable = true;
                self.result.outcome_unknown = self.stage == .write and !self.result.committed;
                // Never cancel or retire an operation with another identity.
                return;
            }
            if (self.cancel.isCancelled()) active.facade.cancel(active.handle);
            self.observeWrite(value);
            if (value.cleanup == .unknown) {
                self.result.failure = error.SshCleanupUnknown;
                self.reportable = true;
                return;
            }
            if (value.cleanup != .released or value.status == .queued or value.status == .opening or value.status == .running) return;
            const released = active.facade.closeCall(active.handle) catch return;
            if (released != .released) return;
            _ = app.sessions.journal.completeReleased(active.key, "terminal file operation released") catch {};
            self.active = null;
            if (self.stale or self.cancel.isCancelled() or value.truncated or value.status != .completed or value.exit_code != 0) {
                const failure = if (self.stale) error.StaleBinding else if (value.truncated) error.FileTooLarge else remoteError(value) orelse if (self.cancel.isCancelled()) error.Cancelled else error.RemoteFileOperationFailed;
                self.result.failure = failure;
                // Leave room for the escaped endpoint, path and stderr in the log record.
                const host = self.ssh_host orelse "";
                const path = self.request.path;
                const stderr = value.stderr[0..@min(value.stderr.len, 320)];
                applog.warn(
                    .ssh,
                    "remote file operation failed: session={d} exec_operation={d} kind={s} stage={s} failure={s} status={s} exit={?d} stderr_bytes={d} capture_truncated={} stderr_preview_truncated={} host=\"{f}\" path=\"{f}\"{s} stderr=\"{f}\"",
                    .{ @backingInt(self.owner.session_id), active.key.operation_id, @tagName(self.request.kind), @tagName(self.stage), @errorName(failure), @tagName(value.status), value.exit_code, value.stderr_bytes, value.truncated, stderr.len < value.stderr.len, std.zig.fmtString(host[0..@min(host.len, 64)]), std.zig.fmtString(path[0..@min(path.len, 64)]), if (path.len > 64) "..." else "", std.zig.fmtString(stderr) },
                );
                self.done = true;
                return;
            }
            self.accept(value.stdout) catch |err| {
                self.result.failure = err;
                self.result.outcome_unknown = self.stage == .write and !self.result.committed;
                self.done = true;
            };
            return;
        }
        if (self.cancel.isCancelled()) {
            self.result.failure = error.Cancelled;
            self.done = true;
            return;
        }
        self.launch(app) catch |err| {
            if (err == error.WorkerBusy) return;
            self.result.failure = err;
            self.done = true;
        };
    }
    /// A local cancel, channel cleanup or even a nonzero remote exit does not
    /// undo a rename. Preserve positive commit evidence before testing status.
    fn observeWrite(self: *Job, value: exec.ExecResult) void {
        if (self.stage != .write) return;
        if (std.mem.startsWith(u8, value.stdout, "ZWCOMMIT1\n")) {
            self.result.committed = true;
            self.result.bytes = self.after;
        }
        const failure = scriptFailure(value);
        const rejected = value.stdout.len == 0 and failure != null and failure.?.before_commit;
        const not_sent = value.diagnostics.request_started == false or (value.status == .channel_rejected and value.effect == .none and !value.diagnostics.request_accepted);
        self.result.outcome_unknown = !self.result.committed and !not_sent and !rejected;
    }
    fn launch(self: *Job, app: *App) !void {
        const a = self.arena.allocator();
        if (self.command == null) self.command = try files.readCommand(a, self.request.path, if (self.request.kind == .read_image) images.max_bytes else files.text_limit, self.request.kind == .write_text and self.request.mode == .create);
        const facade = try app.sshExecService(self.owner);
        const key = try app.sessions.journal.begin(.{ .session = self.owner }, null);
        errdefer _ = app.sessions.journal.failReleased(key, .{ .domain = .host, .code = "FileExecStartFailed", .cleanup = .released, .safe_message = "文件操作未开始" }) catch {};
        const handle = try facade.exec(self.command.?, .{ .key = key, .call_id = key.operation_id, .service_binding = self.binding, .stdin = self.input, .capture_cap = if (self.request.kind == .read_image) images.max_bytes + 4096 else files.text_limit + 4096 });
        self.active = .{ .facade = facade, .handle = handle, .key = key };
    }
    fn accept(self: *Job, bytes: []const u8) !void {
        const a = self.arena.allocator();
        if (self.stage == .write) {
            if (!std.mem.eql(u8, bytes, "ZWCOMMIT1\n")) return error.InvalidFileResponse;
            self.result.committed = true;
            self.result.bytes = self.after;
            self.stage = .verify;
            self.input = null;
            self.command = try files.readCommand(a, self.request.path, files.text_limit, false);
            return;
        }
        const value = try files.parseRemoteRead(bytes, if (self.request.kind == .read_image) images.max_bytes else files.text_limit);
        self.request.version_stamp = try a.dupe(u8, value.stamp);
        if (self.stage == .verify) {
            if (!std.mem.eql(u8, value.bytes, self.after)) return error.VerificationFailed;
            self.result.verified = true;
            self.result.version = files.requestVersion(self.request, self.owner, self.request.path, self.after);
            self.done = true;
            return;
        }
        if (self.request.kind == .read_text or self.request.kind == .read_image) {
            if (value.absent) return error.FileNotFound;
            if (self.request.kind == .read_text) try files.validateText(value.bytes);
            self.result.bytes = try a.dupe(u8, value.bytes);
            self.result.version = files.requestVersion(self.request, self.owner, self.request.path, value.bytes);
            if (self.request.kind == .read_image) self.thread = try std.Thread.spawn(.{}, run, .{self}) else self.done = true;
            return;
        }
        const create = self.request.kind == .write_text and self.request.mode == .create;
        if (create != value.absent) return if (create) error.PathAlreadyExists else error.FileNotFound;
        self.before = try a.dupe(u8, value.bytes);
        self.stamp = try a.dupe(u8, value.stamp);
        self.after = try files.candidate(a, self.request, self.owner, self.request.path, self.before);
        self.command = try files.writeCommand(a, self.request.path, create, self.before, self.after, self.stamp);
        self.input = try std.mem.concat(a, u8, &.{ self.before, self.after });
        self.stage = .write;
    }
    pub fn deinit(self: *Job) void {
        std.debug.assert(self.done and self.active == null and self.thread == null);
        self.image.release();
        if (self.mutation_locked) mutation_mutex.unlock();
        self.arena.deinit();
        const a = self.allocator;
        a.destroy(self);
    }
};
const ScriptFailure = struct { code: anyerror, before_commit: bool = true };

fn scriptFailure(value: exec.ExecResult) ?ScriptFailure {
    if (value.status != .completed or value.exit_code != 1 or value.truncated) return null;
    const stderr = std.mem.trimEnd(u8, value.stderr, "\r\n");
    const line = if (std.mem.lastIndexOfScalar(u8, stderr, '\n')) |index| stderr[index + 1 ..] else stderr;
    const prefix = "ZWFILEERROR1 ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const code = line[prefix.len..];
    inline for (.{ "InvalidParent", "SourceChanged", "FileNotFound", "FileTooLarge", "SymlinkUnsupported", "NotRegularFile", "PathAlreadyExists", "MetadataPreservationFailed", "ExclusiveCommitUnsupported", "UnsupportedFileMetadata", "IncompleteInput", "InvalidInput", "TemporaryFileFailed", "FileNotWritable", "FileReadFailed" }) |name| {
        if (std.mem.eql(u8, code, name)) return .{ .code = @field(anyerror, name) };
    }
    // An error from the commit utility itself does not prove the destination stayed unchanged.
    inline for (.{ "CommitFailed", "ExclusiveCommitFailed" }) |name| {
        if (std.mem.eql(u8, code, name)) return .{ .code = @field(anyerror, name), .before_commit = false };
    }
    return null;
}

fn remoteError(value: exec.ExecResult) ?anyerror {
    if (scriptFailure(value)) |failure| return failure.code;
    return switch (value.status) {
        .channel_rejected => error.SshChannelRejected,
        .timed_out => error.Timeout,
        else => null,
    };
}

test "terminal files SSH commit evidence survives cancellation exit failure and unknown cleanup" {
    const a = std.testing.allocator;
    var job: Job = .{ .allocator = a, .arena = .init(a), .owner = .{ .session_id = @fromBackingInt(1) }, .binding = undefined, .request = .{ .kind = .write_text, .path = "/tmp/file" }, .local = false, .started_ns = 0, .stage = .write, .after = "new contents" };
    defer job.arena.deinit();
    var value: exec.ExecResult = .{ .stdout = "", .stderr = "", .elapsed_ms = 0, .status = .completed, .exit_code = 1, .cleanup = .released, .diagnostics = .{ .request_started = true } };
    // A known exit code is not proof that a rename did not happen.
    job.observeWrite(value);
    try std.testing.expect(job.result.outcome_unknown and !job.result.committed);
    value.stderr = "ZWFILEERROR1 SourceChanged\n";
    job.observeWrite(value);
    try std.testing.expect(!job.result.outcome_unknown and !job.result.committed);
    value.stderr = "ZWFILEERROR1 CommitFailed\n";
    job.observeWrite(value);
    try std.testing.expect(job.result.outcome_unknown);
    value.diagnostics.request_started = false;
    job.observeWrite(value);
    try std.testing.expect(!job.result.outcome_unknown);
    value.diagnostics.request_started = true;
    value.status = .cancelled;
    value.stdout = "ZWCOMMIT1\n";
    value.cleanup = .unknown;
    job.observeWrite(value);
    try std.testing.expect(job.result.committed and !job.result.verified and !job.result.outcome_unknown);
    try std.testing.expectEqualStrings("new contents", job.result.bytes);
    // A later teardown snapshot must not erase evidence already observed.
    value.stdout = "";
    value.exit_code = null;
    job.observeWrite(value);
    try std.testing.expect(job.result.committed and !job.result.outcome_unknown);
}

test "terminal files SSH recognizes precommit errors with utility stderr and keeps uncertain writes gated" {
    const a = std.testing.allocator;
    var job: Job = .{ .allocator = a, .arena = .init(a), .owner = .{ .session_id = @fromBackingInt(1) }, .binding = undefined, .request = .{ .kind = .write_text, .path = "/data/imgxfer/verify_inner.sh" }, .local = false, .started_ns = 0, .stage = .write };
    defer job.arena.deinit();
    var value: exec.ExecResult = .{
        .stdout = "",
        .stderr = "zw-file: line 18: cd: /data/imgxfer: No such file or directory\nZWFILEERROR1 InvalidParent\n",
        .elapsed_ms = 0,
        .exit_code = 1,
        .cleanup = .released,
        .diagnostics = .{ .request_started = true, .request_accepted = true },
    };
    job.observeWrite(value);
    try std.testing.expectEqual(error.InvalidParent, remoteError(value).?);
    try std.testing.expect(!job.result.outcome_unknown and !job.result.committed);
    value.truncated = true;
    job.observeWrite(value);
    try std.testing.expect(job.result.outcome_unknown);
    value.truncated = false;
    value.status = .timed_out;
    job.observeWrite(value);
    try std.testing.expect(job.result.outcome_unknown);

    value.status = .completed;
    value.stderr = "mkdir: No space left on device\nZWFILEERROR1 TemporaryFileFailed\n";
    job.observeWrite(value);
    try std.testing.expectEqual(error.TemporaryFileFailed, remoteError(value).?);
    try std.testing.expect(!job.result.outcome_unknown);
    value.stderr = "link: Input/output error\nZWFILEERROR1 ExclusiveCommitFailed\n";
    job.observeWrite(value);
    try std.testing.expectEqual(error.ExclusiveCommitFailed, remoteError(value).?);
    try std.testing.expect(job.result.outcome_unknown);
    value.stderr = "InvalidParent\n";
    job.observeWrite(value);
    try std.testing.expect(job.result.outcome_unknown);

    value.stderr = "";
    value.status = .channel_rejected;
    value.effect = .none;
    value.diagnostics.request_accepted = false;
    job.observeWrite(value);
    try std.testing.expectEqual(error.SshChannelRejected, remoteError(value).?);
    try std.testing.expect(!job.result.outcome_unknown);
}
