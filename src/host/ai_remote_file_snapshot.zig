//! Bounded remote-file captures for one frozen AI resource picker/tool target.
//! FileBindingHost owns all SFTP IO and its original SessionHost journal. This
//! controller only consumes that service's results; it never opens local files,
//! borrows a native SSH session, chooses a tab, or attaches a draft implicitly.
const std = @import("std");
const files = @import("file_binding_host.zig");
const sessions = @import("session_host.zig");
const scope = @import("../ai/tool_scope.zig");
const clock = @import("../platform/realtime.zig");
const remote = files.readonly;

pub const default_read_bytes = 4096;
pub const max_read_bytes = remote.read_limit;
pub const default_list_entries = 256;
pub const max_list_entries = remote.entry_limit;

pub const Source = struct {
    session: sessions.SessionHandle,
    revision: u64,
    bindings: files.Bindings,

    pub fn eql(self: Source, other: Source) bool {
        return self.session.eql(other.session) and self.revision == other.revision and
            self.bindings.directory.eql(other.bindings.directory) and self.bindings.file_read.eql(other.bindings.file_read);
    }
};

/// Current state of the *original* picker/tool, never the active tab. Passing
/// null to poll invalidates a closed picker. Membership is checked at start and
/// every delivery, so removing a group member cannot publish an old capture.
pub const Context = struct { scope: scope.Scope, source: Source };
pub const Action = union(enum) {
    list: struct { max_entries: u32 = default_list_entries },
    read: struct { max_bytes: u32 = default_read_bytes },
};
pub const Metadata = struct {
    owner: scope.Owner,
    source: sessions.SessionHandle,
    source_revision: u64,
    operation: sessions.OperationKey,
    requested_path: []const u8,
    actual_path: ?[]const u8 = null,
    captured_at_ms: i64 = 0,
};
pub const Listing = struct {
    entries: []const remote.Entry,
    page_count: u32,
    entry_limit: u32,
    /// True only after native READDIR observed at least one additional entry.
    truncated: bool,
};
pub const Text = struct {
    bytes: []const u8,
    original_size: ?u64,
    /// Actual native read count, including the bounded look-ahead byte which
    /// proves truncation. returned_bytes can be smaller at a UTF-8 boundary.
    read_bytes: usize,
    returned_bytes: usize,
    read_limit: u32,
    encoding: enum { utf8 } = .utf8,
    truncated: bool,
};
pub const Failure = union(enum) {
    remote: remote.Failure,
    cancelled,
    source_changed,
    out_of_memory,
    protocol,
};
pub const Value = struct {
    metadata: Metadata,
    body: union(enum) { listing: Listing, text: Text, failure: Failure },
};
const Snapshot = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    references: std.atomic.Value(usize) = .init(1),
    value: Value,
};

/// Content and all metadata are immutable after take(). A preview and a sent
/// message may retain separate references without rereading a changed path.
pub const ResultRef = struct {
    snapshot: ?*Snapshot = null,

    pub fn value(self: ResultRef) ?Value {
        return if (self.snapshot) |snapshot| snapshot.value else null;
    }
    pub fn retain(self: ResultRef) ResultRef {
        const snapshot = self.snapshot orelse return .{};
        const previous = snapshot.references.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *ResultRef) void {
        const snapshot = self.snapshot orelse return;
        self.snapshot = null;
        if (snapshot.references.fetchSub(1, .acq_rel) != 1) return;
        const allocator = snapshot.allocator;
        snapshot.arena.deinit();
        allocator.destroy(snapshot);
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    host: *files.FileBindingHost,
    original: Context,
    action: Action,
    key: sessions.OperationKey,
    binding: sessions.ServiceHandle,
    owner_thread: std.Thread.Id,
    reference: ResultRef,
    entries: []remote.Entry,
    entry_count: usize = 0,
    page_count: u32 = 0,
    failure: ?Failure = null,
    terminal: bool = false,
    retired: bool = false,
    taken: bool = false,

    pub fn start(allocator: std.mem.Allocator, host: *files.FileBindingHost, original: Context, path: []const u8, action: Action) !*Reader {
        try validateContext(host, original);
        // SFTP resolves the explicit default-directory token to an absolute
        // remote path before listing; file reads still require an absolute path.
        if (!(action == .list and std.mem.eql(u8, path, "."))) try validatePath(path);
        try validateAction(action);
        const self = try allocator.create(Reader);
        errdefer allocator.destroy(self);
        const snapshot = try allocator.create(Snapshot);
        errdefer allocator.destroy(snapshot);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        // Allocate the terminal container and bounded list slots before IO.
        // Later OOM still has an allocation-free failure result and key owner.
        const owned_path = try arena.allocator().dupe(u8, path);
        const entries = try arena.allocator().alloc(remote.Entry, if (action == .list) action.list.max_entries else 0);
        const binding = if (action == .list) original.source.bindings.directory else original.source.bindings.file_read;
        const key = try host.begin(binding, .{ .path = owned_path, .directory_revision = original.source.revision, .action = switch (action) {
            .list => |options| .{ .list = .{ .max_entries = options.max_entries, .page_entries = pageSize(options.max_entries) } },
            .read => |options| .{ .read_text = .{ .max_bytes = options.max_bytes } },
        } });
        snapshot.* = .{ .allocator = allocator, .arena = arena, .value = .{
            .metadata = .{ .owner = original.scope.owner, .source = original.source.session, .source_revision = original.source.revision, .operation = key, .requested_path = owned_path },
            .body = .{ .failure = .protocol },
        } };
        self.* = .{ .allocator = allocator, .host = host, .original = original, .action = action, .key = key, .binding = binding, .owner_thread = std.Thread.getCurrentId(), .reference = .{ .snapshot = snapshot }, .entries = entries };
        return self;
    }

    /// No IO, joins or service ticks occur here. ApplicationHost must keep
    /// ticking FileBindingHost even after this picker has closed.
    pub fn poll(self: *Reader, live_context: ?Context) bool {
        self.assertOwner();
        if (!self.taken and !self.current(live_context)) {
            self.invalidate(.source_changed);
            if (self.terminal) self.reference.snapshot.?.value.body = .{ .failure = self.failure.? };
        }
        if (!self.terminal) {
            // Work is bounded per frame; a long directory cannot starve input.
            for (0..8) |_| {
                var response = self.host.take(self.key) orelse break;
                defer response.deinit();
                const result = response.result.value;
                if (!self.matches(response) or response.stale) self.invalidate(if (response.stale) .source_changed else .protocol);
                if (self.failure == null) self.consume(result) catch |err| self.invalidate(if (err == error.OutOfMemory) .out_of_memory else .protocol);
                if (result.final) {
                    self.terminal = true;
                    const snapshot = self.reference.snapshot.?;
                    if (self.failure) |failure| snapshot.value.body = .{ .failure = failure };
                    if (snapshot.value.metadata.captured_at_ms == 0) snapshot.value.metadata.captured_at_ms = clock.milliseconds(undefined);
                    break;
                }
            }
        }
        if (self.terminal and !self.retired and self.host.cleanupReceipt(self.key) == .released) {
            self.host.retire(self.key) catch return self.terminal;
            self.retired = true;
        }
        return self.terminal;
    }

    /// A queued success remains invalidatable until take. Cancelling affects
    /// only this exact original operation and cannot cancel a later source.
    pub fn cancel(self: *Reader) void {
        self.assertOwner();
        if (self.taken) return;
        self.invalidate(.cancelled);
        if (self.terminal) self.reference.snapshot.?.value.body = .{ .failure = self.failure.? };
    }

    pub fn take(self: *Reader) ?ResultRef {
        self.assertOwner();
        if (self.taken or !self.terminal) return null;
        self.taken = true;
        const result = self.reference;
        self.reference = .{};
        return result;
    }

    pub fn cleanupReceipt(self: *const Reader) remote.ReleaseReceipt {
        return if (self.retired) .released else self.host.cleanupReceipt(self.key);
    }

    /// Never forget an awaiting/unknown native operation. UI teardown cancels
    /// and retains this controller for safe ticks until deinit succeeds.
    pub fn deinit(self: *Reader) error{Busy}!void {
        self.assertOwner();
        if (!self.retired) return error.Busy;
        self.reference.release();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Exceptional application teardown only: FileBindingHost remains the
    /// native operation owner and must subsequently close and drain its own
    /// bindings. Release this presentation consumer without claiming cleanup.
    pub fn detachForHostShutdown(self: *Reader) void {
        self.assertOwner();
        self.cancel();
        self.reference.release();
        self.allocator.destroy(self);
    }

    fn current(self: *const Reader, maybe: ?Context) bool {
        const live = maybe orelse return false;
        if (!live.scope.owner.eql(self.original.scope.owner) or !live.source.eql(self.original.source)) return false;
        validateContext(self.host, live) catch return false;
        return true;
    }
    fn invalidate(self: *Reader, failure: Failure) void {
        if (self.failure == null) self.failure = failure;
        if (!self.terminal) _ = self.host.cancel(self.key);
    }
    fn matches(self: *const Reader, response: files.Response) bool {
        const value = response.result.value;
        return response.binding.eql(self.binding) and value.key.eql(self.key) and value.request_id == self.key.operation_id and
            value.directory_revision == self.original.source.revision and value.endpoint.resource_owner == .session and
            value.endpoint.resource_owner.session.eql(self.original.source.session) and
            std.mem.eql(u8, value.requested_path, self.reference.snapshot.?.value.metadata.requested_path);
    }
    fn consume(self: *Reader, result: remote.Result) !void {
        const snapshot = self.reference.snapshot.?;
        const allocator = snapshot.arena.allocator();
        if (result.resolved_path) |path| {
            try validatePath(path);
            if (snapshot.value.metadata.actual_path) |actual| {
                if (!std.mem.eql(u8, actual, path)) return error.RemotePathChanged;
            } else snapshot.value.metadata.actual_path = try allocator.dupe(u8, path);
        }
        switch (result.body) {
            .page => |page| {
                if (self.action != .list or page.index != self.page_count or page.entries.len > self.entries.len - self.entry_count) return error.InvalidRemotePage;
                for (page.entries) |entry| {
                    try validatePath(entry.absolute_path);
                    self.entries[self.entry_count] = .{
                        .raw_name = try allocator.dupe(u8, entry.raw_name),
                        .display_name = try allocator.dupe(u8, entry.display_name),
                        .absolute_path = try allocator.dupe(u8, entry.absolute_path),
                        .attributes = entry.attributes,
                    };
                    self.entry_count += 1;
                }
                self.page_count += 1;
                if (result.final) try self.finishList(false);
            },
            .text => |text| {
                if (self.action != .read or !result.final or snapshot.value.metadata.actual_path == null or
                    text.text.len > self.action.read.max_bytes or text.read_bytes > self.action.read.max_bytes + 1 or
                    text.text.len > text.read_bytes or !std.unicode.utf8ValidateSlice(text.text) or
                    std.mem.indexOfScalar(u8, text.text, 0) != null or text.truncated != (text.read_bytes > self.action.read.max_bytes)) return error.InvalidRemoteText;
                snapshot.value.body = .{ .text = .{ .bytes = try allocator.dupe(u8, text.text), .original_size = text.original_size, .read_bytes = text.read_bytes, .returned_bytes = text.text.len, .read_limit = self.action.read.max_bytes, .truncated = text.truncated } };
                snapshot.value.metadata.captured_at_ms = text.captured_at_ms;
            },
            .failure => |failure| {
                // READDIR proves a bounded partial list only after observing
                // an extra entry. Other failures never become empty success.
                if (failure == .entry_limit and self.action == .list and self.entry_count == self.entries.len) {
                    try self.finishList(true);
                } else self.failure = .{ .remote = failure };
            },
            .cancelled => self.failure = .cancelled,
            else => return error.UnexpectedRemoteResult,
        }
    }
    fn finishList(self: *Reader, truncated: bool) !void {
        const snapshot = self.reference.snapshot.?;
        if (snapshot.value.metadata.actual_path == null) return error.MissingRemotePath;
        snapshot.value.body = .{ .listing = .{ .entries = self.entries[0..self.entry_count], .page_count = self.page_count, .entry_limit = self.action.list.max_entries, .truncated = truncated } };
    }
    fn assertOwner(self: *const Reader) void {
        std.debug.assert(self.owner_thread == std.Thread.getCurrentId());
    }
};

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidRemotePath;
    if (path.len > remote.path_limit) return error.RemotePathTooLong;
}
fn validateAction(action: Action) !void {
    switch (action) {
        .read => |options| if (options.max_bytes == 0 or options.max_bytes > max_read_bytes) return error.InvalidReadLimit,
        .list => |options| if (options.max_entries == 0 or options.max_entries > max_list_entries) return error.InvalidEntryLimit,
    }
}
fn validateContext(host: *files.FileBindingHost, context: Context) !void {
    if (context.source.revision == 0 or context.source.session.generation == 0) return error.InvalidRemoteSource;
    _ = try context.scope.validate(&.{@backingInt(context.source.session.session_id)});
    for ([_]sessions.ServiceHandle{ context.source.bindings.directory, context.source.bindings.file_read }, [_]sessions.ServiceKind{ .directory, .file_read }) |binding, kind| {
        if (binding.kind != kind or binding.resource_owner != .session or !binding.resource_owner.session.eql(context.source.session)) return error.RemoteSourceMismatch;
        if (!host.sessions.bindingIsLive(binding)) return error.StaleRemoteSource;
        const state = host.state(binding) orelse return error.RemoteFilesUnavailable;
        if (state.phase != .ready) return error.RemoteFilesUnavailable;
    }
}
fn pageSize(limit: u32) u16 {
    // A complete multiple of native pages preserves exactly `limit` entries
    // before an entry_limit terminal, including caller limits smaller than128.
    var size = @min(limit, remote.page_limit);
    while (limit % size != 0) size -= 1;
    return @intCast(size);
}
