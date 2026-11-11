//! One IO owner persists metadata before an effect. No command/credential/output
//! text is accepted here. Controllers exchange handles and owned snapshots.
const std = @import("std");
const identity = @import("../host/identity.zig");
const host = @import("host_tools.zig");
const scope = @import("tool_scope.zig");
const file_commit = @import("../host/local_file_commit.zig");
const file_reads = @import("../host/local_file_reads.zig");
pub const local_file_tool_id = "host.local_file_mutation";
const max_file_records = 4096;
pub const max_recovery_bytes = 128 * 1024 * 1024;
pub const LocalFileSelector = union(enum) {
    request_key: []const u8,
    operation_ref: identity.HostOperationId,
};
pub const LocalFileScope = struct {
    conversation_id: identity.ConversationId,
    task_id: identity.TaskId,

    pub fn from(context: host.Context) LocalFileScope {
        return .{ .conversation_id = context.conversation_id, .task_id = context.task_id };
    }

    pub fn matches(self: LocalFileScope, context: host.Context) bool {
        return self.conversation_id.eql(context.conversation_id) and self.task_id.eql(context.task_id);
    }
};
pub const max_change_page = 12;
pub const LocalFilePage = struct {
    rows: []Row,
    snapshot: [32]u8,
    next_offset: ?usize,
    pub const Row = struct {
        record: Record,
        previous_operation: ?identity.HostOperationId = null,
        version_chain: enum { first_observed, continuous, discontinuity, unproven } = .first_observed,
    };

    pub fn deinit(self: LocalFilePage, a: std.mem.Allocator) void {
        for (self.rows) |*row| row.record.deinit(a);
        a.free(self.rows);
    }
};

pub const LocalFileExpiry = struct {
    expired: usize = 0,
    pending: usize = 0,
    failed: usize = 0,
};

pub const LocalFileResult = struct {
    status: file_commit.Status,
    side_effect_started: bool = false,
    created_parent_count: u8 = 0,
    committed: bool = false,
    verified: bool = false,
    conflict: bool = false,
    actual_before_version: ?file_reads.Version = null,
    submitted_after_version: ?file_reads.Version = null,
    diff_ref: ?file_commit.DiffRef = null,
    reason: ?[]const u8 = null,
    target: ?[]const u8 = null,
};
const Digest = [32]u8;
const ExecutionReceipt = @import("../host/terminal_execution.zig").PublicReceipt;
pub const Stage = enum { prepared, dispatch_started, committed, running, succeeded, failed, rejected, cancelled_unsent, outcome_unknown, cleanup_pending };
pub const Ownership = enum { borrowed_user, created_task, handed_to_user };
pub const Record = struct {
    verification: ?@import("readonly_verification.zig").Anchor = null,
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
    /// Saved-host identity only; never a live session or credential source.
    created_asset: ?identity.AssetOwner = null,
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
    local_file_evidence: ?file_commit.Evidence = null,
    local_file_result: ?LocalFileResult = null,
    local_file_parent_progress: ?u8 = null,
    local_file_order: ?u64 = null,
    local_file_material_expired: ?bool = null,

    pub fn jsonStringify(self: Record, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Record).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.startsWith(u8, name, "local_file_")) @field(self, name) != null else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_id);
        allocator.free(self.request_key);
        allocator.free(self.original_call);
        if (self.execution_receipt) |receipt| if (receipt.output_attribution_reason) |reason| allocator.free(reason);
        if (self.local_file_evidence) |evidence| freeFileEvidence(allocator, evidence);
        if (self.local_file_result) |value| freeFileResult(allocator, value);
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
        errdefer if (out.execution_receipt) |receipt| if (receipt.output_attribution_reason) |reason| a.free(reason);
        if (self.local_file_evidence) |value| out.local_file_evidence = try cloneFileEvidence(a, value);
        errdefer if (out.local_file_evidence) |value| freeFileEvidence(a, value);
        if (self.local_file_result) |value| out.local_file_result = try cloneFileResult(a, value);
        return out;
    }
};
pub const Request = struct { context: host.Context, tool_id: []const u8, request_key: []const u8, canonical_hash: Digest, turn_id: u64, call_id: []const u8 };
pub const Handle = struct { index: usize, operation_ref: identity.HostOperationId, reused: bool = false };
pub const Update = struct {
    verification: ?@import("readonly_verification.zig").Anchor = null,
    stage: Stage,
    created_group: ?u64 = null,
    created_session: ?identity.SessionHandle = null,
    created_asset: ?identity.AssetOwner = null,
    execution: ?identity.ExecutionId = null,
    execution_receipt: ?ExecutionReceipt = null,
    committed_binding: ?scope.Owner = null,
    committed_binding_revision: ?u64 = null,
    ownership: ?Ownership = null,
    local_released: bool = true,
    remote_effect_unknown: bool = false,
    notice_revision: ?u64 = null,
    wire_notice_revision: ?u64 = null,
    local_file_evidence: ?file_commit.Evidence = null,
    local_file_result: ?LocalFileResult = null,
    local_file_parent_progress: ?u8 = null,
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
    local_file_last_order: u64 = 1,

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
        const source = dir.readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return journal,
            else => return err,
        };
        defer a.free(source);
        journal.disk_hash = hash(source);
        const parsed = try std.json.parseFromSlice(Disk, a, source, .{});
        defer parsed.deinit();
        if (parsed.value.schema_version < 1 or parsed.value.schema_version > 3) return error.UnsupportedJournalSchema;
        try journal.records.ensureTotalCapacity(a, parsed.value.records.len);
        var recovered = false;
        var file_count: usize = 0;
        var recovery_bytes: usize = 0;
        for (parsed.value.records) |value| {
            if (value.local_file_order) |order| journal.local_file_last_order = @max(journal.local_file_last_order, order);
        }
        for (parsed.value.records) |value| {
            if (parsed.value.schema_version == 1 and value.context.child_origin != null) return error.UnsupportedJournalSchema;
            if (isLocalFile(value.tool_id)) {
                if (parsed.value.schema_version < 3) return error.UnsupportedJournalSchema;
                file_count += 1;
                if (file_count > max_file_records) return error.LocalFileOperationLimit;
                if (value.local_file_material_expired != true) if (value.local_file_evidence) |evidence| {
                    if (evidence.reserved_bytes > max_recovery_bytes - recovery_bytes) return error.RecoveryQuotaExceeded;
                    recovery_bytes += evidence.reserved_bytes;
                };
            }
            try validateRecord(value);
            for (journal.records.items) |prior| {
                if (prior.operation_ref.eql(value.operation_ref) or sameKey(prior, value.context, value.tool_id, value.request_key)) return error.InvalidJournal;
                if (value.local_file_order != null and prior.local_file_order == value.local_file_order) return error.InvalidJournal;
            }
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
                    owned.remote_effect_unknown = !isLocalFile(owned.tool_id);
                    owned.local_released = false;
                    owned.revision = identity.advance(owned.revision) catch |err| {
                        owned.deinit(a);
                        return err;
                    };
                    recovered = true;
                },
                else => {},
            }
            if (isLocalFile(owned.tool_id) and owned.local_file_order == null and isLocalFileTerminal(owned.stage)) {
                journal.local_file_last_order = identity.advance(journal.local_file_last_order) catch |err| {
                    owned.deinit(a);
                    return err;
                };
                owned.local_file_order = journal.local_file_last_order;
                recovered = true;
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
        if (isLocalFile(request.tool_id)) {
            var file_count: usize = 0;
            for (self.records.items) |record| {
                if (isLocalFile(record.tool_id)) file_count += 1;
            }
            if (file_count >= max_file_records) return error.LocalFileOperationLimit;
        }
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
    pub fn findLocalFile(self: *Journal, a: std.mem.Allocator, context: host.Context, selector: LocalFileSelector) !?Record {
        try context.validate();
        switch (selector) {
            .request_key => |key| try validateKey(local_file_tool_id, key, "lookup"),
            .operation_ref => |operation| if (!operation.valid()) return error.InvalidIdentity,
        }
        for (self.records.items) |record| {
            if (!isLocalFile(record.tool_id) or !record.context.conversation_id.eql(context.conversation_id) or
                !record.context.task_id.eql(context.task_id)) continue;
            const matches = switch (selector) {
                .request_key => |key| std.mem.eql(u8, record.request_key, key),
                .operation_ref => |operation| record.operation_ref.eql(operation),
            };
            if (matches) return try record.clone(a);
        }
        return null;
    }
    pub fn findScopedLocalFile(self: *Journal, a: std.mem.Allocator, scopes: []const LocalFileScope, operation: identity.HostOperationId) !?Record {
        if (!operation.valid()) return error.InvalidIdentity;
        for (self.records.items) |record| {
            if (isLocalFile(record.tool_id) and record.operation_ref.eql(operation) and includesLocalFile(scopes, record.context))
                return try record.clone(a);
        }
        return null;
    }

    /// Sort completed records by the order in which their terminal receipt
    /// reached the journal. This keeps approval wait order out of file chains.
    pub fn listLocalFiles(self: *Journal, a: std.mem.Allocator, scopes: []const LocalFileScope, offset: usize, limit: usize) !LocalFilePage {
        if (limit == 0 or limit > max_change_page) return error.InvalidArguments;
        var matching: std.ArrayList(usize) = .empty;
        defer matching.deinit(a);
        for (self.records.items, 0..) |record, index| {
            if (record.local_file_order != null and includesLocalFile(scopes, record.context)) try matching.append(a, index);
        }
        const Ordering = struct {
            fn less(records: []const Record, lhs: usize, rhs: usize) bool {
                return records[lhs].local_file_order.? < records[rhs].local_file_order.?;
            }
        };
        std.mem.sort(usize, matching.items, @as([]const Record, self.records.items), Ordering.less);
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        for (matching.items) |index| {
            const record = self.records.items[index];
            digest.update(&record.operation_ref.bytes);
            var revision: [8]u8 = undefined;
            std.mem.writeInt(u64, &revision, record.revision, .little);
            digest.update(&revision);
        }
        if (offset > matching.items.len) return error.SnapshotChanged;
        const end = @min(matching.items.len, offset + limit);
        const rows = try a.alloc(LocalFilePage.Row, end - offset);
        errdefer a.free(rows);
        var initialized: usize = 0;
        errdefer for (rows[0..initialized]) |*row| row.record.deinit(a);
        var predecessors: std.StringHashMapUnmanaged(usize) = .empty;
        defer predecessors.deinit(a);
        for (matching.items[0..end], 0..) |index, position| {
            const record = self.records.items[index];
            const target = if (record.local_file_evidence) |evidence| evidence.target else null;
            const affects_file = if (record.local_file_result) |result| result.committed or result.status == .unknown else record.dispatch_started;
            const previous = if (target != null and affects_file) predecessors.get(target.?) else null;
            if (target != null and affects_file) try predecessors.put(a, target.?, index);
            if (position < offset) continue;
            rows[initialized] = .{ .record = try record.clone(a) };
            if (previous) |old_index| {
                const old = self.records.items[old_index];
                const row = &rows[initialized];
                row.previous_operation = old.operation_ref;
                row.version_chain = versionChain(old, record);
            }
            initialized += 1;
        }
        return .{ .rows = rows, .snapshot = digest.finalResult(), .next_offset = if (end < matching.items.len) end else null };
    }

    /// Delete recovery materials only after the exact conversation's history
    /// is released. Keep immutable evidence and keys, including on expiry.
    pub fn expireLocalFiles(self: *Journal, conversation: identity.ConversationId) !LocalFileExpiry {
        if (!conversation.valid()) return error.InvalidIdentity;
        var receipt: LocalFileExpiry = .{};
        var next: ?[]Record = null;
        defer if (next) |records| self.allocator.free(records);
        for (self.records.items, 0..) |record, index| {
            if (!record.context.conversation_id.eql(conversation) or record.local_file_material_expired == true) continue;
            const evidence = record.local_file_evidence orelse continue;
            const layout = recoveryExpiryLayout(record) orelse {
                receipt.pending += 1;
                continue;
            };
            if (next == null) next = try self.allocator.dupe(Record, self.records.items);
            const revision = try identity.advance(record.revision);
            (switch (layout) {
                .verified => file_commit.expireRecovery(self.io, evidence),
                .rejected => file_commit.expireRejectedRecovery(self.io, evidence),
            }) catch {
                receipt.failed += 1;
                continue;
            };
            next.?[index].local_file_material_expired = true;
            next.?[index].revision = revision;
            receipt.expired += 1;
        }
        if (receipt.expired != 0) {
            try self.persist(next.?);
            @memcpy(self.records.items, next.?);
        }
        return receipt;
    }

    fn get(self: *Journal, handle: Handle) !Record {
        if (handle.index >= self.records.items.len or !self.records.items[handle.index].operation_ref.eql(handle.operation_ref)) return error.StaleOperation;
        return self.records.items[handle.index];
    }
    pub fn update(self: *Journal, handle: Handle, expected_revision: u64, change: Update) !void {
        var record = try self.get(handle);
        if (record.revision != expected_revision) return error.JournalRevisionChanged;
        if (isLocalFile(record.tool_id)) {
            if (!localTransitionAllowed(record, change)) return error.InvalidJournalTransition;
        } else if (!transitionAllowed(record.stage, change.stage)) return error.InvalidJournalTransition;
        record.revision = try identity.advance(record.revision);
        record.stage = change.stage;
        if (change.verification) |anchor| {
            if (record.verification) |prior| if (!std.meta.eql(prior, anchor)) return error.ResourceIdentityChanged;
            record.verification = anchor;
        }
        record.dispatch_started = record.dispatch_started or change.stage == .dispatch_started;
        if (change.created_group) |value| {
            if (record.created_group != null and record.created_group.? != value) return error.ResourceIdentityChanged;
            record.created_group = value;
        }
        if (change.created_session) |value| {
            if (record.created_session) |prior| if (!prior.eql(value)) return error.ResourceIdentityChanged;
            record.created_session = value;
        }
        if (change.created_asset) |value| {
            if (record.created_asset) |prior| if (!std.meta.eql(prior, value)) return error.ResourceIdentityChanged;
            record.created_asset = value;
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
        if (change.local_file_evidence) |evidence| {
            var available: usize = max_recovery_bytes;
            for (self.records.items) |prior| {
                if (prior.local_file_material_expired == true) continue;
                if (prior.local_file_evidence) |value| available -|= value.reserved_bytes;
            }
            if (evidence.reserved_bytes > available) return error.RecoveryQuotaExceeded;
            record.local_file_evidence = evidence;
        }
        if (change.local_file_result) |result| record.local_file_result = result;
        if (change.local_file_parent_progress) |count| record.local_file_parent_progress = count;
        if (isLocalFile(record.tool_id) and isLocalFileTerminal(record.stage)) record.local_file_order = try identity.advance(self.local_file_last_order);
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
        var owned_evidence: ?file_commit.Evidence = null;
        if (change.local_file_evidence) |evidence| {
            owned_evidence = try cloneFileEvidence(self.allocator, evidence);
            record.local_file_evidence = owned_evidence;
        }
        errdefer if (owned_evidence) |evidence| freeFileEvidence(self.allocator, evidence);
        var owned_file_result: ?LocalFileResult = null;
        if (change.local_file_result) |result| {
            owned_file_result = try cloneFileResult(self.allocator, result);
            record.local_file_result = owned_file_result;
        }
        errdefer if (owned_file_result) |result| freeFileResult(self.allocator, result);
        const next = try self.allocator.dupe(Record, self.records.items);
        defer self.allocator.free(next);
        next[handle.index] = record;
        try self.persist(next);
        if (change.execution_receipt != null) if (self.records.items[handle.index].execution_receipt) |prior| if (prior.output_attribution_reason) |reason| self.allocator.free(reason);
        if (owned_file_result != null) if (self.records.items[handle.index].local_file_result) |prior| freeFileResult(self.allocator, prior);
        self.records.items[handle.index] = record;
        if (record.local_file_order) |order| self.local_file_last_order = @max(self.local_file_last_order, order);
    }
    fn persist(self: *Journal, records: []const Record) !void {
        const current = self.dir.readFileAlloc(self.io, self.path, self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (current) |value| self.allocator.free(value);
        const current_hash = if (current) |value| @as(?Digest, hash(value)) else null;
        if (!std.meta.eql(current_hash, self.disk_hash)) return error.JournalConflict;
        const extended = for (records) |record| {
            if (record.context.child_origin != null) break true;
        } else false;
        const has_file_record = for (records) |record| {
            if (isLocalFile(record.tool_id)) break true;
        } else false;
        const schema_version: u32 = if (has_file_record) 3 else if (extended) 2 else 1;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, Disk{ .schema_version = schema_version, .records = records }, .{});
        defer self.allocator.free(encoded);
        var atomic = try self.dir.createFileAtomic(self.io, self.path, .{ .permissions = @fromBackingInt(0o600), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, encoded);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        if (has_file_record) {
            // A successful dispatch callback must survive loss of the process
            // or the rename of a journal generation could be lost on reboot.
            const parent = try atomic.dir.openDir(self.io, ".", .{});
            defer parent.close(self.io);
            try file_commit.syncDir(parent);
        }
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
    if (record.verification) |anchor| {
        if (!anchor.matches(record.original_turn, record.original_call, anchor.arguments_hash) or anchor.context == null or !anchor.context.?.eql(record.context) or anchor.execution_id == null or record.execution == null or !anchor.execution_id.?.eql(record.execution.?)) return error.InvalidJournal;
        const source = anchor.service.origin_session orelse switch (anchor.service.resource_owner) {
            .session => |handle| handle,
            else => return error.InvalidJournal,
        };
        if (!source.eql(anchor.owner) or anchor.owner.generation == 0 or anchor.service.binding_generation == 0) return error.InvalidJournal;
    }
    if (record.execution_receipt) |receipt| {
        const execution_id = record.execution orelse return error.InvalidExecutionReceipt;
        if (!execution_id.eql(receipt.execution_id)) return error.InvalidExecutionReceipt;
        try receipt.validate();
    }
    if (record.created_group) |value| if (value == 0) return error.InvalidJournal;
    if (record.created_session) |value| if (@backingInt(value.session_id) == 0 or value.generation == 0) return error.InvalidJournal;
    if (record.created_asset) |value| if (@backingInt(value.id) == 0 or value.revision == 0) return error.InvalidJournal;
    if (record.ownership != .borrowed_user and record.created_session == null) return error.InvalidJournal;
    try validateLocalFileRecord(record);
}

fn isLocalFile(tool: []const u8) bool {
    return std.mem.eql(u8, tool, local_file_tool_id);
}

fn cloneFileEvidence(a: std.mem.Allocator, value: file_commit.Evidence) !file_commit.Evidence {
    var out = value;
    out.target = try a.dupe(u8, value.target);
    errdefer a.free(out.target);
    out.request_path = try a.dupe(u8, value.request_path);
    errdefer a.free(out.request_path);
    if (value.base_directory) |base| out.base_directory = try a.dupe(u8, base);
    return out;
}

fn freeFileEvidence(a: std.mem.Allocator, value: file_commit.Evidence) void {
    a.free(value.target);
    a.free(value.request_path);
    if (value.base_directory) |base| a.free(base);
}

fn cloneFileResult(a: std.mem.Allocator, value: LocalFileResult) !LocalFileResult {
    var out = value;
    out.reason = if (value.reason) |reason| try a.dupe(u8, reason) else null;
    errdefer if (out.reason) |reason| a.free(reason);
    out.target = if (value.target) |target| try a.dupe(u8, target) else null;
    return out;
}

fn freeFileResult(a: std.mem.Allocator, value: LocalFileResult) void {
    if (value.reason) |reason| a.free(reason);
    if (value.target) |target| a.free(target);
}

fn validFilePath(text: []const u8) bool {
    return text.len != 0 and text.len < std.Io.Dir.max_path_bytes and
        std.unicode.utf8ValidateSlice(text) and std.mem.indexOfScalar(u8, text, 0) == null;
}

fn recoveryExpiryLayout(record: Record) ?enum { verified, rejected } {
    const result = record.local_file_result orelse return null;
    return switch (result.status) {
        .verified => if (record.stage == .succeeded) .verified else null,
        // Dispatch intent may already have been recorded when the final
        // authorization or version check rejects a write.
        .rejected => if ((record.stage == .rejected or record.stage == .failed) and
            record.local_released and !record.remote_effect_unknown and
            !result.side_effect_started and result.created_parent_count == 0 and
            record.local_file_parent_progress == null) .rejected else null,
        else => null,
    };
}

fn validateLocalFileRecord(record: Record) !void {
    if (!isLocalFile(record.tool_id)) {
        if (record.local_file_evidence != null or record.local_file_result != null or record.local_file_parent_progress != null or
            record.local_file_order != null or record.local_file_material_expired != null) return error.InvalidJournal;
        return;
    }
    if (record.stage == .committed or record.stage == .running or record.stage == .cleanup_pending or
        record.execution != null or record.created_session != null or record.created_group != null or
        record.created_asset != null or record.committed_binding != null or record.notice_revision != 0)
        return error.InvalidJournal;
    if (record.local_file_order) |order| {
        if (order == 0 or !isLocalFileTerminal(record.stage)) return error.InvalidJournal;
    }
    if (record.local_file_material_expired != null and
        (record.local_file_material_expired != true or record.local_file_evidence == null or
            recoveryExpiryLayout(record) == null)) return error.InvalidJournal;
    const evidence = record.local_file_evidence;
    const planned_parents = if (evidence) |prepared| if (prepared.parent_chain) |chain| chain.plan.count else 0 else 0;
    if (record.local_file_parent_progress) |count| {
        if (count == 0 or count > planned_parents or !record.dispatch_started) return error.InvalidJournal;
    }
    if (record.dispatch_started and evidence == null) return error.InvalidJournal;
    if (evidence) |value| {
        if (!value.operation_ref.eql(record.operation_ref) or
            !validFilePath(value.target) or !std.fs.path.isAbsolute(value.target) or
            !validFilePath(value.request_path) or
            !std.mem.eql(u8, &file_commit.stageName(value.operation_ref), &value.recovery.stage_name) or
            value.reserved_bytes == 0 or value.reserved_bytes > max_recovery_bytes)
            return error.InvalidJournal;
        if (value.base_directory) |base| {
            if (!validFilePath(base) or !std.fs.path.isAbsolute(base)) return error.InvalidJournal;
        }
        if ((value.kind == .create) != (value.approved_version == null) or
            (value.source == .workspace) != (value.workspace_revision != null))
            return error.InvalidJournal;
        if (value.workspace_revision) |revision| if (revision == 0) return error.InvalidJournal;
        if (value.approved_version) |token| try file_reads.validateVersion(&token);
        try file_reads.validateVersion(&value.candidate_version);
        if (value.parent_chain) |chain| {
            if (value.kind != .create or chain.plan.count == 0) return error.InvalidJournal;
            try chain.validate(value.target, value.recovery.parent_identity.device);
        }
    }
    if (record.local_file_result) |result| {
        if (result.target) |target| {
            if (result.status != .rejected or !validFilePath(target) or !std.fs.path.isAbsolute(target)) return error.InvalidJournal;
            if (evidence) |prepared| if (!std.mem.eql(u8, prepared.target, target)) return error.InvalidJournal;
        }
        if (result.reason) |reason| {
            if (reason.len == 0 or reason.len > 96) return error.InvalidJournal;
            for (reason) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidJournal;
        }
        const progressed = record.local_file_parent_progress orelse 0;
        if (result.created_parent_count > planned_parents or result.created_parent_count < progressed or
            result.created_parent_count > progressed +| 1 or
            (result.created_parent_count > progressed and result.status != .unknown and result.status != .partial) or
            (result.committed and result.created_parent_count != planned_parents))
            return error.InvalidJournal;
        if (result.side_effect_started and !record.dispatch_started or
            result.committed and !result.side_effect_started or
            (result.verified and (!result.committed or result.conflict)) or
            (result.conflict and !result.committed) or
            (result.diff_ref != null and !result.committed))
            return error.InvalidJournal;
        if (result.actual_before_version) |token| try file_reads.validateVersion(&token);
        if (result.submitted_after_version) |token| {
            const prepared = evidence orelse return error.InvalidJournal;
            if (!std.mem.eql(u8, &token, &prepared.candidate_version)) return error.InvalidJournal;
        }
        const correct_stage = switch (result.status) {
            .rejected => !result.side_effect_started and (record.stage == .rejected or record.stage == .failed),
            .verified => result.verified and record.stage == .succeeded,
            .committed_unverified => result.committed and !result.verified and record.stage == .failed,
            .unknown => result.side_effect_started and record.stage == .outcome_unknown,
            .partial => result.side_effect_started and result.created_parent_count != 0 and !result.committed and record.stage == .failed,
        };
        if (!correct_stage) return error.InvalidJournal;
    } else if (record.stage == .succeeded or record.stage == .failed or record.stage == .rejected) {
        return error.InvalidJournal;
    }
}

fn includesLocalFile(scopes: []const LocalFileScope, context: host.Context) bool {
    for (scopes) |item| if (item.matches(context)) return true;
    return false;
}

fn versionChain(prior: Record, current: Record) @FieldType(LocalFilePage.Row, "version_chain") {
    const before = prior.local_file_result orelse return .unproven;
    const after = current.local_file_result orelse return .unproven;
    if (!before.committed or !after.committed) return .unproven;
    const old_version = before.submitted_after_version orelse return .unproven;
    if (after.actual_before_version) |version| {
        return if (std.mem.eql(u8, &old_version, &version)) .continuous else .discontinuity;
    }
    return if (current.local_file_evidence.?.kind == .create) .discontinuity else .unproven;
}

fn isLocalFileTerminal(stage: Stage) bool {
    return switch (stage) {
        .succeeded, .failed, .rejected, .cancelled_unsent, .outcome_unknown => true,
        else => false,
    };
}

fn localTransitionAllowed(record: Record, change: Update) bool {
    if (change.local_file_parent_progress) |count| {
        const chain = (record.local_file_evidence orelse return false).parent_chain orelse return false;
        return record.stage == .dispatch_started and change.stage == .dispatch_started and
            change.local_file_evidence == null and change.local_file_result == null and
            count == (record.local_file_parent_progress orelse 0) + 1 and count <= chain.plan.count;
    }
    return switch (record.stage) {
        .prepared => switch (change.stage) {
            .prepared => record.local_file_evidence == null and change.local_file_evidence != null and change.local_file_result == null,
            .dispatch_started => record.local_file_evidence != null and change.local_file_evidence == null and change.local_file_result == null,
            .rejected => change.local_file_evidence == null and change.local_file_result != null,
            else => false,
        },
        .dispatch_started => (change.stage == .succeeded or change.stage == .failed or change.stage == .outcome_unknown) and
            change.local_file_evidence == null and change.local_file_result != null,
        else => false,
    };
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
