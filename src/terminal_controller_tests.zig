const std = @import("std");
const identity = @import("host/identity.zig");
const Controller = @import("vt/terminal_controller.zig").Controller;
const Adapter = @import("vt/ghostty_adapter.zig").Adapter;
const VtEngine = @import("vt/engine.zig").VtEngine;
const TextSlot = @import("vt/text_slot.zig").TextSlot;
const text_frame = @import("vt/text_frame.zig");

test {
    _ = @import("vt/worker_io.zig");
    _ = @import("proto/ssh/relay_pump.zig");
}

const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(7), .generation = 2 };

test "notification controller counts parsed output once through retries owner checks and EOF" {
    var vt = try Adapter.init(std.testing.allocator, 2, 20);
    defer vt.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 2048);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    try controller.feedOutput(owner, 1, "\x1b]0;title\x07", 100);
    try std.testing.expectEqual(@as(u64, 0), controller.status().bell_count);
    try controller.feedOutput(owner, 2, "output\x07", 110);
    try controller.feedOutput(owner, 3, "\x1b]133;A\x07", 120);
    try controller.feedOutput(owner, 4, "\x07\x07TAIL", 130);
    try std.testing.expect(controller.publicationPending());
    const stale = try owner.nextGeneration();
    try std.testing.expectError(error.StaleOwner, controller.feedOutput(stale, 5, "\x07", 140));
    try std.testing.expectError(error.InvalidOutputSequence, controller.feedOutput(owner, 4, "\x07", 140));
    try std.testing.expectError(error.InvalidOutputSequence, controller.feedOutput(owner, 6, "\x07", 140));
    var scratch: [2048]u8 = undefined;
    _ = try slot.take(0, &scratch);
    controller.retryPublication(150);
    controller.retryPublication(160);
    try controller.resizeApplied(owner, .{ .revision = 2, .cols = 24, .rows = 3 }, 170);
    try controller.scroll(owner, .top, 180);
    try controller.setTheme(owner, .{ .revision = 1, .foreground = 0xffffffff, .background = 0x000000ff, .cursor = 0xffffffff, .selection = 0x444444ff, .ansi = @splat(0x888888ff) }, 190);
    _ = try vt.feed("");
    try controller.eof(owner);
    try std.testing.expectError(error.OutputAfterEof, controller.feedOutput(owner, 5, "\x07", 200));
    controller.retryPublication(210);
    const facts = controller.status();
    try std.testing.expect(facts.owner.eql(owner) and facts.eof_seen);
    try std.testing.expectEqual(@as(u64, 4), facts.output_sequence);
    try std.testing.expectEqual(@as(u64, 4), vt.snapshot().output_sequence);
    try std.testing.expectEqual(@as(u64, 3), facts.bell_count);
}

test "terminal controller feeds the real VT once per owner output sequence" {
    var vt = try Adapter.init(std.testing.allocator, 2, 20);
    defer vt.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 2048);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    try controller.feedOutput(owner, 1, "first", 100);
    const stale: identity.SessionHandle = .{ .session_id = owner.session_id, .generation = 1 };
    try std.testing.expectError(error.StaleOwner, controller.feedOutput(stale, 2, "wrong", 110));
    try std.testing.expectError(error.InvalidOutputSequence, controller.feedOutput(owner, 1, "duplicate", 110));
    try std.testing.expectError(error.InvalidOutputSequence, controller.feedOutput(owner, 3, "skipped", 110));
    try controller.feedOutput(owner, 2, "\r\nlast", 120);
    try controller.eof(owner);
    try controller.eof(owner);
    try std.testing.expectError(error.OutputAfterEof, controller.feedOutput(owner, 3, "discarded", 130));
    var scratch: [2048]u8 = undefined;
    const frame = text_frame.decode((try controller.textSlot().take(0, &scratch)).?.text).?;
    try std.testing.expect(std.mem.indexOf(u8, frame.text, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.text, "last") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.text, "wrong") == null);
    try std.testing.expectEqual(@as(u64, 2), controller.status().output_sequence);
    try std.testing.expect(controller.status().eof_seen);
}

test "terminal controller keeps EOF tail while display is backpressured" {
    var vt = try Adapter.init(std.testing.allocator, 2, 20);
    defer vt.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 2048);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    try controller.feedOutput(owner, 1, "a", 100);
    try controller.feedOutput(owner, 2, "b", 110);
    try controller.feedOutput(owner, 3, "c", 120);
    try controller.feedOutput(owner, 4, "TAIL", 130);
    try controller.eof(owner);
    try std.testing.expect(controller.publicationPending());
    var scratch: [2048]u8 = undefined;
    const previous = (try slot.take(0, &scratch)).?;
    try std.testing.expect(std.mem.indexOf(u8, text_frame.decode(previous.text).?.text, "TAIL") == null);
    controller.retryPublication(140);
    try std.testing.expect(!controller.publicationPending());
    const tail = text_frame.decode((try slot.take(previous.generation, &scratch)).?.text).?;
    try std.testing.expect(std.mem.indexOf(u8, tail.text, "abcTAIL") != null);
    try std.testing.expect(controller.status().eof_seen);
}

test "terminal controller applies only successful current-owner geometry" {
    var vt = try Adapter.init(std.testing.allocator, 2, 20);
    defer vt.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 2048);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    try std.testing.expectError(error.InvalidGeometry, controller.resizeApplied(owner, .{ .revision = 2, .cols = 0, .rows = 3 }, 100));
    const stale = try owner.nextGeneration();
    try std.testing.expectError(error.StaleOwner, controller.resizeApplied(stale, .{ .revision = 2, .cols = 30, .rows = 3 }, 100));
    try controller.resizeApplied(owner, .{ .revision = 3, .cols = 30, .rows = 3 }, 100);
    try std.testing.expectError(error.StaleGeometry, controller.resizeApplied(owner, .{ .revision = 2, .cols = 10, .rows = 1 }, 110));
    try std.testing.expectEqual(@as(u64, 3), controller.status().geometry.revision);
    try std.testing.expectEqual(@as(u16, 30), vt.snapshot().cols);
    var scratch: [2048]u8 = undefined;
    const frame = text_frame.decode((try slot.take(0, &scratch)).?.text).?;
    try std.testing.expectEqual(@as(u16, 30), frame.cols);
    try std.testing.expectEqual(@as(u16, 3), frame.rows);
}

test "terminal projection preserves native modes graphemes tagged colors and row identities" {
    var vt = try Adapter.init(std.testing.allocator, 3, 24);
    defer vt.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 8192);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    try controller.feedOutput(owner, 1, "\x1b[?2004h\x1b[?1h\x1b[?1002h\x1b[?1006h\x1b[30mA\x1b[38;2;255;255;255mB\x1b[48;5;196m \x1b[0m界e\u{301}👩‍💻", 100);
    var first = try controller.copyProjection(owner, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.modes.bracketed_paste and first.modes.application_cursor);
    try std.testing.expectEqual(.button, first.modes.mouse_tracking);
    try std.testing.expectEqual(.sgr, first.modes.mouse_format);
    try std.testing.expectEqual(@as(u4, 0), first.cells[0].foreground.ansi);
    try std.testing.expectEqual(@as(u24, 0xffffff), first.cells[1].foreground.rgb);
    try std.testing.expectEqual(@as(u8, 196), first.cells[2].background.indexed);
    try std.testing.expectEqual(.wide_lead, first.cells[3].width);
    try std.testing.expectEqual(.wide_tail, first.cells[4].width);
    try std.testing.expectEqualStrings("e\u{301}", first.grapheme(first.cells[5]));
    try std.testing.expectEqualStrings("👩‍💻", first.grapheme(first.cells[6]));
    const id = first.visible_rows[0].id;
    try controller.feedOutput(owner, 2, "\r\nnext\x1b[31m", 120);
    var next = try controller.copyProjection(owner, std.testing.allocator);
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqual(id, next.visible_rows[0].id);
    try std.testing.expect(next.version > first.version and next.style_version > first.style_version);
    try std.testing.expectEqual(first.mode_revision, next.mode_revision);
    try std.testing.expectEqualStrings("e\u{301}", first.grapheme(first.cells[5])); // owned, still immutable
    try controller.feedOutput(owner, 3, "\x1b[?1049h\x1b[?2004l", 140);
    var alternate = try controller.copyProjection(owner, std.testing.allocator);
    defer alternate.deinit(std.testing.allocator);
    try std.testing.expect(alternate.modes.alternate_screen and !alternate.modes.bracketed_paste);
    try std.testing.expect(alternate.mode_revision > next.mode_revision);
}

test "terminal projection exposes native OSC events and queues parser replies" {
    var vt = try Adapter.init(std.testing.allocator, 3, 24);
    defer vt.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 8192);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    try controller.feedOutput(owner, 1, "\x1b]7;file://localhost/srv/a%20", 100);
    try controller.feedOutput(owner, 2, "b\x07\x1b]133;A\x07% \x1b]133;B\x07", 120);
    var prompt = try controller.copyProjection(owner, std.testing.allocator);
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/srv/a b", prompt.reported_cwd.?);
    try std.testing.expect(prompt.at_prompt);
    try std.testing.expectEqual(@as(usize, 3), prompt.events.len);
    try std.testing.expectEqual(.cwd, prompt.events[0].kind);
    try std.testing.expectEqual(.prompt_start, prompt.events[1].kind);
    try std.testing.expectEqual(.input_start, prompt.events[2].kind);
    try controller.feedOutput(owner, 3, "\x1b]133;C\x07output\x1b]133;D;7\x07\x1b[6n", 140);
    var result = try controller.copyProjection(owner, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(.command_end, result.events[result.events.len - 1].kind);
    try std.testing.expectEqual(@as(i32, 7), result.events[result.events.len - 1].exit_code.?);
    var bytes: [128]u8 = undefined;
    const count = try controller.readReply(owner, &bytes);
    try std.testing.expect(count >= 6 and std.mem.startsWith(u8, bytes[0..count], "\x1b[") and bytes[count - 1] == 'R');
    try std.testing.expectEqual(@as(usize, 0), try controller.readReply(owner, &bytes));
}

test "terminal theme defaults preserve actual OSC overrides and reset to the latest published palette" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 24);
    defer adapter.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 8192);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &adapter), .text_slot = &slot });
    const initial: @import("host/terminal_service.zig").Theme = .{ .revision = 1, .foreground = 0x112233ff, .background = 0x223344ff, .cursor = 0x334455ff, .selection = 0x11111150, .ansi = @splat(0xaa0000ff) };
    try controller.setTheme(owner, initial, 1);
    var defaults = try controller.copyProjection(owner, std.testing.allocator);
    defer defaults.deinit(std.testing.allocator);
    const extended_default = defaults.colors.palette[200];
    try std.testing.expectEqual(@as(u24, 0x112233), defaults.colors.foreground);
    try std.testing.expectEqual(@as(u24, 0xaa0000), defaults.colors.palette[1]);
    try controller.feedOutput(owner, 1, "\x1b]4;1;#00ff00\x07\x1b]4;200;#0000aa\x07\x1b]10;#123456\x07\x1b]11;#234567\x07\x1b]12;#345678\x07same text", 2);
    var next = initial;
    next.revision = 2;
    next.foreground = 0xaabbccff;
    next.background = 0xbbccddff;
    next.cursor = 0xccddeeff;
    next.ansi[1] = 0xff0000ff;
    try controller.setTheme(owner, next, 3);
    var overridden = try controller.copyProjection(owner, std.testing.allocator);
    defer overridden.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u24, 0x123456), overridden.colors.foreground);
    try std.testing.expectEqual(@as(u24, 0x234567), overridden.colors.background);
    try std.testing.expectEqual(@as(?u24, 0x345678), overridden.colors.cursor);
    try std.testing.expectEqual(@as(u24, 0x00ff00), overridden.colors.palette[1]);
    try std.testing.expectEqual(@as(u24, 0x0000aa), overridden.colors.palette[200]);
    try std.testing.expect(overridden.style_version > defaults.style_version);
    const version = adapter.snapshot().version;
    try controller.setTheme(owner, next, 4);
    try std.testing.expectEqual(version, adapter.snapshot().version);
    var conflict = next;
    conflict.foreground = 0;
    try std.testing.expectError(error.ConflictingTheme, controller.setTheme(owner, conflict, 4));
    try std.testing.expectError(error.StaleTheme, controller.setTheme(owner, initial, 4));
    try controller.feedOutput(owner, 2, "\x1b]104;1\x07\x1b]104;200\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07", 5);
    var reset = try controller.copyProjection(owner, std.testing.allocator);
    defer reset.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u24, 0xaabbcc), reset.colors.foreground);
    try std.testing.expectEqual(@as(u24, 0xbbccdd), reset.colors.background);
    try std.testing.expectEqual(@as(?u24, 0xccddee), reset.colors.cursor);
    try std.testing.expectEqual(@as(u24, 0xff0000), reset.colors.palette[1]);
    try std.testing.expectEqual(extended_default, reset.colors.palette[200]);
}

test "terminal controller uses native key and mouse encoders with mode and geometry gates" {
    var vt = try Adapter.init(std.testing.allocator, 3, 24);
    defer vt.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 8192);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    const revision = vt.snapshot().mode_revision;
    const normal = try controller.encodeKey(owner, revision, .{ .key = .arrow_up }, std.testing.allocator);
    defer std.testing.allocator.free(normal);
    try std.testing.expectEqualStrings("\x1b[A", normal);
    const shift_tab = try controller.encodeKey(owner, revision, .{ .key = .tab, .modifiers = .{ .shift = true } }, std.testing.allocator);
    defer std.testing.allocator.free(shift_tab);
    try std.testing.expectEqualStrings("\x1b[Z", shift_tab);
    const control = try controller.encodeKey(owner, revision, .{ .key = .c, .utf8 = "c", .unshifted_codepoint = 'c', .modifiers = .{ .control = true } }, std.testing.allocator);
    defer std.testing.allocator.free(control);
    try std.testing.expectEqualStrings("\x03", control);
    try controller.feedOutput(owner, 1, "\x1b[?1h\x1b[?66h\x1b[?1035l\x1b[?1000h\x1b[?1006h", 100);
    const current = vt.snapshot().mode_revision;
    try std.testing.expectError(error.StaleMode, controller.encodeKey(owner, revision, .{ .key = .arrow_up }, std.testing.allocator));
    const application = try controller.encodeKey(owner, current, .{ .key = .arrow_up }, std.testing.allocator);
    defer std.testing.allocator.free(application);
    try std.testing.expectEqualStrings("\x1bOA", application);
    const keypad = try controller.encodeKey(owner, current, .{ .key = .numpad_1 }, std.testing.allocator);
    defer std.testing.allocator.free(keypad);
    try std.testing.expectEqualStrings("\x1bOq", keypad);
    const mouse = @import("vt/input_event.zig").MouseEvent{ .action = .press, .button = .left, .x = 16, .y = 24, .screen_width = 192, .screen_height = 48, .cell_width = 8, .cell_height = 16 };
    try std.testing.expectError(error.StaleGeometry, controller.encodeMouse(owner, current, 2, mouse, std.testing.allocator));
    const report = try controller.encodeMouse(owner, current, 1, mouse, std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expectEqualStrings("\x1b[<0;3;2M", report);
}

test "terminal native anchors preserve half-open Unicode selection through reflow and scrolling" {
    var vt = try Adapter.init(std.testing.allocator, 3, 8);
    defer vt.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 8192);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    try controller.feedOutput(owner, 1, "A界e\u{301}bcdefgh\r\nsecond", 100);
    const displayed_version = vt.snapshot().version;
    try std.testing.expectError(error.StaleProjection, controller.createAnchor(owner, .{ .row = 0, .col = 0, .source_version = displayed_version - 1 }));
    const fresh = try controller.createAnchor(owner, .{ .row = 0, .col = 0, .source_version = displayed_version });
    try std.testing.expectEqual(displayed_version, (try controller.resolveAnchor(fresh)).?.source_version);
    try controller.releaseAnchor(fresh);
    const start = try controller.createAnchor(owner, .{ .row = 0, .col = 0 });
    defer controller.releaseAnchor(start) catch {};
    const end = try controller.createAnchor(owner, .{ .row = 1, .col = 3 });
    defer controller.releaseAnchor(end) catch {};
    const selected = @import("vt/viewport.zig").OwnedSelection{ .start = start, .end = end };
    const before = try controller.selectionText(selected, std.testing.allocator, 4096);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqualStrings("A界e\u{301}bcdefgh", before);
    try controller.resizeApplied(owner, .{ .revision = 2, .cols = 5, .rows = 4 }, 120);
    const after = try controller.selectionText(selected, std.testing.allocator, 4096);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect((try controller.resolveAnchor(end)).?.row > 1);
    try controller.scroll(owner, .top, 140);
    var top = try controller.copyProjection(owner, std.testing.allocator);
    defer top.deinit(std.testing.allocator);
    try controller.feedOutput(owner, 2, "\r\nthird\r\nfourth\r\nfifth", 160);
    var still_top = try controller.copyProjection(owner, std.testing.allocator);
    defer still_top.deinit(std.testing.allocator);
    try std.testing.expectEqual(top.visible_rows[0].id, still_top.visible_rows[0].id);
    try std.testing.expect(!still_top.cursor.visible);
    try controller.scroll(owner, .bottom, 180);
    var bottom = try controller.copyProjection(owner, std.testing.allocator);
    defer bottom.deinit(std.testing.allocator);
    try std.testing.expect(bottom.scrollback.viewport_offset > still_top.scrollback.viewport_offset);
    try controller.feedOutput(owner, 3, "\x1b[?1049h", 200);
    try std.testing.expectError(error.AnchorNotActive, controller.selectionText(selected, std.testing.allocator, 4096));
    try controller.feedOutput(owner, 4, "\x1b[?1049l", 220);
    try controller.releaseAnchor(end);
    try std.testing.expectError(error.StaleAnchor, controller.resolveAnchor(end));
    const wrong = @import("vt/viewport.zig").OwnedAnchor{ .owner = try owner.nextGeneration(), .id = start.id };
    try std.testing.expectError(error.StaleOwner, controller.resolveAnchor(wrong));
    try controller.resizeApplied(owner, .{ .revision = 3, .cols = 80, .rows = 4 }, 230);
    const c = @import("generated_ghostty_vt");
    const no_history: usize = 0;
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_set(vt.terminal, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, @ptrCast(&no_history)));
    var configured_limit: usize = undefined;
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_get(vt.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES, @ptrCast(&configured_limit)));
    try std.testing.expectEqual(no_history, configured_limit);
    var total_before: usize = undefined;
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_get(vt.terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, @ptrCast(&total_before)));
    // Native limits prune complete pages and retain at least one page of
    // history. Setting zero on the small reflow fixture above need not erase
    // anything; create enough real output to exercise automatic page pruning.
    var history: [6 * 4096]u8 = undefined;
    for (0..4096) |index| @memcpy(history[index * 6 ..][0..6], "tail\r\n");
    try controller.feedOutput(owner, 5, &history, 240);
    var total_after: usize = undefined;
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_get(vt.terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, @ptrCast(&total_after)));
    try std.testing.expect(total_after < total_before + 4096);
    const retained = try @import("vt/ghostty_view.zig").format(vt.terminal, .{ .row = 0, .col = 0 }, .{ .row = @intCast(total_after - 1), .col = 79 }, false, std.testing.allocator, 128 * 1024);
    defer std.testing.allocator.free(retained);
    try std.testing.expect(std.mem.indexOf(u8, retained, "A界e\u{301}") == null);
    try std.testing.expect((try controller.resolveAnchor(start)) == null);
}

test "terminal native rectangular copy and bounded logical context preserve original text" {
    var vt = try Adapter.init(std.testing.allocator, 3, 8);
    defer vt.destroy();
    var slot = try TextSlot.init(std.testing.allocator, 8192);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    try controller.feedOutput(owner, 1, "ab界cd\r\nxy\r\n123456", 100);
    const start = try controller.createAnchor(owner, .{ .row = 0, .col = 1 });
    defer controller.releaseAnchor(start) catch {};
    const end = try controller.createAnchor(owner, .{ .row = 2, .col = 5 });
    defer controller.releaseAnchor(end) catch {};
    const text = try controller.selectionText(.{ .start = start, .end = end, .rectangle = true }, std.testing.allocator, 4096);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("b界c\ny   \n2345", text);
    try std.testing.expectError(error.CopyTooLarge, controller.selectionText(.{ .start = start, .end = end }, std.testing.allocator, 2));
    var lines = try controller.readLines(owner, .{ .max_lines = 1, .max_bytes = 8 }, std.testing.allocator);
    defer lines.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), lines.lines.len);
    try std.testing.expectEqualStrings("123456", lines.lines[0]);
    try std.testing.expect(lines.truncated);
    var tiny = try controller.readLines(owner, .{ .max_lines = 2, .max_bytes = 2 }, std.testing.allocator);
    defer tiny.deinit(std.testing.allocator);
    try std.testing.expect(tiny.truncated and tiny.lines.len == 0);
}

test "terminal logical row wall-clock metadata survives reflow and fixes actual submission time" {
    const Clock = struct {
        var value: i64 = 1_750_000_000_000;
        fn now() i64 {
            return value;
        }
    };
    Clock.value = 1_750_000_000_000;
    var vt = try Adapter.init(std.testing.allocator, 4, 8);
    defer vt.destroy();
    vt.wall_clock_ms = Clock.now;
    var slot = try TextSlot.init(std.testing.allocator, 8192);
    defer slot.deinit(std.testing.allocator);
    var controller = try Controller.init(.{ .owner = owner, .engine = VtEngine.from(Adapter, &vt), .text_slot = &slot });
    try controller.feedOutput(owner, 1, "abcdefghij", 100);
    var first = try controller.copyProjection(owner, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    const logical_id = first.visible_rows[0].logical_id.?;
    try std.testing.expectEqual(logical_id, first.visible_rows[1].logical_id.?);
    try std.testing.expectEqual(Clock.value, first.visible_rows[0].received_wallclock_ms.?);
    try std.testing.expect(first.visible_rows[2].logical_id == null);
    Clock.value += 5000;
    try controller.recordSubmission(owner);
    try controller.resizeApplied(owner, .{ .revision = 2, .cols = 5, .rows = 5 }, 120);
    var reflowed = try controller.copyProjection(owner, std.testing.allocator);
    defer reflowed.deinit(std.testing.allocator);
    try std.testing.expectEqual(logical_id, reflowed.visible_rows[0].logical_id.?);
    try std.testing.expectEqual(logical_id, reflowed.visible_rows[1].logical_id.?);
    try std.testing.expectEqual(@as(i64, 1_750_000_000_000), reflowed.visible_rows[1].received_wallclock_ms.?);
    try std.testing.expectEqual(Clock.value, reflowed.visible_rows[0].submitted_wallclock_ms.?);
    Clock.value += 5000;
    try controller.feedOutput(owner, 2, "\r\nnext\r\n", 140);
    var tail = try controller.copyProjection(owner, std.testing.allocator);
    defer tail.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1_750_000_005_000), tail.visible_rows[0].submitted_wallclock_ms.?);
    var found_next = false;
    for (tail.visible_rows) |row| {
        if (std.mem.eql(u8, tail.grapheme(tail.cells[row.cell_start]), "n")) {
            try std.testing.expectEqual(Clock.value, row.received_wallclock_ms.?);
            try std.testing.expect(row.logical_id.? != logical_id);
            found_next = true;
        }
    }
    try std.testing.expect(found_next);
    try std.testing.expect(tail.visible_rows[tail.visible_rows.len - 1].logical_id == null);
    var lines = try controller.readLines(owner, .{ .max_lines = 2, .max_bytes = 128 }, std.testing.allocator);
    defer lines.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abcdefghij", lines.lines[0]);
    try std.testing.expectEqualStrings("next", lines.lines[1]);
}

test "built-in terminal types preserve negotiated input and scope vt100 function aliases" {
    const input = @import("vt/input_event.zig");
    const types = @import("vt/terminal_type.zig");
    const keys = [_]input.Key{ .f5, .f6, .f7, .f8, .f9, .f10 };
    const xterm_bytes = [_][]const u8{ "\x1b[15~", "\x1b[17~", "\x1b[18~", "\x1b[19~", "\x1b[20~", "\x1b[21~" };
    const legacy_bytes = [_][]const u8{ "\x1bOt", "\x1bOu", "\x1bOv", "\x1bOl", "\x1bOw", "\x1bOx" };
    for ([_][]const u8{ "xterm-256color", "xterm", "vt100", "vt100-custom", "screen-256color" }) |name| {
        var vt = try Adapter.init(std.testing.allocator, 3, 30);
        defer vt.destroy();
        vt.configureTerminalType(name);
        for (keys, 0..) |key, i| {
            const bytes = try vt.encodeKey(.{ .key = key }, std.testing.allocator);
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqualStrings(if (types.classify(name) == .vt100) legacy_bytes[i] else xterm_bytes[i], bytes);
        }
        // RIS keeps the chosen compatibility policy; program protocols win.
        _ = try vt.feed("\x1bc");
        const reset = try vt.encodeKey(.{ .key = .f5 }, std.testing.allocator);
        defer std.testing.allocator.free(reset);
        try std.testing.expectEqualStrings(if (types.classify(name) == .vt100) legacy_bytes[0] else xterm_bytes[0], reset);
        const modified = try vt.encodeKey(.{ .key = .f5, .modifiers = .{ .shift = true } }, std.testing.allocator);
        defer std.testing.allocator.free(modified);
        try std.testing.expectEqualStrings("\x1b[15;2~", modified);
        const released = try vt.encodeKey(.{ .key = .f5, .action = .release }, std.testing.allocator);
        defer std.testing.allocator.free(released);
        try std.testing.expectEqual(@as(usize, 0), released.len);
        _ = try vt.feed("\x1b[>1u");
        const negotiated = try vt.encodeKey(.{ .key = .f5 }, std.testing.allocator);
        defer std.testing.allocator.free(negotiated);
        try std.testing.expect(!std.mem.eql(u8, legacy_bytes[0], negotiated));
    }
}
