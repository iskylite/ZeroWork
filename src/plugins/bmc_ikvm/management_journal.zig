//! Durable at-most-once dispatch ledger. A transport write is permitted only
//! after beginDispatch succeeds. Recovered dispatched operations can be queried
//! but can never be dispatched by reserve/beginDispatch again.
const std = @import("std");
const svc = @import("services.zig");
pub const schema_version: u32 = 1;
pub const max_journal_bytes = 4 * 1024 * 1024;
pub const max_entries = 1024;
pub const Parameters = union(enum) { power: svc.PowerAction, boot: svc.BootState };
pub const Baseline = struct { power: ?svc.PowerState = null, boot: ?svc.BootState = null, etag: ?[]const u8 = null, last_reset_time: ?[]const u8 = null };
pub const Entry = struct {
    session_id: u64,
    generation: u64,
    operation_id: u64,
    attempt_id: ?u64 = null,
    nonce: [16]u8,
    canonical_target: []const u8,
    system_identity: []const u8,
    parameters_sha256: [32]u8,
    parameters: Parameters,
    baseline: Baseline,
    dispatch_started: bool = false,
    phase: svc.Phase = .queued,
    reason: ?svc.Reason = null,
    http_status: ?u16 = null,
    task_uri: ?[]const u8 = null,
    current_power: ?svc.PowerState = null,
    current_boot: ?svc.BootState = null,
    pending_boot: ?svc.BootState = null,
    retry_after_ms: u64 = 0,
    pub fn key(self: Entry) svc.OperationKey {
        return .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(self.session_id), .generation = self.generation } }, .operation_id = self.operation_id, .attempt_id = self.attempt_id };
    }
    pub fn result(self: Entry) svc.Result {
        return .{ .operation = self.key(), .phase = self.phase, .reason = self.reason, .http_status = self.http_status, .dispatched = self.dispatch_started, .task_uri = self.task_uri, .current_power = self.current_power, .current_boot = self.current_boot, .pending_boot = self.pending_boot, .retry_after_ms = self.retry_after_ms };
    }
};
const Disk = struct { schema_version: u32, entries: []const Entry };
pub const Backend = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, std.mem.Allocator) anyerror!?[]u8,
    replace_durable: *const fn (*anyopaque, []const u8) anyerror!void,
};
pub const FileBackend = struct {
    io: std.Io,
    dir: std.Io.Dir,
    filename: []const u8,
    pub fn backend(self: *FileBackend) !Backend {
        if (self.filename.len == 0 or self.filename.len > 255 or std.mem.indexOfAny(u8, self.filename, "/\\\x00\r\n") != null or std.mem.eql(u8, self.filename, ".") or std.mem.eql(u8, self.filename, "..")) return error.InvalidJournalPath;
        return .{ .context = self, .read = read, .replace_durable = replace };
    }
    fn read(raw: *anyopaque, a: std.mem.Allocator) !?[]u8 {
        const self: *FileBackend = @ptrCast(@alignCast(raw));
        // No symlink following for existing journals.
        const file = self.dir.openFile(self.io, self.filename, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.nlink != 1 or stat.size > max_journal_bytes) return error.InvalidJournalFile;
        const bytes = try a.alloc(u8, @intCast(stat.size));
        errdefer a.free(bytes);
        var used: usize = 0;
        while (used < bytes.len) {
            const count = try file.readPositional(self.io, &.{bytes[used..]}, used);
            if (count == 0) return error.JournalChangedDuringRead;
            used += count;
        }
        var extra: [1]u8 = undefined;
        if (try file.readPositional(self.io, &.{&extra}, used) != 0) return error.JournalChangedDuringRead;
        return bytes;
    }
    fn replace(raw: *anyopaque, bytes: []const u8) !void {
        const self: *FileBackend = @ptrCast(@alignCast(raw));
        if (bytes.len > max_journal_bytes) return error.JournalTooLarge;
        var atomic = try self.dir.createFileAtomic(self.io, self.filename, .{ .replace = true, .permissions = @fromBackingInt(@intCast(0o600)) });
        defer atomic.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        while (true) switch (std.posix.errno(std.c.fsync(self.dir.handle))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.JournalDirectorySyncFailed,
        };
    }
};
pub const MemoryBackend = struct {
    allocator: std.mem.Allocator,
    bytes: ?[]u8 = null,
    writes: usize = 0,
    fail_writes: bool = false,
    pub fn backend(self: *MemoryBackend) Backend {
        return .{ .context = self, .read = read, .replace_durable = replace };
    }
    pub fn deinit(self: *MemoryBackend) void {
        if (self.bytes) |bytes| self.allocator.free(bytes);
        self.bytes = null;
    }
    fn read(raw: *anyopaque, a: std.mem.Allocator) !?[]u8 {
        const self: *MemoryBackend = @ptrCast(@alignCast(raw));
        return if (self.bytes) |bytes| try a.dupe(u8, bytes) else null;
    }
    fn replace(raw: *anyopaque, bytes: []const u8) !void {
        const self: *MemoryBackend = @ptrCast(@alignCast(raw));
        if (self.fail_writes) return error.InjectedJournalFailure;
        const copy = try self.allocator.dupe(u8, bytes);
        if (self.bytes) |old| self.allocator.free(old);
        self.bytes = copy;
        self.writes += 1;
    }
};
pub const Reservation = struct { index: usize, existing: bool };
pub const OwnedEntry = svc.Owned(Entry);
pub const EntrySnapshot = struct {
    index: usize,
    entry: OwnedEntry,
    pub fn deinit(self: *EntrySnapshot) void {
        self.entry.deinit();
        self.* = undefined;
    }
};
pub const Journal = struct {
    mutex: std.atomic.Mutex = .unlocked,
    arena: std.heap.ArenaAllocator,
    backend: Backend,
    /// Borrowed storage, for inspection only after all users have stopped.
    /// Concurrent consumers must use the owned snapshot APIs below.
    entries: []const Entry = &.{},
    pub fn init(a: std.mem.Allocator, backend: Backend) !Journal {
        var self: Journal = .{ .arena = .init(a), .backend = backend };
        errdefer self.arena.deinit();
        if (try backend.read(backend.context, self.arena.allocator())) |bytes| {
            const parsed = try std.json.parseFromSlice(Disk, self.arena.allocator(), bytes, .{ .allocate = .alloc_always });
            if (parsed.value.schema_version != schema_version or parsed.value.entries.len > max_entries) return error.UnsupportedJournalSchema;
            const entries = try self.arena.allocator().dupe(Entry, parsed.value.entries);
            var recovered = false;
            for (entries, 0..) |*entry, i| {
                try validateEntry(entry.*);
                for (entries[0..i]) |previous| if (previous.key().eql(entry.key()) or std.mem.eql(u8, &previous.nonce, &entry.nonce)) return error.DuplicateJournalOperation;
                if (!entry.result().terminal()) {
                    entry.phase = if (entry.dispatch_started) .outcome_unknown else .cancelled_unsent;
                    entry.reason = if (entry.dispatch_started) .transport_lost else .cancelled;
                    recovered = true;
                }
            }
            self.entries = entries;
            if (recovered) try self.persistLocked(entries);
        }
        return self;
    }
    pub fn deinit(self: *Journal) void {
        self.arena.deinit();
        self.* = undefined;
    }
    /// Indices remain stable because the ledger only appends entries.
    pub fn find(self: *Journal, key: svc.OperationKey) ?usize {
        self.lock();
        defer self.mutex.unlock();
        return self.findLocked(key);
    }
    fn findLocked(self: *const Journal, key: svc.OperationKey) ?usize {
        for (self.entries, 0..) |entry, i| if (entry.key().eql(key)) return i;
        return null;
    }
    pub fn snapshot(self: *Journal, a: std.mem.Allocator, index: usize) !OwnedEntry {
        self.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.len) return error.StaleOperation;
        return OwnedEntry.init(a, self.entries[index]);
    }
    pub fn snapshotOperation(self: *Journal, a: std.mem.Allocator, key: svc.OperationKey) !?EntrySnapshot {
        self.lock();
        defer self.mutex.unlock();
        const index = self.findLocked(key) orelse return null;
        return .{ .index = index, .entry = try OwnedEntry.init(a, self.entries[index]) };
    }
    pub fn snapshotOperationOrNonce(self: *Journal, a: std.mem.Allocator, key: svc.OperationKey, nonce: [16]u8) !?EntrySnapshot {
        self.lock();
        defer self.mutex.unlock();
        for (self.entries, 0..) |entry, index| if (entry.key().eql(key) or std.mem.eql(u8, &entry.nonce, &nonce)) {
            return .{ .index = index, .entry = try OwnedEntry.init(a, entry) };
        };
        return null;
    }
    pub fn snapshotResult(self: *Journal, a: std.mem.Allocator, key: svc.OperationKey) !?svc.Owned(svc.Result) {
        self.lock();
        defer self.mutex.unlock();
        const index = self.findLocked(key) orelse return null;
        return try svc.Owned(svc.Result).init(a, self.entries[index].result());
    }
    pub fn reserve(self: *Journal, execution: svc.Execution, target: []const u8, system_identity: []const u8, parameters: Parameters, baseline: Baseline) !Reservation {
        self.lock();
        defer self.mutex.unlock();
        const owner = switch (execution.operation.owner) {
            .session => |owner| owner,
            else => return error.InvalidOperationOwner,
        };
        if (!owner.eql(execution.call.owner)) return error.InvalidOperationOwner;
        var temporary: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer temporary.deinit();
        const a = temporary.allocator();
        const encoded = try std.json.Stringify.valueAlloc(a, parameters, .{});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});
        for (self.entries, 0..) |entry, i| if (entry.key().eql(execution.operation) or std.mem.eql(u8, &entry.nonce, &execution.nonce)) {
            if (!entry.key().eql(execution.operation) or !std.mem.eql(u8, &entry.nonce, &execution.nonce) or !std.mem.eql(u8, entry.canonical_target, target) or !std.mem.eql(u8, entry.system_identity, system_identity) or !std.mem.eql(u8, &entry.parameters_sha256, &hash)) return error.OperationConflict;
            return .{ .index = i, .existing = true };
        };
        if (self.entries.len >= max_entries) return error.JournalFull;
        const entry: Entry = .{ .session_id = @backingInt(owner.session_id), .generation = owner.generation, .operation_id = execution.operation.operation_id, .attempt_id = execution.operation.attempt_id, .nonce = execution.nonce, .canonical_target = target, .system_identity = system_identity, .parameters_sha256 = hash, .parameters = parameters, .baseline = baseline };
        try validateEntry(entry);
        const owned_bytes = try std.json.Stringify.valueAlloc(a, entry, .{});
        const owned = try std.json.parseFromSlice(Entry, a, owned_bytes, .{ .allocate = .alloc_always });
        const next = try a.alloc(Entry, self.entries.len + 1);
        @memcpy(next[0..self.entries.len], self.entries);
        next[self.entries.len] = owned.value;
        const index = next.len - 1;
        try self.persistLocked(next);
        return .{ .index = index, .existing = false };
    }
    pub fn beginDispatch(self: *Journal, index: usize) !void {
        self.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.len) return error.StaleOperation;
        var entry = self.entries[index];
        if (entry.dispatch_started or entry.result().terminal()) return error.OperationAlreadyDispatched;
        entry.dispatch_started = true;
        entry.phase = .sending;
        try self.updateLocked(index, entry);
    }
    /// A clean pre-write read may supply an anchor absent at discovery. Persist
    /// it before dispatch so recovery/query can use the same frozen baseline.
    pub fn collectLastResetBaseline(self: *Journal, index: usize, value: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.len) return error.StaleOperation;
        var entry = self.entries[index];
        if (entry.dispatch_started or entry.result().terminal() or entry.baseline.last_reset_time != null) return error.OperationAlreadyDispatched;
        if (svc.lastResetTimeMillis(value) == null) return error.InvalidJournalEntry;
        entry.baseline.last_reset_time = value;
        try self.updateLocked(index, entry);
    }
    pub fn setResult(self: *Journal, index: usize, result: svc.Result) !void {
        self.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.len or !self.entries[index].key().eql(result.operation)) return error.StaleOperation;
        var entry = self.entries[index];
        if (entry.dispatch_started and result.phase == .cancelled_unsent) return error.OperationAlreadyDispatched;
        entry.phase = result.phase;
        entry.reason = result.reason;
        entry.http_status = result.http_status;
        entry.task_uri = result.task_uri;
        entry.current_power = result.current_power;
        entry.current_boot = result.current_boot;
        entry.pending_boot = result.pending_boot;
        entry.retry_after_ms = result.retry_after_ms;
        try validateEntry(entry);
        try self.updateLocked(index, entry);
    }
    fn updateLocked(self: *Journal, index: usize, entry: Entry) !void {
        var temporary: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer temporary.deinit();
        const next = try temporary.allocator().dupe(Entry, self.entries);
        next[index] = entry;
        try self.persistLocked(next);
    }
    fn persistLocked(self: *Journal, entries: []const Entry) !void {
        var replacement: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        errdefer replacement.deinit();
        const encoded = try std.json.Stringify.valueAlloc(replacement.allocator(), Disk{ .schema_version = schema_version, .entries = entries }, .{});
        if (encoded.len > max_journal_bytes) return error.JournalTooLarge;
        const parsed = try std.json.parseFromSlice(Disk, replacement.allocator(), encoded, .{ .allocate = .alloc_always });
        try self.backend.replace_durable(self.backend.context, encoded);
        self.arena.deinit();
        self.arena = replacement;
        self.entries = parsed.value.entries;
    }
    fn lock(self: *Journal) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};
fn validText(value: []const u8, max: usize) bool {
    return value.len <= max and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}
fn validateEntry(entry: Entry) !void {
    if (entry.session_id == 0 or entry.generation == 0 or entry.operation_id == 0 or std.mem.allEqual(u8, &entry.nonce, 0) or entry.system_identity.len == 0 or !validText(entry.system_identity, 256) or !validText(entry.canonical_target, 4096) or !std.mem.startsWith(u8, entry.canonical_target, "https://") or std.mem.indexOfAny(u8, entry.canonical_target, "@?#\\% ") != null) return error.InvalidJournalEntry;
    if (!entry.dispatch_started and (entry.phase == .sending or entry.phase == .accepted_remote or entry.phase == .tracking_task or entry.phase == .verifying or entry.phase == .succeeded or entry.phase == .outcome_unknown)) return error.InvalidJournalEntry;
    if (entry.dispatch_started and entry.phase == .cancelled_unsent) return error.InvalidJournalEntry;
    const encoded = try std.json.Stringify.valueAlloc(std.heap.page_allocator, entry.parameters, .{});
    defer std.heap.page_allocator.free(encoded);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});
    if (!std.mem.eql(u8, &hash, &entry.parameters_sha256)) return error.InvalidJournalHash;
    if (entry.baseline.etag) |etag| if (!validText(etag, 1024)) return error.InvalidJournalEntry;
    if (entry.baseline.last_reset_time) |value| if (svc.lastResetTimeMillis(value) == null) return error.InvalidJournalEntry;
    if (entry.task_uri) |uri| if (!validText(uri, 4096) or !std.mem.startsWith(u8, uri, "/redfish/v1/") or std.mem.indexOfAny(u8, uri, "@#\\% ") != null or std.mem.indexOf(u8, uri, "..") != null) return error.InvalidJournalEntry;
    const states = [_]?svc.BootState{ entry.baseline.boot, switch (entry.parameters) {
        .boot => |state| state,
        else => null,
    }, entry.current_boot, entry.pending_boot };
    for (states) |state| if (state) |boot| {
        const fields = [_]?[]const u8{ boot.enabled, boot.target, boot.mode };
        for (fields) |field| if (field) |value| if (!validText(value, 256)) return error.InvalidJournalEntry;
    };
}
