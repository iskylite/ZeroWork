//! Execution boundaries on the existing SSH Timeline and its one manifest.
//! No second VT, transport, timeline, archive identity or output stream.
const std = @import("std");
const recording = @import("ssh_recording_manifest.zig");
const manifest = @import("recording_manifest.zig");
const execution = manifest.execution;
const identity = @import("../host/identity.zig");
const Timeline = @import("timeline.zig").Timeline;
pub const Recording = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    options: recording.Options,
    arena: std.heap.ArenaAllocator,
    revision: u64 = 1,
    ranges: std.ArrayList(Range) = .empty,
    boundaries: std.ArrayList(Marker) = .empty,
    failure: ?[]const u8 = null,
    committed_path: ?[]u8 = null,
    const Range = struct { id: [32]u8, start: manifest.Position, end: ?manifest.Position = null, start_fence: ?u64 = null, end_fence: ?u64 = null, process: ?execution.ProcessReceipt = null, attribution: execution.OutputAttribution = .unverified, reason: ?[]const u8 = null, saved: bool = false, failure: ?[]const u8 = null, evidence: manifest.Evidence = .pending };
    const Marker = struct { position: manifest.Position, consumed: bool = false };
    pub const Barrier = struct { recording_id: [32]u8, generation: u64, revision: u64 };
    pub const BoundaryReceipt = struct { position: manifest.Position, revision: u64 };
    pub fn init(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: recording.Options) !Recording {
        if (options.timeline == null or options.generations.len != 1 or options.ended_ms != null) return error.InvalidExecutionRecording;
        const path = try manifest.pathForCast(a, options.cast_path);
        defer a.free(path);
        const current = try manifest.load(a, io, dir, path);
        defer current.deinit();
        const id = std.fmt.bytesToHex(options.recording_id.bytes, .lower);
        const key = std.fmt.bytesToHex(options.archive_key.bytes, .lower);
        if (!std.mem.eql(u8, current.value.recording_id, &id) or !std.mem.eql(u8, current.value.archive_key, &key) or current.value.state != .active) return error.RecordingIdentityChanged;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owner = arena.allocator();
        var owned = options;
        owned.cast_path = try owner.dupe(u8, options.cast_path);
        owned.generations = try owner.dupe(manifest.Generation, options.generations);
        owned.display.title = try owner.dupe(u8, options.display.title);
        owned.display.host = try owner.dupe(u8, options.display.host);
        owned.display.user = try owner.dupe(u8, options.display.user);
        owned.display.endpoint = try owner.dupe(u8, options.display.endpoint);
        owned.display.cwd = if (options.display.cwd) |v| try owner.dupe(u8, v) else null;
        owned.display.font_family = if (options.display.font_family) |v| try owner.dupe(u8, v) else null;
        owned.display.theme_reference = null;
        return .{ .allocator = a, .io = io, .dir = dir, .options = owned, .arena = arena, .revision = current.value.manifest_revision };
    }
    pub fn deinit(self: *Recording) void {
        self.arena.deinit();
        self.ranges.deinit(self.allocator);
        self.boundaries.deinit(self.allocator);
        if (self.committed_path) |path| self.allocator.free(path);
    }
    pub fn markBoundary(self: *Recording, raw_offset: u64, now: i64) !manifest.Position {
        if (self.failure != null) return error.RecordingDegraded;
        if (self.boundaries.items.len >= 256) return error.RecordingBoundaryCapacity;
        try self.boundaries.ensureUnusedCapacity(self.allocator, 1);
        const sequence = try self.options.timeline.?.markBoundary(now, raw_offset);
        const position: manifest.Position = .{ .raw_offset = raw_offset, .event_sequence = sequence };
        self.boundaries.appendAssumeCapacity(.{ .position = position });
        return position;
    }
    pub fn startBarrier(self: *Recording, id: identity.ExecutionId, total: u64) !Barrier {
        if (self.failure != null) return error.RecordingDegraded;
        if (self.ranges.items.len >= 128) return error.RecordingExecutionCapacity;
        for (self.ranges.items) |range| if (range.end == null and range.evidence == .pending) return error.OperationBusy;
        var frozen = try self.options.timeline.?.snapshotWithAllocator(self.allocator);
        defer frozen.deinit();
        try self.ranges.append(self.allocator, .{ .id = std.fmt.bytesToHex(id.bytes, .lower), .start = .{ .raw_offset = total, .event_sequence = frozen.next_event_sequence -| 1 } });
        const revision = try self.persist(total, null);
        return .{ .recording_id = std.fmt.bytesToHex(self.options.recording_id.bytes, .lower), .generation = self.options.generations[0].recording_generation, .revision = revision };
    }
    pub fn noteBoundary(self: *Recording, id: identity.ExecutionId, start: bool, boundary: execution.Boundary, total: u64) !BoundaryReceipt {
        const range = try self.find(id);
        var selected: ?*Marker = null;
        for (self.boundaries.items) |*marker| if (!marker.consumed and marker.position.raw_offset == boundary.raw_offset) {
            selected = marker;
            break;
        };
        const marker = selected orelse return error.OutputBoundaryPending;
        if (start) {
            if (range.start_fence != null or boundary.sequence != 1) return error.InvalidExecutionBoundary;
            range.start = marker.position;
            range.start_fence = boundary.sequence;
        } else {
            if (range.start_fence == null or range.end != null or boundary.sequence != 2 or marker.position.event_sequence <= range.start.event_sequence) return error.InvalidExecutionBoundary;
            range.end = marker.position;
            range.end_fence = boundary.sequence;
        }
        marker.consumed = true;
        return .{ .position = marker.position, .revision = try self.persist(total, null) };
    }
    pub fn saveInterval(self: *Recording, id: identity.ExecutionId, snapshot: execution.Snapshot, total: u64) !u64 {
        const range = try self.find(id);
        if (range.start_fence == null or range.end_fence == null or range.end == null or snapshot.process == null or !snapshot.process.?.foreground_finished or snapshot.output_scope != .session_interval) return error.OutputBoundaryPending;
        var frozen = try self.options.timeline.?.snapshotWithAllocator(self.allocator);
        defer frozen.deinit();
        if (frozen.events.items.len == 0 or frozen.events.items[0].event_sequence > range.start.event_sequence) return error.ExecutionIntervalNotRetained;
        range.process = snapshot.process;
        range.attribution = snapshot.output_attribution;
        range.reason = snapshot.output_attribution_reason;
        range.evidence = .foreground_finished;
        range.saved = true;
        errdefer range.saved = false;
        return self.persist(total, null);
    }
    pub fn abandon(self: *Recording, id: identity.ExecutionId, snapshot: execution.Snapshot, total: u64) !u64 {
        const range = self.find(id) catch return self.revision;
        range.process = snapshot.process;
        range.attribution = snapshot.output_attribution;
        range.reason = snapshot.output_attribution_reason;
        range.failure = snapshot.failure orelse "ExecutionUnknown";
        range.evidence = if (snapshot.submit_sent) .unknown else .cancelled_unsent;
        return self.persist(total, null);
    }
    fn find(self: *Recording, id: identity.ExecutionId) !*Range {
        const text = std.fmt.bytesToHex(id.bytes, .lower);
        for (self.ranges.items) |*range| if (std.mem.eql(u8, &range.id, &text)) return range;
        return error.ExecutionRecordingNotFound;
    }
    pub fn rangeValues(self: *Recording, buffer: []manifest.ExecutionRange) []const manifest.ExecutionRange {
        std.debug.assert(buffer.len >= self.ranges.items.len);
        for (self.ranges.items, buffer[0..self.ranges.items.len]) |*range, *value| value.* = .{ .execution_id = &range.id, .recording_generation = self.options.generations[0].recording_generation, .start = range.start, .end = range.end, .start_boundary_sequence = range.start_fence, .end_boundary_sequence = range.end_fence, .output_scope = .session_interval, .completion_evidence = range.evidence, .process_receipt = range.process, .output_attribution = range.attribution, .output_attribution_reason = range.reason, .interval_saved = range.saved, .failure = range.failure };
        return buffer[0..self.ranges.items.len];
    }
    pub fn persist(self: *Recording, total: u64, ended_ms: ?i64) !u64 {
        var ranges: [128]manifest.ExecutionRange = undefined;
        var sequences: [256]u64 = undefined;
        for (self.boundaries.items, 0..) |marker, i| sequences[i] = marker.position.event_sequence;
        var options = self.options;
        options.total_received = total;
        options.ended_ms = ended_ms;
        options.execution_ranges = self.rangeValues(&ranges);
        options.boundary_sequences = sequences[0..self.boundaries.items.len];
        const receipt = recording.publish(self.allocator, self.io, self.dir, options) catch |err| {
            self.failure = @errorName(err);
            return err;
        };
        if (self.committed_path) |old| {
            self.dir.deleteFile(self.io, old) catch {};
            self.allocator.free(old);
            self.committed_path = null;
        }
        if (ended_ms == null) self.committed_path = try std.fmt.allocPrint(self.allocator, "{s}.commit-{d}.cast", .{ options.cast_path[0 .. options.cast_path.len - 5], receipt.manifest_revision });
        self.revision = receipt.manifest_revision;
        return receipt.manifest_revision;
    }
};
