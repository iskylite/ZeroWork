//! SSH engine binding. No application or workspace pointer crosses this seam.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const session = @import("../../host/session_host.zig");
const terminal = @import("../../host/terminal_service.zig");
const OperationKey = @import("../../host/operation.zig").OperationKey;
const service = @import("../../host/runtime_service.zig");
const Native = @import("../../ui/session_runtime.zig").SessionRuntime;
const NotificationPublication = service.NotificationPublication;
pub fn borrow(native: *Native) service.Runtime {
    return .{ .context = native, .vtable = &vtable, .torn_down = native.torn_down };
}
fn get(raw: *anyopaque) *Native {
    return @ptrCast(@alignCast(raw));
}
fn releaseStep(raw: *anyopaque, archive: ?service.ArchiveRequest) service.ReleaseReceipt {
    return get(raw).releaseStep(if (archive) |value| .{ .session_id = value.session_id, .retention_days = value.retention_days } else null);
}
fn cleanupReleased(raw: *anyopaque) bool {
    return get(raw).cleanupReleased();
}
fn reconnectSnapshot(raw: *anyopaque) ?@import("../../vt/reconnect.zig").Control.Snapshot {
    return get(raw).reconnectSnapshot();
}
fn requestReconnect(raw: *anyopaque, previous: OperationKey, next: OperationKey) anyerror!void {
    return get(raw).requestReconnect(previous, next);
}
fn acknowledgeAttached(raw: *anyopaque, key: OperationKey) bool {
    return get(raw).acknowledgeAttached(key);
}
fn isAttached(raw: *anyopaque) bool {
    const native = get(raw);
    return !native.torn_down and native.worker.presentation_attached.load(.acquire);
}
fn isConnected(raw: *anyopaque) bool {
    const native = get(raw);
    return !native.torn_down and native.worker.reconnect.currentState() == .connected;
}
fn markAttached(raw: *anyopaque) void {
    get(raw).workerPtr().markAttached();
}
fn setScrollbackLimit(raw: *anyopaque, limit: u32) void {
    const native = get(raw);
    if (!native.torn_down) native.worker.requestScrollbackLimit(limit);
}
fn setInputBufferEnabled(raw: *anyopaque, enabled: bool) void {
    const native = get(raw);
    if (!native.torn_down) native.worker.setInputBufferEnabled(enabled);
}
fn requestCurrentDirectory(raw: *anyopaque) anyerror!void {
    try get(raw).workerPtr().requestCurrentDirectory();
}
fn copyCwd(raw: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
    if (get(raw).torn_down) return error.SessionClosed;
    return get(raw).workerPtr().copyCwd(allocator);
}
fn searchText(raw: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    if (get(raw).torn_down) return error.SessionClosed;
    return get(raw).workerPtr().searchText(allocator);
}
fn readLines(raw: *anyopaque, limits: terminal.LineLimits, allocator: std.mem.Allocator) anyerror!terminal.Lines {
    if (get(raw).torn_down) return error.SessionClosed;
    return get(raw).workerPtr().vt.readLines(limits, allocator);
}
fn readonlyProvider(raw: *anyopaque) anyerror!@import("../../proto/ssh/shared_readonly_mailbox.zig").Provider {
    if (get(raw).torn_down) return error.SessionClosed;
    return get(raw).workerPtr().readonlyProvider();
}
fn notificationSnapshot(raw: *anyopaque, owner: identity.SessionHandle) anyerror!terminal.NotificationSnapshot {
    if (get(raw).torn_down) return error.SessionClosed;
    return get(raw).workerPtr().notificationSnapshot(owner);
}
fn execService(raw: *anyopaque, binding: session.ServiceHandle) anyerror!@import("../../ai/execbridge.zig").ExecBridge {
    if (get(raw).torn_down) return error.SessionClosed;
    return get(raw).workerPtr().execService(binding);
}
fn transferService(raw: *anyopaque, binding: session.ServiceHandle) anyerror!*@import("../../proto/ssh/shared_transfer_service.zig").Service {
    if (get(raw).torn_down) return error.SessionClosed;
    return get(raw).workerPtr().transferService(binding);
}
fn forwardService(raw: *anyopaque, binding: session.ServiceHandle, exit_index: ?usize) anyerror!*@import("../../proto/ssh/forward_service.zig").Service {
    if (get(raw).torn_down) return error.SessionClosed;
    return get(raw).workerPtr().forwardService(binding, exit_index);
}
fn captureExport(raw: *anyopaque, allocator: std.mem.Allocator) !@import("../../vt/timeline.zig").Timeline.ExportSnapshot {
    const runtime = get(raw);
    if (runtime.torn_down) return error.SessionClosed;
    return .{ .timeline = try runtime.worker.timelinePtr().snapshotWithAllocator(allocator), .cols = runtime.worker.options.cols, .rows = runtime.worker.options.rows };
}
fn exportTimeline(raw: *anyopaque, io: std.Io, dir: std.Io.Dir, path: []const u8) anyerror!void {
    return get(raw).exportTimeline(io, dir, path);
}
fn validateDocument(raw: *anyopaque, owner: identity.SessionHandle) !void {
    const native = get(raw);
    if (native.torn_down) return error.SessionClosed;
    const key = try native.worker.replay.notificationKey();
    if (key.owner != .session or !key.owner.session.eql(owner)) return error.StaleOwner;
}
fn documentSource(raw: *anyopaque) !terminal.Service {
    const native = get(raw);
    if (native.torn_down) return error.SessionClosed;
    const key = try native.worker.replay.notificationKey();
    if (key.owner != .session) return error.StaleOwner;
    native.document_source = .{ .adapter = &native.worker.vt, .owner = key.owner.session, .timeline = native.worker.timelinePtr(), .validator = .{ .context = native, .check = validateDocument } };
    return native.document_source.?.service();
}
fn osDetection(raw: *anyopaque) service.OsDetection {
    const worker = get(raw).workerPtr();
    return .{ .kind = worker.detected_os.load(.acquire), .pending = !worker.os_probe_finished.load(.acquire) };
}
fn sourceVersion(raw: *anyopaque) u64 {
    return get(raw).workerPtr().vt.snapshot().version;
}
fn captureAiSelection(raw: *anyopaque, allocator: std.mem.Allocator, owner: identity.SessionHandle, selected: @import("../../vt/engine.zig").Selection, version: u64) anyerror!@import("../../host/ai_terminal_selection.zig").Captured {
    return get(raw).workerPtr().captureAiSelection(allocator, owner, selected, version);
}
fn semanticSequence(raw: *anyopaque) u64 {
    return get(raw).workerPtr().vt.semanticSequence();
}
fn copyProjection(raw: *anyopaque, allocator: std.mem.Allocator) anyerror!@import("../../vt/snapshot.zig").Projection {
    return get(raw).workerPtr().vt.copyProjection(allocator);
}
fn hasJoined(raw: *anyopaque) bool {
    return get(raw).threadPtr().joined;
}
fn isStopping(raw: *anyopaque) bool {
    return get(raw).threadPtr().stop_requested.load(.acquire);
}
fn hasFailed(raw: *anyopaque) bool {
    return get(raw).threadPtr().hasFailed();
}
fn textSlot(raw: *anyopaque) *@import("../../vt/text_slot.zig").TextSlot {
    return get(raw).workerPtr().textSlot();
}
fn reconnectState(raw: *anyopaque) @import("../../vt/reconnect.zig").State {
    return get(raw).workerPtr().reconnectState();
}
fn inputFreeCapacity(raw: *anyopaque) usize {
    return get(raw).workerPtr().inputFreeCapacity();
}
fn requestResize(raw: *anyopaque, cols: u16, rows: u16) void {
    get(raw).workerPtr().requestResize(cols, rows);
}
fn searchViewportOffset(raw: *anyopaque) u64 {
    return get(raw).workerPtr().searchViewportOffset();
}
fn locateSearchRow(raw: *anyopaque, row: usize) void {
    get(raw).workerPtr().locateSearchRow(row);
}
fn copySelection(raw: *anyopaque, selection: @import("../../vt/engine.zig").Selection, allocator: std.mem.Allocator) anyerror![]u8 {
    return get(raw).workerPtr().copySelection(selection, allocator);
}
fn pushInputFrom(raw: *anyopaque, bytes: []const u8, source: @import("../../vt/reconnect_replay.zig").Source) anyerror!void {
    return get(raw).workerPtr().pushInputFrom(bytes, source);
}
fn allowsBufferedOrdinaryInput(raw: *anyopaque) bool {
    return get(raw).workerPtr().allowsBufferedOrdinaryInput();
}
fn discardBufferedInput(raw: *anyopaque) void {
    get(raw).workerPtr().discardBufferedInput();
}
fn notificationPublication(raw: *anyopaque, owner: identity.SessionHandle) anyerror!?NotificationPublication {
    const value = (try get(raw).workerPtr().notificationPublication(owner)) orelse return null;
    return .{ .text_generation = value.text_generation, .output_sequence = value.output_sequence, .at_tail = value.at_tail };
}
fn encodeKey(raw: *anyopaque, event: terminal.KeyEvent, allocator: std.mem.Allocator) ![]u8 {
    const native = get(raw);
    if (native.torn_down or !isConnected(raw)) return error.SessionClosed;
    return native.workerPtr().vt.encodeKey(event, allocator);
}
const vtable: service.Runtime.VTable = .{ .osDetection = osDetection, .documentSource = documentSource, .encodeKey = encodeKey, .releaseStep = releaseStep, .cleanupReleased = cleanupReleased, .reconnectSnapshot = reconnectSnapshot, .requestReconnect = requestReconnect, .acknowledgeAttached = acknowledgeAttached, .isAttached = isAttached, .isConnected = isConnected, .markAttached = markAttached, .setScrollbackLimit = setScrollbackLimit, .setInputBufferEnabled = setInputBufferEnabled, .copyCwd = copyCwd, .requestCurrentDirectory = requestCurrentDirectory, .searchText = searchText, .readLines = readLines, .readonlyProvider = readonlyProvider, .notificationSnapshot = notificationSnapshot, .execService = execService, .transferService = transferService, .forwardService = forwardService, .exportTimeline = exportTimeline, .captureExport = captureExport, .sourceVersion = sourceVersion, .captureAiSelection = captureAiSelection, .semanticSequence = semanticSequence, .copyProjection = copyProjection, .hasJoined = hasJoined, .isStopping = isStopping, .hasFailed = hasFailed, .textSlot = textSlot, .reconnectState = reconnectState, .inputFreeCapacity = inputFreeCapacity, .requestResize = requestResize, .searchViewportOffset = searchViewportOffset, .locateSearchRow = locateSearchRow, .copySelection = copySelection, .pushInputFrom = pushInputFrom, .allowsBufferedOrdinaryInput = allowsBufferedOrdinaryInput, .discardBufferedInput = discardBufferedInput, .notificationPublication = notificationPublication };
