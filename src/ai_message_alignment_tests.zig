const std = @import("std");
const ui = @import("ui");
const S = @import("ui/ai_assistant_styles.zig");

test "AI user messages align with the Figma conversation content before its scrollbar gutter" {
    for ([_]f32{ 520, 600, 1100 }) |width| {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(width, 900);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        const conversation = try ui.box(cx, S.conversation(cx.tokens), .{});
        try cx.root.?.appendChild(cx.allocator, conversation);
        const content_width = width - 40;
        for ([_][]const u8{ "简短问题", "This is a long user prompt which must wrap within the seventy five percent bubble limit and remain aligned to the right edge rather than falling back to the left because of its unwrapped intrinsic width. This also represents a restored conversation message." }) |prompt| {
            const row = try ui.box(cx, S.messageRow(true), .{});
            try conversation.appendChild(cx.allocator, row);
            const bubble = try ui.box(cx, S.userBubble(content_width), .{});
            try row.appendChild(cx.allocator, bubble);
            try bubble.appendChild(cx.allocator, try ui.text(cx, prompt, .{ .font_size = 12.5, .wrap = .word, .line_height = 1.5 }));
            cx.layout();
            const bounds = bubble.globalRect();
            const parent = row.globalRect();
            try std.testing.expectApproxEqAbs(width - 28, parent.w, 0.1);
            try std.testing.expectApproxEqAbs(width - 26, bounds.x + bounds.w, 0.1);
            try std.testing.expect(bounds.w > 0 and bounds.w <= content_width * 0.75 + 0.1);
            try std.testing.expectApproxEqAbs(parent.x + parent.w - 12, bounds.x + bounds.w, 0.1);
        }
        const reply_row = try ui.box(cx, S.messageRow(false), .{});
        try conversation.appendChild(cx.allocator, reply_row);
        const reply = try ui.box(cx, .{ .max_width = 480 }, .{});
        try reply.appendChild(cx.allocator, try ui.text(cx, "Assistant reply", .{ .font_size = 12.5 }));
        try reply_row.appendChild(cx.allocator, reply);
        cx.layout();
        try std.testing.expectApproxEqAbs(reply_row.globalRect().x, reply.globalRect().x, 0.1);
    }
}
