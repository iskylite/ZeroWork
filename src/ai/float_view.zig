const std = @import("std");
const float = @import("float_model.zig");
const status = @import("status.zig");
const cards = @import("card_stream.zig");
const input_model = @import("input_model.zig");

pub const CardKind = enum { text, code, execution_plan, execution_state, file_ref };
pub const CardView = struct { kind: CardKind, title: []const u8, body: []const u8 };

pub const Snapshot = struct {
    visible: bool,
    expanded: bool,
    width: f32,
    height: f32,
    status_text: []const u8,
    status_color: []const u8,
    prompt: []const u8,
    card_count: usize,
    retry_visible: bool,
};

pub const Controller = struct {
    model: float.Model = .{},
    input: input_model.Input = .{},
    stream: cards.Stream,

    pub fn init(allocator: std.mem.Allocator) Controller {
        return .{ .stream = cards.Stream.init(allocator) };
    }

    pub fn deinit(self: *Controller) void {
        self.stream.deinit();
    }

    pub fn snapshot(self: *Controller, pane: float.Rect, window: float.Rect) Snapshot {
        self.model.setCardCount(self.stream.count());
        const rect = self.model.rect(pane, window);
        return .{
            .visible = self.model.visible,
            .expanded = self.model.expanded,
            .width = rect.width,
            .height = rect.height,
            .status_text = if (self.model.status.message.len == 0) "Ask AI" else self.model.status.message,
            .status_color = status.colorName(self.model.status.state),
            .prompt = self.model.prompt,
            .card_count = self.stream.count(),
            .retry_visible = self.model.retryVisible(),
        };
    }

    pub fn cardView(self: Controller, index: usize) ?CardView {
        const card = if (index < self.stream.cards.items.len) self.stream.cards.items[index] else return null;
        return switch (card) {
            .text => |body| .{ .kind = .text, .title = "Text", .body = body },
            .code => |code| .{ .kind = .code, .title = code.lang, .body = code.body },
            .exec_plan => |plan| .{ .kind = .execution_plan, .title = "Run", .body = plan.cmd },
            .exec_state => |state| .{ .kind = .execution_state, .title = @tagName(state.phase), .body = state.summary },
            .file_ref => |file| .{ .kind = .file_ref, .title = file.path, .body = "remote file" },
        };
    }

    pub fn appendInput(self: *Controller, bytes: []const u8) !void {
        try self.input.append(bytes);
        self.model.setPrompt(self.input.text());
    }

    pub fn backspaceInput(self: *Controller) void {
        self.input.backspace();
        self.model.setPrompt(self.input.text());
    }

    pub fn submitInput(self: *Controller) ?[]const u8 {
        const submitted = self.input.submit() orelse return null;
        self.model.status.state = .thinking;
        self.model.status.message = "Thinking";
        return submitted;
    }

    pub fn clearInput(self: *Controller) void {
        self.input.clear();
        self.model.setPrompt("");
    }

    pub fn setPrompt(self: *Controller, prompt: []const u8) void {
        self.model.setPrompt(prompt);
    }
    pub fn toggle(self: *Controller) void {
        self.model.toggle();
    }
    pub fn toggleExpanded(self: *Controller) void {
        self.model.setExpanded(!self.model.expanded);
    }
};

test "AI float snapshot reflects cards, status and expanded geometry" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();
    try controller.appendInput("inspect output");
    try std.testing.expectEqualStrings("inspect output", controller.submitInput().?);
    try std.testing.expectEqual(status.State.thinking, controller.model.status.state);
    controller.clearInput();
    controller.toggle();
    _ = try controller.stream.append(.{ .text = "answer" });
    const snapshot = controller.snapshot(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, .{ .x = 0, .y = 0, .width = 900, .height = 700 });
    try std.testing.expect(snapshot.visible);
    try std.testing.expectEqual(@as(usize, 1), snapshot.card_count);
    try std.testing.expectEqualStrings("inspect output", snapshot.prompt);
    const card = controller.cardView(0).?;
    try std.testing.expectEqual(CardKind.text, card.kind);
    try std.testing.expectEqualStrings("answer", card.body);
    try std.testing.expectEqualStrings("secondary", snapshot.status_color);
    controller.toggleExpanded();
    const expanded = controller.snapshot(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, .{ .x = 0, .y = 0, .width = 900, .height = 700 });
    try std.testing.expectEqual(@as(f32, 600), expanded.width);
    try std.testing.expectEqual(@as(f32, 456), expanded.height);
}
