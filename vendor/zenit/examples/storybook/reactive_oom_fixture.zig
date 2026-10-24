//! Test-mode fault injection for the real navigation signal and its consumers.
const std = @import("std");
const ui = @import("ui");
var active: ?*ui.Signal(usize) = null;
var target_index: usize = 0;

pub fn install(signal: *ui.Signal(usize), index: usize) void {
    active = signal;
    target_index = index;
}

pub fn route(path: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.eql(u8, path, "/review/reactive-propagation-oom")) return null;
    return inject(out) catch |err| std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
}

fn inject(out: []u8) ![]const u8 {
    const signal = active orelse return error.NoSignal;
    if (signal.peek() == target_index) return error.AlreadyAtTarget;
    const graph = &signal.owner.graph;
    const backing = graph.allocator;
    // Force the first propagation worklist reservation to grow, even if prior
    // normal navigation has already warmed it. Free through its owning allocator.
    graph.propagation_stack.deinit(backing);
    graph.propagation_stack = .empty;
    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    graph.beginBatch();
    graph.allocator = failing.allocator();
    signal.set(target_index);
    graph.allocator = backing;
    try graph.endBatch();
    // An identical retry is deliberately a no-op; recovery cannot depend on
    // inventing a second, different application value.
    signal.set(target_index);
    return std.fmt.bufPrint(out, "{{\"allocation_failed\":{},\"source\":{d},\"target\":{d}}}", .{ failing.has_induced_failure, signal.peek(), target_index });
}
