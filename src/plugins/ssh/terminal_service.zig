//! SSH transport facade for the same native TerminalSurface used by Local.
//! UI state lives here; the SSH worker retains socket, PTY, replay and VT ownership.
const std = @import("std");
const terminal = @import("../../host/terminal_service.zig");
const Binding = @import("../../host/session_host.zig").ServiceHandle;
const Owner = @import("../../host/identity.zig").SessionHandle;
const Native = @import("../../ui/session_runtime.zig").SessionRuntime;
const ReadSource = @import("../../ui/terminal_document_source.zig").Source;
const encoder = @import("../../vt/ghostty_input.zig");

pub const Provider = struct {
    native: *Native,
    source: ReadSource,
    registered_binding: ?Binding = null,
    input_sequence: u64 = 0,
    geometry: terminal.Geometry,
    pending_geometry: ?terminal.Geometry = null,
    applied_theme: ?terminal.Theme = null,
    pending_paste: ?struct { bytes: []u8, offset: usize = 0, sequence: u64, mode: u64 } = null,
    pub fn deinit(self: *Provider) void {
        if (self.pending_paste) |p| self.native.allocator.free(p.bytes);
        self.pending_paste = null;
    }

    pub fn init(native: *Native, owner: Owner) Provider {
        const state = native.worker.vt.snapshot();
        return .{ .native = native, .source = .{ .adapter = &native.worker.vt, .owner = owner, .timeline = native.worker.timelinePtr() }, .geometry = .{ .revision = 1, .cols = state.cols, .rows = state.rows } };
    }
    /// The domain host supplies the actual live binding after ready. The
    /// pre-ready renderer's document binding never becomes AI authority.
    pub fn bind(self: *Provider, binding: Binding) !void {
        if (binding.kind != .terminal or binding.binding_id == 0 or binding.binding_generation != self.source.owner.generation or
            binding.resource_owner != .session or !binding.resource_owner.session.eql(self.source.owner) or
            binding.origin_session == null or !binding.origin_session.?.eql(self.source.owner)) return error.StaleBinding;
        if (self.registered_binding) |current| if (!current.eql(binding)) return error.StaleBinding;
        self.registered_binding = binding;
    }
    pub fn service(self: *Provider) terminal.Service {
        return .{ .binding = self.registered_binding orelse self.source.service().binding, .context = self, .vtable = &vtable };
    }
    fn get(raw: *anyopaque, binding: Binding) !*Provider {
        const self: *Provider = @ptrCast(@alignCast(raw));
        if (self.native.torn_down) return error.SessionClosed;
        if (!self.service().binding.eql(binding)) return error.StaleOwner;
        const operation = try self.native.worker.replay.notificationKey();
        if (operation.owner != .session or !operation.owner.session.eql(self.source.owner)) return error.StaleOwner;
        return self;
    }
    fn writable(self: *Provider) bool {
        return self.native.worker.reconnect.currentState() == .connected and self.native.worker.presentation_attached.load(.acquire);
    }
    fn acceptsInput(self: *Provider) bool {
        return self.writable() or self.native.worker.allowsBufferedOrdinaryInput();
    }
    fn ended(self: *Provider) bool {
        const state = self.native.reconnectSnapshot() orelse return false;
        return state.phase == .ended;
    }
    fn updateGeometry(self: *Provider, cols: u16, rows: u16) void {
        if (self.pending_geometry) |pending| if (pending.cols == cols and pending.rows == rows) {
            self.geometry = pending;
            self.pending_geometry = null;
        };
    }
    fn status(raw: *anyopaque, binding: Binding) !terminal.Status {
        const self = try get(raw, binding);
        const state = try self.native.worker.vt.trySnapshot();
        self.updateGeometry(state.cols, state.rows);
        // A lost transport cannot acknowledge its queued resize. Retain the
        // actual final grid so that theme/read-only frames remain available.
        if (!self.writable()) if (self.pending_geometry) |pending| {
            self.geometry = .{ .revision = pending.revision, .cols = state.cols, .rows = state.rows };
            self.pending_geometry = null;
        };
        return .{ .owner = self.source.owner, .writable = self.acceptsInput(), .eof_seen = self.ended(), .geometry = self.geometry, .output_sequence = state.output_sequence, .bell_count = state.bell_count, .pending_input_bytes = self.native.worker.input.pending() + if (self.pending_paste) |p| p.bytes.len - p.offset else @as(usize, 0), .mode_revision = state.mode_revision, .modes = state.modes, .applied_theme_revision = if (self.applied_theme) |t| t.revision else 0 };
    }
    fn snapshot(raw: *anyopaque, binding: Binding, allocator: std.mem.Allocator) !terminal.TerminalSnapshot {
        const self = try get(raw, binding);
        if (self.native.worker.text.structured.load(.acquire)) {
            const frame = try self.native.worker.text.projections.acquire();
            defer frame.release();
            // Only live status may acknowledge a resize: an older frame can
            // have the same dimensions as a newer, still pending request.
            // After acknowledgement, wait for cells matching that geometry.
            if (self.pending_geometry != null or frame.projection.cols != self.geometry.cols or frame.projection.rows != self.geometry.rows) return error.WorkerBusy;
            const projection = try frame.projection.clone(allocator);
            return .{ .owner = self.source.owner, .output_sequence = projection.output_sequence, .geometry_revision = self.geometry.revision, .input_revision = self.input_sequence, .read_only = !self.acceptsInput(), .eof_seen = self.ended(), .projection = projection, .applied_theme_revision = projection.theme_revision };
        }
        var projection = try self.native.worker.vt.tryCopyProjection(allocator);
        errdefer projection.deinit(allocator);
        _ = try get(raw, binding);
        self.updateGeometry(projection.cols, projection.rows);
        return .{ .owner = self.source.owner, .output_sequence = self.native.worker.vt.snapshot().output_sequence, .geometry_revision = self.geometry.revision, .input_revision = self.input_sequence, .read_only = !self.acceptsInput(), .eof_seen = self.ended(), .projection = projection, .applied_theme_revision = if (self.applied_theme) |t| t.revision else 0 };
    }
    fn gate(self: *Provider, sequence: u64, mode_revision: u64) !void {
        if (!self.acceptsInput()) return error.SessionNotWritable;
        if (self.pending_paste != null) return error.InputFull;
        if (sequence <= self.input_sequence) return error.StaleInput;
        if (mode_revision != self.native.worker.vt.mode_revision) return error.StaleMode;
        if (self.native.worker.vt.modes.keyboard_disabled) return error.KeyboardDisabled;
    }
    // Hold the adapter lock across mode validation, Ghostty encoding and replay
    // admission. A mode change cannot turn an encoded key into stale input.
    fn lock(self: *Provider) !void {
        if (!self.native.worker.vt.mutex.tryLock()) return error.WorkerBusy;
    }
    fn submit(self: *Provider, sequence: u64, bytes: []const u8) !terminal.Submission {
        // Native clicks and modifier-only events can encode no PTY input.
        // Acknowledge their sequence without invalidating the clean prompt.
        if (bytes.len == 0) {
            self.input_sequence = sequence;
            return .{ .input_sequence = sequence, .queued_bytes = 0 };
        }
        const execution_locked = try self.native.worker.lockOrdinaryExecutionInput();
        defer if (execution_locked) self.native.worker.execution_mutex.unlock();
        self.native.worker.text.timing.accepted(sequence, self.native.worker.input.write_index.load(.acquire) + bytes.len);
        if (bytes.len != 0) self.native.worker.replay.submit(&self.native.worker.input, bytes, if (self.writable()) .application else .ordinary, @import("../../vt/reconnect_replay.zig").InputMode.from(self.native.worker.vt.modes)) catch |err| return if (err == error.Full) error.InputFull else err;
        self.input_sequence = sequence;
        return .{ .input_sequence = sequence, .queued_bytes = bytes.len };
    }
    fn write(raw: *anyopaque, binding: Binding, request: terminal.WriteRequest) !terminal.Submission {
        const self = try get(raw, binding);
        try self.lock();
        defer self.native.worker.vt.mutex.unlock();
        try self.gate(request.input_sequence, request.mode_revision);
        return self.submit(request.input_sequence, request.bytes);
    }
    fn key(raw: *anyopaque, binding: Binding, request: terminal.KeyRequest) !terminal.Submission {
        const self = try get(raw, binding);
        try self.lock();
        defer self.native.worker.vt.mutex.unlock();
        try self.gate(request.input_sequence, request.mode_revision);
        const bytes = try self.native.worker.vt.encodeKeyLocked(request.event, self.native.allocator);
        defer self.native.allocator.free(bytes);
        return self.submit(request.input_sequence, bytes);
    }
    fn mouse(raw: *anyopaque, binding: Binding, request: terminal.MouseRequest) !terminal.Submission {
        const self = try get(raw, binding);
        if (!self.writable()) return error.SessionNotWritable;
        try self.lock();
        defer self.native.worker.vt.mutex.unlock();
        try self.gate(request.input_sequence, request.mode_revision);
        if (request.geometry_revision != self.geometry.revision or self.pending_geometry != null) return error.StaleGeometry;
        const bytes = try encoder.mouse(self.native.worker.vt.terminal, request.event, self.native.allocator);
        defer self.native.allocator.free(bytes);
        return self.submit(request.input_sequence, bytes);
    }
    fn resize(raw: *anyopaque, binding: Binding, geometry: terminal.Geometry) !void {
        const self = try get(raw, binding);
        if (!self.writable()) return error.SessionNotWritable;
        if (geometry.revision <= self.geometry.revision) return error.StaleGeometry;
        self.pending_geometry = geometry;
        self.native.worker.requestResize(geometry.cols, geometry.rows);
    }
    fn theme(raw: *anyopaque, binding: Binding, value: terminal.Theme) !void {
        const self = try get(raw, binding);
        if (self.applied_theme) |old| {
            if (value.revision < old.revision) return error.StaleTheme;
            if (value.revision == old.revision) {
                if (!std.meta.eql(old, value)) return error.ConflictingTheme;
                return;
            }
        }
        // Adapter serializes appearance updates with VT feed/capture. There
        // is no UI access to the worker's socket or raw-output consumer.
        try self.lock();
        defer self.native.worker.vt.mutex.unlock();
        try self.native.worker.vt.setThemeLocked(value);
        self.native.worker.text.requestProjection();
        self.applied_theme = value;
    }
    fn textSlot(raw: *anyopaque, binding: Binding) !*@import("../../vt/text_slot.zig").TextSlot {
        return (try get(raw, binding)).native.worker.textSlot();
    }
    fn receipt(raw: *anyopaque, binding: Binding) !?terminal.WriteReceipt {
        const self = try get(raw, binding);
        if (self.pending_paste) |*p| {
            const state = try self.native.worker.vt.trySnapshot();
            if (!self.writable() or state.mode_revision != p.mode) {
                const sequence = p.sequence;
                const mode = p.mode;
                self.deinit();
                return .{ .input_sequence = sequence, .mode_revision = mode, .consumed_bytes = 0, .state = .failed, .failure = .stale_mode };
            }
            const count = @min(p.bytes.len - p.offset, self.native.worker.input.freeCapacity());
            if (count > 0) {
                try self.lock();
                defer self.native.worker.vt.mutex.unlock();
                const execution_locked = try self.native.worker.lockOrdinaryExecutionInput();
                defer if (execution_locked) self.native.worker.execution_mutex.unlock();
                if (p.mode != self.native.worker.vt.mode_revision) return error.WorkerBusy;
                self.native.worker.replay.submit(&self.native.worker.input, p.bytes[p.offset..][0..count], .application, .{}) catch |err| return if (err == error.Full) error.WorkerBusy else err;
                p.offset += count;
            }
            if (p.offset == p.bytes.len) self.deinit();
        }
        // Replay owns actual delivery accounting. Queue admission is never
        // reported as transport completion.
        return null;
    }
    fn read(_: *anyopaque, _: Binding, _: []u8) !terminal.Read {
        return error.RawOutputUnavailable;
    }
    fn preparePaste(raw: *anyopaque, binding: Binding, allocator: std.mem.Allocator, text: []const u8) !terminal.Paste {
        const self = try get(raw, binding);
        const decision = (terminal.PastePolicy{}).inspect(text);
        if (decision == .reject or text.len == 0) return error.InvalidPaste;
        if (!self.writable()) return error.SessionNotWritable;
        return .{ .binding = binding, .input_revision = self.input_sequence, .mode_revision = (try self.native.worker.vt.trySnapshot()).mode_revision, .text = try allocator.dupe(u8, text), .requires_confirmation = decision == .confirm };
    }
    fn commitPaste(raw: *anyopaque, binding: Binding, paste: terminal.Paste, sequence: u64, confirmed: bool) !terminal.Submission {
        const self = try get(raw, binding);
        if (!paste.binding.eql(binding) or paste.input_revision != self.input_sequence) return error.StaleInput;
        const decision = (terminal.PastePolicy{}).inspect(paste.text);
        if (decision == .reject or paste.text.len == 0) return error.InvalidPaste;
        if (decision == .confirm and !confirmed) return error.ConfirmationRequired;
        try self.lock();
        defer self.native.worker.vt.mutex.unlock();
        try self.gate(sequence, paste.mode_revision);
        const wrapped = self.native.worker.vt.modes.bracketed_paste;
        const bytes = if (wrapped) try std.mem.concat(self.native.allocator, u8, &.{ "\x1b[200~", paste.text, "\x1b[201~" }) else try self.native.allocator.dupe(u8, paste.text);
        errdefer self.native.allocator.free(bytes);
        // Paste admission owns input just like a key/write. Keep the same
        // execution guard through the pending payload and sequence update.
        const execution_locked = try self.native.worker.lockOrdinaryExecutionInput();
        defer if (execution_locked) self.native.worker.execution_mutex.unlock();
        self.pending_paste = .{ .bytes = bytes, .sequence = sequence, .mode = paste.mode_revision };
        self.input_sequence = sequence;
        return .{ .input_sequence = sequence, .queued_bytes = bytes.len };
    }
    fn searchSnapshot(raw: *anyopaque, binding: Binding, allocator: std.mem.Allocator) !terminal.SearchSnapshot {
        const self = try get(raw, binding);
        return self.source.service().searchSnapshot(allocator);
    }
    fn contentQuery(raw: *anyopaque, binding: Binding, request: terminal.ContentRequest, allocator: std.mem.Allocator) !terminal.ContentCapture {
        const self = try get(raw, binding);
        return self.source.adapter.contentQuery(self.source.owner, request, allocator);
    }
    fn createAnchor(raw: *anyopaque, binding: Binding, point: terminal.Point) !terminal.Anchor {
        const self = try get(raw, binding);
        return self.source.service().createAnchor(point);
    }
    fn resolveAnchor(raw: *anyopaque, binding: Binding, anchor: terminal.Anchor) !?terminal.AnchorPosition {
        const self = try get(raw, binding);
        return self.source.service().resolveAnchor(anchor);
    }
    fn releaseAnchor(raw: *anyopaque, binding: Binding, anchor: terminal.Anchor) !void {
        const self = try get(raw, binding);
        return self.source.service().releaseAnchor(anchor);
    }
    fn selectionText(raw: *anyopaque, binding: Binding, selected: terminal.Selection, allocator: std.mem.Allocator, limit: usize) ![]u8 {
        const self = try get(raw, binding);
        return self.source.service().selectionText(selected, allocator, limit);
    }
    fn scroll(raw: *anyopaque, binding: Binding, value: terminal.Scroll) !void {
        const self = try get(raw, binding);
        try self.source.service().scroll(value);
        self.native.worker.text.requestProjection();
    }
    fn lines(raw: *anyopaque, binding: Binding, limits: terminal.LineLimits, allocator: std.mem.Allocator) !terminal.Lines {
        const self = try get(raw, binding);
        return self.source.service().readLines(limits, allocator);
    }
    fn applicationRecord(raw: *anyopaque, binding: Binding, record: terminal.ApplicationRecord) !void {
        const self = try get(raw, binding);
        return self.source.service().recordApplication(record);
    }
    fn recordingDisplay(raw: *anyopaque, binding: Binding, display: @import("../../vt/recording_manifest.zig").Display) !void {
        const self = try get(raw, binding);
        try self.native.setDisplay(display);
    }
    fn executionSnapshot(raw: *anyopaque, binding: Binding) !terminal.execution.Snapshot {
        const self = try get(raw, binding);
        if (self.native.worker.execution == null and self.native.worker.shell_execution == null) return .{ .owner = self.source.owner, .failure = "IntegrationUnavailable" };
        return self.native.worker.executionSnapshot();
    }
    fn commandHistorySnapshot(raw: *anyopaque, binding: Binding, allocator: std.mem.Allocator) !terminal.CommandHistorySnapshot {
        const self = try get(raw, binding);
        const worker = self.native.worker;
        if (!worker.native_mutex.tryLock()) return error.WorkerBusy;
        defer worker.native_mutex.unlock();
        if (!worker.execution_mutex.tryLock()) return error.WorkerBusy;
        defer worker.execution_mutex.unlock();
        var result = try worker.timeline.commandHistorySnapshot(allocator);
        errdefer result.deinit(allocator);
        result.owner = self.source.owner;
        if (worker.recording_id.valid()) result.recording_id = std.fmt.bytesToHex(worker.recording_id.bytes, .lower);
        if (worker.recording_generations.items.len != 0) {
            const generation = worker.recording_generations.items[worker.recording_generations.items.len - 1];
            if (generation.session_id != @backingInt(self.source.owner.session_id) or generation.session_generation != self.source.owner.generation) return error.StaleOwner;
            result.recording_generation = generation.recording_generation;
        }
        const recording_failure: ?[]const u8 = if (worker.execution_recording) |recording| recording.failure else null;
        const failure: ?[]const u8 = self.native.recording_manifest_failure orelse recording_failure orelse
            if (!worker.recording_id.valid() or worker.recording_generations.items.len == 0) "RecordingUnavailable" else if (worker.recording_generation_failed) "RecordingDegraded" else if (worker.io.timeline == null) "RecordingDisabled" else if (result.partial) "CommandHistoryCapacity" else null;
        result.failure = if (failure) |value| try allocator.dupe(u8, value) else null;
        result.partial = result.partial or failure != null;
        result.persistent = failure == null;
        if (self.ended()) for (result.records) |*record| if (record.value.state == .running) {
            record.value.state = .unknown;
        };
        return result;
    }
    fn recordingIdentity(raw: *anyopaque, binding: Binding) !terminal.RecordingIdentity {
        const self = try get(raw, binding);
        const worker = self.native.worker;
        // Same order as the IO owner: native lock, then execution mailbox.
        // The runtime and Service teardown remain on this controller thread.
        if (!worker.native_mutex.tryLock()) return error.WorkerBusy;
        defer worker.native_mutex.unlock();
        if (!worker.execution_mutex.tryLock()) return error.WorkerBusy;
        defer worker.execution_mutex.unlock();
        if (self.native.recording_manifest_failure) |failure| return .{ .owner = self.source.owner, .failure = failure };
        if (worker.recording_generations.items.len == 0 or worker.recording_generation_failed or !worker.recording_id.valid()) return .{ .owner = self.source.owner, .failure = "RecordingUnavailable" };
        const generation = worker.recording_generations.items[worker.recording_generations.items.len - 1];
        if (generation.session_id != @backingInt(self.source.owner.session_id) or generation.session_generation != self.source.owner.generation) return error.StaleOwner;
        if (worker.io.timeline == null) return .{ .owner = self.source.owner, .failure = "RecordingDisabled" };
        const failure = if (worker.execution_recording) |recording| recording.failure else null;
        return .{ .owner = self.source.owner, .recording_id = std.fmt.bytesToHex(worker.recording_id.bytes, .lower), .recording_generation = generation.recording_generation, .available = failure == null, .failure = failure };
    }
    fn executionRequest(raw: *anyopaque, binding: Binding, request: terminal.execution.Request) !void {
        const self = try get(raw, binding);
        if (self.pending_paste != null) return error.InputConflict;
        return self.native.worker.executionRequest(request);
    }
    fn executionRenew(raw: *anyopaque, binding: Binding, grant: terminal.execution.Grant) !void {
        const self = try get(raw, binding);
        return self.native.worker.executionRenew(grant);
    }
    fn executionRevoke(raw: *anyopaque, binding: Binding, grant: terminal.execution.Grant, takeover: bool) !void {
        const self = try get(raw, binding);
        return self.native.worker.executionRevoke(grant, takeover);
    }
    fn executionInput(raw: *anyopaque, binding: Binding, request: terminal.execution.InputRequest) !terminal.execution.InputReceipt {
        const self = try get(raw, binding);
        if (self.pending_paste != null) return error.InputConflict;
        return self.native.worker.executionInput(request);
    }
    fn executionOutput(raw: *anyopaque, binding: Binding, id: @import("../../host/identity.zig").ExecutionId, allocator: std.mem.Allocator, cursor: u64, max_bytes: usize) !terminal.execution.Output {
        const self = try get(raw, binding);
        return self.native.worker.readExecutionOutput(id, allocator, cursor, max_bytes);
    }
    const vtable: terminal.Service.VTable = .{ .command_history_snapshot = commandHistorySnapshot, .recording_identity = recordingIdentity, .content_query = contentQuery, .recording_display = recordingDisplay, .execution_snapshot = executionSnapshot, .execution_request = executionRequest, .execution_renew = executionRenew, .execution_revoke = executionRevoke, .execution_output = executionOutput, .execution_input = executionInput, .write = write, .resize = resize, .read = read, .receipt = receipt, .status = status, .text_slot = textSlot, .snapshot = snapshot, .prepare_paste = preparePaste, .commit_paste = commitPaste, .key = key, .mouse = mouse, .create_anchor = createAnchor, .resolve_anchor = resolveAnchor, .release_anchor = releaseAnchor, .selection_text = selectionText, .scroll = scroll, .read_lines = lines, .theme = theme, .search_snapshot = searchSnapshot, .application_record = applicationRecord };
};

test "SSH terminal provider preserves the registered binding and rejects a different owner" {
    const owner: Owner = .{ .session_id = @fromBackingInt(7), .generation = 3 };
    var provider: Provider = .{ .native = undefined, .source = .{ .adapter = undefined, .owner = owner }, .geometry = .{ .revision = 1, .cols = 80, .rows = 24 } };
    const provisional = provider.service().binding;
    var registered = provisional;
    registered.binding_id = 47;
    try provider.bind(registered);
    try std.testing.expect(provider.service().binding.eql(registered));
    try std.testing.expect(!provider.service().binding.eql(provisional));
    try std.testing.expectError(error.StaleBinding, provider.bind(provisional));
    var stale = registered;
    stale.resource_owner = .{ .session = .{ .session_id = owner.session_id, .generation = owner.generation + 1 } };
    try std.testing.expectError(error.StaleBinding, provider.bind(stale));
    stale = registered;
    stale.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, provider.bind(stale));
    stale = registered;
    stale.kind = .exec;
    try std.testing.expectError(error.StaleBinding, provider.bind(stale));
    stale = registered;
    stale.origin_session = null;
    try std.testing.expectError(error.StaleBinding, provider.bind(stale));
    try std.testing.expect(provider.service().binding.eql(registered));
}

// No socket or UI surrogate: exercise the production Provider, Ghostty mode
// snapshot, replay admission and shell lease with a small real byte queue.
const PasteFixture = struct {
    const Worker = @import("../../vt/ssh_worker.zig").SshWorker;
    const a = std.testing.allocator;
    worker: Worker = undefined,
    native: Native = undefined,
    provider: Provider = undefined,
    fn init(self: *@This()) !void {
        const owner: Owner = .{ .session_id = @fromBackingInt(71), .generation = 1 };
        self.worker.execution = null;
        self.worker.shell_execution = @import("../../vt/ssh_shell_execution.zig").Bridge.init(a, owner);
        self.worker.execution_mutex = .unlocked;
        self.worker.shell_initializer_chunks = &.{};
        self.worker.startup_pending = .init(false);
        self.worker.presentation_attached = .init(true);
        self.worker.reconnect = try @import("../../vt/reconnect.zig").Machine.init(1, &.{1});
        self.worker.replay = try @import("../../vt/reconnect_replay.zig").Replay.init(a, 32);
        self.worker.replay.configure(.{ .owner = .{ .session = owner }, .operation_id = 1, .attempt_id = 1 }, true, true);
        self.worker.input = try @import("../../vt/input_queue.zig").InputQueue.init(a, 8);
        self.worker.vt = try @import("../../vt/ghostty_adapter.zig").Adapter.init(a, 3, 80);
        self.native.allocator = a;
        self.native.worker = &self.worker;
        self.native.torn_down = false;
        self.provider = Provider.init(&self.native, owner);
    }
    fn deinit(self: *@This()) void {
        self.provider.deinit();
        self.worker.shell_execution.?.deinit();
        self.worker.input.deinit(a);
        self.worker.replay.deinit();
        self.worker.vt.destroy();
    }
    fn acquire(self: *@This()) !terminal.execution.Grant {
        return self.worker.shell_execution.?.lease.acquire(.{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = self.worker.shell_execution.?.lease.input_epoch, .ownership_revision = 1, .command = "true", .command_hash = terminal.execution.digest("true") }, 1);
    }
};

test "SSH paste lease rejects prepared commit without pending bytes or sequence and never replays after handoff" {
    var f: PasteFixture = .{};
    try f.init();
    defer f.deinit();
    const service = f.provider.service();
    var paste = try service.preparePaste(std.testing.allocator, "NEVER_ADMITTED_PASTE");
    defer paste.deinit(std.testing.allocator);
    _ = try f.acquire();
    const epoch = f.worker.shell_execution.?.lease.input_epoch;
    try std.testing.expectError(error.TerminalControlled, service.commitPaste(paste, 1, false));
    try std.testing.expectEqual(@as(u64, 0), f.provider.input_sequence);
    try std.testing.expect(f.provider.pending_paste == null);
    try std.testing.expectEqual(@as(usize, 0), f.worker.input.pending());
    try std.testing.expectEqual(epoch, f.worker.shell_execution.?.lease.input_epoch);
    var candidate = try service.preparePaste(std.testing.allocator, "NEVER_PREPARED");
    defer candidate.deinit(std.testing.allocator);
    try std.testing.expectEqual(epoch, f.worker.shell_execution.?.lease.input_epoch);
    f.worker.shell_execution.?.lease.revoke(false);
    try std.testing.expect(try service.takeWriteReceipt() == null);
    try std.testing.expectEqual(@as(usize, 0), f.worker.input.pending());
}

test "SSH paste lease preserves accepted partial bytes and blocks a new execution" {
    var f: PasteFixture = .{};
    try f.init();
    defer f.deinit();
    const service = f.provider.service();
    const epoch = f.worker.shell_execution.?.lease.input_epoch;
    var paste = try service.preparePaste(std.testing.allocator, "partial-paste");
    defer paste.deinit(std.testing.allocator);
    try std.testing.expectEqual(epoch, f.worker.shell_execution.?.lease.input_epoch);
    const submitted = try service.commitPaste(paste, 1, false);
    try std.testing.expectEqual(paste.text.len, submitted.queued_bytes);
    try std.testing.expect(f.worker.shell_execution.?.lease.input_epoch > epoch);
    try std.testing.expect(try service.takeWriteReceipt() == null);
    try std.testing.expectEqual(@as(usize, 8), f.provider.pending_paste.?.offset);
    try std.testing.expectError(error.InputConflict, service.executionRequest(.{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = f.worker.shell_execution.?.lease.input_epoch, .ownership_revision = 1, .command = "true", .command_hash = terminal.execution.digest("true") }));
    var actual: [13]u8 = undefined;
    const first = f.worker.input.drain(actual[0..8]);
    try std.testing.expectEqualStrings("partial-", first);
    try std.testing.expect(try service.takeWriteReceipt() == null);
    const rest = f.worker.input.drain(actual[8..]);
    try std.testing.expectEqualStrings("paste", rest);
    try std.testing.expectEqualStrings(paste.text, &actual);
    try std.testing.expect(f.provider.pending_paste == null);
}
