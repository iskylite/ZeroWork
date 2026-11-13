const std = @import("std");
const core = @import("../../core.zig");
const coordinates = @import("text_core").text_coordinates;
const layout = core.text_layout;
const markdown = @import("../markdown/mod.zig");
const Document = @import("textarea_document.zig").TextareaDocument;

pub const Presentation = struct {
    options: markdown.MarkdownOptions,
    code: std.ArrayList(markdown.LiveCode) = .empty,
    revision: ?u64 = null,
    code_changed: bool = false,
    caret_line: ?usize = null,
    anchor_line: ?usize = null,
    composing: ?struct { start: usize, end: usize } = null,
    geometry: std.heap.ArenaAllocator,
    projection: std.heap.ArenaAllocator,
    cached_key: ?ProjectionKey = null,
    cached_line: ?markdown.LiveLine = null,

    const ProjectionKey = struct { revision: u64, index: usize, reveal_image: bool, kind: markdown.LiveCode };

    pub fn deinit(self: *Presentation) void {
        self.code.deinit(self.geometry.child_allocator);
        self.geometry.deinit();
        self.projection.deinit();
    }

    pub fn completeHeading(self: *Presentation, a: std.mem.Allocator, doc: *const Document, caret: usize) !?[]u8 {
        const index = doc.offsetToLineCol(caret).line;
        const start = doc.getLineStart(index);
        const source = doc.getText();
        const end = doc.getLineEnd(index);
        if (caret != end and !(caret + 1 == end and source[caret] == '\r')) return null;
        const prefix = std.mem.trimStart(u8, source[start..caret], " ");
        if (caret - start - prefix.len > 3 or prefix.len == 0 or prefix.len > 6 or
            std.mem.indexOfNone(u8, prefix, "#") != null) return null;

        try self.refreshCode(doc);
        if (self.code.items[index] != .prose) return null;
        var previous = index;
        while (previous > 0) {
            previous -= 1;
            if (self.code.items[previous] != .prose) continue;
            const raw = std.mem.trimEnd(u8, source[doc.getLineStart(previous)..doc.getLineEnd(previous)], "\r");
            const heading = std.mem.trimStart(u8, raw, " ");
            if (raw.len - heading.len > 3) continue;
            const level = markdown.atxHeadingLevel(heading) orelse continue;
            if (level > prefix.len) continue;
            if (level < prefix.len) return null;

            const body = skipSpaces(heading, level);
            const number = Number.read(heading, body, endOfDigits(heading, body), true) orelse return null;
            return try std.fmt.allocPrint(a, " {s}{d}{s} ", .{
                heading[body..number.start],
                number.value + 1,
                heading[number.end..number.delimiter_end],
            });
        }
        return null;
    }

    pub fn refreshCode(self: *Presentation, doc: *const Document) !void {
        if (self.revision == doc.revision) return;
        const previous_len = self.code.items.len;
        try self.code.resize(self.geometry.child_allocator, doc.lineCount());
        self.revision = doc.revision;
        var fence: ?Fence = null;
        for (self.code.items, 0..) |*entry, i| {
            const text = doc.getText()[doc.getLineStart(i)..doc.getLineEnd(i)];
            const kind: markdown.LiveCode = if (fence) |opening| blk: {
                if (Fence.read(text)) |closing| {
                    if (closing.marker == opening.marker and closing.count >= opening.count and closing.suffix.len == 0) {
                        fence = null;
                        break :blk .closing_fence;
                    }
                }
                break :blk .code;
            } else blk: {
                if (Fence.read(text)) |opening| {
                    if (opening.marker != '`' or std.mem.indexOfScalar(u8, opening.suffix, '`') == null) {
                        fence = opening;
                        break :blk .opening_fence;
                    }
                }
                break :blk .prose;
            };
            const old_kind: markdown.LiveCode = if (i < previous_len) entry.* else .prose;
            self.code_changed = self.code_changed or old_kind != kind;
            entry.* = kind;
        }
    }

    pub fn continueMarkup(self: *Presentation, a: std.mem.Allocator, doc: *const Document, caret: usize) !?NewlineEdit {
        try self.refreshCode(doc);
        const line_index = doc.offsetToLineCol(caret).line;
        if (self.code.items[line_index] != .prose) return null;
        const start = doc.getLineStart(line_index);
        const line_end = doc.getLineEnd(line_index);
        const source = doc.getText();
        const has_cr = line_end > start and source[line_end - 1] == '\r';
        const end_without_cr = line_end - @intFromBool(has_cr);
        const raw = source[start..end_without_cr];
        const marker = Markup.read(raw, self.options.standalone_tasks) orelse return null;
        if (caret - start < marker.body or caret > end_without_cr) return null;
        const exit = std.mem.trim(u8, raw[marker.body..], " \t").len == 0;
        const edit_start = if (exit) start + marker.exitAt() else caret;
        var end = if (exit) end_without_cr else caret;

        var replacement: std.ArrayList(u8) = .empty;
        defer replacement.deinit(a);
        if (!exit) {
            const crlf = has_cr or (line_index + 1 == doc.lineCount() and start >= 2 and source[start - 2] == '\r');
            const newline: []const u8 = if (crlf) "\r\n" else "\n";
            try replacement.appendSlice(a, newline);
            if (marker.number) |number| {
                try replacement.appendSlice(a, raw[0..number.start]);
                try replacement.print(a, "{d}", .{number.value + 1});
                try replacement.appendSlice(a, raw[number.end..marker.body]);
            } else {
                try replacement.appendSlice(a, raw[0..marker.body]);
                if (marker.check_offset) |offset| replacement.items[newline.len + offset] = ' ';
            }
        }
        const next_caret = replacement.items.len;

        // Update subsequent consecutive siblings in the same undo step.
        // An intentional numbering gap or a different list ends the sequence.
        if (marker.number) |number| {
            var expected = number.value + 1;
            for (line_index + 1..doc.lineCount()) |index| {
                if (self.code.items[index] != .prose) break;
                const next_start = doc.getLineStart(index);
                const next_line = doc.getText()[next_start..doc.getLineEnd(index)];
                const next = Markup.read(next_line, self.options.standalone_tasks) orelse break;
                const next_number = next.number orelse break;
                if (next_number.value != expected or
                    !std.mem.eql(u8, raw[0..number.start], next_line[0..next_number.start]) or
                    raw[number.end] != next_line[next_number.end]) break;
                if (!exit and expected == 999_999_999) break;
                try replacement.appendSlice(a, source[end .. next_start + next_number.start]);
                try replacement.print(a, "{d}", .{if (exit) expected - 1 else expected + 1});
                end = next_start + next_number.end;
                expected += 1;
            }
        }
        return .{ .start = edit_start, .end = end, .text = try replacement.toOwnedSlice(a), .caret = next_caret };
    }

    pub fn revealsImage(self: *const Presentation, index: usize, raw: []const u8) bool {
        return (index == self.caret_line or index == self.anchor_line) and std.mem.indexOf(u8, raw, "![") != null;
    }

    fn line(self: *Presentation, doc: *const Document, index: usize, raw: []const u8) !?markdown.LiveLine {
        try self.refreshCode(doc);
        if (self.composing) |range| if (index >= range.start and index <= range.end) return null;
        const kind = self.code.items[index];
        if (kind == .prose and std.mem.indexOfAny(u8, raw, "#>*+_-~`[\\") == null) return null;
        const key: ProjectionKey = .{
            .revision = doc.revision,
            .index = index,
            .reveal_image = self.revealsImage(index, raw),
            .kind = kind,
        };
        if (self.cached_key) |cached| if (std.meta.eql(cached, key)) return self.cached_line;
        self.cached_key = null;
        _ = self.projection.reset(.{ .retain_with_limit = 256 * 1024 });
        const projected = try markdown.projectLine(self.projection.allocator(), raw, self.options, key.reveal_image, kind);
        self.cached_line = if (projected.spans.len != 0 or projected.edits.len != 0 or projected.font_size != self.options.base_font_size)
            projected
        else
            null;
        self.cached_key = key;
        return self.cached_line;
    }

    pub fn breaks(self: *Presentation, a: std.mem.Allocator, doc: *const Document, index: usize, raw: []const u8, width: f32) !?[]u32 {
        // The same logical line may be requested with its trailing CR by the
        // painter and without it by WrapMap. Use the document slice for both.
        const logical_line = doc.getText()[doc.getLineStart(index)..doc.getLineEnd(index)];
        const projected = try self.line(doc, index, logical_line) orelse return null;
        var offsets: std.ArrayList(u32) = .empty;
        errdefer offsets.deinit(a);
        var start: u32 = 0;
        while (start < projected.text.len) {
            start = layout.nextWordWrapBoundary(projected.text, start, width, projected.font_size, projected.font_weight, projected.spans);
            if (start >= projected.text.len) break;
            const source = projected.displayToSource(start);
            if (source == 0 or source >= raw.len) continue;
            if (offsets.items.len > 0 and source <= offsets.items[offsets.items.len - 1]) continue;
            try offsets.append(a, @intCast(source));
        }
        return try offsets.toOwnedSlice(a);
    }

    pub fn segment(self: *Presentation, a: std.mem.Allocator, doc: *const Document, index: usize, start: usize, end: usize) !?Segment {
        const line_start = doc.getLineStart(index);
        const raw = doc.getText()[line_start..doc.getLineEnd(index)];
        const projected = try self.line(doc, index, raw) orelse return null;
        const from: u32 = @intCast(projected.sourceToDisplay(start - line_start));
        const to: u32 = @intCast(projected.sourceToDisplay(end - line_start));
        var spans: std.ArrayList(core.TextSpan) = .empty;
        for (projected.spans) |style| {
            const lo = @max(from, style.start);
            const hi = @min(to, style.end);
            if (lo >= hi) continue;
            var clipped = style;
            if (lo != style.start) clipped.inline_box_padding_left = 0;
            if (hi != style.end) clipped.inline_box_padding_right = 0;
            clipped.start = lo - from;
            clipped.end = hi - from;
            try spans.append(a, clipped);
        }
        return .{
            .text = projected.text[from..to],
            .spans = spans.items,
            .font_size = projected.font_size,
            .font_weight = projected.font_weight,
            .line_start = line_start,
            .source_start = start,
            .source_end = end,
            .display_start = from,
            .projected = projected,
        };
    }
};

const NewlineEdit = struct { start: usize, end: usize, text: []u8, caret: usize };

fn skipSpaces(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn endOfDigits(line: []const u8, start: usize) usize {
    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    return end;
}

const Number = struct {
    start: usize,
    end: usize,
    delimiter_end: usize,
    value: u32,

    fn read(line: []const u8, start: usize, first_end: usize, heading: bool) ?Number {
        var digits = start;
        var end = first_end;
        if (end == start) return null;
        if (heading) {
            while (end + 1 < line.len and line[end] == '.' and std.ascii.isDigit(line[end + 1])) {
                digits = end + 1;
                end = endOfDigits(line, digits);
            }
        }
        var delimiter_end = end;
        if (end < line.len and (line[end] == '.' or (!heading and line[end] == ')'))) delimiter_end += 1;
        if (delimiter_end == end and (!heading or digits == start)) return null;
        if (delimiter_end < line.len and skipSpaces(line, delimiter_end) == delimiter_end) return null;
        if (end - digits > 9) return null;
        const value = std.fmt.parseInt(u32, line[digits..end], 10) catch return null;
        if (value >= 999_999_999) return null;
        return .{ .start = digits, .end = end, .delimiter_end = delimiter_end, .value = value };
    }
};

const Markup = struct {
    prefix: usize,
    body: usize,
    quote: ?usize = null,
    check_offset: ?usize = null,
    number: ?Number = null,

    fn exitAt(self: Markup) usize {
        return if (self.body == self.prefix) self.quote orelse self.prefix else self.prefix;
    }

    fn read(line: []const u8, standalone_tasks: bool) ?Markup {
        var start = skipSpaces(line, 0);
        var quote: ?usize = null;
        while (start < line.len and line[start] == '>') {
            quote = start;
            start = skipSpaces(line, start + 1);
        }
        var marker: Markup = .{ .prefix = start, .body = start, .quote = quote };
        if (start >= line.len) return if (quote != null) marker else null;

        if (line[start] == '#') return null;
        if (markdown.taskPrefix(line[start..], standalone_tasks)) |task| {
            marker.body = skipSpaces(line, start + task.end);
            marker.check_offset = if (task.short) null else start + task.state;
            return marker;
        }
        if (std.mem.indexOfScalar(u8, "-*+", line[start]) != null and skipSpaces(line, start + 1) > start + 1) {
            marker.body = skipSpaces(line, start + 1);
            return marker;
        }

        const end = endOfDigits(line, start);
        if (end == start or end == line.len or (line[end] != '.' and line[end] != ')')) return if (quote != null) marker else null;
        const number = Number.read(line, start, end, false) orelse return null;
        marker.body = skipSpaces(line, number.delimiter_end);
        marker.number = number;
        return marker;
    }
};

const Fence = struct {
    marker: u8,
    count: usize,
    suffix: []const u8,

    fn read(raw: []const u8) ?Fence {
        const text = std.mem.trimStart(u8, raw, " ");
        if (raw.len - text.len > 3 or text.len < 3) return null;
        const marker = text[0];
        if (marker != '`' and marker != '~') return null;
        var end: usize = 1;
        while (end < text.len and text[end] == marker) : (end += 1) {}
        if (end < 3) return null;
        return .{ .marker = marker, .count = end, .suffix = std.mem.trim(u8, text[end..], " \t\r") };
    }
};

pub const Segment = struct {
    text: []const u8,
    spans: []const core.TextSpan,
    font_size: f32,
    font_weight: u16,
    line_start: usize,
    source_start: usize,
    source_end: usize,
    display_start: usize,
    projected: markdown.LiveLine,

    fn sourceOffset(self: Segment, display: usize) usize {
        const byte = self.line_start + self.projected.displayToSource(self.display_start + display);
        return std.math.clamp(byte, self.source_start, self.source_end) - self.source_start;
    }

    pub fn paint(self: Segment, cx: *core.Cx, node: *core.Node, color: core.Color, line_height: f32) !void {
        const text = try cx.allocator.dupe(u8, self.text);
        errdefer cx.allocator.free(text);
        const spans = try cx.allocator.dupe(core.TextSpan, self.spans);
        node.setStyleInline(cx.allocator, .{ .font_size = self.font_size, .font_weight = self.font_weight });
        node.setText(.{
            .content = text,
            .owned = true,
            .color = color,
            .font_size = self.font_size,
            .font_weight = self.font_weight,
            .line_height = line_height / self.font_size,
            .selectable = false,
            .spans = spans,
            .spans_owned = spans.len > 0,
        });
    }

    /// Mirror the text renderer's run boundaries. CoreText supplies grapheme
    /// and bidi caret geometry for each run, including italic and mono faces.
    pub fn visualLine(self: Segment, cx: *core.Cx, a: std.mem.Allocator) !coordinates.VisualLine {
        var stops: std.ArrayList(coordinates.CaretStop) = .empty;
        var x: f32 = 0;
        var run_start: u32 = 0;
        var index: usize = 0;
        while (true) {
            const first = self.chunk(run_start, &index);
            var run_end = first.end;
            if (!first.has_box) {
                while (run_end < self.text.len) {
                    const next = self.chunk(run_end, &index);
                    if (next.weight != first.weight or next.italic != first.italic or next.mono != first.mono or next.has_box) break;
                    run_end = next.end;
                }
            }
            const line = try cx.text.visualLine(.{
                .text = self.text[run_start..run_end],
                .font_family = "system",
                .font_size = self.font_size,
                .font_weight = first.weight,
                .use_italic = first.italic,
                .use_monospace = first.mono,
            });
            try stops.ensureUnusedCapacity(a, line.caret_stops.len);
            for (line.caret_stops) |stop| {
                var mapped = stop;
                mapped.position.byte.value = self.sourceOffset(run_start + stop.position.byte.value);
                mapped.x.value += x + first.left;
                if (stops.items.len > 0) {
                    const last = stops.items[stops.items.len - 1];
                    if (last.position.byte.value == mapped.position.byte.value and @abs(last.x.value - mapped.x.value) < 0.01) continue;
                }
                stops.appendAssumeCapacity(mapped);
            }
            x += line.width + first.left + first.right;
            if (run_end >= self.text.len) return .{
                .source_start = .{ .value = 0 },
                .source_end = .{ .value = self.source_end - self.source_start },
                .caret_stops = stops.items,
                .width = x,
                .base_direction = if (run_start == 0) line.base_direction else .ltr,
            };
            run_start = run_end;
        }
    }

    const Chunk = struct {
        end: u32,
        weight: u16,
        italic: bool = false,
        mono: bool = false,
        has_box: bool = false,
        left: f32 = 0,
        right: f32 = 0,
    };

    fn chunk(self: Segment, start: u32, index: *usize) Chunk {
        while (index.* < self.spans.len and self.spans[index.*].end <= start) index.* += 1;
        if (index.* < self.spans.len) {
            const span = self.spans[index.*];
            if (span.start > start) return .{ .end = span.start, .weight = self.font_weight };
            return .{
                .end = span.end,
                .weight = span.font_weight orelse self.font_weight,
                .italic = span.use_italic_font,
                .mono = span.use_monospace_font,
                .has_box = layout.spanHasInlineBox(span),
                .left = span.inline_box_padding_left,
                .right = span.inline_box_padding_right,
            };
        }
        return .{ .end = @intCast(self.text.len), .weight = self.font_weight };
    }
};
