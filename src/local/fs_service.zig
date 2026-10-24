//! App-owned local filesystem service. No Local shell, process cwd, Session or
//! shell command is involved. A single worker owns every native file/dir handle;
//! the control thread only freezes requests and consumes owned results.
const std = @import("std");
const identity = @import("../host/identity.zig");
const operation = @import("../host/operation.zig");
const clock = @import("../platform/realtime.zig");

pub const OperationKey = operation.OperationKey;
pub const ReleaseReceipt = enum { released, awaiting, unknown };
pub const path_limit = 4096;
pub const read_limit = 65536;
pub const page_limit = 128;
pub const entry_limit = 4096;
const request_limit = 8;
const result_limit = 32;
const budget_ns = 30 * std.time.ns_per_s;

// Deliberately the same data shape as readonly SFTP, without importing SSH/C
// bindings into the host's independent local filesystem capability.
pub const Attributes = struct {
    kind: enum { file, directory, symlink, other, unknown } = .unknown,
    size: ?u64 = null,
    modified_at: ?u64 = null, // Epoch seconds, as in SFTP attributes.
    permissions: ?u32 = null,
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
pub const EndpointRef = struct {
    kind: enum { local_fs } = .local_fs,
    binding_id: u64,
    binding_generation: u64,
    resource_owner: ?identity.ResourceOwner = null,
    origin_session: ?identity.SessionHandle = null,
    connection_snapshot_id: ?u64 = null,

    pub fn eql(self: EndpointRef, other: EndpointRef) bool {
        return std.meta.eql(self, other);
    }
};
pub const Options = struct {
    /// The application supplies its local HOME once. This service never reads
    /// an interactive shell's cwd/environment or changes process cwd.
    home: ?[]const u8 = null,
};
pub const Action = union(enum) {
    realpath,
    stat, // lstat: preserves a symlink's own type and metadata.
    list: struct { page_entries: u16 = page_limit, max_entries: u32 = entry_limit },
    read_text: struct { max_bytes: u32 = 4096 },
    mkdir: struct { name: []const u8 },
};
pub const Request = struct {
    endpoint: EndpointRef,
    request_id: u64,
    directory_revision: u64 = 0,
    /// Absolute local path, or ~ / ~/... using the frozen local HOME. Relative
    /// UI navigation must first join against that card's original resolved path.
    path: []const u8,
    action: Action,
};
pub const Failure = enum {
    permission_denied,
    not_found,
    not_directory,
    already_exists,
    symlink_loop,
    path_limit,
    entry_limit,
    not_regular_file,
    unsupported_binary,
    unsupported_encoding,
    source_changed,
    timeout,
    out_of_memory,
    io,
};
pub const Body = union(enum) {
    realpath: []const u8,
    stat: Attributes,
    page: struct { index: u32, entries: []const Entry },
    text: Text,
    /// Actual mkdir success, before any independent refresh. A later cancel
    /// cannot turn an already-created directory into a cancelled/no-effect.
    created: []const u8,
    cancelled,
    failure: Failure,
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
    fn init(key: OperationKey, request: Request) !OwnedResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        return .{ .arena = arena, .value = .{
            .key = key,
            .endpoint = request.endpoint,
            .request_id = request.request_id,
            .directory_revision = request.directory_revision,
            .requested_path = try arena.allocator().dupe(u8, request.path),
            .body = .cancelled,
        } };
    }
};
const Work = struct {
    key: OperationKey,
    request: Request,
    path: []u8,
    name: ?[]u8,
    result: OwnedResult,
    deadline: i128,
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
    home: ?[]u8,
    mutex: Mutex = .{},
    works: std.ArrayList(*Work) = .empty,
    results: std.ArrayList(OwnedResult) = .empty,
    closing: std.atomic.Value(bool) = .init(false),
    worker_done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Does no filesystem IO. The application allocates the endpoint identity;
    /// a null ResourceOwner means app-owned and only accepts .app operation keys.
    /// Allocator use stays on the control thread; worker results own C arenas.
    pub fn start(allocator: std.mem.Allocator, endpoint: EndpointRef, options: Options) !*Service {
        try validateEndpoint(endpoint);
        if (options.home) |home| try validateAbsolute(home);
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        const home = if (options.home) |value| try allocator.dupe(u8, value) else null;
        errdefer if (home) |value| allocator.free(value);
        self.* = .{ .allocator = allocator, .endpoint = endpoint, .home = home };
        try self.works.ensureTotalCapacity(allocator, request_limit);
        errdefer self.works.deinit(allocator);
        try self.results.ensureTotalCapacity(allocator, result_limit);
        errdefer self.results.deinit(allocator);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Synchronous validation/deep copy only. Accepted input may be freed on
    /// return. Even a worker allocation failure has a reserved final result.
    pub fn submit(self: *Service, key: OperationKey, request: Request) !void {
        if (!self.endpoint.eql(request.endpoint)) return error.StaleBinding;
        try validateKey(self.endpoint, key, request.action == .read_text);
        try validateRequest(request);
        const work = try self.allocator.create(Work);
        errdefer self.allocator.destroy(work);
        const path = try expand(self.allocator, self.home, request.path);
        errdefer self.allocator.free(path);
        const name = if (request.action == .mkdir) try self.allocator.dupe(u8, request.action.mkdir.name) else null;
        errdefer if (name) |value| self.allocator.free(value);
        var result = try OwnedResult.init(key, request);
        errdefer result.deinit();
        work.* = .{ .key = key, .request = request, .path = path, .name = name, .result = result, .deadline = clock.monotonicNs() + budget_ns };
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
        if (result.value.final) {
            for (self.works.items, 0..) |work, index| if (work.finished and work.key.eql(result.value.key)) {
                _ = self.works.orderedRemove(index);
                self.freeWork(work);
                break;
            };
        }
        return result;
    }

    /// Never joins/cancels an unrelated service or runs native close on UI.
    pub fn requestClose(self: *Service) void {
        self.closing.store(true, .release);
    }

    /// Released only after actual file/dir close and worker IO deinit. A local
    /// OS call already in progress may finish before cancellation is observed.
    pub fn closeReceipt(self: *const Service) ReleaseReceipt {
        return if (self.worker_done.load(.acquire)) .released else .awaiting;
    }

    pub fn deinit(self: *Service) error{Busy}!void {
        if (self.closeReceipt() != .released) return error.Busy;
        if (self.thread) |thread| thread.join();
        for (self.results.items) |*result| result.deinit();
        self.results.deinit(self.allocator);
        for (self.works.items) |work| self.freeWork(work);
        self.works.deinit(self.allocator);
        if (self.home) |home| self.allocator.free(home);
        self.allocator.destroy(self);
    }

    fn freeWork(self: *Service, work: *Work) void {
        self.allocator.free(work.path);
        if (work.name) |name| self.allocator.free(name);
        self.allocator.destroy(work);
    }

    fn run(self: *Service) void {
        defer self.worker_done.store(true, .release);
        var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
        defer threaded.deinit();
        const io = threaded.io();
        while (true) {
            self.mutex.lock();
            var next: ?*Work = null;
            for (self.works.items) |work| if (!work.active and !work.finished) {
                work.active = true;
                next = work;
                break;
            };
            self.mutex.unlock();
            if (next) |work| {
                var context: Context = .{ .service = self, .work = work, .io = io };
                var result = work.result;
                context.process(&result) catch |err| {
                    result.value.body = if (err == error.Cancelled) .cancelled else .{ .failure = classify(err) };
                };
                // process has returned through every native handle's defer.
                self.mutex.lock();
                work.finished = true;
                self.results.appendAssumeCapacity(result);
                self.mutex.unlock();
            } else if (self.closing.load(.acquire)) break else pause();
        }
    }

    fn publishPage(self: *Service, work: *Work, result: OwnedResult) !void {
        while (true) {
            self.mutex.lock();
            // Reserve one final slot for every accepted request. Close/cancel
            // can finish even when the consumer has stopped draining pages.
            if (self.results.items.len < result_limit - request_limit) {
                self.results.appendAssumeCapacity(result);
                self.mutex.unlock();
                return;
            }
            self.mutex.unlock();
            var context: Context = .{ .service = self, .work = work, .io = undefined };
            try context.check();
            pause();
        }
    }
};

const Context = struct {
    service: *Service,
    work: *Work,
    io: std.Io,

    fn check(self: *Context) !void {
        if (self.service.closing.load(.acquire) or self.work.cancelled.load(.acquire)) return error.Cancelled;
        if (clock.monotonicNs() >= self.work.deadline) return error.Timeout;
    }
    fn canonical(self: *Context, allocator: std.mem.Allocator) ![]u8 {
        try self.check();
        var buffer: [path_limit + 1]u8 = undefined;
        const count = try std.Io.Dir.realPathFileAbsolute(self.io, self.work.path, &buffer);
        try self.check();
        try validateAbsolute(buffer[0..count]);
        return allocator.dupe(u8, buffer[0..count]);
    }
    fn process(self: *Context, result: *OwnedResult) !void {
        try self.check();
        if (self.work.request.action == .stat) {
            const stat = try std.Io.Dir.cwd().statFile(self.io, self.work.path, .{ .follow_symlinks = false });
            try self.check();
            result.value.body = .{ .stat = attributes(stat) };
            return;
        }
        const resolved = try self.canonical(result.arena.allocator());
        result.value.resolved_path = resolved;
        switch (self.work.request.action) {
            .realpath => result.value.body = .{ .realpath = resolved },
            .stat => unreachable,
            .list => |options| try self.list(result, resolved, options.page_entries, options.max_entries),
            .read_text => |options| try self.readText(result, resolved, options.max_bytes),
            .mkdir => |options| {
                // Allocate success payload first. OOM must not hide a mkdir
                // which really happened, and refresh is a separate request.
                const created = try joinPath(result.arena.allocator(), resolved, options.name);
                var directory = try std.Io.Dir.openDirAbsolute(self.io, resolved, .{ .follow_symlinks = false });
                defer directory.close(self.io);
                try self.check();
                try directory.createDir(self.io, options.name, .default_dir);
                result.value.body = .{ .created = created };
                return;
            },
        }
        try self.check();
    }
    fn list(self: *Context, result: *OwnedResult, resolved: []const u8, page_entries: usize, max_entries: usize) !void {
        try self.check();
        var directory = try std.Io.Dir.openDirAbsolute(self.io, resolved, .{ .iterate = true, .follow_symlinks = false });
        defer directory.close(self.io);
        var iterator = directory.iterate();
        var count: usize = 0;
        var index: u32 = 0;
        var page = try OwnedResult.init(result.value.key, .{ .endpoint = result.value.endpoint, .request_id = result.value.request_id, .directory_revision = result.value.directory_revision, .path = result.value.requested_path, .action = self.work.request.action });
        defer page.deinit();
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            try self.check();
            const item = try iterator.next(self.io) orelse {
                const target = result.arena.allocator();
                const owned = try target.alloc(Entry, entries.items.len);
                for (entries.items, owned) |entry, *copy| copy.* = try cloneEntry(target, entry);
                result.value.body = .{ .page = .{ .index = index, .entries = owned } };
                return;
            };
            try self.check();
            if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
            if (count == max_entries) return error.EntryLimit;
            const stat = try directory.statFile(self.io, item.name, .{ .follow_symlinks = false });
            try self.check();
            const allocator = page.arena.allocator();
            const raw_name = try allocator.dupe(u8, item.name);
            try entries.append(allocator, .{ .raw_name = raw_name, .display_name = try displayName(allocator, raw_name), .absolute_path = try joinPath(allocator, resolved, raw_name), .attributes = attributes(stat) });
            count += 1;
            if (entries.items.len == page_entries) {
                page.value.resolved_path = try allocator.dupe(u8, resolved);
                page.value.body = .{ .page = .{ .index = index, .entries = entries.items } };
                page.value.final = false;
                page.value.cleanup = .awaiting;
                const replacement = try OwnedResult.init(result.value.key, .{ .endpoint = result.value.endpoint, .request_id = result.value.request_id, .directory_revision = result.value.directory_revision, .path = result.value.requested_path, .action = self.work.request.action });
                self.service.publishPage(self.work, page) catch |err| {
                    var unused = replacement;
                    unused.deinit();
                    return err;
                };
                page = replacement;
                entries = .empty;
                index += 1;
            }
        }
    }
    fn readText(self: *Context, result: *OwnedResult, resolved: []const u8, max_bytes: usize) !void {
        try self.check();
        const before = try std.Io.Dir.cwd().statFile(self.io, resolved, .{ .follow_symlinks = false });
        if (before.kind != .file) return error.NotRegularFile;
        try self.check();
        var file = try std.Io.Dir.openFileAbsolute(self.io, resolved, .{ .allow_directory = false, .follow_symlinks = false });
        defer file.close(self.io);
        const opened = try file.stat(self.io);
        if (opened.kind != .file or changed(before, opened)) return error.SourceChanged;
        const bytes = try result.arena.allocator().alloc(u8, max_bytes + 1);
        var used: usize = 0;
        var eof = false;
        while (used < bytes.len) {
            try self.check();
            const count = try file.readPositional(self.io, &.{bytes[used..][0..@min(bytes.len - used, 32 * 1024)]}, used);
            try self.check();
            if (count == 0) {
                eof = true;
                break;
            }
            used += count;
        }
        const after = try file.stat(self.io);
        const path_after = std.Io.Dir.cwd().statFile(self.io, resolved, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.SourceChanged,
            else => return err,
        };
        if (changed(opened, after) or changed(before, path_after)) return error.SourceChanged;
        const truncated = used > max_bytes;
        result.value.body = .{ .text = .{
            .text = try validateText(bytes[0..used], max_bytes, truncated and !eof),
            .original_size = before.size,
            .read_bytes = used,
            .captured_at_ms = clock.milliseconds(undefined),
            .truncated = truncated,
        } };
    }
};

fn validateEndpoint(endpoint: EndpointRef) !void {
    if (endpoint.binding_id == 0 or endpoint.binding_generation == 0) return error.InvalidBinding;
    if (endpoint.resource_owner) |owner| switch (owner) {
        .session => |session| if (@backingInt(session.session_id) == 0 or session.generation == 0) return error.InvalidOwner,
        .retained_transfer => |id| if (@backingInt(id) == 0) return error.InvalidOwner,
    };
    if (endpoint.origin_session) |origin| if (@backingInt(origin.session_id) == 0 or origin.generation == 0) return error.InvalidOwner;
}
fn validateKey(endpoint: EndpointRef, key: OperationKey, text: bool) !void {
    if (key.operation_id == 0 or key.attempt_id == 0) return error.InvalidOperation;
    if (endpoint.resource_owner) |resource| switch (resource) {
        .session => |session| if (key.owner != .session or !key.owner.session.eql(session)) return error.OwnerMismatch,
        .retained_transfer => |owner| {
            if (text) return error.ReadNotAuthorized;
            if (key.owner != .transfer_owner or key.owner.transfer_owner.id != owner) return error.OwnerMismatch;
        },
    } else if (key.owner != .app) return error.OwnerMismatch;
}
fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > path_limit or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
}
fn validateAbsolute(path: []const u8) !void {
    try validatePath(path);
    if (path[0] != '/') return error.AbsolutePathRequired;
}
fn validateRequest(request: Request) !void {
    if (request.request_id == 0) return error.InvalidRequest;
    try validatePath(request.path);
    if (request.path[0] != '/' and !std.mem.eql(u8, request.path, "~") and !std.mem.startsWith(u8, request.path, "~/")) return error.AbsolutePathRequired;
    switch (request.action) {
        .list => |options| if (options.page_entries == 0 or options.page_entries > page_limit or options.max_entries == 0 or options.max_entries > entry_limit) return error.InvalidEntryLimit,
        .read_text => |options| if (options.max_bytes == 0 or options.max_bytes > read_limit) return error.InvalidReadLimit,
        .mkdir => |options| {
            try validatePath(options.name);
            try @import("../host/directory_name.zig").validate(options.name);
        },
        else => {},
    }
}
fn expand(allocator: std.mem.Allocator, home: ?[]const u8, path: []const u8) ![]u8 {
    if (path[0] == '/') return allocator.dupe(u8, path);
    const base = home orelse return error.HomeUnavailable;
    if (path.len == 1) return allocator.dupe(u8, base);
    const joined = try joinPath(allocator, base, path[2..]);
    return @constCast(joined);
}
fn joinPath(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) ![]const u8 {
    const separator: []const u8 = if (std.mem.endsWith(u8, directory, "/")) "" else "/";
    if (directory.len + separator.len + name.len > path_limit) return error.PathLimit;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ directory, separator, name });
}
fn attributes(stat: std.Io.File.Stat) Attributes {
    const seconds = stat.mtime.toSeconds();
    return .{
        .kind = switch (stat.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            .unknown => .unknown,
            else => .other,
        },
        .size = stat.size,
        .modified_at = if (seconds >= 0) @intCast(seconds) else null,
        .permissions = @intCast(@backingInt(stat.permissions)),
    };
}
fn changed(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.kind != after.kind or before.inode != after.inode or before.size != after.size or !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime);
}
fn cloneEntry(allocator: std.mem.Allocator, entry: Entry) !Entry {
    return .{ .raw_name = try allocator.dupe(u8, entry.raw_name), .display_name = try allocator.dupe(u8, entry.display_name), .absolute_path = try allocator.dupe(u8, entry.absolute_path), .attributes = entry.attributes };
}
fn displayName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(raw)) return raw;
    var display: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < raw.len) {
        const length = std.unicode.utf8ByteSequenceLength(raw[index]) catch 0;
        if (length > 0 and index + length <= raw.len and std.unicode.utf8ValidateSlice(raw[index..][0..length])) {
            try display.appendSlice(allocator, raw[index..][0..length]);
            index += length;
        } else {
            try display.appendSlice(allocator, "\xef\xbf\xbd");
            index += 1;
        }
    }
    return display.items;
}
fn validateText(bytes: []const u8, max_bytes: usize, truncated: bool) ![]const u8 {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.UnsupportedBinary;
    const used = @min(bytes.len, max_bytes);
    var index: usize = 0;
    while (index < used) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return error.UnsupportedEncoding;
        if (index + length > used) {
            if (!truncated) return error.UnsupportedEncoding;
            const available = @min(bytes.len - index, length);
            if (bytes[index] < 0xc2 or bytes[index] > 0xf4) return error.UnsupportedEncoding;
            for (bytes[index + 1 .. index + available]) |byte| if (byte & 0xc0 != 0x80) return error.UnsupportedEncoding;
            if (available > 1 and ((bytes[index] == 0xe0 and bytes[index + 1] < 0xa0) or (bytes[index] == 0xed and bytes[index + 1] > 0x9f) or (bytes[index] == 0xf0 and bytes[index + 1] < 0x90) or (bytes[index] == 0xf4 and bytes[index + 1] > 0x8f))) return error.UnsupportedEncoding;
            return bytes[0..index];
        }
        _ = std.unicode.utf8Decode(bytes[index..][0..length]) catch return error.UnsupportedEncoding;
        index += length;
    }
    return bytes[0..used];
}
fn classify(err: anyerror) Failure {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.FileNotFound => .not_found,
        error.NotDir => .not_directory,
        error.PathAlreadyExists => .already_exists,
        error.SymLinkLoop => .symlink_loop,
        error.PathLimit, error.NameTooLong, error.InvalidPath => .path_limit,
        error.EntryLimit => .entry_limit,
        error.NotRegularFile, error.IsDir => .not_regular_file,
        error.UnsupportedBinary => .unsupported_binary,
        error.UnsupportedEncoding => .unsupported_encoding,
        error.SourceChanged => .source_changed,
        error.Timeout => .timeout,
        error.OutOfMemory => .out_of_memory,
        else => .io,
    };
}
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}

fn testWaitPages(service: *Service) !void {
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (true) {
        service.mutex.lock();
        const full = service.results.items.len == result_limit - request_limit;
        service.mutex.unlock();
        if (full) return;
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
}
fn testStop(service: *Service) void {
    service.requestClose();
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (service.closeReceipt() != .released) {
        if (clock.monotonicNs() >= deadline) @panic("local filesystem worker did not close");
        pause();
    }
    service.deinit() catch unreachable;
}
fn testWorkerDir(path: []const u8, excluded: std.posix.fd_t) !std.posix.fd_t {
    // Actual macOS kernel handle observation, not a mirrored cleanup counter.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    for (0..1024) |index| {
        const fd: std.posix.fd_t = @intCast(index);
        if (fd == excluded) continue;
        var buffer: [path_limit + 1]u8 = @splat(0);
        if (std.c.fcntl(fd, std.c.F.GETPATH, &buffer) < 0) continue;
        const length = std.mem.indexOfScalar(u8, &buffer, 0) orelse continue;
        if (std.mem.eql(u8, path, buffer[0..length])) return fd;
    }
    return error.TestDirectoryHandleNotFound;
}

test "local fs cancellation and shutdown close actual backpressured directory handles" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "many", .default_dir);
    var many = try temporary.dir.openDir(std.testing.io, "many", .{});
    defer many.close(std.testing.io);
    for (0..48) |index| {
        var name: [32]u8 = undefined;
        try many.writeFile(std.testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "item-{d}", .{index}), .data = "x" });
    }
    const path = try many.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const endpoint: EndpointRef = .{ .binding_id = 51, .binding_generation = 2 };
    const service = try Service.start(std.testing.allocator, endpoint, .{});
    defer testStop(service);
    var journal = operation.Journal.init(std.testing.allocator);
    defer journal.deinit();
    const original = try journal.begin(.app, null);
    const list: Request = .{ .endpoint = endpoint, .request_id = 1, .directory_revision = 32, .path = path, .action = .{ .list = .{ .page_entries = 1 } } };
    try service.submit(original, list);
    try testWaitPages(service);
    const native_dir = try testWorkerDir(path, many.handle);
    try std.testing.expect(std.c.fcntl(native_dir, std.c.F.GETFD) >= 0);
    try std.testing.expectEqual(ReleaseReceipt.awaiting, service.closeReceipt());
    try std.testing.expectError(error.DuplicateOperation, service.submit(original, list));
    const sibling = try journal.begin(.app, null);
    try service.submit(sibling, .{ .endpoint = endpoint, .request_id = 2, .path = path, .action = .{ .mkdir = .{ .name = "sibling-created" } } });
    var wrong = original;
    wrong.attempt_id = 1;
    try std.testing.expect(!service.cancel(wrong));
    try std.testing.expect(service.cancel(original));
    var finals: usize = 0;
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (finals < 2) {
        if (service.poll()) |value| {
            var result = value;
            defer result.deinit();
            if (!result.value.final) continue;
            try std.testing.expectEqual(ReleaseReceipt.released, result.value.cleanup);
            if (result.value.key.eql(original)) {
                try std.testing.expectEqual(Body.cancelled, result.value.body);
                try std.testing.expectEqual(@as(u64, 32), result.value.directory_revision);
            } else {
                try std.testing.expect(result.value.key.eql(sibling));
                try std.testing.expect(result.value.body == .created);
            }
            finals += 1;
        } else {
            if (clock.monotonicNs() >= deadline) return error.TestTimeout;
            pause();
        }
    }
    try std.testing.expect(std.c.fcntl(native_dir, std.c.F.GETFD) < 0);
    try std.testing.expectEqual(.directory, (try many.statFile(std.testing.io, "sibling-created", .{})).kind);

    const closing_list = try journal.begin(.app, null);
    try service.submit(closing_list, list);
    try testWaitPages(service);
    const closing_dir = try testWorkerDir(path, many.handle);
    const queued_mkdir = try journal.begin(.app, null);
    try service.submit(queued_mkdir, .{ .endpoint = endpoint, .request_id = 3, .path = path, .action = .{ .mkdir = .{ .name = "must-not-exist" } } });
    service.mutex.lock();
    service.requestClose();
    const still_awaiting = service.closeReceipt();
    const cannot_deinit = service.deinit();
    service.mutex.unlock();
    try std.testing.expectEqual(ReleaseReceipt.awaiting, still_awaiting);
    try std.testing.expectError(error.Busy, cannot_deinit);
    const close_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (service.closeReceipt() != .released) {
        if (clock.monotonicNs() >= close_deadline) return error.TestTimeout;
        pause();
    }
    // Completion does not depend on draining the already-full result queue.
    try std.testing.expect(service.worker_done.load(.acquire));
    try std.testing.expect(std.c.fcntl(closing_dir, std.c.F.GETFD) < 0);
    try std.testing.expectError(error.FileNotFound, many.statFile(std.testing.io, "must-not-exist", .{}));
    finals = 0;
    while (service.poll()) |value| {
        var result = value;
        defer result.deinit();
        if (result.value.final) {
            try std.testing.expect(result.value.key.eql(closing_list) or result.value.key.eql(queued_mkdir));
            try std.testing.expectEqual(Body.cancelled, result.value.body);
            try std.testing.expectEqual(ReleaseReceipt.released, result.value.cleanup);
            finals += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), finals);
    const late = try journal.begin(.app, null);
    try std.testing.expectError(error.Closing, service.submit(late, list));
}

test "local fs display keeps invalid raw bytes separate and metadata detects replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw = "a-\xff-你";
    try std.testing.expectEqualStrings("a-�-你", try displayName(arena.allocator(), raw));
    try std.testing.expectEqualStrings("a-\xff-你", raw);
    try std.testing.expectEqualStrings("a", try validateText("a你", 2, true));
    try std.testing.expectError(error.UnsupportedEncoding, validateText("a\xe4\xbd", 4096, false));
    try std.testing.expectError(error.UnsupportedEncoding, validateText("\xed\xa0", 1, true));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source", .data = "before" });
    const before = try temporary.dir.statFile(std.testing.io, "source", .{});
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source", .data = "after-longer" });
    const after = try temporary.dir.statFile(std.testing.io, "source", .{});
    try std.testing.expect(changed(before, after));
}
