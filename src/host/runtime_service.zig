//! Opaque session runtime boundary. Concrete engines and their threads remain
//! provider-owned; public hosts consume typed services and scalar state only.
const std = @import("std");
const identity = @import("identity.zig");
const session = @import("session_host.zig");
const terminal = @import("terminal_service.zig");
const OperationKey = @import("operation.zig").OperationKey;
pub const ReleaseReceipt = @import("../proto/ssh/session.zig").ReleaseReceipt;
pub const ArchiveRequest = struct { session_id: u64, retention_days: u16 };
pub const NotificationPublication = struct { text_generation: u64, output_sequence: u64, at_tail: bool };
pub const OsDetection = struct { kind: @import("../proto/ssh/remote_os.zig").Kind = .unknown, pending: bool = false };
pub const Runtime = struct {
    context: *anyopaque,
    vtable: *const VTable,
    torn_down: bool = false,
    released: bool = false,
    pub const VTable = struct {
        osDetection: ?*const fn (*anyopaque) OsDetection = null,
        releaseStep: *const fn (*anyopaque, ?ArchiveRequest) ReleaseReceipt,
        cleanupReleased: *const fn (*anyopaque) bool,
        reconnectSnapshot: *const fn (*anyopaque) ?@import("../vt/reconnect.zig").Control.Snapshot,
        requestReconnect: *const fn (*anyopaque, OperationKey, OperationKey) anyerror!void,
        acknowledgeAttached: *const fn (*anyopaque, OperationKey) bool,
        isAttached: *const fn (*anyopaque) bool,
        isConnected: *const fn (*anyopaque) bool,
        markAttached: *const fn (*anyopaque) void,
        setInputBufferEnabled: *const fn (*anyopaque, bool) void,
        requestCurrentDirectory: ?*const fn (*anyopaque) anyerror!void = null,
        copyCwd: *const fn (*anyopaque, std.mem.Allocator) anyerror!?[]u8,
        searchText: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        readLines: *const fn (*anyopaque, terminal.LineLimits, std.mem.Allocator) anyerror!terminal.Lines,
        readonlyProvider: ?*const fn (*anyopaque) anyerror!@import("../proto/ssh/shared_readonly_mailbox.zig").Provider = null,
        notificationSnapshot: *const fn (*anyopaque, identity.SessionHandle) anyerror!terminal.NotificationSnapshot,
        execService: ?*const fn (*anyopaque, session.ServiceHandle) anyerror!@import("../ai/execbridge.zig").ExecBridge = null,
        transferService: ?*const fn (*anyopaque, session.ServiceHandle) anyerror!*@import("../proto/ssh/shared_transfer_service.zig").Service = null,
        forwardService: ?*const fn (*anyopaque, session.ServiceHandle, ?usize) anyerror!*@import("../proto/ssh/forward_service.zig").Service = null,
        exportTimeline: *const fn (*anyopaque, std.Io, std.Io.Dir, []const u8) anyerror!void,
        sourceVersion: *const fn (*anyopaque) u64,
        captureAiSelection: *const fn (*anyopaque, std.mem.Allocator, identity.SessionHandle, @import("../vt/engine.zig").Selection, u64) anyerror!@import("ai_terminal_selection.zig").Captured,
        semanticSequence: *const fn (*anyopaque) u64,
        documentSource: ?*const fn (*anyopaque) anyerror!terminal.Service = null,
        copyProjection: *const fn (*anyopaque, std.mem.Allocator) anyerror!@import("../vt/snapshot.zig").Projection,
        hasJoined: *const fn (*anyopaque) bool,
        isStopping: *const fn (*anyopaque) bool,
        hasFailed: *const fn (*anyopaque) bool,
        textSlot: *const fn (*anyopaque) *@import("../vt/text_slot.zig").TextSlot,
        reconnectState: *const fn (*anyopaque) @import("../vt/reconnect.zig").State,
        inputFreeCapacity: *const fn (*anyopaque) usize,
        requestResize: *const fn (*anyopaque, u16, u16) void,
        searchViewportOffset: *const fn (*anyopaque) u64,
        locateSearchRow: *const fn (*anyopaque, usize) void,
        copySelection: *const fn (*anyopaque, @import("../vt/engine.zig").Selection, std.mem.Allocator) anyerror![]u8,
        encodeKey: ?*const fn (*anyopaque, terminal.KeyEvent, std.mem.Allocator) anyerror![]u8 = null,
        pushInputFrom: *const fn (*anyopaque, []const u8, @import("../vt/reconnect_replay.zig").Source) anyerror!void,
        allowsBufferedOrdinaryInput: *const fn (*anyopaque) bool,
        discardBufferedInput: *const fn (*anyopaque) void,
        notificationPublication: *const fn (*anyopaque, identity.SessionHandle) anyerror!?NotificationPublication,
    };
    pub fn osDetection(self: *Runtime) OsDetection {
        if (self.torn_down) return .{};
        return if (self.vtable.osDetection) |invoke| invoke(self.context) else .{};
    }
    pub fn releaseStep(self: *Runtime, archive: ?ArchiveRequest) ReleaseReceipt {
        if (self.released) return .released;
        self.torn_down = true;
        return self.vtable.releaseStep(self.context, archive);
    }
    pub fn cleanupReleased(self: *Runtime) bool {
        if (self.released) return true;
        self.torn_down = true;
        self.released = self.vtable.cleanupReleased(self.context);
        return self.released;
    }
    pub fn cleanup(self: *Runtime) void {
        _ = self.cleanupReleased();
    }
    /// Compatibility spelling for existing typed service consumers. This is
    /// the same opaque facade, never a native worker or downcast escape hatch.
    pub fn workerPtr(self: *Runtime) *Runtime {
        return self;
    }
    pub fn threadPtr(self: *Runtime) *Runtime {
        return self;
    }
    pub fn encodeKey(self: *Runtime, event: terminal.KeyEvent, allocator: std.mem.Allocator) ![]u8 {
        if (self.torn_down) return error.SessionClosed;
        return (self.vtable.encodeKey orelse return error.UnsupportedService)(self.context, event, allocator);
    }
    pub fn mountTerminal(self: *Runtime, view: *@import("../ui/terminal_view.zig").TerminalViewNode, status: *@import("ui").Node) !void {
        if (self.torn_down) return error.SessionClosed;
        view.bindWorker(self);
        const cx = view.cx;
        const scratch = try cx.allocator.alloc(u8, @import("../vt/text_slot.zig").TextSlot.default_capacity);
        errdefer cx.allocator.free(scratch);
        const seen = try cx.allocator.create(u64);
        errdefer cx.allocator.destroy(seen);
        seen.* = 0;
        try view.addWorkerFrameHook(cx, self, self, status, seen, scratch);
    }
    pub fn reconnectSnapshot(self: *Runtime) ?@import("../vt/reconnect.zig").Control.Snapshot {
        if (self.torn_down) return null;
        return self.vtable.reconnectSnapshot(self.context);
    }
    pub fn requestReconnect(self: *Runtime, previous: OperationKey, next: OperationKey) anyerror!void {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.requestReconnect(self.context, previous, next);
    }
    pub fn acknowledgeAttached(self: *Runtime, key: OperationKey) bool {
        return self.vtable.acknowledgeAttached(self.context, key);
    }
    pub fn isAttached(self: *Runtime) bool {
        if (self.torn_down) return false;
        return self.vtable.isAttached(self.context);
    }
    pub fn isConnected(self: *Runtime) bool {
        if (self.torn_down) return false;
        return self.vtable.isConnected(self.context);
    }
    pub fn markAttached(self: *Runtime) void {
        if (self.torn_down) return;
        return self.vtable.markAttached(self.context);
    }
    pub fn setInputBufferEnabled(self: *Runtime, enabled: bool) void {
        if (self.torn_down) return;
        return self.vtable.setInputBufferEnabled(self.context, enabled);
    }
    pub fn requestCurrentDirectory(self: *Runtime) !void {
        if (self.vtable.requestCurrentDirectory) |call| return call(self.context);
        return error.UnsupportedOperation;
    }
    pub fn copyCwd(self: *Runtime, allocator: std.mem.Allocator) anyerror!?[]u8 {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.copyCwd(self.context, allocator);
    }
    pub fn searchText(self: *Runtime, allocator: std.mem.Allocator) anyerror![]u8 {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.searchText(self.context, allocator);
    }
    pub fn readLines(self: *Runtime, limits: terminal.LineLimits, allocator: std.mem.Allocator) anyerror!terminal.Lines {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.readLines(self.context, limits, allocator);
    }
    pub fn readonlyProvider(self: *Runtime) anyerror!@import("../proto/ssh/shared_readonly_mailbox.zig").Provider {
        if (self.torn_down) return error.SessionClosed;
        const invoke = self.vtable.readonlyProvider orelse return error.UnsupportedService;
        return invoke(self.context);
    }
    pub fn notificationSnapshot(self: *Runtime, owner: identity.SessionHandle) anyerror!terminal.NotificationSnapshot {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.notificationSnapshot(self.context, owner);
    }
    pub fn execService(self: *Runtime, binding: session.ServiceHandle) anyerror!@import("../ai/execbridge.zig").ExecBridge {
        if (self.torn_down) return error.SessionClosed;
        const invoke = self.vtable.execService orelse return error.UnsupportedService;
        return invoke(self.context, binding);
    }
    pub fn transferService(self: *Runtime, binding: session.ServiceHandle) anyerror!*@import("../proto/ssh/shared_transfer_service.zig").Service {
        if (self.torn_down) return error.SessionClosed;
        const invoke = self.vtable.transferService orelse return error.UnsupportedService;
        return invoke(self.context, binding);
    }
    pub fn forwardService(self: *Runtime, binding: session.ServiceHandle, exit_index: ?usize) anyerror!*@import("../proto/ssh/forward_service.zig").Service {
        if (self.torn_down) return error.SessionClosed;
        const invoke = self.vtable.forwardService orelse return error.UnsupportedService;
        return invoke(self.context, binding, exit_index);
    }
    pub fn exportTimeline(self: *Runtime, io: std.Io, dir: std.Io.Dir, path: []const u8) anyerror!void {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.exportTimeline(self.context, io, dir, path);
    }
    pub fn documentSource(self: *Runtime) !terminal.Service {
        if (self.torn_down) return error.SessionClosed;
        return (self.vtable.documentSource orelse return error.UnsupportedService)(self.context);
    }
    pub fn sourceVersion(self: *Runtime) u64 {
        return self.vtable.sourceVersion(self.context);
    }
    pub fn captureAiSelection(self: *Runtime, allocator: std.mem.Allocator, owner: identity.SessionHandle, selected: @import("../vt/engine.zig").Selection, version: u64) anyerror!@import("ai_terminal_selection.zig").Captured {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.captureAiSelection(self.context, allocator, owner, selected, version);
    }
    pub fn semanticSequence(self: *Runtime) u64 {
        return self.vtable.semanticSequence(self.context);
    }
    pub fn copyProjection(self: *Runtime, allocator: std.mem.Allocator) anyerror!@import("../vt/snapshot.zig").Projection {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.copyProjection(self.context, allocator);
    }
    pub fn hasJoined(self: *Runtime) bool {
        if (self.torn_down) return true;
        return self.vtable.hasJoined(self.context);
    }
    pub fn isStopping(self: *Runtime) bool {
        if (self.torn_down) return true;
        return self.vtable.isStopping(self.context);
    }
    pub fn hasFailed(self: *Runtime) bool {
        if (self.torn_down) return true;
        return self.vtable.hasFailed(self.context);
    }
    pub fn textSlot(self: *Runtime) *@import("../vt/text_slot.zig").TextSlot {
        return self.vtable.textSlot(self.context);
    }
    pub fn reconnectState(self: *Runtime) @import("../vt/reconnect.zig").State {
        return self.vtable.reconnectState(self.context);
    }
    pub fn inputFreeCapacity(self: *Runtime) usize {
        return self.vtable.inputFreeCapacity(self.context);
    }
    pub fn requestResize(self: *Runtime, cols: u16, rows: u16) void {
        if (self.torn_down) return;
        return self.vtable.requestResize(self.context, cols, rows);
    }
    pub fn searchViewportOffset(self: *Runtime) u64 {
        return self.vtable.searchViewportOffset(self.context);
    }
    pub fn locateSearchRow(self: *Runtime, row: usize) void {
        if (self.torn_down) return;
        return self.vtable.locateSearchRow(self.context, row);
    }
    pub fn copySelection(self: *Runtime, selection: @import("../vt/engine.zig").Selection, allocator: std.mem.Allocator) anyerror![]u8 {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.copySelection(self.context, selection, allocator);
    }
    pub fn pushInputFrom(self: *Runtime, bytes: []const u8, source: @import("../vt/reconnect_replay.zig").Source) anyerror!void {
        if (self.torn_down) return error.SessionClosed;
        return self.vtable.pushInputFrom(self.context, bytes, source);
    }
    pub fn allowsBufferedOrdinaryInput(self: *Runtime) bool {
        if (self.torn_down) return false;
        return self.vtable.allowsBufferedOrdinaryInput(self.context);
    }
    pub fn discardBufferedInput(self: *Runtime) void {
        if (self.torn_down) return;
        return self.vtable.discardBufferedInput(self.context);
    }
    pub fn notificationPublication(self: *Runtime, owner: identity.SessionHandle) anyerror!?NotificationPublication {
        if (self.torn_down) return null;
        return self.vtable.notificationPublication(self.context, owner);
    }
};

test "released runtime rejects retained consumers before dereferencing provider context" {
    // A released provider has already freed its native allocation. Deliberately
    // invalid callbacks prove every retained consumer checks the facade first.
    var runtime: Runtime = .{ .context = undefined, .vtable = undefined, .torn_down = true, .released = true };
    try std.testing.expectEqual(ReleaseReceipt.released, runtime.releaseStep(null));
    try std.testing.expect(runtime.cleanupReleased());
    try std.testing.expect(runtime.reconnectSnapshot() == null);
    try std.testing.expect(!runtime.isAttached() and !runtime.isConnected());
    try std.testing.expect(runtime.hasJoined() and runtime.isStopping());
    try std.testing.expectError(error.SessionClosed, runtime.copyCwd(std.testing.allocator));
    try std.testing.expectError(error.SessionClosed, runtime.readLines(.{}, std.testing.allocator));
    try std.testing.expectError(error.SessionClosed, runtime.readonlyProvider());
}
