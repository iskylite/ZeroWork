//! `ui.view`: declarative view tree -- pure Zig version of Solid-style JSX (layer 1: zero
//! toolchain, ZLS / zig fmt work as-is).
//!
//! ```zig
//! const v = ui.view;
//!
//! fn mountUI(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
//!     const count = try scope.createSignal(u32, 0);
//!     return v.render(scope, cx, v.col(.{ .style = S.root }, .{
//!         v.text(.{ .style = S.title }, "Reactive Counter"),
//!         v.text(.{ .style = S.count }, v.fmt("count = {d}", .{count})),
//!         v.row(.{ .style = S.buttons }, .{
//!             W.Button(.{ .label = "+1", .on_click = ui.on.update(count, inc) }),
//!             W.Button(.{ .label = "Reset", .on_click = ui.on.set(count, 0) }),
//!         }),
//!         v.show(ui.not(loading), .{ v.text(.{}, "ready") }).fallback(.{ W.Spinner(.{}) }),
//!         v.each(todos, .id, TodoRow),
//!     }));
//! }
//! ```
//!
//! Model (docs/SIGNAL_API_DESIGN.md non-goals): elements are values, not nodes; `render` wires
//! them once into the retained node tree, then only fine-grained effects update -- no VDOM.
//!
//! Children can be: elements from this module, component builders (`W.Button(...)`), `*Node` /
//! `?*Node`, `null`, string literals (default-style text), or nested tuples (unpacked in place).
//!
//! Styling (`.style`):
//!   - `S.card`                         named style fn `fn (*const ThemeTokens) BoxStyle`,
//!                                      auto-replays on theme switch;
//!   - `.{ .gap = 8 }`                  literal;
//!   - `.{ S.card, S.elevated, .{ .gap = 4 } }`  merge left to right (later overrides earlier);
//!   - `v.when(selected, S.selected)`   stack if condition true (bool or any bool reactive
//!                                      source);
//!   - `v.styleBy(size, S.sized)`       style = f(source value, tokens);
//!   - `v.hover(S.rowHover)`            stack on hover.
//! Compile-time-known styles without reactive parts use zero-cost on_theme replay (as
//! `ui.boxStyled`); otherwise an effect tracks condition + theme, and a withdrawn condition
//! resets affected fields to defaults (not to the last value).
//!
//! Lifecycle contract:
//!   - A built element attaches to its parent (or slot) immediately; failure cleanup belongs to
//!     the txn owner -- `render` root, control-flow region, For row. Cleanup order: hook
//!     invalidation -> dispose scope (cleanup still sees live nodes) -> node free.
//!   - `render` opens a child scope under the caller scope; all tree effects belong to it.
//!   - A `*Node` passed as child transfers ownership: on attach failure the framework frees it
//!     in the order above, the caller doesn't.
//!   - `show` / `match` / `each` store child descriptions by value and remount on condition
//!     change: slices borrowed in descriptions (strings, arrays) must outlive the region --
//!     literals and scope-owned data do, stack-built strings don't.
const std = @import("std");
const core = @import("core.zig");
const types = @import("core/types.zig");
const reactive = @import("reactive.zig");
const source_kinds = @import("reactive/source.zig");
const control_flow = @import("control_flow.zig");
const hooks = @import("hooks.zig");
const events = @import("events.zig");
const bind_mod = @import("bind.zig");
const theme_mod = @import("theme.zig");
const render_engine = @import("core/render_engine/mod.zig");

const view_parts = @import("view_parts.zig");
pub const ViewParts = view_parts.ViewParts;
pub const SlotPoint = view_parts.SlotPoint;

const Node = core.Node;
const Cx = core.Cx;
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const BoxStyle = core.BoxStyle;
const TextStyle = core.TextStyle;
const Color = core.Color;
const Direction = core.Direction;
const ThemeTokens = theme_mod.ThemeTokens;
pub const Sink = control_flow.Sink;
const SvgAsset = @import("svg_assets.zig").Asset;
/// public API layer (icon default resource size logic here). ui.zig also import this file, Zig
/// allows
/// file-level cycle.
const ui_api = @import("ui.zig");
/// object-style styles (`ui.css` / `ui.cva`): parse + token lookup here, view layer just
/// integrates.
const css_mod = @import("css.zig");
const ViewThemeReplay = @import("core/node.zig").ViewThemeReplay;
const recipe_entry = @import("recipe.zig");
const node_refs = @import("overlay_layer_refs.zig");
const style_decl = @import("style_decl.zig");
const BoxDecl = style_decl.StyleDecl(BoxStyle);

// Entry

/// mount single-node element as node tree, return root. Effects on tree belong to new child scope
/// under caller scope; mount fail entire tree reclaim per unload order, error pass-through.
pub fn render(scope: *Scope, cx: *Cx, element: anytype) !*Node {
    comptime requireSingle(@TypeOf(element), "ui.view.render");
    const rs = try scope.childScope();
    var root: ?*Node = null;
    var stray: ?*Node = null;
    emit(rs, cx, Sink.capture(&root, &stray), element) catch |err| {
        control_flow.discardCaptured(cx, rs, root, stray);
        return err;
    };
    return root orelse {
        control_flow.discardCaptured(cx, rs, null, stray);
        return error.ViewEmptyRoot;
    };
}

/// append children to existing node (mix with imperative code, gradual migrate). fail this round's
/// nodes all reclaim, parent's existing children untouched.
pub fn mount(scope: *Scope, cx: *Cx, parent: *Node, children: anytype) !void {
    const ms = try scope.childScope();
    const before_len = parent.children.items.len;
    var stray: ?*Node = null;
    emit(ms, cx, .{ .parent = parent, .stray = &stray }, children) catch |err| {
        for (parent.children.items[before_len..]) |n| hooks.invalidateSubtreeHookState(n);
        if (stray) |n| hooks.invalidateSubtreeHookState(n);
        ms.dispose();
        while (parent.children.items.len > before_len) {
            const n = parent.children.items[parent.children.items.len - 1];
            cx.detachChild(parent, n);
            cx.freeNode(n);
        }
        if (stray) |n| {
            cx.destroyDetached(n);
        }
        return err;
    };
}

/// append single-node element to existing node end, return it: element scope bound to root node;
/// component freeNode'ing it destroys scope. component internal "clear then rebuild" loop (option
/// row,
/// calendar cell); repeated calls don't accumulate scope; `mount` scope only releases with caller
/// scope.
pub fn append(scope: *Scope, cx: *Cx, parent: *Node, element: anytype) !*Node {
    comptime requireSingle(@TypeOf(element), "ui.view.append");
    const rs = try scope.childScope();
    var root: ?*Node = null;
    var stray: ?*Node = null;
    emit(rs, cx, Sink.capture(&root, &stray), element) catch |err| {
        control_flow.discardCaptured(cx, rs, root, stray);
        return err;
    };
    const n = root orelse {
        control_flow.discardCaptured(cx, rs, null, stray);
        return error.ViewEmptyRoot;
    };
    Cx.bindScopeToNode(rs, n) catch |err| {
        control_flow.discardCaptured(cx, rs, n, null);
        return err;
    };
    parent.appendChild(cx.allocator, n) catch |err| {
        control_flow.discardCaptured(cx, rs, n, null);
        return err;
    };
    return n;
}

/// emit any children into sink. element classification entirely compile-time.
pub fn emit(scope: *Scope, cx: *Cx, sink: Sink, child: anytype) anyerror!void {
    const T = @TypeOf(child);
    if (T == @TypeOf(null) or T == void) return;
    if (T == *Node) return sink.insert(cx, child);
    // optional element = static condition (mount-time decide present, no region/effect build): `if
    // (cond) elem else null`
    if (comptime @typeInfo(T) == .optional) {
        if (child) |c| try emit(scope, cx, sink, c);
        return;
    }
    if (comptime isStringLike(T)) return emit(scope, cx, sink, text(.{}, child));
    if (comptime isViewElement(T)) return child.viewEmit(scope, cx, sink);
    if (comptime isTuple(T)) {
        inline for (@import("zenit_reflection").fields(T)) |f| try emit(scope, cx, sink, @field(child, f.name));
        return;
    }
    if (comptime @typeInfo(T) == .array) {
        for (child) |c| try emit(scope, cx, sink, c);
        return;
    }
    if (comptime isComponent(T)) {
        _ = try mountComponent(scope, cx, sink, child, {}, {});
        return;
    }
    @compileError("ui.view: unsupported child type " ++ @typeName(T) ++
        ". Expected a ui.view element, a component builder (has `mount`), *Node, ?*Node, null, a string, or a tuple / array of those");
}

/// emit single-node child, return its actual mounted node (sink position or capture slot). null if
/// component root null (portal went).
fn emitSingle(scope: *Scope, cx: *Cx, sink: Sink, child: anytype) !?*Node {
    if (sink.parent) |p| {
        const before_len = p.children.items.len;
        try emit(scope, cx, sink, child);
        if (p.children.items.len == before_len) return null;
        if (sink.before) |b| {
            const i = std.mem.indexOfScalar(*Node, p.children.items, b).?;
            return p.children.items[i - 1];
        }
        return p.children.items[p.children.items.len - 1];
    }
    try emit(scope, cx, sink, child);
    return sink.root.?.*;
}

// Elements: containers and text

const box_props = [_][]const u8{ "window_region", "style", "test_id", "a11y", "on_click", "visible", "focusable", "focus_ring", "hit_test", "on_focus", "on_blur", "on_hover", "on_leave", "tag", "on_event", "event_context", "state", "on_key_down", "on_key_up", "on_pointer_down", "on_pointer_move", "on_pointer_up", "on_scroll" };
const text_props = [_][]const u8{ "style", "box", "test_id", "a11y", "on_click", "visible", "hit_test" };

/// container (direction from style, default column).
pub fn box(props: anytype, children: anytype) Box(@TypeOf(props), @TypeOf(children), null) {
    return .{ .props = props, .children = children };
}

/// row container: direction always row (style direction overridden, on theme replay too).
pub fn row(props: anytype, children: anytype) Box(@TypeOf(props), @TypeOf(children), .row) {
    return .{ .props = props, .children = children };
}

/// column container: direction always column.
pub fn col(props: anytype, children: anytype) Box(@TypeOf(props), @TypeOf(children), .column) {
    return .{ .props = props, .children = children };
}

pub fn Box(comptime Props: type, comptime Children: type, comptime dir: ?Direction) type {
    comptime checkProps(Props, &box_props, "ui.view.box / row / col");
    return struct {
        props: Props,
        children: Children,

        pub const zenit_view_element = true;
        pub const view_single = true;
        const Plan = BoxPlan(Props, dir, false);

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const node = try core.box(cx, Plan.initial(self.props, cx.tokens), .{});
            try sink.insert(cx, node);
            applyAttrs(node, self.props);
            try bindTypedEvents(scope, node, self.props);
            try bindVisible(scope, node, self.props);
            try bindA11y(scope, node, self.props);
            try Plan.attach(self.props, scope, cx, node);
            try bindFocus(scope, cx, node, self.props);
            try emit(scope, cx, sink.child(node), self.children);
        }
    };
}

const grid_props = box_props ++ [_][]const u8{ "columns", "rows", "column_gap", "row_gap" };

/// CSS grid layout container (differs from `W.Grid` virtualized data grid):
/// `v.grid(.{ .columns = &.{ .{ .px = 70 }, .{ .fr = 1 } }, .rows = &.{.{ .px = 52 }}, .column_gap
/// = 8, .style = S.panel }, .{ ... })`.
/// track definitions written at mount, not replay with style; children use `.grid_placement` in
/// style to
/// specify row/col span. rest props same as `v.box`.
pub fn grid(props: anytype, children: anytype) GridBox(@TypeOf(props), @TypeOf(children)) {
    return .{ .props = props, .children = children };
}

pub fn GridBox(comptime Props: type, comptime Children: type) type {
    comptime checkProps(Props, &grid_props, "ui.view.grid");
    return struct {
        props: Props,
        children: Children,

        pub const zenit_view_element = true;
        pub const view_single = true;
        const Plan = BoxPlan(Props, null, false);

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const node = try core.box(cx, Plan.initial(self.props, cx.tokens), .{});
            try sink.insert(cx, node);
            const max = types.GridConfig.MAX_TRACKS;
            if (@hasField(Props, "columns") and self.props.columns.len > max) return error.ViewGridTooManyTracks;
            if (@hasField(Props, "rows") and self.props.rows.len > max) return error.ViewGridTooManyTracks;
            // GridConfig reclaimed when node freed (StyleExt.grid)
            const gc = try cx.allocator.create(types.GridConfig);
            gc.* = .{
                .column_gap = if (@hasField(Props, "column_gap")) self.props.column_gap else 0,
                .row_gap = if (@hasField(Props, "row_gap")) self.props.row_gap else 0,
            };
            if (@hasField(Props, "columns")) gc.column_count = copyTracks(&gc.columns, self.props.columns);
            if (@hasField(Props, "rows")) gc.row_count = copyTracks(&gc.rows, self.props.rows);
            const ext = node.style.ensureExtFallible(cx.allocator) catch |err| {
                cx.allocator.destroy(gc);
                return err;
            };
            ext.grid = gc;
            node.markLayoutDirty();
            applyAttrs(node, self.props);
            try bindTypedEvents(scope, node, self.props);
            try bindVisible(scope, node, self.props);
            try bindA11y(scope, node, self.props);
            try Plan.attach(self.props, scope, cx, node);
            try emit(scope, cx, sink.child(node), self.children);
        }

        fn copyTracks(dst: *[types.GridConfig.MAX_TRACKS]types.GridTrackSize, src: []const types.GridTrackSize) u8 {
            for (src, 0..) |t, i| dst[i] = t;
            return @intCast(src.len);
        }
    };
}

/// text. content can be string, `v.fmt(...)`, or any `[]const u8` reactive source
/// (`*Signal([]const u8)` / Memo / derived value / `Source`). without `.style` use theme default
/// text style (fg_primary / font_size.lg), replay on theme.
pub fn text(props: anytype, content: anytype) Text(@TypeOf(props), @TypeOf(content)) {
    return .{ .props = props, .content = content };
}

/// `.box`: text node own box style (bg, padding, size, corner...), syntax same as box `.style`.
/// for "node self carries text" component (pill badge, tagged label), no need extra box layer.
/// style (including tuple / v.when part) whether wrote icon_color
fn specSetsIconColor(comptime T: type) bool {
    if (partKind(T)) |k| return switch (k) {
        .css => T.sets_icon_color,
        .cva, .param => T.R.sets_icon_color,
        .when => specSetsIconColor(@TypeOf(T.part)),
        else => false,
    };
    if (isTuple(T)) {
        for (@import("zenit_reflection").fields(T)) |f| if (specSetsIconColor(f.type)) return true;
    }
    return false;
}

/// `<text style={...}>` css part box section (null if missing). choose-one with `box` property.
fn textStyleBoxPart(comptime Props: type) ?type {
    if (!@hasField(Props, "style")) return null;
    const S = @FieldType(Props, "style");
    const B: ?type = blk: {
        if (partKind(S)) |k| if (k == .css) break :blk S.box_part;
        if (isTuple(S)) for (@import("zenit_reflection").fields(S)) |f| {
            if (partKind(f.type)) |k| if (k == .css and f.type.box_part != null)
                @compileError("ui.view.text: a style with box fields (padding, background …) must be the whole style, not part of a tuple");
        };
        if (partKind(S)) |k| if (k == .when) {
            const P = @TypeOf(S.part);
            if (partKind(P)) |pk| if (pk == .css and P.box_part != null)
                @compileError("ui.view.text: v.when(…) on text can only switch text fields; put conditional box fields (padding, background …) in box=");
        };
        break :blk null;
    };
    if (B != null and @hasField(Props, "box")) @compileError("ui.view.text: the style already has box fields; give box fields either in the style or in box=, not both");
    return B;
}

/// text `box` as box style: fields rename as-is to style, keep comptime (style function is
/// compile-time value, cannot become runtime field)
fn TextBoxProps(comptime Props: type) type {
    const f = for (@import("zenit_reflection").fields(Props)) |f| {
        if (std.mem.eql(u8, f.name, "box")) break f;
    } else unreachable;
    var out = f;
    out.name = "style";
    return @import("zenit_reflection").Struct(&.{out});
}

pub fn Text(comptime Props: type, comptime Content: type) type {
    comptime checkProps(Props, &text_props, "ui.view.text");
    return struct {
        props: Props,
        content: Content,

        pub const zenit_view_element = true;
        pub const view_single = true;
        const Plan = TextPlan(Props);

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const initial = Plan.initial(self.props, cx.tokens);
            const node = if (comptime isFmt(Content) and !fmtReactive(Content))
                try staticFmtText(cx, Content.format, self.content.args, initial)
            else if (comptime isFmt(Content) and fmtSourcesOnly(Content)) (if (fmtStaticNow(self.content.args))
                // reactive params all Source and now all static value (component received static
                // prop): format
                // once, no effect build.
                try staticFmtText(cx, Content.format, peekFmtArgs(self.content.args), initial)
            else
                try core.textFmt(cx, scope, Content.format, self.content.args, initial)) else if (comptime isFmt(Content))
                try core.textFmt(cx, scope, Content.format, self.content.args, initial)
            else if (comptime isStringLike(Content))
                try core.text(cx, self.content, initial)
            else
                try core.text(cx, sourceOf([]const u8, "ui.view.text content", self.content).peek(), initial);
            try sink.insert(cx, node);
            applyTextStyle(node, initial);
            applyAttrs(node, self.props);
            try bindVisible(scope, node, self.props);
            try bindA11y(scope, node, self.props);
            try Plan.attach(self.props, scope, cx, node);
            if (comptime @hasField(Props, "box")) try BoxPlan(TextBoxProps(Props), null, true).attach(.{ .style = self.props.box }, scope, cx, node);
            // style has box fields (YSS one style both write text + padding/bg): box part fall to
            // text node
            // self
            if (comptime textStyleBoxPart(Props)) |B| try BoxPlan(struct { style: B }, null, true).attach(.{ .style = B{} }, scope, cx, node);
            if (comptime !isFmt(Content) and !isStringLike(Content)) {
                try bind_mod.bindText(cx, scope, self.content, node);
            }
        }
    };
}

/// reactive format text content: `v.text(.{ .style = S.count }, v.fmt("count = {d}", .{count}))`.
/// args element can be signal / memo / derived value / plain value (same `ui.textFmt`).
pub fn fmt(comptime format: []const u8, args: anytype) Fmt(format, @TypeOf(args)) {
    return .{ .args = args };
}

pub fn Fmt(comptime format_str: []const u8, comptime Args: type) type {
    return struct {
        args: Args,
        pub const format = format_str;
        pub const zenit_view_fmt = true;
    };
}

const icon_props = [_][]const u8{ "style", "tint", "test_id", "a11y", "on_click", "visible", "hit_test" };

/// icon: `v.icon(.{ .style = .{ .width = .fixed(13) }, .tint = S.iconMuted },
/// ui.icons.chevron_down)`.
/// - `.style`: same box (unset size uses the resource default);
/// - `.tint`: `Color` or `fn (*const ThemeTokens) Color` (replays on theme); unset = no tint
///   (white multiply).
/// - resource: `SvgAsset` or its source (`Source(SvgAsset)` / `Source(?SvgAsset)`, e.g. a
///   component prop): the value is taken at mount. A changing source is read once at mount +
///   warn; to swap icons swap the element (`show` / `match`).
pub fn icon(props: anytype, asset: anytype) Media(@TypeOf(props), @TypeOf(asset), .icon) {
    return .{ .props = props, .res = asset };
}

/// Color = f(source's current value, tokens): v.icon(.{ .tint = v.tintBy(color, S.iconTint) },
/// asset),
/// fn iconTint(c: TagColor, t: *const ThemeTokens) Color. Re-tint when source changes or theme
/// switches;
/// when source is currently static, replay only with theme (no effect).
pub fn tintBy(src: anytype, comptime f: anytype) TintBy(@TypeOf(src), f) {
    return .{ .src = src };
}

pub fn TintBy(comptime Src: type, comptime f_value: anytype) type {
    return struct {
        src: Src,
        pub const zenit_tint_by = true;
        pub const f = f_value;
        pub const Arg = @import("zenit_reflection").params(@TypeOf(f_value))[0].type.?;
    };
}

fn isTintBy(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zenit_tint_by");
}

pub fn Icon(comptime Props: type) type {
    return Media(Props, SvgAsset, .icon);
}

pub fn Image(comptime Props: type) type {
    return Media(Props, u32, .image);
}

/// Resource (SVG asset or texture id) value at mount; warn once if source changes (asset doesn't
/// follow data).
fn resourceNow(comptime R: type, comptime who: []const u8, res: anytype) !R {
    const X = @TypeOf(res);
    if (comptime X == R) return res;
    if (comptime isSourceUnion(X)) {
        const v = res.peek();
        return if (comptime @typeInfo(@TypeOf(v)) == .optional) (v orelse error.ViewMediaNoResource) else v;
    }
    @compileError(who ++ ": expected " ++ @typeName(R) ++ " or a source of it, got " ++ @typeName(X));
}

/// Icon (SVG asset) and texture image share elements: style, tint (Color / theme function /
/// tintBy), attributes.
fn Media(comptime Props: type, comptime Res: type, comptime kind: enum { icon, image }) type {
    const who = if (kind == .icon) "ui.view.icon" else "ui.view.image";
    comptime checkProps(Props, &icon_props, who);
    const has_tint = @hasField(Props, "tint");
    const Tint = if (has_tint) @FieldType(Props, "tint") else void;
    const tint_fn = has_tint and isColorFn(Tint);
    const tint_by = has_tint and isTintBy(Tint);
    if (has_tint and !tint_fn and Tint != Color and @typeInfo(Tint) != .@"struct")
        @compileError("ui.view.icon: .tint must be a Color, fn (*const ThemeTokens) Color or v.tintBy(src, f), got " ++ @typeName(Tint));
    // When both tint sources exist, precedence depends on effect order; undoing icon_color can't
    // restore correct color: give only one.
    if (has_tint and @hasField(Props, "style") and specSetsIconColor(@FieldType(Props, "style")))
        @compileError(who ++ ": the style sets icon-color and the element also has tint=; give the icon color in one place");
    return struct {
        props: Props,
        res: Res,

        pub const zenit_view_element = true;
        /// When src is source, may rebuild region by resource value (rebuild node on resource
        /// change), not a single-node element.
        pub const view_single = !isReactiveSource(Res);
        const Plan = BoxPlan(Props, null, false);

        fn tintFor(props: Props, t: *const ThemeTokens) Color {
            if (!has_tint) return Color.WHITE;
            if (tint_fn) return props.tint(t);
            if (tint_by) return Tint.f(readSource(Tint.Arg, props.tint.src, false), t);
            return coerceLiteral(Color, props.tint);
        }

        /// tintBy runtime: hang view_theme slot when source is fully static, otherwise effect
        /// follows source and theme.
        const TintState = if (tint_by) struct {
            node: *Node,
            cx: *Cx,
            src: @FieldType(Tint, "src"),
            theme: *Signal(*const ThemeTokens),
            link: ThemeLink = undefined,
            fn run(st: *@This()) void {
                _ = st.node.setTint(Tint.f(readSource(Tint.Arg, st.src, true), st.theme.get()));
            }
            fn replay(r: *ViewThemeReplay, t: *const ThemeTokens) void {
                const link: *ThemeLink = @fieldParentPtr("replay", r);
                const st: *@This() = @fieldParentPtr("link", link);
                _ = st.node.setTint(Tint.f(readSource(Tint.Arg, st.src, false), t));
            }
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                allocator.destroy(@as(*@This(), @ptrCast(@alignCast(ptr))));
            }
            fn start(props: Props, scope: *Scope, cx: *Cx, node: *Node) !void {
                // First get the maybe-failing theme signal, then allocate state: no failure point
                // allowed between create and adoptResource.
                const theme_sig = try cx.themeSignal(rootScopeOf(scope));
                const st = try scope.allocator.create(@This());
                st.* = .{ .node = node, .cx = cx, .src = props.tint.src, .theme = theme_sig };
                try scope.adoptResource(@ptrCast(st), destroy);
                if (sourceStaticNow(props.tint.src)) return st.link.attach(scope, cx, node, replay);
                try scope.createEffect(st, run);
            }
        } else void;

        /// src follows source: build region by resource value, rebuild media node when value
        /// changes (no display when optional resource is null).
        fn emitFollowing(self: @This(), src: anytype, scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const V = @TypeOf(src.peek());
            const R = control_flow.SwitchRegion(V, Props, struct {
                fn e(props: Props, s: *Scope, c: *Cx, sk: Sink, v: V) anyerror!void {
                    if (@typeInfo(V) == .optional) {
                        const x = v orelse return;
                        return Media(Props, @TypeOf(x), kind).viewEmitValue(props, x, s, c, sk);
                    }
                    return Media(Props, V, kind).viewEmitValue(props, v, s, c, sk);
                }
            }.e);
            _ = try R.mount(scope, cx, sink, src, self.props);
        }

        fn viewEmitValue(props: Props, res: Res, scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            return (@This(){ .props = props, .res = res }).viewEmit(scope, cx, sink);
        }

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            if (comptime isReactiveSource(Res) and !isSourceUnion(Res)) return self.emitFollowing(reactive.toSource(self.res), scope, cx, sink);
            if (comptime isSourceUnion(Res)) {
                if (!self.res.isStatic()) return self.emitFollowing(self.res, scope, cx, sink);
            }
            const tint = tintFor(self.props, cx.tokens);
            const style = Plan.initial(self.props, cx.tokens);
            const node = if (kind == .icon)
                try ui_api.iconTintStyled(cx, try resourceNow(SvgAsset, who, self.res), tint, style)
            else
                try core.imageTintStyled(cx, try resourceNow(u32, who, self.res), tint, style);
            try sink.insert(cx, node);
            // icon_color from static style now lands on the node (dynamic style followed by
            // BoxRuntime).
            if (Plan.plan_mode != .dynamic) if (style.icon_color) |c| {
                _ = node.setTint(c);
            };
            applyAttrs(node, self.props);
            try bindVisible(scope, node, self.props);
            try bindA11y(scope, node, self.props);
            if (tint_fn) {
                // Tint function and (compile-time) style share the single on_theme slot.
                const tint_value = comptime blk: {
                    for (@import("zenit_reflection").fields(Props)) |f| if (std.mem.eql(u8, f.name, "tint")) break :blk f.defaultValue().?;
                    unreachable;
                };
                node.meta.per_frame.hooks.on_theme = struct {
                    fn hook(n: *Node, t: *const ThemeTokens, allocator: std.mem.Allocator) void {
                        Plan.applyThemed(n, t, allocator);
                        _ = n.setTint(tint_value(t));
                    }
                }.hook;
                if (Plan.plan_mode == .dynamic) try Plan.attach(self.props, scope, cx, node);
            } else {
                try Plan.attach(self.props, scope, cx, node);
                if (tint_by) try TintState.start(self.props, scope, cx, node);
            }
        }
    };
}

fn isColorFn(comptime T: type) bool {
    const F = switch (@typeInfo(T)) {
        .@"fn" => T,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") p.child else return false,
        else => return false,
    };
    const info = @typeInfo(F).@"fn";
    return @import("zenit_reflection").paramsInfo(info).len == 1 and @import("zenit_reflection").paramsInfo(info)[0].type == *const ThemeTokens and info.return_type == Color;
}

/// Whether format params contain reactive sources: format only once when all are values, no effect.
fn fmtReactive(comptime F: type) bool {
    for (@import("zenit_reflection").fields(@FieldType(F, "args"))) |f| {
        if (isReactiveSource(f.type)) return true;
    }
    return false;
}

fn isSourceUnion(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @hasDecl(T, "zenit_source");
}

/// Reactive params are all Source(T) (no *Signal / *Memo / Derived): staticness only known at
/// runtime.
fn fmtSourcesOnly(comptime F: type) bool {
    for (@import("zenit_reflection").fields(@FieldType(F, "args"))) |f| {
        if (isReactiveSource(f.type) and !isSourceUnion(f.type)) return false;
    }
    return true;
}

fn fmtStaticNow(args: anytype) bool {
    inline for (@import("zenit_reflection").fields(@TypeOf(args))) |f| {
        if (comptime isSourceUnion(f.type)) {
            if (!@field(args, f.name).isStatic()) return false;
        }
    }
    return true;
}

fn PeekedFmtArgs(comptime Args: type) type {
    const fields = @import("zenit_reflection").fields(Args);
    var value_types: [fields.len]type = undefined;
    for (fields, 0..) |f, i| value_types[i] = if (isSourceUnion(f.type)) f.type.Value else f.type;
    return @Tuple(&value_types);
}

fn peekFmtArgs(args: anytype) PeekedFmtArgs(@TypeOf(args)) {
    var out: PeekedFmtArgs(@TypeOf(args)) = undefined;
    inline for (@import("zenit_reflection").fields(@TypeOf(args)), 0..) |f, i| {
        out[i] = if (comptime isSourceUnion(f.type)) @field(args, f.name).peek() else @field(args, f.name);
    }
    return out;
}

fn staticFmtText(cx: *Cx, comptime format: []const u8, args: anytype, style: TextStyle) !*Node {
    var buf: [256]u8 = undefined;
    if (std.fmt.bufPrint(&buf, format, args)) |s| {
        return core.text(cx, s, style); // core.text copies content.
    } else |_| {
        const heap = try std.fmt.allocPrint(cx.allocator, format, args);
        defer cx.allocator.free(heap);
        return core.text(cx, heap, style);
    }
}

/// Texture image (registered texture id, common for app-bundled bitmap icons): v.image(.{ .style =
/// S.icon16, .tint = c }, tex_id).
/// Tint usage same as v.icon (Color / theme function / tintBy); texture id can be source, value
/// taken at mount. Use v.icon for SVG assets.
pub fn image(props: anytype, texture_id: anytype) Media(@TypeOf(props), TextureArg(@TypeOf(texture_id)), .image) {
    return .{ .props = props, .res = if (comptime @TypeOf(texture_id) == comptime_int) @as(u32, texture_id) else texture_id };
}

fn TextureArg(comptime T: type) type {
    return if (T == comptime_int) u32 else T;
}

/// Elastic space (consume remaining space).
pub fn spacer() Spacer {
    return .{};
}

pub const Spacer = struct {
    pub const zenit_view_element = true;
    pub const view_single = true;
    pub fn viewEmit(_: Spacer, _: *Scope, cx: *Cx, sink: Sink) anyerror!void {
        try sink.insert(cx, try core.spacer(cx));
    }
};

// Elements: components

/// Component + children: children plug into component's slot (ScrollArea content list, Modal
/// body...
/// Components with triggers (Popover / Tooltip / Menu) then chain .trigger(.{ ... }).
/// Components declare these positions via ViewParts protocol; see view_parts.zig.
pub fn with(component_builder: anytype, children: anytype) With(@TypeOf(component_builder), @TypeOf(children), void, void, void, void) {
    return .{ .builder = component_builder, .children = children, .trigger_children = {}, .part_ids = {}, .ref_dest = {}, .named = {} };
}

/// Type of v.with(component, children) (use when view function requires return type; With's
/// remaining params change as features are added, don't write directly).
pub fn WithChildren(comptime B: type, comptime Children: type) type {
    return With(B, Children, void, void, void, void);
}

pub fn With(comptime B: type, comptime Children: type, comptime Trigger: type, comptime PartIds: type, comptime RefDest: type, comptime Named: type) type {
    comptime if (!isComponent(B)) @compileError("ui.view.with: first argument must be a component builder, got " ++ @typeName(B));
    return struct {
        builder: B,
        children: Children,
        trigger_children: Trigger,
        part_ids: PartIds,
        ref_dest: RefDest,
        named: Named,

        pub const zenit_view_element = true;
        pub const view_single = true;

        /// Trigger content (Popover / Tooltip / Menu trigger slot).
        pub fn trigger(self: @This(), children: anytype) With(B, Children, @TypeOf(children), PartIds, RefDest, Named) {
            return .{ .builder = self.builder, .children = self.children, .trigger_children = children, .part_ids = self.part_ids, .ref_dest = self.ref_dest, .named = self.named };
        }

        /// Named slot content: .slots(.{ .header = ..., .footer = ... }), field names match
        /// component slot names (Yix component's header: View param).
        pub fn slots(self: @This(), named: anytype) With(B, Children, Trigger, PartIds, RefDest, @TypeOf(named)) {
            return .{ .builder = self.builder, .children = self.children, .trigger_children = self.trigger_children, .part_ids = self.part_ids, .ref_dest = self.ref_dest, .named = named };
        }

        /// Set attributes on component internals: value is test_id string, or .{ .style, .test_id,
        /// ... } (see v.attrs .parts).
        pub fn parts(self: @This(), ids: anytype) With(B, Children, Trigger, @TypeOf(ids), RefDest, Named) {
            return .{ .builder = self.builder, .children = self.children, .trigger_children = self.trigger_children, .part_ids = ids, .ref_dest = self.ref_dest, .named = self.named };
        }

        /// After mount, write component mount result to dest (see v.ref).
        pub fn ref(self: @This(), dest: anytype) With(B, Children, Trigger, PartIds, @TypeOf(dest), Named) {
            comptime checkRefDest(@TypeOf(dest), MountResult(B), @typeName(B));
            return .{ .builder = self.builder, .children = self.children, .trigger_children = self.trigger_children, .part_ids = self.part_ids, .ref_dest = dest, .named = self.named };
        }

        pub fn capture(self: @This(), dest: anytype) With(B, Children, Trigger, PartIds, CaptureDest(@TypeOf(dest)), Named) {
            return self.ref(CaptureDest(@TypeOf(dest)){ .dest = dest });
        }

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const vp = try mountComponent(scope, cx, sink, self.builder, self.part_ids, self.ref_dest);
            if (Trigger != void) {
                const t = vp.trigger orelse return error.ViewComponentHasNoTrigger;
                try emit(scope, cx, sink.child(t), self.trigger_children);
            }
            if (comptime hasChildren(Children)) {
                const slot = vp.slot orelse return error.ViewComponentHasNoSlot;
                var at = sink.child(slot);
                at.before = vp.slot_before;
                try emit(vp.slot_scope orelse scope, cx, at, self.children);
            }
            if (Named != void) inline for (@import("zenit_reflection").fields(Named)) |f| {
                const point = namedSlot(vp, f.name) orelse return error.ViewComponentHasNoSlot;
                var at = sink.child(point.parent);
                at.before = point.before;
                try emit(vp.slot_scope orelse scope, cx, at, @field(self.named, f.name));
            };
        }
    };
}

fn namedSlot(vp: ViewParts, name: []const u8) ?view_parts.SlotPoint {
    for (vp.named) |n| if (n) |slot| if (std.mem.eql(u8, slot.name, name)) return slot.at;
    return null;
}

// -- Slot insertion point (Yix template's {children} / {header}) --

/// When slot is in container middle, place anchor at that position (no space, no gap, no hit or
/// a11y), children inserted before it.
pub fn slotMark(dest: *?view_parts.SlotPoint) SlotMark {
    return .{ .dest = dest };
}

pub const SlotMark = struct {
    dest: *?view_parts.SlotPoint,
    pub const zenit_view_element = true;
    pub const view_single = true;
    pub fn viewEmit(self: SlotMark, _: *Scope, cx: *Cx, sink: Sink) anyerror!void {
        const anchor = try core.anchorNode(cx);
        try sink.insert(cx, anchor);
        self.dest.* = .{ .parent = sink.parent orelse return error.ViewSlotNeedsParent, .before = anchor };
    }
};

/// When slot is container's last child: don't build anchor, record container itself (children
/// appended at end).
pub fn slotEnd(dest: *?view_parts.SlotPoint, child: anytype) SlotEnd(@TypeOf(child)) {
    return .{ .dest = dest, .child = child };
}

pub fn SlotEnd(comptime C: type) type {
    return struct {
        dest: *?view_parts.SlotPoint,
        child: C,
        pub const zenit_view_element = true;
        pub const view_single = true;
        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            var node: ?*Node = null;
            try emit(scope, cx, sink, capture(&node, self.child));
            self.dest.* = .{ .parent = node orelse return error.ViewSlotNeedsParent };
        }
    };
}

/// Yix slotted component mount result: default slot (children) and named slots.
pub fn slottedParts(root: *Node, default: ?view_parts.SlotPoint, named: anytype) ViewParts {
    var vp: ViewParts = .{ .root = root };
    if (default) |d| {
        vp.slot = d.parent;
        vp.slot_before = d.before;
    }
    comptime if (@import("zenit_reflection").fields(@TypeOf(named)).len > view_parts.max_named_slots) @compileError("ui.view: at most 4 named slots");
    inline for (@import("zenit_reflection").fields(@TypeOf(named)), 0..) |f, i| {
        if (@field(named, f.name)) |at| vp.named[i] = .{ .name = f.name, .at = at };
    }
    return vp;
}

/// Stateful user component: f(props, scope, cx) !*Node, or f(scope, cx) !*Node without props
/// (props pass {}). Pure view functions don't need it -- return elements directly; components using
/// signal/
/// hooks / ui.on.bind go here (scope is for them). Props converted per function's first param type
/// (anonymous literal field-by-field).
pub fn component(comptime f: anytype, props: anytype) ComponentOf(f) {
    const P = ComponentProps(f);
    return .{ .props = if (P == void) {} else coerceLiteral(P, props) };
}

/// Yix codegen: reactive source value type, static value as-is.
pub fn yixValue(comptime T: type) type {
    const C = switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .one) p.child else T,
        else => T,
    };
    const container = switch (@typeInfo(C)) {
        .@"struct", .@"union", .@"enum" => true,
        else => false,
    };
    if (container and (@hasDecl(C, "zenit_reactive") or @hasDecl(C, "zenit_source"))) return reactive.SourceValueOf(T);
    return T;
}

/// Yix call expressions may probe actual reads only when their value is storable
/// at runtime. Sources keep their identity; comptime-only results pass through.
pub fn yixCallMayDerive(comptime T: type) bool {
    return yixValue(T) == T and T != void and T != noreturn and !yixRequiresComptime(T, .{});
}

fn yixRequiresComptime(comptime T: type, comptime visited: anytype) bool {
    inline for (visited) |V| if (T == V) return false;
    const next = visited ++ .{T};
    return switch (@typeInfo(T)) {
        .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined, .@"fn" => true,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") @typeInfo(p.child).@"fn".is_generic else yixRequiresComptime(p.child, next),
        .optional => |o| yixRequiresComptime(o.child, next),
        .error_union => |e| yixRequiresComptime(e.payload, next),
        .array => |a| yixRequiresComptime(a.child, next),
        .vector => |v| yixRequiresComptime(v.child, next),
        .@"struct" => |s| blk: {
            inline for (s.field_types, s.field_attrs) |TField, field_attrs| if (!field_attrs.@"comptime" and yixRequiresComptime(TField, next)) break :blk true;
            break :blk false;
        },
        .@"union" => |u| blk: {
            inline for (u.field_types) |TField| if (yixRequiresComptime(TField, next)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Yix codegen: element type of {for (xs) |x|} (xs can be source).
pub fn yixItem(comptime T: type) type {
    const V = yixValue(T);
    return switch (@typeInfo(V)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child,
            .one => @typeInfo(p.child).array.child,
            else => @compileError("Yix for requires a list"),
        },
        .array => |a| a.child,
        else => @compileError("Yix for requires a list"),
    };
}

/// Yix codegen: format specifier for interpolation {x} / {x:.2}.
pub fn yixFormat(comptime T: type, comptime suffix: []const u8) []const u8 {
    const V = yixValue(T);
    const kind = switch (@typeInfo(V)) {
        .int, .comptime_int, .float, .comptime_float => "d",
        .pointer => |p| if (p.child == u8 or (@typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8)) "s" else "any",
        .@"struct", .@"union", .@"enum" => if (@hasDecl(V, "format")) "f" else "any",
        else => "any",
    };
    return "{" ++ kind ++ (if (suffix.len == 0) "" else ":" ++ suffix) ++ "}";
}

/// Component property value type (Yix compiler type-checks property expressions): f is component
/// function,
/// returned element has props field; when that field's component is Source(T) (or Model(T)), get T.
/// null if can't get
/// (not a function, return type depends on params, no such property), caller falls back to
/// expression type. So
/// variant={if (on) .primary else .ghost}, label={if (d) "a" else "b"} type-check per property
/// type.
pub fn attrType(comptime f: anytype, comptime field: []const u8) ?type {
    const info = @typeInfo(@TypeOf(f));
    if (info != .@"fn") return null;
    const R = info.@"fn".return_type orelse return null;
    if (@typeInfo(R) != .@"struct" or !@hasField(R, "props")) return null;
    const P = @FieldType(R, "props");
    if (@typeInfo(P) != .@"struct" or !@hasField(P, field)) return null;
    const F = @FieldType(P, field);
    if (@typeInfo(F) != .@"union" and @typeInfo(F) != .@"struct") return null;
    if (@hasDecl(F, "zenit_source")) return F.Value;
    if (@hasDecl(F, "zenit_model")) return F.Value;
    return null;
}

/// Whether component property is event param (Handler(T) / ?Handler(T)). When Yix compiles
/// onX={...} on component
/// element, split by it: event params compile to handler, rest (onTop: bool) passed by value. null
/// if can't get param table
/// (return type depends on params).
pub fn propIsEvent(comptime f: anytype, comptime field: []const u8) ?bool {
    const info = @typeInfo(@TypeOf(f));
    if (info != .@"fn") return null;
    const R = info.@"fn".return_type orelse return null;
    if (@typeInfo(R) != .@"struct" or !@hasField(R, "props")) return null;
    const P = @FieldType(R, "props");
    if (@typeInfo(P) != .@"struct" or !@hasField(P, field)) return null;
    var F = @FieldType(P, field);
    if (@typeInfo(F) == .optional) F = @typeInfo(F).optional.child;
    return (@typeInfo(F) == .@"struct" or @typeInfo(F) == .@"union") and @hasDecl(F, "zenit_handler");
}

/// Yix: onX={identifier / field} both meanings possible (handler save -> save(), or data flag),
/// type of receiving param picks one. null param table -> treat as event handler (matches general
/// component event usage).
pub fn isEventProp(comptime f: anytype, comptime field: []const u8) bool {
    return propIsEvent(f, field) orelse true;
}

/// Yix: onX={event statement} (assignment, block, if, |v| capture, function call) only for event
/// params.
pub fn eventProp(comptime f: anytype, comptime field: []const u8, handler: anytype) @TypeOf(handler) {
    if (comptime propIsEvent(f, field) == false) @compileError("Yix: ." ++ field ++ " of this component takes a value, not an event; pass a value expression (statements like `x = 1` or `save()` only go to Handler parameters)");
    return handler;
}

/// Yix: onX={literal} only for data params.
pub fn valueProp(comptime f: anytype, comptime field: []const u8, value: anytype) @TypeOf(value) {
    if (comptime propIsEvent(f, field) == true) @compileError("Yix: ." ++ field ++ " of this component is an event; give it a statement such as `{save()}` or `{n += 1}`, not a literal value");
    return value;
}

/// Type of v.component(f, props): when view function needs return type, use v.ComponentOf(f).
pub fn ComponentOf(comptime f: anytype) type {
    return Component(f, ComponentProps(f));
}

fn ComponentProps(comptime f: anytype) type {
    const F = switch (@typeInfo(@TypeOf(f))) {
        .pointer => |p| p.child,
        else => @TypeOf(f),
    };
    const params = @import("zenit_reflection").params(F);
    return switch (params.len) {
        2 => void,
        3 => params[0].type orelse @compileError("ui.view.component: props parameter must have a concrete type"),
        else => @compileError("ui.view.component: f must be fn (Props, *Scope, *Cx) !*Node or fn (*Scope, *Cx) !*Node"),
    };
}

pub fn Component(comptime f: anytype, comptime Props: type) type {
    return struct {
        props: Props,

        pub const zenit_view_element = true;
        pub const view_single = true;

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            // When insert fails, node stashes at sink as stray, caller recycles by capture (with
            // bound scope).
            try sink.insert(cx, try self.mount(scope, cx));
        }

        /// Mount as standalone node (same usage as builder .mount). Component function runs in new
        /// child scope under caller scope;
        /// this child scope binds to returned root node: when node is freed (freeNode),
        /// component-created signal/memo/effect destroyed,
        /// won't outlive the node.
        pub fn mount(self: @This(), scope: *Scope, cx: *Cx) !*Node {
            cx.owner.enterMount();
            defer cx.owner.exitMount();
            const cs = try scope.childScope();
            const node = (if (Props == void) f(cs, cx) else f(self.props, cs, cx)) catch |err| {
                cs.dispose();
                return err;
            };
            Cx.bindScopeToNode(cs, node) catch |err| {
                control_flow.discardCaptured(cx, cs, node, null);
                return err;
            };
            return node;
        }
    };
}

/// Slotted component: f(props, scope, cx) !ViewParts (Yix generates when component declares
/// children: View param).
/// Is component builder (not view element), accepts v.with(component, .{ children }), children plug
/// into ViewParts.slot;
/// without children works normally as child element or .mount. Lifecycle same as Component:
/// component function runs in child scope
/// bound to root node; children in slot belong to caller scope (same as hand-written container
/// component).
pub fn slotted(comptime f: anytype, props: anytype) SlottedOf(f) {
    return .{ .props = coerceLiteral(SlottedProps(f), props) };
}

pub fn SlottedOf(comptime f: anytype) type {
    return Slotted(f, SlottedProps(f));
}

fn SlottedProps(comptime f: anytype) type {
    const params = @import("zenit_reflection").params(@TypeOf(f));
    if (params.len != 3) @compileError("ui.view.slotted: f must be fn (Props, *Scope, *Cx) !ViewParts");
    return params[0].type orelse @compileError("ui.view.slotted: props parameter must have a concrete type");
}

pub fn Slotted(comptime f: anytype, comptime Props: type) type {
    return struct {
        props: Props,

        pub fn viewMount(self: @This(), scope: *Scope, cx: *Cx) !ViewParts {
            cx.owner.enterMount();
            defer cx.owner.exitMount();
            const cs = try scope.childScope();
            const vp: ViewParts = f(self.props, cs, cx) catch |err| {
                cs.dispose();
                return err;
            };
            Cx.bindScopeToNode(cs, vp.root.?) catch |err| {
                control_flow.discardCaptured(cx, cs, vp.root.?, null);
                return err;
            };
            return vp;
        }

        pub fn mount(self: @This(), scope: *Scope, cx: *Cx) !*Node {
            return (try self.viewMount(scope, cx)).root.?;
        }
    };
}

fn PartsChild(comptime Child: type, comptime Ids: type) type {
    if (isComponent(Child)) return With(Child, @TypeOf(.{}), void, Ids, void, void);
    if (@hasDecl(Child, "parts")) return @TypeOf(@as(Child, undefined).parts(@as(Ids, undefined)));
    return Child;
}

fn MountPayload(comptime B: type) type {
    return FnPayload(@TypeOf(B.mount));
}

fn FnPayload(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
}

/// Type of component mount result (what v.ref writes): return value of viewMount, else return value
/// of mount.
pub fn MountResult(comptime B: type) type {
    if (@hasDecl(B, "viewMount")) return FnPayload(@TypeOf(B.viewMount));
    return MountPayload(B);
}

/// A scope-owned, nullable mount handle. Its owner must outlive the mounted region.
/// The handle itself is valid only while its owner scope is alive.
pub fn Ref(comptime T: type) type {
    return struct {
        owner: *Scope,
        value: ?T = null,
        generation: usize = 0,
        pub fn get(self: *const @This()) ?T {
            return self.value;
        }
    };
}

pub fn createRef(scope: *Scope, comptime T: type) !*Ref(T) {
    return scope.createState(Ref(T), .{ .owner = scope });
}

fn CaptureDest(comptime D: type) type {
    return struct {
        pub const view_capture = true;
        dest: D,
    };
}

fn isCapture(comptime D: type) bool {
    return @typeInfo(D) == .@"struct" and @hasDecl(D, "view_capture");
}

fn checkRefDest(comptime D: type, comptime R: type, comptime what: []const u8) void {
    if (isCapture(D)) {
        const P = @FieldType(D, "dest");
        if (P == *R or P == *?R) return;
        @compileError("ui.view.capture: incompatible destination for " ++ what);
    }
    if (D == *Ref(R)) return;
    @compileError("ui.view.ref: use createRef(scope, " ++ @typeName(R) ++ "); for synchronous mount output use v.capture(&dest, child)");
}

fn storeRef(scope: *Scope, dest: anytype, value: anytype) !void {
    const D = @TypeOf(dest);
    if (D == void) return;
    if (comptime isCapture(D)) {
        dest.dest.* = value;
        return;
    }
    // A short-lived owner cannot safely hold a longer-lived mount's cleanup.
    var ancestor: ?*Scope = scope;
    while (ancestor) |s| : (ancestor = s.parent) {
        if (s == dest.owner) break;
    }
    if (ancestor == null) return error.ViewRefOwnerMustOutliveMount;
    const Binding = struct {
        dest: D,
        generation: usize,
        fn clear(self: *@This()) void {
            if (self.dest.generation == self.generation) self.dest.value = null;
        }
    };
    const binding = try scope.createState(Binding, .{ .dest = dest, .generation = dest.generation + 1 });
    try scope.onCleanup(Binding, binding, Binding.clear);
    dest.generation = binding.generation;
    dest.value = value;
}

/// .parts value: string = test_id; or attrs properties (.style uses mount snapshot, can't override
/// part's own effect/animation fields).
const part_props = [_][]const u8{ "window_region", "style", "test_id", "a11y", "on_click", "visible", "focusable", "hit_test", "on_focus", "on_blur", "on_hover", "on_leave" };

/// Part attributes: each field in parts must be *Node / ?*Node field in component Result (or
/// ViewParts), compile-time checked;
/// after mount succeeds (root inserted at insertion point) write to corresponding part.
fn applyParts(scope: *Scope, cx: *Cx, result: anytype, parts: anytype) !void {
    if (@TypeOf(parts) == void) return;
    const R = @TypeOf(result);
    inline for (@import("zenit_reflection").fields(@TypeOf(parts))) |f| {
        if (!@hasField(R, f.name)) @compileError(@typeName(R) ++ " has no part ." ++ f.name ++ " (parts are its *Node fields)");
        const part: ?*Node = @field(result, f.name);
        const spec = @field(parts, f.name);
        const Spec = @TypeOf(spec);
        if (part) |n| {
            if (comptime isStringLike(Spec)) {
                n.meta.ownership.meta.test_id = spec;
            } else {
                comptime checkProps(Spec, &part_props, "ui.view .parts." ++ f.name);
                applyAttrs(n, spec);
                try bindVisible(scope, n, spec);
                try bindA11y(scope, n, spec);
                try BoxPlan(Spec, null, true).attach(spec, scope, cx, n);
            }
        }
    }
}

/// Mount component, insert root at insertion point, then write ref and part attributes.
/// Part attribute write failure: root already in tree, rolls back with it.
fn mountComponent(scope: *Scope, cx: *Cx, sink: Sink, builder: anytype, parts: anytype, ref_dest: anytype) !ViewParts {
    const B = @TypeOf(builder);
    const result = if (comptime @hasDecl(B, "viewMount")) try builder.viewMount(scope, cx) else blk: {
        if (comptime @import("zenit_reflection").params(@TypeOf(B.mount)).len != 3)
            @compileError(@typeName(B) ++ ".mount takes extra arguments, so ui.view cannot mount it; mount it yourself and pass the resulting *Node as a child");
        break :blk try builder.mount(scope, cx);
    };
    const R = @TypeOf(result);
    const vp: ViewParts = if (R == ViewParts) result else if (R == *Node) blk: {
        if (@TypeOf(parts) != void) @compileError(@typeName(B) ++ ".mount returns a single *Node; it has no named parts");
        break :blk .{ .root = result };
    } else if (comptime @typeInfo(R) == .@"struct" and @hasDecl(R, "viewParts")) result.viewParts() else @compileError(@typeName(B) ++ " mounts to " ++ @typeName(R) ++
        "; ui.view needs to know which node to attach — add `pub fn viewParts(self) ui.ViewParts` to " ++
        @typeName(R) ++ " (see src/ui/view_parts.zig)");
    if (vp.root) |r| try sink.insert(cx, r);
    try storeRef(scope, ref_dest, result);
    try applyParts(scope, cx, result, parts);
    return vp;
}

// Elements: decorators and static lists

const attrs_props = [_][]const u8{ "window_region", "style", "test_id", "a11y", "on_click", "visible", "parts", "focusable", "hit_test", "on_focus", "on_blur", "on_hover", "on_leave", "tag", "on_key_down", "on_key_up", "on_pointer_down", "on_pointer_move", "on_pointer_up", "on_scroll" };

/// Yix: <X>text</X>. Component declares param as Text (generated props has pub const text_child =
/// "name"), text is that param
/// (<Button>Save</Button> -> label); else text works normally as child (ui.view.with). Hand-written
/// Zig component adds
/// pub const text_child = "label"; in props struct. literal is static text; null when text has
/// interpolation -- use param={source}.
pub fn textChild(comptime builder: anytype, props: anytype, comptime literal: ?[]const u8, children: anytype) TextChild(builder, @TypeOf(props), @TypeOf(children)) {
    if (comptime textParam(builder)) |field| {
        const words = literal orelse @compileError("Yix: this component takes its text as the `" ++ field ++ "` parameter, which needs static text; use " ++ field ++ "={source} for reactive text");
        if (@hasField(@TypeOf(props), field)) @compileError("Yix: `" ++ field ++ "` is given both as an attribute and as text children");
        return builder(withText(props, field, words));
    }
    return with(builder(props), children);
}

fn TextChild(comptime builder: anytype, comptime Props: type, comptime Children: type) type {
    if (textParam(builder) != null) return BuilderResult(builder).?;
    return @TypeOf(with(builder(@as(Props, undefined)), @as(Children, undefined)));
}

/// Component function return type (only when independent of params).
fn BuilderResult(comptime builder: anytype) ?type {
    return switch (@typeInfo(@TypeOf(builder))) {
        .@"fn" => |f| f.return_type,
        else => null,
    };
}

/// Text param name declared by component (props text_child); null if not declared.
fn textParam(comptime builder: anytype) ?[]const u8 {
    const R = BuilderResult(builder) orelse return null;
    if (@typeInfo(R) != .@"struct" or @hasDecl(R, "viewMount") or !@hasField(R, "props")) return null;
    const P = @FieldType(R, "props");
    if (@typeInfo(P) != .@"struct" or !@hasDecl(P, "text_child")) return null;
    const field: []const u8 = P.text_child;
    if (!@hasField(P, field)) @compileError("ui.view: text_child names ." ++ field ++ ", which is not a field of the component's props");
    return field;
}

/// props plus .<field> = text.
fn withText(props: anytype, comptime field: []const u8, comptime words: []const u8) WithText(@TypeOf(props), field, words) {
    var out: WithText(@TypeOf(props), field, words) = undefined;
    inline for (@import("zenit_reflection").fields(@TypeOf(props))) |f| {
        if (!f.is_comptime) @field(out, f.name) = @field(props, f.name);
    }
    return out;
}

fn WithText(comptime P: type, comptime field: []const u8, comptime words: []const u8) type {
    const fields = @import("zenit_reflection").fields(P);
    var out: [fields.len + 1]@import("zenit_reflection").StructField = undefined;
    for (fields, 0..) |f, i| out[i] = f;
    const value: []const u8 = words;
    out[fields.len] = .{ .name = std.fmt.comptimePrint("{s}", .{field}), .type = []const u8, .default_value_ptr = @ptrCast(&value), .is_comptime = true, .alignment = @alignOf([]const u8) };
    return @import("zenit_reflection").Struct(&out);
}

/// In Yix template, style / parts / testId / visible / a11y on component element: attrs add to
/// component root.
/// Compile error when the component also declares a same-name param: `<X style={...}>` in a
/// template is ambiguous, and that param can never be passed from the template.
/// (Hand-written Zig explicit attrs call is author's choice, no check.)
pub fn templateAttrs(props: anytype, child: anytype) Attrs(@TypeOf(props), @TypeOf(child)) {
    comptime checkAttrsShadowing(@TypeOf(props), @TypeOf(child));
    return attrs(props, child);
}

fn checkAttrsShadowing(comptime Props: type, comptime Child: type) void {
    if (@typeInfo(Child) != .@"struct" or !@hasField(Child, "props")) return;
    const ChildProps = @FieldType(Child, "props");
    if (@typeInfo(ChildProps) != .@"struct") return;
    for (@import("zenit_reflection").fields(Props)) |f| {
        if (std.mem.eql(u8, f.name, "parts")) continue;
        if (@hasField(ChildProps, f.name)) @compileError("Yix template: the component also declares a parameter ." ++ f.name ++
            ", but `" ++ f.name ++ "` on a component element is applied to its root node, so the parameter can never be set from a template. Rename the component parameter");
    }
}

pub fn attrs(props: anytype, child: anytype) Attrs(@TypeOf(props), @TypeOf(child)) {
    return .{ .props = props, .child = child };
}

pub fn Attrs(comptime Props: type, comptime Child: type) type {
    comptime checkProps(Props, &attrs_props, "ui.view.attrs");
    comptime requireSingle(Child, "ui.view.attrs");
    return struct {
        props: Props,
        child: Child,

        pub const zenit_view_element = true;
        pub const view_single = true;
        const Plan = BoxPlan(Props, null, true);

        /// .parts: pass part test_id to component mount (component or v.with(component, ...)).
        fn withParts(self: @This()) if (@hasField(Props, "parts")) PartsChild(Child, @FieldType(Props, "parts")) else Child {
            if (!@hasField(Props, "parts")) return self.child;
            if (comptime isComponent(Child)) return with(self.child, .{}).parts(self.props.parts);
            if (comptime @hasDecl(Child, "parts")) return self.child.parts(self.props.parts);
            @compileError("ui.view.attrs: .parts needs a component builder or v.with(component, ...) as the child");
        }

        /// Set test_id only on internals when root unnecessary (Modal / Sheet portal root is null).
        const parts_only = blk: {
            for (@import("zenit_reflection").fields(Props)) |f| {
                if (!std.mem.eql(u8, f.name, "parts")) break :blk false;
            }
            break :blk true;
        };

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const maybe_node = try emitSingle(scope, cx, sink, self.withParts());
            if (parts_only) return;
            const node = maybe_node orelse return error.ViewAttrsNoRoot;
            applyAttrs(node, self.props);
            try bindVisible(scope, node, self.props);
            try bindA11y(scope, node, self.props);
            // Typed component root event uses capture slot: fires before component's own
            // (e.consume() can intercept), doesn't override on_event.
            try bindTypedEventsAt(.capture, scope, node, self.props);
            try Plan.attach(self.props, scope, cx, node);
        }
    };
}

/// Bind a scope-owned Ref(T). Unmount and mount rollback clear it to null.
/// `const r = try v.createRef(scope, *Node); v.ref(r, child); r.get()`.
/// A later mount supersedes the old binding; old cleanup cannot clear the new value.
pub fn ref(dest: anytype, child: anytype) RefOf(@TypeOf(dest), @TypeOf(child)) {
    const C = @TypeOf(child);
    if (comptime isComponent(C)) return with(child, .{}).ref(dest);
    if (comptime @hasDecl(C, "ref")) return child.ref(dest);
    return .{ .dest = dest, .child = child };
}

/// Capture mount output once. `dest` is only borrowed during synchronous mount;
/// this is suitable for stack locals. It is not a live ref and is invalid after
/// the captured node/result is unmounted, or if mounting returns an error.
/// Use createRef + ref across regions.
pub fn capture(dest: anytype, child: anytype) RefOf(CaptureDest(@TypeOf(dest)), @TypeOf(child)) {
    return ref(CaptureDest(@TypeOf(dest)){ .dest = dest }, child);
}

fn RefOf(comptime D: type, comptime C: type) type {
    if (isComponent(C)) return @TypeOf(with(@as(C, undefined), .{}).ref(@as(D, undefined)));
    if (@hasDecl(C, "ref")) return @TypeOf(@as(C, undefined).ref(@as(D, undefined)));
    return NodeRef(D, C);
}

pub fn NodeCapture(comptime D: type, comptime Child: type) type {
    return NodeRef(CaptureDest(D), Child);
}

pub fn NodeRef(comptime D: type, comptime Child: type) type {
    comptime requireSingle(Child, "ui.view.ref");
    comptime checkRefDest(D, *Node, "a plain element (to get a component's mount result through v.attrs, write v.attrs(.., v.ref(handle, Component(..))))");
    return struct {
        dest: D,
        child: Child,

        pub const zenit_view_element = true;
        pub const view_single = true;

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const node = (try emitSingle(scope, cx, sink, self.child)) orelse return error.ViewRefNoRoot;
            try storeRef(scope, self.dest, node);
        }
    };
}

/// Static if-else: emit a or b per cond at mount (types can differ; no region, no effect).
/// For runtime-changing condition use v.show(...).fallback(...).
pub fn branch(cond: bool, a: anytype, b: anytype) Branch(@TypeOf(a), @TypeOf(b)) {
    return if (cond) .{ .a = a } else .{ .b = b };
}

pub fn Branch(comptime A: type, comptime B: type) type {
    return union(enum) {
        a: A,
        b: B,

        pub const zenit_view_element = true;
        pub const view_single = isSingleType(A) and isSingleType(B);

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            switch (self) {
                .a => |x| try emit(scope, cx, sink, x),
                .b => |x| try emit(scope, cx, sink, x),
            }
        }
    };
}

fn isSingleType(comptime T: type) bool {
    if (T == *Node) return true;
    if (isViewElement(T)) return T.view_single;
    return isComponent(T);
}

/// Mount single-node element to window float layer portal (cx.popover_portal_root, same layer as
/// Popover content),
/// declare position doesn't place node. For overlay that covers whole tree, exempt from ancestor
/// clip.
/// Content: new child scope under declare scope; when declare unloads (or mount rollback), portal
/// node recycles with it.
/// portal root is window-wide absolute container, content uses absolute + inset to position.
pub fn portal(child: anytype) Portal(@TypeOf(child)) {
    return .{ .child = child };
}

pub fn Portal(comptime Child: type) type {
    comptime requireSingle(Child, "ui.view.portal");
    return struct {
        child: Child,

        pub const zenit_view_element = true;
        /// Declare position produces no node (like show miss, no space).
        pub const view_single = false;

        /// Release with portal scope: detach first (not in declare subtree, unmount won't reach
        /// it), then
        /// recycle per "hook lose -> unbind scope -> release". Scope dispose before resource
        /// recycle,
        /// so effect in runtime content already destroyed here.
        const Mounted = struct {
            cx: *Cx,
            node: ?*Node = null,

            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *Mounted = @ptrCast(@alignCast(ptr));
                if (self.node) |n| {
                    if (n.parent) |parent| self.cx.detachChild(parent, n);
                    self.cx.freeDetachedNodeAfterScopeDispose(n);
                }
                allocator.destroy(self);
            }
        };

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, _: Sink) anyerror!void {
            const ps = try scope.childScope();
            var root: ?*Node = null;
            var stray: ?*Node = null;
            emit(ps, cx, Sink.capture(&root, &stray), self.child) catch |err| {
                control_flow.discardCaptured(cx, ps, root, stray);
                return err;
            };
            const n = root orelse {
                ps.dispose();
                return;
            };
            // Register for recycle first (node still null: on failure destroy only self), hang
            // after success.
            const mounted = ps.allocator.create(Mounted) catch |err| {
                control_flow.discardCaptured(cx, ps, n, null);
                return err;
            };
            mounted.* = .{ .cx = cx };
            ps.adoptResource(@ptrCast(mounted), Mounted.destroy) catch |err| {
                control_flow.discardCaptured(cx, ps, n, null);
                return err;
            };
            const portal_root = cx.ensurePopoverPortalRoot() catch |err| {
                control_flow.discardCaptured(cx, ps, n, null);
                return err;
            };
            portal_root.appendChild(cx.allocator, n) catch |err| {
                control_flow.discardCaptured(cx, ps, n, null);
                return err;
            };
            mounted.node = n;
        }
    };
}

/// Escape hatch: after element mounts, get its root node to do things DSL can't cover (attach
/// low-level events,
/// before_render hook, custom draw). f(ctx, node) or f(ctx, node, scope, cx), may return !void.
/// Use only when really needing node capability; standard attrs use v.attrs.
pub fn setup(child: anytype, ctx: anytype, comptime f: anytype) Setup(@TypeOf(child), @TypeOf(ctx), f) {
    return .{ .child = child, .ctx = ctx };
}

pub fn Setup(comptime Child: type, comptime Ctx: type, comptime f: anytype) type {
    comptime requireSingle(Child, "ui.view.setup");
    const nparams = @import("zenit_reflection").params(@TypeOf(f)).len;
    if (nparams != 2 and nparams != 4) @compileError("ui.view.setup: f must be fn (Ctx, *Node) or fn (Ctx, *Node, *Scope, *Cx)");
    const Ret = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return struct {
        child: Child,
        ctx: Ctx,

        pub const zenit_view_element = true;
        pub const view_single = true;

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const node = (try emitSingle(scope, cx, sink, self.child)) orelse return error.ViewSetupNoRoot;
            const r = if (nparams == 2) f(self.ctx, node) else f(self.ctx, node, scope, cx);
            if (@typeInfo(Ret) == .error_union) try r;
        }
    };
}

/// Frame info when custom drawing: frame clock time of the frame that requested this redraw
/// (animations phase accordingly,
/// low framerate doesn't slow down); theme. Time recorded at that frame's tick phase, not read
/// global clock during draw:
/// in multi-window apps windows take turns binding global clock, draw time may be other window's.
pub const Frame = struct {
    now_ms: f64,
    tokens: *const ThemeTokens,
};

/// Custom-draw element: picture = draw(ctx, data, frame).
/// v.canvas(.{ .style = S.ring }, v.paint(.{ .data = ring, .animate = true }, S.drawArc)),
/// fn drawArc(ctx: DrawContext, ring: Ring, frame: v.Frame) !void.
/// data: value or source, redraws on change (one-way; draw must not mutate state).
/// animate (bool or source): redraws per frame when on; skips off-screen, no dirty mark.
pub fn canvas(props: anytype, painter: anytype) Canvas(@TypeOf(props), @TypeOf(painter)) {
    return .{ .props = props, .painter = painter };
}

pub fn paint(opts: anytype, comptime draw_fn: anytype) Paint(PaintField(@TypeOf(opts), "data", void), PaintField(@TypeOf(opts), "animate", bool), draw_fn) {
    const O = @TypeOf(opts);
    return .{
        .data = if (@hasField(O, "data")) opts.data else {},
        .animate = if (@hasField(O, "animate")) opts.animate else false,
    };
}

fn PaintField(comptime O: type, comptime name: []const u8, comptime default: type) type {
    return if (@hasField(O, name)) @FieldType(O, name) else default;
}

pub fn Paint(comptime Data: type, comptime Animate: type, comptime draw_fn: anytype) type {
    const Value = if (Data == void) void else if (comptime isReactiveSource(Data)) SourceValue(Data) else Data;
    const info = @typeInfo(@TypeOf(draw_fn)).@"fn";
    if (@import("zenit_reflection").paramsInfo(info).len != 3 or @import("zenit_reflection").paramsInfo(info)[0].type != core.DrawContext or @import("zenit_reflection").paramsInfo(info)[1].type != Value or @import("zenit_reflection").paramsInfo(info)[2].type != Frame)
        @compileError("ui.view.paint: draw must be fn (DrawContext, " ++ @typeName(Value) ++ ", ui.view.Frame) !void");
    return struct {
        data: Data,
        animate: Animate,
        pub const V = Value;
        pub const draw = draw_fn;
    };
}

pub fn Canvas(comptime Props: type, comptime P: type) type {
    comptime checkProps(Props, &box_props, "ui.view.canvas");
    return struct {
        props: Props,
        painter: P,

        pub const zenit_view_element = true;
        pub const view_single = true;

        const Self = @This();
        const State = struct {
            node: *Node,
            cx: *Cx,
            handle: core.NodeHandle,
            data: P.V,
            animating: bool = false,
            /// Last tick's frame clock time (taken at mount from clock then).
            frame_ms: f64 = 0,

            fn drawThunk(ctx: core.DrawContext, context: ?*anyopaque) anyerror!void {
                const st: *State = @ptrCast(@alignCast(context orelse return));
                try P.draw(ctx, st.data, .{ .now_ms = st.frame_ms, .tokens = st.cx.tokens });
            }

            fn tick(node: *Node) void {
                const d = node.meta.per_frame.custom_hooks.draw orelse return;
                if (d.callback != &drawThunk) return;
                const st: *State = @ptrCast(@alignCast(d.context orelse return));
                st.frame_ms = render_engine.current_frame_time_ms;
                if (node.frame_state.state_bits.flags.out_of_viewport) return;
                node.markRenderDirty();
            }

            fn setAnimating(st: *State, on: bool) void {
                if (on == st.animating) return;
                if (on) {
                    st.node.addBeforeRender(tick);
                    st.node.markRenderDirty();
                } else st.node.removeBeforeRender(tick);
                st.animating = on;
            }

            /// Scope destroy: detach custom-draw callback and frame hook (they point to state about
            /// to release).
            fn detach(st: *State) void {
                const node = node_refs.resolveTrackedNode(&st.cx.node_registry, st.handle, st.node) orelse return;
                if (node.meta.per_frame.custom_hooks.draw) |d| {
                    if (d.context == @as(?*anyopaque, @ptrCast(st))) node.meta.per_frame.custom_hooks.draw = null;
                }
                node.removeBeforeRender(tick);
                st.animating = false;
            }

            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                allocator.destroy(@as(*State, @ptrCast(@alignCast(ptr))));
            }
        };

        pub fn viewEmit(self: Self, scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const node = (try emitSingle(scope, cx, sink, box(self.props, .{}))) orelse return error.ViewCanvasNoRoot;
            const st = try scope.allocator.create(State);
            st.* = .{
                .node = node,
                .cx = cx,
                .handle = .{ .id = node.id, .generation = 0 },
                .frame_ms = render_engine.current_frame_time_ms,
                .data = if (P.V == void) {} else if (comptime isReactiveSource(@FieldType(P, "data"))) sourceOf(P.V, "ui.view.paint data", self.painter.data).peek() else self.painter.data,
            };
            try scope.adoptResource(@ptrCast(st), State.destroy);
            st.handle.generation = try cx.node_registry.trackGeneration(node);
            // Register unlink first, then post callback: OOM leaves no callback pointing to freed
            // state.
            try scope.onCleanup(State, st, State.detach);
            node.setCustomDraw(State.drawThunk, @ptrCast(st));

            if (comptime P.V != void and isReactiveSource(@FieldType(P, "data"))) {
                const src = sourceOf(P.V, "ui.view.paint data", self.painter.data);
                if (!src.isStatic()) try scope.createEffect(.{ .st = st, .src = src }, struct {
                    fn run(c: anytype) void {
                        c.st.data = c.src.get();
                        c.st.node.markRenderDirty();
                    }
                }.run);
            }
            const anim = sourceOf(bool, "ui.view.paint animate", self.painter.animate);
            if (anim.isStatic()) {
                st.setAnimating(anim.peek());
            } else try scope.createEffect(.{ .st = st, .src = anim }, struct {
                fn run(c: anytype) void {
                    c.st.setAnimating(c.src.get());
                }
            }.run);
        }
    };
}

/// Static list: invoke f once per array element (compile-time length), get element array, expand in
/// place (no region, no effect).
/// v.list(&specs, variantButton), f: fn (T) E or fn (T, usize) E. For runtime-changing data use
/// v.each.
pub fn list(arr: anytype, comptime f: anytype) [arrayLen(@TypeOf(arr))]ListElem(f) {
    return listImpl({}, arr, f);
}

/// Expand runtime slice items as sibling nodes (one-time at mount, no region, no effect):
/// v.items(ctx, rows, row), f: fn (Ctx, T) E / fn (Ctx, T, usize) E (ctx omitted when passed {}).
/// Unlike list, no
/// compile-time length required, don't generate element array; for runtime-changing data use
/// v.each.
pub fn items(ctx: anytype, slice: anytype, comptime f: anytype) ItemsOf(@TypeOf(ctx), @TypeOf(slice), f) {
    return .{ .ctx = ctx, .slice = slice };
}

pub fn ItemsOf(comptime Ctx: type, comptime Slice: type, comptime f: anytype) type {
    const lead: usize = if (Ctx == void) 1 else 2;
    const nparams = @import("zenit_reflection").params(@TypeOf(f)).len;
    if (nparams != lead and nparams != lead + 1)
        @compileError("ui.view.items: f must be fn (" ++ (if (Ctx == void) "" else "Ctx, ") ++ "T) E or fn (" ++ (if (Ctx == void) "" else "Ctx, ") ++ "T, usize) E");
    return struct {
        ctx: Ctx,
        slice: Slice,

        pub const zenit_view_element = true;
        pub const view_single = false;

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            for (self.slice, 0..) |item, i| {
                const elem = if (Ctx == void)
                    (if (nparams == 1) f(item) else f(item, i))
                else
                    (if (nparams == 2) f(self.ctx, item) else f(self.ctx, item, i));
                try emit(scope, cx, sink, elem);
            }
        }
    };
}

/// Expand by count (one-time at mount): v.repeat(ctx, n, f), f: fn (Ctx, usize) E (omit ctx when
/// passed {}). n is integer
/// or integer source: when source changes, rebuild all (rows have no identity, nothing retained).
pub fn repeat(ctx: anytype, n: anytype, comptime f: anytype) RepeatOf(@TypeOf(ctx), RepeatCount(@TypeOf(n)), f) {
    // When count is integer, clamp to [0, inf) and cast to usize here (literal is comptime type,
    // can't store in field).
    if (comptime @typeInfo(@TypeOf(n)) == .int or @typeInfo(@TypeOf(n)) == .comptime_int) return .{ .ctx = ctx, .n = @intCast(@max(n, 0)) };
    return .{ .ctx = ctx, .n = n };
}

fn RepeatCount(comptime N: type) type {
    return if (@typeInfo(N) == .int or @typeInfo(N) == .comptime_int) usize else N;
}

pub fn RepeatOf(comptime Ctx: type, comptime N: type, comptime f: anytype) type {
    const Count = if (N == usize) usize else SourceValue(N);
    if (@typeInfo(Count) != .int) @compileError("ui.view.repeat: n must be an integer or an integer source, got " ++ @typeName(N));
    return struct {
        ctx: Ctx,
        n: N,

        pub const zenit_view_element = true;
        pub const view_single = false;

        const params = @import("zenit_reflection").params(@TypeOf(f));
        const ctx_params: usize = if (Ctx == void) 0 else 1;
        /// Component-form row: fn ([Ctx,] usize, *Scope, *Cx) !*Node (Yix {for} generates this).
        const component_row = params.len == ctx_params + 3 and params[params.len - 2].type == *Scope and params[params.len - 1].type == *Cx;

        fn emitRows(ctx: Ctx, scope: *Scope, cx: *Cx, sink: Sink, n: Count) anyerror!void {
            var i: usize = 0;
            const total: usize = @intCast(@max(n, 0));
            while (i < total) : (i += 1) {
                if (component_row) {
                    const node = if (Ctx == void) try f(i, scope, cx) else try f(ctx, i, scope, cx);
                    try sink.insert(cx, node);
                } else try emit(scope, cx, sink, if (Ctx == void) f(i) else f(ctx, i));
            }
        }

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            if (comptime N == usize) return emitRows(self.ctx, scope, cx, sink, self.n);
            const src = sourceOf(Count, "ui.view.repeat count", self.n);
            const R = control_flow.SwitchRegion(Count, Ctx, emitRows);
            if (src.isStatic()) return control_flow.callUntracked(cx, R.emitOnce, .{ self.ctx, scope, cx, sink, src.peek() });
            _ = try R.mount(scope, cx, sink, src, self.ctx);
        }
    };
}

/// Same as list, row function takes extra context: fn (Ctx, T) E or fn (Ctx, T, usize) E.
pub fn listWith(ctx: anytype, arr: anytype, comptime f: anytype) [arrayLen(@TypeOf(arr))]ListElem(f) {
    return listImpl(ctx, arr, f);
}

fn listImpl(ctx: anytype, arr: anytype, comptime f: anytype) [arrayLen(@TypeOf(arr))]ListElem(f) {
    const Ctx = @TypeOf(ctx);
    const nparams = @import("zenit_reflection").params(@TypeOf(f)).len;
    const base: usize = if (Ctx == void) 0 else 1;
    if (nparams != base + 1 and nparams != base + 2) @compileError("ui.view.list: f must take (" ++ (if (Ctx == void) "" else "Ctx, ") ++ "T) or (" ++ (if (Ctx == void) "" else "Ctx, ") ++ "T, usize)");
    var out: [arrayLen(@TypeOf(arr))]ListElem(f) = undefined;
    for (arr, 0..) |item, i| {
        out[i] = if (Ctx == void)
            (if (nparams == 1) f(item) else f(item, i))
        else
            (if (nparams == 2) f(ctx, item) else f(ctx, item, i));
    }
    return out;
}

fn arrayLen(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .array => |a| a.len,
        .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .array) @typeInfo(p.child).array.len else @compileError("ui.view.list: items must be an array or a pointer to an array (compile-time length); use v.each for slices / signals"),
        else => @compileError("ui.view.list: items must be an array or a pointer to an array (compile-time length); use v.each for slices / signals"),
    };
}

fn ListElem(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type orelse
        @compileError("ui.view.list: f must have a concrete return type (no anytype parameters)");
}

// Elements: control flow

/// Conditional render: v.show(cond, .{ ... }), chains .fallback(.{ ... }).
/// cond is bool or any bool reactive source (ui.not(x) / ui.eq(page, .home) ...).
/// Content fixed at show position.
pub fn show(cond: anytype, children: anytype) Show(@TypeOf(cond), @TypeOf(children), void) {
    return .{ .cond = cond, .then = children, .otherwise = {} };
}

pub fn Show(comptime Cond: type, comptime Then: type, comptime Else: type) type {
    return struct {
        cond: Cond,
        then: Then,
        otherwise: Else,

        pub const zenit_view_element = true;
        pub const view_single = false;
        const Ctx = struct { then: Then, otherwise: Else };

        /// Content shown when condition not met.
        pub fn fallback(self: @This(), children: anytype) Show(Cond, Then, @TypeOf(children)) {
            return .{ .cond = self.cond, .then = self.then, .otherwise = children };
        }

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const R = control_flow.SwitchRegion(bool, Ctx, struct {
                fn e(ctx: Ctx, s: *Scope, c: *Cx, sk: Sink, visible: bool) anyerror!void {
                    if (visible) try emit(s, c, sk, ctx.then) else try emit(s, c, sk, ctx.otherwise);
                }
            }.e);
            const src = sourceOf(bool, "ui.view.show condition", self.cond);
            // Static condition (including component-received static prop): emit only true branch,
            // no region, no effect.
            if (src.isStatic()) return control_flow.callUntracked(cx, R.emitOnce, .{ Ctx{ .then = self.then, .otherwise = self.otherwise }, scope, cx, sink, src.peek() });
            _ = try R.mount(scope, cx, sink, src, .{ .then = self.then, .otherwise = self.otherwise });
        }
    };
}

/// Enum branch: v.match(page, .{ .home = HomePage(...), .settings = .{ ... } }).
/// Every enum value must have a branch, or provide .@"else".
pub fn match(value: anytype, cases: anytype) Match(SourceValue(@TypeOf(value)), @TypeOf(value), @TypeOf(cases)) {
    return .{ .value = value, .cases = cases };
}

pub fn Match(comptime T: type, comptime V: type, comptime Cases: type) type {
    comptime checkCases(T, Cases);
    return struct {
        value: V,
        cases: Cases,

        pub const zenit_view_element = true;
        pub const view_single = false;

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const R = control_flow.SwitchRegion(T, Cases, struct {
                fn e(cases: Cases, s: *Scope, c: *Cx, sk: Sink, v: T) anyerror!void {
                    inline for (@import("zenit_reflection").fields(T)) |ef| {
                        if (@backingInt(v) == ef.value) {
                            if (@hasField(Cases, ef.name)) return emit(s, c, sk, @field(cases, ef.name));
                            return emit(s, c, sk, @field(cases, "else"));
                        }
                    }
                    unreachable;
                }
            }.e);
            const src = sourceOf(T, "ui.view.match value", self.value);
            if (src.isStatic()) return control_flow.callUntracked(cx, R.emitOnce, .{ self.cases, scope, cx, sink, src.peek() });
            _ = try R.mount(scope, cx, sink, src, self.cases);
        }
    };
}

/// Render by source's current value: unmount old content on value change, rebuild with
/// render(value, scope, cx)
/// (parallel to Solid's <Dynamic>). v.match requires enum, every branch different element; large
/// value domain or
/// data-driven branch? use it.
pub fn dynamic(src: anytype, comptime render_fn: anytype) Dynamic(SourceValue(@TypeOf(src)), @TypeOf(src), render_fn) {
    return .{ .src = src };
}

pub fn Dynamic(comptime T: type, comptime Src: type, comptime render_fn: anytype) type {
    const params = @import("zenit_reflection").params(@TypeOf(render_fn));
    if (params.len != 3 or params[1].type != *Scope or params[2].type != *Cx)
        @compileError("ui.view.dynamic: render must be fn (T, *Scope, *Cx) !*Node");
    return struct {
        src: Src,

        pub const zenit_view_element = true;
        pub const view_single = false;

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const R = control_flow.SwitchRegion(T, void, struct {
                fn e(_: void, s: *Scope, c: *Cx, sk: Sink, value: T) anyerror!void {
                    try sk.insert(c, try render_fn(value, s, c));
                }
            }.e);
            const src = sourceOf(T, "ui.view.dynamic source", self.src);
            if (src.isStatic()) return control_flow.callUntracked(cx, R.emitOnce, .{ {}, scope, cx, sink, src.peek() });
            _ = try R.mount(scope, cx, sink, src, {});
        }
    };
}

/// Parse all slot config's slots at once:
/// v.slotParts(S.Tag, .{ .color = color, .kind = kind, .size = size }) returns each slot's style
/// parts
/// (p.root / p.label ...), one set of dimensions drives all slots. Requires all config dimensions
/// (even with
/// defaults write them): missing dimension is compile error, not silent default. Dimension values
/// can be source.
pub fn slotParts(comptime R: type, args: anytype) @TypeOf(R.of(args)) {
    comptime checkPartsArgs(R, @TypeOf(args));
    return R.of(args);
}

fn checkPartsArgs(comptime R: type, comptime Args: type) void {
    @setEvalBranchQuota(20_000);
    if (!@hasDecl(R, "Slots") or !@hasDecl(R, "of")) @compileError("ui.view.slotParts: expected a slotted recipe (ui.sva / YSS recipe with slots), got " ++ @typeName(R));
    for (@import("zenit_reflection").fields(R.Variants)) |d| {
        if (!@hasField(Args, d.name)) @compileError("ui.view.slotParts: missing dimension ." ++ d.name ++ " — give every dimension of the recipe (write the default explicitly)");
    }
}

// -- Lazy branches (Yix control flow codegen target) --
// Branch content as function fn (Ctx, *Scope, *Cx, Sink) anyerror!void: branch builds in own scope
// when selected,
// branch's derived values / event context own this scope, swap branches and release together (show
// / match content built before mount).

/// Lazy if: v.lazyIf(cond, ctx, then_fn, else_fn); else_fn can be null.
pub fn lazyIf(cond: anytype, ctx: anytype, comptime then_fn: anytype, comptime else_fn: anytype) LazyIf(@TypeOf(cond), @TypeOf(ctx), then_fn, else_fn) {
    return .{ .cond = cond, .ctx = ctx };
}

pub fn LazyIf(comptime Cond: type, comptime Ctx: type, comptime then_fn: anytype, comptime else_fn: anytype) type {
    return struct {
        cond: Cond,
        ctx: Ctx,

        pub const zenit_view_element = true;
        pub const view_single = false;

        fn emitBranch(ctx: Ctx, s: *Scope, c: *Cx, sk: Sink, yes: bool) anyerror!void {
            if (yes) return then_fn(ctx, s, c, sk);
            if (@TypeOf(else_fn) != @TypeOf(null)) return else_fn(ctx, s, c, sk);
        }

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const R = control_flow.SwitchRegion(bool, Ctx, emitBranch);
            const src = sourceOf(bool, "ui.view.lazyIf condition", self.cond);
            if (src.isStatic()) return control_flow.callUntracked(cx, R.emitOnce, .{ self.ctx, scope, cx, sink, src.peek() });
            _ = try R.mount(scope, cx, sink, src, self.ctx);
        }
    };
}

/// Lazy if capture: source is optional or error union. When has value then_fn(ctx, v, scope, cx,
/// sink), v is
/// branchValue payload source; else else_fn(ctx, scope, cx, sink), error union else can take error
/// source else_fn(ctx, err, scope, cx, sink);
/// else_fn can be null.
pub fn lazyIfSome(src: anytype, ctx: anytype, comptime then_fn: anytype, comptime else_fn: anytype) LazyIfSome(SourceValue(@TypeOf(src)), @TypeOf(src), @TypeOf(ctx), then_fn, else_fn) {
    return .{ .src = src, .ctx = ctx };
}

pub fn LazyIfSome(comptime T: type, comptime Src: type, comptime Ctx: type, comptime then_fn: anytype, comptime else_fn: anytype) type {
    return struct {
        src: Src,
        ctx: Ctx,

        pub const zenit_view_element = true;
        pub const view_single = false;
        const State = struct { ctx: Ctx, src: reactive.Source(T) };

        fn emitBranch(st: State, s: *Scope, c: *Cx, sk: Sink, present: bool) anyerror!void {
            if (present) return then_fn(st.ctx, try branchValue(s, st.src, someOf), s, c, sk);
            if (@TypeOf(else_fn) == @TypeOf(null)) return;
            if (@import("zenit_reflection").params(@TypeOf(else_fn)).len == 5) return else_fn(st.ctx, try branchValue(s, st.src, errOf), s, c, sk);
            return else_fn(st.ctx, s, c, sk);
        }

        fn someOf(x: T) ?Payload(T) {
            return if (@typeInfo(T) == .optional) x else x catch null;
        }
        fn errOf(x: T) ?ErrorOf(T) {
            if (x) |_| return null else |e| return e;
        }
        fn presence(x: T) bool {
            return someOf(x) != null;
        }

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const R = control_flow.SwitchRegion(bool, State, emitBranch);
            const src = sourceOf(T, "ui.view.lazyIfSome source", self.src);
            const st: State = .{ .ctx = self.ctx, .src = src };
            if (src.isStatic()) return control_flow.callUntracked(cx, R.emitOnce, .{ st, scope, cx, sink, presence(src.peek()) });
            const has = try scope.derive(bool, src, struct {
                fn compute(x: reactive.Source(T)) bool {
                    return presence(x.get());
                }
            }.compute);
            _ = try R.mount(scope, cx, sink, has, st);
        }
    };
}

fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        .error_union => |e| e.payload,
        else => @compileError("Yix {if (x) |v| …}: x must be an optional or an error union, got " ++ @typeName(T)),
    };
}

fn ErrorOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |e| e.error_set,
        else => @compileError("Yix {if (x) |v| …} else |e| …: only an error union has an error to capture, got " ++ @typeName(T)),
    };
}

/// Lazy switch: source is enum or tagged union, switch by tag, f(ctx, tag, src, scope, cx, sink)
/// emit that tag's content
/// (union payload via v.branchValue(scope, src, v.payloadOf(U, .tag))). Same tag, payload change
/// doesn't rebuild branch.
pub fn lazySwitch(src: anytype, ctx: anytype, comptime f: anytype) LazySwitch(SourceValue(@TypeOf(src)), @TypeOf(src), @TypeOf(ctx), f) {
    return .{ .src = src, .ctx = ctx };
}

pub fn LazySwitch(comptime T: type, comptime Src: type, comptime Ctx: type, comptime f: anytype) type {
    const Tag = switch (@typeInfo(T)) {
        .@"enum" => T,
        .@"union" => |u| u.tag_type orelse @compileError("Yix {switch}: union " ++ @typeName(T) ++ " needs a tag (union(enum))"),
        else => @compileError("Yix {switch}: the value must be an enum or a tagged union, got " ++ @typeName(T)),
    };
    return struct {
        src: Src,
        ctx: Ctx,

        pub const zenit_view_element = true;
        pub const view_single = false;
        const State = struct { ctx: Ctx, src: reactive.Source(T) };

        fn emitBranch(st: State, s: *Scope, c: *Cx, sk: Sink, tag: Tag) anyerror!void {
            return f(st.ctx, tag, st.src, s, c, sk);
        }
        fn tagOf(x: T) Tag {
            return if (@typeInfo(T) == .@"enum") x else std.meta.activeTag(x);
        }

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const R = control_flow.SwitchRegion(Tag, State, emitBranch);
            const src = sourceOf(T, "ui.view.lazySwitch value", self.src);
            const st: State = .{ .ctx = self.ctx, .src = src };
            if (src.isStatic()) return control_flow.callUntracked(cx, R.emitOnce, .{ st, scope, cx, sink, tagOf(src.peek()) });
            const tag = try scope.derive(Tag, src, struct {
                fn compute(x: reactive.Source(T)) Tag {
                    return tagOf(x.get());
                }
            }.compute);
            _ = try R.mount(scope, cx, sink, tag, st);
        }
    };
}

/// Payload extract for union U's tag branch (use with branchValue).
pub fn payloadOf(comptime U: type, comptime tag: std.meta.Tag(U)) fn (U) ?@FieldType(U, @tagName(tag)) {
    return struct {
        fn f(u: U) ?@FieldType(U, @tagName(tag)) {
            return if (std.meta.activeTag(u) == tag) @field(u, @tagName(tag)) else null;
        }
    }.f;
}

/// Capture value in branch ({if (x) |v|} v, .a => |p| p): follows payload in source. When source no
/// longer matches
/// (branch about to unmount, branch effect may run before region rebuild) hold last value. Source
/// static?
/// just static value, no memo.
pub fn branchValue(scope: *Scope, src: anytype, comptime extract: anytype) !reactive.Source(CaptureOf(extract)) {
    const P = CaptureOf(extract);
    const first = extract(src.peek()) orelse return error.CaptureWithoutValue;
    if (src.isStatic()) return .of(first);
    const Last = struct {
        src: @TypeOf(src),
        last: P,
        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            allocator.destroy(@as(*@This(), @ptrCast(@alignCast(ptr))));
        }
    };
    const last = try scope.allocator.create(Last);
    last.* = .{ .src = src, .last = first };
    try scope.adoptResource(@ptrCast(last), Last.destroy);
    return .{ .memo = try scope.createMemo(P, last, struct {
        fn compute(b: *Last) P {
            if (extract(b.src.get())) |v| b.last = v;
            return b.last;
        }
    }.compute) };
}

fn CaptureOf(comptime extract: anytype) type {
    const R = @typeInfo(@TypeOf(extract)).@"fn".return_type.?;
    return @typeInfo(R).optional.child;
}

fn checkCases(comptime T: type, comptime Cases: type) void {
    if (@typeInfo(T) != .@"enum") @compileError("ui.view.match: value must be an enum (or a reactive source of one), got " ++ @typeName(T));
    const has_else = @hasField(Cases, "else");
    for (@import("zenit_reflection").fields(Cases)) |cf| {
        if (std.mem.eql(u8, cf.name, "else")) continue;
        if (!@hasField(T, cf.name)) @compileError("ui.view.match: " ++ @typeName(T) ++ " has no tag ." ++ cf.name);
    }
    if (!has_else) {
        for (@import("zenit_reflection").fields(T)) |ef| {
            if (!@hasField(Cases, ef.name)) @compileError("ui.view.match: missing case ." ++ ef.name ++ " (add it or an .@\"else\" branch)");
        }
    }
}

/// List: v.each(items, .id, todoRow).
/// - items: `[]const T` slice / array pointer, or any `[]const T` reactive source;
/// - key: .field_name (int / enum / string field) or fn (T) u64;
/// - row function, two forms:
///   - view function fn (T) E / fn (T, usize) E, E is a single-node element;
///   - component function fn (T, *Scope, *Cx) !*Node (use ui.on.bind when the row builds a
///     signal); the body returns v.render(scope, cx, ...).
///   When a row needs an outside value, use eachWith.
pub fn each(arr: anytype, comptime key: anytype, comptime row_fn: anytype) Each(ItemOf(@TypeOf(arr)), @TypeOf(arr), void, key, row_fn) {
    return .{ .items = arr, .ctx = {} };
}

/// Same as each, row function's first param takes extra context: fn (Ctx, T) E / fn (Ctx, T, usize)
/// E /
/// fn (Ctx, T, *Scope, *Cx) !*Node.
pub fn eachWith(ctx: anytype, arr: anytype, comptime key: anytype, comptime row_fn: anytype) Each(ItemOf(@TypeOf(arr)), @TypeOf(arr), @TypeOf(ctx), key, row_fn) {
    return .{ .items = arr, .ctx = ctx };
}

pub fn Each(comptime T: type, comptime Items: type, comptime Ctx: type, comptime key: anytype, comptime row_fn: anytype) type {
    const params = @import("zenit_reflection").params(@TypeOf(row_fn));
    const nparams = params.len;
    const ctx_params: usize = if (Ctx == void) 0 else 1;
    // Component form: last two params are (*Scope, *Cx); can take extra index source after T
    // (follows new position after reorder).
    const component_tail = nparams >= 2 and params[nparams - 2].type == *Scope and params[nparams - 1].type == *Cx;
    // Row gets data source Source(T) (can take index source): same key content changes update in
    // place, don't rebuild row.
    const source_row = component_tail and params[ctx_params].type == reactive.Source(T);
    const source_indexed = source_row and nparams == ctx_params + 4 and params[ctx_params + 1].type == reactive.Source(usize);
    const component_row = component_tail and nparams == ctx_params + 3 and !source_row;
    const indexed_row = component_tail and nparams == ctx_params + 4 and params[ctx_params + 1].type == reactive.Source(usize) and !source_row;
    if (source_row and nparams != ctx_params + 3 and !source_indexed) @compileError("ui.view.each: a source row is fn (" ++ (if (Ctx == void) "" else "Ctx, ") ++ "Source(T), [Source(usize),] *Scope, *Cx) !*Node");
    const ctx_sig = if (Ctx == void) "" else "Ctx, ";
    if (!source_row and !component_row and !indexed_row and nparams != ctx_params + 1 and nparams != ctx_params + 2)
        @compileError("ui.view.each: row function must be fn (" ++ ctx_sig ++ "T) E, fn (" ++ ctx_sig ++ "T, usize) E, fn (" ++ ctx_sig ++ "T, *Scope, *Cx) !*Node, or fn (" ++ ctx_sig ++ "T, Source(usize), *Scope, *Cx) !*Node");
    const RowRet = @typeInfo(@TypeOf(row_fn)).@"fn".return_type.?;
    const RowElem = switch (@typeInfo(RowRet)) {
        .error_union => |eu| eu.payload,
        else => RowRet,
    };
    comptime requireSingle(RowElem, "ui.view.each row");

    return struct {
        items: Items,
        ctx: Ctx,

        pub const zenit_view_element = true;
        pub const view_single = false;

        fn emitIndexedRow(ctx: Ctx, s: *Scope, c: *Cx, sk: Sink, item: T, index: reactive.Source(usize)) anyerror!void {
            const node = if (Ctx == void) try row_fn(item, index, s, c) else try row_fn(ctx, item, index, s, c);
            return sk.insert(c, node);
        }

        fn emitSourceRow(ctx: Ctx, s: *Scope, c: *Cx, sk: Sink, item: reactive.Source(T), index: reactive.Source(usize)) anyerror!void {
            const node = if (source_indexed)
                (if (Ctx == void) try row_fn(item, index, s, c) else try row_fn(ctx, item, index, s, c))
            else
                (if (Ctx == void) try row_fn(item, s, c) else try row_fn(ctx, item, s, c));
            return sk.insert(c, node);
        }

        fn emitRow(ctx: Ctx, s: *Scope, c: *Cx, sk: Sink, item: T, idx: usize) anyerror!void {
            if (source_row) return emitSourceRow(ctx, s, c, sk, .{ .value = item }, .{ .value = idx });
            if (indexed_row) return emitIndexedRow(ctx, s, c, sk, item, .{ .value = idx });
            if (component_row) {
                const node = if (Ctx == void) try row_fn(item, s, c) else try row_fn(ctx, item, s, c);
                return sk.insert(c, node);
            }
            const r = if (Ctx == void)
                (if (nparams == 1) row_fn(item) else row_fn(item, idx))
            else
                (if (nparams == 2) row_fn(ctx, item) else row_fn(ctx, item, idx));
            const elem = if (@typeInfo(RowRet) == .error_union) try r else r;
            try emit(s, c, sk, elem);
        }

        const Region = if (source_row) control_flow.ForRegion(T, Ctx, .{
            .key_fn = keyFnFor(T, key),
            .render_source_fn = struct {
                fn r(ctx: Ctx, s: *Scope, c: *Cx, sk: Sink, item: *Signal(T), index: *Signal(usize)) anyerror!void {
                    return emitSourceRow(ctx, s, c, sk, .{ .signal = item }, .{ .signal = index });
                }
            }.r,
        }) else if (indexed_row) control_flow.ForRegion(T, Ctx, .{
            .key_fn = keyFnFor(T, key),
            .render_index_fn = struct {
                fn r(ctx: Ctx, s: *Scope, c: *Cx, sk: Sink, item: T, sig: *Signal(usize)) anyerror!void {
                    return emitIndexedRow(ctx, s, c, sk, item, .{ .signal = sig });
                }
            }.r,
        }) else control_flow.ForRegion(T, Ctx, .{
            .key_fn = keyFnFor(T, key),
            .render_fn = emitRow,
        });

        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: Sink) anyerror!void {
            const src = sourceOf([]const T, "ui.view.each items", self.items);
            // Static list: emit once per item, no region or effect (matches show / match static
            // path).
            if (src.isStatic()) {
                for (src.peek(), 0..) |item, i| try control_flow.callUntracked(cx, emitRow, .{ self.ctx, scope, cx, sink, item, i });
                return;
            }
            _ = try Region.mount(scope, cx, sink, src, self.ctx);
        }
    };
}

fn ItemOf(comptime Items: type) type {
    const S = if (isReactiveSource(Items)) reactive.SourceValueOf(Items) else Items;
    const info = @typeInfo(S);
    if (info == .pointer) {
        switch (info.pointer.size) {
            .slice => return info.pointer.child,
            .one => if (@typeInfo(info.pointer.child) == .array) return @typeInfo(info.pointer.child).array.child,
            else => {},
        }
    }
    @compileError("ui.view.each: items must be a slice, a pointer to an array, or a reactive source of []const T; got " ++ @typeName(Items));
}

/// List key for any value (Yix {for} row's key={...}): deep hash by content, slice by element
/// content.
pub fn keyOf(v: anytype) u64 {
    var h = std.hash.Wyhash.init(0);
    std.hash.autoHashStrat(&h, v, .Deep);
    return h.final();
}

fn keyFnFor(comptime T: type, comptime key: anytype) fn (T) u64 {
    const K = @TypeOf(key);
    if (K == @TypeOf(.enum_literal)) {
        const name = @tagName(key);
        if (!@hasField(T, name)) @compileError("ui.view.each: " ++ @typeName(T) ++ " has no field ." ++ name ++ " to use as key");
        return struct {
            fn k(item: T) u64 {
                return keyHash(@field(item, name));
            }
        }.k;
    }
    return key;
}

fn keyHash(v: anytype) u64 {
    const V = @TypeOf(v);
    switch (@typeInfo(V)) {
        .int => |i| {
            if (i.bits > 64) @compileError("ui.view.each: integer keys wider than 64 bits are not supported");
            const U = @Int(.unsigned, i.bits);
            return @as(u64, @as(U, @bitCast(v)));
        },
        .@"enum" => return keyHash(@backingInt(v)),
        .pointer => |p| {
            const elem = switch (p.size) {
                .slice => p.child,
                .one => if (@typeInfo(p.child) == .array) @typeInfo(p.child).array.child else void,
                else => void,
            };
            if (elem != u8) @compileError("ui.view.each: key field type " ++ @typeName(V) ++ " is not a string; pass a fn (T) u64 instead");
            const bytes: []const u8 = v;
            return std.hash.Wyhash.hash(0, bytes);
        },
        else => @compileError("ui.view.each: key field type " ++ @typeName(V) ++ " is not hashable; pass a fn (T) u64 instead"),
    }
}

// Callback-style components (VirtualList row / Table cell / Grid pooled cell)

/// Callback-form view function: f([ctx,] args...) element, or component form
/// f([ctx,] args..., *Scope, *Cx) !*Node. lead = ctx (non-void) + args count.
pub fn callbackIsComponent(comptime F: type, comptime lead: usize, comptime what: []const u8) bool {
    const params = @import("zenit_reflection").params(F);
    if (params.len == lead) return false;
    if (params.len == lead + 2 and params[lead].type == *Scope and params[lead + 1].type == *Cx) return true;
    @compileError(what ++ ": expected fn taking " ++ std.fmt.comptimePrint("{d}", .{lead}) ++
        " argument(s) returning a view element, or the same plus (*Scope, *Cx) returning !*Node");
}

fn callbackArgs(ctx: anytype, args: anytype) CallbackArgs(@TypeOf(ctx), @TypeOf(args)) {
    if (@TypeOf(ctx) == void) return args;
    var out: CallbackArgs(@TypeOf(ctx), @TypeOf(args)) = undefined;
    out[0] = ctx;
    inline for (0..@import("zenit_reflection").fields(@TypeOf(args)).len) |i| out[i + 1] = args[i];
    return out;
}

/// .{ctx} ++ args type (assemble by field type, can't use undefined value to infer type -- becomes
/// comptime field).
fn CallbackArgs(comptime Ctx: type, comptime Args: type) type {
    if (Ctx == void) return Args;
    const fields = @import("zenit_reflection").fields(Args);
    var arg_types: [fields.len + 1]type = undefined;
    arg_types[0] = Ctx;
    for (fields, 0..) |f, i| arg_types[i + 1] = f.type;
    return @Tuple(&arg_types);
}

/// Call callback-form view function and emit result into sink (omit ctx when void).
pub fn emitCallback(comptime f: anytype, ctx: anytype, args: anytype, scope: *Scope, cx: *Cx, sink: Sink, comptime what: []const u8) anyerror!void {
    const lead = callbackArgs(ctx, args);
    if (comptime callbackIsComponent(@TypeOf(f), @import("zenit_reflection").fields(@TypeOf(lead)).len, what)) {
        const n = try @call(.auto, f, lead ++ .{ scope, cx });
        return sink.insert(cx, n);
    }
    const elem = @call(.auto, f, lead);
    comptime requireSingle(@TypeOf(elem), what);
    try emit(scope, cx, sink, elem);
}

/// Mount callback-form view into component-provided node (pooled row / cell): open child scope
/// under parent_scope,
/// mount, scope binds to element root -- when component clears / recycles node (freeNode), effect
/// inside element
/// destroys with it. On failure, all nodes + scopes from this call recycle, node unchanged, error
/// passes through.
pub fn renderInto(parent_scope: *Scope, cx: *Cx, node: *Node, comptime f: anytype, ctx: anytype, args: anytype, comptime what: []const u8) !void {
    const rs = try parent_scope.childScope();
    var root: ?*Node = null;
    var stray: ?*Node = null;
    emitCallback(f, ctx, args, rs, cx, Sink.capture(&root, &stray), what) catch |err| {
        control_flow.discardCaptured(cx, rs, root, stray);
        return err;
    };
    const n = root orelse {
        rs.dispose();
        return;
    };
    // Bind scope first (fail: n stays floating, caller recycles by capture), then insert into
    // component node.
    Cx.bindScopeToNode(rs, n) catch |err| {
        control_flow.discardCaptured(cx, rs, n, null);
        return err;
    };
    node.appendChild(cx.allocator, n) catch |err| {
        control_flow.discardCaptured(cx, rs, n, null);
        return err;
    };
}

/// Callback-form component view state: mount scope + user ctx, belong to caller scope (release with
/// it).
pub fn CallbackState(comptime Ctx: type) type {
    return struct {
        scope: *Scope,
        ctx: Ctx,

        const Self = @This();

        pub fn create(scope: *Scope, ctx: Ctx) !*Self {
            const st = try scope.allocator.create(Self);
            st.* = .{ .scope = scope, .ctx = ctx };
            // adoptResource failure: destroy itself.
            try scope.adoptResource(@ptrCast(st), destroy);
            return st;
        }

        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            allocator.destroy(@as(*Self, @ptrCast(@alignCast(ptr))));
        }
    };
}

// Style utilities

/// When cond true, stack part (style function or literal, must be compile-time known). cond is bool
/// or bool source.
pub fn when(cond: anytype, comptime part: anytype) When(@TypeOf(cond), part) {
    return .{ .cond = cond };
}

pub fn When(comptime Cond: type, comptime part_value: anytype) type {
    return struct {
        cond: Cond,
        pub const zenit_style_part = .when;
        pub const part = part_value;
    };
}

/// When mouse hovers, stack part (must be compile-time known).
pub fn hover(comptime part: anytype) Hover(part) {
    return .{};
}

pub fn Hover(comptime part_value: anytype) type {
    return struct {
        pub const zenit_style_part = .hover;
        pub const part = part_value;
    };
}

/// Style = f(source's current value, tokens): v.styleBy(size, S.sized),
/// fn sized(s: Size, t: *const ThemeTokens) BoxStyle (text element returns TextStyle).
pub fn styleBy(src: anytype, comptime f: anytype) StyleBy(@TypeOf(src), f) {
    return .{ .src = src };
}

pub fn StyleBy(comptime Src: type, comptime f_value: anytype) type {
    return struct {
        src: Src,
        pub const zenit_style_part = .style_by;
        pub const f = f_value;
        pub const Arg = @import("zenit_reflection").params(@TypeOf(f_value))[0].type.?;
        pub const Out = @typeInfo(@TypeOf(f_value)).@"fn".return_type.?;
    };
}

/// Style looping over time: v.loop(.{ .period_ms = 2000, .on = animate }, S.shimmer),
/// fn shimmer(phase: f32, t: *const ThemeTokens) BoxStyle, phase in [0, 1).
/// Phase derives from the frame clock's wall-clock time (low framerate doesn't slow it).
/// .on is optional (default always on), can be a bool source. When on, the node re-evaluates
/// style every frame, changing only affected fields; off-screen it neither advances nor marks
/// dirty (idle gate unaffected). When off, the layer withdraws and fields return to rest values.
pub fn loop(opts: anytype, comptime f: anytype) Loop(LoopOn(@TypeOf(opts)), f) {
    return .{ .period_ms = opts.period_ms, .on = if (@hasField(@TypeOf(opts), "on")) opts.on else true };
}

fn LoopOn(comptime Opts: type) type {
    return if (@hasField(Opts, "on")) @FieldType(Opts, "on") else bool;
}

pub fn Loop(comptime On: type, comptime f_value: anytype) type {
    const info = @typeInfo(@TypeOf(f_value)).@"fn";
    if (@import("zenit_reflection").paramsInfo(info).len != 2 or @import("zenit_reflection").paramsInfo(info)[0].type != f32 or @import("zenit_reflection").paramsInfo(info)[1].type != *const ThemeTokens or info.return_type != BoxStyle)
        @compileError("ui.view.loop: f must be fn (phase: f32, *const ThemeTokens) BoxStyle");
    return struct {
        period_ms: f32,
        on: On,
        pub const zenit_style_part = .loop;
        pub const f = f_value;
    };
}

/// Loop phase at current frame clock, in [0, 1).
fn loopPhase(period_ms: f32) f32 {
    if (!(period_ms > 0)) return 0;
    const now = render_engine.current_frame_time_ms;
    const p: f64 = @floatCast(period_ms);
    return @floatCast(@mod(now, p) / p);
}

/// Whether style description has v.loop (compile-time).
fn specLoop(comptime T: type) bool {
    if (partKind(T)) |k| {
        if (k == .when and specLoop(@TypeOf(T.part))) @compileError("ui.view.loop: put the loop directly in the style (it has its own .on switch), not inside v.when");
        return k == .loop;
    }
    if (isTuple(T)) {
        for (@import("zenit_reflection").fields(T)) |f| if (specLoop(f.type)) return true;
    }
    return false;
}

/// Which part of style: author part (recipe, when, styleBy...) or animation part (ui.view.loop).
/// Loop only at style tuple top level or as whole style (specLoop rules), split by top-level part.
const BoxPart = enum { author, animation };

fn isLoopPart(comptime T: type) bool {
    return if (partKind(T)) |k| k == .loop else false;
}

fn resolveBoxFor(comptime part: BoxPart, spec: anytype, t: *const ThemeTokens, comptime tracked: bool, ix: Interact) BoxStyle {
    const T = @TypeOf(spec);
    if (comptime isTuple(T)) {
        var out: BoxStyle = .{};
        inline for (@import("zenit_reflection").fields(T)) |f| {
            if (comptime isLoopPart(f.type) == (part == .animation)) out = out.merge(resolveBox(@field(spec, f.name), t, tracked, ix));
        }
        return out;
    }
    if (comptime isLoopPart(T) == (part == .animation)) return resolveBox(spec, t, tracked, ix);
    return .{};
}

/// Whether loop is on now.
fn specLoopOnNow(spec: anytype) bool {
    const T = @TypeOf(spec);
    if (comptime !specLoop(T)) return false;
    if (comptime isTuple(T)) {
        inline for (@import("zenit_reflection").fields(T)) |f| if (specLoopOnNow(@field(spec, f.name))) return true;
        return false;
    }
    return readSource(bool, spec.on, false);
}

/// Runtime conditional style: v.statesBy(look, S.shell), fn shell(l: Look, t) ConditionalStyle.
/// base always applies; hover stacks on hover, active on pressed with the pointer still in the
/// node (native button semantics). Rest conditions (disabled / selected...) are decided by the
/// component. Only for conditions known at runtime; use css / cva _hover / _active otherwise.
/// Whether a hover / active layer exists can depend on tokens: mount checks the theme and
/// re-checks; a layer appearing after a theme switch builds a signal and goes reactive.
pub fn statesBy(src: anytype, comptime f: anytype) StatesBy(@TypeOf(src), f) {
    return .{ .src = src };
}

pub fn StatesBy(comptime Src: type, comptime f_value: anytype) type {
    const info = @typeInfo(@TypeOf(f_value)).@"fn";
    if (@import("zenit_reflection").paramsInfo(info).len != 2 or @import("zenit_reflection").paramsInfo(info)[1].type != *const ThemeTokens or info.return_type != recipe_entry.ConditionalStyle)
        @compileError("ui.view.statesBy: f must be fn (T, *const ThemeTokens) ConditionalStyle");
    return struct {
        src: Src,
        pub const zenit_style_part = .states_by;
        pub const f = f_value;
        pub const Arg = @import("zenit_reflection").paramsInfo(info)[0].type.?;
    };
}

fn partKind(comptime T: type) ?@TypeOf(.enum_literal) {
    if (@typeInfo(T) != .@"struct") return null;
    if (!@hasDecl(T, "zenit_style_part")) return null;
    return T.zenit_style_part;
}

fn isStyleFn(comptime T: type, comptime R: type) bool {
    const F = switch (@typeInfo(T)) {
        .@"fn" => T,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") p.child else return false,
        else => return false,
    };
    const info = @typeInfo(F).@"fn";
    return @import("zenit_reflection").paramsInfo(info).len == 1 and @import("zenit_reflection").paramsInfo(info)[0].type == *const ThemeTokens and info.return_type == R;
}

/// Whether style description has reactive part (when / hover / styleBy; css with _hover;
/// cva with hover layer or variant value from reactive source).
fn specReactive(comptime T: type) bool {
    if (partKind(T)) |k| return switch (k) {
        .when => isReactiveSource(@FieldType(T, "cond")) or specReactive(@TypeOf(T.part)),
        .hover, .style_by, .loop, .states_by => true,
        .css => T.has_hover or T.has_active or T.state_conditions.any(),
        .cva => cvaReactive(T),
        .param => paramReactive(T),
        else => unreachable,
    };
    if (isTuple(T)) {
        for (@import("zenit_reflection").fields(T)) |f| if (specReactive(f.type)) return true;
    }
    return false;
}

fn paramReactive(comptime T: type) bool {
    for (@import("zenit_reflection").fields(@FieldType(T, "args"))) |f| if (isReactiveSource(f.type)) return true;
    return false;
}

fn cvaReactive(comptime T: type) bool {
    if (T.R.has_hover or T.R.has_active or T.R.state_conditions.any()) return true;
    for (@import("zenit_reflection").fields(@FieldType(T, "args"))) |f| if (isReactiveSource(f.type)) return true;
    return false;
}

/// Functions may return different fields later; reserve ext conservatively for them.
/// Declarative styles inspect all layers without evaluating conditions or variants.
fn specNeedsExt(spec: anytype) bool {
    const T = @TypeOf(spec);
    if (comptime isStyleFn(T, BoxStyle)) return true;
    if (T == BoxStyle) return spec.needsExt();
    if (comptime partKind(T)) |k| return switch (k) {
        .when, .hover => specNeedsExt(T.part),
        .style_by, .loop, .states_by => true,
        .css => T.needs_ext,
        .cva, .param => T.R.needs_ext,
        else => unreachable,
    };
    if (comptime isTuple(T)) {
        inline for (@import("zenit_reflection").fields(T)) |f| if (specNeedsExt(@field(spec, f.name))) return true;
        return false;
    }
    return comptime css_mod.specNeedsExt(T);
}

/// Whether node's hover signal needed (v.hover, or anywhere -- including v.when -- _hover / _active
/// css / cva;
/// _active is "pressed and pointer still in node", also needs hover signal).
fn specHover(comptime T: type) bool {
    if (partKind(T)) |k| return switch (k) {
        .hover, .states_by => true,
        .when => specHover(@TypeOf(T.part)),
        .style_by, .loop, .param => false,
        .css => T.has_hover or T.has_active,
        .cva => T.R.has_hover or T.R.has_active,
        else => unreachable,
    };
    if (isTuple(T)) {
        for (@import("zenit_reflection").fields(T)) |f| if (specHover(f.type)) return true;
    }
    return false;
}

/// Whether node's pressed signal needed (anywhere _active css / cva).
fn specActive(comptime T: type) bool {
    if (partKind(T)) |k| return switch (k) {
        .when => specActive(@TypeOf(T.part)),
        .states_by => true,
        .hover, .style_by, .loop, .param => false,
        .css => T.has_active,
        .cva => T.R.has_active,
        else => unreachable,
    };
    if (isTuple(T)) {
        for (@import("zenit_reflection").fields(T)) |f| if (specActive(f.type)) return true;
    }
    return false;
}

/// Whether style description reads theme (style function, styleBy, css / cva, literal referencing
/// token).
fn specThemed(comptime T: type) bool {
    if (isStyleFn(T, BoxStyle) or isStyleFn(T, TextStyle)) return true;
    if (partKind(T)) |k| return switch (k) {
        .style_by, .css, .cva, .loop, .states_by, .param => true,
        .when, .hover => specThemed(@TypeOf(T.part)),
        else => unreachable,
    };
    if (isTuple(T)) {
        for (@import("zenit_reflection").fields(T)) |f| if (specThemed(f.type)) return true;
        return false;
    }
    if (T != BoxStyle and T != TextStyle and @typeInfo(T) == .@"struct") return css_mod.usesTokens(T);
    return false;
}

/// Plain box only hover has state source; rest conditions (selected etc) either component applies
/// per self-state,
/// or cva / sva variants switch by data. Silent ignore would suggest "wrote it, it works", error
/// instead.
/// Conditions in style outside _hover / _active (register source only for used conditions).
fn specConditions(comptime T: type) css_mod.StateConditions {
    if (partKind(T)) |k| return switch (k) {
        .when => specConditions(@TypeOf(T.part)),
        .hover, .style_by, .loop, .states_by, .param => .{},
        .css => T.state_conditions,
        .cva => T.R.state_conditions,
        else => unreachable,
    };
    var out: css_mod.StateConditions = .{};
    if (isTuple(T)) {
        for (@import("zenit_reflection").fields(T)) |f| out = out.merge(specConditions(f.type));
    }
    return out;
}

/// _disabled / _invalid / _selected / _expanded state source: element's state={.{ .disabled = ...
/// }}, else a11y same field.
/// Node-local, doesn't propagate. Config uses condition, neither place has it -> compile error
/// (otherwise layer never applies).
const ConditionSources = struct {
    disabled: ?reactive.Source(bool) = null,
    invalid: ?reactive.Source(bool) = null,
    selected: ?reactive.Source(bool) = null,
    expanded: ?reactive.Source(bool) = null,
};

fn conditionSources(comptime Spec: type, props: anytype) ConditionSources {
    const conds = comptime specConditions(Spec);
    var out: ConditionSources = .{};
    inline for (@import("zenit_reflection").fields(ConditionSources)) |f| {
        if (@field(conds, f.name)) @field(out, f.name) = conditionSource(f.name, props);
    }
    return out;
}

fn conditionSource(comptime name: []const u8, props: anytype) reactive.Source(bool) {
    const P = @TypeOf(props);
    const who = "ui.view state ." ++ name;
    if (@hasField(P, "state") and @hasField(@TypeOf(props.state), name)) return sourceOf(bool, who, @field(props.state, name));
    if (@hasField(P, "a11y")) {
        const A = @TypeOf(props.a11y);
        if (A == types.A11yProps) {
            const v = @field(props.a11y, name);
            return .of(if (@TypeOf(v) == ?bool) v orelse false else v);
        }
        if (@typeInfo(A) == .@"struct" and @hasField(A, name)) return sourceOf(bool, who, @field(props.a11y, name));
    }
    @compileError("ui.view: the style uses condition ._" ++ name ++ " (YSS :" ++ name ++ "), but this element gives it no state; set a11y." ++ name ++
        " or state={.{ ." ++ name ++ " = … }} (bool or a bool source) on the element");
}

fn readSource(comptime T: type, src: anytype, comptime tracked: bool) T {
    return sourceOf(T, "ui.view style condition", src).read(tracked);
}

/// Parse BoxStyle description to one BoxStyle. tracked: condition read registers dependency (in
/// effect).
/// Node's interactive state sources: hover, pressed (none = null, treat as false).
const Interact = struct {
    hovered: ?*Signal(bool) = null,
    pressed: ?*Signal(bool) = null,
    /// Focus (_focus / _focus_visible, build when config uses).
    focused: ?*Signal(bool) = null,
    focus_visible: ?*Signal(bool) = null,
    /// Element's state={...} or a11y same field (fetch when config uses).
    sources: ConditionSources = .{},

    /// Full interaction state wanted by conditional chain (ConditionalStyle.resolve).
    fn state(self: Interact, comptime tracked: bool) types.InteractionState {
        return .{
            .is_hovered = self.hover(tracked),
            .is_pressed = self.active(tracked),
            .is_focused = readFlag(self.focused, tracked),
            .is_focus_visible = readFlag(self.focus_visible, tracked),
            .is_disabled = readSrc(self.sources.disabled, tracked),
            .is_invalid = readSrc(self.sources.invalid, tracked),
            .is_selected = readSrc(self.sources.selected, tracked),
            .is_expanded = readSrc(self.sources.expanded, tracked),
        };
    }

    fn readSrc(src: ?reactive.Source(bool), comptime tracked: bool) bool {
        const x = src orelse return false;
        return if (tracked) x.get() else x.peek();
    }

    fn hover(self: Interact, comptime tracked: bool) bool {
        return readFlag(self.hovered, tracked);
    }

    /// Pressed and pointer still in node (native button semantics: hold-drag-out cancels highlight,
    /// drag back restores).
    fn active(self: Interact, comptime tracked: bool) bool {
        const p = readFlag(self.pressed, tracked);
        const h = readFlag(self.hovered, tracked);
        return p and h;
    }

    fn readFlag(sig: ?*Signal(bool), comptime tracked: bool) bool {
        const x = sig orelse return false;
        return if (tracked) x.get() else x.peek();
    }
};

fn resolveBox(spec: anytype, t: *const ThemeTokens, comptime tracked: bool, ix: Interact) BoxStyle {
    const T = @TypeOf(spec);
    if (comptime isStyleFn(T, BoxStyle)) return spec(t);
    if (T == BoxStyle) return spec;
    if (comptime partKind(T)) |k| {
        switch (k) {
            .when => return if (readSource(bool, spec.cond, tracked)) resolveBox(T.part, t, tracked, ix) else .{},
            .hover => return if (ix.hover(tracked)) resolveBox(T.part, t, tracked, ix) else .{},
            .style_by => {
                if (T.Out != BoxStyle) @compileError("ui.view.styleBy on a box: f must return BoxStyle");
                return T.f(readSource(T.Arg, spec.src, tracked), t);
            },
            .loop => return if (readSource(bool, spec.on, tracked)) T.f(loopPhase(spec.period_ms), t) else .{},
            .states_by => {
                const cs = T.f(readSource(T.Arg, spec.src, tracked), t);
                var s = cs.base;
                if (ix.hover(tracked)) s = s.merge(cs.hover orelse .{});
                if (ix.active(tracked)) s = s.merge(cs.active orelse .{});
                return s;
            },
            .css => {
                if (comptime T.state_conditions.any()) return T.conditional(t).resolve(ix.state(tracked));
                var s = T.box(t);
                if (T.has_hover and ix.hover(tracked)) s = s.merge(T.hoverBox(t));
                if (T.has_active and ix.active(tracked)) s = s.merge(T.activeBox(t));
                return s;
            },
            .cva => {
                const cs = T.R.resolve(readVariants(T, spec, tracked), t);
                if (comptime T.R.state_conditions.any()) return cs.resolve(ix.state(tracked));
                var s = cs.base;
                if (T.R.has_hover and ix.hover(tracked)) s = s.merge(cs.hover orelse .{});
                if (T.R.has_active and ix.active(tracked)) s = s.merge(cs.active orelse .{});
                return s;
            },
            .param => return T.R.resolve(readParams(T, spec, tracked), t),
            else => unreachable,
        }
    }
    if (comptime isTuple(T)) {
        var out = BoxStyle{};
        inline for (@import("zenit_reflection").fields(T)) |f| out = out.merge(resolveBox(@field(spec, f.name), t, tracked, ix));
        return out;
    }
    if (comptime @typeInfo(T) == .@"struct") {
        comptime if (css_mod.specError(T, false)) |msg| @compileError("ui.view style literal: " ++ msg ++ " (conditions need ui.css(...))");
        return css_mod.boxFrom(spec, t);
    }
    @compileError("ui.view: unsupported box style " ++ @typeName(T) ++
        ". Expected a fn (*const ThemeTokens) BoxStyle, a BoxStyle literal, v.when / v.hover / v.styleBy, or a tuple of those");
}

/// cva part variant value: unspecified dimensions take default, specified read source (tracked:
/// register dependency) switch to that dimension's value.
fn readVariants(comptime T: type, part: T, comptime tracked: bool) T.R.Variants {
    var vs: T.R.Variants = .{};
    inline for (@import("zenit_reflection").fields(@FieldType(T, "args"))) |f| {
        const D = @FieldType(T.R.Variants, f.name);
        const x = @field(part.args, f.name);
        const X = @TypeOf(x);
        @field(vs, f.name) = if (comptime X == @TypeOf(.enum_literal))
            comptime T.R.toDim(D, x)
        else
            T.R.toDim(D, readSource(SourceValue(X), x, tracked));
    }
    return vs;
}

/// Parameterized style part param: unspecified take default, specified read source (tracked:
/// register dependency).
/// Source value type implicitly convert to param type (Signal(f32) pass to ?f32 param).
fn readParams(comptime T: type, part: T, comptime tracked: bool) T.R.Args {
    const Given = @FieldType(T, "args");
    var out: T.R.Args = undefined;
    inline for (@import("zenit_reflection").fields(T.R.Args)) |f| {
        if (comptime @hasField(Given, f.name)) {
            const x = @field(part.args, f.name);
            const X = @TypeOf(x);
            @field(out, f.name) = if (comptime isReactiveSource(X)) readSource(reactive.SourceValueOf(X), x, tracked) else x;
        } else {
            @field(out, f.name) = comptime f.defaultValue().?;
        }
    }
    return out;
}

/// Box style plan: compile-time pick path. overlay: stack style onto existing node (v.attrs add
/// style to component root),
/// undo to node's prior value (snapshot at mount) not Style default.
fn BoxPlan(comptime Props: type, comptime dir: ?Direction, comptime overlay: bool) type {
    const has_style = @hasField(Props, "style");
    const Spec = if (has_style) @FieldType(Props, "style") else void;
    const spec_field: ?@import("zenit_reflection").StructField = if (has_style) blk: {
        for (@import("zenit_reflection").fields(Props)) |f| if (std.mem.eql(u8, f.name, "style")) break :blk f;
        unreachable;
    } else null;
    const spec_comptime = if (spec_field) |f| f.is_comptime else true;
    const reactive_spec = has_style and specReactive(Spec);
    const themed = has_style and specThemed(Spec);
    const Mode = enum { plain, theme_hook, dynamic };
    const mode: Mode = if (reactive_spec or (themed and !spec_comptime))
        .dynamic
    else if (themed)
        .theme_hook
    else
        .plain;

    return struct {
        pub const plan_mode = mode;

        /// Compile-time-known style value (including function) can't store as runtime field: pass
        /// to BoxRuntime as compile-time const;
        /// runtime style return void, BoxRuntime stores field.
        fn staticSpec() if (has_style and spec_comptime) Spec else void {
            if (has_style and spec_comptime) return comptime spec_field.?.defaultValue().?;
        }

        fn withDir(s: BoxStyle) BoxStyle {
            var out = s;
            if (dir) |d| out.direction = d;
            return out;
        }

        /// theme_hook mode playback (re-calculate compile-time style with new tokens at theme
        /// switch, apply).
        fn applyThemed(n: *Node, t: *const ThemeTokens, allocator: std.mem.Allocator) void {
            if (mode != .theme_hook) return;
            const spec = comptime spec_field.?.defaultValue().?;
            const s = withDir(resolveBox(spec, t, false, .{}));
            s.applyTo(&n.style, allocator);
            if (s.icon_color) |c| _ = n.setTint(c);
            if (s.background) |c| n.setBackgroundRaw(c);
            if (s.opacity) |o| n.setOpacityRaw(o);
            n.markLayoutDirty();
        }

        fn initial(props: Props, t: *const ThemeTokens) BoxStyle {
            if (!has_style) return withDir(.{});
            return withDir(resolveBox(props.style, t, false, .{}));
        }

        /// Style declaration transition (.transition = ui.transition(...)): attach to node
        /// post-mount, then hover / variant switch
        /// interpolates via transition setter; initial already set at create, doesn't trigger null
        /// transition.
        const transitions = if (has_style) specTransitions(Spec) else &[_]recipe_entry.TransitionEntry{};

        fn attach(props: Props, scope: *Scope, cx: *Cx, node: *Node) !void {
            if (comptime transitions.len > 0) node.applyTransition(cx.allocator, transitions);
            if (overlay) {
                if (!has_style) return;
                switch (mode) {
                    .plain => {
                        const s = initial(props, cx.tokens);
                        // ext allocate first, can fail: OOM takes error path, not applyTo silent
                        // field drop.
                        if (s.needsExt()) _ = try node.style.ensureExtFallible(cx.allocator);
                        s.applyTo(&node.style, cx.allocator);
                        if (s.background) |c| node.setBackgroundRaw(c);
                        if (s.opacity) |o| node.setOpacityRaw(o);
                        node.markLayoutDirty();
                        return;
                    },
                    // Component root might have own on_theme (single slot): don't override, effect
                    // tracks theme instead.
                    .theme_hook, .dynamic => return BoxRuntime(Spec, dir, true, staticSpec()).start(props.style, scope, cx, node, conditionSources(Spec, props)),
                }
            }
            switch (mode) {
                .plain => {},
                .theme_hook => {
                    if (specNeedsExt(props.style)) _ = try node.style.ensureExtFallible(cx.allocator);
                    node.meta.per_frame.hooks.on_theme = applyThemed;
                },
                .dynamic => try BoxRuntime(Spec, dir, false, staticSpec()).start(props.style, scope, cx, node, conditionSources(Spec, props)),
            }
        }
    };
}

/// Style reset baseline: condition withdraws, field back here. New box uses Style default; v.attrs
/// stack to component root
/// uses mount snapshot (doesn't follow component updates). Node's current tint (icon / image), null
/// without media content.
fn currentTint(node: *Node) ?Color {
    if (node.getIcon()) |ic| return ic.tint;
    if (node.getImage()) |img| return img.tint;
    return null;
}

/// Layer cascade bottom: style default. Property unspecified across layers falls here
/// (component root stacked: component's own style already part of inline layer cascade, no snapshot
/// needed).
const Baseline = struct {
    style: types.Style,
    ext: types.StyleExt,
    background: Color,
    opacity: f32,

    const defaults: Baseline = .{ .style = .{}, .ext = .{}, .background = Color.TRANSPARENT, .opacity = 1 };
};

/// Reactive / runtime Box style: one effect tracks condition source and theme, re-calc and apply
/// incremental.
/// capture_base: stack to existing node (v.attrs), mount snapshot is reset baseline, first run full
/// apply.
/// Transition declared in style description (css top, cva base, sva slot base .transition).
fn specTransitions(comptime T: type) []const recipe_entry.TransitionEntry {
    if (comptime isTuple(T)) {
        comptime var out: []const recipe_entry.TransitionEntry = &.{};
        inline for (@import("zenit_reflection").fields(T)) |f| out = out ++ specTransitions(f.type);
        return out;
    }
    if (comptime partKind(T)) |k| return switch (k) {
        .css => T.transitions,
        .cva => T.R.transitions,
        .when, .hover => specTransitions(@TypeOf(T.part)),
        else => &.{},
    };
    return &.{};
}

/// Runtime style static now: reactive parts (cva / sva param, styleBy source, when cond) are static
/// Source,
/// and doesn't need hover now (see specHoverNow). When true, style only changes with theme, no
/// effect tracking data source.
fn specStaticNow(spec: anytype, t: *const ThemeTokens) bool {
    return specSourcesStaticNow(spec) and !specHoverNow(spec, t);
}

fn specSourcesStaticNow(spec: anytype) bool {
    const T = @TypeOf(spec);
    if (comptime isTuple(T)) {
        inline for (@import("zenit_reflection").fields(T)) |f| if (!specSourcesStaticNow(@field(spec, f.name))) return false;
        return true;
    }
    if (comptime partKind(T)) |k| switch (k) {
        .when => return sourceStaticNow(spec.cond),
        .hover, .css => return true,
        .style_by, .states_by => return sourceStaticNow(spec.src),
        // Loop on always re-calculates per frame; source static and off same as static, still
        // runtime (rare, not worth path).
        .loop => return false,
        .cva, .param => {
            inline for (@import("zenit_reflection").fields(@FieldType(T, "args"))) |f| if (!sourceStaticNow(@field(spec.args, f.name))) return false;
            return true;
        },
        else => unreachable,
    };
    return true;
}

/// Whether node's hover signal needed now. specHover compile-time says "some branch wrote hover
/// layer"; source
/// determining branch static now? judge by value: static v.when(false, ...), static variant without
/// _hover in cva
/// (hoverable = false card) needs no hover, don't build signal & effect. Source changes ->
/// conservative need.
fn specHoverNow(spec: anytype, t: *const ThemeTokens) bool {
    const T = @TypeOf(spec);
    if (comptime !specHover(T)) return false;
    if (comptime isTuple(T)) {
        inline for (@import("zenit_reflection").fields(T)) |f| if (specHoverNow(@field(spec, f.name), t)) return true;
        return false;
    }
    if (comptime partKind(T)) |k| switch (k) {
        .hover, .css => return true,
        .when => {
            if (!sourceStaticNow(spec.cond)) return true;
            return readSource(bool, spec.cond, false) and specHoverNow(T.part, t);
        },
        .states_by => {
            if (!sourceStaticNow(spec.src)) return true;
            const cs = T.f(readSource(T.Arg, spec.src, false), t);
            return cs.hover != null or cs.active != null;
        },
        .cva => {
            if (!specSourcesStaticNow(spec)) return true;
            const cs = T.R.resolve(readVariants(T, spec, false), t);
            return cs.hover != null or cs.active != null;
        },
        else => unreachable,
    };
    return false;
}

/// Whether node's pressed signal needed now (judged like specHoverNow).
fn specActiveNow(spec: anytype, t: *const ThemeTokens) bool {
    const T = @TypeOf(spec);
    if (comptime !specActive(T)) return false;
    if (comptime isTuple(T)) {
        inline for (@import("zenit_reflection").fields(T)) |f| if (specActiveNow(@field(spec, f.name), t)) return true;
        return false;
    }
    if (comptime partKind(T)) |k| switch (k) {
        .css => return true,
        .when => {
            if (!sourceStaticNow(spec.cond)) return true;
            return readSource(bool, spec.cond, false) and specActiveNow(T.part, t);
        },
        .states_by => {
            if (!sourceStaticNow(spec.src)) return true;
            return T.f(readSource(T.Arg, spec.src, false), t).active != null;
        },
        .cva => {
            if (!specSourcesStaticNow(spec)) return true;
            return T.R.resolve(readVariants(T, spec, false), t).active != null;
        },
        else => unreachable,
    };
    return false;
}

fn sourceStaticNow(x: anytype) bool {
    const X = @TypeOf(x);
    if (comptime isSourceUnion(X)) return x.isStatic();
    return comptime !isReactiveSource(X);
}

/// Hang scope's owned style state on node's view_theme slot (core ViewThemeReplay), replay at theme
/// switch,
/// skip dependency graph. State owns scope, node may go first or second: unlink checks node's
/// generation handle,
/// confirm still same node & slot points to self.
const ThemeLink = struct {
    replay: ViewThemeReplay,
    cx: *Cx,
    node: *Node,
    handle: core.NodeHandle,

    /// Hang to replay list head.
    fn attach(self: *ThemeLink, scope: *Scope, cx: *Cx, node: *Node, run: *const fn (*ViewThemeReplay, *const ThemeTokens) void) !void {
        const generation = try cx.node_registry.trackGeneration(node);
        self.* = .{ .replay = .{ .run = run }, .cx = cx, .node = node, .handle = .{ .id = node.id, .generation = generation } };
        // Register unlink first, post callback: OOM leaves no orphan callback.
        try scope.onCleanup(ThemeLink, self, detach);
        self.replay.next = node.meta.per_frame.hooks.view_theme;
        node.meta.per_frame.hooks.view_theme = &self.replay;
    }

    fn detach(self: *ThemeLink) void {
        const node = node_refs.resolveTrackedNode(&self.cx.node_registry, self.handle, self.node) orelse return;
        var link = &node.meta.per_frame.hooks.view_theme;
        while (link.*) |r| : (link = &r.next) {
            if (r == &self.replay) {
                link.* = r.next;
                return;
            }
        }
    }
};

/// Test: style layer size (runtime style no longer saves complete BoxStyle per value).
pub const StyleLayerForTest = StyleLayer;
/// Test: read node's current box style as declaration.
pub const captureInlineStyleForTest = captureInlineStyle;
/// Test: whether node's style host reported "host-managed field directly rewritten".
pub fn styleConflictReportedForTest(node: *Node) bool {
    return if (StyleHost.of(node)) |h| h.conflict_reported else false;
}

/// Style layer order: low -> high. High layer overrides low; when layer stops declaring property,
/// fall back to lower layer,
/// eventually to baseline.
const LayerKind = enum(u8) {
    /// Element's own style={} (recipe, variant, state condition).
    element = 0,
    /// Component inline: component's imperative style write to node (setBackground / setOpacity /
    /// setBorderColor / setTranslateX / setStyleInline).
    inline_ = 1,
    /// Caller stack on component root (v.attrs / template component element style).
    overlay = 2,
    /// Animation (ui.view.loop): overrides all author layers, exclusive over fields it drives; its
    /// change immediate, skip transition,
    /// released field transition back to author layer target value per normal rules.
    animation = 3,
};

/// One runtime box style layer on node: current declaration (sparse), updated by style runtime in
/// its scope.
const StyleLayer = struct {
    kind: LayerKind,
    decl: BoxDecl = .{},
    cx: *Cx,
    /// Already applied once: first apply (during mount) immediate, skip transition (CSS: initial
    /// render doesn't trigger transition).
    applied_once: bool = false,
    /// Owning host (set post-register). Layer & host unlink each other: layer releases first
    /// unlinks self from host;
    /// host releases (node release) clear this. Invariant: host's layer list only live layers (each
    /// unlinks on release),
    /// so safe to write layers when host destroys.
    host: ?*StyleHost = null,

    /// Swap new declaration and recalc host; if same as current, do nothing. OOM keeps old
    /// declaration (skip this update, log).
    fn set(self: *StyleLayer, next: BoxStyle) void {
        if (self.replace(next)) {
            if (self.host) |h| h.recompute();
        } else if (self.host) |h| {
            // Declaration unchanged, but host's prior recalc OOM didn't apply: catch up (else this
            // update waits for other layer change).
            if (h.stale) h.recompute();
        }
    }

    /// Swap new declaration, don't recalc; return changed. OOM keeps old declaration (skip update,
    /// log).
    fn replace(self: *StyleLayer, next: BoxStyle) bool {
        if (declEqlStyle(self.decl, next)) return false;
        const d = BoxDecl.encode(self.cx.allocator, next) catch {
            std.log.warn("ui.view: style layer update dropped (out of memory)", .{});
            return false;
        };
        self.decl.deinit(self.cx.allocator);
        self.decl = d;
        return true;
    }

    /// Unlink from host and release declaration (host already released: just release declaration).
    /// Don't recalc when node releasing.
    fn detach(self: *StyleLayer) void {
        if (self.host) |h| {
            h.remove(self);
            self.host = null;
            if (!h.node.freeing) h.recompute();
        }
        self.decl.deinit(self.cx.allocator);
        self.decl = .{};
    }
};

/// Same as current declaration (no alloc): bit set consistent and each declared field value equal.
fn declEqlStyle(d: BoxDecl, s: BoxStyle) bool {
    inline for (@import("zenit_reflection").fields(BoxStyle), 0..) |f, i| {
        const field: BoxDecl.Field = @fromBackingInt(@intCast(i));
        const in_s = @field(s, f.name) != null;
        if (in_s != d.has(field)) return false;
        if (in_s and !style_decl.valueEql(d.get(field).?, @field(s, f.name).?)) return false;
    }
    return true;
}

/// Read node's current box style as declaration (fields matching default don't declare): component
/// root stacked,
/// component's own style becomes component inline layer init. Inverse of BoxStyle.applyTo -- write
/// result to new node,
/// style storage matches original (roundtrip property for tests).
fn captureInlineStyle(node: *Node) BoxStyle {
    @setEvalBranchQuota(20000);
    comptime assertCaptureCoverage();
    var out: BoxStyle = .{};
    const st = &node.style;
    const def_style: types.Style = .{};
    const def_ext: types.StyleExt = .{};
    // Same-named Style field (border whole here; margin auto see next).
    inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
        const name = f.name;
        if (comptime @hasField(types.Style, name) and !std.mem.eql(u8, name, "ext")) {
            const V = @typeInfo(f.type).optional.child;
            if (comptime @FieldType(types.Style, name) == V) {
                if (!style_decl.valueEql(@field(st.*, name), @field(def_style, name))) @field(out, name) = @field(st.*, name);
            }
        }
    }
    if (!Color.eql(node.getBackground(), Color.TRANSPARENT)) out.background = node.getBackground();
    if (@abs(node.getOpacity() - 1) > 0) out.opacity = node.getOpacity();
    // Transitioning property takes transition end (target), don't solidify interpolation midpoint
    // into declaration.
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        for (slots.slots[0..slots.count]) |slot| {
            if (!slot.active) continue;
            switch (slot.prop) {
                .background => out.background = if (Color.eql(slot.to_color, Color.TRANSPARENT)) null else slot.to_color,
                .opacity => out.opacity = if (slot.to_value == 1) null else slot.to_value,
                .border_color => {
                    var b = out.border orelse st.border;
                    b.color = slot.to_color;
                    out.border = b;
                },
                .translate_x => out.translate_x = if (slot.to_value == 0) null else slot.to_value,
                else => {},
            }
        }
    }
    const e = st.ext orelse return out;
    // Same-named StyleExt field (pass-through field, transform, blend, gradient, glass...).
    inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
        const name = f.name;
        const special = comptime for ([_][]const u8{ "corner_radius", "inset_shadow" }) |x| {
            if (std.mem.eql(u8, x, name)) break true;
        } else false;
        if (comptime @hasField(types.StyleExt, name) and !@hasField(types.Style, name) and !special) {
            const V = @typeInfo(f.type).optional.child;
            const E = @FieldType(types.StyleExt, name);
            if (comptime E == V) {
                if (!style_decl.valueEql(@field(e.*, name), @field(def_ext, name))) @field(out, name) = @field(e.*, name);
            } else if (comptime E == ?V) {
                if (@field(e.*, name)) |val| @field(out, name) = val;
            }
        }
    }
    // Special case: margin auto, split border color, corner radius, shadow list, inner shadow list,
    // text three items.
    if (e.margin_auto_mask != 0) {
        out.margin = null;
        var m = types.Margin.fromPadding(st.margin);
        m.auto_mask = e.margin_auto_mask;
        out.margin_spec = m;
    }
    if (e.border_side_colors) |sc| {
        out.border_top_color = sc.top;
        out.border_right_color = sc.right;
        out.border_bottom_color = sc.bottom;
        out.border_left_color = sc.left;
    }
    if (e.corner_radius) |r| out.corner_radii = r;
    if (e.shadow_count > 0) out.shadows = types.ShadowList.of(e.shadows[0..e.shadow_count]);
    if (e.inset_shadow) |first| {
        const extra = @min(e.extra_inset_count, e.extra_inset_shadows.len);
        if (extra > 0) {
            var layers: [1 + e.extra_inset_shadows.len]types.InsetShadow = undefined;
            layers[0] = first;
            for (0..extra) |i| layers[i + 1] = e.extra_inset_shadows[i];
            out.inset_shadows = types.InsetShadowList.of(layers[0 .. 1 + extra]);
        } else out.inset_shadow = first;
    }
    if (e.text_color) |c| out.text_color = c;
    if (e.text_font_size) |v| out.font_size = v;
    if (e.text_font_weight) |v| out.font_weight = v;
    return out;
}

/// Compile check: every BoxStyle field has capture rule (same-named, same-type Style / StyleExt
/// field, or special case next).
/// New field without rule fails compile, not silent leak (component root stacked loses that style).
fn assertCaptureCoverage() void {
    @setEvalBranchQuota(20000);
    const special = [_][]const u8{
        "background",         "opacity",             "margin_spec",         "corner_radius",     "corner_radii",
        "shadow",             "shadows",             "inset_shadow",        "inset_shadows",     "text_color",
        "font_size",          "font_weight",         "icon_color",          "border_color",      "border_width",
        "border_top_width",   "border_right_width",  "border_bottom_width", "border_left_width", "border_top_color",
        "border_right_color", "border_bottom_color", "border_left_color",
    };
    for (@import("zenit_reflection").fields(BoxStyle)) |f| {
        const V = @typeInfo(f.type).optional.child;
        const in_style = @hasField(types.Style, f.name) and @FieldType(types.Style, f.name) == V;
        const in_ext = @hasField(types.StyleExt, f.name) and (@FieldType(types.StyleExt, f.name) == V or @FieldType(types.StyleExt, f.name) == ?V);
        const is_special = for (special) |x| {
            if (std.mem.eql(u8, x, f.name)) break true;
        } else false;
        if (!in_style and !in_ext and !is_special) @compileError("captureInlineStyle: no capture rule for BoxStyle." ++ f.name);
    }
}

/// Change between two target values: which fields changed (bit set). Compare only within declared
/// by either.
/// Drives apply: fallback, transition setter, invalidate per change kind (redraw only / compose
/// only / relayout).
const StyleChange = struct {
    changed: BoxDecl.Mask = 0,

    fn between(last: BoxStyle, next: BoxStyle) StyleChange {
        var c: StyleChange = .{};
        inline for (@import("zenit_reflection").fields(BoxStyle), 0..) |f, i| {
            const a = @field(last, f.name);
            const b = @field(next, f.name);
            if ((a != null or b != null) and !styleEql(a, b)) c.changed |= @as(BoxDecl.Mask, 1) << i;
        }
        return c;
    }

    fn has(self: StyleChange, comptime name: []const u8) bool {
        return self.changed & (@as(BoxDecl.Mask, 1) << @backingInt(@field(BoxDecl.Field, name))) != 0;
    }

    fn isEmpty(self: StyleChange) bool {
        return self.changed == 0;
    }
};

/// Node's style cascade host: all node's runtime box styles are its layers (element's own,
/// component root stack...),
/// merge layers per order to target (ComputedStyle), compare to last applied target, get change
/// (StyleChange) apply to node.
/// Layers don't each write own: external stack always overrides component own, layer withdraw falls
/// back to lower not snapshot.
/// Host alloced by cx.allocator, hangs on node, release with node; layers owned by respective
/// scope.
const StyleHost = struct {
    cx: *Cx,
    node: *Node,
    /// Low -> high (by kind, same kind by registration order: nested stack outer registers later,
    /// above).
    layers: std.ArrayListUnmanaged(*StyleLayer) = .empty,
    /// Last applied layer cascade result (sparse coverage vs baseline).
    computed: BoxDecl = .{},
    /// Mount tint (icon_color undo back to it).
    tint0: ?Color = null,
    /// Last recalc OOM didn't apply (node & computed at old target).
    stale: bool = false,
    /// Component inline layer (host owns, always in layer list).
    inline_layer: StyleLayer,
    /// Applying change to node now: node setter continue normal, don't fall back to inline layer.
    applying: bool = false,
    /// Debug: reported "host-managed field directly rewritten" (once per host).
    conflict_reported: bool = false,

    fn of(node: *Node) ?*StyleHost {
        const r = node.meta.per_frame.hooks.style_host orelse return null;
        return @ptrCast(@alignCast(r.ptr));
    }

    /// Get node's host, create if none. snapshot: no host? use node's current style as baseline
    /// (stack to existing node).
    fn ensure(cx: *Cx, node: *Node, snapshot: bool) !*StyleHost {
        if (of(node)) |h| return h;
        const h = try cx.allocator.create(StyleHost);
        h.* = .{ .cx = cx, .node = node, .tint0 = currentTint(node), .inline_layer = .{ .kind = .inline_, .cx = cx, .applied_once = true } };
        h.layers.append(cx.allocator, &h.inline_layer) catch |err| {
            cx.allocator.destroy(h);
            return err;
        };
        h.inline_layer.host = h;
        if (snapshot) {
            // Stack to existing node (component root): component's own style becomes component
            // inline layer init; what node displays now is it.
            const own = captureInlineStyle(node);
            h.inline_layer.decl = BoxDecl.encode(cx.allocator, own) catch |err| {
                h.layers.deinit(cx.allocator);
                cx.allocator.destroy(h);
                return err;
            };
            h.computed = BoxDecl.encode(cx.allocator, own) catch |err| {
                h.inline_layer.decl.deinit(cx.allocator);
                h.layers.deinit(cx.allocator);
                cx.allocator.destroy(h);
                return err;
            };
        }
        node.meta.per_frame.hooks.style_host = .{ .ptr = @ptrCast(h), .destroy = destroy, .write_inline = writeInline, .unset_inline = unsetInline };
        return h;
    }

    fn destroy(ptr: *anyopaque) void {
        const h: *StyleHost = @ptrCast(@alignCast(ptr));
        // Node releases before layer: clear each layer's host pointer (list only live layers),
        // later layer won't touch host.
        for (h.layers.items) |l| {
            // Dead layer without unlinking reads fill here: invariant broken, fail on spot.
            std.debug.assert(l.host == h);
            l.host = null;
        }
        h.layers.deinit(h.cx.allocator);
        h.inline_layer.decl.deinit(h.cx.allocator);
        h.computed.deinit(h.cx.allocator);
        h.cx.allocator.destroy(h);
    }

    /// Component imperative style write: merge into inline layer (later field overrides prior) then
    /// recalc. Return false when host applying.
    fn writeInline(ptr: *anyopaque, partial: *const BoxStyle) bool {
        const h: *StyleHost = @ptrCast(@alignCast(ptr));
        if (h.applying) return false;
        h.inline_layer.set(h.inline_layer.decl.decode().merge(partial.*));
        return true;
    }

    /// Strip field from component inline layer (non-null in fields), fall back to lower layer.
    fn unsetInline(ptr: *anyopaque, fields: *const BoxStyle) void {
        const h: *StyleHost = @ptrCast(@alignCast(ptr));
        var cur = h.inline_layer.decl.decode();
        inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
            if (@field(fields.*, f.name) != null) @field(cur, f.name) = null;
        }
        h.inline_layer.set(cur);
    }

    /// Register layer (insert by order).
    fn add(h: *StyleHost, layer: *StyleLayer) !void {
        var at = h.layers.items.len;
        while (at > 0 and @backingInt(h.layers.items[at - 1].kind) > @backingInt(layer.kind)) at -= 1;
        try h.layers.insert(h.cx.allocator, at, layer);
        layer.host = h;
    }

    fn remove(h: *StyleHost, layer: *StyleLayer) void {
        for (h.layers.items, 0..) |l, i| if (l == layer) {
            _ = h.layers.orderedRemove(i);
            return;
        };
    }

    /// Debug: field from last apply directly rewritten bypass host (node.style.x = ...) -- this
    /// apply will override it.
    /// Check only direct same-named field on Style (transition property naturally differs from
    /// target, don't check).
    fn checkConflicts(h: *StyleHost, last: BoxStyle) void {
        if (h.conflict_reported) return;
        inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
            const name = f.name;
            if (comptime @hasField(types.Style, name) and !std.mem.startsWith(u8, name, "border") and !std.mem.eql(u8, name, "translate_x")) {
                if (@field(last, name)) |want| {
                    if (!styleEql(@as(@TypeOf(want), @field(h.node.style, name)), want)) {
                        h.conflict_reported = true;
                        std.log.warn("ui.view: style field `{s}` of node {d} ({s}) was written directly while style layers own it; use node.setStyleInline so the layers can cascade it", .{ name, h.node.id, h.node.meta.ownership.meta.component_name orelse "-" });
                        return;
                    }
                }
            }
        }
    }

    /// Cascade: merge all layers per order.
    fn cascade(h: *const StyleHost) BoxStyle {
        var out: BoxStyle = .{};
        for (h.layers.items) |l| out = out.merge(l.decl.decode());
        return out;
    }

    /// Recalc target; change exists? apply to node (change = new vs old target diff, reset property
    /// back to baseline).
    fn recompute(h: *StyleHost) void {
        // Demand recalc during apply (unreachable theory: restyleBox writes only this node): note,
        // apply end delegates to next write.
        if (h.applying) {
            h.stale = true;
            return;
        }
        const next = h.cascade();
        const last = h.computed.decode();
        if (std.debug.runtime_safety) h.checkConflicts(last);
        const change = StyleChange.between(last, next);
        if (change.isEmpty()) {
            // No change to apply: first apply done (else later when other layer changes these
            // fields, misidentify immediate).
            for (h.layers.items) |l| l.applied_once = true;
            return;
        }
        const d = BoxDecl.encode(h.cx.allocator, next) catch {
            std.log.warn("ui.view: style update dropped (out of memory)", .{});
            h.stale = true;
            return;
        };
        h.stale = false;
        // Fields immediate (skip transition): value from "first-apply layer" or animation layer.
        // Judge by cascade winner per layer (high to low,
        // each field owned by highest declaring layer), not "which layers declared": shadowed
        // declaration doesn't count,
        // animation-released field winner switches to author layer, transition normal.
        var instant: BoxDecl.Mask = 0;
        var covered: BoxDecl.Mask = 0;
        var k = h.layers.items.len;
        while (k > 0) {
            k -= 1;
            const l = h.layers.items[k];
            const won = l.decl.mask & ~covered;
            covered |= l.decl.mask;
            if (!l.applied_once or l.kind == .animation) instant |= won;
        }
        for (h.layers.items) |l| l.applied_once = true;
        const was_applying = h.applying;
        h.applying = true;
        defer h.applying = was_applying;
        restyleBox(h.node, &Baseline.defaults, last, next, .{ .changed = change.changed & ~instant }, change, h.cx.allocator);
        if (change.has("icon_color")) _ = h.node.setTint(next.icon_color orelse h.tint0 orelse Color.WHITE);
        h.computed.deinit(h.cx.allocator);
        h.computed = d;
    }
};

fn BoxRuntime(comptime Spec: type, comptime dir: ?Direction, comptime capture_base: bool, comptime static_spec: anytype) type {
    const is_static = @TypeOf(static_spec) != void;
    const has_loop = specLoop(Spec);
    return struct {
        const Self = @This();

        node: *Node,
        cx: *Cx,
        scope: *Scope,
        spec: if (is_static) void else Spec,
        theme: ?*Signal(*const ThemeTokens),
        ix: Interact,
        /// This style one layer in node's style host (element own style / component root stack).
        layer: StyleLayer,
        /// Style's loop part (ui.view.loop) separate animation layer: override author layer,
        /// exclusive over fields it drives, change skip transition.
        anim_layer: if (has_loop) StyleLayer else void,
        link: ThemeLink = undefined,
        /// v.loop: node's generation handle (scope first? check then unlink hook) & hook hung flag.
        loop_handle: if (has_loop) core.NodeHandle else void = undefined,
        loop_on: bool = false,

        fn start(spec: Spec, scope: *Scope, cx: *Cx, node: *Node, sources: ConditionSources) !void {
            // Include inactive branches and every recipe variant before entering the void effect.
            if (specNeedsExt(spec)) _ = try node.style.ensureExtFallible(cx.allocator);
            const theme_sig = if (comptime specThemed(Spec)) try cx.themeSignal(rootScopeOf(scope)) else null;
            const hovered = if (specHoverNow(spec, cx.tokens)) try hooks.useHover(scope, node) else null;
            const pressed = if (specActiveNow(spec, cx.tokens)) try hooks.usePressed(scope, cx, node) else null;
            const conds = comptime specConditions(Spec);
            const focus: ?hooks.FocusState = if (conds.focus or conds.focus_visible) try hooks.useFocusState(scope, cx, node) else null;
            const st = try scope.allocator.create(Self);
            st.* = .{
                .node = node,
                .cx = cx,
                .scope = scope,
                .spec = if (is_static) {} else spec,
                .theme = theme_sig,
                .ix = .{
                    .hovered = hovered,
                    .pressed = pressed,
                    .focused = if (focus) |f| f.focused else null,
                    .focus_visible = if (focus) |f| f.visible else null,
                    .sources = sources,
                },
                // Element own style at node create already written by init value: not "first
                // apply".
                .layer = .{ .kind = if (capture_base) .overlay else .element, .cx = cx, .applied_once = !capture_base },
                .anim_layer = if (has_loop) .{ .kind = .animation, .cx = cx, .applied_once = true } else {},
            };
            try scope.adoptResource(@ptrCast(st), destroy);
            // Stack to existing node: no host? baseline from node's current style, layer empty
            // first, first apply run.
            const host_existed = StyleHost.of(node) != null;
            const host = try StyleHost.ensure(cx, node, capture_base);
            if (!capture_base) {
                // Element own style: at node create already written by init value, layer & host
                // target from init (don't re-apply).
                const initial = resolveNow(spec, cx.tokens, .{});
                st.layer.decl = try BoxDecl.encode(cx.allocator, if (has_loop) resolveNowFor(.author, spec, cx.tokens) else initial);
                try host.add(&st.layer);
                if (comptime has_loop) {
                    st.anim_layer.decl = try BoxDecl.encode(cx.allocator, resolveNowFor(.animation, spec, cx.tokens));
                    try host.add(&st.anim_layer);
                }
                if (!host_existed) {
                    host.computed = try BoxDecl.encode(cx.allocator, initial);
                    if (initial.icon_color) |c| _ = node.setTint(c);
                    // Node merge-by-tuple init display; split post animation layer differs, align
                    // here.
                    if (comptime has_loop) host.recompute();
                } else host.recompute();
            } else {
                try host.add(&st.layer);
                if (comptime has_loop) try host.add(&st.anim_layer);
            }
            if (comptime has_loop) {
                // Register unlink first, hang hook (first effect run): OOM leaves no callback to
                // freed state.
                st.loop_handle = .{ .id = node.id, .generation = try cx.node_registry.trackGeneration(node) };
                try scope.onCleanup(Self, st, detachLoop);
            }
            const has_state = comptime conds.any();
            if (hovered == null and pressed == null and !has_state and specSourcesStaticNow(spec)) {
                // Data source all static now (component-received static prop) & no hover needed:
                // style only changes with theme, hang theme replay, no effect.
                if (capture_base) st.apply(cx.tokens, false);
                if (comptime !specThemed(Spec)) return;
                return st.link.attach(scope, cx, node, replay);
            }
            try scope.createEffect(st, run);
        }

        fn replay(r: *ViewThemeReplay, t: *const ThemeTokens) void {
            const link: *ThemeLink = @fieldParentPtr("replay", r);
            const self: *Self = @alignCast(@fieldParentPtr("link", link));
            // Mount doesn't need hover / pressed (static variant no layer), after theme swap
            // appeared (e.g. statesBy f
            // by theme decide hover layer): build signal and switch to effect follow, not leave
            // condition layer forever dead.
            if (comptime specHover(Spec)) {
                if (self.ix.hovered == null and specHoverNow(self.specNow(), t)) self.upgrade(t);
            }
            self.apply(t, false);
        }

        fn specNow(self: *const Self) Spec {
            return if (is_static) static_spec else self.spec;
        }

        /// Static upgrade to reactive: build hover (and pressed as needed) signal & effect. Theme
        /// replay link keep (both paths share last delta apply).
        /// Any step fail reset interaction state: next theme replay still retry (hang registered
        /// hover / pressed observer releases with scope, extra harmless).
        fn upgrade(self: *Self, t: *const ThemeTokens) void {
            self.tryUpgrade(t) catch |err| {
                self.ix.hovered = null;
                self.ix.pressed = null;
                std.log.err("ui.view: style gained interaction layers after a theme change but wiring them failed: {}", .{err});
            };
        }

        fn tryUpgrade(self: *Self, t: *const ThemeTokens) !void {
            const hovered = try hooks.useHover(self.scope, self.node);
            const pressed = if (specActiveNow(self.specNow(), t)) try hooks.usePressed(self.scope, self.cx, self.node) else null;
            self.ix.hovered = hovered;
            self.ix.pressed = pressed;
            try self.scope.createEffect(self, run);
        }

        fn resolveNow(spec: Spec, t: *const ThemeTokens, ix: Interact) BoxStyle {
            var s = resolveBox(if (is_static) static_spec else spec, t, false, ix);
            if (dir) |d| s.direction = d;
            return s;
        }

        fn resolveNowFor(comptime part: BoxPart, spec: Spec, t: *const ThemeTokens) BoxStyle {
            var s = resolveBoxFor(part, if (is_static) static_spec else spec, t, false, .{});
            if (part == .author) if (dir) |d| {
                s.direction = d;
            };
            return s;
        }

        fn run(self: *Self) void {
            self.apply(if (self.theme) |sig| sig.get() else self.cx.tokens, true);
        }

        fn apply(self: *Self, t: *const ThemeTokens, comptime tracked: bool) void {
            if (comptime has_loop) {
                const spec = if (is_static) static_spec else self.spec;
                self.syncLoop(specLoopOnNow(spec));
                var author = resolveBoxFor(.author, spec, t, tracked, self.ix);
                if (dir) |d| author.direction = d;
                const anim = resolveBoxFor(.animation, spec, t, tracked, self.ix);
                // Both layers swap, recalc once.
                const a = self.layer.replace(author);
                const b = self.anim_layer.replace(anim);
                if (self.layer.host) |h| {
                    if (a or b or h.stale) h.recompute();
                }
                return;
            }
            var next = if (is_static)
                resolveBox(static_spec, t, tracked, self.ix)
            else
                resolveBox(self.spec, t, tracked, self.ix);
            if (dir) |d| next.direction = d;
            self.layer.set(next);
        }

        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (comptime has_loop) self.anim_layer.detach();
            self.layer.detach();
            allocator.destroy(self);
        }

        /// Loop on: every frame recalc style per current phase; outside viewport doesn't advance or
        /// mark dirty, idle gate normal.
        fn tick(node: *Node) void {
            const self: *Self = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.view_loop orelse return));
            if (node.frame_state.state_bits.flags.out_of_viewport) return;
            self.apply(self.cx.tokens, false);
            node.markRenderDirty();
        }

        /// Hang / unlink before_render hook per loop on/off. One node, one loop (slot single).
        fn syncLoop(self: *Self, on: bool) void {
            if (on == self.loop_on) return;
            const slot = &self.node.meta.per_frame.hooks.slots.view_loop;
            if (on) {
                if (slot.* != null and slot.* != @as(*anyopaque, @ptrCast(self))) {
                    std.log.warn("ui.view.loop: node already runs another loop; only one loop per node", .{});
                    return;
                }
                self.node.addBeforeRender(tick);
                if (!hasHook(self.node)) {
                    // Hook ring full (8): not record on, next apply re-try, not permanent silent
                    // freeze.
                    std.log.warn("ui.view.loop: node has no free before_render slot; the loop is not running", .{});
                    return;
                }
                slot.* = @ptrCast(self);
                self.node.markRenderDirty();
            } else {
                self.node.removeBeforeRender(tick);
                if (slot.* == @as(*anyopaque, @ptrCast(self))) slot.* = null;
            }
            self.loop_on = on;
        }

        fn hasHook(node: *Node) bool {
            const h = &node.meta.per_frame.hooks.before_render;
            if (h.main == tick) return true;
            for (h.hooks[0..h.count]) |x| if (x == tick) return true;
            return false;
        }

        /// Scope destroy unlink hook; node already released (generation off)? touch nothing.
        fn detachLoop(self: *Self) void {
            if (!self.loop_on) return;
            const node = node_refs.resolveTrackedNode(&self.cx.node_registry, self.loop_handle, self.node) orelse return;
            node.removeBeforeRender(tick);
            if (node.meta.per_frame.hooks.slots.view_loop == @as(?*anyopaque, @ptrCast(self))) node.meta.per_frame.hooks.slots.view_loop = null;
            self.loop_on = false;
        }
    };
}

/// Switch last -> next: field set by last but next no longer, back to baseline,
/// reapply next. border family (whole + granular) if last touch, whole reset post-replay,
/// else "base set width, condition set color" undo leaves color residue. animated: change through
/// transition interpolation
/// (other change immediate: first apply, animation layer bring, value).
fn restyleBox(node: *Node, base: *const Baseline, last: BoxStyle, next: BoxStyle, animated: StyleChange, change: StyleChange, allocator: std.mem.Allocator) void {
    // border-color transition declared: pre-reset color interpolation start (border family change
    // whole reset to baseline first).
    const animate_border_color = animated.has("border_color") and if (node.frame_state.frame_local.runtime.transitions) |slots| slots.find(.border_color) != null else false;
    if (change.has("border_color") and !animated.has("border_color")) cancelTransition(node, .border_color);
    const border_color_before = node.style.border.color;
    const d = &base.style;
    const ext_d = &base.ext;
    const s = &node.style;
    var border_touched = false;
    @setEvalBranchQuota(4000);
    inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
        const was = @field(last, f.name) != null;
        if (comptime std.mem.startsWith(u8, f.name, "border")) {
            if (was) border_touched = true;
        } else if (was and @field(next, f.name) == null) {
            const name = f.name;
            if (comptime std.mem.eql(u8, name, "icon_color")) {
                // Tint not in Style: BoxRuntime.apply handle self (undo to mount tint).
            } else if (comptime std.mem.eql(u8, name, "background")) {
                node.setBackground(base.background);
            } else if (comptime std.mem.eql(u8, name, "opacity")) {
                node.setOpacity(base.opacity);
            } else if (comptime std.mem.eql(u8, name, "margin_spec")) {
                s.margin = d.margin;
                if (s.ext) |e| e.margin_auto_mask = ext_d.margin_auto_mask;
            } else if (comptime @hasField(types.Style, name)) {
                @field(s, name) = @field(d, name);
            } else if (s.ext) |e| {
                if (comptime std.mem.eql(u8, name, "corner_radius")) {
                    e.corner_radius = ext_d.corner_radius;
                } else if (comptime std.mem.eql(u8, name, "shadow") or std.mem.eql(u8, name, "shadows")) {
                    e.shadows = ext_d.shadows;
                    e.shadow_count = ext_d.shadow_count;
                } else if (comptime std.mem.eql(u8, name, "corner_radii")) {
                    e.corner_radius = ext_d.corner_radius;
                } else if (comptime std.mem.eql(u8, name, "inset_shadows")) {
                    e.inset_shadow = ext_d.inset_shadow;
                    e.extra_inset_shadows = ext_d.extra_inset_shadows;
                    e.extra_inset_count = ext_d.extra_inset_count;
                } else if (comptime std.mem.eql(u8, name, "text_color")) {
                    e.text_color = ext_d.text_color;
                } else if (comptime std.mem.eql(u8, name, "font_size")) {
                    e.text_font_size = ext_d.text_font_size;
                } else if (comptime std.mem.eql(u8, name, "font_weight")) {
                    e.text_font_weight = ext_d.text_font_weight;
                } else if (comptime @hasField(types.StyleExt, name)) {
                    @field(e, name) = @field(ext_d, name);
                } else {
                    @compileError("ui.view.restyleBox: no reset rule for BoxStyle." ++ name);
                }
            }
        }
    }
    if (border_touched) {
        s.border = d.border;
        if (s.ext) |e| e.border_side_colors = ext_d.border_side_colors;
    }
    // background / opacity / translate_x use transition setter (node declares matching transition
    // interpolate, else direct write);
    // rest field by applyTo land on Style.
    var rest = next;
    rest.background = null;
    rest.opacity = null;
    rest.translate_x = null;
    if (animate_border_color) rest.border_color = null;
    rest.applyTo(s, allocator);
    if (animate_border_color) if (next.border_color) |c| {
        s.border.color = border_color_before;
        node.setBorderColor(c);
    };
    if (change.has("background")) {
        if (next.background) |c| {
            if (animated.has("background")) node.setBackground(c) else {
                cancelTransition(node, .background);
                node.setBackgroundRaw(c);
                node.markRenderDirty();
            }
        }
    }
    if (change.has("translate_x")) {
        if (next.translate_x) |x| {
            if (animated.has("translate_x")) node.setTranslateX(x) else {
                cancelTransition(node, .translate_x);
                node.style.translate_x = x;
                node.markCompositePropDirty();
            }
        }
    }
    if (change.has("opacity")) {
        if (next.opacity) |o| {
            if (animated.has("opacity")) node.setOpacity(o) else {
                cancelTransition(node, .opacity);
                node.setOpacityRaw(o);
                node.markCompositePropDirty();
            }
        }
    }
    markStyleChanges(node, change);
}

/// Immediate field: stop its in-flight transition (else transition engine next frame interpolate
/// value back).
fn cancelTransition(node: *Node, prop: types.TransitionProp) void {
    const slots = node.frame_state.frame_local.runtime.transitions orelse return;
    const slot = slots.find(prop) orelse return;
    slot.active = false;
}

/// Field equality, including NaNs, without comparing undefined struct padding.
fn styleEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    return switch (@typeInfo(T)) {
        .float => a == b or (std.math.isNan(a) and std.math.isNan(b)),
        .optional => if (a) |av| (if (b) |bv| styleEql(av, bv) else false) else b == null,
        .@"struct" => blk: {
            inline for (@import("zenit_reflection").fields(T)) |f| {
                if (!styleEql(@field(a, f.name), @field(b, f.name))) break :blk false;
            }
            break :blk true;
        },
        .array => blk: {
            for (a, b) |av, bv| if (!styleEql(av, bv)) break :blk false;
            break :blk true;
        },
        .@"union" => blk: {
            const tag = std.meta.activeTag(a);
            if (tag != std.meta.activeTag(b)) break :blk false;
            inline for (@import("zenit_reflection").fields(T)) |f| {
                if (tag == @field(std.meta.Tag(T), f.name)) break :blk styleEql(@field(a, f.name), @field(b, f.name));
            }
            unreachable;
        },
        else => std.meta.eql(a, b),
    };
}

fn markStyleChanges(node: *Node, change: StyleChange) void {
    @setEvalBranchQuota(10000);
    var layout = false;
    var repaint = false;
    var composite = false;
    var interaction = false;
    inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
        if (change.has(f.name)) {
            const name = f.name;
            if (comptime std.mem.eql(u8, name, "background") or std.mem.eql(u8, name, "opacity")) {
                // Transition-aware setters already invalidate these properties.
            } else if (comptime inNames(name, &.{ "translate_x", "translate_y", "scale_x", "scale_y", "rotate", "transform_origin", "z_index" })) {
                composite = true;
            } else if (comptime inNames(name, &.{ "cursor", "hit_behavior", "hit_roles", "hit_shape", "tab_index" })) {
                interaction = true;
                if (comptime std.mem.eql(u8, name, "tab_index")) node.markRuntimeIndexDirty();
            } else if (comptime inNames(name, &.{ "corner_radius", "corner_radii", "clip_shape", "shape" })) {
                repaint = true;
                interaction = true;
            } else if (comptime inNames(name, &.{ "border_color", "border_top_color", "border_right_color", "border_bottom_color", "border_left_color", "shadow", "shadows", "inset_shadow", "inset_shadows", "outline", "gradient", "multi_gradient", "noise", "text_color", "overflow_fade", "icon_color" })) {
                repaint = true;
            } else {
                // Unknown/new properties conservatively invalidate layout as well.
                layout = true;
            }
        }
    }
    if (layout) node.markSizingDirty() else if (repaint) node.markRenderDirty();
    // This also discards baked display-list caches; layout invalidation alone does not.
    if (composite) node.markCompositePropDirty() else if (interaction) node.markInteractionDirty();
    if (change.has("z_index")) node.markOrderDirty();
}

fn inNames(comptime name: []const u8, comptime names: []const []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

// ---------- Text Style ----------

fn defaultText(t: *const ThemeTokens) TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = t.tokens.font_size.lg };
}

/// Text style: from theme default text style, stack in order. Whole style (function, TextStyle
/// value, styleBy)
/// swap current; css & style literal only change their declared field; v.when(cond, css or literal)
/// stack when true.
/// hovered: text node's own hover (build when style has _hover; null = unhovered).
fn resolveText(spec: anytype, t: *const ThemeTokens, comptime tracked: bool, hovered: ?*Signal(bool)) TextStyle {
    const T = @TypeOf(spec);
    if (comptime isTuple(T)) {
        var out = defaultText(t);
        inline for (@import("zenit_reflection").fields(T)) |f| out = layerText(out, @field(spec, f.name), t, tracked, hovered);
        return out;
    }
    return layerText(defaultText(t), spec, t, tracked, hovered);
}

fn layerText(base: TextStyle, spec: anytype, t: *const ThemeTokens, comptime tracked: bool, hovered: ?*Signal(bool)) TextStyle {
    const T = @TypeOf(spec);
    if (comptime isStyleFn(T, TextStyle)) return spec(t);
    if (T == TextStyle) return spec;
    if (comptime partKind(T)) |k| {
        switch (k) {
            .style_by => {
                if (T.Out != TextStyle) @compileError("ui.view.styleBy on text: f must return TextStyle");
                return T.f(readSource(T.Arg, spec.src, tracked), t);
            },
            .css => {
                const s = T.text(base, t);
                return if (T.has_hover and Interact.readFlag(hovered, tracked)) T.textHover(s, t) else s;
            },
            .when => {
                comptime if (!isPartialText(@TypeOf(T.part)))
                    @compileError("ui.view.text: v.when on text takes a ui.css(...) value or a style literal (a partial style that can be layered)");
                return if (readSource(bool, spec.cond, tracked)) layerText(base, T.part, t, tracked, hovered) else base;
            },
            .hover => @compileError("ui.view.text: hover styles apply to boxes; put the text in a box and style that"),
            .loop => @compileError("ui.view.text: v.loop animates boxes; put the text in a box and animate that"),
            .states_by => @compileError("ui.view.text: v.statesBy applies to boxes; text takes styleBy / cva"),
            .param => @compileError("ui.view.text: a parameterized style applies to boxes; style the text with a plain style or recipe, or put the parameterized style in box="),
            .cva => return T.R.resolveText(readVariants(T, spec, tracked), base, t),
            else => unreachable,
        }
    }
    if (comptime @typeInfo(T) == .@"struct" and !isTuple(T)) {
        comptime if (css_mod.specError(T, false)) |msg| @compileError("ui.view.text style literal: " ++ msg);
        return css_mod.textFrom(spec, base, t);
    }
    @compileError("ui.view: unsupported text style " ++ @typeName(T) ++
        ". Expected a fn (*const ThemeTokens) TextStyle, a TextStyle value, a style literal, ui.css(...), v.when, v.styleBy, or a tuple of those");
}

/// Partial field change, stackable text style: css value or style literal.
/// Whether text style has _hover (css part).
fn textHover(comptime T: type) bool {
    if (partKind(T)) |k| return switch (k) {
        .css => T.has_hover,
        .when => textHover(@TypeOf(T.part)),
        else => false,
    };
    if (isTuple(T)) {
        for (@import("zenit_reflection").fields(T)) |f| if (textHover(f.type)) return true;
    }
    return false;
}

fn isPartialText(comptime P: type) bool {
    if (partKind(P)) |k| return k == .css;
    return @typeInfo(P) == .@"struct" and !isTuple(P) and P != TextStyle;
}

fn TextPlan(comptime Props: type) type {
    const has_style = @hasField(Props, "style");
    const Spec = if (has_style) @FieldType(Props, "style") else void;
    const spec_field: ?@import("zenit_reflection").StructField = if (has_style) blk: {
        for (@import("zenit_reflection").fields(Props)) |f| if (std.mem.eql(u8, f.name, "style")) break :blk f;
        unreachable;
    } else null;
    const spec_comptime = if (spec_field) |f| f.is_comptime else true;
    const reactive_spec = has_style and specReactive(Spec);
    // Text style stack from theme default (resolveText), whole TextStyle value doesn't read theme.
    const themed = !has_style or Spec != TextStyle;
    const Mode = enum { plain, theme_hook, dynamic };
    const mode: Mode = if (reactive_spec or (themed and !spec_comptime)) .dynamic else if (themed) .theme_hook else .plain;

    return struct {
        fn initial(props: Props, t: *const ThemeTokens) TextStyle {
            if (!has_style) return defaultText(t);
            return resolveText(props.style, t, false, null);
        }

        const transitions = if (has_style) specTransitions(Spec) else &[_]recipe_entry.TransitionEntry{};

        fn attach(props: Props, scope: *Scope, cx: *Cx, node: *Node) !void {
            if (comptime transitions.len > 0) node.applyTransition(cx.allocator, transitions);
            switch (mode) {
                .plain => {},
                .theme_hook => {
                    node.meta.per_frame.hooks.on_theme = struct {
                        fn hook(n: *Node, t: *const ThemeTokens, _: std.mem.Allocator) void {
                            if (!has_style) return applyTextStyle(n, defaultText(t));
                            const spec = comptime spec_field.?.defaultValue().?;
                            applyTextStyle(n, resolveText(spec, t, false, null));
                        }
                    }.hook;
                },
                .dynamic => {
                    const State = struct {
                        node: *Node,
                        cx: *Cx,
                        spec: Spec,
                        theme: *Signal(*const ThemeTokens),
                        hovered: ?*Signal(bool) = null,
                        link: ThemeLink = undefined,
                        fn run(st: *@This()) void {
                            applyTextStyle(st.node, resolveText(st.spec, st.theme.get(), true, st.hovered));
                        }
                        fn replay(r: *ViewThemeReplay, t: *const ThemeTokens) void {
                            const link: *ThemeLink = @fieldParentPtr("replay", r);
                            const st: *@This() = @fieldParentPtr("link", link);
                            applyTextStyle(st.node, resolveText(st.spec, t, false, st.hovered));
                        }
                        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                            allocator.destroy(@as(*@This(), @ptrCast(@alignCast(ptr))));
                        }
                    };
                    const theme_sig = try cx.themeSignal(rootScopeOf(scope));
                    // Style has _hover: build hover signal on text node (link hover color).
                    const hovered: ?*Signal(bool) = if (comptime textHover(Spec)) try hooks.useHover(scope, node) else null;
                    const st = try scope.allocator.create(State);
                    st.* = .{ .node = node, .cx = cx, .spec = props.style, .theme = theme_sig, .hovered = hovered };
                    try scope.adoptResource(@ptrCast(st), State.destroy);
                    // Data source all static now & no hover: only changes with theme, hang theme
                    // replay, no effect.
                    if (hovered == null and specStaticNow(props.style, cx.tokens)) return st.link.attach(scope, cx, node, State.replay);
                    try scope.createEffect(st, State.run);
                },
            }
        }
    };
}

/// Write all TextStyle field to text node (content unchanged). Same as last? don't mark dirty.
fn applyTextStyle(node: *Node, s: TextStyle) void {
    var props = node.getText() orelse return;
    // text_color transition declared: color use transition setter, rest field normal.
    const animate_color = if (node.frame_state.frame_local.runtime.transitions) |slots| slots.find(.text_color) != null else false;
    var styled = s;
    if (animate_color) styled.color = props.color;
    if (animate_color) node.setTextColor(s.color);
    if (!styled.applyTo(&props)) return;
    // content pointer unchanged: ContentTable.setText pointer guard ensure don't free owned content
    // wrongly.
    node.setText(props);
    node.markLayoutDirty();
}

// Internal helpers

/// Anonymous struct literal -> named style struct. Literal via anytype already independent struct
/// type,
/// no whole cast, field-by-field assign; nested literal (.width = .{ .px = 80 }, .padding = .{ .top
/// = 4 }) recursive:
/// target struct? each field, tagged union? unique field @unionInit, rest implicit convert (number,
/// enum literal, same type).
/// Public to component: receive anytype style / property param (like ControlShell slot style)
/// convert to named type.
pub fn literalAs(comptime Target: type, lit: anytype) Target {
    return coerceLiteral(Target, lit);
}

fn coerceLiteral(comptime Target: type, value: anytype) Target {
    const V = @TypeOf(value);
    if (V == Target) return value;
    switch (@typeInfo(Target)) {
        .optional => |o| {
            if (V == @TypeOf(null)) return null;
            return coerceLiteral(o.child, value);
        },
        // .{} (empty tuple) = struct all defaults.
        .@"struct" => if (@typeInfo(V) == .@"struct" and (!@typeInfo(V).@"struct".is_tuple or @import("zenit_reflection").fields(V).len == 0)) {
            inline for (@import("zenit_reflection").fields(V)) |f| {
                if (!@hasField(Target, f.name)) @compileError(@typeName(Target) ++ " has no field ." ++ f.name);
            }
            var out: Target = undefined;
            inline for (@import("zenit_reflection").fields(Target)) |tf| {
                if (@hasField(V, tf.name)) {
                    @field(out, tf.name) = coerceLiteral(tf.type, @field(value, tf.name));
                } else if (tf.defaultValue()) |d| {
                    @field(out, tf.name) = d;
                } else {
                    @compileError(@typeName(Target) ++ " literal is missing field ." ++ tf.name);
                }
            }
            return out;
        },
        .@"union" => |u| if (u.tag_type != null and @typeInfo(V) == .@"struct" and !@typeInfo(V).@"struct".is_tuple) {
            const fields = @import("zenit_reflection").fields(V);
            if (fields.len != 1) @compileError(@typeName(Target) ++ " literal must set exactly one field");
            const name = fields[0].name;
            if (!@hasField(Target, name)) @compileError(@typeName(Target) ++ " has no variant ." ++ name);
            return @unionInit(Target, name, coerceLiteral(@FieldType(Target, name), @field(value, name)));
        },
        else => {},
    }
    const out: Target = value;
    return out;
}

/// .visible = bool or bool source: switch display (none no space/hit/a11y),
/// subtree & state keep -- complement v.show unmount rebuild, fit frequent toggle, state retain.
fn bindVisible(scope: *Scope, node: *Node, props: anytype) !void {
    if (!@hasField(@TypeOf(props), "visible")) return;
    try bind_mod.bind(scope, sourceOf(bool, "ui.view .visible", props.visible), node, struct {
        fn apply(n: *Node, shown: bool) void {
            n.setDisplay(if (shown) .flex else .none);
        }
    }.apply);
}

fn applyAttrs(node: *Node, props: anytype) void {
    const P = @TypeOf(props);
    // test_id at mount (component pass prop as Source, take current value).
    if (@hasField(P, "test_id")) node.meta.ownership.meta.test_id = if (comptime isSourceUnion(@TypeOf(props.test_id))) props.test_id.peek() else props.test_id;
    if (@hasField(P, "a11y")) node.behavior.interaction.a11y = a11yOf(props.a11y);
    if (@hasField(P, "on_click")) node.behavior.events.on_click = props.on_click;
    if (@hasField(P, "on_focus")) node.behavior.events.on_focus = props.on_focus;
    if (@hasField(P, "on_blur")) node.behavior.events.on_blur = props.on_blur;
    if (@hasField(P, "on_hover")) hooks.setHoverHandler(node, true, props.on_hover);
    if (@hasField(P, "on_leave")) hooks.setHoverHandler(node, false, props.on_leave);
    // Semantic tag (.button / .input ...): hit, a11y & keyboard activate per tag.
    if (@hasField(P, "tag")) node.tag = props.tag;
    // Focusable (Tab order / click focus); can be bool source (exit Tab order when disabled), see
    // bindFocus.
    if (@hasField(P, "window_region")) node.behavior.interaction.window_region = coerceLiteral(@import("system_sdk").window_chrome.Region, props.window_region);
    if (@hasField(P, "focusable")) node.setFocusable(sourceOf(bool, "ui.view .focusable", props.focusable).peek());
    if (@hasField(P, "hit_test")) node.setHitTestVisible(props.hit_test);
    // Low-level generic event callback (GenericEventCallback) & context; can be source (mount take
    // value, changing callback effect next).
    if (@hasField(P, "on_event")) node.behavior.events.on_event = peekMaybeSource(props.on_event);
    if (@hasField(P, "event_context")) node.behavior.events.event_context = peekMaybeSource(props.event_context);
}

// -- Typed event of host element (Yix onKeyDown={|e| ...} etc) --
// Handler default doesn't intercept; e.consume() prevent default (Tab focus jump, space / enter
// synthesize click, scroll container scroll),
// e.stop() further stop ancestor propagate. Event bubble parent chain: child element event,
// ancestor handler also get.

/// Event result write slot (all event value share). Valid during handler sync call only:
/// save event value, later call consume / stop writes already-returned dispatch stack.
pub const EventFlow = struct {
    result: *events.EventResult,
    /// Prevent default.
    pub fn consume(self: EventFlow) void {
        if (self.result.* == .ignored) self.result.* = .handled;
    }
    /// Prevent default & stop propagate.
    pub fn stop(self: EventFlow) void {
        self.result.* = .stop;
    }
};

/// Keyboard event value (onKeyDown / onKeyUp). Only fires to focused element & ancestor.
pub const KeyPress = struct {
    key: events.KeyCode,
    modifiers: events.Modifiers,
    raw_keycode: u16,
    flow: EventFlow,
    pub fn consume(self: KeyPress) void {
        self.flow.consume();
    }
    pub fn stop(self: KeyPress) void {
        self.flow.stop();
    }
};

/// Pointer event value (onPointerDown / onPointerMove / onPointerUp). x / y relative receiver
/// element top-left,
/// window_x / window_y window coord; move include this movement dx / dy. After down, move continue
/// to down element.
pub const Pointer = struct {
    x: f32,
    y: f32,
    window_x: f32,
    window_y: f32,
    dx: f32 = 0,
    dy: f32 = 0,
    button: events.MouseButton = .left,
    modifiers: events.Modifiers,
    flow: EventFlow,
    pub fn consume(self: Pointer) void {
        self.flow.consume();
    }
    pub fn stop(self: Pointer) void {
        self.flow.stop();
    }
};

/// Scroll event value (onScroll): wheel / trackpad movement & gesture phase, coord same as Pointer.
pub const Scroll = struct {
    dx: f32,
    dy: f32,
    x: f32,
    y: f32,
    window_x: f32,
    window_y: f32,
    phase: events.ScrollPhase,
    momentum: events.MomentumPhase,
    modifiers: events.Modifiers,
    flow: EventFlow,
    pub fn consume(self: Scroll) void {
        self.flow.consume();
    }
    pub fn stop(self: Scroll) void {
        self.flow.stop();
    }
};

const typed_event_props = .{
    .{ "on_key_down", KeyPress },
    .{ "on_key_up", KeyPress },
    .{ "on_pointer_down", Pointer },
    .{ "on_pointer_move", Pointer },
    .{ "on_pointer_up", Pointer },
    .{ "on_scroll", Scroll },
};

fn hasTypedEvents(comptime P: type) bool {
    inline for (typed_event_props) |e| if (@hasField(P, e[0])) return true;
    return false;
}

/// Handler prop value -> Handler(T): Handler(T) itself, Yix-generated pending handler (bindAny), or
/// null.
fn typedHandler(comptime T: type, x: anytype) ?core.Handler(T) {
    const X = @TypeOf(x);
    if (X == @TypeOf(null)) return null;
    if (X == core.Handler(T) or X == ?core.Handler(T)) return x;
    if (@typeInfo(X) == .@"struct" and @hasDecl(X, "zenit_any_handler")) return x.as(T);
    @compileError("ui.view: expected a Handler(" ++ @typeName(T) ++ "), got " ++ @typeName(X));
}

fn bindTypedEvents(scope: *Scope, node: *Node, props: anytype) !void {
    return bindTypedEventsAt(.bubble, scope, node, props);
}

/// .bubble: host element's own on_event (target / bubble phase); .capture: component root
/// on_event_capture
/// (own capture_context, component on_event unaffected). Fail mount if capture slot taken.
fn bindTypedEventsAt(comptime slot: enum { bubble, capture }, scope: *Scope, node: *Node, props: anytype) !void {
    const P = @TypeOf(props);
    if (comptime !hasTypedEvents(P)) return;
    if (slot == .bubble and @hasField(P, "on_event")) @compileError("ui.view: on_event (the raw event callback) cannot be combined with on_key_down / on_pointer_* / on_scroll on one element");
    if (slot == .capture and node.behavior.events.on_event_capture != null) {
        std.log.err("ui.view: the component's root already has a capture handler; onKeyDown / onPointer* / onScroll cannot be attached to it", .{});
        return error.ViewCaptureSlotTaken;
    }
    const Table = struct {
        node: *Node,
        on_key_down: ?core.Handler(KeyPress) = null,
        on_key_up: ?core.Handler(KeyPress) = null,
        on_pointer_down: ?core.Handler(Pointer) = null,
        on_pointer_move: ?core.Handler(Pointer) = null,
        on_pointer_up: ?core.Handler(Pointer) = null,
        on_scroll: ?core.Handler(Scroll) = null,

        /// Unlink adapter from node at scope release (node alive during scope release): blur etc
        /// event on unlink still
        /// dispatch per on_event, can't reach released Table.
        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const t: *@This() = @ptrCast(@alignCast(ptr));
            const ev = &t.node.behavior.events;
            if (slot == .bubble and ev.on_event == &dispatch and ev.event_context == @as(?*anyopaque, @ptrCast(t))) {
                ev.on_event = null;
                ev.event_context = null;
            }
            if (slot == .capture and ev.on_event_capture == &dispatch and ev.capture_context == @as(?*anyopaque, @ptrCast(t))) {
                ev.on_event_capture = null;
                ev.capture_context = null;
            }
            allocator.destroy(t);
        }

        fn dispatch(event: events.Event, raw: ?*anyopaque) events.EventResult {
            const t: *@This() = @ptrCast(@alignCast(raw.?));
            var result: events.EventResult = .ignored;
            const flow: EventFlow = .{ .result = &result };
            switch (event) {
                .key_down, .key_up => |k| {
                    const h = if (event == .key_down) t.on_key_down else t.on_key_up;
                    if (h) |cb| cb.call(.{ .key = k.key, .modifiers = k.modifiers, .raw_keycode = k.raw_keycode, .flow = flow });
                },
                .mouse_down, .mouse_up => |m| {
                    const h = if (event == .mouse_down) t.on_pointer_down else t.on_pointer_up;
                    const r = t.node.rectFromWorldOrFallback();
                    if (h) |cb| cb.call(.{ .x = m.x - r.x, .y = m.y - r.y, .window_x = m.x, .window_y = m.y, .button = m.button, .modifiers = m.modifiers, .flow = flow });
                },
                .mouse_move => |m| if (t.on_pointer_move) |cb| {
                    const r = t.node.rectFromWorldOrFallback();
                    cb.call(.{ .x = m.x - r.x, .y = m.y - r.y, .window_x = m.x, .window_y = m.y, .dx = m.dx, .dy = m.dy, .modifiers = m.modifiers, .flow = flow });
                },
                .scroll => |e| if (t.on_scroll) |cb| {
                    const r = t.node.rectFromWorldOrFallback();
                    cb.call(.{ .dx = e.dx, .dy = e.dy, .x = e.x - r.x, .y = e.y - r.y, .window_x = e.x, .window_y = e.y, .phase = e.phase, .momentum = e.momentum, .modifiers = e.modifiers, .flow = flow });
                },
                else => {},
            }
            // Component root (capture slot): consume = "this event not to component" -- capture
            // phase only stop can intercept target & component own.
            if (slot == .capture and result == .handled) return .stop;
            return result;
        }
    };
    // Component root (capture): table register to scope hung on root node (component own scope).
    // It's child of caller scope,
    // release with root node -- table neither outlive node nor outlive handler context in caller
    // scope.
    const owner = if (slot == .capture) (node.meta.ownership.scope.scope orelse scope) else scope;
    const t = try owner.allocator.create(Table);
    t.* = .{ .node = node };
    try owner.adoptResource(@ptrCast(t), Table.destroy);
    inline for (typed_event_props) |e| {
        if (@hasField(P, e[0])) @field(t, e[0]) = typedHandler(e[1], @field(props, e[0]));
    }
    switch (slot) {
        .bubble => {
            node.behavior.events.on_event = Table.dispatch;
            node.behavior.events.event_context = @ptrCast(t);
        },
        .capture => {
            node.behavior.events.on_event_capture = Table.dispatch;
            node.behavior.events.capture_context = @ptrCast(t);
        },
    }
}

fn peekMaybeSource(x: anytype) PeekType(@TypeOf(x)) {
    const X = @TypeOf(x);
    if (comptime isReactiveSource(X)) return sourceOf(reactive.SourceValueOf(X), "ui.view attribute", x).peek();
    return x;
}

fn PeekType(comptime X: type) type {
    return if (isReactiveSource(X)) reactive.SourceValueOf(X) else X;
}

/// .a11y receive A11yProps / ?A11yProps or anonymous literal .{ .role = .button, .label = "x" }.
/// Literal field can be reactive source (.live = level, .live_text = message): mount take current
/// value,
/// after follow source (see bindA11y).
fn a11yOf(x: anytype) ?types.A11yProps {
    const X = @TypeOf(x);
    if (X == types.A11yProps or X == ?types.A11yProps or X == @TypeOf(null)) return x;
    if (comptime a11yWholeSource(X)) return x.peek();
    if (comptime a11yReactive(X)) return a11yNow(x, false);
    return coerceLiteral(types.A11yProps, x);
}

/// Whole a11y is source (Source(?A11yProps)): semantic appears / disappears with data (interactive
/// only then button).
fn a11yWholeSource(comptime X: type) bool {
    if (!isSourceUnion(X)) return false;
    const V = reactive.SourceValueOf(X);
    return V == types.A11yProps or V == ?types.A11yProps;
}

fn a11yReactive(comptime X: type) bool {
    if (@typeInfo(X) != .@"struct" or X == types.A11yProps) return false;
    for (@import("zenit_reflection").fields(X)) |f| if (isReactiveSource(f.type)) return true;
    return false;
}

fn a11yNow(x: anytype, comptime tracked: bool) types.A11yProps {
    var out: types.A11yProps = .{};
    inline for (@import("zenit_reflection").fields(@TypeOf(x))) |f| {
        const v = @field(x, f.name);
        @field(out, f.name) = if (comptime isReactiveSource(f.type)) readSource(reactive.SourceValueOf(f.type), v, tracked) else v;
    }
    return out;
}

/// .focusable is bool source, enter / exit Tab order per value; .focus_ring = true (or
/// FocusRingConfig) draw
/// focus ring on keyboard focus gain (hooks.useFocusRing, same impl as hand-written component).
fn bindFocus(scope: *Scope, cx: *Cx, node: *Node, props: anytype) !void {
    const P = @TypeOf(props);
    if (@hasField(P, "focusable")) {
        const src = sourceOf(bool, "ui.view .focusable", props.focusable);
        if (!src.isStatic()) try bind_mod.bind(scope, src, node, struct {
            fn apply(n: *Node, on: bool) void {
                n.setFocusable(on);
            }
        }.apply);
    }
    if (@hasField(P, "focus_ring")) {
        const R = @TypeOf(props.focus_ring);
        if (R == bool) {
            if (props.focus_ring) try hooks.useFocusRing(scope, cx, node, .{});
        } else if (comptime isReactiveSource(R)) {
            const src = sourceOf(hooks.FocusRingConfig, "ui.view .focus_ring", props.focus_ring);
            try hooks.useFocusRing(scope, cx, node, src.peek());
            if (!src.isStatic()) try bind_mod.bind(scope, src, .{ .cx = cx, .node = node }, struct {
                fn apply(c: anytype, config: hooks.FocusRingConfig) void {
                    hooks.updateFocusRingConfig(c.cx, c.node, config);
                }
            }.apply);
        } else try hooks.useFocusRing(scope, cx, node, coerceLiteral(hooks.FocusRingConfig, props.focus_ring));
    }
}

fn followEventField(scope: *Scope, node: *Node, comptime field: []const u8, x: anytype) !void {
    const V = reactive.SourceValueOf(@TypeOf(x));
    const src = sourceOf(V, "ui.view ." ++ field, x);
    if (src.isStatic()) return;
    const State = struct {
        node: *Node,
        src: reactive.Source(V),
        /// Last value written to node (mount applyAttrs wrote peek).
        last: V,
        /// Spotted later writer: cede forever (later even write back same as last, no reclaim).
        yielded: bool = false,
        fn run(st: *@This()) void {
            const next = st.src.get();
            if (st.yielded) return;
            if (@field(st.node.behavior.events, field) != st.last) {
                st.yielded = true;
                return;
            }
            @field(st.node.behavior.events, field) = next;
            st.last = next;
        }
    };
    const st = try scope.createState(State, .{ .node = node, .src = src, .last = src.peek() });
    try scope.createEffect(st, State.run);
}

/// Reactive a11y field: source all static now? mount value is final; else effect recalc whole
/// property write back node
/// (a11y read in-frame, old content from source swap retire next frame, pointer won't dangle).
fn bindA11y(scope: *Scope, node: *Node, props: anytype) !void {
    const P = @TypeOf(props);
    // Changing low-level event callback (component gives null / callback per disabled) & context
    // each follow source
    // write back node (paired use no "new callback + old context"). Bypass host direct node value
    // rewrite: only update when
    // node still own prior value, don't override others' write.
    if (comptime @hasField(P, "on_event") and isReactiveSource(@TypeOf(props.on_event))) {
        try followEventField(scope, node, "on_event", props.on_event);
    }
    if (comptime @hasField(P, "event_context") and isReactiveSource(@TypeOf(props.event_context))) {
        try followEventField(scope, node, "event_context", props.event_context);
    }
    if (!@hasField(P, "a11y")) return;
    const A = @TypeOf(props.a11y);
    if (comptime a11yWholeSource(A)) {
        if (props.a11y.isStatic()) return;
        return scope.createEffect(.{ .node = node, .a11y = props.a11y }, struct {
            fn run(c: anytype) void {
                c.node.behavior.interaction.a11y = c.a11y.get();
            }
        }.run);
    }
    if (comptime !a11yReactive(A)) return;
    var all_static = true;
    inline for (@import("zenit_reflection").fields(A)) |f| {
        if (comptime isReactiveSource(f.type)) all_static = all_static and sourceStaticNow(@field(props.a11y, f.name));
    }
    if (all_static) return;
    try scope.createEffect(.{ .node = node, .a11y = props.a11y }, struct {
        fn run(c: anytype) void {
            c.node.behavior.interaction.a11y = a11yNow(c.a11y, true);
        }
    }.run);
}

fn checkProps(comptime Props: type, comptime allowed: []const []const u8, comptime who: []const u8) void {
    @setEvalBranchQuota(20_000);
    if (@typeInfo(Props) != .@"struct")
        @compileError(who ++ ": props must be a struct literal like .{ .style = S.card }, got " ++ @typeName(Props));
    // .{} empty tuple: same as no prop pass.
    if (@typeInfo(Props).@"struct".is_tuple and @import("zenit_reflection").fields(Props).len != 0)
        @compileError(who ++ ": props must be a struct literal like .{ .style = S.card }, got a tuple — children go in the second argument");
    outer: for (@import("zenit_reflection").fields(Props)) |f| {
        for (allowed) |a| if (std.mem.eql(u8, a, f.name)) continue :outer;
        var names: []const u8 = "";
        for (allowed, 0..) |a, i| names = names ++ (if (i == 0) "" else ", ") ++ a;
        @compileError(who ++ ": unknown prop ." ++ f.name ++ " (allowed: " ++ names ++ ")");
    }
}

/// Children non-empty? (void, empty tuple empty; array / other element non-empty).
fn hasChildren(comptime C: type) bool {
    if (C == void) return false;
    if (isTuple(C)) return @import("zenit_reflection").fields(C).len != 0;
    return true;
}

fn isTuple(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
}

fn isViewElement(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => @hasDecl(T, "zenit_view_element"),
        else => false,
    };
}

fn isComponent(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !@hasDecl(T, "zenit_view_element") and
        (@hasDecl(T, "mount") or @hasDecl(T, "viewMount"));
}

fn isFmt(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zenit_view_fmt");
}

fn isStringLike(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    return switch (info.pointer.size) {
        .slice => info.pointer.child == u8,
        .one => @typeInfo(info.pointer.child) == .array and @typeInfo(info.pointer.child).array.child == u8,
        else => false,
    };
}

fn isReactiveSource(comptime X: type) bool {
    const container = switch (@typeInfo(X)) {
        .@"struct", .@"union" => true,
        else => false,
    };
    if (container and @hasDecl(X, "zenit_source")) return true;
    return source_kinds.reactiveKindOf(X) != null;
}

fn SourceValue(comptime X: type) type {
    return if (isReactiveSource(X)) reactive.SourceValueOf(X) else X;
}

/// Static value or any reactive source -> Source(T).
fn sourceOf(comptime T: type, comptime who: []const u8, x: anytype) reactive.Source(T) {
    const X = @TypeOf(x);
    if (comptime isReactiveSource(X)) {
        const V = reactive.SourceValueOf(X);
        if (V != T) @compileError(who ++ ": expected a source of " ++ @typeName(T) ++ ", got " ++ @typeName(X));
        return reactive.toSource(x);
    }
    const v: T = x;
    return .{ .value = v };
}

fn requireSingle(comptime T: type, comptime who: []const u8) void {
    if (T == *Node) return;
    if (isViewElement(T)) {
        if (!T.view_single) @compileError(who ++ ": needs a single-node element (box / row / col / text / a component), got control flow " ++ @typeName(T) ++ " — wrap it in v.box");
        return;
    }
    if (isComponent(T)) return;
    if (isStringLike(T)) @compileError(who ++ ": wrap the string in v.text(...)");
    @compileError(who ++ ": needs a single-node element, got " ++ @typeName(T));
}

/// Scope tree root: theme signal hangs here, lifecycle cover all subscriber
/// (cx.themeSignal cache release with scope making it, hang short-live child scope dangle).
fn rootScopeOf(scope: *Scope) *Scope {
    var s = scope;
    while (s.parent) |p| s = p;
    return s;
}

test {
    _ = @import("view_tests.zig");
    _ = @import("css.zig");
}
