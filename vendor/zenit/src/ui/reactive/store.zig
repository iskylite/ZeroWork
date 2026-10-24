/// Store: comptime-expands struct fields into independent Signals for fine-grained tracking
///
/// Usage:
/// ```zig
/// const AppState = struct { count: i32, name: []const u8 };
/// const store = try StoreOf(AppState).create(scope, .{ .count = 0, .name = "hello" });
/// // Read (automatically tracks dependencies)
/// const count = store.get(.count);
/// // Set (notifies only count subscribers; name subscribers unaffected)
/// store.set(.count, 42);
/// ```
const std = @import("std");
const Scope = @import("scope.zig").Scope;
const Signal = @import("signal.zig").Signal;

/// Store type generated for struct T
pub fn StoreOf(comptime T: type) type {
    const fields = @import("zenit_reflection").fields(T);

    return struct {
        const Self = @This();

        /// Each field maps to independent Signal
        signals: [fields.len]*anyopaque,
        scope: *Scope,

        /// Create Store on scope, initial values from initial; each field one signal. `[]const u8`
        /// fields are owning-text signals (`scope.createText`): write copies content, caller can
        /// pass temp buffer (like Input callback borrowed slice); read slice valid only in current
        /// sync call and field not rewritten since (see `Signal.get`).
        pub fn create(scope: *Scope, initial: T) !Self {
            var signals: [fields.len]*anyopaque = undefined;
            inline for (fields, 0..) |f, i| {
                signals[i] = if (f.type == []const u8)
                    @ptrCast(try scope.createText(@field(initial, f.name), .{}))
                else
                    @ptrCast(try scope.createSignal(f.type, @field(initial, f.name)));
            }
            return .{ .signals = signals, .scope = scope };
        }

        /// Field's signal: can bind directly as component Source/Model (`.value =
        /// store.field(.email)`).
        pub fn field(self: *const Self, comptime f: std.meta.FieldEnum(T)) *Signal(FieldType(f)) {
            return self.signalPtr(f);
        }

        /// Read single field (auto-track dependencies)
        pub fn get(self: *const Self, comptime fe: std.meta.FieldEnum(T)) FieldType(fe) {
            return self.signalPtr(fe).get();
        }

        /// Set single field (notify only that field's subscribers)
        pub fn set(self: *Self, comptime fe: std.meta.FieldEnum(T), value: FieldType(fe)) void {
            self.signalPtr(fe).set(value);
        }

        /// Read all fields without tracking (snapshot)
        pub fn snapshot(self: *const Self) T {
            var result: T = undefined;
            inline for (fields, 0..) |f, i| {
                const signal: *Signal(f.type) = @ptrCast(@alignCast(self.signals[i]));
                @field(result, f.name) = signal.peek();
            }
            return result;
        }

        /// Get field type
        fn FieldType(comptime fe: std.meta.FieldEnum(T)) type {
            return std.meta.fieldInfo(T, fe).type;
        }

        fn signalPtr(self: *const Self, comptime fe: std.meta.FieldEnum(T)) *Signal(FieldType(fe)) {
            return @ptrCast(@alignCast(self.signals[@backingInt(fe)]));
        }
    };
}

// Tests in src/ui/ui.zig run via full import chain (store + scope need work/deferred_scheduler
// module). Here only type-level compile verification: StoreOf instantiation compiles all methods.
test "StoreOf: text fields own their bytes; field() exposes the signal" {
    const SignalOwner = @import("owner.zig").SignalOwner;
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(std.testing.allocator, null, owner);
    defer scope.dispose();
    const Data = struct { name: []const u8, n: i32 };
    var store = try StoreOf(Data).create(scope, .{ .name = "a", .n = 1 });
    var tmp = "temporary".*;
    store.set(.name, &tmp);
    tmp[0] = 'X';
    try std.testing.expectEqualStrings("temporary", store.get(.name));
    store.field(.n).set(5);
    try std.testing.expectEqual(@as(i32, 5), store.snapshot().n);
    try std.testing.expect(store.field(.name).slice_store != null);
}

test "StoreOf: type instantiates" {
    const Counter = struct { n: i32, name: []const u8 };
    const T = StoreOf(Counter);
    _ = T.create;
    _ = T.get;
    _ = T.set;
    _ = T.snapshot;
}
