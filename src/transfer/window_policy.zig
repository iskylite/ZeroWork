const std = @import("std");

/// Service implementation limits for this engine revision. These are not
/// prototype defaults: 2 MiB derives from the previous 32 KiB x 64 capacity,
/// and 6 MiB preserves that capacity across the original three running jobs.
pub const max_job_window_bytes: u64 = 32 * 1024 * 64;
pub const max_global_window_bytes: u64 = max_job_window_bytes * 3;
pub const max_concurrency: u16 = std.math.maxInt(u8);

pub fn chunkBytes(chunk_kb: u16) !u32 {
    if (chunk_kb == 0) return error.InvalidTransferChunk;
    return std.math.mul(u32, chunk_kb, 1024) catch error.TransferWindowOverflow;
}

pub fn windowBytes(chunk_kb: u16, window_chunks: u8) !u64 {
    if (window_chunks == 0) return error.InvalidTransferWindow;
    const bytes = try chunkBytes(chunk_kb);
    const window = std.math.mul(u64, bytes, window_chunks) catch return error.TransferWindowOverflow;
    if (window > max_job_window_bytes) return error.TransferWindowBudgetExceeded;
    return window;
}

/// Pure preflight for settings and before any connection/authentication IO.
/// Manager also checks the actual active frozen policies when scheduling.
pub fn validateWindowPolicy(chunk_kb: u16, window_chunks: u8, concurrency: u16) !void {
    if (concurrency == 0 or concurrency > max_concurrency) return error.InvalidTransferConcurrency;
    const window = try windowBytes(chunk_kb, window_chunks);
    const total = std.math.mul(u64, window, concurrency) catch return error.TransferWindowOverflow;
    if (total > max_global_window_bytes) return error.TransferGlobalWindowBudgetExceeded;
}

test "window policy defaults and configured logical dimensions are exact KiB" {
    try validateWindowPolicy(64, 16, 3);
    try std.testing.expectEqual(@as(u32, 65_536), try chunkBytes(64));
    try std.testing.expectEqual(@as(u64, 1_048_576), try windowBytes(64, 16));
    try validateWindowPolicy(1, 255, 3);
    try validateWindowPolicy(2048, 1, 3);
    try std.testing.expectEqual(max_job_window_bytes, try windowBytes(2048, 1));
    try std.testing.expectEqual(@as(u32, 65_535 * 1024), try chunkBytes(65_535));
}

test "window policy refuses invalid or over budget combinations without clipping" {
    try std.testing.expectError(error.InvalidTransferChunk, validateWindowPolicy(0, 16, 3));
    try std.testing.expectError(error.InvalidTransferWindow, validateWindowPolicy(64, 0, 3));
    try std.testing.expectError(error.InvalidTransferConcurrency, validateWindowPolicy(64, 16, 0));
    try std.testing.expectError(error.InvalidTransferConcurrency, validateWindowPolicy(1, 1, 256));
    try std.testing.expectError(error.TransferWindowBudgetExceeded, validateWindowPolicy(2049, 1, 1));
    try std.testing.expectError(error.TransferWindowBudgetExceeded, validateWindowPolicy(65_535, 255, 255));
    try std.testing.expectError(error.TransferGlobalWindowBudgetExceeded, validateWindowPolicy(64, 16, 7));
    try std.testing.expectError(error.TransferGlobalWindowBudgetExceeded, validateWindowPolicy(2048, 1, 4));
    // The large concurrency input remains valid with a small actual window.
    try validateWindowPolicy(1, 1, 255);
}
