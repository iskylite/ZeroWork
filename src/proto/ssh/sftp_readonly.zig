//! Owned SFTP directory and bounded file-read service; mkdir is its only
//! directory mutation. The Connector creates a dedicated Session on
//! this one worker; it must never return a terminal/transfer Session borrowed
//! from another IO owner. All native calls, retries and teardown stay here.
const std = @import("std");
const ssh = @import("session.zig");
const identity = @import("../../host/identity.zig");
const operation = @import("../../host/operation.zig");
const clock = @import("../../platform/realtime.zig");
const c = @import("generated_ssh_session");

pub const OperationKey = operation.OperationKey;
pub const ReleaseReceipt = ssh.ReleaseReceipt;
pub const Attributes = ssh.SftpAttributes;
pub const path_limit = 4096;
pub const read_limit = 65536;
pub const page_limit = 128;
pub const entry_limit = 4096;
const request_limit = 8;
const budget_ns = 30 * std.time.ns_per_s;

pub const EndpointRef = struct {
    kind: enum { sftp } = .sftp,
    binding_id: u64,
    binding_generation: u64,
    resource_owner: identity.ResourceOwner,
    origin_session: ?identity.SessionHandle = null,
    connection_snapshot_id: ?u64 = null,

    pub fn eql(self: EndpointRef, other: EndpointRef) bool {
        return std.meta.eql(self, other);
    }
};
pub const Connector = struct {
    key: OperationKey,
    ctx: *anyopaque,
    connect_fn: *const fn (*anyopaque, *const std.atomic.Value(bool)) anyerror!ssh.Session,
    // Includes any route/ledger remainder after connect_fn fails. Only called
    // on this worker. A Session pointer is present only after successful move.
    close_fn: *const fn (*anyopaque, ?*ssh.Session) ReleaseReceipt,
    deinit_fn: *const fn (*anyopaque) void,
};
pub const Action = union(enum) {
    realpath,
    stat,
    list: struct { page_entries: u16 = page_limit, max_entries: u32 = entry_limit },
    read_text: struct { max_bytes: u32 = 4096 },
    mkdir: struct { name: []const u8 },
};
pub const Request = struct {
    endpoint: EndpointRef,
    request_id: u64,
    directory_revision: u64 = 0,
    path: []const u8,
    action: Action,
};
pub const Entry = struct {
    raw_name: []const u8,
    display_name: []const u8,
    absolute_path: []const u8,
    attributes: Attributes,
};
pub const Text = struct {
    text: []const u8,
    original_size: ?u64,
    read_bytes: usize,
    captured_at_ms: i64,
    truncated: bool,
};
pub const Failure = enum {
    connection,
    subsystem_denied,
    permission_denied,
    not_found,
    already_exists,
    unsupported,
    path_limit,
    entry_limit,
    not_regular_file,
    unsupported_binary,
    unsupported_encoding,
    source_changed,
    timeout,
    close_failed,
    out_of_memory,
    protocol,
};
pub const Body = union(enum) {
    ready,
    realpath: []const u8,
    stat: Attributes,
    page: struct { index: u32, entries: []const Entry },
    text: Text,
    /// A completed mutation stays factual even if its owner later expires.
    created: []const u8,
    cancelled,
    failure: Failure,
    closed,
};
pub const Result = struct {
    key: OperationKey,
    endpoint: EndpointRef,
    request_id: u64,
    directory_revision: u64,
    requested_path: []const u8,
    resolved_path: ?[]const u8 = null,
    body: Body,
    final: bool = true,
    cleanup: ReleaseReceipt = .released,
};
pub const OwnedResult = struct {
    arena: std.heap.ArenaAllocator,
    value: Result,

    pub fn deinit(self: *OwnedResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn init(key: OperationKey, endpoint: EndpointRef, request_id: u64, revision: u64, path: []const u8) !OwnedResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const owned_path = try arena.allocator().dupe(u8, path);
        return .{ .arena = arena, .value = .{
            .key = key,
            .endpoint = endpoint,
            .request_id = request_id,
            .directory_revision = revision,
            .requested_path = owned_path,
            .body = .cancelled,
        } };
    }
};
const Work = struct {
    key: OperationKey,
    request: Request,
    path: [:0]u8,
    name: ?[]u8 = null,
    deadline: i128,
    result: OwnedResult,
    cancelled: std.atomic.Value(bool) = .init(false),
    active: bool = false,
    finished: bool = false,
};
const Mutex = struct {
    locked: std.atomic.Value(bool) = .init(false),
    fn lock(self: *Mutex) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.locked.store(false, .release);
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    endpoint: EndpointRef,
    connector: Connector,
    mutex: Mutex = .{},
    works: std.ArrayList(*Work) = .empty,
    results: std.ArrayList(OwnedResult) = .empty,
    closing: std.atomic.Value(bool) = .init(false),
    worker_done: std.atomic.Value(bool) = .init(false),
    close_state: std.atomic.Value(u8) = .init(@backingInt(ReleaseReceipt.awaiting)),
    thread: ?std.Thread = null,
    // Only the worker reads/writes this value or anything reachable from it.
    session: ?ssh.Session = null,

    /// On success takes Connector.ctx ownership. On failure the caller retains
    /// it. The supplied allocator is used only on the calling/control thread;
    /// worker results own c_allocator arenas, and queues are preallocated.
    pub fn start(allocator: std.mem.Allocator, endpoint: EndpointRef, connector: Connector) !*Service {
        try validateEndpoint(endpoint);
        try validateKey(endpoint, connector.key, false);
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .endpoint = endpoint, .connector = connector };
        try self.works.ensureTotalCapacity(allocator, request_limit);
        errdefer self.works.deinit(allocator);
        try self.results.ensureTotalCapacity(allocator, 32);
        errdefer self.results.deinit(allocator);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Accepted paths are owned before return. Bad identity/limits reject
    /// synchronously without native IO or consuming another operation's key.
    pub fn submit(self: *Service, key: OperationKey, request: Request) !void {
        if (!self.endpoint.eql(request.endpoint)) return error.StaleBinding;
        try validateKey(self.endpoint, key, request.action == .read_text);
        if (key.eql(self.connector.key)) return error.DuplicateOperation;
        try validateRequest(request);
        const work = try self.allocator.create(Work);
        errdefer self.allocator.destroy(work);
        const path = try self.allocator.dupeSentinel(u8, request.path, 0);
        errdefer self.allocator.free(path);
        const name = if (request.action == .mkdir) try self.allocator.dupe(u8, request.action.mkdir.name) else null;
        errdefer if (name) |value| self.allocator.free(value);
        // Reserve the final result before acceptance, so even allocator failure
        // on the worker can report a typed terminal without retry allocation.
        var result = try OwnedResult.init(key, self.endpoint, request.request_id, request.directory_revision, path);
        errdefer result.deinit();
        work.* = .{ .key = key, .request = request, .path = path, .name = name, .deadline = clock.monotonicNs() + budget_ns, .result = result };
        work.request.path = path;
        if (name) |value| work.request.action.mkdir.name = value;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing.load(.acquire)) return error.Closing;
        if (self.works.items.len >= request_limit) return error.QueueFull;
        for (self.works.items) |previous| if (previous.key.eql(key)) return error.DuplicateOperation;
        self.works.appendAssumeCapacity(work);
    }

    pub fn cancel(self: *Service, key: OperationKey) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.works.items) |work| if (work.key.eql(key) and !work.finished) {
            work.cancelled.store(true, .release);
            return true;
        };
        return false;
    }

    pub fn poll(self: *Service) ?OwnedResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.results.items.len == 0) return null;
        const result = self.results.orderedRemove(0);
        if (result.value.final and result.value.request_id != 0) {
            for (self.works.items, 0..) |work, index| if (work.key.eql(result.value.key) and work.finished) {
                _ = self.works.orderedRemove(index);
                self.allocator.free(work.path);
                if (work.name) |name| self.allocator.free(name);
                self.allocator.destroy(work);
                break;
            };
        }
        return result;
    }

    pub fn requestClose(self: *Service) void {
        self.closing.store(true, .release);
    }

    pub fn closeReceipt(self: *const Service) ReleaseReceipt {
        const receipt: ReleaseReceipt = @fromBackingInt(@intCast(self.close_state.load(.acquire)));
        if (receipt == .released and !self.worker_done.load(.acquire)) return .awaiting;
        return receipt;
    }

    pub fn deinit(self: *Service) error{Busy}!void {
        if (self.closeReceipt() != .released) return error.Busy;
        if (self.thread) |thread| thread.join();
        for (self.results.items) |*result| result.deinit();
        self.results.deinit(self.allocator);
        for (self.works.items) |work| {
            self.allocator.free(work.path);
            if (work.name) |name| self.allocator.free(name);
            self.allocator.destroy(work);
        }
        self.works.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn event(self: *Service, body: Body, cleanup: ReleaseReceipt) void {
        var result = OwnedResult.init(self.connector.key, self.endpoint, 0, 0, "") catch return;
        result.value.body = body;
        result.value.cleanup = cleanup;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.results.appendAssumeCapacity(result);
    }

    fn run(self: *Service) void {
        defer self.worker_done.store(true, .release);
        self.session = self.connector.connect_fn(self.connector.ctx, &self.closing) catch |err| {
            self.event(if (err == error.Cancelled) .cancelled else .{ .failure = classify(err) }, .awaiting);
            self.closing.store(true, .release);
            self.drainCancelled();
            self.finishClose();
            return;
        };
        const session = &self.session.?;
        if (session.state != .active or session.channel != null or session.handle == null or session.socket_fd < 0) {
            self.event(.{ .failure = .connection }, .awaiting);
            self.closing.store(true, .release);
        } else {
            c.zw_libssh2_session_nonblocking(session.handle.?);
            var context: Context = .{ .service = self, .deadline = clock.monotonicNs() + budget_ns };
            context.call(ssh.Session.sftpReadonlyInit, .{session}) catch |err| {
                self.event(if (err == error.Cancelled) .cancelled else .{ .failure = classify(err) }, .awaiting);
                self.closing.store(true, .release);
            };
            if (!self.closing.load(.acquire)) {
                if (@import("../../platform/runtime_mode.zig").automation) std.debug.print("SFTP_READONLY_READY {{\"binding_id\":{d},\"generation\":{d},\"channel_absent\":{}}}\n", .{ self.endpoint.binding_id, self.endpoint.binding_generation, session.channel == null });
                self.event(.ready, .released);
            }
        }
        while (!self.closing.load(.acquire)) {
            self.mutex.lock();
            var next: ?*Work = null;
            for (self.works.items) |work| if (!work.active and !work.finished) {
                work.active = true;
                next = work;
                break;
            };
            self.mutex.unlock();
            if (next) |work| {
                var context: Context = .{ .service = self, .work = work, .deadline = work.deadline };
                var result = work.result;
                context.process(&result) catch |err| {
                    result.value.body = if (err == error.Cancelled) .cancelled else .{ .failure = classify(err) };
                };
                result.value.cleanup = context.cleanup;
                self.publishFinal(work, result);
            } else pause(-1);
        }
        self.drainCancelled();
        self.finishClose();
    }

    fn publishFinal(self: *Service, work: *Work, result: OwnedResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        work.finished = true;
        self.results.appendAssumeCapacity(result);
    }

    fn publishPage(self: *Service, work: *Work, result: OwnedResult) !void {
        while (true) {
            self.mutex.lock();
            if (self.results.items.len < request_limit) {
                self.results.appendAssumeCapacity(result);
                self.mutex.unlock();
                return;
            }
            self.mutex.unlock();
            if (work.cancelled.load(.acquire) or self.closing.load(.acquire)) return error.Cancelled;
            if (clock.monotonicNs() >= work.deadline) return error.Timeout;
            pause(-1);
        }
    }

    fn drainCancelled(self: *Service) void {
        // No new submit can enter once closing=true. Only the worker changes
        // finished, so a pending Work cannot be removed by poll during this.
        while (true) {
            self.mutex.lock();
            var pending: ?*Work = null;
            for (self.works.items) |work| if (!work.finished) {
                pending = work;
                break;
            };
            self.mutex.unlock();
            const work = pending orelse break;
            self.publishFinal(work, work.result);
        }
    }

    fn finishClose(self: *Service) void {
        var reported_unknown = false;
        while (true) {
            const receipt = self.connector.close_fn(self.connector.ctx, if (self.session) |*session| session else null);
            if (receipt == .released) break;
            if (receipt == .unknown and !reported_unknown) {
                self.close_state.store(@backingInt(ReleaseReceipt.unknown), .release);
                self.event(.closed, .unknown);
                reported_unknown = true;
            }
            pause(-1);
        }
        self.session = null;
        self.connector.deinit_fn(self.connector.ctx);
        self.event(.closed, .released);
        self.close_state.store(@backingInt(ReleaseReceipt.released), .release);
    }
};

fn Payload(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload;
}
const Context = struct {
    service: *Service,
    work: ?*Work = null,
    deadline: i128,
    cleanup: ReleaseReceipt = .released,

    fn check(self: *Context) !void {
        if (self.service.closing.load(.acquire)) return error.Cancelled;
        if (self.work) |work| if (work.cancelled.load(.acquire)) return error.Cancelled;
        if (clock.monotonicNs() >= self.deadline) return error.Timeout;
    }
    fn call(self: *Context, comptime function: anytype, args: anytype) anyerror!Payload(function) {
        try self.check();
        while (true) {
            return @call(.auto, function, args) catch |err| {
                if (err != error.WouldBlock) {
                    if (err == error.SftpIoFailed or err == error.SessionNotActive) self.service.closing.store(true, .release);
                    return err;
                }
                // A cancelled operation must finish its current native step
                // with the same buffer/arguments before using this context
                // for another operation. Whole-binding close can abandon it.
                if (self.service.closing.load(.acquire)) {
                    self.cleanup = .awaiting;
                    return error.Cancelled;
                }
                if (clock.monotonicNs() >= self.deadline) {
                    self.cleanup = .awaiting;
                    self.service.closing.store(true, .release);
                    return error.Timeout;
                }
                pause(self.service.session.?.socket_fd);
                continue;
            };
        }
    }
    fn closeHandle(self: *Context, handle: *ssh.SftpReadonlyHandle) void {
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (true) {
            const result = handle.closeReceipt();
            if (result.consumed) {
                self.cleanup = result.receipt;
                if (result.receipt != .released) self.service.closing.store(true, .release);
                return;
            }
            if (clock.monotonicNs() >= deadline) {
                // Only this dedicated binding is terminally closing. Do not
                // recycle its fd or free an in-flight handle on the UI thread.
                const session = &self.service.session.?;
                c.zw_libssh2_session_abort_io(session.handle.?, session.socket_fd);
                self.service.closing.store(true, .release);
            }
            pause(self.service.session.?.socket_fd);
        }
    }
    fn canonical(self: *Context, allocator: std.mem.Allocator, path: [:0]const u8) ![:0]u8 {
        var buffer: [path_limit + 1]u8 = undefined;
        const resolved = try self.call(ssh.Session.sftpRealpath, .{ &self.service.session.?, path, &buffer });
        try validatePath(resolved, true);
        return allocator.dupeSentinel(u8, resolved, 0);
    }
    fn process(self: *Context, result: *OwnedResult) !void {
        const work = self.work.?;
        const allocator = result.arena.allocator();
        try self.check();
        if (work.request.action == .stat) {
            result.value.body = .{ .stat = try self.call(ssh.Session.sftpStat, .{ &self.service.session.?, work.path, false }) };
            try self.check();
            return;
        }
        const resolved = try self.canonical(allocator, work.path);
        result.value.resolved_path = resolved;
        switch (work.request.action) {
            .realpath => result.value.body = .{ .realpath = resolved },
            .stat => unreachable,
            .list => |options| try self.list(result, resolved, options.page_entries, options.max_entries),
            .read_text => |options| try self.readText(result, resolved, options.max_bytes),
            .mkdir => |options| {
                // Allocate before native acceptance: OOM/cancel after success
                // must never hide a directory which was actually created.
                const created = try allocator.dupeSentinel(u8, try joinPath(allocator, resolved, options.name), 0);
                // SFTP v3 servers sometimes report generic FAILURE for an
                // existing child. Preserve an explicit preflight conflict.
                if (self.call(ssh.Session.sftpStat, .{ &self.service.session.?, created, false })) |_| {
                    return error.PathAlreadyExists;
                } else |err| if (err != error.FileNotFound) return err;
                self.call(ssh.Session.sftpMkdir, .{ &self.service.session.?, created }) catch |err| {
                    // v3 generic FAILURE may mean a race with another creator.
                    // Re-stat only on this still-live original endpoint.
                    if (err == error.SftpProtocolFailed) {
                        if (self.call(ssh.Session.sftpStat, .{ &self.service.session.?, created, false })) |_| {
                            return error.PathAlreadyExists;
                        } else |_| {}
                    }
                    return err;
                };
                result.value.body = .{ .created = created };
                return;
            },
        }
        try self.check();
        if (self.cleanup != .released) return error.CloseFailed;
    }
    fn list(self: *Context, result: *OwnedResult, resolved: [:0]const u8, page_entries: usize, max_entries: usize) !void {
        var handle = try self.call(ssh.Session.sftpOpenReadonly, .{ &self.service.session.?, resolved, true });
        defer self.closeHandle(&handle);
        var count: usize = 0;
        var page_index: u32 = 0;
        var page = try OwnedResult.init(result.value.key, result.value.endpoint, result.value.request_id, result.value.directory_revision, result.value.requested_path);
        defer page.deinit();
        var entries: std.ArrayList(Entry) = .empty;
        var buffer: [path_limit + 1]u8 = undefined;
        while (true) {
            const next = try self.call(ssh.SftpReadonlyHandle.readDirectory, .{ &handle, &buffer });
            try self.check();
            const item = next orelse {
                // Last page is installed only after handle close succeeds.
                const target = result.arena.allocator();
                const owned = try target.alloc(Entry, entries.items.len);
                for (entries.items, owned) |entry, *copy| copy.* = try cloneEntry(target, entry);
                result.value.body = .{ .page = .{ .index = page_index, .entries = owned } };
                return;
            };
            if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
            if (item.name.len == 0 or std.mem.indexOfScalar(u8, item.name, 0) != null or std.mem.indexOfScalar(u8, item.name, '/') != null) return error.Protocol;
            if (count == max_entries) return error.EntryLimit;
            count += 1;
            const page_allocator = page.arena.allocator();
            const path = try joinPath(page_allocator, resolved, item.name);
            const raw_name = try page_allocator.dupe(u8, item.name);
            const display = if (std.unicode.utf8ValidateSlice(raw_name)) raw_name else try std.fmt.allocPrint(page_allocator, "{s}", .{"[invalid UTF-8 name]"});
            try entries.append(page_allocator, .{ .raw_name = raw_name, .display_name = display, .absolute_path = path, .attributes = item.attributes });
            if (entries.items.len == page_entries) {
                page.value.resolved_path = try page_allocator.dupe(u8, resolved);
                page.value.body = .{ .page = .{ .index = page_index, .entries = entries.items } };
                page.value.final = false;
                page.value.cleanup = .awaiting;
                const replacement = try OwnedResult.init(result.value.key, result.value.endpoint, result.value.request_id, result.value.directory_revision, result.value.requested_path);
                self.service.publishPage(self.work.?, page) catch |err| {
                    var unused = replacement;
                    unused.deinit();
                    return err;
                };
                page = replacement;
                entries = .empty;
                page_index += 1;
            }
        }
    }
    fn readText(self: *Context, result: *OwnedResult, resolved: [:0]const u8, max_bytes: usize) !void {
        const before = try self.call(ssh.Session.sftpStat, .{ &self.service.session.?, resolved, false });
        if (before.kind != .file) return error.NotRegularFile;
        var handle = try self.call(ssh.Session.sftpOpenReadonly, .{ &self.service.session.?, resolved, false });
        defer self.closeHandle(&handle);
        const opened = try self.call(ssh.SftpReadonlyHandle.stat, .{&handle});
        if (opened.kind != .file or changed(before, opened)) return error.SourceChanged;
        const bytes = try result.arena.allocator().alloc(u8, max_bytes + 1);
        var used: usize = 0;
        var eof = false;
        while (used < bytes.len) {
            const len = @min(bytes.len - used, 32 * 1024);
            const count = try self.call(ssh.SftpReadonlyHandle.read, .{ &handle, bytes[used..][0..len] });
            try self.check();
            if (count == 0) {
                eof = true;
                break;
            }
            used += count;
        }
        const after = try self.call(ssh.SftpReadonlyHandle.stat, .{&handle});
        const path_after = try self.call(ssh.Session.sftpStat, .{ &self.service.session.?, resolved, false });
        if (changed(opened, after) or changed(before, path_after)) return error.SourceChanged;
        const truncated = used > max_bytes;
        const shown = try validateText(bytes[0..used], max_bytes, truncated and !eof);
        result.value.body = .{ .text = .{
            .text = shown,
            .original_size = before.size,
            .read_bytes = used,
            .captured_at_ms = clock.milliseconds(undefined),
            .truncated = truncated,
        } };
    }
};

fn pause(fd: c_int) void {
    var descriptor = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    _ = std.c.poll(&descriptor, if (fd < 0) 0 else 1, 10);
}
pub fn validateEndpoint(endpoint: EndpointRef) !void {
    if (endpoint.binding_id == 0 or endpoint.binding_generation == 0) return error.InvalidBinding;
    switch (endpoint.resource_owner) {
        .session => |owner| if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return error.InvalidOwner,
        .retained_transfer => |owner| if (@backingInt(owner) == 0) return error.InvalidOwner,
    }
}
pub fn validateKey(endpoint: EndpointRef, key: OperationKey, text: bool) !void {
    if (key.operation_id == 0 or key.attempt_id == 0) return error.InvalidOperation;
    switch (endpoint.resource_owner) {
        .session => |owner| {
            if (key.owner != .session or !key.owner.session.eql(owner)) return error.OwnerMismatch;
        },
        .retained_transfer => |owner| {
            if (text) return error.ReadNotAuthorized;
            if (key.owner != .transfer_owner or key.owner.transfer_owner.id != owner) return error.OwnerMismatch;
        },
    }
}
fn validatePath(path: []const u8, absolute: bool) !void {
    if (path.len == 0 or path.len > path_limit) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (absolute and path[0] != '/') return error.AbsolutePathRequired;
}
pub fn validateRequest(request: Request) !void {
    if (request.request_id == 0) return error.InvalidRequest;
    try validatePath(request.path, request.action == .read_text or request.action == .stat or request.action == .mkdir);
    if (request.path[0] != '/' and !std.mem.eql(u8, request.path, ".")) return error.AbsolutePathRequired;
    switch (request.action) {
        .read_text => |options| if (options.max_bytes == 0 or options.max_bytes > read_limit) return error.InvalidReadLimit,
        .list => |options| if (options.page_entries == 0 or options.page_entries > page_limit or options.max_entries == 0 or options.max_entries > entry_limit) return error.InvalidEntryLimit,
        .mkdir => |options| {
            try @import("../../host/directory_name.zig").validate(options.name);
            if (request.path.len + options.name.len + 1 > path_limit) return error.PathLimit;
        },
        else => {},
    }
}
pub fn joinPath(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) ![]const u8 {
    const separator: []const u8 = if (std.mem.endsWith(u8, directory, "/")) "" else "/";
    if (directory.len + separator.len + name.len > path_limit) return error.PathLimit;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ directory, separator, name });
}
fn cloneEntry(allocator: std.mem.Allocator, entry: Entry) !Entry {
    return .{ .raw_name = try allocator.dupe(u8, entry.raw_name), .display_name = try allocator.dupe(u8, entry.display_name), .absolute_path = try allocator.dupe(u8, entry.absolute_path), .attributes = entry.attributes };
}
pub fn changed(before: Attributes, after: Attributes) bool {
    return before.kind != after.kind or !std.meta.eql(before.size, after.size) or !std.meta.eql(before.modified_at, after.modified_at);
}
pub fn validateText(bytes: []const u8, max_bytes: usize, truncated: bool) ![]const u8 {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.UnsupportedBinary;
    const used = @min(bytes.len, max_bytes);
    var index: usize = 0;
    while (index < used) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return error.UnsupportedEncoding;
        if (index + length > used) {
            if (truncated) {
                // Confirm the split is a valid prefix, including the probe
                // byte(s) already read, rather than hiding malformed input.
                const available = @min(bytes.len - index, length);
                if (bytes[index] < 0xc2 or bytes[index] > 0xf4) return error.UnsupportedEncoding;
                for (bytes[index + 1 .. index + available]) |byte| if (byte & 0xc0 != 0x80) return error.UnsupportedEncoding;
                if (available > 1 and ((bytes[index] == 0xe0 and bytes[index + 1] < 0xa0) or (bytes[index] == 0xed and bytes[index + 1] > 0x9f) or (bytes[index] == 0xf0 and bytes[index + 1] < 0x90) or (bytes[index] == 0xf4 and bytes[index + 1] > 0x8f))) return error.UnsupportedEncoding;
                return bytes[0..index];
            }
            return error.UnsupportedEncoding;
        }
        _ = std.unicode.utf8Decode(bytes[index..][0..length]) catch return error.UnsupportedEncoding;
        index += length;
    }
    return bytes[0..used];
}
pub fn classify(err: anyerror) Failure {
    return switch (err) {
        error.SftpSubsystemDenied => .subsystem_denied,
        error.PermissionDenied => .permission_denied,
        error.FileNotFound => .not_found,
        error.PathAlreadyExists => .already_exists,
        error.UnsupportedOperation => .unsupported,
        error.PathLimit, error.InvalidPath => .path_limit,
        error.EntryLimit => .entry_limit,
        error.NotRegularFile => .not_regular_file,
        error.UnsupportedBinary => .unsupported_binary,
        error.UnsupportedEncoding => .unsupported_encoding,
        error.SourceChanged => .source_changed,
        error.Timeout => .timeout,
        error.CloseFailed => .close_failed,
        error.OutOfMemory => .out_of_memory,
        error.Protocol, error.SftpProtocolFailed => .protocol,
        else => .connection,
    };
}

fn testWait(flag: *const std.atomic.Value(bool)) !void {
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!flag.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimedOut;
        pause(-1);
    }
}
test "sftp readonly UTF8 bounds reject binary and malformed EOF but trim only budget split" {
    try std.testing.expectEqualStrings("", try validateText("", 4096, false));
    try std.testing.expectEqualStrings("hello", try validateText("hello", 4096, false));
    try std.testing.expectEqualStrings("a", try validateText("a你", 2, true));
    try std.testing.expectEqualStrings("你", try validateText("你好", 3, true));
    try std.testing.expectError(error.UnsupportedBinary, validateText("a\x00b", 3, false));
    try std.testing.expectError(error.UnsupportedEncoding, validateText("\xff", 1, false));
    try std.testing.expectError(error.UnsupportedEncoding, validateText("a\xe4\xbd", 4096, false));
    try std.testing.expectError(error.UnsupportedEncoding, validateText("a\xe4x", 2, true));
    try std.testing.expectError(error.UnsupportedEncoding, validateText("\xed\xa0\x80", 3, false));
    try std.testing.expectError(error.UnsupportedEncoding, validateText("\xc0\x80", 1, true));
    try std.testing.expectError(error.UnsupportedEncoding, validateText("\xed\xa0", 1, true));
}
test "sftp readonly metadata keeps unknown size separate and detects source change" {
    try std.testing.expect(!changed(.{ .kind = .file }, .{ .kind = .file }));
    try std.testing.expect(changed(.{ .kind = .file }, .{ .kind = .file, .size = 0 }));
    try std.testing.expect(changed(.{ .kind = .file, .size = 5, .modified_at = 7 }, .{ .kind = .file, .size = 5, .modified_at = 8 }));
    try std.testing.expect(changed(.{ .kind = .symlink }, .{ .kind = .file }));
    const path = try joinPath(std.testing.allocator, "/", "a b,'x");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/a b,'x", path);
}
test "sftp readonly worker freezes requests and cancellation while real close receipt stays awaiting" {
    const Gate = struct {
        caller: std.Thread.Id,
        connect_entered: std.atomic.Value(bool) = .init(false),
        connect_release: std.atomic.Value(bool) = .init(false),
        close_entered: std.atomic.Value(bool) = .init(false),
        close_release: std.atomic.Value(bool) = .init(false),
        close_unknown: std.atomic.Value(bool) = .init(false),
        destroyed: std.atomic.Value(bool) = .init(false),
        fn connect(raw: *anyopaque, _: *const std.atomic.Value(bool)) !ssh.Session {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.Thread.getCurrentId() == self.caller) return error.ConnectionOnControlThread;
            self.connect_entered.store(true, .release);
            try testWait(&self.connect_release);
            return error.TestConnectFailure;
        }
        fn close(raw: *anyopaque, session: ?*ssh.Session) ReleaseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(session == null);
            std.debug.assert(std.Thread.getCurrentId() != self.caller);
            self.close_entered.store(true, .release);
            return if (self.close_release.load(.acquire)) .released else if (self.close_unknown.load(.acquire)) .unknown else .awaiting;
        }
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.close_release.load(.acquire));
            self.destroyed.store(true, .release);
        }
    };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 3 };
    const endpoint: EndpointRef = .{ .binding_id = 72, .binding_generation = 4, .resource_owner = .{ .session = owner }, .origin_session = owner };
    const connect_key: OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 1 };
    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    const service = try Service.start(std.testing.allocator, endpoint, .{ .key = connect_key, .ctx = &gate, .connect_fn = Gate.connect, .close_fn = Gate.close, .deinit_fn = Gate.destroy });
    defer {
        gate.connect_release.store(true, .release);
        gate.close_release.store(true, .release);
        service.requestClose();
        testWait(&service.worker_done) catch unreachable;
        service.deinit() catch unreachable;
    }
    try testWait(&gate.connect_entered);
    const key: OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 2 };
    const second: OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 3 };
    const path = try std.testing.allocator.dupe(u8, "/original/a b");
    const accepted = service.submit(key, .{ .endpoint = endpoint, .request_id = 9, .directory_revision = 7, .path = path, .action = .{ .read_text = .{} } });
    std.testing.allocator.free(path);
    try accepted;
    try service.submit(second, .{ .endpoint = endpoint, .request_id = 10, .path = "/", .action = .{ .list = .{} } });
    const mkdir_key: OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 4 };
    const child_name = try std.testing.allocator.dupe(u8, "original-child");
    const mkdir_accepted = service.submit(mkdir_key, .{ .endpoint = endpoint, .request_id = 11, .directory_revision = 7, .path = "/original", .action = .{ .mkdir = .{ .name = child_name } } });
    std.testing.allocator.free(child_name);
    try mkdir_accepted;
    try std.testing.expectEqualStrings("original-child", service.works.items[2].request.action.mkdir.name);
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "a\x00b" }) |invalid_name| {
        try std.testing.expectError(error.InvalidName, service.submit(mkdir_key, .{ .endpoint = endpoint, .request_id = 12, .path = "/original", .action = .{ .mkdir = .{ .name = invalid_name } } }));
    }
    try std.testing.expectError(error.AbsolutePathRequired, service.submit(mkdir_key, .{ .endpoint = endpoint, .request_id = 12, .path = ".", .action = .{ .mkdir = .{ .name = "valid" } } }));
    try std.testing.expectEqualStrings("/original/a b", service.works.items[0].path);
    var stale = endpoint;
    stale.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, service.submit(key, .{ .endpoint = stale, .request_id = 9, .path = "/", .action = .stat }));
    var wrong_key = key;
    wrong_key.owner.session.generation += 1;
    try std.testing.expectError(error.OwnerMismatch, service.submit(wrong_key, .{ .endpoint = endpoint, .request_id = 12, .path = "/", .action = .stat }));
    try std.testing.expectError(error.DuplicateOperation, service.submit(key, .{ .endpoint = endpoint, .request_id = 12, .path = "/", .action = .stat }));
    try std.testing.expectError(error.InvalidReadLimit, service.submit(second, .{ .endpoint = endpoint, .request_id = 12, .path = "/a", .action = .{ .read_text = .{ .max_bytes = 0 } } }));
    try std.testing.expectError(error.InvalidReadLimit, service.submit(second, .{ .endpoint = endpoint, .request_id = 12, .path = "/a", .action = .{ .read_text = .{ .max_bytes = 65537 } } }));
    try std.testing.expectError(error.InvalidEntryLimit, service.submit(second, .{ .endpoint = endpoint, .request_id = 12, .path = "/", .action = .{ .list = .{ .page_entries = 129 } } }));
    try std.testing.expectError(error.InvalidPath, service.submit(second, .{ .endpoint = endpoint, .request_id = 12, .path = "/a\x00b", .action = .stat }));
    try std.testing.expectError(error.AbsolutePathRequired, service.submit(second, .{ .endpoint = endpoint, .request_id = 12, .path = "relative", .action = .stat }));
    try std.testing.expect(!service.cancel(wrong_key));
    try std.testing.expect(service.cancel(key));
    try std.testing.expect(!service.works.items[1].cancelled.load(.acquire));
    try std.testing.expectError(error.Busy, service.deinit());
    service.requestClose();
    gate.connect_release.store(true, .release);
    try testWait(&gate.close_entered);
    try std.testing.expectEqual(ReleaseReceipt.awaiting, service.closeReceipt());
    try std.testing.expect(!gate.destroyed.load(.acquire));
    try std.testing.expect(!service.worker_done.load(.acquire));
    gate.close_unknown.store(true, .release);
    const unknown_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (service.closeReceipt() != .unknown) {
        if (clock.monotonicNs() >= unknown_deadline) return error.TestTimedOut;
        pause(-1);
    }
    try std.testing.expectError(error.Busy, service.deinit());
    try std.testing.expect(!gate.destroyed.load(.acquire));
    try std.testing.expect(!service.worker_done.load(.acquire));
    gate.close_release.store(true, .release);
    try testWait(&service.worker_done);
    try std.testing.expectEqual(ReleaseReceipt.released, service.closeReceipt());
    try std.testing.expect(gate.destroyed.load(.acquire));
    var cancelled: usize = 0;
    while (service.poll()) |value| {
        var result = value;
        defer result.deinit();
        if (result.value.request_id != 0) {
            const expected = switch (result.value.request_id) {
                9 => key,
                10 => second,
                11 => mkdir_key,
                else => return error.UnexpectedRequest,
            };
            try std.testing.expect(result.value.key.eql(expected));
            try std.testing.expectEqual(Body.cancelled, result.value.body);
            cancelled += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), cancelled);
}
