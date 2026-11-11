const std = @import("std");
const ui = @import("ui");
const SourceRef = @import("../plugins/notes/queries.zig").SourceRef;

pub const Action = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, SourceRef) void,
};

const Citation = struct { title: []const u8, source: SourceRef };

fn escaped(text: []const u8, position: usize) bool {
    var start = position;
    while (start > 0 and text[start - 1] == '\\') start -= 1;
    return (position - start) % 2 != 0;
}

fn labelStart(text: []const u8, separator: usize) ?usize {
    if (escaped(text, separator)) return null;
    var depth: usize = 1;
    var index = separator;
    while (index > separator -| 481) {
        index -= 1;
        switch (text[index]) {
            '\r', '\n' => return null,
            ']' => if (!escaped(text, index)) {
                depth += 1;
            },
            '[' => if (!escaped(text, index)) {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
    }
    return null;
}

fn next(text: []const u8, offset: *usize) ?Citation {
    while (std.mem.indexOfPos(u8, text, offset.*, "](notes:")) |separator| {
        const destination = separator + 2;
        offset.* = destination;
        const opening = labelStart(text, separator) orelse continue;
        if (opening > 0 and text[opening - 1] == '!' and !escaped(text, opening - 1)) continue;
        const title = text[opening + 1 .. separator];
        if (title.len == 0) continue;
        const closing = std.mem.indexOfScalarPos(u8, text, destination, ')') orelse return null;
        if (closing - destination > 128) continue;
        const source = SourceRef.parse(text[destination..closing]) catch continue;
        offset.* = closing + 1;
        return .{ .title = title, .source = source };
    }
    return null;
}

pub fn append(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, text: []const u8, action: Action) !void {
    var seen: [6]SourceRef = undefined;
    var count: usize = 0;
    var offset: usize = 0;
    while (count < seen.len) {
        const citation = next(text, &offset) orelse break;
        for (seen[0..count]) |existing| {
            if (std.meta.eql(existing, citation.source)) break;
        } else {
            seen[count] = citation.source;
            count += 1;
            const click = try scope.createState(Click, .{ .action = action, .source = citation.source });
            const title = try scope.createText(citation.title, .{});
            const button = try ui.widgets.Button(.{
                .label = title,
                .variant = .ghost,
                .icon_asset = ui.icons.notebook,
                .on_click = cx.on(Click, click, Click.open),
            }).mount(scope, cx);
            button.meta.ownership.meta.test_id = "ai.notes.source";
            try parent.appendChild(cx.allocator, button);
        }
    }
}

const Click = struct {
    action: Action,
    source: SourceRef,

    fn open(self: *Click) void {
        self.action.open(self.action.context, self.source);
    }
};

test "notes citations accept stable local references and skip other links" {
    var offset: usize = 0;
    const citation = next("[普通链接](https://example.com) [环境约定](notes:01010101010101010101010101010101:02020202020202020202020202020202:7:2:18)", &offset).?;
    try std.testing.expectEqualStrings("环境约定", citation.title);
    try std.testing.expectEqual(@as(u64, 7), citation.source.revision);
    try std.testing.expectEqual(@as(usize, 18), citation.source.range.end_byte);
    offset = 0;
    try std.testing.expect(next("[损坏](notes:unknown)", &offset) == null);
    offset = 0;
    const source = "(notes:01010101010101010101010101010101:02020202020202020202020202020202:7:2:18)";
    try std.testing.expectEqualStrings("环境 [生产]", next("![图标]" ++ source ++ " \\[示例]" ++ source ++ " [环境 [生产]]" ++ source, &offset).?.title);
}
