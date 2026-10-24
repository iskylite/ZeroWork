//! ui.view.slotParts requires every dimension of slot recipe: missing is compile error, not any
//! slot silently defaulting.
const ui = @import("ui");
const R = ui.sva(.{
    .slots = .{ .root, .label },
    .variants = .{ .tone = .{ .a = .{ .root = .{ .gap = 1 } }, .b = .{} }, .size = .{ .sm = .{}, .md = .{} } },
});
test {
    _ = ui.view.slotParts(R, .{ .tone = .a });
}
