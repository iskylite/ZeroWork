/// Context: generic cross-layer dependency injection
///
/// Searches up the Scope tree; zero extra allocation (8 stack slots).
///
/// Usage:
/// ```zig
/// // Provider
/// const ThemeCtx = Context(*ThemeTokens);
/// try ThemeCtx.provide(scope, &my_tokens);
///
/// // Consumer (in any child scope)
/// const tokens = ThemeCtx.consume(scope) orelse &default_tokens;
/// ```
const std = @import("std");
const Scope = @import("scope.zig").Scope;

/// Generate unique type ID.
///
/// Cannot use a generic function address: ReleaseFast's identical-code folding merges
/// empty functions of different T to one address, colliding context slots and casting to
/// the wrong pointer type. Each generic instance needs its own observable token storage
/// address.
fn typeId(comptime T: type) usize {
    const S = struct {
        var token: struct { type_marker: ?*T = null } = .{};
    };
    return @intFromPtr(&S.token);
}

/// Generic Context, auto-select slot by type parameter
pub fn Context(comptime T: type) type {
    return struct {
        /// Register a context value in current scope
        pub fn provide(scope: *Scope, value: *T) !void {
            try scope.setContext(typeId(T), @ptrCast(value));
        }

        /// Walk up parent chain to find nearest context value
        pub fn consume(scope: *Scope) ?*T {
            if (scope.getContext(typeId(T))) |ptr| {
                return @ptrCast(@alignCast(ptr));
            }
            return null;
        }
    };
}

/// Scope context entry (inlined in scope.zig's ContextSlot)
pub const ContextSlot = struct {
    type_id: usize = 0,
    ptr: ?*anyopaque = null,
};

pub const max_context_slots = 16;

const testing = std.testing;
const owner_mod = @import("owner.zig");

test "Context: child scope shadows parent scope" {
    const Theme = struct { value: i32 };
    const ThemeCtx = Context(Theme);

    const owner = try owner_mod.SignalOwner.init(testing.allocator);
    defer owner.deinit();

    const root = try Scope.init(testing.allocator, null, owner);
    defer root.dispose();
    const child = try root.childScope();

    var parent_theme = Theme{ .value = 1 };
    try ThemeCtx.provide(root, &parent_theme);
    try testing.expectEqual(@as(i32, 1), ThemeCtx.consume(child).?.value);

    var child_theme = Theme{ .value = 2 };
    try ThemeCtx.provide(child, &child_theme);
    try testing.expectEqual(@as(i32, 2), ThemeCtx.consume(child).?.value);
    try testing.expectEqual(@as(i32, 1), ThemeCtx.consume(root).?.value);
}

test "Context: distinct types retain distinct IDs in optimized builds" {
    const A = struct { value: u8 };
    const B = struct { value: u8 };
    try testing.expect(typeId(A) != typeId(B));
}
