//! AI message Markdown: six-level compact headings, copyable code and text selection.
const ui = @import("ui");
const std = @import("std");
const S = @import("ai_assistant_styles.zig");
const blocks = @import("ai_markdown_blocks.zig");
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, value: []const u8) !*ui.Node {
    return mountWithWidth(cx, scope, value, 540);
}
pub fn mountWithWidth(cx: *ui.Cx, scope: *ui.Scope, value: []const u8, width: f32) !*ui.Node {
    return mountWithImages(cx, scope, value, width, null);
}
pub fn mountWithImages(cx: *ui.Cx, scope: *ui.Scope, value: []const u8, width: f32, images: ?@import("ai_transcript_images.zig").Context) !*ui.Node {
    return mountContent(cx, scope, value, width, images, true, null, 0);
}
fn mountContent(cx: *ui.Cx, scope: *ui.Scope, value: []const u8, width: f32, images: ?@import("ai_transcript_images.zig").Context, selection: bool, retained_code: ?*?*CodeState, depth: usize) anyerror!*ui.Node {
    const root = try ui.box(cx, S.assistantMessage(), .{});
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(cx.allocator);
    var iterator = std.mem.splitScalar(u8, value, '\n');
    while (iterator.next()) |line| try lines.append(cx.allocator, line);
    var start: usize = 0;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const trimmed = std.mem.trim(u8, lines.items[i], " \t\r");
        const container_end = if (depth < 32) blocks.containerEnd(lines.items, i) else i;
        if (container_end > i) {
            try appendMarkdown(cx, scope, root, lines.items[start..i]);
            try appendContainer(cx, scope, root, lines.items[i..container_end], width, images, depth);
            i = container_end - 1;
            start = container_end;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            try appendMarkdown(cx, scope, root, lines.items[start..i]);
            var fence_len: usize = 0;
            while (fence_len < trimmed.len and trimmed[fence_len] == trimmed[0]) : (fence_len += 1) {}
            var end = i + 1;
            while (end < lines.items.len) : (end += 1) {
                const closing = std.mem.trim(u8, lines.items[end], " \t\r");
                var count: usize = 0;
                while (count < closing.len and closing[count] == trimmed[0]) : (count += 1) {}
                if (count >= fence_len and std.mem.trim(u8, closing[count..], " \t\r").len == 0) break;
            }
            const code = try std.mem.join(cx.allocator, "\n", lines.items[i + 1 .. end]);
            defer cx.allocator.free(code);
            const source = if (end < lines.items.len and end > i + 1) try std.mem.concat(cx.allocator, u8, &.{ code, "\n" }) else try cx.allocator.dupe(u8, code);
            defer cx.allocator.free(source);
            const code_state = try appendCode(cx, scope, root, code, source, trimmed[fence_len..]);
            if (retained_code) |slot| slot.* = code_state;
            i = end;
            start = @min(end + 1, lines.items.len);
            continue;
        }
        if (images) |context| if (@import("ai_transcript_images.zig").reference(lines.items[i])) |first| {
            try appendMarkdown(cx, scope, root, lines.items[start..i]);
            var remaining = lines.items[i];
            var ref = first;
            while (true) {
                if (ref.start != 0) try appendMarkdown(cx, scope, root, &.{remaining[0..ref.start]});
                try root.appendChild(cx.allocator, try @import("ai_transcript_images.zig").mount(cx, scope, context, ref, width));
                remaining = remaining[ref.end..];
                ref = @import("ai_transcript_images.zig").reference(remaining) orelse break;
            }
            if (remaining.len > 0) try appendMarkdown(cx, scope, root, &.{remaining});
            start = i + 1;
            continue;
        };
        if (i + 1 >= lines.items.len or std.mem.indexOfScalar(u8, trimmed, '|') == null or !tableSeparator(lines.items[i + 1])) continue;
        try appendMarkdown(cx, scope, root, lines.items[start..i]);
        var end = i + 2;
        while (end < lines.items.len and std.mem.indexOfScalar(u8, lines.items[end], '|') != null and std.mem.trim(u8, lines.items[end], " \t\r").len != 0) : (end += 1) {}
        try appendTable(cx, scope, root, lines.items[i..end], width);
        i = end - 1;
        start = end;
    }
    try appendMarkdown(cx, scope, root, lines.items[start..]);
    if (selection) try @import("ai_text_selection.zig").attach(cx, scope, root);
    return root;
}
fn appendContainer(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, lines: []const []const u8, width: f32, images: ?@import("ai_transcript_images.zig").Context, depth: usize) !void {
    const quoted = blocks.quoteContent(lines[0]) != null;
    const row = try ui.box(cx, S.markdownContainer(quoted), .{});
    row.meta.ownership.meta.test_id = if (quoted) "ai.message.quote" else "ai.message.list.item";
    if (quoted) {
        try row.appendChild(cx.allocator, try ui.box(cx, S.markdownQuoteBar(), .{}));
    } else {
        const marker = blocks.listMarker(lines[0]).?;
        const label = if (marker.label.len == 1) "•" else marker.label;
        const marker_node = try ui.text(cx, "", S.markdownListMarker());
        try marker_node.setTextContent(cx.allocator, label);
        marker_node.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
        try row.appendChild(cx.allocator, marker_node);
        row.behavior.interaction.a11y = .{ .role = .listitem };
    }
    const source = try blocks.containerSource(cx.allocator, lines);
    defer cx.allocator.free(source);
    const owned = try scope.createText(source, .{});
    const content = try mountContent(cx, scope, owned.peek(), @max(1, width - 20), images, false, null, depth + 1);
    content.setStyleInline(cx.allocator, .{ .flex = 1 });
    try row.appendChild(cx.allocator, content);
    try parent.appendChild(cx.allocator, row);
}

/// Escaped pipes belong to cells. Keep escapes intact for the inline renderer.
fn tableCells(allocator: std.mem.Allocator, source: []const u8) ![][]const u8 {
    const line = std.mem.trim(u8, source, " \t\r");
    var cells: std.ArrayList([]const u8) = .empty;
    errdefer cells.deinit(allocator);
    var start: usize = if (line.len > 0 and line[0] == '|') 1 else 0;
    var i = start;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            if (i + 1 < line.len) i += 1;
            continue;
        }
        if (line[i] == '|') {
            try cells.append(allocator, line[start..i]);
            start = i + 1;
        }
    }
    if (start < line.len or cells.items.len == 0) try cells.append(allocator, line[start..]);
    return cells.toOwnedSlice(allocator);
}

fn unescapeTablePipes(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\' and i + 1 < source.len) {
            if (source[i + 1] != '|') try result.append(allocator, source[i]);
            i += 1;
        }
        try result.append(allocator, source[i]);
    }
    return result.toOwnedSlice(allocator);
}

pub fn mountCode(cx: *ui.Cx, scope: *ui.Scope, code: []const u8, language: []const u8) !*ui.Node {
    const root = try ui.box(cx, S.assistantMessage(), .{});
    _ = try appendCode(cx, scope, root, code, code, language);
    try @import("ai_text_selection.zig").attach(cx, scope, root);
    return root;
}
pub fn languageLabel(info: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, info, " \t\r");
    const token = trimmed[0 .. std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len];
    if (token.len == 0) return "代码";
    const aliases = .{
        .{ "yaml", "YAML" },             .{ "yml", "YAML" },      .{ "zig", "Zig" },
        .{ "json", "JSON" },             .{ "jsonc", "JSONC" },   .{ "toml", "TOML" },
        .{ "sh", "Shell" },              .{ "shell", "Shell" },   .{ "bash", "Bash" },
        .{ "zsh", "Zsh" },               .{ "python", "Python" }, .{ "py", "Python" },
        .{ "javascript", "JavaScript" }, .{ "js", "JavaScript" }, .{ "typescript", "TypeScript" },
        .{ "ts", "TypeScript" },         .{ "html", "HTML" },     .{ "css", "CSS" },
        .{ "sql", "SQL" },               .{ "rust", "Rust" },     .{ "rs", "Rust" },
        .{ "cpp", "C++" },               .{ "c", "C" },
        .{ "text", "纯文本" },
        .{ "txt", "纯文本" },
    };
    inline for (aliases) |alias| if (std.ascii.eqlIgnoreCase(token, alias[0])) return alias[1];
    return token;
}
fn appendMarkdown(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, lines: []const []const u8) !void {
    if (lines.len == 0) return;
    const joined = try std.mem.join(cx.allocator, "\n", lines);
    defer cx.allocator.free(joined);
    const node = try ui.widgets.Markdown(.{ .text = try scope.createText(joined, .{}), .options = S.markdownOptions() }).mount(scope, cx);
    try compact(cx, scope, node);
    try @import("ai_markdown_links.zig").bind(cx, scope, node, joined);
    try parent.appendChild(cx.allocator, node);
}
pub fn tableSeparator(line: []const u8) bool {
    const value = std.mem.trim(u8, line, " \t\r|");
    if (value.len == 0) return false;
    var cells = std.mem.splitScalar(u8, value, '|');
    while (cells.next()) |cell| {
        const rule = std.mem.trim(u8, cell, " \t:");
        if (rule.len < 3) return false;
        for (rule) |byte| if (byte != '-') return false;
    }
    return true;
}
const TableLayout = struct {
    cx: *ui.Cx,
    scroll: ui.widgets.ScrollAreaResult,
    columns: usize,
    preferred: [16]f32 = @splat(0),
    measured: bool = false,

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *TableLayout = @ptrCast(@alignCast(raw));
        const viewport = self.scroll.container.globalRect();
        if (viewport.w <= 0) return .done;
        if (!self.measured) {
            for (self.scroll.content.children.items) |row| {
                for (row.children.items, 0..) |cell, column| {
                    const edges = cell.style.border.resolvedWidths();
                    const natural = tableContentWidth(self.cx, cell.children.items[0]) + cell.style.padding.horizontal() + edges[1] + edges[3];
                    self.preferred[column] = @max(self.preferred[column], std.math.clamp(natural, S.table_min_column_width, S.table_preferred_column_max_width));
                }
            }
            self.measured = true;
        }
        var minimum: f32 = 0;
        var weight: f32 = 0;
        for (self.preferred[0..self.columns]) |preferred| {
            minimum += @min(preferred, S.table_wrapped_column_min_width);
            weight += @max(0, preferred - S.table_wrapped_column_min_width);
        }
        // Compact columns keep their measured width. Columns that need wrapping
        // share the remaining viewport according to their rendered content.
        const total = if (weight > 0) @max(minimum, viewport.w) else minimum;
        var widths: [16]f32 = @splat(0);
        for (self.preferred[0..self.columns], 0..) |preferred, column| {
            widths[column] = @min(preferred, S.table_wrapped_column_min_width);
            if (weight > 0) widths[column] += (total - minimum) * @max(0, preferred - S.table_wrapped_column_min_width) / weight;
        }
        var widths_changed = false;
        if (@abs(self.scroll.content.globalRect().w - total) > 0.1) {
            self.scroll.content.setStyleInline(self.cx.allocator, .{ .width = .{ .px = total } });
            widths_changed = true;
        }
        for (self.scroll.content.children.items) |row| {
            for (row.children.items, 0..) |cell, column| if (@abs(cell.globalRect().w - widths[column]) > 0.1) {
                cell.setStyleInline(self.cx.allocator, .{ .width = .{ .px = widths[column] } });
                widths_changed = true;
            };
        }
        if (widths_changed) return .needs_layout;
        var resized = false;
        for (self.scroll.content.children.items) |row| {
            var height: f32 = 34;
            for (row.children.items) |cell| {
                const edges = cell.style.border.resolvedWidths();
                height = @max(height, cell.children.items[0].globalRect().h + cell.style.padding.vertical() + edges[0] + edges[2]);
            }
            for (row.children.items) |cell| if (@abs(cell.globalRect().h - height) > 0.1) {
                cell.setStyleInline(self.cx.allocator, .{ .height = .{ .px = height } });
                resized = true;
            };
        }
        return if (resized) .needs_layout else .done;
    }

    fn release(self: *TableLayout) void {
        self.cx.removeAfterLayoutHook(self);
    }
};

// Measure parsed Markdown text with the same font/span choices as rendering,
// rather than counting source bytes (which include markup and vary for CJK).
fn tableContentWidth(cx: *ui.Cx, node: *ui.Node) f32 {
    var width: f32 = 0;
    if (node.getText()) |text| {
        var start: usize = 0;
        while (start < text.content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text.content, start, '\n') orelse text.content.len;
            var pos = start;
            var line_width: f32 = 0;
            while (pos < line_end) {
                var end = line_end;
                var weight = text.font_weight;
                var mono = text.use_monospace_font;
                var italic = text.use_italic_font;
                var padding: f32 = 0;
                for (text.spans) |span| {
                    if (span.start > pos) end = @min(end, span.start);
                    if (span.start <= pos and span.end > pos) {
                        end = @min(end, span.end);
                        weight = span.font_weight orelse weight;
                        mono = mono or span.use_monospace_font;
                        italic = italic or span.use_italic_font;
                        if (pos == span.start) padding += span.inline_box_padding_left;
                        if (end == span.end) padding += span.inline_box_padding_right;
                        break;
                    }
                }
                const visual = cx.text.visualLine(.{ .text = text.content[pos..end], .font_family = "system", .font_family_id = text.font_family, .font_size = text.font_size, .font_weight = weight, .use_monospace = mono, .use_italic = italic, .use_symbols = text.use_symbols_font }) catch null;
                line_width += padding + if (visual) |line| line.width else cx.text.measureTextWidth(text.content[pos..end], text.font_size, weight, italic);
                pos = end;
            }
            width = @max(width, line_width);
            start = line_end + 1;
        }
    }
    var children_width: f32 = 0;
    for (node.children.items) |child| {
        const child_width = tableContentWidth(cx, child) + child.style.marginHorizontal();
        if (node.style.direction == .row) children_width += child_width else children_width = @max(children_width, child_width);
    }
    const edges = node.style.border.resolvedWidths();
    return @max(width, children_width) + node.style.padding.horizontal() + edges[1] + edges[3];
}

fn appendTable(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, lines: []const []const u8, width: f32) !void {
    const header_cells = try tableCells(cx.allocator, lines[0]);
    defer cx.allocator.free(header_cells);
    const columns = @min(header_cells.len, 16);
    const column_width = @max(120, width / @as(f32, @floatFromInt(columns)));
    // Markdown spans wrap using their rendered fonts and word boundaries.
    // Let layout measure that content instead of estimating lines from width.
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .horizontal, .rubber_band_x = false }).mount(scope, cx);
    scroll.container.meta.ownership.meta.test_id = "ai.message.table";
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .flex_shrink = 0 });
    scroll.content.setStyleInline(cx.allocator, .{ .width = .{ .px = @as(f32, @floatFromInt(columns)) * column_width }, .direction = .column, .flex_shrink = 0 });
    for (lines, 0..) |line, index| {
        if (index == 1) continue;
        const row = try ui.box(cx, .{ .width = .fill(), .min_height = 34, .direction = .row, .flex_shrink = 0 }, .{});
        const cells = try tableCells(cx.allocator, line);
        defer cx.allocator.free(cells);
        for (0..columns) |column| {
            const cell = try ui.box(cx, S.tableCell(column_width, index == 0, column == 0), .{});
            const value = std.mem.trim(u8, if (column < cells.len) cells[column] else "", " \t\r");
            const cell_source = try unescapeTablePipes(cx.allocator, value);
            defer cx.allocator.free(cell_source);
            const owned_cell = try scope.createText(cell_source, .{});
            const text = try ui.widgets.Markdown(.{ .text = owned_cell, .options = S.markdownOptions() }).mount(scope, cx);
            try compact(cx, scope, text);
            try @import("ai_markdown_links.zig").bind(cx, scope, text, owned_cell.peek());
            try cell.appendChild(cx.allocator, text);
            try row.appendChild(cx.allocator, cell);
        }
        try scroll.content.appendChild(cx.allocator, row);
    }
    // The mount width is only a seed. Use the actual viewport after layout so
    // retained messages reflow without rebuilding text, selection or controls.
    const layout = try scope.createState(TableLayout, .{ .cx = cx, .scroll = scroll, .columns = columns });
    try scope.onCleanup(TableLayout, layout, TableLayout.release);
    try cx.addAfterLayoutHook(layout, TableLayout.afterLayout);
    try parent.appendChild(cx.allocator, scroll.container);
}

/// Zenit already emits h1..h6 at `base_font_size * mdHeadingSizeMul(level)`
/// (1.0×..1.4×) with weight 600. Fit that hierarchy into the compact bubble by
/// remapping the ratio range onto `heading_font_size..heading_max_font_size`;
/// collapsing every heading to one size loses the outline.
fn compact(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node) !void {
    if (node.getText()) |text| if (text.font_weight == 600) {
        const ratio = @min(S.heading_scale_max, @max(@as(f32, 1.0), text.font_size / S.body_font_size));
        const scale = (ratio - 1.0) / (S.heading_scale_max - 1.0);
        var style = text;
        style.font_size = S.heading_font_size + scale * (S.heading_max_font_size - S.heading_font_size);
        // Keep an 18px per-line rhythm; wrapping still determines total height.
        style.line_height = 18.0 / style.font_size;
        node.setText(style);
    };
    for (node.children.items) |child| try compact(cx, scope, child);
}

const CodeState = struct {
    cx: *ui.Cx,
    source: *ui.Signal([]const u8),
    language: *ui.Signal([]const u8),
    copy_button: *@import("copy_button.zig").Button = undefined,
    wrap_label: *ui.Signal([]const u8),
    wrap_style: *ui.Signal(S.ButtonStyle),
    scroll: ui.widgets.ScrollAreaResult = undefined,
    text: *ui.Node = undefined,
    button: *ui.Node = undefined,
    natural_width: f32 = 1,
    available_width: f32 = -1,
    wrapped: bool = false,
    fn update(self: *CodeState, code: []const u8, source: []const u8) !void {
        const before = self.text.getText().?.content;
        if (!std.mem.eql(u8, before, code)) {
            const start = if (std.mem.startsWith(u8, code, before)) (if (std.mem.lastIndexOfScalar(u8, before, '\n')) |i| i + 1 else 0) else 0;
            const width = textWidth(self.cx, code[start..], 11, 450);
            self.natural_width = if (start > 0) @max(self.natural_width, width) else width;
            try self.text.setTextContent(self.cx.allocator, code);
            self.available_width = -1;
        }
        if (!std.mem.eql(u8, self.source.peek(), source)) self.source.set(source);
    }
    fn copy(self: *CodeState) void {
        self.copy_button.copy(self.source.get());
    }
    fn toggleWrap(self: *CodeState) void {
        self.wrapped = !self.wrapped;
        self.available_width = -1;
        var text = self.text.getText().?;
        text.wrap = if (self.wrapped) .char else .newline_only;
        self.text.setText(text);
        self.wrap_label.set(if (self.wrapped) "取消自动换行" else "自动换行");
        self.wrap_style.set(S.codeWrapButton(self.wrapped));
        if (self.button.behavior.interaction.a11y) |*a11y| a11y.pressed = self.wrapped;
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *CodeState = @ptrCast(@alignCast(raw));
        const viewport = self.scroll.container.globalRect();
        if (viewport.w <= 20) return .done;
        const width = if (self.wrapped) viewport.w else self.natural_width + 20;
        if (@abs(width - self.available_width) > 0.1) {
            self.available_width = width;
            self.scroll.content.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width } });
            self.text.setStyleInline(self.cx.allocator, .{ .width = .{ .px = @max(1, width - 20) } });
            return .needs_layout;
        }
        const height = @min(@max(16, self.text.globalRect().h) + 12, S.code_max_height);
        if (@abs(viewport.h - height) > 0.1) {
            self.scroll.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = height } });
            return .needs_layout;
        }
        return .done;
    }
    fn release(self: *CodeState) void {
        self.cx.removeAfterLayoutHook(self);
    }
};
fn appendCode(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, code: []const u8, source: []const u8, language: []const u8) !*CodeState {
    const block = try ui.box(cx, S.codeBlock(), .{});
    block.meta.ownership.meta.test_id = "ai.message.code";
    @import("layer_materials.zig").card(block, .control);
    const toolbar = try ui.box(cx, S.codeToolbar(), .{});
    toolbar.meta.ownership.meta.test_id = "ai.message.code.header";
    const label = try ui.text(cx, "", S.codeLanguage());
    try label.setTextContent(cx.allocator, languageLabel(language));
    @import("app_theme.zig").bindInk(label, "fg_2");
    label.meta.ownership.meta.test_id = "ai.message.code.language";
    label.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1 });
    try toolbar.appendChild(cx.allocator, label);
    const state = try scope.createState(CodeState, .{ .cx = cx, .source = try scope.createText(source, .{}), .language = try scope.createText(language, .{}), .wrap_label = try scope.createText("自动换行", .{}), .wrap_style = try scope.createSignal(S.ButtonStyle, S.codeWrapButton(false)) });
    const wrap = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get("wrap-text").?, .icon_size = @as(f32, 13), .a11y_label = state.wrap_label, .base_style = state.wrap_style, .on_click = cx.on(CodeState, state, CodeState.toggleWrap) }).mount(scope, cx);
    wrap.meta.ownership.meta.test_id = "ai.message.code.wrap";
    state.button = wrap;
    try toolbar.appendChild(cx.allocator, wrap);
    state.copy_button = try @import("copy_button.zig").Button.mount(cx, scope, .{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 13), .a11y_label = "复制代码", .base_style = S.windowControl(), .on_click = cx.on(CodeState, state, CodeState.copy) });
    const copy = state.copy_button.node;
    copy.meta.ownership.meta.test_id = "ai.message.code.copy";
    try toolbar.appendChild(cx.allocator, copy);
    try block.appendChild(cx.allocator, toolbar);
    var count: usize = 1;
    for (code) |byte| if (byte == '\n') {
        count += 1;
    };
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .both, .rubber_band_x = false, .rubber_band_y = false, .height = @min(@as(f32, @floatFromInt(count)) * 16 + 12, S.code_max_height) }).mount(scope, cx);
    scroll.container.meta.ownership.meta.test_id = "ai.message.code.scroll";
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .max_height = S.code_max_height, .flex_shrink = 0 });
    const content_width = textWidth(cx, code, 11, 450);
    const text = try ui.text(cx, code, .{ .font_size = 11, .font_weight = 450, .line_height = 16.0 / 11.0, .wrap = .newline_only, .use_monospace_font = true, .color = S.markdownOptions().code_color });
    @import("app_theme.zig").bindInk(text, "fg_1");
    text.meta.ownership.meta.test_id = "ai.message.code.text";
    text.setStyleInline(cx.allocator, .{ .width = .{ .px = content_width }, .min_height = 16, .flex_shrink = 0 });
    try scroll.content.appendChild(cx.allocator, text);
    scroll.content.setStyleInline(cx.allocator, .{ .width = .{ .px = content_width + 20 }, .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 }, .direction = .column, .gap = 0, .flex_shrink = 0 });
    state.scroll = scroll;
    state.text = text;
    state.natural_width = content_width;
    try scope.onCleanup(CodeState, state, CodeState.release);
    try cx.addAfterLayoutHook(state, CodeState.afterLayout);
    try block.appendChild(cx.allocator, scroll.container);
    try parent.appendChild(cx.allocator, block);
    return state;
}

// Zenit's Markdown emitter skips empty code lines. Keep a visual blank line
// in the display projection; the conversation and copy source remain original.
pub fn preserveCodeLines(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var lines = std.mem.splitScalar(u8, value, '\n');
    var fence: u8 = 0;
    var fence_length: usize = 0;
    var first = true;
    while (lines.next()) |line| {
        if (!first) try output.append(allocator, '\n');
        first = false;
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (line.len - trimmed.len <= 3 and trimmed.len >= 3 and (trimmed[0] == '`' or trimmed[0] == '~')) {
            var count: usize = 0;
            while (count < trimmed.len and trimmed[count] == trimmed[0]) : (count += 1) {}
            if (fence == 0 and count >= 3) {
                fence = trimmed[0];
                fence_length = count;
            } else if (fence == trimmed[0] and count >= fence_length and std.mem.trim(u8, trimmed[count..], " \t\r").len == 0) {
                fence = 0;
            }
        }
        if (fence != 0 and line.len == 0) try output.append(allocator, ' ') else try output.appendSlice(allocator, line);
    }
    return output.toOwnedSlice(allocator);
}

pub fn textWidth(cx: *ui.Cx, value: []const u8, size: f32, weight: u16) f32 {
    var width: f32 = 1;
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |line| {
        const visual = cx.text.visualLine(.{ .text = line, .font_family = "system", .font_size = size, .font_weight = weight, .use_monospace = true }) catch {
            width = @max(width, cx.text.measureTextWidth(line, size, weight, false) * 1.25 + 1);
            continue;
        };
        width = @max(width, visual.width + 1);
    }
    return width;
}

/// Stable completed Markdown blocks with one mutable tail. Parsing of each
/// chunk uses the same renderer as a completed message (fences/tables/images).
pub const Retained = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    chunks: std.ArrayList(Chunk) = .empty,
    selection: *@import("ai_text_selection.zig").Selection = undefined,
    width: f32 = 0,
    const Chunk = struct { root: *ui.Node, scope: *ui.Scope, source: []const u8, owned: *ui.Signal([]const u8), selection_start: usize, plain: ?*ui.Node = null, code: ?*CodeState = null };
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*Retained {
        const self = try scope.createState(Retained, .{ .cx = cx, .scope = scope, .root = try ui.box(cx, S.assistantMessage(), .{}) });
        self.selection = try @import("ai_text_selection.zig").retained(cx, scope, self.root);
        try scope.onCleanup(Retained, self, cleanup);
        return self;
    }
    fn cleanup(self: *Retained) void {
        self.chunks.deinit(self.cx.allocator);
    }
    fn truncate(self: *Retained, count: usize) void {
        while (self.chunks.items.len > count) {
            const old = self.chunks.pop().?;
            self.selection.truncate(old.selection_start);
            self.cx.detachChild(self.root, old.root);
            old.scope.dispose();
            self.cx.destroyDetached(old.root);
        }
    }
    pub fn update(self: *Retained, source: []const u8, width: f32, images: ?@import("ai_transcript_images.zig").Context) !void {
        if (self.width != width) self.truncate(0);
        self.width = width;
        var start: usize = 0;
        var offset: usize = 0;
        var slot: usize = 0;
        var fence: u8 = 0;
        var fence_len: usize = 0;
        var container_end: usize = 0;
        while (offset < source.len) {
            const end = if (std.mem.indexOfScalarPos(u8, source, offset, '\n')) |pos| pos + 1 else source.len;
            const complete = source[end - 1] == '\n';
            const line = std.mem.trim(u8, source[offset..end], " \t\r\n");
            if (fence == 0 and offset >= container_end) container_end = blocks.sourceEnd(source, offset);
            var closed = false;
            if (offset >= container_end and (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~"))) {
                var count: usize = 0;
                while (count < line.len and line[count] == line[0]) : (count += 1) {}
                if (fence == 0) {
                    fence = line[0];
                    fence_len = count;
                } else if (fence == line[0] and count >= fence_len and std.mem.trim(u8, line[count..], " \t\r").len == 0) {
                    fence = 0;
                    closed = true;
                }
            }
            if (complete and fence == 0 and end >= container_end and (line.len == 0 or closed)) {
                try self.chunk(&slot, source[start..end], width, images);
                start = end;
            }
            offset = end;
        }
        try self.chunk(&slot, source[start..], width, images);
        self.truncate(slot);
    }
    fn chunk(self: *Retained, slot: *usize, text: []const u8, width: f32, images: ?@import("ai_transcript_images.zig").Context) !void {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
        const index = slot.*;
        slot.* += 1;
        if (index < self.chunks.items.len and std.mem.eql(u8, self.chunks.items[index].source, text)) return;
        if (index + 1 == self.chunks.items.len) {
            const old = &self.chunks.items[index];
            if (old.code) |code| if (codeParts(text)) |parts| {
                if (std.mem.eql(u8, code.language.peek(), parts.language)) {
                    try code.update(parts.code, parts.source);
                    old.owned.set(text);
                    old.source = old.owned.peek();
                    return;
                }
            };
        }
        if (index + 1 == self.chunks.items.len and plainSource(text)) {
            const old = &self.chunks.items[index];
            if (old.plain) |node| {
                try node.setTextContent(self.cx.allocator, text);
                old.owned.set(text);
                old.source = old.owned.peek();
                return;
            }
        }
        self.truncate(index);
        const scope = try self.scope.childScope();
        errdefer scope.dispose();
        const owned = try scope.createText(text, .{});
        var code_state: ?*CodeState = null;
        const root = try mountContent(self.cx, scope, owned.peek(), width, images, false, &code_state, 0);
        errdefer self.cx.destroyDetached(root);
        try self.chunks.ensureUnusedCapacity(self.cx.allocator, 1);
        try self.root.appendChild(self.cx.allocator, root);
        const selection_start = self.selection.entries.items.len;
        try self.selection.append(scope, root);
        self.chunks.appendAssumeCapacity(.{ .root = root, .scope = scope, .source = owned.peek(), .owned = owned, .selection_start = selection_start, .plain = if (plainSource(text)) plainNode(root, text) else null, .code = if (codeParts(text) != null) code_state else null });
    }
};

fn plainSource(text: []const u8) bool {
    return text.len != 0 and std.mem.trim(u8, text, " ").len == text.len and std.mem.indexOfAny(u8, text, "\n\r\t`*_[]<>#!|~\\-+.") == null;
}
fn plainNode(root: *ui.Node, text: []const u8) ?*ui.Node {
    if (root.getText()) |value| if (value.spans.len == 0 and std.mem.eql(u8, value.content, text)) return root;
    for (root.children.items) |child| if (plainNode(child, text)) |node| return node;
    return null;
}

const CodeParts = struct { language: []const u8, code: []const u8, source: []const u8 };
fn codeParts(text: []const u8) ?CodeParts {
    const first_end = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
    const first = std.mem.trim(u8, text[0..first_end], " \t\r");
    if (!std.mem.startsWith(u8, first, "```") and !std.mem.startsWith(u8, first, "~~~")) return null;
    var length: usize = 0;
    while (length < first.len and first[length] == first[0]) : (length += 1) {}
    const start = first_end + 1;
    var offset = start;
    while (offset < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[offset..end], " \t\r");
        var count: usize = 0;
        while (count < line.len and line[count] == first[0]) : (count += 1) {}
        if (count >= length and std.mem.trim(u8, line[count..], " \t\r").len == 0) {
            if (std.mem.trim(u8, text[end..], " \t\r\n").len != 0) return null;
            const code_end = if (offset > start and text[offset - 1] == '\n') offset - 1 else offset;
            return .{ .language = first[length..], .code = text[start..code_end], .source = text[start..offset] };
        }
        offset = @min(text.len, end + 1);
    }
    return .{ .language = first[length..], .code = text[start..], .source = text[start..] };
}
