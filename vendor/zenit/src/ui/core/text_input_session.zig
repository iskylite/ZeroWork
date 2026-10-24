//! Native IME session reconciliation state machine, extracted from `Cx`.
//!
//! One responsibility: **reconcile what the framework thinks 'native IME should be
//! active' with the platform's actual state**. Three states via `native_enabled: ?bool`:
//!
//! - null: platform state **unknown** (SDK just attached / window changed / just init);
//!   the next reconcile must dispatch unconditionally, never skip on 'looks unchanged'
//! - true: confirmed open
//! - false: confirmed closed
//!
//! Separating 'unknown' from 'closed' is the point: with a bare bool, the first
//! reconcile after SDK attach would skip on false==false, a focused text field would
//! keep native IME closed, and CJK input fails with no error.
//!
//! **Focus resolution is not done here** (it touches focus_manager / node_registry,
//! Cx's job); this module only receives the resolved result (node handle + client
//! context) and reconciles, so the state machine is table-driven unit testable.

const std = @import("std");
const NodeHandle = @import("hit_runtime.zig").NodeHandle;

/// platform-side actions. implemented by `Cx` (it owns system_sdk / window_id).
pub const Host = struct {
    ctx: *anyopaque,
    /// enable/disable native IME. returns whether **successfully dispatched**, on failure state
    /// machine stays 'unknown', next frame retries instead of recording as effective.
    setEnabled: *const fn (ctx: *anyopaque, enabled: bool) bool,
    /// discard in-progress preedit (must do before focus change, else partial composition leaks to
    /// new target).
    discardIme: *const fn (ctx: *anyopaque) void,
};

/// result of one focus parse. both fields null means 'currently no text input target'.
pub const Target = struct {
    node: ?NodeHandle = null,
    context: ?*anyopaque = null,
};

pub const TextInputSession = struct {
    active_node: ?NodeHandle = null,
    active_context: ?*anyopaque = null,
    /// see module header: null = platform state unknown, must reconcile unconditionally once.
    native_enabled: ?bool = null,

    /// reconcile session to `target`. order is part of contract: **discardIme first then switch
    /// target**. reversed leaks uncommitted composition from previous field to new target.
    pub fn reconcile(self: *TextInputSession, target: Target, host: Host) void {
        const changed = !std.meta.eql(self.active_node, target.node) or
            self.active_context != target.context;
        if (changed and self.active_node != null) host.discardIme(host.ctx);
        self.active_node = target.node;
        self.active_context = target.context;

        const desired = target.node != null;
        // when native_enabled == null (unknown) dispatch unconditionally, that's the point of
        // three-state.
        if (self.native_enabled == null or self.native_enabled.? != desired) {
            if (host.setEnabled(host.ctx, desired)) self.native_enabled = desired;
        }
    }

    /// fully disable (before window destroy / SDK detach). unlike reconcile, here pin
    /// native_enabled to false not null, we just closed it.
    pub fn deactivate(self: *TextInputSession, host: Host) void {
        if (self.active_node != null) host.discardIme(host.ctx);
        _ = host.setEnabled(host.ctx, false);
        self.* = .{ .active_node = null, .active_context = null, .native_enabled = false };
    }

    /// call when platform state becomes untrusted (SDK/window change): next reconcile
    /// unconditionally re-dispatch.
    pub fn invalidatePlatformState(self: *TextInputSession) void {
        self.native_enabled = null;
    }
};

// -- tests --

const Recorder = struct {
    enable_calls: std.ArrayList(bool) = .empty,
    discard_count: u32 = 0,
    fail_enable: bool = false,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Recorder {
        return .{ .alloc = alloc };
    }
    fn deinit(self: *Recorder) void {
        self.enable_calls.deinit(self.alloc);
    }
    fn setEnabled(ctx: *anyopaque, enabled: bool) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.enable_calls.append(self.alloc, enabled) catch {};
        return !self.fail_enable;
    }
    fn discardIme(ctx: *anyopaque) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.discard_count += 1;
    }
    fn host(self: *Recorder) Host {
        return .{ .ctx = @ptrCast(self), .setEnabled = setEnabled, .discardIme = discardIme };
    }
};

fn handle(id: u32) NodeHandle {
    return .{ .id = id, .generation = 1 };
}

test "未知状态下即使 desired 与默认值相同也必须下发一次" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    // native_enabled = null (unknown), target empty => desired = false. bare bool would skip on
    // false==false; three-state must dispatch.
    var s = TextInputSession{};
    s.reconcile(.{}, rec.host());
    try std.testing.expectEqual(@as(usize, 1), rec.enable_calls.items.len);
    try std.testing.expectEqual(false, rec.enable_calls.items[0]);
    try std.testing.expectEqual(@as(?bool, false), s.native_enabled);
}

test "状态已知且未变时不重复下发" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host()); // open
    try std.testing.expectEqual(@as(usize, 1), rec.enable_calls.items.len);
    s.reconcile(.{ .node = handle(1) }, rec.host()); // same target, should be silent
    try std.testing.expectEqual(@as(usize, 1), rec.enable_calls.items.len);
}

test "换目标时先 discard 再切，且顺序不可颠倒" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host());
    try std.testing.expectEqual(@as(u32, 0), rec.discard_count);

    s.reconcile(.{ .node = handle(2) }, rec.host());
    // must discard previous partial composition before switching to new target
    try std.testing.expectEqual(@as(u32, 1), rec.discard_count);
    try std.testing.expectEqual(@as(?NodeHandle, handle(2)), s.active_node);
}

test "context 变化（同节点换 client）也算换目标" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var a: u8 = 0;
    var b: u8 = 0;
    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1), .context = @ptrCast(&a) }, rec.host());
    s.reconcile(.{ .node = handle(1), .context = @ptrCast(&b) }, rec.host());
    try std.testing.expectEqual(@as(u32, 1), rec.discard_count);
}

test "下发失败时保持未知，下次重试" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();
    rec.fail_enable = true;

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host());
    // failure => can't record as effective
    try std.testing.expectEqual(@as(?bool, null), s.native_enabled);

    rec.fail_enable = false;
    s.reconcile(.{ .node = handle(1) }, rec.host());
    try std.testing.expectEqual(@as(?bool, true), s.native_enabled);
    try std.testing.expectEqual(@as(usize, 2), rec.enable_calls.items.len);
}

test "deactivate 把状态钉成 false 而不是 null" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host());
    s.deactivate(rec.host());
    try std.testing.expectEqual(@as(?bool, false), s.native_enabled);
    try std.testing.expectEqual(@as(?NodeHandle, null), s.active_node);
    try std.testing.expectEqual(@as(u32, 1), rec.discard_count);
}

test "invalidatePlatformState 之后必须重新下发" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host());
    const before = rec.enable_calls.items.len;

    s.invalidatePlatformState(); // SDK/window change
    s.reconcile(.{ .node = handle(1) }, rec.host());
    // target unchanged but platform state untrusted, must dispatch again
    try std.testing.expectEqual(before + 1, rec.enable_calls.items.len);
}
