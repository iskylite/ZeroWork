//! Native monotonic profiling for D3D12 APIs that do not own an Io context.
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;

pub fn nowNanoseconds() ?u64 {
    var counter: i64 = undefined;
    var frequency: i64 = undefined;
    if (QueryPerformanceCounter(&counter) == 0 or QueryPerformanceFrequency(&frequency) == 0 or counter < 0 or frequency <= 0) return null;
    return @intCast(@divTrunc(@as(i128, counter) * 1_000_000_000, frequency));
}
