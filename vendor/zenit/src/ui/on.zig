//! ui.on: event handler combinator, replaces boilerplate "write Bindings struct + cx.bindState +
//! cx.on for one click". Mirrors role of ui.not / ui.map on derived values: Zig has no closures,
//! common event patterns expand at compile-time to typed functions, context is signal pointer
//! itself
//! -- zero allocation.
//!
//! ```zig
//! W.Button(.{ .label = "+1",    .on_click = ui.on.update(count, inc) })
//! W.Button(.{ .label = "Reset", .on_click = ui.on.set(count, 0) })
//! W.Switch(.{ .on_change = ui.on.assign(dark_mode) })      // valued event writes to signal
//! v.box(.{ .on_click = ui.on.toggle(expanded) }, .{ ... })
//! ```
//!
//! Capture runtime values (list row item.id etc) with ui.on.bind(scope, ctx, f): ctx copied
//! by value into scope-owned memory, freed with scope -- shape matches scope.createEffect(ctx, f).
const std = @import("std");
const core = @import("core.zig");
const reactive = @import("reactive.zig");

const HandlerRef = core.HandlerRef;
const Scope = reactive.Scope;
const Signal = reactive.Signal;

fn SignalValue(comptime P: type, comptime who: []const u8) type {
    const info = @typeInfo(P);
    if (info == .pointer and info.pointer.size == .one) {
        const C = info.pointer.child;
        if (@typeInfo(C) == .@"struct" and @hasDecl(C, "Value") and C == Signal(C.Value)) return C.Value;
    }
    @compileError(who ++ ": expected a *Signal(T) (something that can be written), got " ++ @typeName(P));
}

fn erase(sig: anytype) *anyopaque {
    return @ptrCast(sig);
}

/// On click, set signal to compile-time constant `value`. Component's callback is optional or
/// required; `Handler(void)` has no value, value-carrying `Callback(T)` passes one value. Yix event
/// statements generate this by writing callback param names (`onClick`, `onChange(v)`).
pub fn fire(h: anytype, args: anytype) void {
    const H = @TypeOf(h);
    if (@typeInfo(H) == .optional) {
        if (h) |x| fire(x, args);
        return;
    }
    if (H == HandlerRef) {
        if (args.len != 0) @compileError("ui.on.fire: Handler(void) takes no value");
        h.invoke();
    } else {
        if (args.len != 1) @compileError("ui.on.fire: a valued callback takes exactly one value");
        h.call(args[0]);
    }
}

pub fn set(sig: anytype, comptime value: anytype) HandlerRef {
    const T = SignalValue(@TypeOf(sig), "ui.on.set");
    const v: T = value;
    return .{ .context = erase(sig), .callback = struct {
        fn f(ctx: *anyopaque) void {
            const s: *Signal(T) = @ptrCast(@alignCast(ctx));
            s.set(v);
        }
    }.f };
}

/// On click, toggle bool signal.
pub fn toggle(sig: *Signal(bool)) HandlerRef {
    return .{ .context = erase(sig), .callback = struct {
        fn f(ctx: *anyopaque) void {
            const s: *Signal(bool) = @ptrCast(@alignCast(ctx));
            s.set(!s.peek());
        }
    }.f };
}

/// On click, `sig = f(sig)`, `f: fn (T) T`.
pub fn update(sig: anytype, comptime f: anytype) HandlerRef {
    const T = SignalValue(@TypeOf(sig), "ui.on.update");
    return .{ .context = erase(sig), .callback = struct {
        fn run(ctx: *anyopaque) void {
            const s: *Signal(T) = @ptrCast(@alignCast(ctx));
            s.set(f(s.peek()));
        }
    }.run };
}

/// Value event (`Handler(T)`, e.g., on_change) writes directly into signal.
pub fn assign(sig: anytype) reactive.Callback(SignalValue(@TypeOf(sig), "ui.on.assign")) {
    const T = SignalValue(@TypeOf(sig), "ui.on.assign");
    return .{ .ctx = erase(sig), .call_fn = struct {
        fn run(ctx: *anyopaque, value: T) void {
            const s: *Signal(T) = @ptrCast(@alignCast(ctx));
            s.set(value);
        }
    }.run };
}

/// Like `assign`, but event payload type `P` differs from signal value type and implicitly
/// converts: `.on_change = ui.on.assignAs(bool, last)` (`last: *Signal(?bool)`).
pub fn assignAs(comptime P: type, sig: anytype) reactive.Callback(P) {
    const T = SignalValue(@TypeOf(sig), "ui.on.assignAs");
    return .{ .ctx = erase(sig), .call_fn = struct {
        fn run(ctx: *anyopaque, value: P) void {
            const s: *Signal(T) = @ptrCast(@alignCast(ctx));
            s.set(value);
        }
    }.run };
}

/// Call method on state object: `fn (*S) void` -> `Handler(void)`, `fn (*S, T) void` ->
/// `Handler(T)`. Same as `cx.on`, but no cx required.
pub fn call(state: anytype, comptime method: anytype) core.Handler(MethodPayload(@TypeOf(state), method)) {
    const S = @typeInfo(@TypeOf(state)).pointer.child;
    const P = MethodPayload(@TypeOf(state), method);
    if (P == void) return core.Cx.handlerFrom(S, state, method);
    return reactive.Callback(P).from(S, state, method);
}

fn MethodPayload(comptime Ptr: type, comptime method: anytype) type {
    const pinfo = @typeInfo(Ptr);
    if (pinfo != .pointer or pinfo.pointer.size != .one) @compileError("ui.on.call: expected a pointer to a state object, got " ++ @typeName(Ptr));
    const params = @import("zenit_reflection").params(@TypeOf(method));
    if (params.len == 0 or params[0].type != Ptr) @compileError("ui.on.call: the method's first parameter must be " ++ @typeName(Ptr));
    return switch (params.len) {
        1 => void,
        2 => params[1].type.?,
        else => @compileError("ui.on.call: methods take (*State) or (*State, value)"),
    };
}

/// Count of `try` failures in event handlers (read by tests and DevTools).
pub var handler_error_count: usize = 0;
/// Suppress logging when deliberately triggering failure in tests (test runner treats err logs as
/// failures).
pub var suppress_error_log = false;

/// Error reporting from event handlers (called on `try` failure in Yix handlers): tally and log, UI
/// continues.
pub fn reportError(site: []const u8, err: anyerror) void {
    handler_error_count += 1;
    if (suppress_error_log) return;
    std.log.scoped(.zenit_event).err("{s} handler failed: {s}", .{ site, @errorName(err) });
}

/// Handler with value type pending (generated for component events by Yix): ctx copies by value
/// into scope-owned memory; receiving prop is `Handler(void)` or `Handler(T)`, instantiated at prop
/// conversion time (see reactive.props). f is `fn (ctx) void` (ignores event value) or `fn (ctx,
/// value: anytype) void` (capturing |v|).
pub fn bindAny(scope: *Scope, ctx: anytype, comptime f: anytype) !AnyHandler(@TypeOf(ctx), f) {
    const Ctx = @TypeOf(ctx);
    const p = try scope.allocator.create(Ctx);
    p.* = ctx;
    try scope.adoptResource(@ptrCast(p), struct {
        fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
            allocator.destroy(@as(*Ctx, @ptrCast(@alignCast(raw))));
        }
    }.destroy);
    return .{ .ctx = p };
}

pub fn AnyHandler(comptime Ctx: type, comptime f: anytype) type {
    const takes_value = @import("zenit_reflection").params(@TypeOf(f)).len == 2;
    return struct {
        ctx: *Ctx,
        pub const zenit_any_handler = true;

        /// Instantiate into the receiver's handler type.
        pub fn as(self: @This(), comptime T: type) core.Handler(T) {
            if (T == void) {
                if (takes_value) @compileError("ui.on.bindAny: |value| capture on an event that carries no value");
                return .{ .context = @ptrCast(self.ctx), .callback = struct {
                    fn run(raw: *anyopaque) void {
                        f(@as(*Ctx, @ptrCast(@alignCast(raw))).*);
                    }
                }.run };
            }
            return .{ .ctx = @ptrCast(self.ctx), .call_fn = struct {
                fn invoke(raw: *anyopaque, value: T) void {
                    const c = @as(*Ctx, @ptrCast(@alignCast(raw))).*;
                    if (takes_value) f(c, value) else f(c);
                }
            }.invoke };
        }
    };
}

/// Click handler that captures runtime values: `ctx` is copied by value into scope-owned memory
/// (freed with scope),
/// calls `f(ctx)` on click. `f` receives either `Ctx` value or `*Ctx` (use the pointer when the
/// handler needs to mutate ctx).
///
/// ```zig
/// .on_click = try ui.on.bind(scope, .{ .todos = todos, .id = item.id }, removeTodo),
/// ```
pub fn bind(scope: *Scope, ctx: anytype, comptime f: anytype) !HandlerRef {
    const Ctx = @TypeOf(ctx);
    const by_ptr = comptime blk: {
        const params = @import("zenit_reflection").params(@TypeOf(f));
        if (params.len != 1) @compileError("ui.on.bind: handler takes exactly one parameter (the ctx)");
        break :blk params[0].type == *Ctx;
    };
    const p = try scope.allocator.create(Ctx);
    p.* = ctx;
    try scope.adoptResource(@ptrCast(p), struct {
        fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
            allocator.destroy(@as(*Ctx, @ptrCast(@alignCast(raw))));
        }
    }.destroy);
    return .{ .context = @ptrCast(p), .callback = struct {
        fn run(raw: *anyopaque) void {
            const c: *Ctx = @ptrCast(@alignCast(raw));
            if (by_ptr) f(c) else f(c.*);
        }
    }.run };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testScope() !struct { cx: *core.Cx, scope: *Scope } {
    const cx = try core.Cx.init(testing.allocator, std.testing.io);
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    return .{ .cx = cx, .scope = scope };
}

test "act.set / toggle / update / assign 写 signal，零分配" {
    const env = try testScope();
    defer env.cx.deinit();
    defer env.scope.dispose();
    const n = try env.scope.createSignal(u32, 5);
    const b = try env.scope.createSignal(bool, false);

    const res_before = env.scope.resources.items.len;
    const h_set = set(n, 0);
    const h_toggle = toggle(b);
    const h_inc = update(n, struct {
        fn inc(x: u32) u32 {
            return x + 1;
        }
    }.inc);
    const h_assign = assign(n);
    try testing.expectEqual(res_before, env.scope.resources.items.len);

    h_set.callback(h_set.context);
    try testing.expectEqual(@as(u32, 0), n.peek());
    h_inc.callback(h_inc.context);
    h_inc.callback(h_inc.context);
    try testing.expectEqual(@as(u32, 2), n.peek());
    h_assign.call(42);
    try testing.expectEqual(@as(u32, 42), n.peek());
    h_toggle.callback(h_toggle.context);
    try testing.expect(b.peek());
    h_toggle.callback(h_toggle.context);
    try testing.expect(!b.peek());
}

test "act.call 推断 payload，act.bind 捕获运行期值并随 scope 释放" {
    const env = try testScope();
    defer env.cx.deinit();
    defer env.scope.dispose();

    const State = struct {
        hits: u32 = 0,
        last: u32 = 0,
        fn hit(s: *@This()) void {
            s.hits += 1;
        }
        fn got(s: *@This(), v: u32) void {
            s.last = v;
        }
    };
    var st = State{};
    const h = call(&st, State.hit);
    h.callback(h.context);
    const cb = call(&st, State.got);
    cb.call(7);
    try testing.expectEqual(@as(u32, 1), st.hits);
    try testing.expectEqual(@as(u32, 7), st.last);

    const n = try env.scope.createSignal(u32, 0);
    var runtime_id: u32 = 9;
    _ = &runtime_id;
    const hb = try bind(env.scope, .{ .sig = n, .id = runtime_id }, struct {
        fn f(c: anytype) void {
            c.sig.set(c.id);
        }
    }.f);
    hb.callback(hb.context);
    try testing.expectEqual(@as(u32, 9), n.peek());

    const Counter = struct { k: u32 };
    const hp = try bind(env.scope, Counter{ .k = 0 }, struct {
        fn f(c: *Counter) void {
            c.k += 1;
        }
    }.f);
    hp.callback(hp.context);
    hp.callback(hp.context);
    const stored: *Counter = @ptrCast(@alignCast(hp.context));
    try testing.expectEqual(@as(u32, 2), stored.k);
}
