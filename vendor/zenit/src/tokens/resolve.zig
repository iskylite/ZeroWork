//! Strict, source-located token declarations and per-mode dependency resolution.
const std = @import("std");
const m = @import("token_model");
const A = std.mem.Allocator;
const E = error{ InvalidInput, OutOfMemory };
const Obj = std.StringArrayHashMapUnmanaged(*Node);
const Node = struct {
    offset: usize,
    pointer: []const u8,
    value: union(enum) { object: Obj, string: []const u8, number: []const u8, other },
};
const Rule = struct { category: m.Category, secondary: ?m.Category = null, signed: bool = false };
const Field = struct { name: []const u8, expr: *Expr };
const Expr = struct {
    node: *Node,
    category: m.Category,
    value: union(enum) { literal: m.Value, ref: usize, branches: []?*Expr, fields: []Field },
};
const Draft = struct { token: m.Token, node: *Node, expr: ?*Expr = null };
const ModeDraft = struct { name: []const u8, scheme: m.Scheme, fallback_name: ?[]const u8, node: ?*Node };

pub fn parse(allocator: A, source: []const u8) A.Error!m.Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    // Enforce the byte limit before copying untrusted input into the arena.
    if (source.len > 8 * 1024 * 1024) return .{
        .arena = arena,
        .diagnostic = .{ .offset = 0, .pointer = "", .message = "input exceeds 8 MiB" },
    };
    const a = arena.allocator();
    const owned = try a.dupe(u8, source);
    var scanner = std.json.Scanner.initCompleteInput(a, owned);
    defer scanner.deinit();
    var p: Parser = .{ .a = a, .source = owned, .scanner = &scanner };
    p.run() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidInput => {},
    };
    return .{ .arena = arena, .source = owned, .tokens = p.tokens, .modes = p.modes, .diagnostic = p.diagnostic };
}

const Parser = struct {
    a: A,
    source: []const u8,
    scanner: *std.json.Scanner,
    diagnostic: ?m.Diagnostic = null,
    drafts: std.ArrayList(Draft) = .empty,
    groups: std.StringHashMapUnmanaged(*Node) = .empty,
    paths: std.StringHashMapUnmanaged(*Node) = .empty,
    sources: std.StringHashMapUnmanaged(usize) = .empty,
    tokens: []m.Token = &.{},
    modes: []m.Mode = &.{},

    fn fail(p: *Parser, offset: usize, pointer: []const u8, comptime fmt: []const u8, args: anytype) E {
        p.diagnostic = .{ .offset = offset, .pointer = pointer, .message = std.fmt.allocPrint(p.a, fmt, args) catch return error.OutOfMemory };
        return error.InvalidInput;
    }
    fn bad(p: *Parser, n: *const Node, comptime fmt: []const u8, args: anytype) E {
        return p.fail(n.offset, n.pointer, fmt, args);
    }
    fn formatAlloc(p: *Parser, comptime f: []const u8, args: anytype) E![]const u8 {
        return std.fmt.allocPrint(p.a, f, args);
    }
    fn next(p: *Parser, pointer: []const u8) E!struct { token: std.json.Token, offset: usize } {
        var start = p.scanner.cursor;
        while (start < p.source.len and std.mem.indexOfScalar(u8, " \t\r\n:,", p.source[start]) != null) : (start += 1) {}
        const t = p.scanner.nextAllocMax(p.a, .alloc_always, 8 * 1024 * 1024) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return p.fail(@min(p.scanner.cursor, p.source.len), pointer, "invalid JSON: {s}", .{@errorName(err)});
        };
        return .{ .token = t, .offset = start };
    }
    fn string(t: std.json.Token) ?[]const u8 {
        return switch (t) {
            .string, .allocated_string => |s| s,
            else => null,
        };
    }
    fn childPointer(p: *Parser, parent: []const u8, key: []const u8) E![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.a, parent);
        try out.append(p.a, '/');
        for (key) |c| switch (c) {
            '~' => try out.appendSlice(p.a, "~0"),
            '/' => try out.appendSlice(p.a, "~1"),
            else => try out.append(p.a, c),
        };
        return out.items;
    }
    fn read(p: *Parser, t: std.json.Token, offset: usize, pointer: []const u8, depth: usize) E!*Node {
        const n = try p.a.create(Node);
        n.* = .{ .offset = offset, .pointer = pointer, .value = .other };
        switch (t) {
            .object_begin => {
                if (depth > 64) return p.bad(n, "JSON nesting exceeds 64", .{});
                n.value = .{ .object = .{} };
                while (true) {
                    const key = try p.next(pointer);
                    if (key.token == .object_end) break;
                    const name = string(key.token) orelse return p.fail(key.offset, pointer, "expected object key", .{});
                    const child = try p.childPointer(pointer, name);
                    if (n.value.object.contains(name)) return p.fail(key.offset, child, "duplicate JSON key: {s}", .{name});
                    const val = try p.next(child);
                    const node = try p.read(val.token, val.offset, child, depth + 1);
                    try n.value.object.put(p.a, name, node);
                }
            },
            .array_begin => return p.bad(n, "arrays are not token declarations", .{}),
            .string, .allocated_string => |s| n.value = .{ .string = s },
            .number, .allocated_number => |s| n.value = .{ .number = s },
            .true, .false, .null => {},
            else => return p.bad(n, "expected JSON value", .{}),
        }
        return n;
    }
    fn object(p: *Parser, n: *Node) E!Obj {
        if (n.value != .object) return p.bad(n, "expected object", .{});
        return n.value.object;
    }
    fn text(p: *Parser, n: *Node) E![]const u8 {
        if (n.value != .string) return p.bad(n, "expected string", .{});
        return n.value.string;
    }
    fn keys(p: *Parser, n: *Node, allowed: []const []const u8) E!void {
        const obj = try p.object(n);
        for (obj.keys()) |key| {
            for (allowed) |known| {
                if (std.mem.eql(u8, key, known)) break;
            } else return p.bad(obj.get(key).?, "unknown field: {s}", .{key});
        }
    }
    fn require(p: *Parser, n: *Node, key: []const u8) E!*Node {
        const obj = try p.object(n);
        return obj.get(key) orelse return p.bad(n, "missing required field: {s}", .{key});
    }
    fn validName(name: []const u8) bool {
        if (name.len == 0) return false;
        for (name, 0..) |c, i| if (!(std.ascii.isAlphanumeric(c) or c == '_' or (i > 0 and c == '-'))) return false;
        return true;
    }
    fn checkName(p: *Parser, n: *Node, key: []const u8) E!void {
        if (!validName(key)) return p.bad(n, "invalid name: {s}", .{key});
    }
    fn modeIndex(p: *Parser, name_: []const u8) ?usize {
        for (p.modes, 0..) |mode, i| if (std.mem.eql(u8, mode.name, name_)) return i;
        return null;
    }
    fn hasDollar(obj: Obj) bool {
        for (obj.keys()) |key| if (std.mem.startsWith(u8, key, "$")) return true;
        return false;
    }
    fn run(p: *Parser) E!void {
        const first = try p.next("");
        const root = try p.read(first.token, first.offset, "", 1);
        if ((try p.next("")).token != .end_of_document) return p.bad(root, "unexpected trailing input", .{});
        try p.keys(root, &.{ "$version", "$schema", "$modes", "tokens", "semantic" });
        const version = try p.require(root, "$version");
        if (version.value != .number) return p.bad(version, "expected $version 1", .{});
        const v = std.fmt.parseFloat(f64, version.value.number) catch return p.bad(version, "expected $version 1", .{});
        if (v != 1) return p.bad(version, "unsupported $version", .{});
        if (root.value.object.get("$schema")) |n| _ = try p.text(n);
        try p.readModes(root);
        try p.materials(try p.require(root, "tokens"), "tokens");
        if (root.value.object.get("semantic")) |n| try p.materials(n, "semantic");
        std.mem.sort(Draft, p.drafts.items, {}, struct {
            fn less(_: void, l: Draft, r: Draft) bool {
                return std.mem.lessThan(u8, l.token.path, r.token.path);
            }
        }.less);
        p.tokens = try p.a.alloc(m.Token, p.drafts.items.len);
        for (p.drafts.items, 0..) |draft, i| {
            p.tokens[i] = draft.token;
            try p.sources.put(p.a, draft.token.source_path, i);
        }
        for (p.drafts.items) |*draft| draft.expr = try p.expression(.{ .category = draft.token.category }, draft.node, std.mem.startsWith(u8, draft.token.source_path, "tokens."), true, true);
        try p.resolveModes();
    }
    fn readModes(p: *Parser, root: *Node) E!void {
        var ds: std.ArrayList(ModeDraft) = .empty;
        try ds.append(p.a, .{ .name = "light", .scheme = .light, .fallback_name = null, .node = null });
        try ds.append(p.a, .{ .name = "dark", .scheme = .dark, .fallback_name = "light", .node = null });
        if (root.value.object.get("$modes")) |n| {
            const obj = try p.object(n);
            if (obj.count() > 62) return p.bad(n, "mode count exceeds 64 including light/dark", .{});
            for (obj.keys(), obj.values()) |key, child| {
                try p.checkName(child, key);
                for ([_][]const u8{ "light", "dark", "value", "description", "version", "schema", "modes" }) |reserved| if (std.mem.eql(u8, key, reserved)) return p.bad(child, "reserved mode name: {s}", .{key});
                try p.keys(child, &.{ "scheme", "fallback" });
                const scheme = try p.text(try p.require(child, "scheme"));
                const s = std.meta.stringToEnum(m.Scheme, scheme) orelse return p.bad(child, "scheme must be light or dark", .{});
                const fallback = try p.text(try p.require(child, "fallback"));
                try ds.append(p.a, .{ .name = key, .scheme = s, .fallback_name = fallback, .node = child });
            }
        }
        std.mem.sort(ModeDraft, ds.items, {}, struct {
            fn less(_: void, l: ModeDraft, r: ModeDraft) bool {
                return std.mem.lessThan(u8, l.name, r.name);
            }
        }.less);
        p.modes = try p.a.alloc(m.Mode, ds.items.len);
        for (ds.items, 0..) |mode, i| p.modes[i] = .{ .name = mode.name, .scheme = mode.scheme, .fallback = null, .values = &.{} };
        for (ds.items, 0..) |mode, i| if (mode.fallback_name) |fallback| {
            p.modes[i].fallback = p.modeIndex(fallback) orelse return p.bad(mode.node orelse root, "unknown fallback mode: {s}", .{fallback});
        };
        for (p.modes, 0..) |_, i| {
            var visited = @as([64]bool, @splat(false));
            var cur: ?usize = i;
            while (cur) |idx| {
                if (visited[idx]) return p.bad(ds.items[i].node orelse root, "mode fallback cycle", .{});
                visited[idx] = true;
                cur = p.modes[idx].fallback;
            }
        }
    }
    fn materials(p: *Parser, n: *Node, layer: []const u8) E!void {
        const cats = try p.object(n);
        for (cats.keys(), cats.values()) |key, category_node| {
            const category = std.meta.stringToEnum(m.Category, key) orelse return p.bad(category_node, "unknown category: {s}", .{key});
            const names = try p.object(category_node);
            for (names.keys(), names.values()) |name_, child| {
                try p.checkName(child, name_);
                try p.collect(layer, category, try p.formatAlloc("{s}.{s}", .{ key, name_ }), child);
            }
        }
    }
    fn collect(p: *Parser, layer: []const u8, category: m.Category, path: []const u8, n: *Node) E!void {
        const composite = category == .shadow or category == .typography;
        if (!composite and n.value == .object and !hasDollar(n.value.object)) {
            if (p.paths.get(path)) |previous| return p.bad(n, "token/group conflict: {s}; first declaration {s}", .{ path, previous.pointer });
            try p.groups.put(p.a, path, n);
            for (n.value.object.keys(), n.value.object.values()) |key, child| {
                try p.checkName(child, key);
                try p.collect(layer, category, try p.formatAlloc("{s}.{s}", .{ path, key }), child);
            }
        } else {
            if (p.paths.get(path)) |previous| return p.bad(n, "duplicate token: {s}; first declaration {s}", .{ path, previous.pointer });
            if (p.groups.get(path)) |previous| return p.bad(n, "token/group conflict: {s}; first declaration {s}", .{ path, previous.pointer });
            if (p.drafts.items.len == 65536) return p.bad(n, "token count exceeds 65536", .{});
            try p.paths.put(p.a, path, n);
            try p.drafts.append(p.a, .{ .token = .{ .path = path, .source_path = try p.formatAlloc("{s}.{s}", .{ layer, path }), .category = category, .offset = n.offset, .pointer = n.pointer }, .node = n });
        }
    }
    fn newExpr(p: *Parser, rule: Rule, n: *Node) E!*Expr {
        const x = try p.a.create(Expr);
        x.* = .{ .node = n, .category = rule.category, .value = undefined };
        return x;
    }
    fn reference(p: *Parser, n: *Node, base: bool) E!usize {
        const s = try p.text(n);
        if (s.len < 3 or s[0] != '{' or s[s.len - 1] != '}') return p.bad(n, "expected a complete token reference", .{});
        const path = s[1 .. s.len - 1];
        const idx = p.sources.get(path) orelse return p.bad(n, "unknown token reference: {s}", .{path});
        if (base and std.mem.startsWith(u8, path, "semantic.")) return p.bad(n, "base tokens cannot depend on semantic: {s}", .{path});
        return idx;
    }
    fn expression(p: *Parser, rule: Rule, n: *Node, base: bool, metadata: bool, modes: bool) E!*Expr {
        if (n.value == .object and hasDollar(n.value.object)) {
            const obj = n.value.object;
            if (obj.get("$value")) |child| {
                if (!metadata) return p.bad(n, "metadata wrapper is only allowed at token root", .{});
                try p.keys(n, &.{ "$value", "$description" });
                if (obj.get("$description")) |d| _ = try p.text(d);
                return p.expression(rule, child, base, false, modes);
            }
            if (!modes) return p.bad(n, "nested mode objects are not supported", .{});
            if (!obj.contains("$light")) return p.bad(n, "mode object requires $light", .{});
            const out = try p.newExpr(rule, n);
            const branches = try p.a.alloc(?*Expr, p.modes.len);
            @memset(branches, null);
            for (obj.keys(), obj.values()) |key, child| {
                if (key.len < 2 or key[0] != '$') return p.bad(child, "mode objects only accept mode keys", .{});
                const idx = p.modeIndex(key[1..]) orelse return p.bad(child, "unknown mode: {s}", .{key});
                branches[idx] = try p.expression(rule, child, base, false, false);
            }
            out.value = .{ .branches = branches };
            return out;
        }
        const out = try p.newExpr(rule, n);
        if (n.value == .string and std.mem.startsWith(u8, n.value.string, "{")) {
            const idx = try p.reference(n, base);
            const cat = p.tokens[idx].category;
            if (cat != rule.category and (rule.secondary == null or cat != rule.secondary.?)) return p.bad(n, "expected {s} reference, found {s}: {s}", .{ @tagName(rule.category), @tagName(cat), p.tokens[idx].source_path });
            out.value = .{ .ref = idx };
            return out;
        }
        if (rule.category == .shadow or rule.category == .typography) {
            out.value = .{ .fields = try p.compound(rule.category, n, base) };
            return out;
        }
        out.value = .{ .literal = try p.scalar(rule, n) };
        return out;
    }
    fn scalar(p: *Parser, rule: Rule, n: *Node) E!m.Value {
        if (rule.category == .color) {
            const s = try p.text(n);
            const len = s.len;
            if ((len != 4 and len != 5 and len != 7 and len != 9) or s[0] != '#') return p.bad(n, "expected #RGB/#RGBA/#RRGGBB/#RRGGBBAA", .{});
            for (s[1..]) |c| if (std.mem.indexOfScalar(u8, "0123456789abcdefABCDEF", c) == null) return p.bad(n, "invalid hex color", .{});
            var channels = [_]u8{ 0, 0, 0, 255 };
            const short = len < 6;
            const count = if (len == 5 or len == 9) @as(usize, 4) else 3;
            for (0..count) |i| {
                const start = 1 + i * (if (short) @as(usize, 1) else 2);
                const x = std.fmt.parseInt(u8, s[start .. start + (if (short) @as(usize, 1) else 2)], 16) catch return p.bad(n, "invalid hex color", .{});
                channels[i] = if (short) x * 17 else x;
            }
            return .{ .color = .{ .r = channels[0], .g = channels[1], .b = channels[2], .a = channels[3] } };
        }
        if (n.value != .number) return p.bad(n, "expected numeric {s} value or reference", .{@tagName(rule.category)});
        const d = std.fmt.parseFloat(f64, n.value.number) catch return p.bad(n, "invalid number", .{});
        if (!std.math.isFinite(d)) return p.bad(n, "number must be finite", .{});
        if (rule.category == .font_weight) {
            if (d < 1 or d > 1000 or @floor(d) != d) return p.bad(n, "font_weight must be an integer in 1..1000", .{});
            return .{ .weight = @intFromFloat(d) };
        }
        const positive = rule.category == .font_size or rule.category == .line_height;
        if ((!rule.signed and d < 0) or (positive and d <= 0) or (rule.category == .opacity and d > 1)) return p.bad(n, "value outside {s} range", .{@tagName(rule.category)});
        const f: f32 = @floatCast(d);
        if (!std.math.isFinite(f) or (positive and f <= 0)) return p.bad(n, "value not representable as finite {s}", .{@tagName(rule.category)});
        return .{ .number = f };
    }
    fn compound(p: *Parser, cat: m.Category, n: *Node, base: bool) E![]Field {
        const obj = try p.object(n);
        const allowed: []const []const u8 = switch (cat) {
            .shadow => &.{ "color", "blur", "spread", "offset_x", "offset_y" },
            .typography => &.{ "font_size", "font_weight", "line_height" },
            else => unreachable,
        };
        try p.keys(n, allowed);
        if (cat == .shadow) _ = try p.require(n, "color");
        if (cat == .typography and obj.count() == 0) return p.bad(n, "typography requires at least one field", .{});
        const fields = try p.a.alloc(Field, obj.count());
        for (obj.keys(), obj.values(), 0..) |key, child, i| {
            var rule: Rule = .{ .category = .space };
            if (cat == .shadow) {
                if (std.mem.eql(u8, key, "color")) rule.category = .color else {
                    rule.secondary = .size;
                    rule.signed = !std.mem.eql(u8, key, "blur");
                }
            } else if (cat == .typography) {
                rule.category = std.meta.stringToEnum(m.Category, key).?;
            }
            fields[i] = .{ .name = key, .expr = try p.expression(rule, child, base, false, false) };
        }
        return fields;
    }
    fn selected(p: *Parser, e: *Expr, mode: usize) *Expr {
        if (e.value != .branches) return e;
        var i = mode;
        while (true) {
            if (e.value.branches[i]) |x| return x;
            i = p.modes[i].fallback.?;
        }
    }
    const Frame = struct { idx: usize, finish: bool };
    fn dependencies(p: *Parser, e: *Expr, mode: usize, stack: *std.ArrayList(Frame)) E!void {
        const x = p.selected(e, mode);
        switch (x.value) {
            .ref => |idx| try stack.append(p.a, .{ .idx = idx, .finish = false }),
            .fields => |fields| for (fields) |f| try p.dependencies(f.expr, mode, stack),
            .literal => {},
            .branches => unreachable,
        }
    }
    fn resolveModes(p: *Parser) E!void {
        const states = try p.a.alloc(u8, p.tokens.len);
        var stack: std.ArrayList(Frame) = .empty;
        for (p.modes, 0..) |*mode, mi| {
            @memset(states, 0);
            const vals = try p.a.alloc(m.Value, p.tokens.len);
            mode.values = vals;
            for (0..p.tokens.len) |root| {
                if (states[root] == 2) continue;
                try stack.append(p.a, .{ .idx = root, .finish = false });
                while (stack.pop()) |frame| {
                    const idx = frame.idx;
                    const expr = p.drafts.items[idx].expr.?;
                    if (frame.finish) {
                        vals[idx] = try p.evaluate(expr, mi, vals);
                        states[idx] = 2;
                        continue;
                    }
                    if (states[idx] == 2) continue;
                    if (states[idx] == 1) return p.bad(expr.node, "reference cycle in mode {s}: {s}", .{ mode.name, p.tokens[idx].source_path });
                    states[idx] = 1;
                    try stack.append(p.a, .{ .idx = idx, .finish = true });
                    try p.dependencies(expr, mi, &stack);
                }
            }
        }
    }
    fn convert(comptime T: type, v: m.Value) T {
        if (T == m.values.Color) return v.color;
        if (T == f32 or T == ?f32) return v.number;
        if (T == u16 or T == ?u16) return v.weight;
        @compileError("unsupported compound field");
    }
    fn fill(p: *Parser, comptime T: type, initial: T, fields: []Field, mode: usize, vals: []m.Value) E!T {
        var out = initial;
        for (fields) |field| {
            const v = try p.evaluate(field.expr, mode, vals);
            inline for (@import("zenit_reflection").fields(T)) |f| if (std.mem.eql(u8, field.name, f.name)) {
                @field(out, f.name) = convert(f.type, v);
            };
        }
        return out;
    }
    fn evaluate(p: *Parser, e: *Expr, mode: usize, vals: []m.Value) E!m.Value {
        const x = p.selected(e, mode);
        return switch (x.value) {
            .literal => |v| v,
            .ref => |idx| vals[idx],
            .branches => unreachable,
            .fields => |fields| switch (x.category) {
                .shadow => .{ .shadow = try p.fill(m.values.Shadow, .{ .color = m.values.Color.BLACK, .blur = 0, .spread = 0, .offset_x = 0, .offset_y = 0 }, fields, mode, vals) },
                .typography => .{ .typography = try p.fill(m.values.TypographyPatch, .{}, fields, mode, vals) },
                else => unreachable,
            },
        };
    }
};
