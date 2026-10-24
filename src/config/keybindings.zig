//! App shortcut map; remote Control combinations and Tab stay reserved.
const std = @import("std");
pub const KeyCode = enum {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    @"return",
    tab,
    space,
    delete,
    escape,
    forward_delete,
    left,
    right,
    down,
    up,
    slash,
    minus,
    equal,
    left_bracket,
    right_bracket,
    period,
    comma,
    semicolon,
    quote,
    backslash,
    grave,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    unknown,
};
pub fn fromKey(key: anytype) KeyCode {
    return std.meta.stringToEnum(KeyCode, @tagName(key)) orelse .unknown;
}

pub const Action = enum { new_tab, close_tab, tab_1, tab_2, tab_3, tab_4, tab_5, tab_6, tab_7, tab_8, tab_9, previous_tab, next_tab, recent_tab, split_vertical, split_horizontal, copy, paste, search, completion, accept_completion, quick_connect, reconnect, sidebar, ai, upload, broadcast };
pub const Chord = struct {
    key: KeyCode,
    command: bool = true,
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    pub fn eql(a: Chord, b: Chord) bool {
        return a.key == b.key and a.command == b.command and a.shift == b.shift and a.control == b.control and a.option == b.option;
    }
};
pub const Row = struct { label: []const u8, actions: []const Action };
pub const rows = [_]Row{
    .{ .label = "新建 / 关闭", .actions = &.{ .new_tab, .close_tab } },
    .{ .label = "按序号直达", .actions = &.{ .tab_1, .tab_2, .tab_3, .tab_4, .tab_5, .tab_6, .tab_7, .tab_8, .tab_9 } },
    .{ .label = "上一个 / 下一个", .actions = &.{ .previous_tab, .next_tab } },
    .{ .label = "最近使用的页签", .actions = &.{.recent_tab} },
    .{ .label = "分栏", .actions = &.{ .split_vertical, .split_horizontal } },
    .{ .label = "复制 / 粘贴", .actions = &.{ .copy, .paste } },
    .{ .label = "搜索当前终端", .actions = &.{.search} },
    .{ .label = "补全菜单 / 采纳", .actions = &.{ .completion, .accept_completion } },
    .{ .label = "快速连接 / 立即重连", .actions = &.{ .quick_connect, .reconnect } },
    .{ .label = "侧栏 / AI 浮窗", .actions = &.{ .sidebar, .ai } },
    .{ .label = "上传面板 / 广播", .actions = &.{ .upload, .broadcast } },
};
pub const Map = struct {
    chords: [27]Chord = defaults(),
    pub fn reset(self: *Map) void {
        self.* = .{};
    }
    pub fn get(self: Map, action: Action) Chord {
        return self.chords[@backingInt(action)];
    }
    pub fn match(self: Map, key: anytype, mods: anytype) ?Action {
        if (mods.ctrl or fromKey(key) == .tab) return null;
        const chord = Chord{ .key = fromKey(key), .command = mods.super, .shift = mods.shift, .control = mods.ctrl, .option = mods.alt };
        for (self.chords, 0..) |candidate, i| if (candidate.eql(chord)) return @fromBackingInt(@intCast(i));
        return null;
    }
    pub fn conflict(self: Map, action: Action, chord: Chord) ?Action {
        for (self.chords, 0..) |candidate, i| if (i != @backingInt(action) and candidate.eql(chord)) return @fromBackingInt(@intCast(i));
        return null;
    }
    pub fn set(self: *Map, action: Action, chord: Chord) !void {
        if (chord.key == .unknown or chord.key == .escape) return error.ReservedKey;
        if (action == .recent_tab or action == .accept_completion) {
            if (!chord.eql(defaults()[@backingInt(action)])) return error.RemoteKeyReserved;
        } else if (!chord.command or chord.control or chord.key == .tab) return error.RemoteKeyReserved;
        if (self.conflict(action, chord) != null) return error.Conflict;
        self.chords[@backingInt(action)] = chord;
    }
    pub fn cloneOwned(self: Map, allocator: std.mem.Allocator) !*Map {
        const copy = try allocator.create(Map);
        copy.* = self;
        return copy;
    }
    /// Append this section to the same config.toml used by the settings host.
    pub fn format(self: Map, buffer: []u8) std.Io.Writer.Error![]const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        try writer.writeAll("[keys]\n");
        for (self.chords, 0..) |chord, i| try writer.print("{s} = \"{s}{s}{s}{s}{s}\"\n", .{ @tagName(@as(Action, @fromBackingInt(@intCast(i)))), if (chord.command) "cmd+" else "", if (chord.control) "ctrl+" else "", if (chord.shift) "shift+" else "", if (chord.option) "alt+" else "", @tagName(chord.key) });
        return writer.buffered();
    }
    pub fn parse(source: []const u8) !Map {
        var map: Map = .{};
        var active = false;
        var seen: [27]bool = .{ false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false };
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                active = std.mem.eql(u8, line, "[keys]");
                continue;
            }
            if (!active) continue;
            const split = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidFormat;
            const name = std.mem.trim(u8, line[0..split], " ");
            const action = std.meta.stringToEnum(Action, name) orelse return error.UnknownAction;
            if (seen[@backingInt(action)]) return error.DuplicateAction;
            seen[@backingInt(action)] = true;
            const quoted = std.mem.trim(u8, line[split + 1 ..], " ");
            if (quoted.len < 2 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') return error.InvalidFormat;
            const val = quoted[1 .. quoted.len - 1];
            var parts = std.mem.splitScalar(u8, val, '+');
            var chord = Chord{ .key = .unknown, .command = false };
            while (parts.next()) |part| {
                if (std.mem.eql(u8, part, "cmd")) chord.command = true else if (std.mem.eql(u8, part, "ctrl")) chord.control = true else if (std.mem.eql(u8, part, "shift")) chord.shift = true else if (std.mem.eql(u8, part, "alt")) chord.option = true else chord.key = std.meta.stringToEnum(KeyCode, part) orelse return error.InvalidKey;
            }
            map.chords[@backingInt(action)] = chord;
        }
        // Validate final map, so a valid reassignment is independent of file ordering.
        for (map.chords, 0..) |chord, i| try map.set(@fromBackingInt(@intCast(i)), chord);
        return map;
    }
    pub fn rowText(self: Map, label: []const u8, buffer: []u8) ![]const u8 {
        for (rows) |row| if (std.mem.eql(u8, row.label, label)) {
            var writer = std.Io.Writer.fixed(buffer);
            for (row.actions, 0..) |action, i| {
                if (row.actions.len == 9 and i != 0 and i != 8) continue;
                if (i > 0) try writer.writeAll(if (row.actions.len == 9) " – " else " / ");
                const chord = self.get(action);
                try writer.print("{s}{s}{s}{s}{s}", .{ if (chord.command) "⌘" else "", if (chord.control) "⌃" else "", if (chord.shift) "⇧" else "", if (chord.option) "⌥" else "", symbol(chord.key) });
            }
            return writer.buffered();
        };
        return error.UnknownRow;
    }
};
fn symbol(key: KeyCode) []const u8 {
    return switch (key) {
        .tab => "⇥",
        .right => "→",
        .left_bracket => "[",
        .right_bracket => "]",
        .semicolon => ";",
        .a => "A",
        .b => "B",
        .c => "C",
        .d => "D",
        .e => "E",
        .f => "F",
        .g => "G",
        .h => "H",
        .i => "I",
        .j => "J",
        .k => "K",
        .l => "L",
        .m => "M",
        .n => "N",
        .o => "O",
        .p => "P",
        .q => "Q",
        .r => "R",
        .s => "S",
        .t => "T",
        .u => "U",
        .v => "V",
        .w => "W",
        .x => "X",
        .y => "Y",
        .z => "Z",
        else => @tagName(key),
    };
}
fn defaults() [27]Chord {
    return .{ .{ .key = .t }, .{ .key = .w }, .{ .key = .@"1" }, .{ .key = .@"2" }, .{ .key = .@"3" }, .{ .key = .@"4" }, .{ .key = .@"5" }, .{ .key = .@"6" }, .{ .key = .@"7" }, .{ .key = .@"8" }, .{ .key = .@"9" }, .{ .key = .left_bracket, .shift = true }, .{ .key = .right_bracket, .shift = true }, .{ .key = .tab, .command = false, .control = true }, .{ .key = .d }, .{ .key = .d, .shift = true }, .{ .key = .c }, .{ .key = .v }, .{ .key = .f }, .{ .key = .semicolon }, .{ .key = .right, .command = false }, .{ .key = .k }, .{ .key = .r }, .{ .key = .b }, .{ .key = .j }, .{ .key = .u }, .{ .key = .i, .shift = true } };
}

test "pure shortcut map parses entire config and routes foreign enum by tag" {
    const ForeignKey = enum { f, tab, c };
    const Mods = struct { super: bool = false, ctrl: bool = false, shift: bool = false, alt: bool = false };
    const map = try Map.parse("[ui]\nfont_size = 14\n[keys]\nsearch = \"cmd+e\"\n[log]\nring_mb = 64\n");
    try std.testing.expectEqual(KeyCode.e, map.get(.search).key);
    try std.testing.expect((Map{}).match(ForeignKey.tab, Mods{ .ctrl = true }) == null);
    try std.testing.expect((Map{}).match(ForeignKey.c, Mods{ .ctrl = true }) == null);
    try std.testing.expectEqual(Action.search, (Map{}).match(ForeignKey.f, Mods{ .super = true }).?);
    try std.testing.expectError(error.Conflict, Map.parse("[keys]\nsearch = \"cmd+j\"\n"));
}
