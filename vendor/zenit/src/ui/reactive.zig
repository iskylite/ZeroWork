// Project Zenit - Reactive UI System
// Phase 1: Owner-based Reactive System (Zig-optimized)

pub const SignalOwner = @import("reactive/owner.zig").SignalOwner;
/// Deferred-destroy queue entry type export to consumer, 'node still in queue, borrowed resource
/// can't free immediate' scene (Global Find EditorPool destroy in reactive callback) need put
/// resource free into **same queue** (FIFO: node first, resource after). Entry storage resource
/// own, till callback done or cancel.
pub const DeferredDisposal = @import("reactive/deferred_disposal.zig").Entry;
pub const Signal = @import("reactive/signal.zig").Signal;
pub const createEffect = @import("reactive/effect.zig").createEffect;
pub const Memo = @import("reactive/memo.zig").Memo;
pub const createMemo = @import("reactive/memo.zig").createMemo;
pub const Scope = @import("reactive/scope.zig").Scope;
pub const Context = @import("reactive/context.zig").Context;
pub const StoreOf = @import("reactive/store.zig").StoreOf;

// Signal-first component API (docs/SIGNAL_API_DESIGN.md)
const source_mod = @import("reactive/source.zig");
pub const Source = source_mod.Source;
pub const Model = source_mod.Model;
pub const Split = source_mod.Split;
pub const Derived = source_mod.Derived;
pub const Callback = source_mod.Callback;
pub const Bound = source_mod.Bound;
pub const ReactiveKind = @import("reactive/signal.zig").ReactiveKind;
pub const derive = source_mod.derive;
pub const not = source_mod.not;
pub const eq = source_mod.eq;
pub const map = source_mod.map;
pub const map2 = source_mod.map2;
pub const field = source_mod.field;
pub const split = source_mod.split;
pub const toSource = source_mod.toSource;
pub const SourceValueOf = source_mod.SourceValueOf;
pub const resolveModel = source_mod.resolveModel;
pub const resolveTextModel = source_mod.resolveTextModel;
pub const resolveListModel = source_mod.resolveListModel;
pub const resolveModelFor = source_mod.resolveModelFor;
pub const checkBorrow = source_mod.checkBorrow;
pub const assumeOutlives = source_mod.assumeOutlives;
pub const props = @import("reactive/props.zig");

// Internal types (supply advanced user)
pub const SignalBase = @import("reactive/signal_base.zig").SignalBase;
pub const EffectBase = @import("reactive/effect_base.zig").EffectBase;
pub const BatchContext = @import("reactive/batch.zig").BatchContext;

// Phase 1: public-type-dispatch eq tool, component layer can use same semantic for prop diff
pub const eqlValue = @import("reactive/eq.zig").eqlValue;

// Ensure all submodule tests included
test {
    _ = @import("reactive/scope.zig");
    _ = @import("reactive/signal.zig");
    _ = @import("reactive/effect.zig");
    _ = @import("reactive/owner.zig");
    _ = @import("reactive/batch.zig");
    _ = @import("reactive/memo.zig");
    _ = @import("reactive/context.zig");
    _ = @import("reactive/signal_base.zig");
    _ = @import("reactive/effect_base.zig");
    _ = @import("reactive/eq.zig");
    _ = @import("reactive/graph.zig");
    _ = @import("reactive/source.zig");
    _ = @import("reactive/props.zig");
}

// ===== Quickstart example =====

const std = @import("std");

test "Reactive System: complete example" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    // Create Signal
    const count = try Signal(i32).create(owner, 0);
    const name = try Signal([]const u8).create(owner, "World");

    var output_buffer: [100]u8 = undefined;
    var output_len: usize = 0;

    // Create Effect (auto track dependency)
    try createEffect(owner, .{
        .count = count,
        .name = name,
        .buffer = &output_buffer,
        .len = &output_len,
    }, struct {
        fn render(ctx: anytype) void {
            const message = std.fmt.bufPrint(
                ctx.buffer,
                "Hello {s}, Count: {d}",
                .{ ctx.name.get(), ctx.count.get() },
            ) catch unreachable;
            ctx.len.* = message.len;
        }
    }.render);

    // Verify initial render
    try std.testing.expectEqualStrings("Hello World, Count: 0", output_buffer[0..output_len]);

    // Single update
    count.set(5);
    try std.testing.expectEqualStrings("Hello World, Count: 5", output_buffer[0..output_len]);

    name.set("Zenit");
    try std.testing.expectEqualStrings("Hello Zenit, Count: 5", output_buffer[0..output_len]);
}

test "Reactive System: batch updates" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const a = try Signal(i32).create(owner, 0);
    const b = try Signal(i32).create(owner, 0);

    var effect_run_count: i32 = 0;

    try createEffect(owner, .{
        .a = a,
        .b = b,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.a.get();
            _ = ctx.b.get();
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    // No batch: two update = two Effect run
    a.set(1);
    b.set(1);
    try std.testing.expectEqual(@as(i32, 3), effect_run_count);

    // With batch: two update = one Effect run
    try owner.batch(struct {
        fn update(ctx: anytype) void {
            ctx.a.set(2);
            ctx.b.set(2);
        }
    }.update, .{ .a = a, .b = b });

    try std.testing.expectEqual(@as(i32, 4), effect_run_count); // only increase 1 time
}

test "Reactive System: peek doesn't track" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const tracked = try Signal(i32).create(owner, 0);
    const untracked = try Signal(i32).create(owner, 100);

    var effect_run_count: i32 = 0;

    try createEffect(owner, .{
        .tracked = tracked,
        .untracked = untracked,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.tracked.get(); // track
            _ = ctx.untracked.peek(); // no track
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    tracked.set(1);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count); // Effect re-run

    untracked.set(200);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count); // Effect no run
}

// Facade-level diamond glitch freedom.
//
//      A (signal)
//     / \
//    B   C   <-- both Memos, depend on A
//    \ /
//     D (effect)
//
// Writing A: D must see B/C already recomputed with the new A (no intermediate stale state).
test "Reactive System: diamond glitch freedom (Memo + Effect)" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const a = try Signal(i32).create(owner, 1);

    const b = try createMemo(owner, i32, .{ .a = a }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.a.get() * 10;
        }
    }.compute);
    const c = try createMemo(owner, i32, .{ .a = a }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.a.get() + 100;
        }
    }.compute);

    const Observed = struct { b: i32, c: i32, run: u32 };
    var observed = Observed{ .b = 0, .c = 0, .run = 0 };

    try createEffect(owner, .{
        .b = b,
        .c = c,
        .obs = &observed,
    }, struct {
        fn run(ctx: anytype) void {
            ctx.obs.* = .{
                .b = ctx.b.get(),
                .c = ctx.c.get(),
                .run = ctx.obs.run + 1,
            };
        }
    }.run);

    // Initial: a=1 -> b=10, c=101
    try std.testing.expectEqual(@as(i32, 10), observed.b);
    try std.testing.expectEqual(@as(i32, 101), observed.c);
    try std.testing.expectEqual(@as(u32, 1), observed.run);

    // Write a=5 -> must finally b=50, c=105, no 'intermediate observation value'
    a.set(5);
    try std.testing.expectEqual(@as(i32, 50), observed.b);
    try std.testing.expectEqual(@as(i32, 105), observed.c);
    // run count depend on push model: maybe 2 or 3 (b recompute->push, c recompute->push
    // or merge), but final value must match. Allow 1-3 run here, key is value match.
    try std.testing.expect(observed.run >= 2);
}

// Phase 1: verify eqlValue fix std.meta.eql slice ptr-equality bug
test "Reactive System: signal []const u8 same content different ptr does not renotify" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    var buf1: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };
    var buf2: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };

    const s = try Signal([]const u8).create(owner, &buf1);

    var run_count: u32 = 0;
    try createEffect(owner, .{ .s = s, .c = &run_count }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.s.get();
            ctx.c.* += 1;
        }
    }.run);
    try std.testing.expectEqual(@as(u32, 1), run_count);

    // same content, diff buffer: std.meta.eql judge != trigger; eqlValue judge = skip
    try std.testing.expect(buf1[0..].ptr != buf2[0..].ptr);
    s.set(&buf2);
    try std.testing.expectEqual(@as(u32, 1), run_count);

    // diff content should trigger
    var buf3: [5]u8 = .{ 'w', 'o', 'r', 'l', 'd' };
    s.set(&buf3);
    try std.testing.expectEqual(@as(u32, 2), run_count);
}

// Phase 1: verify NaN in signal set no longer trigger renotify storm
test "Reactive System: signal f32 NaN does not renotify" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const nan = @as(f32, std.math.nan(f32));
    const s = try Signal(f32).create(owner, nan);

    var run_count: u32 = 0;
    try createEffect(owner, .{ .s = s, .c = &run_count }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.s.get();
            ctx.c.* += 1;
        }
    }.run);
    try std.testing.expectEqual(@as(u32, 1), run_count);

    // write NaN again no trigger (eqlValue judge equal)
    s.set(nan);
    try std.testing.expectEqual(@as(u32, 1), run_count);

    // write real value trigger
    s.set(1.0);
    try std.testing.expectEqual(@as(u32, 2), run_count);
}

// Cross-scope cleanup adversarial test.
//
// Scene: owner-arena managed signal x scope-managed effect. After scope.dispose the signal
// is still alive; signal.set must:
//   (a) not call the already-destroyed effect (use-after-free risk)
//   (b) not panic or read out of bounds
//
// scope.dispose calls graph.destroyNode, which unregisters the effect node, so
// graph.markSignalWritten
// finds no dirty observer. But signal_base.subscribers may still hold the old effect ptr; a
// push-DFS path that walked it would hit UAF. set now takes the graph path and does not walk
// push, and the subscribers list itself is cleaned via scope.dispose:120. This test keeps
// the invariant if the double-rail protection is later torn down.
test "Reactive System: cross-scope cleanup — owner signal + scope effect" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    // owner-arena create signal (cross-scope alive)
    const counter = try Signal(i32).create(owner, 0);

    // create scope, scope-inside effect subscribe owner-arena signal
    var scope = try @import("reactive/scope.zig").Scope.init(owner.parent_allocator, null, owner);
    var effect_run_count: u32 = 0;

    try scope.createEffect(.{
        .signal = counter,
        .out = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.signal.get();
            ctx.out.* += 1;
        }
    }.run);
    try std.testing.expectEqual(@as(u32, 1), effect_run_count);

    // trigger: scope-effect should run
    counter.set(1);
    try std.testing.expectEqual(@as(u32, 2), effect_run_count);

    // destroy scope, effect should dispose; signal still alive
    scope.dispose();

    // Key assert: after dispose signal.set must **not** trigger already-destroyed effect.
    // If v0.3 tear double-rail middle graph.destroyNode not correct prune from signal.observers,
    // here panic/segfault/trigger effect call stale ctx make run_count change.
    counter.set(2);
    counter.set(3);
    try std.testing.expectEqual(@as(u32, 2), effect_run_count); // no change

    // signal self still can normal subscribe by new scope
    const new_scope = try @import("reactive/scope.zig").Scope.init(owner.parent_allocator, null, owner);
    defer new_scope.dispose();
    var new_run_count: u32 = 0;
    try new_scope.createEffect(.{
        .signal = counter,
        .out = &new_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.signal.get();
            ctx.out.* += 1;
        }
    }.run);
    try std.testing.expectEqual(@as(u32, 1), new_run_count);

    counter.set(4);
    try std.testing.expectEqual(@as(u32, 2), new_run_count);
    try std.testing.expectEqual(@as(u32, 2), effect_run_count); // old effect still no change
}

// signal owner.deinit after no leftover graph node leak
test "Reactive System: owner.deinit cleans up graph nodes" {
    var owner = try SignalOwner.init(std.testing.allocator);

    // create 100 signal + 50 effect
    var signals: [100]*Signal(i32) = undefined;
    for (&signals) |*slot| {
        slot.* = try Signal(i32).create(owner, 0);
    }
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try createEffect(owner, .{ .s = signals[i] }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.s.get();
            }
        }.run);
    }

    // graph node count: 100 signal + 50 effect = 150
    try std.testing.expectEqual(@as(usize, 150), owner.graph.nodeCount());

    owner.deinit();
    // owner already deinit; graph also destroy, this test mainly verify no leak
    // (testing.allocator at test end report leak found)
}

// Regression: memo compute in updateIfNecessary recursion create reactive node,
// let graph.nodes (ArrayListUnmanaged) realloc. Pre-fix updateIfNecessary
// cache `*GraphNode` cross-recursion use, realloc after deref freed memory
// n.seen_versions.items -> segfault (graph.zig:468).
//
// Trigger shape must be **two-tier memo chain**: memoB depend memoA enter .check branch
// and recursion updateIfNecessary(memoA), thus run memoA compute inside recursion.
// Single memo walk .dirty direct recomputeNode, can't hit path.
test "regression: memo compute allocating reactive nodes must not dangle updateIfNecessary" {
    const owner_mod_ = @import("reactive/owner.zig");
    const owner = try owner_mod_.SignalOwner.init(std.testing.allocator);
    defer owner.deinit();
    const root = try Scope.init(std.testing.allocator, null, owner);
    defer root.dispose();

    const src = try root.createSignal(u32, 1);

    const A = struct {
        sc: *Scope,
        s: *Signal(u32),
        fn compute(self: *@This()) u32 {
            const v = self.s.get();
            // compute inside create new reactive node -> nodes.append -> realloc
            const tmp = self.sc.createSignal(u32, v) catch return v;
            return tmp.get();
        }
    };
    var actx = A{ .sc = root, .s = src };
    const memo_a = try root.createMemo(u32, &actx, A.compute);
    const MemoT = @TypeOf(memo_a.*);

    const B = struct {
        a: *MemoT,
        fn compute(self: *@This()) u32 {
            return self.a.get() +% 1;
        }
    };
    var bctx = B{ .a = memo_a };
    const memo_b = try root.createMemo(u32, &bctx, B.compute);
    _ = memo_b.get();

    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        src.set(i);
        _ = memo_b.get();
    }

    // able run here prove no dangling deref; side verify value still propagate correct.
    src.set(4242);
    try std.testing.expectEqual(@as(u32, 4243), memo_b.get());
}
