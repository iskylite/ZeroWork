//! Shared lifecycle-journal ownership for host and terminal Local writes.
//! Callers must check their live authority before claims, receipt access and
//! commit. This adapter never resolves a path or retries an effect.
const std = @import("std");
const journal = @import("lifecycle_journal.zig");
const ProcessJournal = @import("lifecycle_runtime.zig").ProcessJournal;
const HostContext = @import("host_tools.zig").Context;
const OperationId = @import("../host/identity.zig").HostOperationId;
const commit = @import("../host/local_file_commit.zig");

pub const Request = struct {
    context: HostContext,
    request_key: []const u8,
    canonical_hash: commit.Digest,
    turn_id: u64,
    call_id: []const u8,
};

/// Normalize only arguments from the original request. Store the resolved
/// path and workspace dependency separately as evidence on the same record.
pub fn canonicalHash(a: std.mem.Allocator, target: union(enum) {
    path: []const u8,
    file_ref: []const u8,
}, base_directory: ?[]const u8, request: commit.Request) !commit.Digest {
    const encoded = try std.json.Stringify.valueAlloc(a, .{
        .target_kind = @tagName(target),
        .target = switch (target) {
            .path, .file_ref => |value| value,
        },
        .base_directory = base_directory,
        .request = request,
    }, .{});
    defer a.free(encoded);
    var out: commit.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &out, .{});
    return out;
}

pub const Transaction = struct {
    owner: *ProcessJournal,
    handle: journal.Handle,
    revision: u64 = 1,
    stage: journal.Stage = .prepared,
    prepared: bool = false,

    /// Use the same tool family for both entrances and claim before resolving
    /// against a mutable workspace. A reused key has no write path.
    pub fn claim(owner: *ProcessJournal, request: Request) !Transaction {
        const handle = try owner.begin(.{
            .context = request.context,
            .tool_id = journal.local_file_tool_id,
            .request_key = request.request_key,
            .canonical_hash = request.canonical_hash,
            .turn_id = request.turn_id,
            .call_id = request.call_id,
        });
        return .{ .owner = owner, .handle = handle };
    }

    pub fn snapshot(self: *Transaction, a: std.mem.Allocator) !journal.Record {
        return self.owner.snapshot(a, self.handle);
    }

    pub fn callbacks(self: *Transaction) !commit.Journal {
        if (self.handle.reused or self.prepared or self.stage != .prepared) return error.LocalFileOperationAlreadyClaimed;
        return .{ .context = self, .prepare = prepare, .dispatch = dispatch, .finish = finish, .progress = progress };
    }

    /// Close a preflight/approval failure where no staged commit was dispatched.
    pub fn reject(self: *Transaction, reason: anyerror) !void {
        return self.rejectAt(reason, null);
    }

    pub fn rejectAt(self: *Transaction, reason: anyerror, target: ?[]const u8) !void {
        if (self.handle.reused or self.stage != .prepared) return error.InvalidJournalTransition;
        try self.publish(.{
            .stage = .rejected,
            .local_file_result = .{ .status = .rejected, .reason = @errorName(reason), .target = target },
        });
    }

    fn publish(self: *Transaction, update: journal.Update) !void {
        const next = try @import("../host/identity.zig").advance(self.revision);
        try self.owner.update(self.handle, self.revision, update);
        self.revision = next;
        self.stage = update.stage;
    }

    fn prepare(raw: *anyopaque, evidence: commit.Evidence) !void {
        const self: *Transaction = @ptrCast(@alignCast(raw));
        if (self.handle.reused or self.prepared or self.stage != .prepared or
            !self.handle.operation_ref.eql(evidence.operation_ref))
            return error.InvalidJournalTransition;
        self.publish(.{ .stage = .prepared, .local_file_evidence = evidence }) catch |err| {
            if (err == error.RecoveryQuotaExceeded) try self.reject(err);
            return err;
        };
        self.prepared = true;
    }

    fn dispatch(raw: *anyopaque, operation: OperationId) !void {
        const self: *Transaction = @ptrCast(@alignCast(raw));
        if (!self.prepared or self.stage != .prepared or !self.handle.operation_ref.eql(operation))
            return error.InvalidJournalTransition;
        try self.publish(.{ .stage = .dispatch_started, .local_released = false });
    }

    fn progress(raw: *anyopaque, operation: OperationId, count: u8) !void {
        const self: *Transaction = @ptrCast(@alignCast(raw));
        if (self.stage != .dispatch_started or !self.handle.operation_ref.eql(operation)) return error.InvalidJournalTransition;
        try self.publish(.{ .stage = .dispatch_started, .local_released = false, .local_file_parent_progress = count });
    }

    fn finish(raw: *anyopaque, receipt: commit.Receipt) !void {
        const self: *Transaction = @ptrCast(@alignCast(raw));
        if (!self.prepared or !self.handle.operation_ref.eql(receipt.operation_ref))
            return error.InvalidJournalTransition;
        const stage: journal.Stage = switch (receipt.status) {
            .rejected => if (self.stage == .prepared) .rejected else .failed,
            .verified => .succeeded,
            .committed_unverified, .partial => .failed,
            .unknown => .outcome_unknown,
        };
        try self.publish(.{
            .stage = stage,
            .local_released = receipt.status != .unknown,
            .local_file_result = .{
                .status = receipt.status,
                .side_effect_started = receipt.side_effect_started,
                .created_parent_count = receipt.created_parent_count,
                .committed = receipt.committed,
                .verified = receipt.verified,
                .conflict = receipt.conflict,
                .actual_before_version = receipt.actual_before_version,
                .submitted_after_version = receipt.submitted_after_version,
                .diff_ref = receipt.diff_ref,
                .reason = if (receipt.reason) |reason| @errorName(reason) else null,
            },
        });
    }
};

pub fn find(owner: *ProcessJournal, a: std.mem.Allocator, context: HostContext, selector: journal.LocalFileSelector) !?journal.Record {
    return owner.findLocalFile(a, context, selector);
}

test {
    _ = @import("local_file_operation_tests.zig");
}
