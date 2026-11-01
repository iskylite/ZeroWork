//! Asynchronous, read-only editor probes. No presentation, input or management
//! write facade is present in this context.
const std = @import("std");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
const envelopes = @import("../config/connection_envelope.zig");
const contexts = @import("host_context.zig");

pub const api_id = "host.probes";
pub const api_major: u32 = 1;
pub const CloseReceipt = enum { released, awaiting, unknown };

pub const ProbeToken = struct {
    handle: identity.SessionHandle,
    operation: operations.OperationKey,
    parent_editor_operation: operations.OperationKey,
    draft_revision: u64,

    pub fn eql(self: ProbeToken, other: ProbeToken) bool {
        return std.meta.eql(self, other);
    }
};

pub const ProbeContext = struct {
    owner: identity.SessionHandle,
    operation: operations.OperationKey,
    connection_configs: ?@import("connection_config_resolver.zig").Resolver = null,
    transports: ?@import("transport_factory.zig").Factory = null,
    credentials: ?@import("transport_factory.zig").Credentials = null,
    trust: contexts.Trust = .{},
    secrets: ?@import("secret_lease.zig").Facade = null,
    challenges: ?*@import("challenge_host.zig").Host = null,
    cancel: *const std.atomic.Value(bool),

    pub fn cancelled(self: ProbeContext) bool {
        return self.cancel.load(.acquire);
    }
    pub fn requireOwner(self: ProbeContext, owner: identity.SessionHandle, operation: operations.OperationKey) !void {
        if (!self.owner.eql(owner) or !self.operation.eql(operation)) return error.StaleProbeContext;
    }
};
pub const ContextFactory = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, ProbeToken, *const std.atomic.Value(bool)) anyerror!ProbeContext,
};
pub const ProbeRequest = struct {
    token: ProbeToken,
    handle: identity.SessionHandle,
    operation: operations.OperationKey,
    parent_editor_operation: operations.OperationKey,
    draft_revision: u64,
    envelope: envelopes.Envelope,
    restricted_context: ProbeContext,
};
pub const Stage = enum { accepted, transport, trust, authentication, discovery, cleanup, finished };
pub const Outcome = enum { succeeded, failed, cancelled };
pub const ProbeUpdate = union(enum) {
    progress: struct { stage: Stage, safe_message: []const u8 = "" },
    result: struct { outcome: Outcome, safe_message: []const u8 = "", cleanup: CloseReceipt },
    cleanup: CloseReceipt,
};
pub const ProbeFactory = struct {
    context: *anyopaque,
    /// Submit work only. Completion is observed by poll at a host safe point.
    /// Throwing means no resources were acquired.
    begin: *const fn (*anyopaque, ProbeRequest) anyerror!void,
    /// Nonblocking; returned strings remain borrowed until this call returns.
    /// The host copies them before the next provider call.
    poll: *const fn (*anyopaque, operations.OperationKey) anyerror!?ProbeUpdate,
    cancel: *const fn (*anyopaque, operations.OperationKey) CloseReceipt,
};
pub const ProbeSnapshot = struct {
    token: ProbeToken,
    stage: Stage,
    outcome: ?Outcome,
    cleanup: CloseReceipt,
    safe_message: []const u8,
    /// Old drafts and destroyed editors remain diagnostic only.
    applies_to_draft: bool,
    /// An outcome is publishable only after all child resources released.
    complete: bool,
};
pub const OwnedProbeSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    value: ProbeSnapshot,
    pub fn init(allocator: std.mem.Allocator, value: ProbeSnapshot) !OwnedProbeSnapshot {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var copy = value;
        copy.safe_message = try arena.allocator().dupe(u8, value.safe_message);
        return .{ .arena = arena, .value = copy };
    }
    pub fn deinit(self: *OwnedProbeSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Bound to one editor operation. Its token cannot address another editor.
pub const EditorTicket = enum(u64) { _ };
pub const EditorProbes = struct {
    context: *anyopaque,
    /// Host-issued identity, independent of the caller's reusable editor ID.
    /// The context is the host, so recycling an editor cannot dangle a facade.
    ticket: EditorTicket,
    editor_id: u64,
    parent_editor_operation: operations.OperationKey,
    begin_fn: *const fn (*anyopaque, EditorTicket, envelopes.Envelope, u64) anyerror!ProbeToken,
    snapshot_fn: *const fn (*anyopaque, EditorTicket, ProbeToken, std.mem.Allocator) anyerror!OwnedProbeSnapshot,
    cancel_fn: *const fn (*anyopaque, EditorTicket, ProbeToken) anyerror!CloseReceipt,
    revision_fn: *const fn (*anyopaque, EditorTicket, u64) anyerror!void,
    destroy_fn: *const fn (*anyopaque, EditorTicket) void,

    pub fn begin(self: EditorProbes, envelope: envelopes.Envelope, draft_revision: u64) !ProbeToken {
        return self.begin_fn(self.context, self.ticket, envelope, draft_revision);
    }
    pub fn snapshot(self: EditorProbes, token: ProbeToken, allocator: std.mem.Allocator) !OwnedProbeSnapshot {
        if (!token.parent_editor_operation.eql(self.parent_editor_operation)) return error.ProbeOwnerMismatch;
        return self.snapshot_fn(self.context, self.ticket, token, allocator);
    }
    pub fn cancel(self: EditorProbes, token: ProbeToken) !CloseReceipt {
        if (!token.parent_editor_operation.eql(self.parent_editor_operation)) return error.ProbeOwnerMismatch;
        return self.cancel_fn(self.context, self.ticket, token);
    }
    pub fn setDraftRevision(self: EditorProbes, revision: u64) !void {
        return self.revision_fn(self.context, self.ticket, revision);
    }
    pub fn destroy(self: EditorProbes) void {
        self.destroy_fn(self.context, self.ticket);
    }
};
