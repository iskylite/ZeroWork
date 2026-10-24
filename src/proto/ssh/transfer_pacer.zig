const std = @import("std");

pub const Pacer = struct {
    target_kbps: u32,
    sent_bytes: u64 = 0,
    elapsed_ms: u64 = 0,

    pub fn init(target_kbps: u32) !Pacer {
        return .{ .target_kbps = target_kbps };
    }

    pub fn record(self: *Pacer, bytes: usize, elapsed_ms: u64) void {
        self.sent_bytes +|= bytes;
        self.elapsed_ms +|= elapsed_ms;
    }

    pub fn allowedBytes(self: Pacer, elapsed_ms: u64) u64 {
        if (self.target_kbps == 0) return std.math.maxInt(u64);
        const allowed = @as(u128, self.target_kbps) * 1024 * elapsed_ms / 1000;
        return @intCast(@min(allowed, std.math.maxInt(u64)));
    }

    pub fn delayMs(self: Pacer, pending_bytes: usize) u64 {
        if (self.target_kbps == 0) return 0;
        const allowed = self.allowedBytes(self.elapsed_ms +| 1);
        const requested = @as(u128, self.sent_bytes) + pending_bytes;
        if (requested <= allowed) return 0;
        const rate = @as(u64, self.target_kbps) * 1024;
        const delay = ((requested - allowed) * 1000 + rate - 1) / rate;
        return @intCast(@min(delay, std.math.maxInt(u64)));
    }
};

test "pacer limits shared channel transfer rate" {
    var pacer = try Pacer.init(1024);
    pacer.record(512 * 1024, 0);
    try std.testing.expect(pacer.delayMs(512 * 1024) > 0);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), pacer.allowedBytes(1000));
}

test "pacer zero explicitly means unlimited and counters saturate" {
    var unlimited = try Pacer.init(0);
    unlimited.record(std.math.maxInt(usize), std.math.maxInt(u64));
    unlimited.record(1, 1);
    try std.testing.expectEqual(@as(u64, 0), unlimited.delayMs(std.math.maxInt(usize)));
    try std.testing.expectEqual(std.math.maxInt(u64), unlimited.allowedBytes(std.math.maxInt(u64)));
    const largest = try Pacer.init(std.math.maxInt(u32));
    try std.testing.expectEqual(std.math.maxInt(u64), largest.allowedBytes(std.math.maxInt(u64)));
}

/// Sole-IO-owner token budget. Refill is capped to one bounded IO slice, so
/// metadata work or an idle connection cannot accumulate an unlimited burst.
/// A zero rate is explicitly unlimited. No waiting or sleeping happens here.
pub const Budget = struct {
    pub const scale: u64 = std.time.ns_per_s;
    target_kbps: u32 = 0,
    capacity: u32 = 32 * 1024,
    last_ns: u64 = 0,
    scaled_tokens: u64 = 0,

    pub fn setRate(self: *Budget, rate: u32, now_ns: u64) void {
        if (self.target_kbps == rate) return;
        self.target_kbps = rate;
        self.last_ns = now_ns;
        self.scaled_tokens = 0;
    }

    pub fn allowance(self: *Budget, now_ns: u64, requested: usize) usize {
        const bounded = @min(requested, self.capacity);
        if (self.target_kbps == 0) return bounded;
        const elapsed = now_ns -| self.last_ns;
        // Never mint additional credit if a supplied clock moves backwards.
        self.last_ns = @max(now_ns, self.last_ns);
        const refill = @as(u128, elapsed) * self.target_kbps * 1024;
        const ceiling = @as(u64, self.capacity) * scale;
        self.scaled_tokens = @intCast(@min(ceiling, @as(u128, self.scaled_tokens) + refill));
        return @intCast(@min(bounded, self.scaled_tokens / scale));
    }

    pub fn consume(self: *Budget, bytes: usize) void {
        if (self.target_kbps == 0) return;
        const amount: u64 = @intCast(@as(u128, bytes) * scale);
        std.debug.assert(amount <= self.scaled_tokens);
        self.scaled_tokens -= amount;
    }
};

test "pacer budget exact elapsed credit short IO and idle bursts" {
    var budget: Budget = .{ .capacity = 1024 };
    budget.setRate(4, 100);
    try std.testing.expectEqual(@as(usize, 0), budget.allowance(100, 4096));
    try std.testing.expectEqual(@as(usize, 512), budget.allowance(100 + std.time.ns_per_s / 8, 4096));
    budget.consume(100);
    try std.testing.expectEqual(@as(usize, 412), budget.allowance(100 + std.time.ns_per_s / 8, 4096));
    // Repeated same-clock calls and backwards clocks cannot earn credit.
    try std.testing.expectEqual(@as(usize, 412), budget.allowance(0, 4096));
    try std.testing.expectEqual(@as(usize, 1024), budget.allowance(std.math.maxInt(u64), 4096));
    budget.consume(1024);
    try std.testing.expectEqual(@as(usize, 0), budget.allowance(std.math.maxInt(u64), 4096));
    budget.setRate(0, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 1024), budget.allowance(0, 4096));
    budget.consume(1024);
    budget.setRate(std.math.maxInt(u32), 0);
    try std.testing.expectEqual(@as(usize, 1024), budget.allowance(std.math.maxInt(u64), 4096));
}
