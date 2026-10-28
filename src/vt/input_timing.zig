//! Opt-in test-build diagnostics. One isolated input per surface is measured.
//! First output after a completed write is a causal candidate, not proof of
//! echo: the external fixture must verify the expected marker. No text is logged.
const std = @import("std");
const automation = @import("../platform/runtime_mode.zig").automation;
pub var enabled = false;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
pub fn configure() void {
    if (comptime automation) enabled = getenv("ZEROWORK_INPUT_TIMING") != null;
}
const Sample = struct {
    sequence: u64 = 0,
    end_offset: usize = 0,
    output_sequence: u64 = 0,
    ui: i64 = 0,
    accepted: i64 = 0,
    written: i64 = 0,
    received: i64 = 0,
    published: i64 = 0,
    applied: i64 = 0,
};
pub const Trace = struct {
    mutex: std.atomic.Mutex = .unlocked,
    sample: Sample = .{},
    session: u64 = 0,
    generation: u64 = 0,
    skipped: u64 = 0,
    pub fn begin(self: *Trace, sequence: u64) void {
        if (!enabled or !self.mutex.tryLock()) return;
        defer self.mutex.unlock();
        // Overlapping input cannot be attributed to a single returned batch.
        if (self.sample.sequence != 0 and now() - self.sample.ui < 5 * std.time.ns_per_s) {
            self.sample = .{};
            self.skipped += 1;
            return;
        }
        self.sample = .{ .sequence = sequence, .ui = now() };
    }
    pub fn accepted(self: *Trace, sequence: u64, end_offset: usize) void {
        if (!enabled or !self.mutex.tryLock()) return;
        defer self.mutex.unlock();
        if (self.sample.sequence != sequence) return;
        self.sample.accepted = now();
        self.sample.end_offset = end_offset;
    }
    pub fn written(self: *Trace, sequence: u64, end_offset: ?usize) void {
        if (!enabled or !self.mutex.tryLock()) return;
        defer self.mutex.unlock();
        const s = &self.sample;
        if (s.sequence == 0 or s.accepted == 0 or s.written != 0) return;
        if (end_offset) |offset| {
            if (offset < s.end_offset) return;
        } else if (s.sequence != sequence) return;
        s.written = now();
    }
    pub fn received(self: *Trace, output_sequence: u64) void {
        if (!enabled or !self.mutex.tryLock()) return;
        defer self.mutex.unlock();
        if (self.sample.written == 0 or self.sample.received != 0) return;
        self.sample.received = now();
        self.sample.output_sequence = output_sequence;
    }
    pub fn published(self: *Trace, output_sequence: u64) void {
        if (!enabled or !self.mutex.tryLock()) return;
        defer self.mutex.unlock();
        if (self.sample.received == 0 or self.sample.published != 0 or output_sequence < self.sample.output_sequence) return;
        self.sample.published = now();
    }
    pub fn applied(self: *Trace, output_sequence: u64) void {
        if (!enabled or !self.mutex.tryLock()) return;
        defer self.mutex.unlock();
        if (self.sample.published == 0 or self.sample.applied != 0 or output_sequence < self.sample.output_sequence) return;
        self.sample.applied = now();
    }
    fn finish(self: *Trace) void {
        if (!self.mutex.tryLock()) return;
        const s = self.sample;
        if (s.applied == 0) {
            self.mutex.unlock();
            return;
        }
        self.sample = .{};
        self.mutex.unlock();
        const returned = now();
        // End is after MultiWindowApp.tick returned, not scanout/key-to-photon.
        std.debug.print("[terminal-latency] session={d} generation={d} input={d} output={d} queue_us={d} write_us={d} first_output_us={d} publish_us={d} apply_us={d} frame_return_us={d} total_us={d} skipped={d}\n", .{ self.session, self.generation, s.sequence, s.output_sequence, @divTrunc(s.accepted - s.ui, 1000), @divTrunc(s.written - s.accepted, 1000), @divTrunc(s.received - s.written, 1000), @divTrunc(s.published - s.received, 1000), @divTrunc(s.applied - s.published, 1000), @divTrunc(returned - s.applied, 1000), @divTrunc(returned - s.ui, 1000), self.skipped });
    }
};
fn now() i64 {
    return @intCast(@import("../platform/realtime.zig").monotonicNs());
}
// Main-thread only registry, detached before the surface or worker is released.
var surfaces: [128]?*Trace = @splat(null);
pub fn attach(trace: *Trace, session: u64, generation: u64) void {
    if (!enabled) return;
    trace.session = session;
    trace.generation = generation;
    for (&surfaces) |*slot| if (slot.* == null) {
        slot.* = trace;
        return;
    };
}
pub fn detach(trace: *Trace) void {
    if (!enabled) return;
    for (&surfaces) |*slot| if (slot.* == trace) {
        slot.* = null;
    };
}
pub fn frameReturned() void {
    if (!enabled) return;
    for (surfaces) |slot| if (slot) |trace| trace.finish();
}

test "input timing rejects unrelated write and publication and overlapping input" {
    enabled = true;
    defer enabled = false;
    var trace: Trace = .{};
    trace.begin(1);
    trace.accepted(1, 20);
    trace.written(0, 19);
    trace.received(4);
    try std.testing.expectEqual(@as(i64, 0), trace.sample.received);
    trace.written(0, 20);
    trace.received(5);
    trace.published(4);
    try std.testing.expectEqual(@as(i64, 0), trace.sample.published);
    trace.published(5);
    trace.applied(5);
    try std.testing.expect(trace.sample.applied >= trace.sample.published);
    trace.begin(2);
    try std.testing.expectEqual(@as(u64, 0), trace.sample.sequence);
    try std.testing.expectEqual(@as(u64, 1), trace.skipped);
}
