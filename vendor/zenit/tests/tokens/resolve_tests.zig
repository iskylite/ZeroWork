const std = @import("std");
const resolver = @import("token_resolver");
const m = @import("token_model");
const a = std.testing.allocator;

fn value(doc: *const m.Document, mode: []const u8, path: []const u8) !m.Value {
    for (doc.modes) |mde| if (std.mem.eql(u8, mde.name, mode)) {
        for (doc.tokens, 0..) |tok, i| if (std.mem.eql(u8, tok.path, path)) return mde.values[i];
    };
    return error.NotFound;
}

const valid =
    \\{"$version":1,"$modes":{"hc":{"scheme":"dark","fallback":"dark"}},
    \\"tokens":{"font_size":{"xLargeBlaBla":32},"color":{"base":{"$light":"#1234","$dark":"#11223344","$hc":"#ff0"}}},
    \\"semantic":{"color":{"surface":{"$light":"{tokens.color.base}"},"alias":"{semantic.color.surface}"},
    \\"typography":{"title":{"font_size":"{tokens.font_size.xLargeBlaBla}"}},
    \\"shadow":{"card":{"color":"{semantic.color.surface}"}}}}
;

test "aliases preserve request mode through fallback; compound defaults are explicit" {
    var doc = try resolver.parse(a, valid);
    defer doc.deinit();
    if (doc.diagnostic) |d| std.debug.print("{s} {s}\n", .{ d.pointer, d.message });
    try std.testing.expect(doc.diagnostic == null);
    try std.testing.expectEqual(@as(u8, 0x44), (try value(&doc, "light", "color.alias")).color.a);
    try std.testing.expectEqual(@as(u8, 255), (try value(&doc, "hc", "color.alias")).color.r);
    try std.testing.expectEqual(@as(u8, 0), (try value(&doc, "hc", "color.alias")).color.b);
    const shadow = (try value(&doc, "dark", "shadow.card")).shadow;
    try std.testing.expectEqual(@as(f32, 0), shadow.blur);
    try std.testing.expectEqual(@as(f32, 0), shadow.offset_y);
    const typo = (try value(&doc, "dark", "typography.title")).typography;
    try std.testing.expectEqual(@as(?f32, 32), typo.font_size);
    try std.testing.expect(typo.font_weight == null and typo.line_height == null);
}

test "mode-specific reference graphs must not be rejected as a union cycle" {
    const source =
        \\{"$version":1,"tokens":{"space":{"a":{"$light":"{tokens.space.b}","$dark":2},"b":{"$light":1,"$dark":"{tokens.space.a}"}}}}
    ;
    var doc = try resolver.parse(a, source);
    defer doc.deinit();
    try std.testing.expect(doc.diagnostic == null);
    try std.testing.expectEqual(@as(f32, 1), (try value(&doc, "light", "space.a")).number);
    try std.testing.expectEqual(@as(f32, 2), (try value(&doc, "dark", "space.b")).number);
}

test "reject invalid declarations before emitting any provider" {
    const bodies = [_][]const u8{
        \\{"$version":1,"tokens":{"space":{"x":1}},"semantic":{"space":{"x":1}}}
        ,
        \\{"$version":1,"tokens":{"color":{"action":"#fff"}},"semantic":{"color":{"action":{"hover":"#000"}}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":1,"\u0078":2}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":"{semantic.space.y}"}},"semantic":{"space":{"y":2}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":"{tokens.duration.x}"},"duration":{"x":1}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":"{tokens.space.missing}"}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":"{tokens.space.y}","y":"{tokens.space.x}"}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":{"$dark":2}}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":{"$light":1,"$dakr":2}}}}
        ,
        \\{"$version":1,"tokens":{"font_size":{"x":1e-100}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":1e100}}}
        ,
        \\{"$version":1,"tokens":{"font_weight":{"x":400.5}}}
        ,
        \\{"$version":1,"tokens":{"opacity":{"x":1.1}}}
        ,
        \\{"$version":1,"tokens":{"color":{"x":"#12345"}}}
        ,
        \\{"$version":1,"tokens":{"shadow":{"x":{"color":"#000","blur":-1}}}}
        ,
        \\{"$version":1,"tokens":{"typography":{"x":{}}}}
        ,
        \\{"$version":1,"tokens":{"typography":{"x":{"font_size":{"$light":14}}}}}
        ,
        \\{"$version":1,"tokens":{"control":{"x":{"font_size":10,"line_height":1,"radius":0,"padding_y":0,"padding_h":0,"padding_leading_icon":0,"icon_size":20,"gap":0}}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":{"$value":1,"oops":2}}}}
        ,
        \\{"$version":1,"tokens":{},"unexpected":{}}
        ,
        \\{"$version":1,"tokens":{},"$modes":{"hc":{"scheme":"dark","fallback":"hc"}}}
        ,
        \\{"$version":1,"tokens":{"color":{"x":"#000"}},"bindings":{"color.typo":"{tokens.color.x}"}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":1}},"bindings":{"color.bg_primary":"{tokens.space.x}"}}
        ,
        \\{"$version":1,"tokens":{},}
        ,
        \\{"$version":1,"tokens":{"space":{"x":true}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":null}}}
        ,
        \\{"$version":1,"tokens":{"space":{"x":[1,2]}}}
        ,
    };
    for (bodies) |source| {
        var doc = try resolver.parse(a, source);
        defer doc.deinit();
        if (doc.diagnostic == null) std.debug.print("unexpected success: {s}\n", .{source});
        try std.testing.expect(doc.diagnostic != null);
        try std.testing.expect(doc.diagnostic.?.offset <= source.len);
        try std.testing.expect(doc.diagnostic.?.message.len > 0);
    }
}

test "empty categories, nested merged groups, metadata and arbitrary names" {
    const source =
        \\{"$version":1,"tokens":{"color":{},"space":{"group":{"500":1,"error":2,"extra-large":3}},"font_size":{"same":14}},"semantic":{"space":{"group":{"new":{"$value":4,"$description":"note"}},"same":5}}}
    ;
    var doc = try resolver.parse(a, source);
    defer doc.deinit();
    try std.testing.expect(doc.diagnostic == null);
    try std.testing.expectEqual(@as(usize, 6), doc.tokens.len);
    try std.testing.expectEqual(@as(f32, 4), (try value(&doc, "dark", "space.group.new")).number);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var doc = try resolver.parse(allocator, valid);
    defer doc.deinit();
    try std.testing.expect(doc.diagnostic == null);
    var bad = try resolver.parse(allocator, "{\"$version\":1,\"tokens\":{\"space\":{\"x\":-1}}}");
    defer bad.deinit();
    try std.testing.expect(bad.diagnostic != null);
}
test "resolver owns all allocations on success error and allocation failure" {
    try std.testing.checkAllAllocationFailures(a, allocationProbe, .{});
}

test "generation is byte-stable across declaration order and retains precise locations" {
    const emitter = @import("token_emitter");
    const left = "{\"$version\":1,\"tokens\":{\"space\":{\"b\":2,\"a\":1}}}";
    const right = "{\"tokens\":{\"space\":{\"a\":1,\"b\":2}},\"$version\":1}";
    var d1 = try resolver.parse(a, left);
    defer d1.deinit();
    var d2 = try resolver.parse(a, right);
    defer d2.deinit();
    try std.testing.expect(d1.diagnostic == null and d2.diagnostic == null);
    const out1 = try emitter.generate(a, &d1);
    defer a.free(out1);
    const out2 = try emitter.generate(a, &d2);
    defer a.free(out2);
    try std.testing.expectEqualStrings(out1, out2);
    const malformed = "{\n \"$version\":1,\n \"tokens\":{\"space\":{\"ok\":1,\"bad\":-2}}}";
    var bad = try resolver.parse(a, malformed);
    defer bad.deinit();
    try std.testing.expect(bad.diagnostic != null);
    try std.testing.expectEqualStrings("/tokens/space/bad", bad.diagnostic.?.pointer);
    try std.testing.expect(bad.diagnostic.?.offset >= std.mem.indexOf(u8, malformed, "\"bad\"").?);
}

fn emissionAllocationProbe(allocator: std.mem.Allocator, doc: *const m.Document) !void {
    const output = try @import("token_emitter").generate(allocator, doc);
    defer allocator.free(output);
}
test "emitter releases transient allocations and returned output on OOM" {
    var doc = try resolver.parse(a, valid);
    defer doc.deinit();
    try std.testing.expect(doc.diagnostic == null);
    try std.testing.checkAllAllocationFailures(a, emissionAllocationProbe, .{&doc});
}

test "deep dependency chains use a bounded traversal rather than JSON recursion depth" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "{\"$version\":1,\"tokens\":{\"space\":{");
    for (0..1024) |i| {
        const part = try std.fmt.allocPrint(a, "\"n{d}\":\"{{tokens.space.n{d}}}\",", .{ i, i + 1 });
        defer a.free(part);
        try source.appendSlice(a, part);
    }
    try source.appendSlice(a, "\"n1024\":7}}}");
    var doc = try resolver.parse(a, source.items);
    defer doc.deinit();
    try std.testing.expect(doc.diagnostic == null);
    try std.testing.expectEqual(@as(f32, 7), (try value(&doc, "dark", "space.n0")).number);
}

test "JSON depth and malformed UTF-8 fail safely" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "{\"$version\":1,\"tokens\":{\"space\":{");
    for (0..65) |_| try source.appendSlice(a, "\"g\":{");
    try source.appendSlice(a, "\"x\":1");
    for (0..68) |_| try source.append(a, '}');
    var doc = try resolver.parse(a, source.items);
    defer doc.deinit();
    try std.testing.expect(doc.diagnostic != null);
    var utf = try resolver.parse(a, "{\"$version\":1,\"tokens\":{},\"$schema\":\"\xff\"}");
    defer utf.deinit();
    try std.testing.expect(utf.diagnostic != null);
}

test "hex syntax excludes signed or underscored integer spellings" {
    for ([_][]const u8{ "#+1+1+1", "#0_0_0_" }) |color| {
        const source = try std.fmt.allocPrint(a, "{{\"$version\":1,\"tokens\":{{\"color\":{{\"x\":\"{s}\"}}}}}}", .{color});
        defer a.free(source);
        var doc = try resolver.parse(a, source);
        defer doc.deinit();
        try std.testing.expect(doc.diagnostic != null);
    }
}

test "bindings is not part of the token language" {
    var doc = try resolver.parse(a, "{\"$version\":1,\"tokens\":{},\"bindings\":{}}");
    defer doc.deinit();
    const diagnostic = doc.diagnostic orelse return error.ExpectedDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "bindings") != null);
}

test "component size matrices are not a theme category" {
    var doc = try resolver.parse(a,
        \\{"$version":1,"tokens":{"control":{"md":{"font_size":14,"line_height":1.25,"radius":8,"padding_y":7.25,"padding_h":12,"padding_leading_icon":10,"icon_size":16,"gap":6}}}}
    );
    defer doc.deinit();
    const diagnostic = doc.diagnostic orelse return error.ExpectedDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "control") != null);
}
