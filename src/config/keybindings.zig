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

pub const Action = enum { new_tab, close_tab, tab_1, tab_2, tab_3, tab_4, tab_5, tab_6, tab_7, tab_8, tab_9, previous_tab, next_tab, recent_tab, split_vertical, split_horizontal, copy, paste, search, completion, accept_completion, quick_connect, reconnect, sidebar, ai, upload, broadcast, notes_float, notes_directory };
const action_count = @typeInfo(Action).@"enum".field_names.len;
const notes_actions = [_]Action{ .notes_float, .notes_directory };
const unbound: Chord = .{ .key = .unknown, .command = false };
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

fn isNotesAction(action: Action) bool {
    return action == .notes_float or action == .notes_directory;
}

fn builtInChord(chord: Chord) bool {
    // Match the AppKit menu and native event pump, plus the workspace's
    // fixed actions and the notes editor's own save, search and undo keys.
    if (chord.key == .q or chord.key == .grave or (chord.key == .w and chord.shift)) return true;
    if (chord.option) return chord.key == .h and !chord.shift;
    if (chord.shift) return switch (chord.key) {
        .b, .n, .r, .s, .z => true,
        else => false,
    };
    return switch (chord.key) {
        .a, .c, .f, .h, .l, .m, .n, .o, .s, .v, .w, .x, .z, .comma => true,
        else => false,
    };
}
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
    .{ .label = "笔记浮窗 / 笔记目录", .actions = &notes_actions },
};
pub const Map = struct {
    chords: [action_count]Chord = defaults(),
    pub fn reset(self: *Map) void {
        self.* = .{};
    }
    pub fn get(self: Map, action: Action) Chord {
        return self.chords[@backingInt(action)];
    }
    pub fn match(self: Map, key: anytype, mods: anytype) ?Action {
        const code = fromKey(key);
        if (mods.ctrl or code == .tab or code == .unknown) return null;
        const chord = Chord{ .key = code, .command = mods.super, .shift = mods.shift, .control = mods.ctrl, .option = mods.alt };
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
        if (isNotesAction(action) and builtInChord(chord)) return error.BuiltInKeyReserved;
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
        for (self.chords, 0..) |chord, i| {
            const action: Action = @fromBackingInt(@intCast(i));
            if (chord.key == .unknown and isNotesAction(action)) {
                try writer.print("{s} = \"unbound\"\n", .{@tagName(action)});
                continue;
            }
            try writer.print("{s} = \"{s}{s}{s}{s}{s}\"\n", .{ @tagName(action), if (chord.command) "cmd+" else "", if (chord.control) "ctrl+" else "", if (chord.shift) "shift+" else "", if (chord.option) "alt+" else "", @tagName(chord.key) });
        }
        return writer.buffered();
    }
    pub fn parse(source: []const u8) !Map {
        var map: Map = .{};
        var active = false;
        var seen: [action_count]bool = @splat(false);
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
            if (isNotesAction(action) and std.mem.eql(u8, val, "unbound")) {
                map.chords[@backingInt(action)] = unbound;
                continue;
            }
            var parts = std.mem.splitScalar(u8, val, '+');
            var chord = Chord{ .key = .unknown, .command = false };
            while (parts.next()) |part| {
                if (std.mem.eql(u8, part, "cmd")) chord.command = true else if (std.mem.eql(u8, part, "ctrl")) chord.control = true else if (std.mem.eql(u8, part, "shift")) chord.shift = true else if (std.mem.eql(u8, part, "alt")) chord.option = true else chord.key = std.meta.stringToEnum(KeyCode, part) orelse return error.InvalidKey;
            }
            if (chord.key == .unknown) return error.ReservedKey;
            map.chords[@backingInt(action)] = chord;
        }
        // Existing custom chords take precedence over newly introduced defaults.
        for (notes_actions) |action| {
            const index = @backingInt(action);
            if (!seen[index] and map.conflict(action, map.chords[index]) != null) {
                map.chords[index] = unbound;
            }
        }
        // Validate final map, so a valid reassignment is independent of file ordering.
        for (map.chords, 0..) |chord, i| {
            if (chord.key == .unknown) continue;
            try map.set(@fromBackingInt(@intCast(i)), chord);
        }
        return map;
    }
    pub fn rowText(self: Map, label: []const u8, buffer: []u8) ![]const u8 {
        for (rows) |row| if (std.mem.eql(u8, row.label, label)) {
            var writer = std.Io.Writer.fixed(buffer);
            for (row.actions, 0..) |action, i| {
                if (row.actions.len == 9 and i != 0 and i != 8) continue;
                if (i > 0) try writer.writeAll(if (row.actions.len == 9) " – " else " / ");
                const chord = self.get(action);
                if (chord.key == .unknown) {
                    try writer.writeAll("未设置");
                    continue;
                }
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
fn defaults() [action_count]Chord {
    return .{ .{ .key = .t }, .{ .key = .w }, .{ .key = .@"1" }, .{ .key = .@"2" }, .{ .key = .@"3" }, .{ .key = .@"4" }, .{ .key = .@"5" }, .{ .key = .@"6" }, .{ .key = .@"7" }, .{ .key = .@"8" }, .{ .key = .@"9" }, .{ .key = .left_bracket, .shift = true }, .{ .key = .right_bracket, .shift = true }, .{ .key = .tab, .command = false, .control = true }, .{ .key = .d }, .{ .key = .d, .shift = true }, .{ .key = .c }, .{ .key = .v }, .{ .key = .f }, .{ .key = .semicolon }, .{ .key = .right, .command = false }, .{ .key = .k }, .{ .key = .r }, .{ .key = .b }, .{ .key = .j }, .{ .key = .u }, .{ .key = .i, .shift = true }, .{ .key = .n, .option = true }, .{ .key = .b, .option = true } };
}

test "notes shortcuts preserve existing custom chords when reading legacy maps" {
    const mods = struct { super: bool = true, shift: bool = false, ctrl: bool = false, alt: bool = false };
    const defaults_map: Map = .{};
    try std.testing.expectEqual(Action.notes_float, defaults_map.match(KeyCode.n, mods{ .alt = true }).?);
    try std.testing.expectEqual(Action.notes_directory, defaults_map.match(KeyCode.b, mods{ .alt = true }).?);
    try std.testing.expectEqual(Action.sidebar, defaults_map.match(KeyCode.b, mods{}).?);
    try std.testing.expect(defaults_map.match(KeyCode.n, mods{}) == null);

    var map = try Map.parse("[keys]\nai = \"cmd+alt+n\"\nsearch = \"cmd+alt+b\"\n");
    try std.testing.expectEqual(Action.ai, map.match(KeyCode.n, mods{ .alt = true }).?);
    try std.testing.expectEqual(Action.search, map.match(KeyCode.b, mods{ .alt = true }).?);
    try std.testing.expectEqual(KeyCode.unknown, map.get(.notes_float).key);
    try std.testing.expectEqual(KeyCode.unknown, map.get(.notes_directory).key);
    try std.testing.expectError(error.Conflict, map.set(.notes_float, .{ .key = .n, .option = true }));
    try map.set(.notes_float, .{ .key = .p, .option = true });
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualDeep(map, try Map.parse(try map.format(&buffer)));
    try map.set(.search, .{ .key = .f });
    try std.testing.expectEqualDeep(map, try Map.parse(try map.format(&buffer)));
}

test "notes shortcuts reject native and fixed commands while accepting unused chords" {
    var map: Map = .{};
    for ([_]Chord{
        .{ .key = .n },                 .{ .key = .s },                                .{ .key = .z, .shift = true },
        .{ .key = .q, .option = true }, .{ .key = .w, .shift = true, .option = true }, .{ .key = .grave, .option = true },
        .{ .key = .h, .option = true }, .{ .key = .b, .shift = true },
    }) |chord| {
        try std.testing.expectError(error.BuiltInKeyReserved, map.set(.notes_float, chord));
        try std.testing.expectError(error.BuiltInKeyReserved, map.set(.notes_directory, chord));
    }
    try map.set(.notes_float, .{ .key = .z, .option = true });
    try std.testing.expectError(error.BuiltInKeyReserved, Map.parse("[keys]\nnotes_directory = \"cmd+s\"\n"));
    try std.testing.expectError(error.InvalidKey, Map.parse("[keys]\nai = \"unbound\"\n"));
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
