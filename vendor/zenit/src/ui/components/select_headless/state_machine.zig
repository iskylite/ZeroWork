//! Select Headless, pure-logic state machine.
//!
//! Lives separately from `mod.zig` so bench builds can import this surface
//! without transitively pulling `mount.zig` -> `core.zig` -> `reactive.zig`
//! (which conflicts with bench's separate `reactive` module).

const std = @import("std");
const testing = std.testing;

/// Single option data. No N limit (v0.7 S2.2 onward virtualize=true uses VirtualList pooling).
pub fn Option(comptime ValueT: type) type {
    return struct {
        value: ValueT,
        label: []const u8,
        /// Whether disabled (still appears in list but not selectable)
        disabled: bool = false,
    };
}

/// State machine three states: closed / open (no selection) / open_with_highlight (has highlight)
pub const OpenState = enum(u8) { closed, open, open_with_highlight };

/// Navigation state: open / value mirrors component data source (mount layer handles
/// sync and proposals), highlight / typeahead owned by state machine
pub fn SelectState(comptime ValueT: type) type {
    return struct {
        open: bool = false,
        value: ?ValueT = null,
        highlight_index: ?u32 = null,
        /// typeahead buffer (character input selects option whose label starts with buffer)
        typeahead_buf: [32]u8 = undefined,
        typeahead_len: u8 = 0,
        typeahead_last_input_ms: i64 = 0,
    };
}

/// State machine operations
pub const Action = enum(u8) {
    open,
    close,
    toggle,
    arrow_down,
    arrow_up,
    page_up,
    page_down,
    home_key,
    end_key,
    enter,
    escape,
    type_char,
};

/// Single-step state machine. Return highlight index after operation (caller writes
/// back to state).
pub fn step(
    comptime ValueT: type,
    state: *SelectState(ValueT),
    options: []const Option(ValueT),
    action: Action,
    typed_char: u8,
) void {
    const n: u32 = @intCast(options.len);

    switch (action) {
        .open => state.open = true,
        .close => {
            state.open = false;
            state.highlight_index = null;
        },
        .toggle => {
            state.open = !state.open;
            if (!state.open) state.highlight_index = null;
        },
        .arrow_down => {
            if (n == 0) return;
            const cur = state.highlight_index orelse {
                state.highlight_index = 0;
                return;
            };
            state.highlight_index = if (cur + 1 < n) cur + 1 else 0; // wrap
        },
        .arrow_up => {
            if (n == 0) return;
            const cur = state.highlight_index orelse {
                state.highlight_index = n - 1;
                return;
            };
            state.highlight_index = if (cur == 0) n - 1 else cur - 1;
        },
        .page_down => {
            if (n == 0) return;
            const cur = state.highlight_index orelse 0;
            const PAGE_STEP: u32 = 10;
            state.highlight_index = @min(cur + PAGE_STEP, n - 1);
        },
        .page_up => {
            if (n == 0) return;
            const cur = state.highlight_index orelse (n - 1);
            const PAGE_STEP: u32 = 10;
            state.highlight_index = if (cur > PAGE_STEP) cur - PAGE_STEP else 0;
        },
        .home_key => {
            if (n > 0) state.highlight_index = 0;
        },
        .end_key => {
            if (n > 0) state.highlight_index = n - 1;
        },
        .enter => {
            // Select current highlight; caller then calls commitSelection
            state.open = false;
        },
        .escape => {
            state.open = false;
            state.highlight_index = null;
            state.typeahead_len = 0;
        },
        .type_char => {
            // typeahead: add character to buf; find first option whose label starts with buf
            if (state.typeahead_len < state.typeahead_buf.len) {
                state.typeahead_buf[state.typeahead_len] = std.ascii.toLower(typed_char);
                state.typeahead_len += 1;
            }
            const prefix = state.typeahead_buf[0..state.typeahead_len];
            for (options, 0..) |opt, idx| {
                if (opt.disabled) continue;
                if (matchPrefixCI(opt.label, prefix)) {
                    state.highlight_index = @intCast(idx);
                    return;
                }
            }
        },
    }
}

/// Commit current highlight as value (call after Enter / item click)
pub fn commitSelection(
    comptime ValueT: type,
    state: *SelectState(ValueT),
    options: []const Option(ValueT),
) ?ValueT {
    const idx = state.highlight_index orelse return null;
    if (idx >= options.len) return null;
    const opt = options[idx];
    if (opt.disabled) return null;
    state.value = opt.value;
    return opt.value;
}

fn matchPrefixCI(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    for (prefix, 0..) |c, i| {
        if (std.ascii.toLower(text[i]) != c) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const Opt = Option(i32);

test "SelectState defaults" {
    const state = SelectState(i32){};
    try testing.expect(!state.open);
    try testing.expect(state.value == null);
    try testing.expect(state.highlight_index == null);
}

test "step: open / close / toggle" {
    var state = SelectState(i32){};
    const opts: []const Opt = &.{
        .{ .value = 1, .label = "Apple" },
    };
    step(i32, &state, opts, .open, 0);
    try testing.expect(state.open);
    step(i32, &state, opts, .close, 0);
    try testing.expect(!state.open);
    step(i32, &state, opts, .toggle, 0);
    try testing.expect(state.open);
    step(i32, &state, opts, .toggle, 0);
    try testing.expect(!state.open);
}

test "step: arrow_down with empty highlight starts at 0" {
    var state = SelectState(i32){};
    const opts: []const Opt = &.{
        .{ .value = 1, .label = "A" },
        .{ .value = 2, .label = "B" },
        .{ .value = 3, .label = "C" },
    };
    step(i32, &state, opts, .arrow_down, 0);
    try testing.expectEqual(@as(?u32, 0), state.highlight_index);
    step(i32, &state, opts, .arrow_down, 0);
    try testing.expectEqual(@as(?u32, 1), state.highlight_index);
}

test "step: arrow_down wraps at end" {
    var state = SelectState(i32){};
    state.highlight_index = 2;
    const opts: []const Opt = &.{
        .{ .value = 1, .label = "A" },
        .{ .value = 2, .label = "B" },
        .{ .value = 3, .label = "C" },
    };
    step(i32, &state, opts, .arrow_down, 0);
    try testing.expectEqual(@as(?u32, 0), state.highlight_index);
}

test "step: arrow_up with null highlight goes to last" {
    var state = SelectState(i32){};
    const opts: []const Opt = &.{
        .{ .value = 1, .label = "A" },
        .{ .value = 2, .label = "B" },
        .{ .value = 3, .label = "C" },
    };
    step(i32, &state, opts, .arrow_up, 0);
    try testing.expectEqual(@as(?u32, 2), state.highlight_index);
}

test "step: home / end" {
    var state = SelectState(i32){};
    const opts: []const Opt = &.{
        .{ .value = 1, .label = "A" },
        .{ .value = 2, .label = "B" },
        .{ .value = 3, .label = "C" },
    };
    state.highlight_index = 1;
    step(i32, &state, opts, .home_key, 0);
    try testing.expectEqual(@as(?u32, 0), state.highlight_index);
    step(i32, &state, opts, .end_key, 0);
    try testing.expectEqual(@as(?u32, 2), state.highlight_index);
}

test "step: page_down and page_up" {
    var state = SelectState(i32){};
    var opts_buf: [50]Opt = undefined;
    for (&opts_buf, 0..) |*o, i| {
        o.* = .{ .value = @intCast(i), .label = "x" };
    }
    state.highlight_index = 5;
    step(i32, &state, &opts_buf, .page_down, 0);
    try testing.expectEqual(@as(?u32, 15), state.highlight_index);
    step(i32, &state, &opts_buf, .page_up, 0);
    try testing.expectEqual(@as(?u32, 5), state.highlight_index);
}

test "step: typeahead matches prefix case-insensitive" {
    var state = SelectState(i32){};
    const opts: []const Opt = &.{
        .{ .value = 1, .label = "Apple" },
        .{ .value = 2, .label = "Banana" },
        .{ .value = 3, .label = "Cherry" },
    };
    step(i32, &state, opts, .type_char, 'b');
    try testing.expectEqual(@as(?u32, 1), state.highlight_index);
    step(i32, &state, opts, .type_char, 'a'); // "ba"
    try testing.expectEqual(@as(?u32, 1), state.highlight_index); // still Banana
}

test "step: escape clears state" {
    var state = SelectState(i32){};
    state.open = true;
    state.highlight_index = 2;
    state.typeahead_len = 3;
    const opts: []const Opt = &.{
        .{ .value = 1, .label = "A" },
    };
    step(i32, &state, opts, .escape, 0);
    try testing.expect(!state.open);
    try testing.expect(state.highlight_index == null);
    try testing.expectEqual(@as(u8, 0), state.typeahead_len);
}

test "commitSelection: returns value of highlighted option" {
    var state = SelectState(i32){};
    state.highlight_index = 1;
    const opts: []const Opt = &.{
        .{ .value = 100, .label = "A" },
        .{ .value = 200, .label = "B" },
    };
    const got = commitSelection(i32, &state, opts);
    try testing.expectEqual(@as(?i32, 200), got);
    try testing.expectEqual(@as(?i32, 200), state.value);
}

test "commitSelection: disabled option not committed" {
    var state = SelectState(i32){};
    state.highlight_index = 0;
    const opts: []const Opt = &.{
        .{ .value = 100, .label = "A", .disabled = true },
    };
    const got = commitSelection(i32, &state, opts);
    try testing.expect(got == null);
    try testing.expect(state.value == null);
}

test "step: empty options is safe" {
    var state = SelectState(i32){};
    const opts: []const Opt = &.{};
    step(i32, &state, opts, .arrow_down, 0);
    try testing.expect(state.highlight_index == null);
    step(i32, &state, opts, .home_key, 0);
    try testing.expect(state.highlight_index == null);
}
