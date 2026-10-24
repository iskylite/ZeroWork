/// Widget State - component state management
///
/// Allows component to maintain cross-frame state. Each component via unique ID
/// stores and retrieves state.
///
/// Usage:
/// 1. Get state in component build() via StateStore.getOrCreate()
/// 2. State persists between frames
/// 3. Modify state via event handlers
/// 4. State change marks dirty, trigger rerender
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Compile-time detect if type has pub fn deinit(*T) void
fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "deinit"),
        else => false,
    };
}

/// Get unique type ID via function pointer address (faster than @typeName string compare)
fn typeIdPtr(comptime T: type) *const anyopaque {
    return @ptrCast(&struct {
        fn f(_: *T) void {}
    }.f);
}

/// Type-erased state entry
const StateEntry = struct {
    ptr: *anyopaque,
    destroy_fn: *const fn (*anyopaque, Allocator) void,
    type_id: *const anyopaque,
    type_name: []const u8,
    debug_fn: *const fn (*anyopaque, []u8) []const u8,
};

/// State storage - manage all component state
pub const StateStore = struct {
    allocator: Allocator,
    states: std.AutoHashMap(u64, StateEntry),

    pub fn init(allocator: Allocator) StateStore {
        return .{
            .allocator = allocator,
            .states = std.AutoHashMap(u64, StateEntry).init(allocator),
        };
    }

    pub fn deinit(self: *StateStore) void {
        var it = self.states.valueIterator();
        while (it.next()) |entry| {
            entry.destroy_fn(entry.ptr, self.allocator);
        }
        self.states.deinit();
    }

    /// Get or create typed state
    pub fn getOrCreate(self: *StateStore, comptime T: type, id: u64, initial: T) !*T {
        const tid = typeIdPtr(T);
        if (self.states.get(id)) |entry| {
            if (entry.type_id == tid) {
                return @ptrCast(@alignCast(entry.ptr));
            }
            std.log.warn(
                "[StateStore] state id collision: id=0x{x} existing={s} requested={s}; replacing existing state",
                .{ id, entry.type_name, @typeName(T) },
            );
            entry.destroy_fn(entry.ptr, self.allocator);
            _ = self.states.remove(id);
        }

        // Create new state
        const state = try self.allocator.create(T);
        // put fails -> the newly-built state is orphaned.
        // Contract: initial must be a **no-resource bare struct** (all 7 call sites pass `T{}` /
        // `.{}`);
        // only destroy, not deinit, is called here: deinit on an uninitialized struct is UB, and a
        // resource-holding initial on this rare path would leak internals.
        // Anyone passing a resource-holding initial must fix this first.
        errdefer self.allocator.destroy(state);
        state.* = initial;

        try self.states.put(id, .{
            .ptr = state,
            .destroy_fn = struct {
                fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                    const typed: *T = @ptrCast(@alignCast(ptr));
                    // If type has deinit, call first to clean internal resources
                    if (comptime hasDeinit(T)) {
                        typed.deinit();
                    }
                    alloc.destroy(typed);
                }
            }.destroy,
            .type_id = tid,
            .type_name = @typeName(T),
            .debug_fn = struct {
                fn dump(ptr: *anyopaque, out: []u8) []const u8 {
                    const typed: *T = @ptrCast(@alignCast(ptr));
                    return debugFormatSafe(T, out, typed.*);
                }
            }.dump,
        });

        return state;
    }

    /// Get existing state (return null if not found)
    pub fn get(self: *StateStore, comptime T: type, id: u64) ?*T {
        if (self.states.get(id)) |entry| {
            if (entry.type_id != typeIdPtr(T)) {
                std.log.warn(
                    "[StateStore] get type mismatch: id=0x{x} existing={s} requested={s}",
                    .{ id, entry.type_name, @typeName(T) },
                );
                return null;
            }
            return @ptrCast(@alignCast(entry.ptr));
        }
        return null;
    }

    /// Delete state
    pub fn remove(self: *StateStore, id: u64) void {
        if (self.states.fetchRemove(id)) |kv| {
            kv.value.destroy_fn(kv.value.ptr, self.allocator);
        }
    }

    /// State count
    pub fn count(self: *StateStore) usize {
        return self.states.count();
    }

    /// Generate debug state list by state pointer whitelist (format only matched state, avoid full
    /// cost)
    pub fn debugEntriesByPtrs(self: *StateStore, allocator: Allocator, ptrs: []const *anyopaque) []DebugStateEntry {
        if (ptrs.len == 0) return &[_]DebugStateEntry{};

        var ptr_set = std.AutoHashMap(usize, void).init(allocator);
        defer ptr_set.deinit();
        // Intentionally swallow error: this only serves devtools state panel (sole call site
        // devtools.zig:1981). OOM -> fewer debug lines is safe degradation,
        // doesn't affect any production correctness path.
        for (ptrs) |ptr| {
            _ = ptr_set.put(@intFromPtr(ptr), {}) catch {};
        }

        var list = std.ArrayList(DebugStateEntry).empty;
        defer list.deinit(allocator);
        var it = self.states.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (!ptr_set.contains(@intFromPtr(value.ptr))) continue;
            var debug_entry: DebugStateEntry = .{
                .id = id,
                .ptr = value.ptr,
                .type_name = value.type_name,
            };
            const text = value.debug_fn(value.ptr, debug_entry.value[0..]);
            debug_entry.value_len = @intCast(text.len);
            _ = list.append(allocator, debug_entry) catch {};
        }
        return list.toOwnedSlice(allocator) catch &[_]DebugStateEntry{};
    }
};

/// DevTools debug struct
pub const DebugStateEntry = struct {
    id: u64,
    ptr: *anyopaque,
    type_name: []const u8,
    value: [256]u8 = @as([256]u8, @splat(0)),
    value_len: u16 = 0,

    pub fn valueSlice(self: *const DebugStateEntry) []const u8 {
        return self.value[0..self.value_len];
    }
};

fn debugFormatSafe(comptime T: type, out: []u8, value: T) []const u8 {
    if (out.len == 0) return out[0..0];
    var writer = std.Io.Writer.fixed(out);
    formatValue(T, value, &writer, 0) catch {
        const written = writer.buffered().len;
        if (out.len >= 3 and written >= 3) {
            out[written - 3] = '.';
            out[written - 2] = '.';
            out[written - 1] = '.';
            return out[0..written];
        }
        const fallback = "<?>";
        const n = @min(out.len, fallback.len);
        if (n > 0) @memcpy(out[0..n], fallback[0..n]);
        return out[0..n];
    };
    return writer.buffered();
}

fn formatValue(comptime T: type, value: T, writer: anytype, depth: u8) !void {
    if (depth > 4) {
        try writer.writeAll("…");
        return;
    }
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float => {
            try writer.print("{}", .{value});
        },
        .@"enum" => |info| {
            // Empty enum (`enum(u64) { _ }` opaque id idiom) has no tag names, @tagName
            // compile-fails;
            // non-exhaustive enum values also fall outside named tags. Both cases fallback to print
            // int value.
            if (info.field_names.len == 0 or info.mode == .nonexhaustive) {
                try writer.print("{d}", .{@backingInt(value)});
            } else {
                try writer.print("{s}", .{@tagName(value)});
            }
        },
        .optional => {
            if (value) |v| {
                try formatValue(@TypeOf(v), v, writer, depth + 1);
            } else {
                try writer.writeAll("null");
            }
        },
        .pointer => |p| {
            if (p.size == .slice) {
                const Child = p.child;
                if (Child == u8) {
                    try formatByteSlice(writer, value);
                } else {
                    const len = value.len;
                    try writer.writeAll("[");
                    const preview = @min(len, 4);
                    var i: usize = 0;
                    while (i < preview) : (i += 1) {
                        if (i > 0) try writer.writeAll(", ");
                        try formatValue(Child, value[i], writer, depth + 1);
                    }
                    if (len > preview) try writer.writeAll(", …");
                    try writer.writeAll("]");
                }
            } else {
                const ptr_addr: usize = @intFromPtr(value);
                _ = ptr_addr;
                try writer.writeAll("<ptr>");
            }
        },
        .array => {
            try writer.print("[{d}]", .{value.len});
        },
        .@"struct" => {
            try writer.writeAll("{");
            inline for (@import("zenit_reflection").fields(T), 0..) |field, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(field.name);
                try writer.writeAll("=");
                const field_value = @field(value, field.name);
                try formatValue(field.type, field_value, writer, depth + 1);
            }
            try writer.writeAll("}");
        },
        else => {
            try writer.writeAll("<opaque>");
        },
    }
}

fn formatByteSlice(writer: anytype, bytes: []const u8) !void {
    const max_preview: usize = 64;
    const preview = bytes[0..@min(bytes.len, max_preview)];

    if (std.unicode.utf8ValidateSlice(preview) and isReasonablyPrintableText(preview)) {
        try writer.writeAll("\"");
        try writeEscapedAsciiUtf8(writer, preview);
        if (bytes.len > max_preview) try writer.writeAll("…");
        try writer.writeAll("\"");
        return;
    }

    try writer.print("bytes[{d}](", .{bytes.len});
    const hex_preview = @min(bytes.len, @as(usize, 16));
    for (bytes[0..hex_preview], 0..) |b, i| {
        if (i > 0) try writer.writeAll(" ");
        try writer.print("{x:0>2}", .{b});
    }
    if (bytes.len > hex_preview) try writer.writeAll(" …");
    try writer.writeAll(")");
}

fn isReasonablyPrintableText(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == 0) return false;
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t') return false;
        if (c == 0x7F) return false;
    }
    return true;
}

fn writeEscapedAsciiUtf8(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

/// Generate component state ID (based on component type name + instance index)
pub fn stateId(comptime component_name: []const u8, instance: u32) u64 {
    var hash: u64 = 0;
    for (component_name) |c| {
        hash = hash *% 31 +% c;
    }
    return hash *% 0x100000000 +% instance;
}

// ===== Tests =====

test "StateStore: init/deinit" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "StateStore: getOrCreate" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const CounterState = struct {
        value: i32,
        clicked: bool,
    };

    const state = try store.getOrCreate(CounterState, 1, .{ .value = 0, .clicked = false });
    try std.testing.expectEqual(@as(i32, 0), state.value);

    // Modify state
    state.value = 42;
    state.clicked = true;

    // Get again, should get same state
    const state2 = try store.getOrCreate(CounterState, 1, .{ .value = 0, .clicked = false });
    try std.testing.expectEqual(@as(i32, 42), state2.value);
    try std.testing.expect(state2.clicked);

    // Pointer identical
    try std.testing.expect(state == state2);
}

test "StateStore: multiple states" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const state_a = try store.getOrCreate(u32, 1, 100);
    const state_b = try store.getOrCreate(u32, 2, 200);

    try std.testing.expectEqual(@as(u32, 100), state_a.*);
    try std.testing.expectEqual(@as(u32, 200), state_b.*);
    try std.testing.expectEqual(@as(usize, 2), store.count());
}

test "StateStore: get returns null for missing" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const result = store.get(u32, 999);
    try std.testing.expectEqual(@as(?*u32, null), result);
}

test "StateStore: remove" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.getOrCreate(u32, 1, 42);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    store.remove(1);
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "stateId: different names produce different IDs" {
    const id1 = stateId("TextInput", 0);
    const id2 = stateId("Checkbox", 0);
    const id3 = stateId("TextInput", 1);

    try std.testing.expect(id1 != id2);
    try std.testing.expect(id1 != id3);
    try std.testing.expect(id2 != id3);
}

test "StateStore: struct state with ArrayList" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const InputState = struct {
        cursor_pos: usize,
        focused: bool,
    };

    const state = try store.getOrCreate(InputState, 1, .{
        .cursor_pos = 0,
        .focused = false,
    });

    state.cursor_pos = 5;
    state.focused = true;

    const state2 = try store.getOrCreate(InputState, 1, .{
        .cursor_pos = 0,
        .focused = false,
    });

    try std.testing.expectEqual(@as(usize, 5), state2.cursor_pos);
    try std.testing.expect(state2.focused);
}

test "StateStore: getOrCreate replaces mismatched type for same id" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const A = struct { v: i32 };
    const B = struct { flag: bool };

    const id: u64 = 0x00ABCDEF;
    const a = try store.getOrCreate(A, id, .{ .v = 9 });
    try std.testing.expectEqual(@as(i32, 9), a.v);

    const b = try store.getOrCreate(B, id, .{ .flag = true });
    try std.testing.expectEqual(true, b.flag);

    try std.testing.expect(store.get(A, id) == null);
    try std.testing.expect(store.get(B, id) != null);
}

test "debugFormatSafe: empty enum (opaque id) prints integer value" {
    const ObjectId = enum(u64) { _ };
    const S = struct { id: ObjectId = @fromBackingInt(@intCast(42)) };
    var buf: [128]u8 = undefined;
    const out = debugFormatSafe(S, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, out, "42") != null);
}
