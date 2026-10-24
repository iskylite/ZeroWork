const std = @import("std");

/// EffectBase: type-erased Effect base class
///
/// Why base class?
/// - SignalOwner needs unified Effect management
/// - Polymorphism via virtual function table
///
/// Single-track dependency: all relations go through ReactiveGraph (src/ui/reactive/graph.zig);
/// graph.sources is the sole dependency source.
pub const EffectBase = struct {
    /// Virtual function table
    vtable: *const VTable,

    /// For effect self-allocation (Scope path: scope.allocator; Arena path: fallback)
    scope_allocator: ?std.mem.Allocator = null,

    /// Effect in execution queue (avoid duplicate-add)
    is_queued: bool = false,
    /// Effect running (prevent recursive execute)
    is_running: bool = false,
    /// Marked needs re-run when re-triggered mid-execution
    needs_rerun: bool = false,

    /// Corresponding NodeId raw in ReactiveGraph (0xFFFFFFFF = unregistered).
    /// Register on effect create; run arrives via graph topological order.
    graph_node_raw: u32 = 0xFFFFFFFF,

    pub const VTable = struct {
        /// Run Effect
        run: *const fn (*EffectBase) void,

        /// Clean up Effect
        cleanup: *const fn (*EffectBase) void,

        /// Free concrete type memory (Scope dispose uses this);
        /// null means Arena-managed (old path)
        destroy: ?*const fn (*EffectBase, std.mem.Allocator) void = null,
    };

    /// Initialize EffectBase
    pub fn init(allocator: std.mem.Allocator, vtable: *const VTable) EffectBase {
        _ = allocator;
        return .{
            .vtable = vtable,
        };
    }

    /// Run Effect
    pub fn run(self: *EffectBase) void {
        self.vtable.run(self);
    }

    /// Clean Effect
    pub fn cleanup(self: *EffectBase) void {
        self.vtable.cleanup(self);
    }

    /// Free concrete type memory (Scope dispose calls)
    pub fn destroy(self: *EffectBase, allocator: std.mem.Allocator) void {
        if (self.vtable.destroy) |destroyFn| {
            destroyFn(self, allocator);
        }
    }

    /// Run Effect and re-collect dependencies, with reentry guard
    ///
    /// runWithTrackingFast skips graph.clearSources/pushTracking setup. Call it only from
    /// graph.recomputeNode -> graphRecomputeCb, which already did those.
    pub fn runWithTrackingFast(self: *EffectBase, owner: anytype) void {
        if (self.is_running) {
            self.needs_rerun = true;
            return;
        }

        const has_deferred_disposal = comptime @hasDecl(@TypeOf(owner.*), "beginReactiveCallback");
        if (has_deferred_disposal) owner.beginReactiveCallback();
        defer if (has_deferred_disposal) owner.endReactiveCallback();

        self.is_running = true;
        defer self.is_running = false;

        var rerun_count: u32 = 0;
        const max_reruns: u32 = 128;

        while (true) {
            self.needs_rerun = false;

            const prev_effect = owner.current_effect;
            owner.current_effect = self;
            defer owner.current_effect = prev_effect;

            self.run();

            if (!self.needs_rerun) break;

            rerun_count += 1;
            if (rerun_count >= max_reruns) {
                if (std.debug.runtime_safety) {
                    std.debug.panic("Effect re-run limit exceeded ({d})", .{max_reruns});
                } else {
                    std.log.err("Effect re-run limit exceeded ({d}); skipping further runs", .{max_reruns});
                }
                break;
            }
        }
    }

    /// Single-track: push/pop graph.tracking_stack + clearSources.
    /// For (a) effect create initial run (effect.zig:50/75) and (b) batch.flush path
    /// (batch.zig:93).
    /// graph.recomputeNode -> graphRecomputeCb path use runWithTrackingFast to skip duplicate
    /// setup.
    pub fn runWithTracking(self: *EffectBase, owner: anytype, allocator: std.mem.Allocator) void {
        if (self.is_running) {
            self.needs_rerun = true;
            return;
        }

        const has_deferred_disposal = comptime @hasDecl(@TypeOf(owner.*), "beginReactiveCallback");
        if (has_deferred_disposal) owner.beginReactiveCallback();
        defer if (has_deferred_disposal) owner.endReactiveCallback();

        self.is_running = true;
        defer self.is_running = false;

        _ = allocator;
        var rerun_count: u32 = 0;
        const max_reruns: u32 = 128;

        while (true) {
            self.needs_rerun = false;

            // Set current Effect (compatible with untrack detection; signal.get still needs
            // owner.current_effect)
            const prev_effect = owner.current_effect;
            owner.current_effect = self;
            defer owner.current_effect = prev_effect;

            // Single-track: push graph node, let signal.get -> graph.trackRead add edge
            const has_graph = comptime @hasField(@TypeOf(owner.*), "graph");
            const has_node = has_graph and self.graph_node_raw != 0xFFFFFFFF;
            if (has_node) {
                const nid: @import("graph.zig").NodeId = @bitCast(self.graph_node_raw);
                if (owner.graph.getNode(nid)) |node| node.tracking_failed = false;
                owner.graph.pushTracking(nid) catch {
                    if (owner.graph.getNode(nid)) |node| {
                        node.tracking_failed = true;
                        node.state = .dirty;
                    }
                    return;
                };
                owner.graph.clearSourcesPub(nid);
            }
            defer if (has_node) owner.graph.popTracking();

            // Execute Effect
            self.run();

            if (!self.needs_rerun) break;

            rerun_count += 1;
            if (rerun_count >= max_reruns) {
                if (std.debug.runtime_safety) {
                    std.debug.panic("Effect re-run limit exceeded ({d})", .{max_reruns});
                } else {
                    std.log.err("Effect re-run limit exceeded ({d}); skipping further runs", .{max_reruns});
                }
                break;
            }
        }
    }
};
