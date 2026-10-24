//! Host CLI for application-owned Design System tokens.
const std = @import("std");
const resolver = @import("token_resolver");
const emitter = @import("token_emitter");
const model = @import("token_model");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("zenit-tokens: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn usage() noreturn {
    std.debug.print("usage: zenit-tokens check INPUT.json\n       zenit-tokens generate INPUT.json --out OUTPUT.zig\n       zenit-tokens explain INPUT.json TOKEN_PATH --mode MODE\n", .{});
    std.process.exit(64);
}
fn run(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3) usage();
    const check = std.mem.eql(u8, args[1], "check");
    const generate = std.mem.eql(u8, args[1], "generate");
    const explain = std.mem.eql(u8, args[1], "explain");
    if (check) {
        if (args.len != 3) usage();
    } else if (generate) {
        if (args.len != 5 or !std.mem.eql(u8, args[3], "--out")) usage();
    } else if (explain) {
        if (args.len != 6 or !std.mem.eql(u8, args[4], "--mode")) usage();
    } else usage();
    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .limited(8 * 1024 * 1024));
    var doc = try resolver.parse(a, source);
    defer doc.deinit();
    if (doc.diagnostic) |d| {
        var line: usize = 1;
        var column: usize = 1;
        for (source[0..@min(d.offset, source.len)]) |c| {
            if (c == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{ args[2], line, column, d.pointer, d.message });
        std.process.exit(1);
    }
    if (check) {
        std.debug.print("valid: {d} tokens, {d} modes\n", .{ doc.tokens.len, doc.modes.len });
    } else if (generate) {
        const output = try emitter.generate(a, &doc);
        var buffer: [4096]u8 = undefined;
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, args[4], .{ .replace = true });
        defer atomic.deinit(io);
        var writer = atomic.file.writer(io, &buffer);
        try writer.interface.writeAll(output);
        try writer.interface.flush();
        try atomic.replace(io);
    } else {
        const mi = for (doc.modes, 0..) |mode, i| {
            if (std.mem.eql(u8, mode.name, args[5])) break i;
        } else return error.UnknownMode;
        const ti = for (doc.tokens, 0..) |tok, i| {
            if (std.mem.eql(u8, tok.path, args[3]) or std.mem.eql(u8, tok.source_path, args[3])) break i;
        } else return error.UnknownToken;
        std.debug.print("{s} [{s}]\n  source: {s} {s}\n  value: {any}\n", .{ doc.tokens[ti].path, doc.modes[mi].name, doc.tokens[ti].source_path, doc.tokens[ti].pointer, doc.modes[mi].values[ti] });
        try trace(a, &doc, mi, ti);
    }
}

fn trace(a: std.mem.Allocator, doc: *const model.Document, mi: usize, ti: usize) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, doc.source, .{});
    defer parsed.deinit();
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(a);
    var seen = std.AutoHashMap(usize, void).init(a);
    defer seen.deinit();
    try pending.append(a, ti);
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        const idx = pending.items[cursor];
        if ((try seen.getOrPut(idx)).found_existing) continue;
        var expression = parsed.value;
        var parts = std.mem.splitScalar(u8, doc.tokens[idx].source_path, '.');
        while (parts.next()) |part| expression = expression.object.get(part).?;
        if (expression == .object) if (expression.object.get("$value")) |v| {
            expression = v;
        };
        if (expression == .object and expression.object.contains("$light")) {
            var selected = mi;
            while (true) {
                const key = try std.fmt.allocPrint(a, "${s}", .{doc.modes[selected].name});
                if (expression.object.get(key)) |v| {
                    std.debug.print("  branch: {s} -> {s} (references still resolve in {s})\n", .{ doc.tokens[idx].source_path, key, doc.modes[mi].name });
                    expression = v;
                    break;
                }
                selected = doc.modes[selected].fallback.?;
            }
        }
        try refs(a, doc, idx, expression, &pending);
    }
}
fn refs(a: std.mem.Allocator, doc: *const model.Document, from: usize, v: std.json.Value, pending: *std.ArrayList(usize)) anyerror!void {
    if (v == .string and std.mem.startsWith(u8, v.string, "{")) {
        const path = v.string[1 .. v.string.len - 1];
        for (doc.tokens, 0..) |tok, idx| if (std.mem.eql(u8, tok.source_path, path)) {
            std.debug.print("  reference: {s} -> {s}\n", .{ doc.tokens[from].source_path, path });
            try pending.append(a, idx);
            return;
        };
    } else if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |entry| try refs(a, doc, from, entry.value_ptr.*, pending);
    }
}
