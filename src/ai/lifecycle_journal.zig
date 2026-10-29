//! One IO owner persists metadata before an effect. No command/credential/output
//! text is accepted here. Controllers exchange handles and owned snapshots.
const std = @import("std");
const identity = @import("../host/identity.zig");
const host = @import("host_tools.zig");
const scope = @import("tool_scope.zig");
const Digest = [32]u8;
const ExecutionReceipt = @import("../host/terminal_execution.zig").PublicReceipt;
pub const max_records = 512;
pub const max_file_bytes = 2 * 1024 * 1024;
pub const Stage = enum { prepared, dispatch_started, committed, running, succeeded, failed, rejected, cancelled_unsent, outcome_unknown, cleanup_pending };
pub const Ownership = enum { borrowed_user, created_task, handed_to_user };
pub const Record = struct {
    context: host.Context,
    operation_ref: identity.HostOperationId,
    tool_id: []const u8,
    request_key: []const u8,
    canonical_hash: Digest,
    original_turn: u64,
    original_call: []const u8,
    revision: u64 = 1,
    stage: Stage = .prepared,
    dispatch_started: bool = false,
    created_group: ?u64 = null,
    created_session: ?identity.SessionHandle = null,
    execution: ?identity.ExecutionId = null,
    execution_receipt: ?ExecutionReceipt = null,
    committed_binding: ?scope.Owner = null,
    committed_binding_revision: ?u64 = null,
    ownership: Ownership = .borrowed_user,
    ownership_revision: u64 = 1,
    local_released: bool = true,
    remote_effect_unknown: bool = false,
    notice_revision: u64 = 0,
    wire_notice_revision: u64 = 0,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_id);
        allocator.free(self.request_key);
        allocator.free(self.original_call);
        if (self.execution_receipt) |receipt| if (receipt.output_attribution_reason) |reason| allocator.free(reason);
        self.* = undefined;
    }
    fn clone(self: Record, a: std.mem.Allocator) !Record {
        var out = self;
        out.tool_id = try a.dupe(u8, self.tool_id);
        errdefer a.free(out.tool_id);
        out.request_key = try a.dupe(u8, self.request_key);
        errdefer a.free(out.request_key);
        out.original_call = try a.dupe(u8, self.original_call);
        errdefer a.free(out.original_call);
        if (self.execution_receipt) |receipt| if (receipt.output_attribution_reason) |reason| {
            out.execution_receipt.?.output_attribution_reason = try a.dupe(u8, reason);
        };
        return out;
    }
};
pub const Request = struct { context: host.Context, tool_id: []const u8, request_key: []const u8, canonical_hash: Digest, turn_id: u64, call_id: []const u8 };
pub const Handle = struct { index: usize, operation_ref: identity.HostOperationId, reused: bool = false };
pub const Update = struct {
    stage: Stage,
    created_group: ?u64 = null,
    created_session: ?identity.SessionHandle = null,
    execution: ?identity.ExecutionId = null,
    execution_receipt: ?ExecutionReceipt = null,
    committed_binding: ?scope.Owner = null,
    committed_binding_revision: ?u64 = null,
    ownership: ?Ownership = null,
    local_released: bool = true,
    remote_effect_unknown: bool = false,
    notice_revision: ?u64 = null,
    wire_notice_revision: ?u64 = null,
};
const Disk = struct { schema_version: u32, records: []const Record };
pub const Journal = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []u8,
    lock_file: std.Io.File,
    records: std.ArrayList(Record) = .empty,
    disk_hash: ?Digest = null,

    /// A process data-scope lock plus this advisory file lock prevent competing
    /// window workers from maintaining separate snapshots of the same journal.
    pub fn open(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Journal {
        if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOf(u8, path, "..") != null) return error.InvalidJournalPath;
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
        const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
        defer a.free(lock_path);
        const lock_file = try dir.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = @fromBackingInt(0o600) });
        errdefer lock_file.close(io);
        var journal: Journal = .{ .allocator = a, .io = io, .dir = dir, .path = try a.dupe(u8, path), .lock_file = lock_file };
        errdefer {
            for (journal.records.items) |*record| record.deinit(a);
            journal.records.deinit(a);
            a.free(journal.path);
        }
        const source = dir.readFileAlloc(io, path, a, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return journal,
            else => return err,
        };
        defer a.free(source);
        journal.disk_hash = hash(source);
        const parsed = try std.json.parseFromSlice(Disk, a, source, .{});
        defer parsed.deinit();
        if (parsed.value.schema_version != 1) return error.UnsupportedJournalSchema;
        if (parsed.value.records.len > max_records) return error.JournalLimit;
        try journal.records.ensureTotalCapacity(a, parsed.value.records.len);
        var recovered = false;
        for (parsed.value.records) |value| {
            try validateRecord(value);
            for (journal.records.items) |prior| if (prior.operation_ref.eql(value.operation_ref) or sameKey(prior, value.context, value.tool_id, value.request_key)) return error.InvalidJournal;
            var owned = try value.clone(a);
            switch (owned.stage) {
                .prepared => {
                    owned.stage = .cancelled_unsent;
                    owned.local_released = true;
                    owned.revision = identity.advance(owned.revision) catch |err| {
                        owned.deinit(a);
                        return err;
                    };
                    recovered = true;
                },
                .dispatch_started, .running => {
                    owned.stage = .outcome_unknown;
                    owned.remote_effect_unknown = true;
                    owned.local_released = false;
                    owned.revision = identity.advance(owned.revision) catch |err| {
                        owned.deinit(a);
                        return err;
                    };
                    recovered = true;
                },
                else => {},
            }
            journal.records.appendAssumeCapacity(owned);
        }
        if (recovered) try journal.persist(journal.records.items);
        return journal;
    }
    pub fn deinit(self: *Journal) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.allocator.free(self.path);
        self.lock_file.close(self.io);
        self.* = undefined;
    }
    /// Repeated provider call IDs do not create another operation. A changed
    /// binding/grant may inspect the old receipt but does not revive authority.
    pub fn begin(self: *Journal, request: Request) !Handle {
        try request.context.validate();
        try validateKey(request.tool_id, request.request_key, request.call_id);
        if (request.turn_id == 0) return error.InvalidJournalRequest;
        for (self.records.items, 0..) |record, index| if (sameKey(record, request.context, request.tool_id, request.request_key)) {
            if (!std.mem.eql(u8, &record.canonical_hash, &request.canonical_hash)) return error.IdempotencyConflict;
            return .{ .index = index, .operation_ref = record.operation_ref, .reused = true };
        };
        if (self.records.items.len >= max_records) return error.JournalLimit;
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        var record = try (Record{ .context = request.context, .operation_ref = identity.HostOperationId.generate(), .tool_id = request.tool_id, .request_key = request.request_key, .canonical_hash = request.canonical_hash, .original_turn = request.turn_id, .original_call = request.call_id }).clone(self.allocator);
        errdefer record.deinit(self.allocator);
        const next = try self.allocator.alloc(Record, self.records.items.len + 1);
        defer self.allocator.free(next);
        @memcpy(next[0..self.records.items.len], self.records.items);
        next[self.records.items.len] = record;
        try self.persist(next);
        self.records.appendAssumeCapacity(record);
        return .{ .index = self.records.items.len - 1, .operation_ref = record.operation_ref };
    }
    pub fn snapshot(self: *Journal, a: std.mem.Allocator, handle: Handle) !Record {
        const record = try self.get(handle);
        return record.clone(a);
    }
    fn get(self: *Journal, handle: Handle) !Record {
        if (handle.index >= self.records.items.len or !self.records.items[handle.index].operation_ref.eql(handle.operation_ref)) return error.StaleOperation;
        return self.records.items[handle.index];
    }
    pub fn update(self: *Journal, handle: Handle, expected_revision: u64, change: Update) !void {
        var record = try self.get(handle);
        if (record.revision != expected_revision) return error.JournalRevisionChanged;
        if (!transitionAllowed(record.stage, change.stage)) return error.InvalidJournalTransition;
        record.revision = try identity.advance(record.revision);
        record.stage = change.stage;
        record.dispatch_started = record.dispatch_started or change.stage == .dispatch_started;
        if (change.created_group) |value| {
            if (record.created_group != null and record.created_group.? != value) return error.ResourceIdentityChanged;
            record.created_group = value;
        }
        if (change.created_session) |value| {
            if (record.created_session) |prior| if (!prior.eql(value)) return error.ResourceIdentityChanged;
            record.created_session = value;
        }
        if (change.execution) |value| {
            if (record.execution) |prior| if (!prior.eql(value)) return error.ResourceIdentityChanged;
            record.execution = value;
        }
        if (change.execution_receipt) |receipt| {
            const execution_id = record.execution orelse return error.InvalidExecutionReceipt;
            if (!execution_id.eql(receipt.execution_id)) return error.ResourceIdentityChanged;
            if (record.execution_receipt) |prior| try receipt.validateTransition(prior) else try receipt.validate();
            record.execution_receipt = receipt;
        }
        if (change.committed_binding) |value| {
            if (record.committed_binding) |prior| if (!prior.eql(value)) return error.ResourceIdentityChanged;
            record.committed_binding = value;
        }
        if (change.committed_binding_revision) |value| {
            if (record.committed_binding_revision != null and record.committed_binding_revision.? != value) return error.ResourceIdentityChanged;
            record.committed_binding_revision = value;
        }
        if (change.ownership) |value| {
            if (record.ownership == .handed_to_user and value != .handed_to_user) return error.OwnershipChanged;
            if (value != record.ownership) record.ownership_revision = try identity.advance(record.ownership_revision);
            record.ownership = value;
        }
        record.local_released = change.local_released;
        record.remote_effect_unknown = record.remote_effect_unknown or change.remote_effect_unknown;
        if (change.notice_revision) |value| {
            if (value < record.notice_revision) return error.StaleNotice;
            record.notice_revision = value;
        }
        if (change.wire_notice_revision) |value| {
            if (value < record.wire_notice_revision or value > record.notice_revision) return error.StaleNotice;
            record.wire_notice_revision = value;
        }
        try validateRecord(record);
        // Receipt strings arrive borrowed from a worker snapshot or JSON arena.
        // Own the bounded reason only after validation, then publish it with
        // the transaction; a failed persist keeps the prior memory intact.
        var owned_reason: ?[]u8 = null;
        if (change.execution_receipt != null) if (record.execution_receipt.?.output_attribution_reason) |reason| {
            owned_reason = try self.allocator.dupe(u8, reason);
            record.execution_receipt.?.output_attribution_reason = owned_reason;
        };
        errdefer if (owned_reason) |reason| self.allocator.free(reason);
        const next = try self.allocator.dupe(Record, self.records.items);
        defer self.allocator.free(next);
        next[handle.index] = record;
        try self.persist(next);
        if (change.execution_receipt != null) if (self.records.items[handle.index].execution_receipt) |prior| if (prior.output_attribution_reason) |reason| self.allocator.free(reason);
        self.records.items[handle.index] = record;
    }
    fn persist(self: *Journal, records: []const Record) !void {
        const current = self.dir.readFileAlloc(self.io, self.path, self.allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (current) |value| self.allocator.free(value);
        const current_hash = if (current) |value| @as(?Digest, hash(value)) else null;
        if (!std.meta.eql(current_hash, self.disk_hash)) return error.JournalConflict;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, Disk{ .schema_version = 1, .records = records }, .{});
        defer self.allocator.free(encoded);
        if (encoded.len > max_file_bytes) return error.JournalLimit;
        var atomic = try self.dir.createFileAtomic(self.io, self.path, .{ .permissions = @fromBackingInt(0o600), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, encoded);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.disk_hash = hash(encoded);
    }
};
fn hash(text: []const u8) Digest {
    var out: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &out, .{});
    return out;
}
fn sameKey(record: Record, context: host.Context, tool_id: []const u8, key: []const u8) bool {
    return record.context.conversation_id.eql(context.conversation_id) and record.context.task_id.eql(context.task_id) and std.mem.eql(u8, record.tool_id, tool_id) and std.mem.eql(u8, record.request_key, key);
}
fn validateKey(tool: []const u8, key: []const u8, call: []const u8) !void {
    if (!std.mem.startsWith(u8, tool, "host.") or tool.len > 64 or key.len == 0 or key.len > 128 or call.len == 0 or call.len > 256 or !std.unicode.utf8ValidateSlice(call) or std.mem.indexOfScalar(u8, call, 0) != null) return error.InvalidJournalRequest;
    for (key) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != ':') return error.InvalidJournalRequest;
}
fn validateRecord(record: Record) !void {
    try record.context.validate();
    try validateKey(record.tool_id, record.request_key, record.original_call);
    if (!record.operation_ref.valid() or record.original_turn == 0 or record.revision == 0 or record.ownership_revision == 0 or record.wire_notice_revision > record.notice_revision) return error.InvalidJournal;
    if (record.stage == .succeeded and (!record.local_released or record.remote_effect_unknown)) return error.InvalidJournal;
    if (record.committed_binding != null and (record.committed_binding_revision == null or record.committed_binding_revision.? <= record.context.binding_revision)) return error.InvalidJournal;
    if (record.execution_receipt) |receipt| {
        const execution_id = record.execution orelse return error.InvalidExecutionReceipt;
        if (!execution_id.eql(receipt.execution_id)) return error.InvalidExecutionReceipt;
        try receipt.validate();
    }
    if (record.created_group) |value| if (value == 0) return error.InvalidJournal;
    if (record.created_session) |value| if (@backingInt(value.session_id) == 0 or value.generation == 0) return error.InvalidJournal;
    if (record.ownership != .borrowed_user and record.created_session == null) return error.InvalidJournal;
}
fn transitionAllowed(before: Stage, after: Stage) bool {
    return switch (before) {
        .prepared => after == .dispatch_started or after == .committed or after == .rejected or after == .cancelled_unsent or after == .failed,
        .dispatch_started => after == .dispatch_started or after == .committed or after == .running or after == .succeeded or after == .failed or after == .outcome_unknown,
        .committed => after == .succeeded or after == .running or after == .cleanup_pending or after == .outcome_unknown,
        .running => after == .running or after == .succeeded or after == .failed or after == .outcome_unknown or after == .cleanup_pending,
        .cleanup_pending => after == .cleanup_pending or after == .succeeded or after == .failed or after == .outcome_unknown,
        .outcome_unknown => after == .outcome_unknown or after == .cleanup_pending,
        .succeeded, .failed, .rejected, .cancelled_unsent => after == before,
    };
}

test {
    _ = @import("lifecycle_journal_tests.zig");
}
