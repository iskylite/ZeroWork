//! Bounded, immutable presentation facts copied after the tool worker joins.
//! Records are keyed by owner/turn/call and outlive the next provider request.
const std = @import("std");
const loop = @import("tool_loop.zig");
const scope = @import("tool_scope.zig");
const identity = @import("../host/identity.zig");
pub const Source = struct { owner: identity.SessionHandle, label: []const u8 };
pub const Target = struct { result: loop.TargetResult, source: ?identity.SessionHandle = null, label: []const u8 = "", operation_id: ?u64 = null };
pub const execution_projection = @import("execution_result_projection.zig");
pub const ExecutionProjection = execution_projection.Projection;
pub const ExecutionActionTarget = execution_projection.ActionTarget;
pub const HostFact = struct { status: @import("plugin_tools.zig").Status, receipt: @import("host_tools.zig").Receipt, content: []const u8 };
/// Presentation position survives view rebuilds and may outlive its source
/// record briefly while rollback disposes the old native tree.
pub const ScrollPositions = struct {
    pub const Slot = enum { body, command, stdout, stderr };
    pub const Offset = struct { x: f32 = 0, y: f32 = 0 };
    allocator: std.mem.Allocator,
    references: usize = 1,
    offsets: [4]Offset = @splat(.{}),
    pub fn create(allocator: std.mem.Allocator) !*ScrollPositions {
        const self = try allocator.create(ScrollPositions);
        self.* = .{ .allocator = allocator };
        return self;
    }
    pub fn retain(self: *ScrollPositions) void {
        self.references += 1;
    }
    pub fn release(self: *ScrollPositions) void {
        self.references -= 1;
        if (self.references == 0) self.allocator.destroy(self);
    }
};
pub const Record = struct {
    arena: std.heap.ArenaAllocator,
    owner: scope.Owner,
    turn_id: u64,
    call_id: []const u8,
    name: []const u8,
    arguments: []const u8,
    command: []const u8,
    arguments_hash: [32]u8,
    targets: []Target,
    host: ?HostFact = null,
    execution: ?ExecutionProjection = null,
    execution_view_initialized: bool = false,
    images: []const @import("image_attachments.zig").ContentRef = &.{},
    error_code: ?[]const u8 = null,
    error_status: ?loop.Status = null,
    dispatched: bool,
    total_elapsed_ms: ?u64 = null,
    decision: ?bool = null,
    expanded: bool = false,
    selected: usize = 0,
    scroll_positions: ?*ScrollPositions = null,
    test_id: [96]u8 = @splat(0),
    test_id_len: usize = 0,
    pub fn scrollPositions(self: *Record, allocator: std.mem.Allocator) !*ScrollPositions {
        if (self.scroll_positions == null) self.scroll_positions = try ScrollPositions.create(allocator);
        return self.scroll_positions.?;
    }
    pub fn deinit(self: *Record) void {
        if (self.scroll_positions) |positions| positions.release();
        self.scroll_positions = null;
        self.arena.deinit();
    }
    pub fn testId(self: *const Record) []const u8 {
        return self.test_id[0..self.test_id_len];
    }
    pub fn summary(self: *const Record, buffer: []u8) []const u8 {
        if (self.host) |fact| return switch (fact.status) {
            .succeeded => "成功",
            .failed => "失败",
            .rejected => "已拒绝",
            .cancelled_unsent => "已取消",
            .outcome_unknown => "结果待核实",
        };
        var succeeded: usize = 0;
        var unknown: usize = 0;
        var cancelled: usize = 0;
        var remote_unknown: usize = 0;
        for (self.targets) |target| {
            succeeded += @intFromBool(target.result.status == .succeeded);
            unknown += @intFromBool(target.result.status == .unknown or !target.result.local_released);
            remote_unknown += @intFromBool(target.result.remote_effect_unknown);
            cancelled += @intFromBool(target.result.status == .cancelled or target.result.status == .timed_out);
        }
        const label: []const u8 = if (unknown > 0 or self.error_status == .unknown) "结果待核实" else if (succeeded == self.targets.len and succeeded > 0) "成功" else if (succeeded > 0) "部分成功" else if (remote_unknown > 0) "已停止 / 远端后果待核实" else if (cancelled > 0) "已取消" else if (!self.dispatched) "未派发" else "失败 / 已拒绝";
        return if (self.targets.len <= 1) label else std.fmt.bufPrint(buffer, "{s} · {d}/{d}", .{ label, succeeded, self.targets.len }) catch label;
    }
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(*Record) = .empty,
    retained_bytes: usize = 0,
    pub const max_records = 128;
    pub const max_bytes = 16 * 1024 * 1024;
    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Store) void {
        for (self.records.items) |record| {
            for (record.images) |reference| {
                var owned = reference;
                owned.release();
            }
            record.deinit();
            self.allocator.destroy(record);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
    }
    fn releaseRecord(self: *Store, record: *Record) void {
        for (record.images) |ref| {
            var owned = ref;
            owned.release();
        }
        record.deinit();
        self.allocator.destroy(record);
    }
    fn recount(self: *Store) void {
        self.retained_bytes = 0;
        for (self.records.items) |record| {
            self.retained_bytes += record.name.len + record.arguments.len * 2 + record.call_id.len + 1024;
            if (record.host) |fact| self.retained_bytes += fact.content.len;
            if (record.execution) |execution| self.retained_bytes += execution.retainedBytes();
            for (record.targets) |target| self.retained_bytes += target.result.stdout.len + target.result.stderr.len + target.label.len + (if (target.result.cwd) |cwd| cwd.len else 0) + (if (target.result.error_code) |code| code.len else 0);
            for (record.images) |ref| if (ref.content()) |content| {
                self.retained_bytes += content.bytes.len + content.pixels.len;
            };
        }
    }
    pub fn keepTurns(self: *Store, messages: []const @import("assistant_store.zig").Message) void {
        var i = self.records.items.len;
        while (i > 0) {
            i -= 1;
            const record = self.records.items[i];
            var keep = false;
            for (messages) |m| if (m.turn) |turn| if (turn.id == record.turn_id) {
                keep = true;
                break;
            };
            if (!keep) self.releaseRecord(self.records.orderedRemove(i));
        }
        self.recount();
    }
    pub fn cloneTurns(self: *Store, messages: []const @import("assistant_store.zig").Message) !Store {
        var result = Store.init(self.allocator);
        errdefer result.deinit();
        try result.records.ensureTotalCapacity(self.allocator, self.records.items.len);
        for (self.records.items) |record| {
            var keep = false;
            for (messages) |m| if (m.turn) |turn| if (turn.id == record.turn_id) {
                keep = true;
                break;
            };
            if (!keep) continue;
            var targets: [scope.max_targets]loop.TargetResult = undefined;
            var sources: [scope.max_targets]Source = undefined;
            var count: usize = 0;
            for (record.targets, 0..) |target, i| {
                targets[i] = target.result;
                if (target.source) |owner| {
                    sources[count] = .{ .owner = owner, .label = target.label };
                    count += 1;
                }
            }
            const copy = try result.copyRecord(.{ .key = .{ .owner = record.owner, .turn_id = record.turn_id, .call_id = record.call_id }, .name = record.name, .arguments = record.arguments, .arguments_hash = record.arguments_hash, .dispatched = record.dispatched, .outcome = .{ .targets = targets[0..record.targets.len] } }, sources[0..count]);
            result.records.appendAssumeCapacity(copy);
            const a = copy.arena.allocator();
            copy.images = try a.dupe(@import("image_attachments.zig").ContentRef, record.images);
            for (copy.images) |ref| _ = ref.retain();
            copy.error_code = if (record.error_code) |code| try a.dupe(u8, code) else null;
            copy.error_status = record.error_status;
            if (record.host) |fact| copy.host = .{ .status = fact.status, .receipt = fact.receipt, .content = try a.dupe(u8, fact.content) };
            if (record.execution) |execution| copy.execution = try execution.clone(a);
            copy.execution_view_initialized = record.execution_view_initialized;
            copy.expanded = record.expanded;
            copy.selected = record.selected;
            if (record.scroll_positions) |positions| (try copy.scrollPositions(self.allocator)).offsets = positions.offsets;
            copy.total_elapsed_ms = record.total_elapsed_ms;
            copy.decision = record.decision;
            for (copy.targets, record.targets) |*target, original| target.operation_id = original.operation_id;
        }
        result.recount();
        return result;
    }
    /// Resolve the same execution's newest trusted observation without changing
    /// immutable call facts. Never correlate by active pane or small session ID.
    pub fn executionProjection(self: *const Store, record: *const Record) ?ExecutionProjection {
        const original = record.execution orelse return null;
        // Input receipts retain their own operation outcome. They neither
        // replace execution observations nor inherit another call's completion.
        if (original.input_result) return original;
        const id = original.execution_id orelse return original;
        var result = original;
        for (self.records.items) |other| if (other.execution) |candidate| {
            if (!candidate.input_result and candidate.execution_id != null and candidate.execution_id.?.eql(id) and candidate.conversation_id.eql(original.conversation_id) and candidate.task_id.eql(original.task_id)) result = candidate;
        };
        if (result.command == null) {
            for (self.records.items) |other| if (other.execution) |candidate| {
                if (candidate.command != null and candidate.execution_id != null and candidate.execution_id.?.eql(id) and candidate.conversation_id.eql(original.conversation_id) and candidate.task_id.eql(original.task_id)) {
                    result.command = candidate.command;
                    break;
                }
            };
        }
        if (result.target == null) result.target = original.target;
        if (result.target != null and result.target_label.len == 0) {
            for (self.records.items) |other| if (other.execution) |candidate| {
                if (candidate.target_label.len != 0 and candidate.target != null and candidate.target.?.eql(result.target.?) and candidate.execution_id != null and candidate.execution_id.?.eql(id) and candidate.conversation_id.eql(original.conversation_id) and candidate.task_id.eql(original.task_id)) {
                    result.target_label = candidate.target_label;
                    break;
                }
            };
        }
        return result;
    }
    fn contains(self: *const Store, owner: scope.Owner, turn_id: u64, call_id: []const u8) bool {
        for (self.records.items) |record| if (record.owner.eql(owner) and record.turn_id == turn_id and std.mem.eql(u8, record.call_id, call_id)) return true;
        return false;
    }
    pub fn countForOwner(self: *const Store, owner: scope.Owner) usize {
        var count: usize = 0;
        for (self.records.items) |record| if (record.owner.eql(owner)) {
            count += 1;
        };
        return count;
    }
    /// Called after worker.join(), or through an explicit closed-batch exchange
    /// that blocks the worker for the complete immutable read/deep-copy.
    /// Polling the mutable worker ledger without that exchange is forbidden.
    /// Capacity is preflighted for the entire ledger; failure retains the old
    /// Loop for inspection and must prevent starting a new request.
    pub fn capture(self: *Store, run: *const loop.Loop, sources: []const Source) !bool {
        var needed: usize = 0;
        var added: usize = 0;
        for (run.records.items) |record| {
            if (self.contains(record.key.owner, record.key.turn_id, record.key.call_id)) continue;
            added += 1;
            needed += record.name.len + record.arguments.len * 2 + record.key.call_id.len + 1024;
            if (record.host_result != null and execution_projection.supports(record.name)) needed += 4096;
            if (record.host_result == null and record.result_body != null and execution_projection.supports(record.name)) needed += record.result_body.?.len;
            if (record.host_result) |result| for (result.blocks) |block| {
                needed += switch (block) {
                    .text, .structured => |text| text.len * (if (execution_projection.supports(record.name)) @as(usize, 2) else 1) + 1,
                };
            };
            if (record.generic_results) |results| for (results) |result| for (result.blocks) |block| switch (block) {
                .text, .structured => |bytes| needed += bytes.len,
                .image_ref => |reference| if (reference.content()) |content| {
                    needed += content.bytes.len + content.pixels.len;
                },
            };
            if (record.outcome) |outcome| for (outcome.targets) |target| {
                needed += target.stdout.len + target.stderr.len + (if (target.cwd) |s| s.len else 0) + (if (target.error_code) |s| s.len else 0) + 128;
                for (sources) |source| if (@backingInt(source.owner.session_id) == target.session_id) {
                    needed += @min(source.label.len, 4096);
                    break;
                };
            };
        }
        if (added == 0) return false;
        if (self.records.items.len + added > max_records or needed > max_bytes -| self.retained_bytes) return error.ToolResultStoreCapacity;
        try self.records.ensureUnusedCapacity(self.allocator, added);
        const start = self.records.items.len;
        errdefer {
            for (self.records.items[start..]) |record| {
                for (record.images) |reference| {
                    var owned = reference;
                    owned.release();
                }
                record.deinit();
                self.allocator.destroy(record);
            }
            self.records.shrinkRetainingCapacity(start);
        }
        for (run.records.items) |record| {
            if (self.contains(record.key.owner, record.key.turn_id, record.key.call_id)) continue;
            const saved = try self.copyRecord(record, sources);
            self.records.appendAssumeCapacity(saved);
        }
        self.retained_bytes += needed;
        return true;
    }
    fn copyRecord(self: *Store, record: loop.Record, sources: []const Source) !*Record {
        const saved = try self.allocator.create(Record);
        errdefer self.allocator.destroy(saved);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const arguments = try a.dupe(u8, record.arguments);
        var command: []const u8 = arguments;
        const Args = struct { command: ?[]const u8 = null, path: ?[]const u8 = null };
        if (@import("plugin_tools.zig").legacyName(record.name)) {
            const parsed = std.json.parseFromSlice(Args, a, arguments, .{ .ignore_unknown_fields = true }) catch null;
            if (parsed) |json| if (json.value.command orelse json.value.path) |value| {
                command = try a.dupe(u8, value);
            };
        }
        var targets: []Target = &.{};
        var result_images: std.ArrayList(@import("image_attachments.zig").ContentRef) = .empty;
        var error_code: ?[]const u8 = null;
        var error_status: ?loop.Status = null;
        var host_fact: ?HostFact = null;
        if (record.outcome) |outcome| {
            const copied = try loop.Outcome.copy(a, outcome.targets);
            targets = try a.alloc(Target, copied.targets.len);
            for (copied.targets, targets) |result, *target| {
                target.* = .{ .result = result };
                for (sources) |source| if (@backingInt(source.owner.session_id) == result.session_id) {
                    target.source = source.owner;
                    var keep = @min(source.label.len, 4096);
                    while (keep > 0 and !std.unicode.utf8ValidateSlice(source.label[0..keep])) keep -= 1;
                    target.label = try a.dupe(u8, source.label[0..keep]);
                    break;
                };
            }
        } else if (record.generic_results) |results| {
            targets = try a.alloc(Target, results.len);
            for (results, targets) |result, *target| {
                var text: std.ArrayList(u8) = .empty;
                for (result.blocks) |block| switch (block) {
                    .text, .structured => |bytes| {
                        if (text.items.len != 0) try text.append(a, '\n');
                        try text.appendSlice(a, bytes);
                    },
                    .image_ref => |reference| try result_images.append(a, reference),
                };
                target.* = .{ .result = .{ .session_id = @backingInt(result.receipt.owner.session_id), .status = switch (result.status) {
                    .succeeded => .succeeded,
                    .failed => .failed,
                    .rejected => .rejected,
                    .cancelled_unsent => .cancelled,
                    .outcome_unknown => .unknown,
                }, .stdout = try text.toOwnedSlice(a), .local_released = result.receipt.local_released, .remote_effect_unknown = result.receipt.remote_effect_unknown }, .source = result.receipt.owner, .operation_id = result.receipt.operation_id };
                if (@import("plugin_tools.zig").legacyName(record.name)) for (result.blocks) |block| {
                    if (block != .structured) continue;
                    const original = std.json.parseFromSlice(loop.TargetResult, a, block.structured, .{ .allocate = .alloc_always }) catch continue;
                    target.result = original.value;
                    break;
                };
                for (sources) |source| if (source.owner.eql(result.receipt.owner)) {
                    target.label = try a.dupe(u8, source.label);
                    break;
                };
            }
        } else if (record.host_result) |result| {
            var text: std.ArrayList(u8) = .empty;
            for (result.blocks) |block| {
                if (text.items.len != 0) try text.append(a, '\n');
                try text.appendSlice(a, switch (block) {
                    .text, .structured => |bytes| bytes,
                });
            }
            host_fact = .{ .status = result.status, .receipt = result.receipt, .content = try text.toOwnedSlice(a) };
        } else if (record.result_body) |body| {
            const json = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch null;
            if (json) |value| if (value.value == .object) {
                if (value.value.object.get("status")) |status| if (status == .string) {
                    error_status = std.meta.stringToEnum(loop.Status, status.string);
                };
                if (value.value.object.get("error_code")) |code| if (code == .string) {
                    error_code = try a.dupe(u8, code.string);
                };
            };
            if (error_code == null) error_code = "ToolOutcomeUnavailable";
        }
        const call_id = try a.dupe(u8, record.key.call_id);
        const name = try a.dupe(u8, record.name);
        const captured_images = try result_images.toOwnedSlice(a);
        saved.* = .{ .arena = undefined, .images = captured_images, .owner = record.key.owner, .turn_id = record.key.turn_id, .call_id = call_id, .name = name, .arguments = arguments, .command = command, .arguments_hash = record.arguments_hash, .targets = targets, .host = host_fact, .error_code = error_code, .error_status = error_status, .dispatched = record.dispatched };
        const tag = try std.fmt.bufPrint(&saved.test_id, "ai.tool.result.{d}.{x}", .{ saved.turn_id, std.hash.Wyhash.hash(0, saved.call_id) });
        saved.test_id_len = tag.len;
        if (host_fact) |fact| {
            var invalid_receipt = false;
            if (execution_projection.supports(name)) if (record.result_body) |body| {
                const failure = std.json.parseFromSliceLeaky(struct { error_code: ?[]const u8 = null }, a, body, .{ .ignore_unknown_fields = true }) catch null;
                if (failure) |value| if (value.error_code) |code| {
                    invalid_receipt = std.mem.eql(u8, code, "InvalidHostToolResult");
                };
            };
            if (invalid_receipt) {
                saved.execution = try execution_projection.parseFailure(a, name, arguments, record.result_body, record.dispatched);
                if (saved.execution) |*execution| {
                    execution.call_status = if (record.dispatched) .outcome_unknown else .failed;
                    execution.remote_effect_unknown = record.dispatched;
                }
            } else saved.execution = try execution_projection.parse(a, name, arguments, fact.status, fact.receipt, fact.content);
            if (saved.execution) |*execution| if (execution.target) |target| {
                for (sources) |source| if (source.owner.eql(target)) {
                    var keep = @min(source.label.len, 4096);
                    while (keep > 0 and !std.unicode.utf8ValidateSlice(source.label[0..keep])) keep -= 1;
                    execution.target_label = try a.dupe(u8, source.label[0..keep]);
                    break;
                };
            };
        }
        if (saved.execution == null and record.host_result == null and record.generic_results == null and record.outcome == null) saved.execution = try execution_projection.parseFailure(a, name, arguments, record.result_body, record.dispatched);
        for (captured_images) |reference| _ = reference.retain();
        // Parsing can grow the arena. Transfer its final page chain only after
        // every projection allocation; a premature copy loses later pages.
        saved.arena = arena;
        return saved;
    }
};

test "host result snapshot retains exact content and receipt without a fake session target" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    defer store.deinit();
    const context: @import("host_tools.zig").Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = 7 }, .binding_revision = 2, .grant_revision = 1 };
    var run = loop.Loop.init(a, .{ .owner = context.binding, .members = .{} }, 4, .{});
    const aa = run.arena.allocator();
    const blocks = try a.alloc(@import("host_tools.zig").Block, 1);
    blocks[0] = .{ .structured = try a.dupe(u8, "{\"sessions\":[],\"source_revision\":42}") };
    try run.records.append(aa, .{ .key = .{ .owner = context.binding, .turn_id = 4, .call_id = "host-query" }, .name = "host__list_usessions", .arguments = "{}", .arguments_hash = @splat(1), .dispatched = true, .host_result = .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = context.conversation_id, .task_id = context.task_id, .operation_id = 5, .binding_revision = 2 } } });
    try std.testing.expect(try store.capture(&run, &.{}));
    run.deinit();
    const saved = store.records.items[0];
    try std.testing.expectEqual(@as(usize, 0), saved.targets.len);
    try std.testing.expect(saved.host.?.receipt.conversation_id.eql(context.conversation_id));
    try std.testing.expectEqualStrings("{\"sessions\":[],\"source_revision\":42}", saved.host.?.content);
    var buffer: [80]u8 = undefined;
    try std.testing.expectEqualStrings("成功", saved.summary(&buffer));
    var copy = try store.cloneTurns(&.{.{ .user = false, .text = @constCast(""), .turn = .{ .id = 4 } }});
    defer copy.deinit();
    try std.testing.expectEqualStrings(saved.host.?.content, copy.records.items[0].host.?.content);
    try std.testing.expectEqual(@as(u64, 5), copy.records.items[0].host.?.receipt.operation_id);
}

test "tool result snapshot owns all mixed facts after loop is destroyed and isolates owners" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    defer store.deinit();
    var run = loop.Loop.init(a, .{ .owner = .{ .group = 7 }, .members = .{} }, 4, .{});
    const aa = run.arena.allocator();
    const outcome = try loop.Outcome.copy(a, &.{ .{ .session_id = 101, .status = .succeeded, .transport = .local, .stdout = "LOCAL_REAL", .exit = 0 }, .{ .session_id = 102, .status = .cancelled, .transport = .ssh, .stdout = "PARTIAL_REAL", .stderr = "kept stderr", .local_released = true } });
    try run.records.append(aa, .{ .key = .{ .owner = .{ .group = 7 }, .turn_id = 4, .call_id = try aa.dupe(u8, "original-call") }, .name = "run_command", .arguments = "{\"session_ids\":[101,102],\"command\":\"sleep 10\"}", .arguments_hash = @splat(7), .dispatched = true, .outcome = outcome });
    try std.testing.expect(try store.capture(&run, &.{.{ .owner = .{ .session_id = @fromBackingInt(102), .generation = 9 }, .label = "SSH original@remote:22" }}));
    try std.testing.expect(!try store.capture(&run, &.{}));
    run.deinit();
    const record = store.records.items[0];
    try std.testing.expectEqualStrings("sleep 10", record.command);
    try std.testing.expectEqualStrings("PARTIAL_REAL", record.targets[1].result.stdout);
    try std.testing.expectEqualStrings("kept stderr", record.targets[1].result.stderr);
    try std.testing.expectEqual(@as(u64, 9), record.targets[1].source.?.generation);
    try std.testing.expect(record.targets[1].result.local_released);
    try std.testing.expectEqual(@as(usize, 0), store.countForOwner(.{ .session = 101 }));
    try std.testing.expectEqual(@as(usize, 1), store.countForOwner(.{ .group = 7 }));
    var summary: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, record.summary(&summary), "部分成功") != null);
}

fn appendExecutionFixture(run: *loop.Loop, context: @import("host_tools.zig").Context, call: []const u8, name: []const u8, arguments: []const u8, content: []const u8) !void {
    const a = std.testing.allocator;
    const blocks = try a.alloc(@import("host_tools.zig").Block, 1);
    blocks[0] = .{ .structured = try a.dupe(u8, content) };
    try run.records.append(run.arena.allocator(), .{ .key = .{ .owner = context.binding, .turn_id = 42, .call_id = call }, .name = name, .arguments = arguments, .arguments_hash = @splat(1), .dispatched = true, .host_result = .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = context.conversation_id, .task_id = context.task_id, .operation_id = 5, .binding_revision = 2 } } });
}

test "execution result projection preserves exact host identities output and latest receipt without altering call facts" {
    const a = std.testing.allocator;
    const terminal = @import("../host/terminal_execution.zig");
    var store = Store.init(a);
    defer store.deinit();
    const context: @import("host_tools.zig").Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 7 }, .binding_revision = 2, .grant_revision = 1 };
    const exec: identity.ExecutionId = .generate();
    const recording: identity.RecordingId = .generate();
    const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 9 };
    const reference = try std.fmt.allocPrint(a, "x1:{s}", .{std.fmt.bytesToHex(exec.bytes, .lower)});
    defer a.free(reference);
    const snapshot: terminal.Snapshot = .{ .owner = target, .execution_id = exec, .state = .running, .grant = .{ .execution_id = exec, .task_id = context.task_id, .fence = 8, .input_epoch = 3, .ownership_revision = 4 }, .recording_id = std.fmt.bytesToHex(recording.bytes, .lower), .elapsed_ms = 1234 };
    const initial = try std.json.Stringify.valueAlloc(a, .{ .execution_ref = reference, .snapshot = snapshot, .recording_ref = @as([]const u8, &std.fmt.bytesToHex(recording.bytes, .lower)), .output = "FIRST_REAL_OUTPUT\n", .output_available = true }, .{});
    defer a.free(initial);
    var run = loop.Loop.init(a, .{ .owner = context.binding, .members = .{} }, 42, .{});
    try appendExecutionFixture(&run, context, "initial-run", "host__run_uin_uterminal", "{\"command\":\"printf actual-command\"}", initial);
    try std.testing.expect(try store.capture(&run, &.{.{ .owner = target, .label = "original@production" }}));
    run.deinit();
    const original = store.records.items[0];
    const captured = original.execution.?;
    try std.testing.expect(captured.target.?.eql(target));
    try std.testing.expect(captured.execution_id.?.eql(exec));
    try std.testing.expect(captured.recording_id.?.eql(recording));
    try std.testing.expect(captured.canStop() and captured.canTakeover());
    try std.testing.expectEqualStrings("printf actual-command", captured.command.?);
    try std.testing.expectEqualStrings("FIRST_REAL_OUTPUT\n", captured.terminal_output);
    var completed_snapshot = snapshot;
    completed_snapshot.state = .sealed;
    completed_snapshot.grant = null;
    completed_snapshot.process = .{ .exit_code = 0, .foreground_finished = true };
    completed_snapshot.recording_settled = true;
    const completed = try std.json.Stringify.valueAlloc(a, .{ .execution_ref = reference, .snapshot = completed_snapshot, .output = "FINAL_REAL_OUTPUT\n", .output_available = true }, .{});
    defer a.free(completed);
    var later = loop.Loop.init(a, .{ .owner = context.binding, .members = .{} }, 42, .{});
    try appendExecutionFixture(&later, context, "latest-observation", "host.wait_execution", "{}", completed);
    try std.testing.expect(try store.capture(&later, &.{}));
    later.deinit();
    const latest = store.executionProjection(original).?;
    try std.testing.expectEqual(.sealed, latest.state.?);
    try std.testing.expectEqualStrings("FINAL_REAL_OUTPUT\n", latest.terminal_output);
    try std.testing.expectEqualStrings("printf actual-command", latest.command.?);
    try std.testing.expect(!latest.canStop() and !latest.canTakeover());
    try std.testing.expectEqualStrings("FIRST_REAL_OUTPUT\n", original.execution.?.terminal_output);
    try std.testing.expectEqualStrings(initial, original.host.?.content);
    var clone = try store.cloneTurns(&.{.{ .user = false, .text = @constCast(""), .turn = .{ .id = 42 } }});
    defer clone.deinit();
    try std.testing.expectEqualStrings("FINAL_REAL_OUTPUT\n", clone.executionProjection(clone.records.items[0]).?.terminal_output);
    try std.testing.expect(clone.records.items[0].execution.?.target.?.eql(target));
}

test "execution result projection missing invalid or cross-task identities never provide fabricated controls" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const receipt: @import("host_tools.zig").Receipt = .{ .conversation_id = .generate(), .task_id = .generate(), .operation_id = 5, .binding_revision = 1 };
    try std.testing.expect((try execution_projection.parse(aa, "host.list_sessions", "{}", .succeeded, receipt, "{}")) == null);
    const missing = (try execution_projection.parse(aa, "host.get_execution", "{}", .succeeded, receipt, "{\"state\":\"sealed\",\"execution_ref\":\"not-an-id\"}")).?;
    try std.testing.expect(missing.execution_id == null and missing.target == null and missing.recording_id == null and missing.process == null);
    try std.testing.expect(!missing.canStop() and !missing.canTakeover());
    try std.testing.expectEqualStrings("执行状态待核实", missing.statusLabel());
    const id: identity.ExecutionId = .generate();
    const other: identity.ExecutionId = .generate();
    const body = try std.json.Stringify.valueAlloc(a, .{ .execution_ref = try std.fmt.allocPrint(aa, "x1:{s}", .{std.fmt.bytesToHex(id.bytes, .lower)}), .snapshot = .{ .owner = identity.SessionHandle{ .session_id = @fromBackingInt(101), .generation = 9 }, .execution_id = other, .state = "running" } }, .{});
    defer a.free(body);
    const conflict = (try execution_projection.parse(aa, "host.run_in_terminal", "{}", .succeeded, receipt, body)).?;
    try std.testing.expect(conflict.execution_id == null and conflict.actionTarget() == null);
    var original: Record = .{ .arena = .init(a), .owner = .{ .group = 7 }, .turn_id = 1, .call_id = "original", .name = "host.get_execution", .arguments = "{}", .command = "{}", .arguments_hash = @splat(0), .targets = &.{}, .dispatched = true, .execution = missing };
    defer original.arena.deinit();
    original.execution.?.execution_id = id;
    var alien = original;
    alien.execution.?.task_id = .generate();
    alien.execution.?.state = .sealed;
    var records = Store.init(a);
    defer records.records.deinit(a);
    try records.records.append(a, &original);
    try records.records.append(a, &alien);
    try std.testing.expect(records.executionProjection(&original).?.state == null);
}

test "execution result without host receipt keeps actual rejection cancellation or unknown with no fabricated identities" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    defer store.deinit();
    var run = loop.Loop.init(a, .{ .owner = .{ .group = 7 }, .members = .{} }, 42, .{});
    defer run.deinit();
    const cid: identity.ConversationId = .generate();
    const task: identity.TaskId = .generate();
    inline for (.{ .{ "rejected", "ToolApprovalRejected" }, .{ "rejected", "CancelledBeforeDispatch" }, .{ "outcome_unknown", "WorkerUnavailable" } }, 0..) |source, index| {
        const body = try std.json.Stringify.valueAlloc(run.arena.allocator(), .{ .conversation_id = cid, .task_id = task, .status = source[0], .error_code = source[1] }, .{});
        const call = try std.fmt.allocPrint(run.arena.allocator(), "preflight-{d}", .{index});
        try run.records.append(run.arena.allocator(), .{ .key = .{ .owner = .{ .group = 7 }, .turn_id = 42, .call_id = call }, .name = "host.run_in_terminal", .arguments = "{\"command\":\"not-dispatched\",\"session_ref\":\"model-supplied-value\"}", .arguments_hash = @splat(0), .result_body = body });
    }
    try std.testing.expect(try store.capture(&run, &.{}));
    for (store.records.items, 0..) |record, index| {
        const projection = record.execution.?;
        try std.testing.expect(projection.conversation_id.eql(cid) and projection.task_id.eql(task));
        try std.testing.expect(projection.target == null and projection.execution_id == null and projection.recording_id == null and projection.process == null);
        try std.testing.expect(projection.actionTarget() == null and !projection.canStop() and !projection.canTakeover());
        try std.testing.expectEqualStrings("not-dispatched", projection.command.?);
        try std.testing.expectEqualStrings(([_][]const u8{ "未执行 · 已拒绝", "未派发 · 已取消", "结果待核实" })[index], projection.statusLabel());
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const absent = (try execution_projection.parseFailure(arena.allocator(), "host.wait_execution", "{}", null, false)).?;
    try std.testing.expect(!absent.conversation_id.valid() and !absent.task_id.valid() and absent.actionTarget() == null);
}

test "execution result invalid host receipt never becomes authority for an execution card action" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    defer store.deinit();
    var run = loop.Loop.init(a, .{ .owner = .{ .group = 7 }, .members = .{} }, 42, .{});
    defer run.deinit();
    const context: @import("host_tools.zig").Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 7 }, .binding_revision = 2, .grant_revision = 1 };
    const id: identity.ExecutionId = .generate();
    const body = try std.json.Stringify.valueAlloc(a, .{ .execution_ref = try std.fmt.allocPrint(run.arena.allocator(), "x1:{s}", .{std.fmt.bytesToHex(id.bytes, .lower)}), .snapshot = .{ .owner = identity.SessionHandle{ .session_id = @fromBackingInt(101), .generation = 9 }, .execution_id = id, .state = "running" } }, .{});
    defer a.free(body);
    try appendExecutionFixture(&run, context, "invalid-host-receipt", "host.run_in_terminal", "{}", body);
    run.records.items[0].host_result.?.receipt.binding_revision = 99;
    run.records.items[0].result_body = "{\"status\":\"failed\",\"error_code\":\"InvalidHostToolResult\"}";
    try std.testing.expect(try store.capture(&run, &.{}));
    const projection = store.records.items[0].execution.?;
    try std.testing.expect(projection.execution_id == null and projection.target == null and projection.actionTarget() == null);
    try std.testing.expectEqualStrings("结果待核实", projection.statusLabel());
    try std.testing.expect(!projection.canStop() and !projection.canTakeover());
}

test "tool result cloned scroll positions are independent and survive original store release" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    var store_alive = true;
    defer if (store_alive) store.deinit();
    var run = loop.Loop.init(a, .{ .owner = .{ .group = 7 }, .members = .{} }, 4, .{});
    defer run.deinit();
    try run.records.append(run.arena.allocator(), .{ .key = .{ .owner = .{ .group = 7 }, .turn_id = 4, .call_id = "position" }, .name = "read_terminal", .arguments = "{}", .arguments_hash = @splat(0), .dispatched = false });
    _ = try store.capture(&run, &.{});
    const original = store.records.items[0];
    original.selected = 1;
    const positions = try original.scrollPositions(a);
    positions.offsets[@backingInt(ScrollPositions.Slot.body)].y = 80;
    positions.offsets[@backingInt(ScrollPositions.Slot.stdout)].x = 45;
    var clone = try store.cloneTurns(&.{.{ .user = false, .text = @constCast(""), .turn = .{ .id = 4 } }});
    defer clone.deinit();
    const copied = clone.records.items[0];
    try std.testing.expect(copied.scroll_positions.? != positions);
    positions.offsets[0].y = 0;
    store.deinit();
    store_alive = false;
    try std.testing.expectEqual(@as(usize, 1), copied.selected);
    try std.testing.expectEqual(@as(f32, 80), copied.scroll_positions.?.offsets[0].y);
    try std.testing.expectEqual(@as(f32, 45), copied.scroll_positions.?.offsets[@backingInt(ScrollPositions.Slot.stdout)].x);
}
