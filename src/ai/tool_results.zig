//! Bounded, immutable presentation facts copied after the tool worker joins.
//! Records are keyed by owner/turn/call and outlive the next provider request.
const std = @import("std");
const loop = @import("tool_loop.zig");
const scope = @import("tool_scope.zig");
const identity = @import("../host/identity.zig");
pub const Source = struct { owner: identity.SessionHandle, label: []const u8 };
pub const Target = struct { result: loop.TargetResult, source: ?identity.SessionHandle = null, label: []const u8 = "", operation_id: ?u64 = null };
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
    images: []const @import("image_attachments.zig").ContentRef = &.{},
    error_code: ?[]const u8 = null,
    error_status: ?loop.Status = null,
    dispatched: bool,
    expanded: bool = false,
    selected: usize = 0,
    test_id: [96]u8 = @splat(0),
    test_id_len: usize = 0,
    pub fn testId(self: *const Record) []const u8 {
        return self.test_id[0..self.test_id_len];
    }
    pub fn summary(self: *const Record, buffer: []u8) []const u8 {
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
            record.arena.deinit();
            self.allocator.destroy(record);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
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
    /// Must be called after worker.join(), before Manager clears/replaces Loop.
    /// Capacity is preflighted for the entire ledger; failure retains the old
    /// Loop for inspection and must prevent starting a new request.
    pub fn capture(self: *Store, run: *const loop.Loop, sources: []const Source) !bool {
        var needed: usize = 0;
        var added: usize = 0;
        for (run.records.items) |record| {
            if (self.contains(record.key.owner, record.key.turn_id, record.key.call_id)) continue;
            added += 1;
            needed += record.name.len + record.arguments.len * 2 + record.key.call_id.len + 1024;
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
                record.arena.deinit();
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
        saved.* = .{ .arena = arena, .images = captured_images, .owner = record.key.owner, .turn_id = record.key.turn_id, .call_id = call_id, .name = name, .arguments = arguments, .command = command, .arguments_hash = record.arguments_hash, .targets = targets, .error_code = error_code, .error_status = error_status, .dispatched = record.dispatched };
        const tag = try std.fmt.bufPrint(&saved.test_id, "ai.tool.result.{d}.{x}", .{ saved.turn_id, std.hash.Wyhash.hash(0, saved.call_id) });
        saved.test_id_len = tag.len;
        for (captured_images) |reference| _ = reference.retain();
        return saved;
    }
};

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
