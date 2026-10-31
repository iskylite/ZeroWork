//! Transport-neutral terminal I/O. Transport is worker-owned; Service is a
//! checked controller-thread mailbox facade, never a borrowed PTY or socket.
const session = @import("session_host.zig");
const identity = @import("identity.zig");
const TextSlot = @import("../vt/text_slot.zig").TextSlot;
const std = @import("std");
pub const Modes = @import("../vt/snapshot.zig").Modes;
pub const Projection = @import("../vt/snapshot.zig").Projection;
pub const PastePolicy = @import("../ui/paste_policy.zig").Policy;
pub const KeyEvent = @import("../vt/input_event.zig").KeyEvent;
pub const MouseEvent = @import("../vt/input_event.zig").MouseEvent;
const viewport = @import("../vt/viewport.zig");
pub const Point = viewport.Point;
pub const Anchor = viewport.OwnedAnchor;
pub const AnchorPosition = viewport.AnchorPosition;
pub const Selection = viewport.OwnedSelection;
pub const Scroll = viewport.OwnedScroll;
pub const LineLimits = viewport.LineLimits;
pub const Lines = viewport.Lines;
pub const Theme = @import("../vt/theme.zig").Theme;
pub const SearchSnapshot = struct {
    owner: identity.SessionHandle,
    document: @import("../vt/search_snapshot.zig").Document,
    pub fn deinit(self: *SearchSnapshot, allocator: std.mem.Allocator) void {
        self.document.deinit(allocator);
    }
};
pub const SearchTask = @import("../vt/search_task.zig").Task;
pub const SearchTail = struct { start_row: u32, version: u64, max_rows: u16 };

/// Bounded retained logical-line query. Line indices are revision-bound and
/// count soft-wrapped physical rows as a single logical line.
pub const ContentRequest = struct {
    range_kind: enum { tail, lines, time } = .tail,
    expected_version: ?u64 = null,
    start_line: ?u64 = null,
    end_line: ?u64 = null,
    start_ms: ?i64 = null,
    end_ms: ?i64 = null,
    after_line: ?u64 = null,
    max_lines: u16 = 100,
    max_bytes: usize = 8192,
};
pub const ContentLine = struct {
    line: u64,
    first_row: u32,
    last_row: u32,
    received_at_ms: ?i64 = null,
    text: []u8,
};
pub const ContentCapture = struct {
    owner: identity.SessionHandle,
    source_revision: u64,
    alternate_screen: bool,
    total_lines: u64,
    lines: []ContentLine,
    truncated: bool = false,
    next_line: ?u64 = null,
    /// A retained VT screen cannot assert durable recording completeness.
    retained_only: bool = true,
    unknown_timestamps: bool = false,
    range_incomplete: bool = false,
    first_line_partial: bool = false,
    pub fn deinit(self: *ContentCapture, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line.text);
        allocator.free(self.lines);
        self.* = undefined;
    }
};

pub const Read = union(enum) { bytes: usize, would_block, eof };
pub const Write = union(enum) { bytes: usize, would_block };
pub const Geometry = struct { revision: u64, cols: u16, rows: u16 };
pub const CommandHistorySnapshot = @import("../vt/recording_manifest.zig").CommandHistorySnapshot;
pub const RecordingKind = enum { txt, cast };
/// Exact provider-owned recording metadata. This carries no file path,
/// terminal text, archive lease, or authority to read a returned identity.
pub const RecordingIdentity = struct {
    owner: identity.SessionHandle,
    recording_id: ?[32]u8 = null,
    recording_generation: u64 = 0,
    available: bool = false,
    failure: ?[]const u8 = null,
};
/// Separate application record event; never a transport/VT output segment.
pub const ApplicationRecord = struct {
    id: u64,
    owner: identity.SessionHandle,
    timestamp_ms: i64,
    /// Native retained-screen position captured when this separate event is published.
    anchor_row: ?u32 = null,
    command: []const u8,
    output: []const u8,
    state: enum { pending, success, failure },
};

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        read: *const fn (*anyopaque, []u8) anyerror!Read,
        write: *const fn (*anyopaque, []const u8) anyerror!Write,
        resize: *const fn (*anyopaque, u64, u16, u16) anyerror!void,
    };
    pub fn read(self: Transport, buffer: []u8) !Read {
        return self.vtable.read(self.context, buffer);
    }
    pub fn write(self: Transport, bytes: []const u8) !Write {
        return self.vtable.write(self.context, bytes);
    }
    pub fn resize(self: Transport, revision: u64, cols: u16, rows: u16) !void {
        if (revision == 0 or cols == 0 or rows == 0) return error.InvalidGeometry;
        return self.vtable.resize(self.context, revision, cols, rows);
    }
};

pub const WriteRequest = struct { input_sequence: u64, mode_revision: u64 = 1, bytes: []const u8, submission: bool = false };
pub const KeyRequest = struct { input_sequence: u64, mode_revision: u64, event: KeyEvent };
pub const MouseRequest = struct { input_sequence: u64, mode_revision: u64, geometry_revision: u64, event: MouseEvent };
/// Acceptance into the bounded mailbox is distinct from a PTY write receipt.
pub const Submission = struct { input_sequence: u64, queued_bytes: usize };
pub const WriteFailure = enum { stale_mode, transport_failed };
pub const WriteReceipt = struct {
    input_sequence: u64,
    mode_revision: u64,
    consumed_bytes: usize,
    state: enum { completed, cancelled, failed },
    failure: ?WriteFailure = null,
};
/// Scalar facts copied for the exact terminal owner. The consumer retains its
/// last observed counters per owner instead of inferring activity from redraws.
pub const NotificationSnapshot = struct {
    owner: identity.SessionHandle,
    output_sequence: u64,
    bell_count: u64,
    recording_error: ?[]const u8 = null,
};
pub const Status = struct {
    owner: identity.SessionHandle,
    writable: bool,
    eof_seen: bool,
    geometry: Geometry,
    output_sequence: u64,
    bell_count: u64 = 0,
    pending_input_bytes: usize,
    resize_error: ?[]const u8 = null,
    terminal_error: ?[]const u8 = null,
    snapshot_error: ?[]const u8 = null,
    recording_error: ?[]const u8 = null,
    theme_error: ?[]const u8 = null,
    applied_theme_revision: u64 = 0,
    mode_revision: u64 = 1,
    modes: Modes = .{},

    pub fn notification(self: Status) NotificationSnapshot {
        return .{ .owner = self.owner, .output_sequence = self.output_sequence, .bell_count = self.bell_count, .recording_error = self.recording_error };
    }
};

pub const TerminalSnapshot = struct {
    owner: identity.SessionHandle,
    /// Output included in this successfully captured projection, not the
    /// worker's possibly newer receive counter.
    output_sequence: u64 = 0,
    geometry_revision: u64,
    input_revision: u64,
    read_only: bool,
    eof_seen: bool,
    projection: Projection,
    applied_theme_revision: u64 = 0,
    pub fn deinit(self: *TerminalSnapshot, allocator: std.mem.Allocator) void {
        self.projection.deinit(allocator);
    }
};
/// Owns the exact validated text shown by confirmation. A changed input,
/// binding or real VT mode invalidates it before any byte is queued.
pub const Paste = struct {
    binding: session.ServiceHandle,
    input_revision: u64,
    mode_revision: u64,
    text: []const u8,
    requires_confirmation: bool,
    pub fn deinit(self: *Paste, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const trusted_edit = @import("trusted_edit.zig");
pub const execution = @import("terminal_execution.zig");

pub const Service = struct {
    binding: session.ServiceHandle,
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        command_history_snapshot: ?*const fn (*anyopaque, session.ServiceHandle, std.mem.Allocator) anyerror!CommandHistorySnapshot = null,
        recording_identity: ?*const fn (*anyopaque, session.ServiceHandle) anyerror!RecordingIdentity = null,
        content_query: ?*const fn (*anyopaque, session.ServiceHandle, ContentRequest, std.mem.Allocator) anyerror!ContentCapture = null,
        recording_display: ?*const fn (*anyopaque, session.ServiceHandle, @import("../vt/recording_manifest.zig").Display) anyerror!void = null,
        execution_secret: ?*const fn (*anyopaque, session.ServiceHandle, execution.SecretAction) anyerror!execution.InputReceipt = null,
        execution_input: ?*const fn (*anyopaque, session.ServiceHandle, execution.InputRequest) anyerror!execution.InputReceipt = null,
        execution_output: ?*const fn (*anyopaque, session.ServiceHandle, identity.ExecutionId, std.mem.Allocator, u64, usize) anyerror!execution.Output = null,
        execution_snapshot: ?*const fn (*anyopaque, session.ServiceHandle) anyerror!execution.Snapshot = null,
        execution_request: ?*const fn (*anyopaque, session.ServiceHandle, execution.Request) anyerror!void = null,
        execution_renew: ?*const fn (*anyopaque, session.ServiceHandle, execution.Grant) anyerror!void = null,
        execution_revoke: ?*const fn (*anyopaque, session.ServiceHandle, execution.Grant, bool) anyerror!void = null,
        write: *const fn (*anyopaque, session.ServiceHandle, WriteRequest) anyerror!Submission,
        resize: *const fn (*anyopaque, session.ServiceHandle, Geometry) anyerror!void,
        read: *const fn (*anyopaque, session.ServiceHandle, []u8) anyerror!Read,
        receipt: *const fn (*anyopaque, session.ServiceHandle) anyerror!?WriteReceipt,
        status: *const fn (*anyopaque, session.ServiceHandle) anyerror!Status,
        text_slot: *const fn (*anyopaque, session.ServiceHandle) anyerror!*TextSlot,
        snapshot: *const fn (*anyopaque, session.ServiceHandle, std.mem.Allocator) anyerror!TerminalSnapshot,
        prepare_paste: *const fn (*anyopaque, session.ServiceHandle, std.mem.Allocator, []const u8) anyerror!Paste,
        commit_paste: *const fn (*anyopaque, session.ServiceHandle, Paste, u64, bool) anyerror!Submission,
        key: *const fn (*anyopaque, session.ServiceHandle, KeyRequest) anyerror!Submission,
        mouse: *const fn (*anyopaque, session.ServiceHandle, MouseRequest) anyerror!Submission,
        create_anchor: *const fn (*anyopaque, session.ServiceHandle, Point) anyerror!Anchor,
        resolve_anchor: *const fn (*anyopaque, session.ServiceHandle, Anchor) anyerror!?AnchorPosition,
        release_anchor: *const fn (*anyopaque, session.ServiceHandle, Anchor) anyerror!void,
        selection_text: *const fn (*anyopaque, session.ServiceHandle, Selection, std.mem.Allocator, usize) anyerror![]u8,
        scroll: *const fn (*anyopaque, session.ServiceHandle, Scroll) anyerror!void,
        read_lines: *const fn (*anyopaque, session.ServiceHandle, LineLimits, std.mem.Allocator) anyerror!Lines,
        theme: *const fn (*anyopaque, session.ServiceHandle, Theme) anyerror!void,
        application_record: ?*const fn (*anyopaque, session.ServiceHandle, ApplicationRecord) anyerror!void = null,
        export_recording: ?*const fn (*anyopaque, session.ServiceHandle, RecordingKind, std.Io, std.Io.Dir, []const u8) anyerror!void = null,
        recording_lease: ?*const fn (*anyopaque, session.ServiceHandle) anyerror!@import("../vt/timeline.zig").Timeline.ExportLease = null,
        trusted_snapshot: ?*const fn (*anyopaque, session.ServiceHandle, std.mem.Allocator) anyerror!?trusted_edit.Snapshot = null,
        trusted_request: ?*const fn (*anyopaque, session.ServiceHandle, trusted_edit.Request) anyerror!void = null,
        trusted_outcome: ?*const fn (*anyopaque, session.ServiceHandle) anyerror!?trusted_edit.Outcome = null,
        trusted_cancel: ?*const fn (*anyopaque, session.ServiceHandle) anyerror!void = null,
        search_snapshot: ?*const fn (*anyopaque, session.ServiceHandle, std.mem.Allocator) anyerror!SearchSnapshot = null,
        search_async: ?*const fn (*anyopaque, session.ServiceHandle) anyerror!*SearchTask = null,
        search_tail: ?*const fn (*anyopaque, session.ServiceHandle, SearchTail, std.mem.Allocator) anyerror!SearchSnapshot = null,
    };
    pub fn contentQuery(self: Service, request: ContentRequest, allocator: std.mem.Allocator) !ContentCapture {
        if (request.max_lines == 0 or request.max_lines > 500 or request.max_bytes == 0 or request.max_bytes > 65536) return error.InvalidArguments;
        const call = self.vtable.content_query orelse return error.RangeUnavailable;
        return call(self.context, self.binding, request, allocator);
    }
    pub fn setRecordingDisplay(self: Service, display: @import("../vt/recording_manifest.zig").Display) !void {
        const call = self.vtable.recording_display orelse return error.RecordingUnavailable;
        return call(self.context, self.binding, display);
    }
    pub fn executionSecret(self: Service, action: execution.SecretAction) !execution.InputReceipt {
        const call = self.vtable.execution_secret orelse return error.HostSecretUnavailable;
        return call(self.context, self.binding, action);
    }
    pub fn executionInput(self: Service, request: execution.InputRequest) !execution.InputReceipt {
        const call = self.vtable.execution_input orelse return error.UnsupportedInteraction;
        return call(self.context, self.binding, request);
    }
    pub fn executionOutput(self: Service, id: identity.ExecutionId, allocator: std.mem.Allocator, cursor: u64, max_bytes: usize) !execution.Output {
        const call = self.vtable.execution_output orelse return error.IntegrationUnavailable;
        if (max_bytes == 0 or max_bytes > 65536) return error.InvalidArguments;
        return call(self.context, self.binding, id, allocator, cursor, max_bytes);
    }
    pub fn executionSnapshot(self: Service) !execution.Snapshot {
        const call = self.vtable.execution_snapshot orelse return .{ .owner = switch (self.binding.resource_owner) {
            .session => |owner| owner,
            else => self.binding.origin_session orelse return error.InvalidOwner,
        } };
        return call(self.context, self.binding);
    }
    pub fn executionRequest(self: Service, request: execution.Request) !void {
        const call = self.vtable.execution_request orelse return error.IntegrationUnavailable;
        return call(self.context, self.binding, request);
    }
    /// On-demand bounded metadata copy; this never scans or replays a cast.
    pub fn commandHistorySnapshot(self: Service, allocator: std.mem.Allocator) !CommandHistorySnapshot {
        const call = self.vtable.command_history_snapshot orelse return error.CommandHistoryUnavailable;
        const owner = switch (self.binding.resource_owner) {
            .session => |value| value,
            else => return error.InvalidOwner,
        };
        var result = try call(self.context, self.binding, allocator);
        errdefer result.deinit(allocator);
        if (!result.owner.eql(owner)) return error.StaleOwner;
        if (result.recording_id) |id| {
            _ = identity.RecordingId.parse(&id) catch return error.InvalidRecordingIdentity;
            if (result.recording_generation == 0) return error.InvalidRecordingIdentity;
        }
        var bytes: usize = 0;
        for (result.records) |record| {
            if (record.recording_generation == 0 or record.value.id == 0) return error.InvalidCommandHistory;
            bytes = std.math.add(usize, bytes, @sizeOf(@import("../vt/recording_manifest.zig").CommandExecution) + (if (record.value.command) |text| text.len else @as(usize, 0))) catch return error.CommandHistoryCapacity;
            if (bytes > 4 * 1024 * 1024) return error.CommandHistoryCapacity;
        }
        return result;
    }
    pub fn recordingIdentity(self: Service) !RecordingIdentity {
        const call = self.vtable.recording_identity orelse return error.RecordingIdentityUnavailable;
        const owner = switch (self.binding.resource_owner) {
            .session => |value| value,
            else => return error.InvalidOwner,
        };
        const value = try call(self.context, self.binding);
        if (!value.owner.eql(owner)) return error.StaleOwner;
        if (value.recording_id) |id| {
            _ = identity.RecordingId.parse(&id) catch return error.InvalidRecordingIdentity;
            if (value.recording_generation == 0) return error.InvalidRecordingIdentity;
        } else if (value.available or value.recording_generation != 0) return error.InvalidRecordingIdentity;
        if (value.available and value.failure != null) return error.InvalidRecordingIdentity;
        return value;
    }
    pub fn executionRenew(self: Service, grant: execution.Grant) !void {
        const call = self.vtable.execution_renew orelse return error.IntegrationUnavailable;
        return call(self.context, self.binding, grant);
    }
    pub fn executionRevoke(self: Service, grant: execution.Grant, takeover: bool) !void {
        const call = self.vtable.execution_revoke orelse return error.IntegrationUnavailable;
        return call(self.context, self.binding, grant, takeover);
    }
    pub fn trustedSnapshot(self: Service, allocator: std.mem.Allocator) !?trusted_edit.Snapshot {
        const call = self.vtable.trusted_snapshot orelse return null;
        return call(self.context, self.binding, allocator);
    }
    pub fn trustedRequest(self: Service, request: trusted_edit.Request) !void {
        const call = self.vtable.trusted_request orelse return error.TrustedEditUnavailable;
        return call(self.context, self.binding, request);
    }
    pub fn trustedOutcome(self: Service) !?trusted_edit.Outcome {
        const call = self.vtable.trusted_outcome orelse return null;
        return call(self.context, self.binding);
    }
    pub fn cancelTrustedEdit(self: Service) !void {
        const call = self.vtable.trusted_cancel orelse return;
        return call(self.context, self.binding);
    }
    pub fn write(self: Service, request: WriteRequest) !Submission {
        if (request.input_sequence == 0 or request.mode_revision == 0 or request.bytes.len == 0) return error.InvalidInput;
        return self.vtable.write(self.context, self.binding, request);
    }
    pub fn resize(self: Service, geometry: Geometry) !void {
        if (geometry.revision == 0 or geometry.cols == 0 or geometry.rows == 0) return error.InvalidGeometry;
        return self.vtable.resize(self.context, self.binding, geometry);
    }
    pub fn readOutput(self: Service, buffer: []u8) !Read {
        return self.vtable.read(self.context, self.binding, buffer);
    }
    pub fn takeWriteReceipt(self: Service) !?WriteReceipt {
        return self.vtable.receipt(self.context, self.binding);
    }
    pub fn status(self: Service) !Status {
        return self.vtable.status(self.context, self.binding);
    }
    pub fn textSlot(self: Service) !*TextSlot {
        return self.vtable.text_slot(self.context, self.binding);
    }
    pub fn snapshot(self: Service, allocator: std.mem.Allocator) !TerminalSnapshot {
        return self.vtable.snapshot(self.context, self.binding, allocator);
    }
    pub fn preparePaste(self: Service, allocator: std.mem.Allocator, text: []const u8) !Paste {
        return self.vtable.prepare_paste(self.context, self.binding, allocator, text);
    }
    pub fn commitPaste(self: Service, paste: Paste, input_sequence: u64, confirmed: bool) !Submission {
        return self.vtable.commit_paste(self.context, self.binding, paste, input_sequence, confirmed);
    }
    pub fn writeKey(self: Service, request: KeyRequest) !Submission {
        return self.vtable.key(self.context, self.binding, request);
    }
    pub fn writeMouse(self: Service, request: MouseRequest) !Submission {
        return self.vtable.mouse(self.context, self.binding, request);
    }
    pub fn createAnchor(self: Service, point: Point) !Anchor {
        return self.vtable.create_anchor(self.context, self.binding, point);
    }
    pub fn resolveAnchor(self: Service, anchor: Anchor) !?AnchorPosition {
        return self.vtable.resolve_anchor(self.context, self.binding, anchor);
    }
    pub fn releaseAnchor(self: Service, anchor: Anchor) !void {
        return self.vtable.release_anchor(self.context, self.binding, anchor);
    }
    pub fn selectionText(self: Service, selected: Selection, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        return self.vtable.selection_text(self.context, self.binding, selected, allocator, max_bytes);
    }
    pub fn scroll(self: Service, request: Scroll) !void {
        return self.vtable.scroll(self.context, self.binding, request);
    }
    pub fn readLines(self: Service, limits: LineLimits, allocator: std.mem.Allocator) !Lines {
        return self.vtable.read_lines(self.context, self.binding, limits, allocator);
    }
    pub fn searchSnapshot(self: Service, allocator: std.mem.Allocator) !SearchSnapshot {
        const capture = self.vtable.search_snapshot orelse return error.SearchUnavailable;
        return capture(self.context, self.binding, allocator);
    }
    pub fn beginSearch(self: Service) !*SearchTask {
        const call = self.vtable.search_async orelse return error.SearchAsyncUnavailable;
        return call(self.context, self.binding);
    }
    pub fn searchTail(self: Service, request: SearchTail, allocator: std.mem.Allocator) !SearchSnapshot {
        const call = self.vtable.search_tail orelse return error.FullSearchRequired;
        return call(self.context, self.binding, request, allocator);
    }
    pub fn setTheme(self: Service, theme: Theme) !void {
        if (theme.revision == 0) return error.InvalidTheme;
        return self.vtable.theme(self.context, self.binding, theme);
    }
    pub fn recordApplication(self: Service, record: ApplicationRecord) !void {
        const call = self.vtable.application_record orelse return;
        return call(self.context, self.binding, record);
    }
    pub fn exportRecording(self: Service, kind: RecordingKind, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        const export_recording = self.vtable.export_recording orelse return error.RecordingUnavailable;
        try export_recording(self.context, self.binding, kind, io, dir, path);
    }
    pub fn recordingLease(self: Service) !@import("../vt/timeline.zig").Timeline.ExportLease {
        const call = self.vtable.recording_lease orelse return error.RecordingUnavailable;
        return call(self.context, self.binding);
    }
};

test "recording identity validates owner generation and availability without content access" {
    const Fixture = struct {
        value: RecordingIdentity,
        fn snapshot(raw: *anyopaque, _: session.ServiceHandle) !RecordingIdentity {
            return (@as(*@This(), @ptrCast(@alignCast(raw)))).value;
        }
    };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(17), .generation = 2 };
    var fixture: Fixture = .{ .value = .{ .owner = owner, .failure = "RecordingDisabled" } };
    var hooks: Service.VTable = undefined;
    hooks.recording_identity = Fixture.snapshot;
    const service: Service = .{ .binding = .{ .resource_owner = .{ .session = owner }, .kind = .terminal, .binding_id = 1, .binding_generation = 1 }, .context = &fixture, .vtable = &hooks };
    const absent = try service.recordingIdentity();
    try std.testing.expect(!absent.available and absent.recording_id == null);
    try std.testing.expectEqualStrings("RecordingDisabled", absent.failure.?);
    fixture.value = .{ .owner = owner, .recording_id = "0123456789abcdef0123456789abcdef".*, .recording_generation = 4, .available = true };
    const live = try service.recordingIdentity();
    try std.testing.expect(live.available and live.recording_generation == 4);
    fixture.value.recording_generation = 0;
    try std.testing.expectError(error.InvalidRecordingIdentity, service.recordingIdentity());
    fixture.value.recording_generation = 4;
    fixture.value.owner.generation += 1;
    try std.testing.expectError(error.StaleOwner, service.recordingIdentity());
    fixture.value.owner = owner;
    fixture.value.failure = "RecordingUnavailable";
    try std.testing.expectError(error.InvalidRecordingIdentity, service.recordingIdentity());
    fixture.value.available = false;
    try std.testing.expect(!(try service.recordingIdentity()).available);
    hooks.recording_identity = null;
    try std.testing.expectError(error.RecordingIdentityUnavailable, service.recordingIdentity());
}

test "command history snapshot owns complete metadata and checks the exact service owner" {
    const a = std.testing.allocator;
    const Fixture = struct {
        owner: identity.SessionHandle,
        record_generation: u64 = 2,
        fn capture(raw: *anyopaque, _: session.ServiceHandle, allocator: std.mem.Allocator) !CommandHistorySnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const records = try allocator.alloc(@import("../vt/recording_manifest.zig").CommandExecution, 1);
            errdefer allocator.free(records);
            const command = try allocator.dupe(u8, "true");
            errdefer allocator.free(command);
            records[0] = .{ .recording_generation = self.record_generation, .value = .{ .id = 9, .command = command, .start_ms = 100, .exit_code = 0, .state = .succeeded } };
            return .{ .owner = self.owner, .recording_id = "0123456789abcdef0123456789abcdef".*, .recording_generation = 2, .revision = 7, .records = records, .partial = true, .failure = try allocator.dupe(u8, "RecordingDegraded") };
        }
    };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(17), .generation = 2 };
    var fixture: Fixture = .{ .owner = owner };
    var hooks: Service.VTable = undefined;
    hooks.command_history_snapshot = Fixture.capture;
    const service: Service = .{ .binding = .{ .resource_owner = .{ .session = owner }, .kind = .terminal, .binding_id = 1, .binding_generation = 2 }, .context = &fixture, .vtable = &hooks };
    var first = try service.commandHistorySnapshot(a);
    defer first.deinit(a);
    var second = try service.commandHistorySnapshot(a);
    defer second.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), first.records.len);
    try std.testing.expectEqual(first.revision, second.revision);
    try std.testing.expectEqualStrings("true", second.records[0].value.command.?);
    try std.testing.expect(first.records[0].value.command.?.ptr != second.records[0].value.command.?.ptr);
    fixture.owner.generation += 1;
    try std.testing.expectError(error.StaleOwner, service.commandHistorySnapshot(a));
    fixture.owner = owner;
    fixture.record_generation = 0;
    try std.testing.expectError(error.InvalidCommandHistory, service.commandHistorySnapshot(a));
    hooks.command_history_snapshot = null;
    try std.testing.expectError(error.CommandHistoryUnavailable, service.commandHistorySnapshot(a));
}
