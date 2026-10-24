/// Frame-level Timeline Profiler that records phase timing for the last 128 frames
///
/// Usage:
/// ```zig
/// profiler.beginFrame();
/// profiler.markPhase(.layout);
/// // ... layout ...
/// profiler.markPhase(.before_render);
/// // ... before_render ...
/// profiler.markPhase(.render);
/// // ... render ...
/// profiler.endFrame();
/// ```
const std = @import("std");

/// Frame rendering phases
pub const Phase = enum(u8) {
    layout = 0,
    before_render = 1,
    render = 2,
    encode = 3,
    flush = 4,
    deferred = 5,
    idle = 6, // inter-frame idle (non-rendering time)
};

/// Single frame timeline
pub const FrameTimeline = struct {
    /// Duration of each phase (microseconds)
    phase_us: [7]u64 = @as([7]u64, @splat(0)),
    /// Total frame duration (microseconds)
    total_us: u64 = 0,
    /// Frame number
    frame_number: u64 = 0,
};

/// Timeline Profiler
pub const TimelineProfiler = struct {
    io: std.Io,
    /// Ring buffer (last 128 frames)
    ring_buffer: [ring_size]FrameTimeline = @as([ring_size]FrameTimeline, @splat(.{})),
    /// Write position
    write_pos: u7 = 0,
    /// Number of recorded frames
    frame_count: u64 = 0,
    /// Enabled
    enabled: bool = false,

    /// Timing state for current frame
    frame_start: ?@import("zenit_time").Instant = null,
    current_phase: ?Phase = null,
    phase_start: ?@import("zenit_time").Instant = null,
    current_frame: FrameTimeline = .{},

    const ring_size = 128;

    /// Start timing new frame
    pub fn beginFrame(self: *TimelineProfiler) void {
        if (!self.enabled) return;
        self.frame_start = @import("zenit_time").Instant.now(self.io) catch null;
        self.current_frame = .{ .frame_number = self.frame_count };
        self.current_phase = null;
        self.phase_start = null;
    }

    /// Mark entering new phase (auto-end previous phase timing)
    pub fn markPhase(self: *TimelineProfiler, phase: Phase) void {
        if (!self.enabled) return;
        const now = @import("zenit_time").Instant.now(self.io) catch return;

        // End previous phase
        if (self.current_phase) |prev_phase| {
            if (self.phase_start) |start| {
                const elapsed_ns = now.since(start);
                self.current_frame.phase_us[@backingInt(prev_phase)] = elapsed_ns / 1000;
            }
        }

        // Start new phase
        self.current_phase = phase;
        self.phase_start = now;
    }

    /// End current frame timing, write to ring buffer
    pub fn endFrame(self: *TimelineProfiler) void {
        if (!self.enabled) return;
        const now = @import("zenit_time").Instant.now(self.io) catch return;

        // End last phase
        if (self.current_phase) |prev_phase| {
            if (self.phase_start) |start| {
                const elapsed_ns = now.since(start);
                self.current_frame.phase_us[@backingInt(prev_phase)] = elapsed_ns / 1000;
            }
        }

        // Total frame time
        if (self.frame_start) |start| {
            self.current_frame.total_us = now.since(start) / 1000;
        }

        // Write to ring buffer
        self.ring_buffer[self.write_pos] = self.current_frame;
        self.write_pos +%= 1;
        self.frame_count += 1;

        // Reset
        self.frame_start = null;
        self.current_phase = null;
    }
};

test "TimelineProfiler: basic recording" {
    var profiler = TimelineProfiler{ .io = std.testing.io, .enabled = true };

    profiler.beginFrame();
    profiler.markPhase(.layout);
    profiler.markPhase(.render);
    profiler.endFrame();

    try std.testing.expect(profiler.frame_count == 1);
    try std.testing.expect(profiler.ring_buffer[0].frame_number == 0);
}
