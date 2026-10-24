//! Value-only facade. Only SharedTransfer's original SSH IO owner calls step.
const std = @import("std");
const ssh = @import("session.zig");
pub const readonly = @import("sftp_readonly.zig");
const clock = @import("../../platform/realtime.zig");
pub const Provider = struct {
    context: *anyopaque,
    attach: *const fn (*anyopaque, readonly.EndpointRef, readonly.OperationKey) anyerror!*Mailbox,
};
const Work = struct {
    result: readonly.OwnedResult,
    action: readonly.Action,
    path: [:0]u8,
    resolved: ?[:0]u8 = null,
    handle: ?ssh.SftpReadonlyHandle = null,
    before: ssh.SftpAttributes = .{},
    opened: ssh.SftpAttributes = .{},
    bytes: []u8 = &.{},
    used: usize = 0,
    entries: std.ArrayList(readonly.Entry) = .empty,
    page_index: u32 = 0,
    count: usize = 0,
    phase: enum { init, resolve, stat, open, fstat, read, after, path_after, directory, close, done } = .init,
    cancel: bool = false,
    retry: bool = false,
    deadline: i128,
    buffer: [readonly.path_limit + 1]u8 = undefined,
};
pub const Mailbox = struct {
    allocator: std.mem.Allocator,
    endpoint: readonly.EndpointRef,
    key: readonly.OperationKey,
    mutex: std.atomic.Value(bool) = .init(false),
    work: ?*Work = null,
    startup: ?readonly.OwnedResult = null,
    initialized: bool = false,
    results: std.ArrayList(readonly.OwnedResult) = .empty,
    closing: bool = false,
    parent_released: bool = false,
    cleanup_unknown: bool = false,
    consumer_released: bool = false,
    pub fn init(a: std.mem.Allocator, endpoint: readonly.EndpointRef, key: readonly.OperationKey) !*Mailbox {
        try readonly.validateEndpoint(endpoint);
        try readonly.validateKey(endpoint, key, false);
        const self = try a.create(Mailbox);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .endpoint = endpoint, .key = key };
        try self.results.ensureTotalCapacity(a, 34);
        errdefer self.results.deinit(a);
        var ready = try readonly.OwnedResult.init(key, endpoint, 0, 0, "");
        ready.value.body = .ready;
        self.startup = ready;
        return self;
    }
    fn lock(self: *Mailbox) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mailbox) void {
        self.mutex.store(false, .release);
    }
    pub fn submit(self: *Mailbox, key: readonly.OperationKey, request: readonly.Request) !void {
        self.lock();
        defer self.unlock();
        if (self.closing or self.consumer_released) return error.Closing;
        if (!self.endpoint.eql(request.endpoint)) return error.StaleBinding;
        try readonly.validateKey(self.endpoint, key, request.action == .read_text);
        try readonly.validateRequest(request);
        if (request.action == .mkdir) return error.UnsupportedOperation;
        if (request.request_id != key.operation_id or key.eql(self.key)) return error.InvalidOperation;
        if (self.work != null or self.results.items.len > 1) return error.QueueFull;
        const work = try self.allocator.create(Work);
        errdefer self.allocator.destroy(work);
        var result = try readonly.OwnedResult.init(key, self.endpoint, request.request_id, request.directory_revision, request.path);
        errdefer result.deinit();
        const path = try result.arena.allocator().dupeSentinel(u8, request.path, 0);
        work.* = .{ .result = result, .action = request.action, .path = path, .deadline = clock.monotonicNs() + 30 * std.time.ns_per_s };
        self.work = work;
    }
    pub fn cancel(self: *Mailbox, key: readonly.OperationKey) bool {
        self.lock();
        defer self.unlock();
        if (self.work) |work| if (work.result.value.key.eql(key)) {
            work.cancel = true;
            return true;
        };
        return false;
    }
    pub fn poll(self: *Mailbox) ?readonly.OwnedResult {
        self.lock();
        defer self.unlock();
        if (self.results.items.len == 0) return null;
        return self.results.orderedRemove(0);
    }
    pub fn requestClose(self: *Mailbox) void {
        self.lock();
        defer self.unlock();
        self.closing = true;
        if (self.work) |work| work.cancel = true;
    }
    pub fn closeReceipt(self: *Mailbox) readonly.ReleaseReceipt {
        self.lock();
        defer self.unlock();
        return if (self.parent_released) .released else if (self.cleanup_unknown) .unknown else if (self.closing and self.work == null) .released else .awaiting;
    }
    pub fn deinit(self: *Mailbox) !void {
        self.lock();
        defer self.unlock();
        if (!self.closing or self.work != null or self.cleanup_unknown and !self.parent_released) return error.Busy;
        for (self.results.items) |*result| result.deinit();
        self.results.clearRetainingCapacity();
        if (self.startup) |*startup| startup.deinit();
        self.startup = null;
        self.consumer_released = true;
    }
    pub fn destroy(self: *Mailbox) void {
        std.debug.assert(self.work == null and self.consumer_released);
        self.results.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn hasPending(self: *Mailbox) bool {
        self.lock();
        defer self.unlock();
        return self.work != null or !self.initialized and !self.closing;
    }
    pub fn canReleaseParent(self: *Mailbox) bool {
        self.lock();
        defer self.unlock();
        return self.work == null and self.consumer_released;
    }
    pub fn sessionReleased(self: *Mailbox) void {
        self.lock();
        defer self.unlock();
        self.parent_released = true;
        self.closing = true;
        if (self.startup) |*startup| {
            startup.value.body = .{ .failure = .connection };
            self.results.appendAssumeCapacity(startup.*);
            self.startup = null;
        }
        if (self.work) |w| {
            w.handle = null;
            w.result.value.body = .{ .failure = .connection };
            w.phase = .done;
            self.finish(w);
        }
    }
    fn finish(self: *Mailbox, w: *Work) void {
        w.result.value.final = true;
        w.result.value.cleanup = if (self.cleanup_unknown and !self.parent_released) .unknown else .released;
        self.results.appendAssumeCapacity(w.result);
        self.allocator.destroy(w);
        self.work = null;
    }
    /// Returns true only while the exact native operation needs EAGAIN retry.
    pub fn step(self: *Mailbox, session: *ssh.Session) bool {
        self.lock();
        defer self.unlock();
        if (!self.initialized and !self.closing) {
            session.sftpReadonlyInit() catch |err| {
                if (err == error.WouldBlock or err == error.ChannelOpenBusy) return true;
                self.startup.?.value.body = .{ .failure = readonly.classify(err) };
                self.closing = true;
            };
            self.initialized = true;
            self.results.appendAssumeCapacity(self.startup.?);
            self.startup = null;
            return false;
        }
        const w = self.work orelse return false;
        if (!w.retry and w.phase != .close and w.phase != .done and (w.cancel or clock.monotonicNs() >= w.deadline)) {
            w.result.value.body = if (w.cancel) .cancelled else .{ .failure = .timeout };
            w.phase = .close;
        }
        if (w.phase == .directory and self.results.items.len >= 32) return false;
        self.advance(w, session) catch |err| {
            if (err == error.WouldBlock or err == error.ChannelOpenBusy) {
                w.retry = true;
                return true;
            }
            w.retry = false;
            w.result.value.body = .{ .failure = readonly.classify(err) };
            w.phase = if (w.handle != null) .close else .done;
        };
        w.retry = false;
        if (w.phase == .done) self.finish(w);
        return false;
    }
    fn advance(self: *Mailbox, w: *Work, session: *ssh.Session) !void {
        const a = w.result.arena.allocator();
        switch (w.phase) {
            .init => {
                try session.sftpReadonlyInit();
                w.phase = if (w.action == .stat) .stat else .resolve;
            },
            .resolve => {
                const path = try session.sftpRealpath(w.path, &w.buffer);
                w.resolved = try a.dupeSentinel(u8, path, 0);
                w.result.value.resolved_path = w.resolved.?;
                if (w.action == .realpath) {
                    w.result.value.body = .{ .realpath = w.resolved.? };
                    w.phase = .done;
                } else w.phase = if (w.action == .read_text) .stat else .open;
            },
            .stat => {
                const attrs = try session.sftpStat(w.resolved orelse w.path, false);
                if (w.action == .stat) {
                    w.result.value.body = .{ .stat = attrs };
                    w.phase = .done;
                } else {
                    if (attrs.kind != .file) return error.NotRegularFile;
                    w.before = attrs;
                    w.phase = .open;
                }
            },
            .open => {
                w.handle = try session.sftpOpenReadonly(w.resolved.?, w.action == .list);
                w.phase = if (w.action == .list) .directory else .fstat;
            },
            .fstat => {
                w.opened = try w.handle.?.stat();
                if (readonly.changed(w.before, w.opened)) return error.SourceChanged;
                w.bytes = try a.alloc(u8, w.action.read_text.max_bytes + 1);
                w.phase = .read;
            },
            .read => {
                const n = try w.handle.?.read(w.bytes[w.used..][0..@min(w.bytes.len - w.used, 4096)]);
                w.used += n;
                if (n == 0 or w.used == w.bytes.len) w.phase = .after;
            },
            .after => {
                if (readonly.changed(w.opened, try w.handle.?.stat())) return error.SourceChanged;
                w.phase = .path_after;
            },
            .path_after => {
                if (readonly.changed(w.before, try session.sftpStat(w.resolved.?, false))) return error.SourceChanged;
                const limit = w.action.read_text.max_bytes;
                w.result.value.body = .{ .text = .{ .text = try readonly.validateText(w.bytes[0..w.used], limit, w.used > limit), .original_size = w.before.size, .read_bytes = w.used, .captured_at_ms = clock.milliseconds(undefined), .truncated = w.used > limit } };
                w.phase = .close;
            },
            .directory => {
                const next = try w.handle.?.readDirectory(&w.buffer);
                if (next) |entry| {
                    if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) return;
                    if (entry.name.len == 0 or std.mem.indexOfScalar(u8, entry.name, 0) != null or std.mem.indexOfScalar(u8, entry.name, '/') != null) return error.Protocol;
                    if (w.count == w.action.list.max_entries) return error.EntryLimit;
                    w.count += 1;
                    const name = try a.dupe(u8, entry.name);
                    try w.entries.append(a, .{ .raw_name = name, .display_name = if (std.unicode.utf8ValidateSlice(name)) name else "[invalid UTF-8 name]", .absolute_path = try readonly.joinPath(a, w.resolved.?, name), .attributes = entry.attributes });
                    // bounded pages are published without moving the work arena
                    if (w.entries.items.len == w.action.list.page_entries) try self.page(w);
                } else {
                    w.result.value.body = .{ .page = .{ .index = w.page_index, .entries = w.entries.items } };
                    w.phase = .close;
                }
            },
            .close => {
                if (w.handle) |*handle| {
                    const result = handle.closeReceipt();
                    if (result.receipt == .awaiting) return error.WouldBlock;
                    if (!result.consumed) return error.CloseFailed;
                    w.handle = null;
                    if (result.receipt != .released) {
                        self.cleanup_unknown = true;
                        w.result.value.body = .{ .failure = .close_failed };
                    }
                }
                w.phase = .done;
            },
            .done => {},
        }
    }
    fn page(self: *Mailbox, w: *Work) !void {
        if (self.results.items.len >= 32) return error.EntryLimit;
        var page_result = try readonly.OwnedResult.init(w.result.value.key, self.endpoint, w.result.value.request_id, w.result.value.directory_revision, w.path);
        errdefer page_result.deinit();
        const a = page_result.arena.allocator();
        const entries = try a.alloc(readonly.Entry, w.entries.items.len);
        for (entries, w.entries.items) |*out, in| out.* = .{ .raw_name = try a.dupe(u8, in.raw_name), .display_name = try a.dupe(u8, in.display_name), .absolute_path = try a.dupe(u8, in.absolute_path), .attributes = in.attributes };
        page_result.value.resolved_path = try a.dupe(u8, w.resolved.?);
        page_result.value.body = .{ .page = .{ .index = w.page_index, .entries = entries } };
        page_result.value.final = false;
        page_result.value.cleanup = .awaiting;
        self.results.appendAssumeCapacity(page_result);
        w.page_index += 1;
        w.entries.clearRetainingCapacity();
    }
};

fn exerciseAllocation(a: std.mem.Allocator) !void {
    const identity = @import("../../host/identity.zig");
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(500), .generation = 2 };
    const endpoint: readonly.EndpointRef = .{ .binding_id = 1, .binding_generation = 2, .resource_owner = .{ .session = owner }, .origin_session = owner };
    const mailbox = try Mailbox.init(a, endpoint, .{ .owner = .{ .session = owner }, .operation_id = 10 });
    defer {
        mailbox.sessionReleased();
        mailbox.deinit() catch unreachable;
        mailbox.destroy();
    }
    const key: readonly.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 11 };
    try mailbox.submit(key, .{ .endpoint = endpoint, .request_id = 11, .path = "/text", .action = .{ .read_text = .{} } });
    mailbox.requestClose();
    try std.testing.expectEqual(readonly.ReleaseReceipt.awaiting, mailbox.closeReceipt());
    // Parent release settles a pinned RPC only after its real owner confirms.
    mailbox.sessionReleased();
    try std.testing.expectEqual(readonly.ReleaseReceipt.released, mailbox.closeReceipt());
    var startup = mailbox.poll().?;
    defer startup.deinit();
    try std.testing.expect(startup.value.request_id == 0 and startup.value.body == .failure);
    var final = mailbox.poll().?;
    defer final.deinit();
    try std.testing.expect(final.value.key.eql(key) and final.value.cleanup == .released and final.value.body == .failure);
}
test "shared readonly mailbox allocation failure retains no accepted request or parent reference" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocation, .{});
}
