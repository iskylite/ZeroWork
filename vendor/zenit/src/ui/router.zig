/// Declarative routing system for page navigation based on Signal + Match
///
/// Usage:
/// ```zig
/// const Page = enum { welcome, editor, settings };
/// var router = try Router(Page).init(scope, .welcome);
/// var params: RouteParams = .{};
/// try params.set("file", "test.md");
/// router.navigate(.editor, params);
/// router.back(); // back to welcome
/// // mount automatically switches pages using Match internally
/// ```
const std = @import("std");
const Scope = @import("reactive/scope.zig").Scope;
const Signal = @import("reactive/signal.zig").Signal;
const SignalOwner = @import("reactive/owner.zig").SignalOwner;

/// Route parameters
pub const RouteParams = struct {
    pub const max_params = 8;
    pub const max_key_len = 64;
    pub const max_value_len = 512;
    pub const Error = error{
        TooManyParams,
        KeyTooLong,
        ValueTooLong,
    };

    entries: [max_params]ParamEntry = @as([max_params]ParamEntry, @splat(.{})),
    count: u8 = 0,

    const ParamEntry = struct {
        key_buf: [max_key_len]u8 = @as([max_key_len]u8, @splat(0)),
        key_len: u8 = 0,
        value_buf: [max_value_len]u8 = @as([max_value_len]u8, @splat(0)),
        value_len: u16 = 0,

        fn init(param_key: []const u8, param_value: []const u8) Error!ParamEntry {
            if (param_key.len > max_key_len) return error.KeyTooLong;
            if (param_value.len > max_value_len) return error.ValueTooLong;

            var entry = ParamEntry{};
            @memcpy(entry.key_buf[0..param_key.len], param_key);
            entry.key_len = @intCast(param_key.len);
            @memcpy(entry.value_buf[0..param_value.len], param_value);
            entry.value_len = @intCast(param_value.len);
            return entry;
        }

        fn key(self: *const ParamEntry) []const u8 {
            return self.key_buf[0..self.key_len];
        }

        fn value(self: *const ParamEntry) []const u8 {
            return self.value_buf[0..self.value_len];
        }
    };

    pub fn get(self: *const RouteParams, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, entry.key(), key)) return entry.value();
        }
        return null;
    }

    pub fn set(self: *RouteParams, key: []const u8, value: []const u8) Error!void {
        if (key.len > max_key_len) return error.KeyTooLong;
        if (value.len > max_value_len) return error.ValueTooLong;

        // Update existing
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.key(), key)) {
                @memcpy(entry.value_buf[0..value.len], value);
                entry.value_len = @intCast(value.len);
                return;
            }
        }
        // Add new
        if (self.count >= max_params) return error.TooManyParams;

        self.entries[self.count] = try ParamEntry.init(key, value);
        self.count += 1;
    }
};

/// History entry
fn HistoryEntry(comptime PageEnum: type) type {
    return struct {
        page: PageEnum,
        params: RouteParams,
    };
}

/// Generic router
pub fn Router(comptime PageEnum: type) type {
    return struct {
        const Self = @This();
        const Entry = HistoryEntry(PageEnum);

        /// Current page (reactive Signal)
        current: *Signal(PageEnum),
        /// Current route parameters (reactive Signal)
        params: *Signal(RouteParams),
        /// Navigation history stack
        history: [max_history]Entry = undefined,
        history_len: u16 = 0,
        /// Current position in history stack
        history_pos: u16 = 0,

        const max_history = 64;

        /// Create router
        pub fn init(scope: *Scope, initial_page: PageEnum) !Self {
            const current = try scope.createSignal(PageEnum, initial_page);
            const params = try scope.createSignal(RouteParams, .{});
            var router = Self{
                .current = current,
                .params = params,
                .history = undefined,
            };
            // Push initial page into history
            router.pushHistory(initial_page, .{});
            return router;
        }

        /// Navigate to new page
        pub fn navigate(self: *Self, page: PageEnum, route_params: RouteParams) void {
            // If not at top of history stack (due to back()), truncate forward history
            if (self.history_pos + 1 < self.history_len) {
                self.history_len = self.history_pos + 1;
            }
            self.pushHistory(page, route_params);
            self.current.set(page);
            self.params.set(route_params);
        }

        /// Navigate to new page (no parameters)
        pub fn navigateTo(self: *Self, page: PageEnum) void {
            self.navigate(page, .{});
        }

        /// Go back
        pub fn back(self: *Self) bool {
            if (self.history_pos == 0) return false;
            self.history_pos -= 1;
            const entry = self.history[self.history_pos];
            self.current.set(entry.page);
            self.params.set(entry.params);
            return true;
        }

        /// Go forward
        pub fn forward(self: *Self) bool {
            if (self.history_pos + 1 >= self.history_len) return false;
            self.history_pos += 1;
            const entry = self.history[self.history_pos];
            self.current.set(entry.page);
            self.params.set(entry.params);
            return true;
        }

        /// Can go back
        pub fn canGoBack(self: *const Self) bool {
            return self.history_pos > 0;
        }

        /// Can go forward
        pub fn canGoForward(self: *const Self) bool {
            return self.history_pos + 1 < self.history_len;
        }

        fn pushHistory(self: *Self, page: PageEnum, route_params: RouteParams) void {
            if (self.history_len >= max_history) {
                // Stack full: discard oldest half of history
                const keep = max_history / 2;
                const discard = self.history_len - keep;
                var i: u16 = 0;
                while (i < keep) : (i += 1) {
                    self.history[i] = self.history[i + discard];
                }
                self.history_len = keep;
                self.history_pos = if (self.history_pos >= discard) self.history_pos - discard else 0;
            }
            self.history[self.history_len] = .{ .page = page, .params = route_params };
            self.history_len += 1;
            self.history_pos = self.history_len - 1;
        }
    };
}

test "RouteParams owns copied key/value bytes" {
    var params: RouteParams = .{};
    var key_buf = [_]u8{ 'f', 'i', 'l', 'e' };
    var value_buf = [_]u8{ 'd', 'r', 'a', 'f', 't', '.', 'm', 'd' };

    try params.set(key_buf[0..], value_buf[0..]);
    key_buf[0] = 'x';
    value_buf[0] = 'x';

    try std.testing.expectEqualStrings("draft.md", params.get("file").?);
}

test "RouteParams rejects overflow instead of truncating" {
    var params: RouteParams = .{};

    var i: usize = 0;
    while (i < RouteParams.max_params) : (i += 1) {
        var key_buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "k{d}", .{i});
        try params.set(key, "value");
    }

    try std.testing.expectError(error.TooManyParams, params.set("overflow", "value"));
}

test "RouteParams validates key and value lengths" {
    var params: RouteParams = .{};
    const long_key = @as([(RouteParams.max_key_len + 1)]u8, @splat('k'));
    const long_value = @as([(RouteParams.max_value_len + 1)]u8, @splat('v'));

    try std.testing.expectError(error.KeyTooLong, params.set(long_key[0..], "value"));
    try std.testing.expectError(error.ValueTooLong, params.set("key", long_value[0..]));
}

test "Router works with enums that do not start at zero" {
    const Page = enum(u8) {
        welcome = 1,
        editor = 2,
        settings = 3,
    };

    const owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const scope = try Scope.init(std.testing.allocator, null, owner);
    defer scope.dispose();

    var router = try Router(Page).init(scope, .welcome);

    var route_params: RouteParams = .{};
    try route_params.set("file", "draft.md");
    router.navigate(.editor, route_params);

    try route_params.set("file", "mutated.md");

    try std.testing.expectEqual(Page.editor, router.current.peek());
    try std.testing.expectEqualStrings("draft.md", router.params.peek().get("file").?);
    try std.testing.expect(router.canGoBack());
    try std.testing.expect(!router.canGoForward());

    try std.testing.expect(router.back());
    try std.testing.expectEqual(Page.welcome, router.current.peek());
    try std.testing.expect(router.canGoForward());

    try std.testing.expect(router.forward());
    try std.testing.expectEqual(Page.editor, router.current.peek());
    try std.testing.expectEqualStrings("draft.md", router.params.peek().get("file").?);
}
