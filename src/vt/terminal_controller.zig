//! Worker-side terminal projection shared by Local and SSH transports.
//! The adapter remains the sole transport reader and input executor. It feeds
//! each output batch here once, then publishes status through its own mailbox.
const std = @import("std");
const identity = @import("../host/identity.zig");
const Geometry = @import("../host/terminal_service.zig").Geometry;
const VtEngine = @import("engine.zig").VtEngine;
const FeedBridge = @import("feed_bridge.zig").FeedBridge;
const TextSlot = @import("text_slot.zig").TextSlot;
const DirtySlot = @import("dirty_slot.zig").DirtySlot;
const viewport = @import("viewport.zig");

pub const Config = struct {
    owner: identity.SessionHandle,
    engine: VtEngine,
    text_slot: *TextSlot,
    dirty_slot: ?*DirtySlot = null,
    geometry_revision: u64 = 1,
};

/// This is a worker-local status value, not a borrowed UI snapshot. The text
/// frame crosses threads exclusively through the existing SPSC TextSlot.
pub const Status = struct {
    owner: identity.SessionHandle,
    output_sequence: u64,
    bell_count: u64 = 0,
    geometry: Geometry,
    eof_seen: bool,
    publication_pending: bool,
};

pub const Controller = struct {
    owner: identity.SessionHandle,
    feed: FeedBridge,
    output_sequence: u64 = 0,
    geometry: Geometry,
    eof_seen: bool = false,
    theme: ?@import("theme.zig").Theme = null,

    /// Engine and slots remain owned by the adapter. They must outlive this
    /// controller and its single text-slot consumer; no second VT is created.
    pub fn init(config: Config) !Controller {
        if (@backingInt(config.owner.session_id) == 0 or config.owner.generation == 0) return error.InvalidOwner;
        const snapshot = config.engine.snapshot();
        if (config.geometry_revision == 0 or snapshot.cols == 0 or snapshot.rows == 0) return error.InvalidGeometry;
        return .{
            .owner = config.owner,
            .feed = .{ .engine = config.engine, .text_slot = config.text_slot, .dirty_slot = config.dirty_slot },
            .geometry = .{ .revision = config.geometry_revision, .cols = snapshot.cols, .rows = snapshot.rows },
        };
    }

    /// Output must be contiguous for this owner. A rejected duplicate/stale
    /// batch never reaches the parser. Display backpressure may coalesce frames
    /// but never defers, repeats, or discards the actual VT feed.
    pub fn feedOutput(self: *Controller, owner: identity.SessionHandle, output_sequence: u64, bytes: []const u8, now_ms: i64) !void {
        try self.requireOwner(owner);
        if (self.eof_seen) return error.OutputAfterEof;
        if (self.output_sequence == std.math.maxInt(u64)) return error.OutputSequenceExhausted;
        if (output_sequence != self.output_sequence + 1 or bytes.len == 0) return error.InvalidOutputSequence;
        _ = try self.feed.feedAndPublish(bytes, now_ms);
        self.output_sequence = output_sequence;
    }

    /// Called only after the transport accepted this exact geometry. A failed
    /// transport resize must not change the VT grid or its applied revision.
    pub fn resizeApplied(self: *Controller, owner: identity.SessionHandle, geometry: Geometry, now_ms: i64) !void {
        try self.requireOwner(owner);
        if (geometry.revision == 0 or geometry.cols == 0 or geometry.rows == 0) return error.InvalidGeometry;
        if (geometry.revision <= self.geometry.revision) return error.StaleGeometry;
        try self.feed.engine.resize(geometry.cols, geometry.rows);
        self.geometry = geometry;
        self.feed.publishCurrentText(now_ms);
    }

    /// EOF is independent from process exit/reaping. Retain the entire VT and
    /// keep retrying a pending final publication until the consumer catches up.
    pub fn eof(self: *Controller, owner: identity.SessionHandle) !void {
        try self.requireOwner(owner);
        self.eof_seen = true;
    }

    pub fn retryPublication(self: *Controller, now_ms: i64) void {
        if (self.feed.republish_pending) self.feed.publishCurrentText(now_ms);
    }

    pub fn publicationPending(self: *const Controller) bool {
        return self.feed.republish_pending;
    }

    /// Exposes the existing handoff, never a worker-owned engine or cell slice.
    /// The adapter must preserve one UI consumer for this slot.
    pub fn textSlot(self: *Controller) *TextSlot {
        return self.feed.text_slot.?;
    }

    pub fn status(self: *const Controller) Status {
        return .{
            .owner = self.owner,
            .output_sequence = self.output_sequence,
            .bell_count = self.feed.engine.snapshot().bell_count,
            .geometry = self.geometry,
            .eof_seen = self.eof_seen,
            .publication_pending = self.publicationPending(),
        };
    }

    pub fn copyProjection(self: *Controller, owner: identity.SessionHandle, allocator: std.mem.Allocator) !@import("engine.zig").Projection {
        try self.requireOwner(owner);
        const scalar = self.feed.engine.snapshot();
        if (scalar.cols != self.geometry.cols or scalar.rows != self.geometry.rows) return error.GeometryPending;
        return self.feed.engine.copyProjection(allocator);
    }

    pub fn readReply(self: *Controller, owner: identity.SessionHandle, buffer: []u8) !usize {
        try self.requireOwner(owner);
        return self.feed.engine.readReply(buffer);
    }
    /// Pure encoding may be called by the adapter while it holds the same
    /// serialization guard as feedOutput. The transport is still worker-only.
    pub fn encodeKey(self: *Controller, owner: identity.SessionHandle, mode_revision: u64, event: @import("engine.zig").KeyEvent, allocator: std.mem.Allocator) ![]u8 {
        try self.requireOwner(owner);
        if (mode_revision != self.feed.engine.snapshot().mode_revision) return error.StaleMode;
        return self.feed.engine.encodeKey(event, allocator);
    }
    pub fn encodeMouse(self: *Controller, owner: identity.SessionHandle, mode_revision: u64, geometry_revision: u64, event: @import("engine.zig").MouseEvent, allocator: std.mem.Allocator) ![]u8 {
        try self.requireOwner(owner);
        if (mode_revision != self.feed.engine.snapshot().mode_revision) return error.StaleMode;
        if (geometry_revision != self.geometry.revision) return error.StaleGeometry;
        return self.feed.engine.encodeMouse(event, allocator);
    }
    pub fn createAnchor(self: *Controller, owner: identity.SessionHandle, point: viewport.Point) !viewport.OwnedAnchor {
        try self.requireOwner(owner);
        if (point.source_version) |version| if (version != self.feed.engine.snapshot().version) return error.StaleProjection;
        return .{ .owner = owner, .id = try self.feed.engine.createAnchor(point) };
    }
    pub fn resolveAnchor(self: *Controller, anchor: viewport.OwnedAnchor) !?viewport.AnchorPosition {
        try self.requireOwner(anchor.owner);
        var position = (try self.feed.engine.resolveAnchor(anchor.id)) orelse return null;
        position.source_version = self.feed.engine.snapshot().version;
        return position;
    }
    pub fn releaseAnchor(self: *Controller, anchor: viewport.OwnedAnchor) !void {
        try self.requireOwner(anchor.owner);
        return self.feed.engine.releaseAnchor(anchor.id);
    }
    pub fn selectionText(self: *Controller, selected: viewport.OwnedSelection, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        try self.requireOwner(selected.start.owner);
        try self.requireOwner(selected.end.owner);
        return self.feed.engine.selectionFromAnchors(.{ .start = selected.start.id, .end = selected.end.id, .rectangle = selected.rectangle }, allocator, max_bytes);
    }
    pub fn scroll(self: *Controller, owner: identity.SessionHandle, request: viewport.OwnedScroll, now_ms: i64) !void {
        try self.requireOwner(owner);
        const native: viewport.Scroll = switch (request) {
            .top => .top,
            .bottom => .bottom,
            .delta => |value| .{ .delta = value },
            .anchor => |anchor| value: {
                try self.requireOwner(anchor.owner);
                break :value .{ .anchor = anchor.id };
            },
        };
        try self.feed.engine.scroll(native);
        self.feed.publishCurrentText(now_ms);
    }
    pub fn readLines(self: *Controller, owner: identity.SessionHandle, limits: viewport.LineLimits, allocator: std.mem.Allocator) !viewport.Lines {
        try self.requireOwner(owner);
        return self.feed.engine.readLines(limits, allocator);
    }
    pub fn searchSnapshot(self: *Controller, owner: identity.SessionHandle, allocator: std.mem.Allocator) !@import("search_snapshot.zig").Document {
        try self.requireOwner(owner);
        return self.feed.engine.searchSnapshot(allocator);
    }
    pub fn recordSubmission(self: *Controller, owner: identity.SessionHandle) !void {
        try self.requireOwner(owner);
        self.feed.engine.recordSubmission();
    }
    pub fn setTheme(self: *Controller, owner: identity.SessionHandle, theme: @import("theme.zig").Theme, now_ms: i64) !void {
        try self.requireOwner(owner);
        if (theme.revision == 0) return error.InvalidTheme;
        if (self.theme) |current| {
            if (theme.revision < current.revision) return error.StaleTheme;
            if (theme.revision == current.revision) {
                if (!std.meta.eql(theme, current)) return error.ConflictingTheme;
                return;
            }
        }
        try self.feed.engine.setTheme(theme);
        self.theme = theme;
        self.feed.publishCurrentText(now_ms);
    }

    fn requireOwner(self: *const Controller, owner: identity.SessionHandle) !void {
        if (!self.owner.eql(owner)) return error.StaleOwner;
    }
};
