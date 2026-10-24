//! Engine/Manager conflict wire values. No IO and no UI nodes. A Context uses
//! existing domain identities; Manager supplies its actual JobId and attempt.
const std = @import("std");
const domain = @import("conflict.zig");
const identity = @import("../host/identity.zig");

pub const Context = struct {
    intent_id: u64,
    job: u64 = 0,
    attempt: u32 = 0,
    original_owner: identity.SessionHandle,
    resource_owner: identity.ResourceOwner,
    source_endpoint: domain.Endpoint,
    target_endpoint: domain.Endpoint,
};

pub const Request = union(enum) {
    select: struct { key: domain.Key, selection: domain.Selection },
    confirm_overwrite: struct { key: domain.Key, ticket: domain.ConfirmationTicket },
    return_to_choice: struct { key: domain.Key, ticket: domain.ConfirmationTicket },

    pub fn key(self: Request) domain.Key {
        return switch (self) {
            inline else => |value| value.key,
        };
    }
};

pub const Snapshot = struct {
    engine_job: u64,
    context: ?Context,
    /// Legacy direct-engine users have no invented Session/Endpoint identity.
    /// They still stop before an existing target, but cannot authorize it.
    pending: union(enum) {
        context_required: struct {
            entry: u32,
            revision: u64,
            source_path: []const u8,
            target_path: []const u8,
            source_metadata: domain.Metadata,
            target: domain.Observation,
        },
        choice: domain.Prompt,
        overwrite_confirmation: domain.Confirmation,
    },
    issue: ?enum { invalid_name, invalid_decision, permission_denied, io, unsupported } = null,
};

/// Caller-owned deep snapshot. It remains valid across worker progress,
/// decisions, cancellation, resume and engine teardown until deinit().
pub const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    value: Snapshot,

    pub fn clone(allocator: std.mem.Allocator, source: Snapshot) !OwnedSnapshot {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var result = source;
        switch (source.pending) {
            .context_required => |entry| {
                var copy = entry;
                copy.source_path = try a.dupe(u8, entry.source_path);
                copy.target_path = try a.dupe(u8, entry.target_path);
                result.pending = .{ .context_required = copy };
            },
            .choice => |prompt| {
                var copy = prompt;
                copy.source_path = try a.dupe(u8, prompt.source_path);
                copy.target_path = try a.dupe(u8, prompt.target_path);
                copy.selection.rename = try a.dupe(u8, prompt.selection.rename);
                if (prompt.suggested_path) |path| copy.suggested_path = try a.dupe(u8, path);
                result.pending = .{ .choice = copy };
            },
            .overwrite_confirmation => |confirmation| {
                var copy = confirmation;
                const targets = try a.dupe(domain.OverwriteTarget, confirmation.targets);
                for (targets) |*target| target.path = try a.dupe(u8, target.path);
                copy.targets = targets;
                result.pending = .{ .overwrite_confirmation = copy };
            },
        }
        return .{ .arena = arena, .value = result };
    }

    pub fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
