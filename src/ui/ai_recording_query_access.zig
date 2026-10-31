//! Per-request recording content access, bridging UI metadata capture to worker
//! archive IO. A discovered recording ID alone is never content authority.
//!
//! Lifecycle/concurrency contract:
//! - init/captureUi/captureClosedReceipts/captureSelectedHistory run on the UI
//!   thread before the request worker starts, with no archive/filesystem IO.
//! - execute is called serially by that request's worker; it owns path/grant
//!   storage and performs resolver/checksum/decoder IO outside the UI lock.
//! - validateContext only reads immutable context plus the cancellation flag.
//! - the application keeps the supplied Archive directory valid until the
//!   worker first executes (when Access opens its own directory handle).
//! - join the old worker before cancel/deinit/replacing Access or its grants.
//!   Within the SAME Task, beginQuiescentCapture is also permitted only during
//!   a controller UI exchange that proves the worker is blocked; it never runs
//!   concurrently with execute.
//!   Access and its owned strings never carry into another Task. A later Task
//!   captures its own valid sources and same-conversation/binding close receipts.
//! - expireIdle uses tryLock and only bounded reader teardown; call from the
//!   worker/maintenance path. It never resolves/scans/decodes a recording.
const std = @import("std");
const host = @import("../ai/host_tools.zig");
const queries = @import("../ai/host_terminal_queries.zig");
const identity = @import("../host/identity.zig");
const terminal = @import("../host/terminal_service.zig");
const archive_mod = @import("../vt/session_archive.zig");
const backend_mod = @import("../ai/host_recording_queries.zig");
const grant_helpers = @import("ai_host_recording_queries.zig");
const max_candidates = 128;
const Candidate = struct {
    owner: identity.SessionHandle,
    id: [32]u8,
    generation: u64,
    origin: enum { captured_source, explicit_history_selection },
    manifest_path: ?[]const u8 = null,
    manifest_revision: u64 = 0,
};

pub const Access = struct {
    arena: std.heap.ArenaAllocator,
    context: host.Context,
    backend: backend_mod.Backend,
    candidates: std.ArrayList(Candidate) = .empty,
    grants: std.ArrayList(backend_mod.Grant) = .empty,
    owned_dir: ?std.Io.Dir = null,
    worker_started: bool = false,
    candidate_limit_reached: bool = false,
    cancelled: std.atomic.Value(bool) = .init(false),
    worker_mutex: std.atomic.Mutex = .unlocked,

    /// Does not open/read the archive. Archive.dir is borrowed until the first
    /// authorized worker call; the main application must keep it alive then.
    pub fn init(allocator: std.mem.Allocator, archive: archive_mod.Archive, context: host.Context) !Access {
        try context.validate();
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .context = context, .backend = .{ .archive = archive } };
    }
    pub fn validateContext(self: *const Access, context: host.Context) !void {
        try context.validate();
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (!self.context.eql(context)) return error.ScopeChanged;
    }
    /// Trusted controller only, at a proven quiescent UI exchange: the request
    /// worker is blocked and cannot execute Access until this call and capture
    /// complete. Same-context refresh preserves valid pagination; changed
    /// binding/grant revisions cancel old cursors before rebinding this Task's
    /// already captured recording authority. A new Task/CID requires new init.
    pub fn beginQuiescentCapture(self: *Access, context: host.Context) !void {
        try context.validate();
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (!self.context.conversation_id.eql(context.conversation_id) or !self.context.task_id.eql(context.task_id)) return error.ScopeChanged;
        if (!self.context.eql(context)) {
            self.backend.cancel(self.context);
            self.backend.grants = &.{};
            self.grants.clearRetainingCapacity();
            self.context = context;
        }
        self.worker_started = false;
    }
    fn captureReady(self: *const Access) !void {
        try self.validateContext(self.context);
        if (self.worker_started) return error.RecordingCaptureClosed;
    }
    fn appendCandidate(self: *Access, candidate: Candidate) !void {
        for (self.candidates.items) |existing| if (existing.owner.eql(candidate.owner) and existing.generation == candidate.generation and std.mem.eql(u8, &existing.id, &candidate.id)) return;
        if (self.candidates.items.len >= max_candidates) {
            self.candidate_limit_reached = true;
            return;
        }
        try self.candidates.append(self.arena.allocator(), candidate);
    }

    /// Main-thread only. `bridge` is the request's real ui/ai_tools.Bridge;
    /// only its captured children AND captured content scope can contribute.
    /// app is ApplicationHost. No directory/catalog/model reference is read.
    pub fn captureUi(self: *Access, app: anytype, roster: ?*@import("group_model.zig").Roster, bridge: anytype) !void {
        try self.captureReady();
        const captured = bridge.captured_scope orelse return error.ScopeChanged;
        if (!captured.owner.eql(self.context.binding)) return error.ScopeChanged;
        for (bridge.children.items) |child| {
            const owner = child.owner;
            _ = captured.validate(&.{@backingInt(owner.session_id)}) catch continue;
            const tab = for (app.workspace.tabs.items) |item| {
                if (item.content_owner == .session and item.content_owner.session.eql(owner)) break item;
            } else continue;
            if (tab.closing or tab.failed or tab.archived or tab.owned_pending) continue;
            if (self.context.binding == .group) {
                const group = (roster orelse return error.ScopeChanged).findById(std.math.cast(u32, self.context.binding.group) orelse return error.ScopeChanged) orelse return error.ScopeChanged;
                const member = for (group.members.items) |item| {
                    if (item.active and item.pane_id == tab.id) break true;
                } else false;
                if (!member or app.workspace.groupClosing(group.id)) continue;
            }
            const manifest = app.sessions.manifestFor(owner) orelse continue;
            if (!manifest.integration.ai) continue;
            const content_allowed = for (manifest.tools) |tool| {
                if (std.mem.eql(u8, tool.definition_id, "read_terminal")) break true;
            } else false;
            if (!content_allowed) continue;
            const available = app.sessions.queryService(owner, .terminal);
            if (available != .available) continue;
            const service: terminal.Service = if (tab.terminal) |view| if (view.terminal_surface) |surface| blk: {
                if (!surface.owner.eql(owner)) continue;
                break :blk surface.service;
            } else if (tab.runtime) |runtime| runtime.terminalService() catch continue else continue else if (tab.runtime) |runtime| runtime.terminalService() catch continue else continue;
            if (!service.binding.eql(available.available) or !app.sessions.bindingIsLive(service.binding)) continue;
            try self.captureService(owner, service);
        }
    }
    /// Existing host close receipts form the bounded provenance index. A new
    /// Task may read its own conversation/binding's sealed exact generation;
    /// no archive listing or removed live session can populate this path.
    pub fn captureClosedReceipts(self: *Access, app: anytype) !void {
        try self.captureReady();
        for (app.deferred_closes.items) |close| {
            if (!@import("../ai/host_queries.zig").sameHistoricalBinding(close.context, self.context) or close.snapshot.state != .closed) continue;
            const state = app.sessions.queryState(close.handle) orelse continue;
            if (state.lifecycle != .closed) continue;
            const id = close.retained_metadata.recording_id orelse continue;
            const generation = close.retained_metadata.recording_generation;
            if (generation == 0) continue;
            try self.appendCandidate(.{ .owner = close.handle, .id = id, .generation = generation, .origin = .captured_source });
        }
    }
    /// Shared with captureUi after its exact content permission checks. Kept
    /// private so model arguments cannot install a snapshot or grant.
    fn captureService(self: *Access, owner: identity.SessionHandle, service: terminal.Service) !void {
        if (service.binding.kind != .terminal or service.binding.resource_owner != .session or !service.binding.resource_owner.session.eql(owner)) return;
        if (service.vtable.recording_identity != null) {
            const recording = service.recordingIdentity() catch return;
            if (!recording.owner.eql(owner) or !recording.available) return;
            const id = recording.recording_id orelse return;
            try self.appendCandidate(.{ .owner = owner, .id = id, .generation = recording.recording_generation, .origin = .captured_source });
            return;
        }
        if (service.vtable.execution_snapshot == null) return;
        const facts = service.executionSnapshot() catch return;
        if (!facts.owner.eql(owner) or facts.recording_generation == 0) return;
        const id = facts.recording_id orelse return;
        _ = identity.RecordingId.parse(&id) catch return;
        try self.appendCandidate(.{ .owner = owner, .id = id, .generation = facts.recording_generation, .origin = .captured_source });
    }
    /// Call only for an explicitly user-selected descriptor within the binding
    /// or a captured source. Selection itself never grants access outside it;
    /// metadata listing and model recording_ref lookup cannot install authority.
    pub fn captureSelectedHistory(self: *Access, descriptor: archive_mod.Descriptor, generation: u64) !void {
        try self.captureReady();
        const grant = try grant_helpers.selectedHistory(self.context, descriptor, generation);
        const in_scope = switch (self.context.binding) {
            .session => |id| id == @backingInt(grant.owner.session_id),
            .group => for (self.candidates.items) |candidate| {
                if (candidate.origin == .captured_source and candidate.owner.eql(grant.owner)) break true;
            } else false,
        };
        if (!in_scope) return error.TargetNotAuthorized;
        try self.appendCandidate(.{ .owner = grant.owner, .id = grant.recording_id, .generation = grant.recording_generation, .manifest_path = try self.arena.allocator().dupe(u8, grant.manifest_path), .manifest_revision = grant.manifest_revision, .origin = .explicit_history_selection });
    }
    /// Main-thread preflight, before archive IO. Candidate ownership comes
    /// only from trusted capture, never from a model-supplied recording ID.
    pub const CandidateIdentity = struct { owner: identity.SessionHandle, id: [32]u8, generation: u64 };
    pub fn candidateIdentity(self: *const Access, invocation: host.Invocation) !CandidateIdentity {
        try self.validateContext(invocation.context);
        const request = try queries.parse(invocation.tool_id, invocation.arguments);
        if (request.source != .recording) return error.TargetNotAuthorized;
        const ref = try queries.resolveRecording(invocation.context, request.source.recording);
        for (self.candidates.items) |candidate| if (candidate.generation == ref.generation and std.mem.eql(u8, &candidate.id, &ref.id)) return .{ .owner = candidate.owner, .id = candidate.id, .generation = candidate.generation };
        return error.TargetNotAuthorized;
    }
    pub fn candidateOwner(self: *const Access, invocation: host.Invocation) !identity.SessionHandle {
        return (try self.candidateIdentity(invocation)).owner;
    }
    fn ownDirectory(self: *Access) !void {
        if (self.owned_dir != null) return;
        const dir = try self.backend.archive.dir.openDir(self.backend.archive.io, ".", .{ .follow_symlinks = false });
        self.owned_dir = dir;
        self.backend.archive.dir = dir;
        self.backend.archive.allocator = self.arena.child_allocator;
    }

    /// Worker only. Parse/source/context/candidate checks precede ANY IO. Only
    /// a trusted candidate ID reaches Archive.resolveRecord's bounded catalog.
    pub fn execute(self: *Access, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
        const request = try queries.parse(invocation.tool_id, invocation.arguments);
        try self.validateContext(invocation.context);
        if (invocation.authority != .conversation_context or request.source != .recording) return error.PermissionDenied;
        const ref = try queries.resolveRecording(invocation.context, request.source.recording);
        const candidate_index = for (self.candidates.items, 0..) |value, index| {
            if (value.generation == ref.generation and std.mem.eql(u8, &value.id, &ref.id)) break index;
        } else return if (self.candidate_limit_reached) error.RecordingGrantLimit else error.PermissionDenied;
        if (!self.worker_mutex.tryLock()) return error.RecordingQueryBusy;
        defer self.worker_mutex.unlock();
        self.worker_started = true;
        try self.ownDirectory();
        const exists = for (self.grants.items) |grant| {
            if (grant.recording_generation == ref.generation and std.mem.eql(u8, &grant.recording_id, &ref.id)) break true;
        } else false;
        if (!exists) try self.resolveGrant(candidate_index);
        self.backend.grants = self.grants.items;
        return self.backend.execute(invocation, allocator);
    }
    fn resolveGrant(self: *Access, candidate_index: usize) !void {
        const candidate = &self.candidates.items[candidate_index];
        // Only a captured host identity enters the resolver; the model's text
        // never grants catalog access or selects another owner/generation.
        var resolved = try self.backend.archive.resolveRecord(self.arena.child_allocator, .{ .recording_id = &candidate.id });
        defer resolved.deinit();
        const descriptor = resolved.descriptor;
        const doc = descriptor.document orelse return error.RecordingUnavailable;
        if (doc.state != .closed) return error.RecordingNotClosed;
        if (!std.mem.eql(u8, doc.recording_id, &candidate.id)) return error.StaleReference;
        const generation = for (doc.recording.generations) |value| {
            if (value.recording_generation == candidate.generation) break value;
        } else return error.StaleGeneration;
        if (generation.session_id != @backingInt(candidate.owner.session_id) or generation.session_generation != candidate.owner.generation) return error.StaleGeneration;
        const path = descriptor.manifest_path orelse return error.RecordingUnavailable;
        if (candidate.manifest_revision != 0 and candidate.manifest_revision != doc.manifest_revision) return error.StaleRecordingRevision;
        if (candidate.manifest_path) |captured_path| if (!std.mem.eql(u8, captured_path, path)) return error.StaleReference;
        if (candidate.manifest_path == null) {
            candidate.manifest_path = try self.arena.allocator().dupe(u8, path);
            candidate.manifest_revision = doc.manifest_revision;
        }
        const grant: backend_mod.Grant = .{ .context = self.context, .owner = candidate.owner, .recording_id = candidate.id, .recording_generation = candidate.generation, .manifest_path = candidate.manifest_path.?, .manifest_revision = doc.manifest_revision, .origin = if (candidate.origin == .explicit_history_selection) .explicit_history_selection else .captured_source };
        try self.grants.append(self.arena.allocator(), grant);
    }
    /// Nonblocking maintenance. No resolve/checksum/decoder IO occurs here;
    /// bounded descriptor closes release expired readers' pinned files.
    pub fn expireIdle(self: *Access) void {
        if (!self.worker_mutex.tryLock()) return;
        defer self.worker_mutex.unlock();
        self.backend.expireIdle();
    }
    /// Caller must have joined the old worker. Future calls reject the old
    /// Task even if its recording ID also appears in another request.
    pub fn cancel(self: *Access) void {
        self.cancelled.store(true, .release);
        self.backend.cancel(self.context);
        self.backend.grants = &.{};
    }
    /// Caller must have joined the worker; close leases before the owned dir.
    pub fn deinit(self: *Access) void {
        self.cancel();
        self.backend.deinit();
        if (self.owned_dir) |dir| dir.close(self.backend.archive.io);
        self.arena.deinit();
    }
};

const test_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(9), .generation = 3 };
const test_recording: [32]u8 = "11111111111111111111111111111111".*;
fn testContext() host.Context {
    return .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 9 }, .binding_revision = 1, .grant_revision = 1 };
}
test "recording_access candidate budget preserves other queries and rejects overflow before IO" {
    var access = try Access.init(std.testing.allocator, .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = undefined }, testContext());
    defer access.deinit();
    for (0..max_candidates + 1) |index| {
        var raw: [16]u8 = @splat(0);
        std.mem.writeInt(u64, raw[0..8], index + 1, .little);
        try access.appendCandidate(.{ .owner = .{ .session_id = @fromBackingInt(index + 1), .generation = 1 }, .id = std.fmt.bytesToHex(raw, .lower), .generation = 2, .origin = .captured_source });
    }
    try std.testing.expect(access.candidate_limit_reached);
    try std.testing.expectEqual(max_candidates, access.candidates.items.len);
    var arguments = try testArguments();
    defer arguments.deinit();
    try std.testing.expectError(error.RecordingGrantLimit, access.execute(testInvocation(arguments.value), std.testing.allocator));
    try std.testing.expect(access.owned_dir == null and !access.worker_started);
}
const TestFacts = struct {
    owner: identity.SessionHandle = test_owner,
    recording_id: ?[32]u8 = test_recording,
    generation: u64 = 2,
    calls: usize = 0,
    fn snapshot(raw: *anyopaque, _: @import("../host/session_host.zig").ServiceHandle) !terminal.execution.Snapshot {
        const self: *TestFacts = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .owner = self.owner, .recording_id = self.recording_id, .recording_generation = self.generation };
    }
};
const TestSurface = struct { owner: identity.SessionHandle, service: terminal.Service };
const TestView = struct { terminal_surface: ?*TestSurface };
const TestRuntime = struct {
    fn terminalService(_: *@This()) !terminal.Service {
        return error.Unavailable;
    }
};
const TestTab = struct { content_owner: identity.ContentOwner = .{ .session = test_owner }, id: u64 = 9, closing: bool = false, failed: bool = false, archived: bool = false, owned_pending: bool = false, terminal: ?*TestView, runtime: ?*TestRuntime = null };
const TestWorkspace = struct {
    tabs: struct { items: []const *TestTab },
    fn groupClosing(_: *@This(), _: u32) bool {
        return false;
    }
};
const TestSessions = struct {
    service: terminal.Service,
    manifest: struct { integration: struct { ai: bool = true } = .{}, tools: []const struct { definition_id: []const u8 } = &.{.{ .definition_id = "read_terminal" }} } = .{},
    fn manifestFor(self: *@This(), owner: identity.SessionHandle) ?*@TypeOf(@as(@This(), undefined).manifest) {
        return if (owner.eql(test_owner)) &self.manifest else null;
    }
    fn queryService(self: *@This(), _: identity.SessionHandle, _: enum { terminal }) union(enum) { available: @import("../host/session_host.zig").ServiceHandle, unavailable } {
        return .{ .available = self.service.binding };
    }
    fn bindingIsLive(self: *@This(), binding: @import("../host/session_host.zig").ServiceHandle) bool {
        return self.service.binding.eql(binding);
    }
};
const TestApp = struct { workspace: *TestWorkspace, sessions: TestSessions };
const TestChild = struct { owner: identity.SessionHandle };
const TestBridge = struct { captured_scope: ?@import("../ai/tool_scope.zig").Scope, children: struct { items: []const *TestChild } };
fn testService(facts: *TestFacts, hooks: *terminal.Service.VTable) terminal.Service {
    var source: @import("terminal_document_source.zig").Source = .{ .adapter = undefined, .owner = test_owner };
    var service = source.service();
    hooks.* = service.vtable.*;
    hooks.execution_snapshot = TestFacts.snapshot;
    service.context = facts;
    service.vtable = hooks;
    return service;
}

test "recording_access UI captures only exact Bridge children content permission without archive IO" {
    var facts: TestFacts = .{};
    var hooks: terminal.Service.VTable = undefined;
    const service = testService(&facts, &hooks);
    var surface: TestSurface = .{ .owner = test_owner, .service = service };
    var view: TestView = .{ .terminal_surface = &surface };
    var tab: TestTab = .{ .terminal = &view };
    var workspace: TestWorkspace = .{ .tabs = .{ .items = &.{&tab} } };
    var app: TestApp = .{ .workspace = &workspace, .sessions = .{ .service = service } };
    var child: TestChild = .{ .owner = test_owner };
    const scope: @import("../ai/tool_scope.zig").Scope = .{ .owner = testContext().binding, .members = .{ .ids = .{9} ++ @as([15]u64, @splat(0)), .len = 1 } };
    var bridge: TestBridge = .{ .captured_scope = scope, .children = .{ .items = &.{&child} } };
    // Undefined IO/dir would fault if UI capture touched the filesystem.
    var access = try Access.init(std.testing.allocator, .{ .allocator = std.testing.allocator, .io = undefined, .dir = undefined }, testContext());
    defer access.deinit();
    try access.captureUi(&app, null, &bridge);
    try std.testing.expectEqual(@as(usize, 1), facts.calls);
    try std.testing.expectEqual(@as(usize, 1), access.candidates.items.len);
    try std.testing.expectEqual(@as(usize, 0), access.grants.items.len);
    try std.testing.expect(access.owned_dir == null);
    var denied = try Access.init(std.testing.allocator, .{ .allocator = std.testing.allocator, .io = undefined, .dir = undefined }, testContext());
    defer denied.deinit();
    app.sessions.manifest.tools = &.{};
    try denied.captureUi(&app, null, &bridge);
    try std.testing.expectEqual(@as(usize, 0), denied.candidates.items.len);
    try std.testing.expectEqual(@as(usize, 1), facts.calls);
    app.sessions.manifest.tools = &.{.{ .definition_id = "read_terminal" }};
    child.owner.generation = 4;
    try denied.captureUi(&app, null, &bridge);
    try std.testing.expectEqual(@as(usize, 0), denied.candidates.items.len);
    child.owner = test_owner;
    bridge.captured_scope.?.members.len = 0;
    try denied.captureUi(&app, null, &bridge);
    try std.testing.expectEqual(@as(usize, 0), denied.candidates.items.len);
    try std.testing.expectEqual(@as(usize, 1), facts.calls);
}

const TestRecord = struct {
    tmp: std.testing.TmpDir,
    archive: archive_mod.Archive,
    fn init() !TestRecord {
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "logs/history");
        const cast = "{\"version\":2,\"width\":40,\"height\":2}\n[0,\"o\",\"controlled closed recording\\r\\n\"]\n";
        const file = try tmp.dir.createFile(std.testing.io, "logs/history/access.cast", .{ .read = true });
        try file.writeStreamingAll(std.testing.io, cast);
        const checksum = try archive_mod.manifest.fingerprint(std.testing.io, file, cast.len);
        file.close(std.testing.io);
        try archive_mod.manifest.save(a, std.testing.io, tmp.dir, "logs/history/access.session.json", .{ .archive_key = "22222222222222222222222222222222", .recording_id = &test_recording, .manifest_revision = 7, .source_kind = .ssh, .started_ms = 1, .ended_ms = 2, .state = .closed, .coverage = .complete, .recording = .{ .generations = &.{.{ .recording_generation = 2, .session_id = 9, .session_generation = 3, .initial_cols = 40, .initial_rows = 2, .receive_time_origin = 1, .baselines = &.{.{ .event_sequence = 0, .raw_offset = 0, .kind = .initial_empty }} }} }, .files = &.{.{ .path = "logs/history/access.cast", .kind = .cast, .committed_length = cast.len, .checksum = &checksum }} });
        return .{ .tmp = tmp, .archive = .{ .allocator = a, .io = std.testing.io, .dir = tmp.dir } };
    }
    fn deinit(self: *TestRecord) void {
        self.tmp.cleanup();
    }
};
fn testArguments() !std.json.Parsed(std.json.Value) {
    const a = std.testing.allocator;
    const ref = try queries.recordingRef(a, testContext(), test_recording, 2);
    defer a.free(ref);
    const wire = try std.fmt.allocPrint(a, "{{\"recording_ref\":\"{s}\"}}", .{ref});
    defer a.free(wire);
    return std.json.parseFromSlice(std.json.Value, a, wire, .{ .allocate = .alloc_always });
}
fn testInvocation(args: std.json.Value) host.Invocation {
    return .{ .context = testContext(), .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "access", .tool_id = "host.read_terminal", .arguments = args, .arguments_json = "{}", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
}

test "recording_access worker resolves trusted source owns grant path and isolates Task context" {
    var record = try TestRecord.init();
    defer record.deinit();
    var access = try Access.init(std.testing.allocator, record.archive, testContext());
    defer access.deinit();
    var facts: TestFacts = .{};
    var hooks: terminal.Service.VTable = undefined;
    try access.captureService(test_owner, testService(&facts, &hooks));
    const args = try testArguments();
    defer args.deinit();
    const Worker = struct {
        access: *Access,
        invocation: host.Invocation,
        result: ?host.Result = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.result = self.access.execute(self.invocation, std.testing.allocator) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var worker: Worker = .{ .access = &access, .invocation = testInvocation(args.value) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |failure| return failure;
    var result = worker.result orelse return error.MissingResult;
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.blocks[0].structured, "controlled closed recording") != null);
    try std.testing.expect(access.owned_dir != null);
    try std.testing.expectEqual(@as(usize, 1), access.grants.items.len);
    try std.testing.expectEqual(@as(u64, 7), access.grants.items[0].manifest_revision);
    try std.testing.expectEqualStrings("logs/history/access.session.json", access.grants.items[0].manifest_path);
    var other = testContext();
    other.task_id.bytes[0] = 3;
    try std.testing.expectError(error.ScopeChanged, access.validateContext(other));
    try std.testing.expectError(error.RecordingCaptureClosed, access.captureReady());
    access.cancel();
    try std.testing.expectError(error.Cancelled, access.execute(testInvocation(args.value), std.testing.allocator));
    var next_task = try Access.init(std.testing.allocator, record.archive, other);
    defer next_task.deinit();
    var next_invocation = testInvocation(args.value);
    next_invocation.context = other;
    try std.testing.expectError(error.PermissionDenied, next_task.execute(next_invocation, std.testing.allocator));
    try std.testing.expect(next_task.owned_dir == null);
}

test "recording_access selected history copies descriptor bytes and guessed IDs cannot trigger IO" {
    var record = try TestRecord.init();
    defer record.deinit();
    var access = try Access.init(std.testing.allocator, record.archive, testContext());
    defer access.deinit();
    var resolved = try record.archive.resolveRecord(std.testing.allocator, .{ .recording_id = &test_recording });
    try access.captureSelectedHistory(resolved.descriptor, 2);
    resolved.deinit();
    const args = try testArguments();
    defer args.deinit();
    var result = try access.execute(testInvocation(args.value), std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.blocks[0].structured, "controlled closed recording") != null);
    var denied = try Access.init(std.testing.allocator, .{ .allocator = std.testing.allocator, .io = undefined, .dir = undefined }, testContext());
    defer denied.deinit();
    try std.testing.expectError(error.PermissionDenied, denied.execute(testInvocation(args.value), std.testing.allocator));
    try std.testing.expect(denied.owned_dir == null);
}

test "recording_access quiescent capture preserves same context cursor and fences changed revisions" {
    const a = std.testing.allocator;
    var record = try TestRecord.init();
    defer record.deinit();
    var access = try Access.init(a, record.archive, testContext());
    defer access.deinit();
    var facts: TestFacts = .{};
    var hooks: terminal.Service.VTable = undefined;
    try access.captureService(test_owner, testService(&facts, &hooks));
    const ref = try queries.recordingRef(a, testContext(), test_recording, 2);
    defer a.free(ref);
    const wire = try std.fmt.allocPrint(a, "{{\"recording_ref\":\"{s}\",\"range_kind\":\"lines\",\"start_line\":0,\"end_line\":1,\"max_lines\":1}}", .{ref});
    defer a.free(wire);
    const args = try std.json.parseFromSlice(std.json.Value, a, wire, .{});
    defer args.deinit();
    var first = try access.execute(testInvocation(args.value), a);
    defer first.deinit(a);
    const first_json = try std.json.parseFromSlice(std.json.Value, a, first.blocks[0].structured, .{});
    defer first_json.deinit();
    const cursor = first_json.value.object.get("next_cursor").?.string;
    const cursor_wire = try std.fmt.allocPrint(a, "{{\"recording_ref\":\"{s}\",\"range_kind\":\"cursor\",\"cursor\":\"{s}\",\"max_lines\":1}}", .{ ref, cursor });
    defer a.free(cursor_wire);
    const cursor_args = try std.json.parseFromSlice(std.json.Value, a, cursor_wire, .{});
    defer cursor_args.deinit();
    try access.beginQuiescentCapture(testContext());
    try std.testing.expectEqual(@as(usize, 1), access.grants.items.len);
    var continued = try access.execute(testInvocation(cursor_args.value), a);
    defer continued.deinit(a);
    var again = try access.execute(testInvocation(args.value), a);
    defer again.deinit(a);
    const again_json = try std.json.parseFromSlice(std.json.Value, a, again.blocks[0].structured, .{});
    defer again_json.deinit();
    const old_token = again_json.value.object.get("next_cursor").?.string;
    const old_wire = try std.fmt.allocPrint(a, "{{\"recording_ref\":\"{s}\",\"range_kind\":\"cursor\",\"cursor\":\"{s}\",\"max_lines\":1}}", .{ ref, old_token });
    defer a.free(old_wire);
    const old_args = try std.json.parseFromSlice(std.json.Value, a, old_wire, .{});
    defer old_args.deinit();
    var changed = testContext();
    changed.binding_revision += 1;
    try access.beginQuiescentCapture(changed);
    try std.testing.expectEqual(@as(usize, 0), access.grants.items.len);
    try std.testing.expectEqual(@as(usize, 1), access.candidates.items.len);
    var old_invocation = testInvocation(old_args.value);
    old_invocation.context = changed;
    try std.testing.expectError(error.CursorExpired, access.execute(old_invocation, a));
    var next = changed;
    next.task_id.bytes[0] = 5;
    try std.testing.expectError(error.ScopeChanged, access.beginQuiescentCapture(next));
    try access.validateContext(changed);
}

test "recording_access absent idle recording ID stays unauthorized until true service capture" {
    var access = try Access.init(std.testing.allocator, .{ .allocator = std.testing.allocator, .io = undefined, .dir = undefined }, testContext());
    defer access.deinit();
    var facts: TestFacts = .{ .recording_id = null };
    var hooks: terminal.Service.VTable = undefined;
    const service = testService(&facts, &hooks);
    try access.captureService(test_owner, service);
    try std.testing.expectEqual(@as(usize, 0), access.candidates.items.len);
    const args = try testArguments();
    defer args.deinit();
    try std.testing.expectError(error.PermissionDenied, access.execute(testInvocation(args.value), std.testing.allocator));
    try std.testing.expect(access.owned_dir == null);
    try access.beginQuiescentCapture(testContext());
    facts.recording_id = test_recording;
    try access.captureService(test_owner, service);
    try std.testing.expectEqual(@as(usize, 1), access.candidates.items.len);
    try std.testing.expect(access.owned_dir == null);
}

test "current-tab recording candidate checks reject unknown IDs before archive IO" {
    const a = std.testing.allocator;
    var access = try Access.init(a, .{ .allocator = a, .io = undefined, .dir = undefined }, testContext());
    defer access.deinit();
    const args = try testArguments();
    defer args.deinit();
    try std.testing.expectError(error.TargetNotAuthorized, access.candidateOwner(testInvocation(args.value)));
    try access.appendCandidate(.{ .owner = test_owner, .id = test_recording, .generation = 2, .origin = .captured_source });
    try std.testing.expect((try access.candidateOwner(testInvocation(args.value))).eql(test_owner));
    try std.testing.expect(access.owned_dir == null);
}

test "current-tab recording history selection cannot grant an external session" {
    var record = try TestRecord.init();
    defer record.deinit();
    var context = testContext();
    context.binding = .{ .session = 999 };
    var access = try Access.init(std.testing.allocator, record.archive, context);
    defer access.deinit();
    var resolved = try record.archive.resolveRecord(std.testing.allocator, .{ .recording_id = &test_recording });
    defer resolved.deinit();
    try std.testing.expectError(error.TargetNotAuthorized, access.captureSelectedHistory(resolved.descriptor, 2));
    try std.testing.expectEqual(@as(usize, 0), access.candidates.items.len);
    try std.testing.expect(access.owned_dir == null);
}
