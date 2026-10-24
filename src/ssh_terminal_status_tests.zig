//! Real Ghostty -> production FeedBridge/TextSlot -> TerminalView metadata.
//! A test-local worker shell supplies only the actual frame/control mailboxes;
//! no socket or native window is opened and its unrelated IO fields are unused.
const std = @import("std");
const ui = @import("ui");
const View = @import("ui/terminal_view.zig").TerminalViewNode;
const SSH = @import("ui/ssh_status_host.zig");
const Details = @import("ui/connection_details_view.zig");
const Frame = @import("vt/text_frame.zig");
const Adapter = @import("vt/ghostty_adapter.zig").Adapter;
const Feed = @import("vt/feed_bridge.zig").FeedBridge;
const Engine = @import("vt/engine.zig").VtEngine;
const Worker = @import("vt/ssh_worker.zig").SshWorker;
const Thread = @import("vt/ssh_worker_thread.zig").Thread;
const Slot = @import("vt/text_slot.zig").TextSlot;
const Control = @import("vt/reconnect.zig").Control;
const a = std.testing.allocator;
const key: Details.OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(902), .generation = 2 } }, .operation_id = 52, .attempt_id = 2 };

const Fixture = struct {
    cx: *ui.Cx,
    view: View,
    adapter: Adapter,
    worker: Worker,
    thread: Thread,
    native_runtime: @import("ui/session_runtime.zig").SessionRuntime = undefined,
    presentation: @import("host/runtime_service.zig").Runtime = undefined,
    feed: Feed,
    seen: u64 = 0,
    scratch: []u8,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .view = undefined, .adapter = try Adapter.init(a, 35, 138), .worker = undefined, .thread = undefined, .feed = undefined, .scratch = try a.alloc(u8, Slot.default_capacity) };
        self.cx.setViewport(1200, 760);
        self.view = try View.mount(self.cx);
        self.cx.root = self.view.root;
        self.worker.text = try Slot.init(a, Slot.default_capacity);
        self.worker.presentation_attached = .init(true);
        self.thread = .{ .worker = &self.worker, .thread = undefined, .reconnect_control = Control.init(key) };
        self.feed = .{ .engine = Engine.from(Adapter, &self.adapter), .text_slot = &self.worker.text };
        self.native_runtime.torn_down = false;
        self.native_runtime.worker = &self.worker;
        self.native_runtime.thread = &self.thread;
        self.presentation = @import("plugins/ssh/runtime_binding.zig").borrow(&self.native_runtime);
        self.view.worker = &self.presentation;
        const status = try ui.text(self.cx, "", .{});
        status.setDisplay(.none);
        try self.view.root.appendChild(a, status);
        try self.view.addWorkerFrameHook(self.cx, &self.presentation, &self.presentation, status, &self.seen, self.scratch);
        // Metadata exercises the real public consume path. The fake IO shell
        // must never run FrameHook's unrelated network/input polling work.
        self.cx.removeAfterLayoutHook(self.view.frame_hook.?);
    }
    fn deinit(self: *Fixture) void {
        self.view.removeFrameHook(self.cx);
        self.view.worker = null;
        self.view.releaseBuffers(self.cx);
        self.worker.text.deinit(a);
        self.adapter.destroy();
        a.free(self.scratch);
        self.cx.deinit();
    }
    fn publish(self: *Fixture, text: []const u8, time_ms: i64) !void {
        _ = try self.feed.feedAndPublish(text, time_ms);
    }
    fn consume(self: *Fixture) !bool {
        return self.view.consumeWorkerText(self.cx, &self.presentation, &self.seen, self.scratch);
    }
};
fn details(captured: Details.OperationKey) Details.Snapshot {
    return .{ .key = captured, .revision = 1, .source = .session, .hops = @splat(.{}), .hop_count = 1, .target_rtt_sample = null, .sampled_at = null };
}

test "SSH terminal status uses real published UTF8 frame and applied 138x35 grid" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try std.testing.expect(f.view.statusSnapshot(key) == null);
    try f.publish("root@vm 中文\r\n", 10);
    // Publication alone does not claim that TerminalView has consumed it.
    try std.testing.expect(f.view.statusSnapshot(key) == null);
    try std.testing.expect(try f.consume());
    const source = f.view.statusSnapshot(key).?;
    try std.testing.expect(source.operation_key.?.eql(key));
    try std.testing.expectEqual(Frame.frame_version, source.frame_version.?);
    try std.testing.expectEqual(f.seen, source.revision);
    try std.testing.expectEqual(@as(u16, 138), source.cols);
    try std.testing.expectEqual(@as(u16, 35), source.rows);
    try std.testing.expectEqual(SSH.TerminalStatus.Encoding.utf8, source.encoding);
    const active = SSH.Active.fromTerminal(details(key), source, false);
    try std.testing.expect(active.utf8);
    try std.testing.expectEqual(@as(u16, 138), active.grid.?.cols);
    // An unacknowledged resize request is not a new displayed grid.
    try Engine.from(Adapter, &f.adapter).resize(160, 42);
    try std.testing.expectEqual(@as(u16, 138), f.view.statusSnapshot(key).?.cols);
    f.feed.publishTextFrame(20);
    try std.testing.expect(try f.consume());
    const resized = f.view.statusSnapshot(key).?;
    try std.testing.expectEqual(@as(u16, 160), resized.cols);
    try std.testing.expectEqual(@as(u16, 42), resized.rows);
    try std.testing.expect(resized.revision > source.revision);
}

test "SSH terminal status rejects old owner generations queued reconnect frames and failure" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.publish("initial", 10);
    try std.testing.expect(try f.consume());
    var next = key;
    next.owner.session.generation += 1;
    next.operation_id += 1;
    next.attempt_id = 3;
    try std.testing.expect(f.view.statusSnapshot(next) == null);
    try f.publish("old queued", 20);
    f.thread.reconnect_control.lost(key, .released, error.ConnectFailed);
    try std.testing.expect(f.view.statusSnapshot(key) == null);
    try f.thread.reconnect_control.request(key, next);
    _ = f.thread.reconnect_control.take().?;
    f.thread.reconnect_control.ready(next);
    try std.testing.expect(try f.consume());
    // Already queued bytes must not acquire the successor's identity.
    try std.testing.expect(f.view.statusSnapshot(next) == null);
    try std.testing.expect(f.view.statusSnapshot(key) == null);
    // Identical viewport content still has a fresh real publication revision.
    f.feed.publishTextFrame(30);
    try std.testing.expect(try f.consume());
    const current = f.view.statusSnapshot(next).?;
    try std.testing.expect(current.operation_key.?.eql(next));
    try std.testing.expect(f.view.statusSnapshot(key) == null);
    const wrong = SSH.Active.fromTerminal(details(key), current, false);
    try std.testing.expect(!wrong.utf8 and wrong.grid == null);
    f.thread.failed.store(true, .release);
    try std.testing.expect(f.view.statusSnapshot(next) == null);
    f.thread.failed.store(false, .release);
    f.worker.presentation_attached.store(false, .release);
    try std.testing.expect(f.view.statusSnapshot(next) == null);
    f.worker.presentation_attached.store(true, .release);
    f.view.removeFrameHook(f.cx);
    try std.testing.expect(f.view.statusSnapshot(next) == null);
}

test "SSH terminal status rejects invalid wire version and does not infer configured UTF8" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.publish("valid", 10);
    try std.testing.expect(try f.consume());
    var wire: [Frame.header_bytes]u8 = undefined;
    Frame.encodeHeader(&wire, .{}, 138, 35, 0, 0);
    wire[9] = Frame.frame_version + 1;
    _ = try f.worker.text.publish(&wire);
    try std.testing.expect(!try f.consume());
    try std.testing.expect(f.view.statusSnapshot(key) == null);
    const missing = SSH.Active.fromTerminal(details(key), null, false);
    try std.testing.expect(!missing.utf8 and missing.grid == null);
    const unknown_encoding: SSH.TerminalStatus.Snapshot = .{ .owner = key.owner.session, .operation_key = key, .revision = 6, .cols = 138, .rows = 35, .frame_version = Frame.frame_version };
    const unknown = SSH.Active.fromTerminal(details(key), unknown_encoding, false);
    try std.testing.expect(!unknown.utf8);
    try std.testing.expectEqual(@as(u16, 138), unknown.grid.?.cols);
    var bad = unknown_encoding;
    bad.revision = 0;
    const no_geometry = SSH.Active.fromTerminal(details(key), bad, false);
    try std.testing.expect(!no_geometry.utf8 and no_geometry.grid == null);
}
