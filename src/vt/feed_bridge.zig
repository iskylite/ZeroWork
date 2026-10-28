const std = @import("std");
const VtEngine = @import("engine.zig").VtEngine;
const FeedResult = @import("engine.zig").FeedResult;
const DirtySlot = @import("dirty_slot.zig").DirtySlot;
const TextSlot = @import("text_slot.zig").TextSlot;
const text_frame = @import("text_frame.zig");

/// Worker-side bridge: feed one byte batch, then publish a full text frame
/// (projected viewport text + cursor metadata).
///
/// Data-plane model mirrors open-source terminal emulators (Ghostty/Kitty/
/// Alacritty): VT bytes reach the parser IMMEDIATELY — the in-memory cell
/// grid is cheap and must never queue — while PUBLICATION is throttled to
/// display cadence with latest-wins coalescing. Under output floods the
/// socket wakes every few milliseconds; projecting/publishing more than one
/// frame per UI frame burns CPU (full-viewport projection per publish,
/// full-text re-shape per consume) without adding visible smoothness. The
/// next publish always carries the freshest state, so dropped intermediates
/// are safe — exactly the "damage, present at vsync, latest wins" contract.
///
/// Failure policy: the remote read loop must only fail for connection-level
/// errors. UI-side publication backpressure is expected whenever the UI is
/// a frame behind, so it is absorbed here (republish_pending) and retried by
/// the worker on its next step. Dirty-page publication stays optional and
/// advisory: a skipped hint only delays invalidation, never data.
pub const FeedBridge = struct {
    /// Minimum spacing between two successful publications (~1 UI frame at
    /// 120Hz; the UI frame hook runs at 8ms cadence on ProMotion panels).
    pub const min_publish_interval_ms: i64 = 8;
    pub const Publication = struct { text_generation: u64, output_sequence: u64, vt_version: u64 };

    engine: VtEngine,
    dirty_slot: ?*DirtySlot = null,
    text_slot: ?*TextSlot = null,
    /// Set when a publication is owed (cadence-throttled or deferred by a
    /// full slot). The worker retries via publishCurrentText on its next step.
    republish_pending: bool = false,
    last_publish_ms: i64 = 0,
    publication_lock: std.atomic.Value(bool) = .init(false),
    publication: ?Publication = null,
    /// Local surfaces consume structured projections. Their owner publishes
    /// text from that same projection after draining the output batch.
    deferred_projection: bool = false,

    /// A main-thread value receipt for bytes actually accepted by TextSlot.
    /// A throttled/failed publication keeps its preceding receipt unchanged.
    pub fn notificationPublication(self: *FeedBridge) ?Publication {
        if (self.publication_lock.swap(true, .acquire)) return null;
        defer self.publication_lock.store(false, .release);
        return self.publication;
    }

    pub fn feedAndPublish(self: *FeedBridge, bytes: []const u8, now_ms: i64) !PublishedFeed {
        const result = try self.engine.feed(bytes);
        var generation: ?u64 = null;
        if (self.dirty_slot) |slot| {
            if (result.dirty_pages.len != 0) {
                // Invalidation hints only. When the consumer lags, dropping
                // the hint is correct: the next full frame supersedes it.
                generation = slot.publish(result.dirty_pages) catch null;
            }
        }
        self.publishTextFrame(now_ms);
        return .{ .result = result, .generation = generation };
    }

    /// Publishes the current VT snapshot (text + cursor metadata) to the text
    /// slot. Cadence-throttled (latest-wins): a fresh publish less than
    /// min_publish_interval_ms after the last success owes a retry on the
    /// next worker step instead of projecting now. Retries observe the same
    /// cadence. All publication errors are contained: backpressure defers
    /// to the next worker step instead of failing the connection.
    pub fn publishTextFrame(self: *FeedBridge, now_ms: i64) void {
        if (self.deferred_projection) {
            self.republish_pending = true;
            return;
        }
        const slot = self.text_slot orelse return;
        // Uniform cadence for BOTH paths: an owed retry must also wait out
        // the interval. An earlier "pending bypasses the check" variant let
        // the event-driven step loop (≈2ms under floods) publish hundreds of
        // frames per second, while burst tails then waited a full 50ms step
        // timeout — dense-then-idle publication, perceived as stutter.
        if (self.last_publish_ms != 0 and
            now_ms -% self.last_publish_ms < min_publish_interval_ms)
        {
            self.republish_pending = true;
            return;
        }
        if (self.publishTextFrameInner(slot)) |_| {
            self.last_publish_ms = now_ms;
            self.republish_pending = false;
        } else |err| {
            self.republish_pending = true;
            std.log.warn("[feed] text frame publish deferred: {s}", .{@errorName(err)});
        }
    }

    /// A throttled burst tail is due at publication cadence, not the transport's
    /// idle timeout. A full slot waits for consumer wakeup instead of polling.
    pub fn publicationTimeout(self: *const FeedBridge, timeout_ms: u32, now_ms: i64) u32 {
        if (!self.republish_pending) return timeout_ms;
        const slot = self.text_slot orelse return timeout_ms;
        if (!slot.canPublish()) return timeout_ms;
        const remaining = @max(0, min_publish_interval_ms - (now_ms -% self.last_publish_ms));
        return @min(timeout_ms, @as(u32, @intCast(remaining)));
    }

    /// Retry entry point for a deferred/throttled publication; called from
    /// the worker step loop, not from the read path.
    pub fn publishCurrentText(self: *FeedBridge, now_ms: i64) void {
        self.publishTextFrame(now_ms);
    }

    pub fn publishProjection(self: *FeedBridge, projection: *const @import("snapshot.zig").Projection, now_ms: i64) !void {
        const slot = self.text_slot orelse return;
        if (!slot.canPublish()) return error.ConsumerBehind;
        const wire = try @import("projection_frame.zig").encode(std.heap.page_allocator, projection, true);
        defer std.heap.page_allocator.free(wire);
        const generation = try slot.publish(wire);
        const snapshot = self.engine.snapshot();
        while (self.publication_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        self.publication = .{ .text_generation = generation, .output_sequence = snapshot.output_sequence, .vt_version = projection.version };
        self.publication_lock.store(false, .release);
        slot.timing.published(snapshot.output_sequence);
        self.last_publish_ms = now_ms;
        self.republish_pending = false;
        @import("../platform/presentation_wakeup.zig").notify();
    }

    fn publishTextFrameInner(self: *FeedBridge, slot: *TextSlot) !void {
        // Probe BEFORE projecting: the styled viewport projection is the
        // expensive step, and with the UI a full ring behind it would be
        // recomputed on every read just for the publish to fail — burning
        // the CPU that starved the reader and caused periodic stutter.
        if (!slot.canPublish()) return error.ConsumerBehind;
        if (slot.structured.load(.acquire)) {
            var projection = try self.engine.copyProjection(std.heap.page_allocator);
            errdefer projection.deinit(std.heap.page_allocator);
            const generation = try slot.publishOwnedProjection(projection, 1);
            while (self.publication_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
            self.publication = .{ .text_generation = generation, .output_sequence = projection.output_sequence, .vt_version = projection.version };
            self.publication_lock.store(false, .release);
            slot.timing.published(projection.output_sequence);
            @import("../platform/presentation_wakeup.zig").notify();
            return;
        }
        const snapshot = self.engine.snapshot();
        const styled = try @import("text_projection_styled.zig").renderVisibleTextStyled(self.engine, std.heap.page_allocator);
        defer std.heap.page_allocator.free(styled.text);
        defer std.heap.page_allocator.free(styled.spans);
        var header: [text_frame.header_bytes]u8 = undefined;
        text_frame.encodeHeader(
            &header,
            .{ .row = snapshot.cursor.row, .col = snapshot.cursor.col, .visible = snapshot.cursor.visible },
            snapshot.cols,
            snapshot.rows,
            styled.spans.len,
            styled.text.len,
        );
        const generation = if (styled.spans.len == 0) try slot.publishParts(&.{ &header, styled.text }) else blk: {
            const wire = try std.heap.page_allocator.alloc(u8, styled.spans.len * text_frame.span_wire_bytes);
            defer std.heap.page_allocator.free(wire);
            text_frame.encodeSpans(wire, styled.spans);
            break :blk try slot.publishParts(&.{ &header, wire, styled.text });
        };
        while (self.publication_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        self.publication = .{ .text_generation = generation, .output_sequence = snapshot.output_sequence, .vt_version = snapshot.version };
        self.publication_lock.store(false, .release);
        slot.timing.published(snapshot.output_sequence);
        // TextSlot's wake can already have been handled before this receipt
        // was committed. Notify again so the main thread can observe both.
        @import("../platform/presentation_wakeup.zig").notify();
        self.republish_pending = false;
    }
};

pub const PublishedFeed = struct { result: FeedResult, generation: ?u64 };

const FakeEngine = struct {
    dirty: [2]u32 = .{ 1, 4 },
    versions: [1]u64 = .{1},
    pub fn destroy(_: *FakeEngine) void {}
    pub fn feed(self: *FakeEngine, bytes: []const u8) !FeedResult {
        return .{ .dirty_pages = if (bytes.len == 0) &.{} else &self.dirty, .cursor_moved = bytes.len != 0, .bell = false };
    }
    pub fn resize(_: *FakeEngine, _: u16, _: u16) !void {}
    pub fn snapshot(self: *FakeEngine) @import("engine.zig").Snapshot {
        return .{ .cols = 80, .rows = 24, .cursor = .{}, .page_versions = &self.versions, .scroll_offset = 0 };
    }
    pub fn lineAt(_: *FakeEngine, _: u64) ?@import("engine.zig").LineView {
        return null;
    }
    pub fn selectionText(_: *FakeEngine, _: @import("engine.zig").Selection, _: @import("engine.zig").CopyMode, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, "");
    }
    pub fn setOscCallback(_: *FakeEngine, _: ?@import("engine.zig").OscCallback) void {}
};

test "feed bridge publishes engine dirty pages" {
    var fake: FakeEngine = .{};
    var slot = try DirtySlot.init(std.testing.allocator, 4);
    defer slot.deinit(std.testing.allocator);
    var bridge: FeedBridge = .{ .engine = VtEngine.from(FakeEngine, &fake), .dirty_slot = &slot };
    const published = try bridge.feedAndPublish("hello", 100);
    try std.testing.expect(published.generation != null);
    var destination: [4]u32 = undefined;
    const snapshot = (try slot.take(0, &destination)).?;
    try std.testing.expectEqualSlices(u32, &.{ 1, 4 }, snapshot.pages);
}

test "feed bridge absorbs dirty slot backpressure" {
    var fake: FakeEngine = .{};
    var slot = try DirtySlot.init(std.testing.allocator, 4);
    defer slot.deinit(std.testing.allocator);
    var bridge: FeedBridge = .{ .engine = VtEngine.from(FakeEngine, &fake), .dirty_slot = &slot };
    _ = try bridge.feedAndPublish("one", 100);
    _ = try bridge.feedAndPublish("two", 200);
    // Third unconsumed generation: the hint is dropped, but the feed itself
    // must keep succeeding — a UI that is behind must never tear down the
    // SSH connection.
    const published = try bridge.feedAndPublish("three", 300);
    try std.testing.expect(published.generation == null);
}

test "feed bridge skips dirty publication when nothing is dirty" {
    var fake: FakeEngine = .{};
    var slot = try DirtySlot.init(std.testing.allocator, 4);
    defer slot.deinit(std.testing.allocator);
    var bridge: FeedBridge = .{ .engine = VtEngine.from(FakeEngine, &fake), .dirty_slot = &slot };
    const published = try bridge.feedAndPublish("", 100);
    try std.testing.expect(published.generation == null);
}

const FakeProjectionEngine = struct {
    cols: u16 = 20,
    rows: u16 = 2,
    cursor: @import("engine.zig").Cursor = .{ .row = 1, .col = 5, .visible = true },
    feed_count: usize = 0,

    pub fn destroy(_: *FakeProjectionEngine) void {}
    pub fn feed(self: *FakeProjectionEngine, _: []const u8) !FeedResult {
        self.feed_count += 1;
        return .{ .dirty_pages = &.{}, .cursor_moved = false, .bell = false };
    }
    pub fn resize(_: *FakeProjectionEngine, _: u16, _: u16) !void {}
    pub fn snapshot(self: *FakeProjectionEngine) @import("engine.zig").Snapshot {
        return .{ .cols = self.cols, .rows = self.rows, .cursor = self.cursor, .page_versions = &.{}, .scroll_offset = 0 };
    }
    pub fn lineAt(self: *FakeProjectionEngine, row: u64) ?@import("engine.zig").LineView {
        if (row >= self.rows) return null;
        return .{ .abs_row = row, .cells = &.{}, .received_at_ms = 0 };
    }
    pub fn selectionText(_: *FakeProjectionEngine, _: @import("engine.zig").Selection, _: @import("engine.zig").CopyMode, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, "");
    }
    pub fn setOscCallback(_: *FakeProjectionEngine, _: ?@import("engine.zig").OscCallback) void {}
};

test "feed bridge publishes cursor metadata with the text frame" {
    var fake: FakeProjectionEngine = .{};
    var text = try TextSlot.init(std.testing.allocator, 64);
    defer text.deinit(std.testing.allocator);
    var bridge: FeedBridge = .{ .engine = VtEngine.from(FakeProjectionEngine, &fake), .text_slot = &text };
    _ = try bridge.feedAndPublish("data", 100);
    var scratch: [64]u8 = undefined;
    const payload = (try text.take(0, &scratch)).?;
    const frame = text_frame.decode(payload.text).?;
    try std.testing.expectEqual(@as(u32, 1), frame.cursor.row);
    try std.testing.expectEqual(@as(u16, 5), frame.cursor.col);
    try std.testing.expect(frame.cursor.visible);
    try std.testing.expectEqual(@as(u16, 20), frame.cols);
    try std.testing.expectEqual(@as(u16, 2), frame.rows);
}

test "feed bridge retries text publication after the consumer catches up" {
    var fake: FakeProjectionEngine = .{};
    var text = try TextSlot.init(std.testing.allocator, 32);
    defer text.deinit(std.testing.allocator);
    var bridge: FeedBridge = .{ .engine = VtEngine.from(FakeProjectionEngine, &fake), .text_slot = &text };
    // Triple-depth slot: three publishes fit; the fourth hits ConsumerBehind.
    _ = try bridge.feedAndPublish("one", 100);
    _ = try bridge.feedAndPublish("two", 200);
    _ = try bridge.feedAndPublish("three", 300);
    _ = try bridge.feedAndPublish("four", 400);
    try std.testing.expect(bridge.republish_pending);
    // UI catches up: consume the latest generation.
    var scratch: [32]u8 = undefined;
    _ = (try text.take(0, &scratch)).?;
    // Worker retries on its next step; the frame becomes publishable again.
    bridge.publishCurrentText(500);
    try std.testing.expect(!bridge.republish_pending);
    const latest = (try text.take(0, &scratch)).?;
    try std.testing.expect(text_frame.decode(latest.text) != null);
}

test "feed bridge notifies after its publication receipt is committed" {
    const wake = @import("../platform/presentation_wakeup.zig");
    const Observer = struct {
        var bridge: *FeedBridge = undefined;
        var observed: ?FeedBridge.Publication = null;
        fn notified() void {
            // Model a main thread that immediately handles the TextSlot wake.
            // That wake can precede the bridge's publication receipt.
            _ = wake.take();
            observed = bridge.notificationPublication();
        }
    };
    const previous = wake.wake_fn;
    _ = wake.take();
    defer {
        wake.wake_fn = previous;
        _ = wake.take();
    }
    var fake: FakeProjectionEngine = .{};
    var text = try TextSlot.init(std.testing.allocator, 64);
    defer text.deinit(std.testing.allocator);
    var bridge: FeedBridge = .{ .engine = VtEngine.from(FakeProjectionEngine, &fake), .text_slot = &text };
    Observer.bridge = &bridge;
    Observer.observed = null;
    wake.wake_fn = Observer.notified;
    _ = try bridge.feedAndPublish("data", 100);
    try std.testing.expect(Observer.observed != null);
    try std.testing.expectEqual(text.generation.load(.acquire), Observer.observed.?.text_generation);
}

test "notification feed publication receipt excludes throttled and rejected future output" {
    const a = std.testing.allocator;
    var adapter = try @import("ghostty_adapter.zig").Adapter.init(a, 2, 20);
    defer adapter.destroy();
    var text = try TextSlot.init(a, 4096);
    defer text.deinit(a);
    var bridge: FeedBridge = .{ .engine = VtEngine.from(@import("ghostty_adapter.zig").Adapter, &adapter), .text_slot = &text };
    try std.testing.expect(bridge.notificationPublication() == null);
    _ = try bridge.feedAndPublish("one", 100);
    const first = bridge.notificationPublication().?;
    try std.testing.expectEqual(@as(u64, 1), first.output_sequence);
    try std.testing.expectEqual(text.generation.load(.acquire), first.text_generation);
    _ = try bridge.feedAndPublish("two", 101);
    try std.testing.expectEqualDeep(first, bridge.notificationPublication().?);
    try std.testing.expectEqual(@as(u64, 2), adapter.snapshot().output_sequence);
    bridge.publishCurrentText(110);
    try std.testing.expectEqual(@as(u64, 2), bridge.notificationPublication().?.output_sequence);
    _ = try bridge.feedAndPublish("three", 120);
    const full = bridge.notificationPublication().?;
    _ = try bridge.feedAndPublish("four", 130);
    try std.testing.expect(bridge.republish_pending);
    try std.testing.expectEqualDeep(full, bridge.notificationPublication().?);
    try std.testing.expectEqual(@as(u64, 4), adapter.snapshot().output_sequence);
    var scratch: [4096]u8 = undefined;
    _ = (try text.take(0, &scratch)).?;
    bridge.publishCurrentText(140);
    try std.testing.expectEqual(@as(u64, 4), bridge.notificationPublication().?.output_sequence);
    try std.testing.expectEqual(text.generation.load(.acquire), bridge.notificationPublication().?.text_generation);
}

test "deferred burst publication uses display deadline instead of idle transport timeout" {
    var engine: FakeEngine = .{};
    var slot = try TextSlot.init(std.testing.allocator, 128);
    defer slot.deinit(std.testing.allocator);
    var feed: FeedBridge = .{ .engine = VtEngine.from(FakeEngine, &engine), .text_slot = &slot, .republish_pending = true, .last_publish_ms = 100 };
    try std.testing.expectEqual(@as(u32, 6), feed.publicationTimeout(50, 102));
    try std.testing.expectEqual(@as(u32, 0), feed.publicationTimeout(50, 109));
    for (0..3) |_| _ = try slot.publish("x");
    try std.testing.expectEqual(@as(u32, 50), feed.publicationTimeout(50, 109));
    _ = slot.acknowledge(0);
    try std.testing.expectEqual(@as(u32, 0), feed.publicationTimeout(50, 109));
}
