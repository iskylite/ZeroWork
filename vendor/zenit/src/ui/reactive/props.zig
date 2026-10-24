//! Component props normalization (docs/SIGNAL_API_DESIGN.md section 4.6).
//!
//! Component entry X(props: anytype) calls coerce(XProps, props), converts caller's
//! anonymous struct literal field-by-field at comptime to canonical Props struct:
//!
//! ```zig
//! W.Checkbox(.{ .label = "Agree", .checked = agree, .disabled = ui.not(loading) })
//! ```
//!
//! Resolution order (target F, caller value type X):
//! 1. X == F pass-through;
//! 2. X == T static value (before any reactivity check, so Source(*Node) passing *Node
//!    never mismatches);
//! 3. Reactive sources only via explicit marker (zenit_reactive), no duck typing;
//! 4. Anonymous struct literal recursively constructs by field;
//! 5. Rest delegated to @as for normal coercion.
//! All custom errors start with <Props>.<field>:
const std = @import("std");
const source = @import("source.zig");
const Source = source.Source;
const Model = source.Model;
const Split = source.Split;

/// Convert call-site props literal to canonical struct `P`. Also accepts passing `P` directly.
pub fn coerce(comptime P: type, args: anytype) P {
    comptime assertPropsShape(P);
    const A = @TypeOf(args);
    if (A == P) return args;
    if (@typeInfo(A) != .@"struct") @compileError(@typeName(P) ++ ": props must be a struct literal, got " ++ @typeName(A));

    const a_fields = @import("zenit_reflection").fields(A);
    const p_fields = @import("zenit_reflection").fields(P);
    inline for (a_fields) |af| {
        if (!@hasField(P, af.name)) @compileError(shortName(P) ++ ": unknown prop '" ++ af.name ++ "'");
    }

    var out: P = undefined;
    inline for (p_fields) |pf| {
        if (@hasField(A, pf.name)) {
            @field(out, pf.name) = coerceField(P, pf.type, pf.name, @field(args, pf.name));
        } else if (pf.defaultValue()) |d| {
            @field(out, pf.name) = d;
        } else {
            @compileError(shortName(P) ++ ": missing required prop '" ++ pf.name ++ "'");
        }
    }
    // Controlled value receives read-only source + change callback (on_<x>_change or
    // on_change for sole Model): synthesizes split(read-only source, callback)--user action
    // calls parent; parent decides accept/reject/override based on source change. Same
    // semantics as split (buffered components like Input restore on reject, correct in-place
    // on override). Callback cleared; no re-invoke after mount. No callback: stay controlled
    // (display only, no write).
    inline for (p_fields) |pf| {
        if (comptime isModelType(pf.type) and @hasField(A, pf.name)) {
            const T = pf.type.Value;
            if (comptime isReadOnlySource(@FieldType(A, pf.name), T)) {
                if (comptime changeHandlerField(P, A, pf.name, T)) |hn| {
                    const h: ?Callback(T) = @field(out, hn);
                    if (h) |cb| {
                        @field(out, pf.name) = .{ .split = .{ .read = source.toSource(@field(args, pf.name)), .write = cb } };
                        @field(out, hn) = null;
                    }
                }
            }
        }
    }
    return out;
}

const Callback = source.Callback;

fn isReadOnlySource(comptime X: type, comptime T: type) bool {
    if (X == Source(T)) return true;
    const kind = source.reactiveKindOf(X) orelse return false;
    return kind != .signal and source.ValueOf(X) == T;
}

/// Change callback for Model field `name`: on_<name>_change, else on_change if P has
/// sole Model field; type must be `?Callback(T)` (clearable); call site must pass it.
fn changeHandlerField(comptime P: type, comptime A: type, comptime name: []const u8, comptime T: type) ?[]const u8 {
    const specific = "on_" ++ name ++ "_change";
    if (@hasField(P, specific) and @hasField(A, specific) and @FieldType(P, specific) == ?Callback(T)) return specific;
    var models: usize = 0;
    for (@import("zenit_reflection").fields(P)) |f| {
        if (isModelType(f.type)) models += 1;
    }
    if (models == 1 and @hasField(P, "on_change") and @hasField(A, "on_change") and @FieldType(P, "on_change") == ?Callback(T)) return "on_change";
    return null;
}

fn coerceField(comptime P: type, comptime F: type, comptime name: []const u8, v: anytype) F {
    if (comptime isSourceType(F)) return toSourceProp(P, F.Value, name, v);
    if (comptime isModelType(F)) return toModelProp(P, F.Value, name, v);
    return coerceValue(P, F, name, v);
}

fn toSourceProp(comptime P: type, comptime T: type, comptime name: []const u8, v: anytype) Source(T) {
    const X = @TypeOf(v);
    if (X == Source(T)) return v;
    if (X == T) return .{ .value = v };
    // Source of different value type (e.g. Source(*const [4:0]u8) to Source([]const u8)):
    // error on type mismatch, not obscure @as error.
    if (comptime isContainer(X) and @hasDecl(X, "zenit_source")) mismatch(P, name, T, X, X.Value);
    if (comptime source.reactiveKindOf(X)) |kind| {
        const V = source.ValueOf(X);
        if (V != T) mismatch(P, name, T, X, V);
        return switch (kind) {
            .signal => .{ .signal = v },
            .memo => .{ .memo = v },
            .derived => .{ .derived = v },
        };
    }
    if (comptime isConstReactivePtr(X)) {
        @compileError(prefix(P, name) ++ "pass a mutable pointer (*Signal / *Memo), got " ++ @typeName(X) ++ "; reading a signal registers a dependency and needs *Self");
    }
    if (comptime isContainer(X) and @hasDecl(X, "zenit_split")) {
        @compileError(prefix(P, name) ++ "ui.split is only for controlled-value props (Model); this prop is read-only (Source(" ++ @typeName(T) ++ "))");
    }
    return .{ .value = coerceValue(P, T, name, v) };
}

fn toModelProp(comptime P: type, comptime T: type, comptime name: []const u8, v: anytype) Model(T) {
    const X = @TypeOf(v);
    if (X == Model(T)) return v;
    if (X == T) return .{ .local = v };
    if (X == Split(T)) return .{ .split = v };
    if (comptime isContainer(X) and @hasDecl(X, "zenit_split")) mismatch(P, name, T, X, X.Value);
    // Read-only source (derived, list row field, component param): controlled (read-only)--
    // component displays; user action goes to onChange; no write-back.
    if (X == Source(T)) return .{ .controlled = v };
    if (comptime isContainer(X) and @hasDecl(X, "zenit_source")) mismatch(P, name, T, X, X.Value);
    if (comptime source.reactiveKindOf(X)) |kind| {
        const V = source.ValueOf(X);
        if (V != T) mismatch(P, name, T, X, V);
        return switch (kind) {
            .signal => .{ .bound = v },
            .memo => .{ .controlled = .{ .memo = v } },
            .derived => .{ .controlled = .{ .derived = v } },
        };
    }
    if (comptime isConstReactivePtr(X)) {
        @compileError(prefix(P, name) ++ "controlled-value props (Model) need a mutable *Signal(" ++ @typeName(T) ++ "), got " ++ @typeName(X));
    }
    return .{ .local = coerceValue(P, T, name, v) };
}

/// Anon struct literal becomes distinct type post-anytype; @as(Struct, anon) fails;
/// recursively construct per target: struct field-by-field; tagged union extract sole
/// field (`.{ .px = 10 }`); optional unwrap.
fn coerceValue(comptime P: type, comptime T: type, comptime name: []const u8, v: anytype) T {
    const X = @TypeOf(v);
    if (X == T) return v;
    // Handlers with deferred value type (ui.on.bindAny, Yix component events):
    // instantiate by callback type.
    if (comptime @typeInfo(X) == .@"struct" and @hasDecl(X, "zenit_any_handler")) {
        const H = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
        if (comptime @hasField(H, "callback") and @hasField(H, "context")) return v.as(void);
        if (comptime @hasDecl(H, "Value") and @hasField(H, "call_fn")) return v.as(H.Value);
        @compileError(prefix(P, name) ++ "an event handler was passed to " ++ @typeName(T) ++ ", which is not a Handler");
    }
    if (comptime isAnonStructLiteral(X)) {
        switch (@typeInfo(T)) {
            .optional => |o| return coerceValue(P, o.child, name, v),
            .@"union" => |u| {
                const xf = @import("zenit_reflection").fields(X);
                if (u.tag_type == null or xf.len != 1) {
                    @compileError(prefix(P, name) ++ "a " ++ @typeName(T) ++ " literal must set exactly one field");
                }
                if (!@hasField(T, xf[0].name)) @compileError(prefix(P, name) ++ @typeName(T) ++ " has no field '" ++ xf[0].name ++ "'");
                return @unionInit(T, xf[0].name, coerceValue(P, @FieldType(T, xf[0].name), name ++ "." ++ xf[0].name, @field(v, xf[0].name)));
            },
            else => {},
        }
    }
    if (@typeInfo(T) == .@"struct" and comptime isAnonStructLiteral(X)) {
        var out: T = undefined;
        const t_fields = @import("zenit_reflection").fields(T);
        inline for (@import("zenit_reflection").fields(X)) |xf| {
            if (!@hasField(T, xf.name)) @compileError(prefix(P, name) ++ @typeName(T) ++ " has no field '" ++ xf.name ++ "'");
        }
        inline for (t_fields) |tf| {
            if (@hasField(X, tf.name)) {
                @field(out, tf.name) = coerceValue(P, tf.type, name ++ "." ++ tf.name, @field(v, tf.name));
            } else if (tf.defaultValue()) |d| {
                @field(out, tf.name) = d;
            } else {
                @compileError(prefix(P, name) ++ "missing field '" ++ tf.name ++ "' of " ++ @typeName(T));
            }
        }
        return out;
    }
    return @as(T, v);
}

fn isAnonStructLiteral(comptime X: type) bool {
    return switch (@typeInfo(X)) {
        // Empty literal `.{}` is unit type.
        .@"struct" => |st| st.decl_names.len == 0 and (!st.is_tuple or st.field_names.len == 0),
        else => false,
    };
}

fn mismatch(comptime P: type, comptime name: []const u8, comptime T: type, comptime X: type, comptime V: type) noreturn {
    if (@typeInfo(T) == .optional and @typeInfo(T).optional.child == V) {
        @compileError(prefix(P, name) ++ "expected a source of " ++ @typeName(T) ++ ", got " ++ @typeName(X) ++
            " (value type " ++ @typeName(V) ++ "); the prop is optional, use a Signal(" ++ @typeName(T) ++ ") or ui.map to wrap it");
    }
    @compileError(prefix(P, name) ++ "expected a source of " ++ @typeName(T) ++ ", got " ++ @typeName(X) ++ " (value type " ++ @typeName(V) ++ ")");
}

/// Struct constraint (§4.6): no `?Source(T)` / `?Model(T)`; use `Source(?T)` / `Model(?T)`.
fn assertPropsShape(comptime P: type) void {
    if (@typeInfo(P) != .@"struct") @compileError("props.coerce: " ++ @typeName(P) ++ " is not a struct");
    for (@import("zenit_reflection").fields(P)) |f| {
        if (@typeInfo(f.type) == .optional) {
            const C = @typeInfo(f.type).optional.child;
            if (isSourceType(C) or isModelType(C)) {
                @compileError(shortName(P) ++ "." ++ f.name ++ ": use Source(?T) / Model(?T) instead of an optional Source / Model");
            }
        }
    }
}

fn isSourceType(comptime F: type) bool {
    return isContainer(F) and @hasDecl(F, "zenit_source");
}

fn isModelType(comptime F: type) bool {
    return isContainer(F) and @hasDecl(F, "zenit_model");
}

fn isContainer(comptime X: type) bool {
    return switch (@typeInfo(X)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

fn isConstReactivePtr(comptime X: type) bool {
    return switch (@typeInfo(X)) {
        .pointer => |p| p.size == .one and p.attrs.@"const" and isContainer(p.child) and @hasDecl(p.child, "zenit_reactive"),
        else => false,
    };
}

fn shortName(comptime P: type) []const u8 {
    const full = @typeName(P);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

fn prefix(comptime P: type, comptime name: []const u8) []const u8 {
    return shortName(P) ++ "." ++ name ++ ": ";
}

// ---------------------------------------------------------------------------
// Tests (compile-time error cases in tests/compile_errors/, run via
// scripts/check_compile_errors.sh)
// ---------------------------------------------------------------------------

const testing = std.testing;
const SignalOwner = @import("owner.zig").SignalOwner;
const Scope = @import("scope.zig").Scope;
const Signal = @import("signal.zig").Signal;

const Mode = enum { compact, comfortable };
const Point = struct { x: f32 = 0, y: f32 = 0 };
const DemoProps = struct {
    id: u32, // Required.
    label: Source([]const u8) = .{ .value = "" },
    disabled: Source(bool) = .{ .value = false },
    mode: Source(Mode) = .{ .value = .compact },
    offset: Source(Point) = .{ .value = .{} },
    width: Source(f32) = .{ .value = 0 },
    selection: Model(?u32) = .{ .local = null },
    checked: Model(bool) = .{ .local = false },
    node: Source(?*u8) = .{ .value = null },
    on_change: ?source.Callback(bool) = null,
};

test "coerce: 受控值收到只读源 + 变更回调 -> split（回调字段清空）；没有回调 -> controlled；可写 signal 仍是 bound" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();
    const P = struct {
        checked: Model(bool) = .{ .local = false },
        on_change: ?Callback(bool) = null,
    };
    const Q = struct {
        open: Model(bool) = .{ .local = false },
        value: Model(u32) = .{ .local = 0 },
        on_open_change: ?Callback(bool) = null,
        on_change: ?Callback(u32) = null,
    };
    const Sink = struct {
        fn f(_: *@This(), _: bool) void {}
    };
    var sink = Sink{};
    const cb = Callback(bool).from(Sink, &sink, Sink.f);
    const sig = try scope.createSignal(bool, true);
    const m = try scope.createMemo(bool, .{ .s = sig }, struct {
        fn f(c: anytype) bool {
            return c.s.get();
        }
    }.f);
    const a = coerce(P, .{ .checked = m, .on_change = cb });
    try testing.expect(a.checked == .split and a.on_change == null);
    try testing.expect(coerce(P, .{ .checked = m }).checked == .controlled);
    const via_source: Source(bool) = .{ .memo = m };
    try testing.expect(coerce(P, .{ .checked = via_source, .on_change = cb }).checked == .split);
    const b = coerce(P, .{ .checked = sig, .on_change = cb });
    try testing.expect(b.checked == .bound and b.on_change != null);
    // Multiple controlled values: only recognize on_<x>_change, not on_change for open.
    const q = coerce(Q, .{ .open = m, .on_open_change = cb });
    try testing.expect(q.open == .split and q.on_open_change == null);
}

test "coerce: literals, signals, memos, derived values and defaults" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const agree = try scope.createSignal(bool, true);
    const loading = try scope.createSignal(bool, false);
    const sel = try scope.createSignal(?u32, 3);

    const p = coerce(DemoProps, .{
        .id = 1,
        .label = "I agree",
        .checked = agree,
        .disabled = source.not(loading),
        .mode = .comfortable,
        .offset = .{ .x = 4 },
        .width = 12,
        .selection = sel,
    });
    try testing.expectEqualStrings("I agree", p.label.get());
    try testing.expect(p.checked == .bound and p.checked.bound == agree);
    try testing.expect(p.disabled == .derived and p.disabled.get());
    try testing.expectEqual(Mode.comfortable, p.mode.get());
    try testing.expectEqual(@as(f32, 4), p.offset.get().x);
    try testing.expectEqual(@as(f32, 0), p.offset.get().y);
    try testing.expectEqual(@as(f32, 12), p.width.get());
    try testing.expect(p.selection == .bound);
    try testing.expect(p.on_change == null);

    const q = coerce(DemoProps, .{ .id = 2, .checked = true, .selection = null });
    try testing.expect(q.checked == .local and q.checked.local);
    try testing.expect(q.selection == .local and q.selection.local == null);
    try testing.expectEqualStrings("", q.label.get());
}

test "coerce: nested literals into optional structs and tagged unions" {
    const Size = union(enum) { px: f32, grow: struct { factor: f32 = 1 } };
    const Inner = struct { width: ?Size = null, pad: f32 = 0 };
    const P = struct { style: ?Inner = null, size: Size = .{ .px = 0 } };
    const p = coerce(P, .{ .style = .{ .width = .{ .px = 12 }, .pad = 3 }, .size = .{ .grow = .{} } });
    try testing.expectEqual(@as(f32, 12), p.style.?.width.?.px);
    try testing.expectEqual(@as(f32, 3), p.style.?.pad);
    try testing.expectEqual(@as(f32, 1), p.size.grow.factor);
}

test "coerce: a value whose type equals T is static even if T is a pointer" {
    var byte: u8 = 0;
    const p = coerce(DemoProps, .{ .id = 3, .node = &byte });
    try testing.expect(p.node == .value and p.node.value == &byte);
}

test "coerce: canonical struct passes through, decl literals work" {
    const p = coerce(DemoProps, DemoProps{ .id = 4, .label = .of("x"), .checked = .of(true) });
    try testing.expectEqualStrings("x", p.label.get());
    try testing.expect(p.checked.local);
}
