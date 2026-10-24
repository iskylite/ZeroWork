const std = @import("std");
const EffectBase = @import("effect_base.zig").EffectBase;

/// BatchContext: batch update context
///
/// Scheduling is delegated to ReactiveGraph (owner.graph). This struct retains:
///   1. nesting_level: nested batch count (public API)
///   2. is_batching: getter for compatibility queries
/// queueEffect / flush / pending_effects paths are deprecated; signal.set does not use this queue.
/// Scheduling uses graph.markSignalWritten + graph.endBatch topological drain.
pub const BatchContext = struct {
    /// Queue of Effects to execute
    pending_effects: std.ArrayList(*EffectBase),

    /// Whether in batch mode
    is_batching: bool = false,

    /// Nesting level
    nesting_level: u32 = 0,

    /// Parent allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BatchContext {
        return .{
            .pending_effects = @as(std.ArrayList(*EffectBase), .empty),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BatchContext) void {
        self.pending_effects.deinit(self.allocator);
    }

    /// Begin batch update
    pub fn begin(self: *BatchContext) !void {
        self.nesting_level += 1;
        if (self.nesting_level == 1) {
            self.is_batching = true;
            self.pending_effects.clearRetainingCapacity();
        }
    }

    /// End batch update
    ///
    /// owner: *SignalOwner (type-erased to anyopaque, avoid circular dependency)
    pub fn end(self: *BatchContext, owner: anytype) void {
        if (self.nesting_level == 0) return;

        self.nesting_level -= 1;

        // Execute only when outermost batch ends
        if (self.nesting_level == 0) {
            // Note: do not set is_batching=false here; flush manages batching state internally.
            // This ensures new Effects during flush still use batch path (queueEffect).
            self.flush(owner);
        }
    }

    /// Add Effect to execution queue
    pub fn queueEffect(self: *BatchContext, effect: *EffectBase) !void {
        // Avoid duplicate additions
        if (effect.is_queued) return;

        try self.pending_effects.append(self.allocator, effect);
        effect.is_queued = true;
    }

    /// Execute all pending Effects with a drain loop (batching stays on during flush).
    /// New Signal changes inside an Effect queue more Effects. Loop until empty or the
    /// 1024-iteration
    /// limit. At the limit: panic (debug) / error log (release), never silent discard, since it
    /// indicates a real circular dependency bug.
    fn flush(self: *BatchContext, owner: anytype) void {
        const max_iterations: u32 = 1024;
        var iteration: u32 = 0;

        while (self.pending_effects.items.len > 0 and iteration < max_iterations) {
            iteration += 1;

            // Keep batching on; new Effects during flush enter queue.
            self.is_batching = true;

            // Snapshot current queue length; execute only Effects from this round.
            const count = self.pending_effects.items.len;
            for (self.pending_effects.items[0..count]) |effect| {
                effect.is_queued = false;
                effect.runWithTracking(owner, self.allocator);
            }

            // Remove executed Effects (new ones may be appended).
            if (self.pending_effects.items.len > count) {
                std.mem.copyForwards(
                    *EffectBase,
                    self.pending_effects.items[0 .. self.pending_effects.items.len - count],
                    self.pending_effects.items[count..],
                );
                self.pending_effects.shrinkRetainingCapacity(self.pending_effects.items.len - count);
            } else {
                self.pending_effects.clearRetainingCapacity();
            }
        }

        self.is_batching = false;

        if (iteration >= max_iterations and self.pending_effects.items.len > 0) {
            // True circular dependency; not silent discard, clear error for developer.
            // Debug: panic; release: severe log + clear queue to prevent deadloop (not silent).
            if (std.debug.runtime_safety) {
                std.debug.panic(
                    "[reactive.BatchContext] flush did not converge after {d} iterations, {d} effects pending — likely cyclic dependency",
                    .{ max_iterations, self.pending_effects.items.len },
                );
            } else {
                std.log.err(
                    "[reactive.BatchContext] flush did not converge after {d} iterations, {d} effects pending — likely cyclic dependency",
                    .{ max_iterations, self.pending_effects.items.len },
                );
            }
            for (self.pending_effects.items) |effect| {
                effect.is_queued = false;
            }
            self.pending_effects.clearRetainingCapacity();
        }
    }
};

// ===== Tests =====

test "BatchContext: init/deinit" {
    var ctx = BatchContext.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.is_batching == false);
    try std.testing.expectEqual(@as(u32, 0), ctx.nesting_level);
}

test "BatchContext: nesting" {
    var ctx = BatchContext.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.begin();
    try std.testing.expect(ctx.is_batching == true);
    try std.testing.expectEqual(@as(u32, 1), ctx.nesting_level);

    try ctx.begin(); // Nested batches
    try std.testing.expectEqual(@as(u32, 2), ctx.nesting_level);

    // Mock owner (simplified test)
    var mock_owner = struct {
        current_effect: ?*EffectBase = null,
    }{};

    ctx.end(&mock_owner);
    try std.testing.expect(ctx.is_batching == true); // Still in batch mode
    try std.testing.expectEqual(@as(u32, 1), ctx.nesting_level);

    ctx.end(&mock_owner);
    try std.testing.expect(ctx.is_batching == false); // Exited batch mode
    try std.testing.expectEqual(@as(u32, 0), ctx.nesting_level);
}
