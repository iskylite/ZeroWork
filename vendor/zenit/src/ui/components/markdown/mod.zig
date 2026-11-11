/// Markdown read-only renderer (render only, no editing).
///
/// For rich-text tooltips, simple doc display on about/settings pages, any "display an existing
/// markdown string" case. **Not** for WYSIWYG editing; real editors couple parser to editing and
/// are built atop zenit as app code.
///
/// Design principles:
/// - Single-pass byte scan -> flat Block array (each Block embeds Inline spans)
/// - Inline spans render via TextSpan (bold/italic/code), not split text nodes
/// - `![alt](data:...)` degrades to a `[alt]` text chip, never fetches images
/// - `<http://...>` autolinks are not expanded, flattened to plain text
/// - Unclosed fence / malformed input is fuzz-safe: forced flush at end
///
/// Not supported (explicit non-goals):
///   - nested lists, setext headings, task lists, footnotes, definition lists, HTML passthrough
///   - tables (use a dedicated markdown editor)
///   - image fetching
///
/// Consumer:
/// ```zig
/// const result = try markdown.Markdown(text, .{
///     .base_font_size = 12,
///     .theme = my_theme,
/// }).render(cx);
/// try parent.appendChild(cx.allocator, result.root);
/// ```
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const bind_mod = @import("../../bind.zig");

const Cx = core.Cx;
const Node = core.Node;
const Color = core.Color;
const Padding = core.Padding;
const TextSpan = core.TextSpan;
const box = core.box;

// ============================================================================
// Public API
// ============================================================================

pub const MarkdownOptions = struct {
    base_font_size: f32 = 12,
    /// Font size for code regions (default slightly smaller than body).
    code_font_size: f32 = 11,
    /// Body text color.
    text_color: Color = Color.hex(0x1F1F1F),
    /// Inline code / fenced code font color.
    code_color: Color = Color.hex(0x2F2F35),
    /// Inline code / fenced code background.
    code_bg: Color = Color.hex(0xF5F5F7),
    /// Link text color.
    link_color: Color = Color.hex(0x0B63CE),
    /// Horizontal rule color.
    rule_color: Color = Color.hex(0xE0E0E4),
    /// Heading color (inherit text_color if null).
    heading_color: ?Color = null,
    /// Vertical spacing between paragraphs.
    paragraph_gap: f32 = 4,
    /// Line spacing inside code block.
    code_line_height: f32 = 1.35,
    /// Body line spacing.
    line_height: f32 = 1.4,
};

// ============================================================================
// Style layer extracted to styles.zig, emitter only consumes, no visual decisions here
// ============================================================================

const styles = @import("styles.zig");
const mdRootStyle = styles.mdRootStyle;
const mdHeadingSizeMul = styles.mdHeadingSizeMul;
const mdCodeBlockStyle = styles.mdCodeBlockStyle;
const mdCodeLineText = styles.mdCodeLineText;
const mdRuleStyle = styles.mdRuleStyle;
const mdBlockquoteStyle = styles.mdBlockquoteStyle;
const mdBlockquoteBarStyle = styles.mdBlockquoteBarStyle;
const mdBlockquoteBodyStyle = styles.mdBlockquoteBodyStyle;
const mdListRowStyle = styles.mdListRowStyle;
const mdListMarkerText = styles.mdListMarkerText;
const mdCodeSpanStyle = styles.mdCodeSpanStyle;
const mdImageChipSpanStyle = styles.mdImageChipSpanStyle;
const mdLinkSpanStyle = styles.mdLinkSpanStyle;
const mdBoldSpanStyle = styles.mdBoldSpanStyle;
const mdItalicSpanStyle = styles.mdItalicSpanStyle;

/// Markdown attributes.
pub const MarkdownProps = struct {
    /// Text (can pass signal/derived: content or buffer address change triggers full reflow). Node
    /// borrows text bytes: static text must outlive component unmount; owned-buffer signal
    /// (`scope.createText`) remains valid after next write, covering reflow window before render.
    text: Source([]const u8),
    options: MarkdownOptions = .{},
};

/// Create Markdown: `W.Markdown(.{ .text = doc, .options = .{ .base_font_size = 13 }
/// }).mount(scope, cx)`.
pub fn Markdown(props: anytype) MarkdownBuilder {
    return .{ .props = reactive.props.coerce(MarkdownProps, props) };
}

pub const MarkdownBuilder = struct {
    props: MarkdownProps,

    pub fn mount(self: MarkdownBuilder, scope: *Scope, cx: *Cx) !*Node {
        const p = self.props;
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const container = try view.render(my_scope, cx, view.box(.{ .style = mdRootStyle(p.options) }, {}));
        // Sweep: if renderInto fails mid-way, container (with already-mounted blocks) can't leak.
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Markdown";
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;
        const Ctx = struct { cx: *Cx, options: MarkdownOptions };
        try bind_mod.rebuildOn(cx, my_scope, p.text, container, Ctx{ .cx = cx, .options = p.options }, struct {
            fn key(text: []const u8) u64 {
                var h = std.hash.Wyhash.init(0);
                h.update(text);
                h.update(std.mem.asBytes(&@intFromPtr(text.ptr)));
                return h.final();
            }
        }.key, struct {
            fn build(c: Ctx, rebuild_scope: *Scope, host: *Node, text: []const u8) !void {
                try renderBlocks(rebuild_scope, c.cx, host, text, c.options);
            }
        }.build);
        return container;
    }
};

/// Append markdown directly to an existing container (no outer wrapper); fits embedding into a
/// pre-laid popup/panel.
///
/// **Lifetime**: emitted Nodes' `text.content` slices borrow from `text` until Node destroy; the
/// caller **must ensure `text` outlives Node destroy** (typical: hold `current_text: ?[]u8`, free
/// the old buffer and pass a new one on each refresh). The component never allocates/frees
/// intermediate buffers; the caller owns text.
pub fn renderInto(cx: *Cx, container: *Node, text: []const u8, opts: MarkdownOptions) !void {
    // Block elements are static (no effect, no binding, nodes don't reference scope), mount-time
    // scope lives only this call; Markdown walks renderBlocks with rebuildOn's rebuild scope.
    const tmp_scope = try Scope.init(cx.allocator, null, cx.owner);
    defer tmp_scope.dispose();
    try renderBlocks(tmp_scope, cx, container, text, opts);
}

fn renderBlocks(scope: *Scope, cx: *Cx, container: *Node, text: []const u8, opts: MarkdownOptions) !void {
    const allocator = cx.allocator;
    var scanner = BlockScanner{ .src = text };
    while (try scanner.next(allocator)) |block| {
        switch (block) {
            .paragraph => |lines| try emitParagraph(scope, cx, container, lines, opts),
            .heading => |h| try emitHeading(scope, cx, container, h.level, h.text, opts),
            .code_block => |c| try emitCodeBlock(scope, cx, container, c.content, opts),
            .rule => try emitRule(scope, cx, container, opts),
            .blockquote => |q| try emitBlockquote(scope, cx, container, q, opts),
            .list_item => |li| try emitListItem(scope, cx, container, li.ordered, li.marker, li.text, opts),
        }
    }
}

// ============================================================================
// Block scanner
// ============================================================================

const Block = union(enum) {
    paragraph: []const u8,
    heading: struct { level: u8, text: []const u8 },
    code_block: struct { content: []const u8 },
    rule: void,
    blockquote: []const u8,
    list_item: struct { ordered: bool, marker: []const u8, text: []const u8 },
};

const BlockScanner = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(self: *BlockScanner, allocator: std.mem.Allocator) !?Block {
        _ = allocator;
        // Skip consecutive blank lines.
        while (self.pos < self.src.len) {
            const line = peekLine(self.src, self.pos);
            if (lineIsBlank(line.content)) {
                self.pos = line.next;
                continue;
            }
            break;
        }
        if (self.pos >= self.src.len) return null;

        const line = peekLine(self.src, self.pos);
        const trimmed = trimAscii(line.content);

        // fenced code block
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            const fence_char = trimmed[0];
            const fence_start = self.pos;
            _ = fence_start;
            self.pos = line.next;
            const content_start = self.pos;
            // Scan to matching fence or EOF.
            while (self.pos < self.src.len) {
                const l = peekLine(self.src, self.pos);
                const t = trimAscii(l.content);
                if (t.len >= 3 and t[0] == fence_char and t[1] == fence_char and t[2] == fence_char) {
                    const content_end = self.pos;
                    self.pos = l.next;
                    return .{ .code_block = .{ .content = trimTrailingNewline(self.src[content_start..content_end]) } };
                }
                self.pos = l.next;
            }
            // Unclosed fence: treat rest as code.
            return .{ .code_block = .{ .content = trimTrailingNewline(self.src[content_start..self.src.len]) } };
        }

        // Horizontal rule: --- / *** / ___ (3+ chars, spaces allowed).
        if (isHorizontalRule(trimmed)) {
            self.pos = line.next;
            return .rule;
        }

        // ATX heading
        if (atxHeadingLevel(trimmed)) |level| {
            self.pos = line.next;
            const heading_text = trimAscii(trimmed[level + 1 ..]);
            return .{ .heading = .{ .level = level, .text = heading_text } };
        }

        // Blockquote (single level).
        if (trimmed.len > 0 and trimmed[0] == '>') {
            self.pos = line.next;
            const quote_text = if (trimmed.len > 1 and trimmed[1] == ' ')
                trimmed[2..]
            else
                trimmed[1..];
            return .{ .blockquote = quote_text };
        }

        // Unordered list (single level).
        if (trimmed.len >= 2) {
            const first = trimmed[0];
            if ((first == '-' or first == '*' or first == '+') and trimmed[1] == ' ') {
                self.pos = line.next;
                return .{ .list_item = .{ .ordered = false, .marker = trimmed[0..1], .text = trimmed[2..] } };
            }
        }

        // Ordered list `1. xxx` / `10. xxx` (single level).
        if (std.ascii.isDigit(trimmed[0])) {
            var digit_end: usize = 0;
            while (digit_end < trimmed.len and std.ascii.isDigit(trimmed[digit_end])) digit_end += 1;
            if (digit_end > 0 and digit_end + 1 < trimmed.len and trimmed[digit_end] == '.' and trimmed[digit_end + 1] == ' ') {
                self.pos = line.next;
                return .{ .list_item = .{ .ordered = true, .marker = trimmed[0..digit_end], .text = trimmed[digit_end + 2 ..] } };
            }
        }

        // Paragraph: accumulate following non-empty non-special lines. First line unconditionally
        // consumed: reaching here means it's not a block start; if break condition diverges from
        // block check above (e.g., '#123' not legal ATX), not advancing pos causes next() to loop
        // empty paragraphs -> renderInto infinite loop.
        const para_start = self.pos;
        self.pos = line.next;
        while (self.pos < self.src.len) {
            const l = peekLine(self.src, self.pos);
            const t = trimAscii(l.content);
            if (t.len == 0) break;
            if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) break;
            if (isHorizontalRule(t)) break;
            if (atxHeadingLevel(t) != null) break;
            if (t.len > 0 and t[0] == '>') break;
            if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') break;
            self.pos = l.next;
        }
        return .{ .paragraph = self.src[para_start..self.pos] };
    }
};

// ============================================================================
// Block emitters
// ============================================================================

// Block nodes mount as built (view.mount), applyInlineText failure rolls back with container guard.
// Body nodes = box + applyInlineText: content has TextSpan (bold/italic/code/link) composed by
// InlineBuilder then handed off; view.text has no spans entry, text writes post-mount.
const grow_width = core.BoxStyle{ .width = .{ .grow = .{} } };

fn emitParagraph(scope: *Scope, cx: *Cx, container: *Node, text: []const u8, opts: MarkdownOptions) !void {
    var node: *Node = undefined;
    try view.mount(scope, cx, container, view.capture(&node, view.box(.{ .style = grow_width }, {})));
    try applyInlineText(cx, node, text, opts.base_font_size, opts.text_color, opts.line_height, 400, opts);
}

fn emitHeading(scope: *Scope, cx: *Cx, container: *Node, level: u8, text: []const u8, opts: MarkdownOptions) !void {
    var node: *Node = undefined;
    try view.mount(scope, cx, container, view.capture(&node, view.box(.{
        .style = grow_width,
        // Headings are render-only 'larger heavier text'; screen reader gets role=heading so it
        // lists outline, user can jump by heading. (a11y tree currently lacks heading level field,
        // hierarchy unexpressed.)
        .a11y = core.A11yProps{ .role = .heading, .label = text },
    }, {})));
    const color = opts.heading_color orelse opts.text_color;
    const font_size = opts.base_font_size * mdHeadingSizeMul(level);
    try applyInlineText(cx, node, text, font_size, color, opts.line_height, 600, opts);
}

fn emitCodeBlock(scope: *Scope, cx: *Cx, container: *Node, code: []const u8, opts: MarkdownOptions) !void {
    var block: *Node = undefined;
    try view.mount(scope, cx, container, view.capture(&block, view.box(.{ .style = mdCodeBlockStyle(opts) }, {})));
    var it = std.mem.splitScalar(u8, code, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try view.mount(scope, cx, block, view.text(.{ .style = mdCodeLineText(opts) }, line));
    }
}

fn emitRule(scope: *Scope, cx: *Cx, container: *Node, opts: MarkdownOptions) !void {
    try view.mount(scope, cx, container, view.box(.{ .style = mdRuleStyle(opts) }, {}));
}

fn emitBlockquote(scope: *Scope, cx: *Cx, container: *Node, text: []const u8, opts: MarkdownOptions) !void {
    var body: *Node = undefined;
    try view.mount(scope, cx, container, view.box(.{ .style = mdBlockquoteStyle() }, .{
        view.box(.{ .style = mdBlockquoteBarStyle(opts) }, {}),
        view.capture(&body, view.box(.{ .style = mdBlockquoteBodyStyle() }, {})),
    }));
    try applyInlineText(cx, body, text, opts.base_font_size, opts.text_color, opts.line_height, 400, opts);
}

fn emitListItem(scope: *Scope, cx: *Cx, container: *Node, ordered: bool, marker: []const u8, text: []const u8, opts: MarkdownOptions) !void {
    var body: *Node = undefined;
    try view.mount(scope, cx, container, view.box(.{
        .style = mdListRowStyle(),
        // Label text only, no bullet/number marker; marker is visual (AT broadcasts 'item N'
        // itself).
        .a11y = core.A11yProps{ .role = .listitem, .label = text },
    }, .{
        view.text(.{ .style = mdListMarkerText(opts) }, if (ordered) marker else bulletGlyph()),
        view.capture(&body, view.box(.{ .style = grow_width }, {})),
    }));
    try applyInlineText(cx, body, text, opts.base_font_size, opts.text_color, opts.line_height, 400, opts);
}

fn bulletGlyph() []const u8 {
    return "•";
}

// ============================================================================
// Inline parser: expand [text](url) / ![alt](url) / **bold** / *italic* / `code`
// into string + TextSpan array, attach to node.text
// ============================================================================

fn applyInlineText(
    cx: *Cx,
    node: *Node,
    raw: []const u8,
    font_size: f32,
    text_color: Color,
    line_height: f32,
    font_weight: u16,
    opts: MarkdownOptions,
) !void {
    const allocator = cx.allocator;
    var builder = InlineBuilder.init(allocator);
    defer builder.deinit();

    try expandInline(&builder, raw, opts);

    // If nothing survives (all data:url discarded), use space to maintain height.
    if (builder.text.items.len == 0) {
        try builder.text.appendSlice(allocator, " ");
    }

    const has_spans = builder.spans.items.len > 0;
    const owned_text = try builder.text.toOwnedSlice(allocator);
    errdefer allocator.free(owned_text);
    const owned_spans = if (has_spans)
        try builder.spans.toOwnedSlice(allocator)
    else
        &[_]TextSpan{};

    // Old owned text/spans freed by ContentTable.setText on next content (automatic free).
    node.setText(.{
        .content = owned_text,
        .owned = true,
        .font_size = font_size,
        .font_weight = font_weight,
        .color = text_color,
        .line_height = line_height,
        .wrap = .word,
        .spans = owned_spans,
        .spans_owned = has_spans,
    });
}

const InlineBuilder = struct {
    text: std.ArrayListUnmanaged(u8) = .empty,
    spans: std.ArrayListUnmanaged(TextSpan) = .empty,
    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator) InlineBuilder {
        return .{ .allocator = a };
    }

    fn deinit(self: *InlineBuilder) void {
        self.text.deinit(self.allocator);
        self.spans.deinit(self.allocator);
    }

    fn appendPlain(self: *InlineBuilder, s: []const u8) !void {
        try self.text.appendSlice(self.allocator, s);
    }

    fn appendSpan(self: *InlineBuilder, s: []const u8, style: TextSpan) !void {
        const start: u32 = @intCast(self.text.items.len);
        try self.text.appendSlice(self.allocator, s);
        const end: u32 = @intCast(self.text.items.len);
        var span = style;
        span.start = start;
        span.end = end;
        try self.spans.append(self.allocator, span);
    }

    /// Inherited formatting is flattened into ordered, disjoint spans. Only
    /// merge text runs: separate inline boxes must keep their own padding.
    fn appendStyled(self: *InlineBuilder, s: []const u8, style: TextSpan) !void {
        if (s.len == 0) return;
        if (std.meta.eql(style, plain_inline_style)) return self.appendPlain(s);
        if (self.spans.items.len > 0 and style.bg_color == null) {
            const last = &self.spans.items[self.spans.items.len - 1];
            var previous_style = last.*;
            previous_style.start = 0;
            previous_style.end = 0;
            if (last.end == self.text.items.len and std.meta.eql(previous_style, style)) {
                try self.text.appendSlice(self.allocator, s);
                last.end = @intCast(self.text.items.len);
                return;
            }
        }
        try self.appendSpan(s, style);
    }
};

const plain_inline_style: TextSpan = .{ .start = 0, .end = 0 };
const max_inline_depth = 32;

/// Merge semantic inline styles, not ranges. Code supplies its foreground and
/// box metrics while inheriting emphasis and link decoration.
fn inheritInlineStyle(parent: TextSpan, child: TextSpan) TextSpan {
    var result = parent;
    result.color = child.color orelse parent.color;
    result.font_weight = child.font_weight orelse parent.font_weight;
    result.use_italic_font = parent.use_italic_font or child.use_italic_font;
    result.use_monospace_font = parent.use_monospace_font or child.use_monospace_font;
    result.underline = parent.underline or child.underline;
    if (child.bg_color != null) {
        result.bg_color = child.bg_color;
        result.inline_box_padding_left = child.inline_box_padding_left;
        result.inline_box_padding_right = child.inline_box_padding_right;
        result.inline_box_inset_top = child.inline_box_inset_top;
        result.inline_box_inset_bottom = child.inline_box_inset_bottom;
        result.inline_box_corner_radius = child.inline_box_corner_radius;
    }
    return result;
}

fn expandInline(builder: *InlineBuilder, raw: []const u8, opts: MarkdownOptions) !void {
    try expandInlineStyled(builder, raw, opts, plain_inline_style, 0);
}

fn expandInlineStyled(builder: *InlineBuilder, raw: []const u8, opts: MarkdownOptions, inherited: TextSpan, depth: usize) error{OutOfMemory}!void {
    if (depth >= max_inline_depth) return builder.appendStyled(raw, inherited);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        // Paragraph-local soft breaks flatten to spaces, including in styled runs.
        if (c == '\n' or c == '\r') {
            var next = i + 1;
            if (c == '\r' and next < raw.len and raw[next] == '\n') next += 1;
            const has_previous_text = builder.text.items.len > 0;
            const has_following_text = next < raw.len;
            const previous_is_space = has_previous_text and
                (builder.text.items[builder.text.items.len - 1] == ' ' or builder.text.items[builder.text.items.len - 1] == '\t');
            const following_is_space = has_following_text and (raw[next] == ' ' or raw[next] == '\t');
            if (has_previous_text and has_following_text and !previous_is_space and !following_is_space) {
                try builder.appendStyled(" ", inherited);
            }
            i = next;
            continue;
        }

        // Code is opaque: its contents never become emphasis or links.
        if (c == '`') {
            if (findMatching(raw, i + 1, '`')) |end| {
                if (end > i + 1) try builder.appendSpan(raw[i + 1 .. end], inheritInlineStyle(inherited, mdCodeSpanStyle(opts)));
                i = end + 1;
                continue;
            }
        }

        if (c == '*' or c == '_') {
            const width: usize = if (c == '*' and i + 1 < raw.len and raw[i + 1] == '*') 2 else 1;
            const word_underscore = c == '_' and i > 0 and isWordByte(raw[i - 1]);
            if (!word_underscore and canOpenEmphasis(raw, i, width)) {
                if (findEmphasisEnd(raw, i + width, c, width, depth)) |end| {
                    const style = if (width == 2) mdBoldSpanStyle() else mdItalicSpanStyle();
                    try expandInlineStyled(builder, raw[i + width .. end], opts, inheritInlineStyle(inherited, style), depth + 1);
                    i = end + width;
                    continue;
                }
            }
            // An unmatched ** opener must not restart as * at its second byte.
            try builder.appendStyled(raw[i .. i + width], inherited);
            i += width;
            continue;
        }

        // Images retain the existing chip / literal-alt fallback behavior.
        if (c == '!' and i + 1 < raw.len and raw[i + 1] == '[') {
            if (parseLink(raw, i + 1)) |link| {
                if (link.text.len > 0 and !isDataUri(link.url)) {
                    try builder.appendStyled("[", inherited);
                    try builder.appendStyled(link.text, inherited);
                    try builder.appendStyled("]", inherited);
                } else if (link.text.len > 0) {
                    try builder.appendSpan(link.text, inheritInlineStyle(inherited, mdImageChipSpanStyle(opts)));
                }
                i = link.next;
                continue;
            }
        }

        if (c == '[') {
            if (parseLink(raw, i)) |link| {
                try expandInlineStyled(builder, link.text, opts, inheritInlineStyle(inherited, mdLinkSpanStyle(opts)), depth + 1);
                i = link.next;
                continue;
            }
        }

        // Byte offsets remain relative to the final UTF-8 text, after markers
        // have been removed. appendStyled coalesces adjacent inherited text.
        try builder.appendStyled(raw[i .. i + 1], inherited);
        i += 1;
    }
}

fn canOpenEmphasis(src: []const u8, start: usize, width: usize) bool {
    return start + width < src.len and !std.ascii.isWhitespace(src[start + width]);
}

/// Match this delimiter while skipping opaque code/links and differently sized
/// nested emphasis. A *** closer can close inner * followed by outer ** (or the
/// reverse); consuming only the nested delimiter leaves the outer closer intact.
fn findEmphasisEnd(src: []const u8, start: usize, marker: u8, width: usize, depth: usize) ?usize {
    // Bound backtracking on malformed alternating * / ** openers as well as
    // stack depth. Exhaustion falls back to literal input, just like no match.
    var budget = src.len *| max_inline_depth;
    return findEmphasisEndBounded(src, start, marker, width, depth, &budget);
}

fn findEmphasisEndBounded(src: []const u8, start: usize, marker: u8, width: usize, depth: usize, budget: *usize) ?usize {
    if (depth >= max_inline_depth) return null;
    var i = start;
    while (i < src.len) {
        if (budget.* == 0) return null;
        budget.* -= 1;
        const c = src[i];
        if (c == '\n' or c == '\r') return null;
        if (c == '`') {
            if (findMatching(src, i + 1, '`')) |end| {
                i = end + 1;
                continue;
            }
        }
        if (c == '[') {
            if (parseLink(src, i)) |link| {
                i = link.next;
                continue;
            }
        }
        if (c == '*' or c == '_') {
            var run_end = i + 1;
            while (run_end < src.len and src[run_end] == c) : (run_end += 1) {}
            const run_width = run_end - i;
            const closes = i > start and !std.ascii.isWhitespace(src[i - 1]) and
                (c != '_' or run_end == src.len or !isWordByte(src[run_end]));
            if (c == marker and run_width >= width and (width == 2 or run_width != 2) and closes) return i;

            const nested_width: usize = if (c == '*' and run_width >= 2) 2 else 1;
            const word_underscore = c == '_' and i > 0 and isWordByte(src[i - 1]);
            if ((c != marker or nested_width != width) and !word_underscore and canOpenEmphasis(src, i, nested_width)) {
                if (findEmphasisEndBounded(src, i + nested_width, c, nested_width, depth + 1, budget)) |end| {
                    i = end + nested_width;
                    continue;
                }
            }
            i = run_end;
            continue;
        }
        i += 1;
    }
    return null;
}

const ParsedLink = struct {
    text: []const u8,
    url: []const u8,
    next: usize,
};

/// Parse `[text](url)`. Enter with src[start] == '['. Return null on failure (no consume).
fn parseLink(src: []const u8, start: usize) ?ParsedLink {
    if (start >= src.len or src[start] != '[') return null;
    // Brackets inside code are literal; ordinary brackets in labels and
    // parentheses in destinations must balance before closing the link.
    var cursor = start + 1;
    var brackets: usize = 1;
    while (cursor < src.len) : (cursor += 1) {
        if (src[cursor] == '\n' or src[cursor] == '\r') return null;
        if (src[cursor] == '`') {
            if (findMatching(src, cursor + 1, '`')) |end| {
                cursor = end;
                continue;
            }
        }
        if (src[cursor] == '[') brackets += 1;
        if (src[cursor] == ']') {
            brackets -= 1;
            if (brackets == 0) break;
        }
    }
    const bracket_end = cursor;
    if (bracket_end + 1 >= src.len or src[bracket_end + 1] != '(') return null;
    cursor = bracket_end + 2;
    var parentheses: usize = 1;
    while (cursor < src.len) : (cursor += 1) {
        if (src[cursor] == '\n' or src[cursor] == '\r') return null;
        if (src[cursor] == '(') parentheses += 1;
        if (src[cursor] == ')') {
            parentheses -= 1;
            if (parentheses == 0) break;
        }
    }
    if (cursor == src.len) return null;
    const paren_end = cursor;
    return .{
        .text = src[start + 1 .. bracket_end],
        .url = src[bracket_end + 2 .. paren_end],
        .next = paren_end + 1,
    };
}

fn findMatching(src: []const u8, start: usize, ch: u8) ?usize {
    var i = start;
    while (i < src.len) : (i += 1) {
        if (src[i] == ch) return i;
        if (src[i] == '\n') return null; // Inline limited to single line.
    }
    return null;
}

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

fn isDataUri(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "data:");
}

// ============================================================================
// Helper functions
// ============================================================================

const LineSlice = struct { content: []const u8, next: usize };

fn peekLine(src: []const u8, start: usize) LineSlice {
    if (start >= src.len) return .{ .content = src[start..start], .next = src.len };
    var end = start;
    while (end < src.len and src[end] != '\n') : (end += 1) {}
    const after = if (end < src.len) end + 1 else end;
    // Strip \r.
    var content_end = end;
    if (content_end > start and src[content_end - 1] == '\r') content_end -= 1;
    return .{ .content = src[start..content_end], .next = after };
}

fn lineIsBlank(line: []const u8) bool {
    for (line) |b| if (b != ' ' and b != '\t') return false;
    return true;
}

fn trimAscii(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

fn trimTrailingNewline(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) end -= 1;
    return s[0..end];
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const first = line[0];
    if (first != '-' and first != '*' and first != '_') return false;
    var count: usize = 0;
    for (line) |c| {
        if (c == first) {
            count += 1;
        } else if (c != ' ' and c != '\t') {
            return false;
        }
    }
    return count >= 3;
}

/// Valid ATX heading (1-6 `#` followed by space) returns level, else null.
fn atxHeadingLevel(trimmed: []const u8) ?u8 {
    if (trimmed.len == 0 or trimmed[0] != '#') return null;
    var level: u8 = 0;
    while (level < 6 and level < trimmed.len and trimmed[level] == '#') level += 1;
    if (level < trimmed.len and trimmed[level] == ' ') return level;
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "markdown: 非标题的 # 行按段落推进，不死循环" {
    const cases = [_][]const u8{ "#123 fixed\n", "#include <x>\n", "#\n", "text\n#nope\nmore\n", "####### seven\n" };
    for (cases) |src| {
        var scanner = BlockScanner{ .src = src };
        var n: usize = 0;
        while (try scanner.next(std.testing.allocator)) |b| {
            try std.testing.expect(b == .paragraph);
            try std.testing.expect(b.paragraph.len > 0);
            n += 1;
            try std.testing.expect(n < 8);
        }
        try std.testing.expectEqual(@as(usize, 1), n);
    }
    // Valid heading still breaks paragraph.
    var scanner = BlockScanner{ .src = "para\n## H\n" };
    try std.testing.expect((try scanner.next(std.testing.allocator)).? == .paragraph);
    try std.testing.expect((try scanner.next(std.testing.allocator)).? == .heading);
}

test "markdown: detects paragraph vs heading" {
    var scanner = BlockScanner{ .src = "# Hello\n\nA paragraph.\n" };
    const h = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(h == .heading);
    try std.testing.expectEqual(@as(u8, 1), h.heading.level);
    try std.testing.expectEqualStrings("Hello", h.heading.text);
    const p = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(p == .paragraph);
}

test "markdown: fenced code block with unclosed fence" {
    var scanner = BlockScanner{ .src = "```\nfoo\nbar\n" };
    const b = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(b == .code_block);
    try std.testing.expectEqualStrings("foo\nbar", b.code_block.content);
}

test "markdown: horizontal rule" {
    var scanner = BlockScanner{ .src = "---\n" };
    const b = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(b == .rule);
}

test "markdown: list items and blockquote" {
    var scanner = BlockScanner{ .src = "- first\n- second\n> quoted\n" };
    const a = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(a == .list_item);
    try std.testing.expect(!a.list_item.ordered);
    const b = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(b == .list_item);
    const c = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(c == .blockquote);
    try std.testing.expectEqualStrings("quoted", c.blockquote);
}

test "markdown inline: data uri image dropped to chip" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "before ![Baseline icon](data:image/svg+xml;base64,abc) after", .{});
    const out = builder.text.items;
    // URL should not appear, 'Baseline icon' chip should.
    try std.testing.expect(std.mem.indexOf(u8, out, "data:image") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "base64") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Baseline icon") != null);
}

test "markdown inline: code span gets monospace + bg_color TextSpan" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "call `foo()` now", .{});
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "`") == null);
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "foo()") != null);
    try std.testing.expect(builder.spans.items.len >= 1);
    try std.testing.expect(builder.spans.items[0].use_monospace_font);
}

test "markdown inline: bold and italic spans" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "**bold** and *italic*", .{});
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "*") == null);
    try std.testing.expectEqual(@as(usize, 2), builder.spans.items.len);
    try std.testing.expectEqual(@as(?u16, 700), builder.spans.items[0].font_weight);
    try std.testing.expect(builder.spans.items[1].use_italic_font);
}

fn expectInlineSpan(builder: *const InlineBuilder, text: []const u8) !TextSpan {
    for (builder.spans.items) |span| {
        if (std.mem.eql(u8, builder.text.items[span.start..span.end], text)) return span;
    }
    return error.ExpectedInlineSpan;
}

fn expectOrderedInlineSpans(builder: *const InlineBuilder) !void {
    var previous_end: u32 = 0;
    for (builder.spans.items) |span| {
        try std.testing.expect(span.start >= previous_end);
        try std.testing.expect(span.end > span.start);
        try std.testing.expect(span.end <= builder.text.items.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(builder.text.items[span.start..span.end]));
        previous_end = span.end;
    }
}

test "markdown inline: bold code inherits emphasis and preserves UTF-8 byte ranges" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    const opts: MarkdownOptions = .{ .code_color = Color.hex(0x123456), .code_bg = Color.hex(0xABCDEF) };
    try expandInline(&builder, "**1. `tuned` 已改为 `hpc-compute`**", opts);
    try std.testing.expectEqualStrings("1. tuned 已改为 hpc-compute", builder.text.items);
    try std.testing.expectEqual(@as(usize, 4), builder.spans.items.len);
    try expectOrderedInlineSpans(&builder);
    for (builder.spans.items) |span| try std.testing.expectEqual(@as(?u16, 700), span.font_weight);
    for ([_][]const u8{ "tuned", "hpc-compute" }) |code| {
        const span = try expectInlineSpan(&builder, code);
        try std.testing.expect(span.use_monospace_font);
        try std.testing.expectEqualDeep(opts.code_color, span.color.?);
        try std.testing.expectEqualDeep(opts.code_bg, span.bg_color.?);
        try std.testing.expectEqual(@as(f32, 2), span.inline_box_padding_left);
        try std.testing.expectEqual(@as(f32, 2), span.inline_box_padding_right);
        try std.testing.expectEqual(@as(f32, 3), span.inline_box_corner_radius);
    }
}

test "markdown inline: nested emphasis works in both directions and adjacent triple closers" {
    const cases = [_]struct { raw: []const u8, text: []const u8, nested: []const u8 }{
        .{ .raw = "**粗体 *斜体* 文字**", .text = "粗体 斜体 文字", .nested = "斜体" },
        .{ .raw = "*斜体 **粗体** 文字*", .text = "斜体 粗体 文字", .nested = "粗体" },
        .{ .raw = "**粗体 _斜体_ 文字**", .text = "粗体 斜体 文字", .nested = "斜体" },
        .{ .raw = "_斜体 **粗体** 文字_", .text = "斜体 粗体 文字", .nested = "粗体" },
        .{ .raw = "**外层 *内层***", .text = "外层 内层", .nested = "内层" },
        .{ .raw = "*外层 **内层***", .text = "外层 内层", .nested = "内层" },
        .{ .raw = "***全部***", .text = "全部", .nested = "全部" },
    };
    for (cases) |case| {
        var builder = InlineBuilder.init(std.testing.allocator);
        defer builder.deinit();
        try expandInline(&builder, case.raw, .{});
        try std.testing.expectEqualStrings(case.text, builder.text.items);
        try expectOrderedInlineSpans(&builder);
        const span = try expectInlineSpan(&builder, case.nested);
        try std.testing.expectEqual(@as(?u16, 700), span.font_weight);
        try std.testing.expect(span.use_italic_font);
    }
}

test "markdown inline: code is opaque to emphasis and outer delimiter matching" {
    const cases = [_]struct { raw: []const u8, text: []const u8, code: []const u8, bold: bool, italic: bool }{
        .{ .raw = "**表达式 `a**b` 的说明**", .text = "表达式 a**b 的说明", .code = "a**b", .bold = true, .italic = false },
        .{ .raw = "*说明 `a*b` 结束*", .text = "说明 a*b 结束", .code = "a*b", .bold = false, .italic = true },
        .{ .raw = "_说明 `a_b` 结束_", .text = "说明 a_b 结束", .code = "a_b", .bold = false, .italic = true },
        .{ .raw = "`**bold** *italic* [x](url)`", .text = "**bold** *italic* [x](url)", .code = "**bold** *italic* [x](url)", .bold = false, .italic = false },
        .{ .raw = "**普通 `a` `b`**", .text = "普通 a b", .code = "a", .bold = true, .italic = false },
    };
    for (cases) |case| {
        var builder = InlineBuilder.init(std.testing.allocator);
        defer builder.deinit();
        try expandInline(&builder, case.raw, .{});
        try std.testing.expectEqualStrings(case.text, builder.text.items);
        try expectOrderedInlineSpans(&builder);
        const span = try expectInlineSpan(&builder, case.code);
        try std.testing.expect(span.use_monospace_font);
        try std.testing.expectEqual(case.bold, span.font_weight == 700);
        try std.testing.expectEqual(case.italic, span.use_italic_font);
    }
}

test "markdown inline: links inherit emphasis and code overrides link color only" {
    const cases = [_][]const u8{
        "**[前 `arr[0]` 后](https://example.com/a_(b))**",
        "[**前 `arr[0]` 后**](https://example.com/a_(b))",
    };
    const opts: MarkdownOptions = .{ .link_color = Color.hex(0x123456), .code_color = Color.hex(0x654321) };
    for (cases) |raw| {
        var builder = InlineBuilder.init(std.testing.allocator);
        defer builder.deinit();
        try expandInline(&builder, raw, opts);
        try std.testing.expectEqualStrings("前 arr[0] 后", builder.text.items);
        try expectOrderedInlineSpans(&builder);
        for (builder.spans.items) |span| {
            try std.testing.expectEqual(@as(?u16, 700), span.font_weight);
            try std.testing.expect(span.underline);
            try std.testing.expectEqualDeep(if (span.use_monospace_font) opts.code_color else opts.link_color, span.color.?);
        }
        const code = try expectInlineSpan(&builder, "arr[0]");
        try std.testing.expect(code.use_monospace_font and code.bg_color != null);
    }
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "**[link](https://example.com/a**b) tail**", .{});
    try std.testing.expectEqualStrings("link tail", builder.text.items);
    try std.testing.expectEqual(@as(?u16, 700), (try expectInlineSpan(&builder, " tail")).font_weight);
}

test "markdown inline: incomplete streaming input recovers when completed" {
    const cases = [_][]const u8{ "**前 `tuned`", "*前 `tuned`", "_前 `tuned`", "[**前 `tuned`**](https://example.com" };
    for (cases) |raw| {
        var builder = InlineBuilder.init(std.testing.allocator);
        defer builder.deinit();
        try expandInline(&builder, raw, .{});
        try expectOrderedInlineSpans(&builder);
        try std.testing.expect(builder.text.items.len > 0);
    }
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "**前 `tuned`**", .{});
    try std.testing.expectEqualStrings("前 tuned", builder.text.items);
    try std.testing.expectEqual(@as(?u16, 700), (try expectInlineSpan(&builder, "tuned")).font_weight);
    var plain = InlineBuilder.init(std.testing.allocator);
    defer plain.deinit();
    try expandInline(&plain, "snake_case **unclosed", .{});
    try std.testing.expectEqualStrings("snake_case **unclosed", plain.text.items);
    try std.testing.expectEqual(@as(usize, 0), plain.spans.items.len);
}

test "markdown inline: malformed alternating emphasis stays bounded and retains text" {
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    defer raw.deinit(std.testing.allocator);
    for (0..64) |_| try raw.appendSlice(std.testing.allocator, "*a **a ");
    try raw.appendSlice(std.testing.allocator, "tail");
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, raw.items, .{});
    try std.testing.expectEqualStrings(raw.items, builder.text.items);
}

test "markdown inline: nested links have a bounded literal fallback" {
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    defer raw.deinit(std.testing.allocator);
    for (0..max_inline_depth + 4) |_| try raw.appendSlice(std.testing.allocator, "[");
    try raw.appendSlice(std.testing.allocator, "value");
    for (0..max_inline_depth + 4) |_| try raw.appendSlice(std.testing.allocator, "](url)");
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, raw.items, .{});
    try expectOrderedInlineSpans(&builder);
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "value") != null);
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "](url)") != null);
}

test "markdown inline: ellipsis and plain link" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "see [MDN](https://mdn.io/x) \u{2026}", .{});
    // Link URL absent, only 'MDN' kept.
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "https://") == null);
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "MDN") != null);
    // One link span.
    try std.testing.expect(builder.spans.items.len >= 1);
    try std.testing.expect(builder.spans.items[0].underline);
}

test "markdown inline: paragraph soft breaks become spaces" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try expandInline(
        &builder,
        "A typed array. If the\nrequested number of bytes could not be allocated.\r\nThe operation raises an exception.",
        .{},
    );

    try std.testing.expectEqualStrings(
        "A typed array. If the requested number of bytes could not be allocated. The operation raises an exception.",
        builder.text.items,
    );
}

test "markdown: pathological unclosed inline tokens stay safe" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    // Unclosed code/link/bold: no crash, keep original literal.
    try expandInline(&builder, "foo `unclosed and **half bold and [link no paren", .{});
    try std.testing.expect(builder.text.items.len > 0);
}

test "markdown: empty input yields no blocks" {
    var scanner = BlockScanner{ .src = "" };
    try std.testing.expect((try scanner.next(std.testing.allocator)) == null);
}

test "markdown: blank-only input yields no blocks" {
    var scanner = BlockScanner{ .src = "\n\n\t\n" };
    try std.testing.expect((try scanner.next(std.testing.allocator)) == null);
}

// styles.zig test collection; required (see docs/STYLING.md).
test {
    _ = @import("styles.zig");
}

// Remaining unsweep components (markdown render / form_field / select_headless).
const sweep_md = "# Title\n\nA **bold *italic* with `code`** and [**link `code`**](https://x.y) ![alt](a.png)\n\n- one\n- two\n1. first\n\n```\nlet x = 1;\nlet y = 2;\n```\n\n---\n\n> quoted **text**\n";
test "markdown: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("markdown", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Markdown(.{ .text = sweep_md }).mount(scope, cx);
        }
    }.m);
}

test "markdown: 动态文本的 mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("markdown(dynamic)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const doc = try scope.createText(sweep_md, .{});
            return try Markdown(.{ .text = doc }).mount(scope, cx);
        }
    }.m);
}

test "Markdown: a text signal re-renders the document" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const doc = try scope.createText("# One", .{});
    const root = try Markdown(.{ .text = doc }).mount(scope, ctx);
    defer ctx.freeNode(root);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    doc.set("# One\n\nTwo\n\n---");
    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
}
