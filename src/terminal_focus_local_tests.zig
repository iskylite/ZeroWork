//! Actual Cx keyboard/IME routing into an isolated real ZSH, without a window.
const std = @import("std");
const ui = @import("ui");
const local = @import("local/adapter.zig");
const host = @import("host/session_host.zig");
const terminal = @import("host/terminal_service.zig");
const native = @import("local/native.zig");
const View = @import("ui/terminal_view.zig").TerminalViewNode;
const focus_return = @import("ui/ai_return_focus.zig");
const a = std.testing.allocator;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;

fn pause() void {
    const delay: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
}

const Rig = struct {
    adapter: *local.LocalAdapter,
    sessions: host.SessionHost,

    fn init() !Rig {
        const adapter = try local.LocalAdapter.init(a, .{});
        errdefer adapter.deinit() catch unreachable;
        return .{ .adapter = adapter, .sessions = try host.SessionHost.init(a, &.{adapter.adapter()}) };
    }
    fn deinit(self: *Rig) void {
        const deadline = native.zw_local_monotonic_ms() + 8000;
        while (self.adapter.shutdownStep() != .released) {
            _ = self.adapter.drain(&self.sessions) catch unreachable;
            if (native.zw_local_monotonic_ms() >= deadline) @panic("focus test did not release its owned ZSH");
            pause();
        }
        self.adapter.deinit() catch unreachable;
        self.sessions.deinit();
    }
    fn ready(self: *Rig, accepted: host.Accepted) !terminal.Service {
        const deadline = native.zw_local_monotonic_ms() + 5000;
        while (native.zw_local_monotonic_ms() < deadline) {
            _ = try self.adapter.drain(&self.sessions);
            if (self.sessions.queryService(accepted.handle, .terminal) == .available)
                return self.adapter.terminalService(self.sessions.queryService(accepted.handle, .terminal).available);
            pause();
        }
        return error.LocalStartTimeout;
    }
    fn processSnapshot(self: *Rig, owner: host.SessionHandle) !local.ProcessSnapshot {
        const deadline = native.zw_local_monotonic_ms() + 5000;
        while (native.zw_local_monotonic_ms() < deadline) {
            return self.adapter.processSnapshot(owner) catch |err| {
                if (err != error.WorkerBusy) return err;
                pause();
                continue;
            };
        }
        return error.LocalProcessSnapshotTimeout;
    }
    fn output(self: *Rig, view: *View, service: terminal.Service, result: *std.ArrayList(u8), expected: []const u8) !void {
        const deadline = native.zw_local_monotonic_ms() + 5000;
        var bytes: [4096]u8 = undefined;
        while (native.zw_local_monotonic_ms() < deadline) {
            _ = try self.adapter.drain(&self.sessions);
            _ = view.refreshTerminalService(service.binding.resource_owner.session, true) catch |err| {
                if (err == error.WorkerBusy) {
                    pause();
                    continue;
                }
                return err;
            };
            _ = view.cx.render();
            for (0..16) |_| switch (service.readOutput(&bytes) catch |err| {
                if (err == error.WorkerBusy) break;
                return err;
            }) {
                .bytes => |count| try result.appendSlice(a, bytes[0..count]),
                else => break,
            };
            if (std.mem.indexOf(u8, result.items, expected) != null) return;
            pause();
        }
        std.debug.print("Local focus timeout expected={s} received={s} pending={d} preedit={s} focus={?d} error={?s}\n", .{ expected, result.items, view.terminal_surface.?.pending.items.len, view.terminal_surface.?.preedit, if (view.cx.focus_manager.getFocused()) |node| node.id else null, view.terminal_surface.?.error_message });
        return error.LocalOutputTimeout;
    }
    fn promptSettled(self: *Rig, view: *View, service: terminal.Service) !void {
        const deadline = native.zw_local_monotonic_ms() + 5000;
        var prior: ?struct { output: u64, mode: u64 } = null;
        var stable: usize = 0;
        while (native.zw_local_monotonic_ms() < deadline) {
            _ = try self.adapter.drain(&self.sessions);
            _ = view.refreshTerminalService(service.binding.resource_owner.session, true) catch |err| {
                if (err == error.WorkerBusy) {
                    pause();
                    continue;
                }
                return err;
            };
            _ = view.cx.render();
            const status = service.status() catch |err| {
                if (err == error.WorkerBusy) {
                    pause();
                    continue;
                }
                return err;
            };
            if (status.pending_input_bytes == 0 and view.terminalSnapshot(status.owner) != null and
                view.terminalSnapshot(status.owner).?.projection.mode_revision == status.mode_revision)
            {
                if (prior) |old| {
                    if (old.output == status.output_sequence and old.mode == status.mode_revision) stable += 1 else stable = 0;
                }
                prior = .{ .output = status.output_sequence, .mode = status.mode_revision };
                if (stable >= 10) return;
            } else stable = 0;
            pause();
        }
        return error.LocalPromptDidNotSettle;
    }
};

test "real Local Cx canvas recovery and assistant focus return execute on the same ZSH with IME" {
    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();
    try sandbox.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "setopt NO_RCS\nPROMPT=''\nRPROMPT=''\n" });
    const path = try sandbox.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    const previous = if (std.c.getenv("ZDOTDIR")) |value| try a.dupeSentinel(u8, std.mem.span(value), 0) else null;
    defer {
        if (previous) |value| {
            _ = setenv("ZDOTDIR", value.ptr, 1);
            a.free(value);
        } else _ = unsetenv("ZDOTDIR");
    }
    if (setenv("ZDOTDIR", path.ptr, 1) != 0) return error.EnvironmentFailed;
    var rig = try Rig.init();
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = path } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    const service = try rig.ready(accepted);
    const initial_process = try rig.processSnapshot(accepted.handle);
    try std.testing.expect(initial_process.pid != null);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(700, 240);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var view = try View.mount(cx);
    defer view.releaseBuffers(cx);
    try cx.root.?.appendChild(a, view.root);
    try view.bindTerminalService(service);
    const panel = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 200 }, .top = .{ .px = 20 } }, .width = .{ .px = 240 }, .height = .{ .px = 100 }, .z_index = 50 }, .{});
    const draft = try scope.createText("assistant draft", .{});
    const assistant = try ui.widgets.Textarea(.{ .value = draft }).mountResult(scope, cx);
    try panel.appendChild(a, assistant.wrapper);
    try cx.root.?.appendChild(a, panel);
    _ = cx.render();
    _ = try view.refreshTerminalService(accepted.handle, true);
    _ = cx.render();
    try rig.promptSettled(&view, service);
    cx.setFocus(assistant.input);
    panel.setDisplay(.none);
    _ = cx.render();
    cx.clearFocus(); // Match root's observed cleared focus, without focusing the terminal.
    const canvas = view.terminal_surface.?.root.globalRect();
    cx.handleMouseDown(canvas.x + canvas.w / 2, canvas.y + canvas.h / 2, .{});
    cx.handleMouseUp(canvas.x + canvas.w / 2, canvas.y + canvas.h / 2);
    try std.testing.expect(cx.focus_manager.getFocused() == view.root);
    cx.handleTextInput("printf '__FOCUS_%s__\\n' CANVAS");
    cx.handleKeyDown(.@"return", .{});
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);
    try rig.output(&view, service, &received, "__FOCUS_CANVAS__");
    try rig.promptSettled(&view, service);

    panel.setDisplay(.flex);
    _ = cx.render();
    cx.setFocus(assistant.input);
    const ticket: focus_return.Ticket = .{ .tab = @fromBackingInt(7), .owner = .{ .session = accepted.handle } };
    panel.setDisplay(.none);
    try std.testing.expect(focus_return.restore(cx, ticket, ticket, view.root, panel, null, false));
    _ = cx.render();
    try std.testing.expect(cx.focus_manager.getFocused() == view.root);
    // No terminal click is allowed after this explicit assistant dismissal.
    cx.handleTextInput("printf '__FOCUS_%s__\\n' RETURNED");
    cx.handleKeyDown(.@"return", .{});
    try rig.output(&view, service, &received, "__FOCUS_RETURNED__");
    try rig.promptSettled(&view, service);

    cx.handleTextInput("printf '__FOCUS_IME_%s__\\n' '");
    cx.handleImePreedit("你好", "你好".len);
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqualStrings("你好", view.terminal_surface.?.preedit);
    cx.handleImeCommit("你好");
    cx.handleTextInput("'");
    cx.handleKeyDown(.@"return", .{});
    try rig.output(&view, service, &received, "__FOCUS_IME_你好__");
    try std.testing.expectEqual(initial_process.pid, (try rig.processSnapshot(accepted.handle)).pid);

    view.unbindTerminalService(accepted.handle);
    _ = try rig.sessions.requestClose(accepted.handle, .{});
    const deadline = native.zw_local_monotonic_ms() + 8000;
    while (rig.sessions.queryState(accepted.handle).?.lifecycle != .closed) {
        _ = try rig.adapter.drain(&rig.sessions);
        if (native.zw_local_monotonic_ms() >= deadline) return error.LocalCloseTimeout;
        pause();
    }
    try std.testing.expectEqual(host.CloseReceipt.released, (try rig.processSnapshot(accepted.handle)).cleanup);
}

test "real Local search editor keeps text keyboard and IME out of the original ZSH" {
    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();
    try sandbox.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "setopt NO_RCS\nPROMPT=''\nRPROMPT=''\n" });
    const path = try sandbox.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    const previous = if (std.c.getenv("ZDOTDIR")) |value| try a.dupeSentinel(u8, std.mem.span(value), 0) else null;
    defer {
        if (previous) |value| {
            _ = setenv("ZDOTDIR", value.ptr, 1);
            a.free(value);
        } else _ = unsetenv("ZDOTDIR");
    }
    if (setenv("ZDOTDIR", path.ptr, 1) != 0) return error.EnvironmentFailed;
    var rig = try Rig.init();
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = path } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    const service = try rig.ready(accepted);
    const original_pid = (try rig.processSnapshot(accepted.handle)).pid;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(700, 300);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var view = try View.mount(cx);
    defer view.releaseBuffers(cx);
    try cx.root.?.appendChild(a, view.root);
    try view.attachSearch(scope);
    try view.bindTerminalService(service);
    _ = cx.render();
    _ = try view.refreshTerminalService(accepted.handle, true);
    _ = cx.render();
    try rig.promptSettled(&view, service);
    view.focus();
    cx.handleTextInput("printf '__SEARCH_%s__\\n' BASELINE");
    cx.handleKeyDown(.@"return", .{});
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    try rig.output(&view, service, &output, "__SEARCH_BASELINE__");
    try rig.promptSettled(&view, service);
    cx.handleTextInput("for zw_i in {1..35}; do printf 'SCROLL_ROW_%s\\n' $zw_i; done");
    cx.handleKeyDown(.@"return", .{});
    try rig.output(&view, service, &output, "SCROLL_ROW_35");
    try rig.promptSettled(&view, service);
    const tail = view.terminalSnapshot(accepted.handle).?.projection.scrollback;
    try std.testing.expect(tail.viewport_offset > 0);
    const input_before = view.terminal_surface.?.next_input;
    view.openSearch();
    _ = cx.render();
    try std.testing.expect(view.service_search != null);
    try std.testing.expect(view.service_search.?.owner.eql(accepted.handle));
    try std.testing.expect(std.mem.indexOf(u8, view.search.source.items, "__SEARCH_BASELINE__") != null);
    const query = &view.search_view.?.input_result;
    const rect = query.input_container.globalRect();
    cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
    cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expect(cx.focus_manager.getFocused() == query.input_container);
    try std.testing.expect(!view.terminal_surface.?.dragging);
    try std.testing.expect(view.terminal_surface.?.selection == null);
    cx.handleKeyDown(.a, .{ .super = true });
    cx.handleTextInput("__SEARCH_BASELINE__");
    try rig.promptSettled(&view, service);
    try std.testing.expectEqual(@as(usize, 1), view.search.count());
    try std.testing.expectEqualStrings("1/1", view.search_view.?.count.getText().?.content);
    try std.testing.expect(view.search_anchor != null);
    try std.testing.expect(view.terminalSnapshot(accepted.handle).?.projection.scrollback.viewport_offset < tail.viewport_offset);
    var painted = false;
    for (view.search_marks.items) |mark| if (mark.style.display != .none and mark.children.items.len > 0) {
        if (std.mem.eql(u8, mark.children.items[0].getText().?.content, "__SEARCH_BASELINE__")) painted = true;
    };
    try std.testing.expect(painted);
    // Reflow remaps the same native hit anchor, rather than retaining a row
    // number that could now address another line.
    const original_anchor = view.search_anchor.?;
    cx.setViewport(490, 300);
    _ = cx.render();
    try rig.promptSettled(&view, service);
    try std.testing.expectEqual(original_anchor, view.search_anchor.?);
    try std.testing.expectEqual(@as(usize, 1), view.search.count());
    cx.handleKeyDown(.a, .{ .super = true });
    cx.handleTextInput("QUERY_ONLY");
    try std.testing.expectEqualStrings("QUERY_ONLY", query.state.getText());
    cx.handleKeyDown(.c, .{ .ctrl = true });
    cx.handleImePreedit("你好", "你好".len);
    try std.testing.expect(query.state.imeIsComposing());
    try std.testing.expectEqualStrings("组字中", view.search_view.?.count.getText().?.content);
    try std.testing.expect(!view.search_view.?.navigation_enabled.get());
    try std.testing.expectEqualStrings("QUERY_ONLY", view.search.query.items);
    try std.testing.expectEqual(@as(usize, 0), view.terminal_surface.?.preedit.len);
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expect(view.search_open);
    cx.handleImeCommit("你好");
    try std.testing.expectEqualStrings("QUERY_ONLY你好", query.state.getText());
    try std.testing.expectEqual(input_before, view.terminal_surface.?.next_input);
    try rig.promptSettled(&view, service);
    try std.testing.expectEqual(input_before, view.terminal_surface.?.next_input);
    // Closing the owned search returns to the same terminal. Its command line
    // must still be empty: query edits above are never PTY input.
    cx.handleKeyDown(.escape, .{});
    try std.testing.expect(!view.search_open);
    try std.testing.expect(cx.focus_manager.getFocused() == view.root);
    cx.handleTextInput("printf '__SEARCH_%s__\\n' RETURNED");
    cx.handleKeyDown(.@"return", .{});
    try rig.output(&view, service, &output, "__SEARCH_RETURNED__");
    try std.testing.expectEqual(original_pid, (try rig.processSnapshot(accepted.handle)).pid);
    view.unbindTerminalService(accepted.handle);
    _ = try rig.sessions.requestClose(accepted.handle, .{});
    const deadline = native.zw_local_monotonic_ms() + 8000;
    while (rig.sessions.queryState(accepted.handle).?.lifecycle != .closed) {
        _ = try rig.adapter.drain(&rig.sessions);
        if (native.zw_local_monotonic_ms() >= deadline) return error.LocalCloseTimeout;
        pause();
    }
    try std.testing.expectEqual(host.CloseReceipt.released, (try rig.processSnapshot(accepted.handle)).cleanup);
}
