const std = @import("std");

/// SignalBase: type-erased Signal base class
///
/// Why a base class?
/// - SignalOwner needs unified management of all Signal types
/// - It allows Signal(i32), Signal([]const u8) etc. in unified storage
/// - A virtual function table implements polymorphism
///
/// Tracking is single-track: all subscribers go through ReactiveGraph (src/ui/reactive/graph.zig);
/// graph.observers is the sole observer source, and signal.set goes through
/// graph.markSignalWritten.
pub const SignalBase = struct {
    /// Virtual function table
    vtable: *const VTable,

    /// For signal self allocation (Scope path uses scope.allocator; Arena path uses fallback)
    scope_allocator: ?std.mem.Allocator = null,

    /// Corresponding NodeId in ReactiveGraph (u32, 0xFFFFFFFF = unregistered). Signal create
    /// registers sync to graph; set path uses graph.markSignalWritten for topo order + version
    /// stamp propagation.
    graph_node_raw: u32 = 0xFFFFFFFF,

    pub const VTable = struct {
        /// Cleanup function
        cleanup: *const fn (*SignalBase) void,

        /// Free concrete type memory (used on Scope dispose). null means Arena-managed (old path)
        destroy: ?*const fn (*SignalBase, std.mem.Allocator) void = null,
    };

    /// Initialize SignalBase
    pub fn init(allocator: std.mem.Allocator, vtable: *const VTable) SignalBase {
        _ = allocator;
        return .{
            .vtable = vtable,
        };
    }

    /// Clean up Signal
    pub fn cleanup(self: *SignalBase) void {
        self.vtable.cleanup(self);
    }

    /// Free concrete type memory (called by Scope dispose)
    pub fn destroy(self: *SignalBase, allocator: std.mem.Allocator) void {
        if (self.vtable.destroy) |destroyFn| {
            destroyFn(self, allocator);
        }
    }
};
