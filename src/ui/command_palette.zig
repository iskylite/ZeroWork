//! 行首 @ 命令面板 — 纯状态机模块（过滤 / 选择 / 采纳 / 行首检测）。
//!
//! 本文件刻意不 import zenit `ui`：`zig build test` 的测试模块（src/root.zig）
//! 没有 ui import，面板逻辑必须能在测试树里编译执行。节点树（白色圆角卡片、
//! 行节点重建、setBackground 选中刷新、每帧光标行锚定）全部在
//! terminal_view.zig 的 TerminalViewNode 侧完成，两侧契约：
//!
//!   - 文本入口 pushText：面板开着 → handleChar 过滤/@@ 转义；
//!     面板关着且行缓冲为空 → 单个 '@' 开面板并吞掉（不发送远端）。
//!   - 键盘入口 onWorkerKeyDown：面板开着 → handleKey 处理
//!     ↑↓/→/↵/Esc/Backspace，返回 .forward 的键走终端正常路径。
//!   - FrameHook：面板开着 → visibleWindow() 决定行节点窗口，光标行锚定定位。
//!
//! → adopts into a client-local Editor; Enter dispatches a valid local action.
//! Neither the query nor the adopted command is remote terminal input.

const std = @import("std");
const builtin = @import("builtin_commands.zig");

/// 面板可视行数上限：超过后按选中行滚动窗口（“超高时内部滚动”的廉价实现）。
pub const max_visible_rows = 8;

/// 面板键盘事件（terminal_view 把 ui.events.KeyCode 映射过来，带修饰键的组合
/// 一律 .other 保持终端语义）。
pub const Key = enum {
    up,
    down,
    /// → 采纳补全到输入行。
    adopt,
    /// ↵ 执行；缺少参数时继续在本地输入行编辑。
    execute,
    escape,
    backspace,
    other,
};

/// handleChar 的结果。
pub const TextResult = enum {
    /// 输入被吞掉但状态无变化（面板未开 / 无可打印字符）。
    none,
    /// 过滤串已更新，调用方应刷新行内容。
    filtered,
    /// @@ 转义：面板已关闭，调用方发送字面 '@' 到远端。
    escape_at,
};

/// handleKey 的结果。
pub const KeyResult = enum {
    /// 键被面板吞掉但无需发送（↑↓ 移动、退格缩短等）。
    none,
    /// 面板已关闭且无需发送（Esc、空结果时的 ↵/→、退格到空）。
    close,
    /// 键盘路径不产生该值（@@ 转义来自 handleChar）；防御性处理同 escape。
    escape_at,
    /// 不是面板的键（Tab/←/翻页/修饰组合…），调用方继续终端正常处理。
    forward,
    /// 面板已关闭，adoptedText() 里是待本地编辑的命令文本。
    adopt,
    /// 同 adopt，但来自 ↵；调用方校验后执行本地动作。
    execute,
};

/// 行首检测用的远端输入行追踪。应用无法得知远端 shell 的提示符状态，只能
/// 在本地记录“自上次 ↵ 发送以来的字符序列”：
///
///   - 可打印字符（含 UTF-8）追加进 line buffer；
///   - '\r'/'\n' 与“杀行”ctrl（^C ^K ^U ^W）清空（与远端行为一致）；
///   - ↑↓（历史回溯）、Tab（补全改写行）、其余 ctrl/ESC 序列 → 行内容不可
///     知，置 unknown（触发判定一律偏保守：宁可不开面板也不误开）；
///   - ←→/Home/End（仅移动光标）、翻页（scrollback）内容不变；
///   - Backspace(0x7f) 弹出最后一个码点。
///
/// 行缓冲为空且非 unknown 时，'@' 才在行首触发面板。所有成功发往远端的
/// 字节都经 pushBytesToWorker 喂入 record，包括面板采纳的命令文本。
pub const LineTracker = struct {
    content: std.ArrayList(u8) = .empty,
    /// 行内容已不可靠（历史回溯/补全/未知控制序列）；直到下一次 ↵ 才恢复。
    unknown: bool = false,

    /// 超过上限的行（巨型粘贴）不再追踪内容，仅保留“非空”事实。
    const max_tracked_bytes = 4096;

    pub fn deinit(self: *LineTracker, gpa: std.mem.Allocator) void {
        self.content.deinit(gpa);
    }

    /// 行缓冲为空且内容可信 → 行首 '@' 可以触发面板。
    pub fn atLineStart(self: *const LineTracker) bool {
        return !self.unknown and self.content.items.len == 0;
    }

    /// 提交（↵）或杀行（^C/^U）后的空行状态。
    pub fn clearLine(self: *LineTracker) void {
        self.content.clearRetainingCapacity();
        self.unknown = false;
    }

    pub fn markUnknown(self: *LineTracker) void {
        self.unknown = true;
    }

    /// 把一段即将发往远端的字节喂进追踪器（单次 key 序列或粘贴分块均可）。
    pub fn record(self: *LineTracker, gpa: std.mem.Allocator, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == '\r' or b == '\n') {
                self.clearLine();
                i += 1;
            } else if (b == '\t') {
                // Tab 补全会改写远端行 → 内容不可知。
                self.markUnknown();
                i += 1;
            } else if (b == 0x7f) {
                self.popLastCodepoint();
                i += 1;
            } else if (b == 0x1b) {
                i += self.recordEscape(bytes[i..]);
            } else if (b < 0x20) {
                // 控制字符：杀行类与远端行为一致 → 清空；其余（^A/^E 移动、
                // ^D/^Z 改变行状态…）保守置 unknown，避免“假空行”误触发面板。
                switch (b) {
                    0x03, 0x15 => self.clearLine(),
                    else => self.markUnknown(),
                }
                i += 1;
            } else {
                // 可打印字节（ASCII 或 UTF-8 序列字节，含 CJK 双宽字符）。
                if (!self.unknown) {
                    if (self.content.items.len >= max_tracked_bytes) {
                        self.markUnknown();
                    } else {
                        self.content.append(gpa, b) catch self.markUnknown();
                    }
                }
                i += 1;
            }
        }
    }

    /// 解析一个以 ESC 开头的序列，返回消费的字节数。
    fn recordEscape(self: *LineTracker, seq: []const u8) usize {
        if (seq.len < 2) {
            self.markUnknown();
            return seq.len;
        }
        if (seq[1] == '[') {
            // CSI：扫到 final 字节（0x40..0x7E）为止。
            var j: usize = 2;
            while (j < seq.len and !(seq[j] >= 0x40 and seq[j] <= 0x7e)) j += 1;
            if (j >= seq.len) {
                self.markUnknown();
                return seq.len;
            }
            const params = seq[2..j];
            switch (seq[j]) {
                // ↑↓：shell 历史回溯整行替换 → 不可知。
                'A', 'B' => self.markUnknown(),
                // ←→/Home/End：仅移动光标，行内容不变。
                'C', 'D', 'H', 'F' => if (self.content.items.len > 0) self.markUnknown(),
                '~' => {
                    if (std.mem.eql(u8, params, "3")) {
                        self.markUnknown(); // Forward-delete 改写行
                    } else if (std.mem.eql(u8, params, "5") or std.mem.eql(u8, params, "6")) {
                        // PageUp/PageDown：scrollback，行内容不变。
                    } else {
                        self.markUnknown();
                    }
                },
                else => self.markUnknown(),
            }
            return j + 1;
        }
        if (seq[1] == 'O') {
            // SS3（应用键盘模式，vim/tmux 里的方向键）。
            if (seq.len < 3) {
                self.markUnknown();
                return seq.len;
            }
            switch (seq[2]) {
                'A', 'B' => self.markUnknown(),
                'C', 'D', 'H', 'F' => if (self.content.items.len > 0) self.markUnknown(),
                else => self.markUnknown(),
            }
            return 3;
        }
        // 裸 ESC（Esc 键）或 ESC+字母（macOS Option 组合）。
        self.markUnknown();
        return @min(2, seq.len);
    }

    /// Backspace：弹出最后一个 UTF-8 码点（与远端行编辑保持同步）。
    fn popLastCodepoint(self: *LineTracker) void {
        if (self.unknown) return;
        const items = self.content.items;
        if (items.len == 0) return;
        var n = items.len - 1;
        while (n > 0 and (items[n] & 0xC0) == 0x80) n -= 1;
        self.content.shrinkRetainingCapacity(n);
    }
};

/// 面板状态机。节点渲染在 terminal_view.zig；本结构只决定“显示哪些行、
/// 选中哪行、采纳什么文本”。
pub const Palette = struct {
    local_session: bool = false,
    is_open: bool = false,
    /// '@' 之后敲入的过滤串（不含 '@' 本身；可含空格延伸出参数）。
    query: std.ArrayList(u8) = .empty,
    /// 采纳文本暂存（“@name + 过滤串中超出 name 的部分”），handleKey 在
    /// close 前填充，调用方须在下一次面板操作前取用。
    adopt_buf: std.ArrayList(u8) = .empty,
    /// 当前匹配的 catalog 下标（保序）。
    matches: [builtin.catalog.len]usize = @splat(0),
    match_count: usize = 0,
    selected: usize = 0,
    first_visible: usize = 0,

    pub fn deinit(self: *Palette, gpa: std.mem.Allocator) void {
        self.query.deinit(gpa);
        self.adopt_buf.deinit(gpa);
    }

    pub fn isOpen(self: *const Palette) bool {
        return self.is_open;
    }

    /// 打开面板：空过滤串 → 全部内置命令，选中归零。
    pub fn open(self: *Palette) void {
        self.is_open = true;
        self.query.clearRetainingCapacity();
        self.adopt_buf.clearRetainingCapacity();
        self.selected = 0;
        self.first_visible = 0;
        self.rebuild();
    }

    pub fn close(self: *Palette) void {
        self.is_open = false;
        self.query.clearRetainingCapacity();
        self.match_count = 0;
        self.selected = 0;
        self.first_visible = 0;
    }

    pub fn matchCount(self: *const Palette) usize {
        return self.match_count;
    }

    /// 绝对匹配下标 → catalog 条目。
    pub fn matchAt(self: *const Palette, index: usize) builtin.Entry {
        return builtin.catalog[self.matches[index]];
    }

    pub fn selectedEntry(self: *const Palette) ?builtin.Entry {
        if (!self.is_open or self.match_count == 0 or self.selected >= self.match_count) return null;
        return self.matchAt(self.selected);
    }

    /// 面板打开期间的可视窗口（超出 max_visible_rows 时滚动）。
    /// selected_offset 保证非空（ensureWindow 保证选中行始终在窗口内）。
    pub const VisibleWindow = struct {
        first: usize,
        count: usize,
        selected_offset: ?usize,
    };

    pub fn visibleWindow(self: *const Palette) VisibleWindow {
        const available = if (self.match_count > self.first_visible) self.match_count - self.first_visible else 0;
        const count = @min(available, max_visible_rows);
        const selected_offset: ?usize = if (self.match_count > 0 and
            self.selected >= self.first_visible and
            self.selected < self.first_visible + count)
            self.selected - self.first_visible
        else
            null;
        return .{ .first = self.first_visible, .count = count, .selected_offset = selected_offset };
    }

    /// 文本输入（text_input / IME commit / 粘贴的可打印部分）：
    /// 追加进过滤串并重算匹配；“面板开着 + 过滤串为空 + 单个 '@'”是
    /// @@ 转义 → 关面板，由调用方发送字面 '@'。
    pub fn handleChar(self: *Palette, gpa: std.mem.Allocator, text: []const u8) TextResult {
        if (!self.is_open) return .none;
        if (text.len == 1 and text[0] == '@' and self.query.items.len == 0) {
            self.close();
            return .escape_at;
        }
        var appended = false;
        var i: usize = 0;
        while (i < text.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                i += 1;
                continue;
            };
            if (i + cp_len > text.len) break;
            const cp = std.unicode.utf8Decode(text[i .. i + cp_len]) catch {
                i += cp_len;
                continue;
            };
            if (isPrintableCodepoint(cp)) {
                self.query.appendSlice(gpa, text[i .. i + cp_len]) catch return .none;
                appended = true;
            }
            i += cp_len;
        }
        if (!appended) return .none;
        self.rebuild();
        return .filtered;
    }

    /// 键盘输入（↑↓/→/↵/Esc/Backspace；其余 .other → .forward 由调用方走终端）。
    pub fn handleKey(self: *Palette, gpa: std.mem.Allocator, key: Key) KeyResult {
        if (!self.is_open) return .forward;
        switch (key) {
            .other => return .forward,
            .up => {
                if (self.match_count > 0) {
                    self.selected = (self.selected + self.match_count - 1) % self.match_count;
                    self.ensureWindow();
                }
                return .none;
            },
            .down => {
                if (self.match_count > 0) {
                    self.selected = (self.selected + 1) % self.match_count;
                    self.ensureWindow();
                }
                return .none;
            },
            .escape => {
                self.close();
                return .close;
            },
            .backspace => {
                // 缩短过滤串；已为空（或缩短后为空）则关闭面板。
                if (self.query.items.len == 0) {
                    self.close();
                    return .close;
                }
                var n = self.query.items.len - 1;
                while (n > 0 and (self.query.items[n] & 0xC0) == 0x80) n -= 1;
                self.query.shrinkRetainingCapacity(n);
                if (self.query.items.len == 0) {
                    self.close();
                    return .close;
                }
                self.rebuild();
                return .none;
            },
            .adopt, .execute => {
                if (self.match_count == 0) {
                    self.close();
                    return .close;
                }
                // 先把采纳文本固化进 adopt_buf（close 会清空 query），再关面板。
                _ = self.fillAdoptText(gpa);
                self.close();
                return if (key == .adopt) .adopt else .execute;
            },
        }
    }

    /// 采纳文本：“@name” + 过滤串里超出命令名的部分（用户在面板里继续敲的
    /// 参数，如 “@theme dark-pro”）。面板已关时返回 handleKey 固化的结果。
    pub fn adoptText(self: *Palette, gpa: std.mem.Allocator) ?[]const u8 {
        if (self.selectedEntry()) |_| {
            return self.fillAdoptText(gpa);
        }
        return null;
    }

    /// handleKey 关面板前固化的采纳文本（无匹配为 null）。
    pub fn adoptedText(self: *const Palette) ?[]const u8 {
        if (self.adopt_buf.items.len == 0) return null;
        return self.adopt_buf.items;
    }

    fn fillAdoptText(self: *Palette, gpa: std.mem.Allocator) ?[]const u8 {
        const entry = self.selectedEntry() orelse return null;
        self.adopt_buf.clearRetainingCapacity();
        self.adopt_buf.appendSlice(gpa, entry.name) catch return null;
        // entry.name 含前导 '@'；过滤串比命令名长出来的部分是参数（保留原样）。
        const name_core_len = entry.name.len - 1;
        if (self.query.items.len > name_core_len) {
            self.adopt_buf.appendSlice(gpa, self.query.items[name_core_len..]) catch return null;
        }
        return self.adopt_buf.items;
    }

    /// 重算匹配 + 粘滞选中（过滤后原选中命令仍匹配则保持选中）。
    /// 匹配规则：命令名（去 '@’）与过滤串互为大小写不敏感前缀 —
    /// “th” 匹配 @theme；“theme dark” 也匹配 @theme（参数延伸）。
    pub fn rebuild(self: *Palette) void {
        const prev = if (self.match_count > 0 and self.selected < self.match_count) self.matches[self.selected] else null;
        var count: usize = 0;
        for (builtin.catalog, 0..) |entry, index| {
            if (self.local_session and (std.mem.eql(u8, entry.name, "@up") or std.mem.eql(u8, entry.name, "@dl") or std.mem.eql(u8, entry.name, "@socks"))) continue;
            if (matchesQuery(entry, self.query.items)) {
                self.matches[count] = index;
                count += 1;
            }
        }
        self.match_count = count;
        var next: usize = 0;
        if (prev) |wanted| {
            for (self.matches[0..count], 0..) |catalog_index, position| {
                if (catalog_index == wanted) {
                    next = position;
                    break;
                }
            }
        }
        self.selected = if (count > 0) next else 0;
        self.ensureWindow();
    }

    /// 选中行移出可视窗口时滚动窗口。
    fn ensureWindow(self: *Palette) void {
        if (self.match_count == 0) {
            self.first_visible = 0;
            return;
        }
        if (self.selected < self.first_visible) {
            self.first_visible = self.selected;
        } else if (self.selected >= self.first_visible + max_visible_rows) {
            self.first_visible = self.selected + 1 - max_visible_rows;
        }
    }
};

fn matchesQuery(entry: builtin.Entry, query: []const u8) bool {
    const name = entry.name[1..]; // 去掉前导 '@'
    if (query.len == 0) return true;
    if (query.len <= name.len) {
        return asciiStartsWithIgnoreCase(name, query);
    }
    // A parameter begins at a separator; @newest must not execute @new.
    return asciiStartsWithIgnoreCase(query, name) and
        (query[name.len] == ' ' or query[name.len] == '\t');
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
    }
    return true;
}

fn isPrintableCodepoint(cp: u21) bool {
    return cp >= 0x20 and cp != 0x7f and !(cp >= 0x80 and cp <= 0x9f);
}

/// Owns the adopted line while the remote shell remains at its unchanged prompt.
pub const Editor = struct {
    active: bool = false,
    text: std.ArrayList(u8) = .empty,
    caret: usize = 0,

    pub const Key = enum { left, right, home, end, backspace, delete, execute, escape, clear };
    pub const Result = enum { edited, execute, invalid, cancel };

    pub fn deinit(self: *Editor, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
    }

    pub fn adopt(self: *Editor, gpa: std.mem.Allocator, text: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, text);
        self.active = true;
        self.caret = self.text.items.len;
    }

    pub fn cancel(self: *Editor) void {
        self.active = false;
        self.text.clearRetainingCapacity();
        self.caret = 0;
    }

    pub fn insert(self: *Editor, gpa: std.mem.Allocator, text: []const u8) !bool {
        if (!self.active or !std.unicode.utf8ValidateSlice(text)) return false;
        var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (!isPrintableCodepoint(cp)) return false;
        }
        try self.text.insertSlice(gpa, self.caret, text);
        self.caret += text.len;
        return true;
    }

    pub fn key(self: *Editor, input: Editor.Key) Editor.Result {
        switch (input) {
            .escape => {
                self.cancel();
                return .cancel;
            },
            .execute => {
                return switch (builtin.parse(self.text.items)) {
                    .invalid, .not_command => .invalid,
                    else => .execute,
                };
            },
            .left => self.caret = previousCodepoint(self.text.items, self.caret),
            .right => self.caret = nextCodepoint(self.text.items, self.caret),
            .home => self.caret = 0,
            .end => self.caret = self.text.items.len,
            .backspace => {
                const start = previousCodepoint(self.text.items, self.caret);
                self.removeRange(start, self.caret);
                self.caret = start;
            },
            .delete => self.removeRange(self.caret, nextCodepoint(self.text.items, self.caret)),
            .clear => {
                self.text.clearRetainingCapacity();
                self.caret = 0;
            },
        }
        return .edited;
    }

    fn removeRange(self: *Editor, start: usize, end: usize) void {
        if (end <= start) return;
        std.mem.copyForwards(u8, self.text.items[start..], self.text.items[end..]);
        self.text.shrinkRetainingCapacity(self.text.items.len - (end - start));
    }

    fn previousCodepoint(text: []const u8, at: usize) usize {
        if (at == 0) return 0;
        var result = at - 1;
        while (result > 0 and (text[result] & 0xc0) == 0x80) result -= 1;
        return result;
    }

    fn nextCodepoint(text: []const u8, at: usize) usize {
        if (at >= text.len) return text.len;
        return @min(text.len, at + (std.unicode.utf8ByteSequenceLength(text[at]) catch 1));
    }
};

// ─── 单元测试（std.testing.allocator；节点渲染侧不可测，见文件头说明）──────

test "palette: empty query lists the full catalog, filter matches name prefix case-insensitively" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);

    palette.open();
    try std.testing.expect(palette.isOpen());
    try std.testing.expectEqual(builtin.catalog.len, palette.matchCount());

    try std.testing.expectEqual(TextResult.filtered, palette.handleChar(std.testing.allocator, "TH"));
    try std.testing.expectEqual(@as(usize, 1), palette.matchCount());
    try std.testing.expectEqualStrings("@theme", palette.matchAt(0).name);

    // 大小写不敏感 + 多字符输入（IME/粘贴一次到位）。
    palette.open();
    try std.testing.expectEqual(TextResult.filtered, palette.handleChar(std.testing.allocator, "tS"));
    try std.testing.expectEqualStrings("@ts", palette.matchAt(0).name);

    // 过滤串比命令名长（带参数）依旧匹配。
    palette.open();
    try std.testing.expectEqual(TextResult.filtered, palette.handleChar(std.testing.allocator, "theme dark-pro"));
    try std.testing.expectEqual(@as(usize, 1), palette.matchCount());
    try std.testing.expectEqualStrings("@theme", palette.matchAt(0).name);
}

test "palette: arrow keys move selection with wraparound cycling" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);

    palette.open();
    try std.testing.expectEqual(@as(usize, 0), palette.selected);
    try std.testing.expectEqual(KeyResult.none, palette.handleKey(std.testing.allocator, .down));
    try std.testing.expectEqual(@as(usize, 1), palette.selected);
    // 往回上移 → 0。
    try std.testing.expectEqual(KeyResult.none, palette.handleKey(std.testing.allocator, .up));
    try std.testing.expectEqual(@as(usize, 0), palette.selected);
    // 0 上移 → 环绕到最后一项。
    try std.testing.expectEqual(KeyResult.none, palette.handleKey(std.testing.allocator, .up));
    try std.testing.expectEqual(palette.matchCount() - 1, palette.selected);
    // 最后一项下移 → 环绕回 0。
    try std.testing.expectEqual(KeyResult.none, palette.handleKey(std.testing.allocator, .down));
    try std.testing.expectEqual(@as(usize, 0), palette.selected);
}

test "palette: window scrolls so the selected row stays visible" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);

    palette.open();
    try std.testing.expect(palette.matchCount() > max_visible_rows);
    // 选中压到窗口末行之外 → 窗口下移使其可见。
    palette.selected = max_visible_rows;
    palette.ensureWindow();
    const window = palette.visibleWindow();
    try std.testing.expectEqual(@as(usize, 1), window.first);
    try std.testing.expectEqual(max_visible_rows, window.count);
    try std.testing.expectEqual(@as(usize, max_visible_rows - 1), window.selected_offset.?);
    // 往回选 → 窗口跟着上移。
    palette.selected = 0;
    palette.ensureWindow();
    try std.testing.expectEqual(@as(usize, 0), palette.visibleWindow().first);
}

test "palette: empty result set keeps state safe and returns null adopt text" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);

    palette.open();
    try std.testing.expectEqual(TextResult.filtered, palette.handleChar(std.testing.allocator, "zzz"));
    try std.testing.expectEqual(@as(usize, 0), palette.matchCount());
    try std.testing.expect(palette.selectedEntry() == null);
    try std.testing.expect(palette.adoptText(std.testing.allocator) == null);
    // 空结果时 ↑↓ 不动、↵/→ 关面板不发送。
    try std.testing.expectEqual(KeyResult.none, palette.handleKey(std.testing.allocator, .down));
    try std.testing.expectEqual(KeyResult.close, palette.handleKey(std.testing.allocator, .execute));
    try std.testing.expect(!palette.isOpen());
    try std.testing.expect(palette.adoptedText() == null);
    // 可视窗口为空。
    try std.testing.expectEqual(@as(usize, 0), palette.visibleWindow().count);
}

test "palette: adopt preserves arguments typed past the command name" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);

    palette.open();
    try std.testing.expectEqual(TextResult.filtered, palette.handleChar(std.testing.allocator, "theme dark"));
    try std.testing.expectEqual(KeyResult.execute, palette.handleKey(std.testing.allocator, .execute));
    try std.testing.expectEqualStrings("@theme dark", palette.adoptedText().?);

    // 前缀补全：只敲 “th” 时采纳完整命令名。
    palette.open();
    try std.testing.expectEqual(TextResult.filtered, palette.handleChar(std.testing.allocator, "th"));
    try std.testing.expectEqual(KeyResult.adopt, palette.handleKey(std.testing.allocator, .adopt));
    try std.testing.expectEqualStrings("@theme", palette.adoptedText().?);
}

test "palette: @@ escape closes the panel for a literal at" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);

    palette.open();
    try std.testing.expectEqual(TextResult.escape_at, palette.handleChar(std.testing.allocator, "@"));
    try std.testing.expect(!palette.isOpen());
    // 面板关闭后文本不再进入过滤串。
    try std.testing.expectEqual(TextResult.none, palette.handleChar(std.testing.allocator, "x"));
}

test "palette: backspace shortens the query and closes the panel when empty" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);

    palette.open();
    try std.testing.expectEqual(TextResult.filtered, palette.handleChar(std.testing.allocator, "th"));
    try std.testing.expectEqual(KeyResult.none, palette.handleKey(std.testing.allocator, .backspace));
    try std.testing.expectEqualStrings("t", palette.query.items);
    try std.testing.expect(palette.isOpen());
    try std.testing.expectEqual(KeyResult.close, palette.handleKey(std.testing.allocator, .backspace));
    try std.testing.expect(!palette.isOpen());
    // 已空时再退格：仍然只是关闭。
    palette.open();
    try std.testing.expectEqual(KeyResult.close, palette.handleKey(std.testing.allocator, .backspace));
    try std.testing.expect(!palette.isOpen());
}

test "palette: refilter keeps the selection sticky on a still-matching command" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);

    palette.open();
    // 全量列表里选中 @sync（目录序靠后）。
    while (!std.mem.eql(u8, palette.selectedEntry().?.name, "@sync")) {
        _ = palette.handleKey(std.testing.allocator, .down);
    }
    try std.testing.expectEqual(TextResult.filtered, palette.handleChar(std.testing.allocator, "sy"));
    // “sy” 之后 @sync 仍匹配 → 粘滞保持选中。
    try std.testing.expectEqualStrings("@sync", palette.selectedEntry().?.name);
}

test "line tracker: return clears the line, printable input blocks the trigger" {
    var tracker: LineTracker = .{};
    defer tracker.deinit(std.testing.allocator);

    try std.testing.expect(tracker.atLineStart());
    tracker.record(std.testing.allocator, "ls -l");
    try std.testing.expect(!tracker.atLineStart());
    tracker.record(std.testing.allocator, "\r");
    try std.testing.expect(tracker.atLineStart());
    tracker.record(std.testing.allocator, "@theme");
    try std.testing.expect(!tracker.atLineStart());
    // 多行粘贴：\r 恢复“空行”。
    tracker.record(std.testing.allocator, "echo hi\r\necho bye\r");
    try std.testing.expect(tracker.atLineStart());
}

test "line tracker: history recall, tab completion and unknown sequences block the trigger" {
    var tracker: LineTracker = .{};
    defer tracker.deinit(std.testing.allocator);

    tracker.record(std.testing.allocator, "\x1b[A");
    try std.testing.expect(!tracker.atLineStart());
    tracker.clearLine();
    tracker.record(std.testing.allocator, "\t");
    try std.testing.expect(!tracker.atLineStart());
    tracker.clearLine();
    tracker.record(std.testing.allocator, "\x1b[3~");
    try std.testing.expect(!tracker.atLineStart());
    tracker.clearLine();
    tracker.record(std.testing.allocator, "\x1b");
    try std.testing.expect(!tracker.atLineStart());
}

test "line tracker: cursor moves and scrollback preserve tracked content, backspace pops a codepoint" {
    var tracker: LineTracker = .{};
    defer tracker.deinit(std.testing.allocator);

    tracker.record(std.testing.allocator, "echo");
    tracker.record(std.testing.allocator, "\x1b[D");
    tracker.record(std.testing.allocator, "\x1b[H");
    tracker.record(std.testing.allocator, "\x1b[5~");
    try std.testing.expect(!tracker.atLineStart());
    try std.testing.expectEqualStrings("echo", tracker.content.items);

    tracker.clearLine();
    tracker.record(std.testing.allocator, "ab你");
    try std.testing.expectEqualStrings("ab你", tracker.content.items);
    tracker.record(std.testing.allocator, "\x7f");
    try std.testing.expectEqualStrings("ab", tracker.content.items);
    tracker.record(std.testing.allocator, "\x7f");
    tracker.record(std.testing.allocator, "\x7f");
    try std.testing.expect(tracker.atLineStart());
}

test "line tracker: line-kill control bytes clear, other control bytes mark unknown" {
    var tracker: LineTracker = .{};
    defer tracker.deinit(std.testing.allocator);

    tracker.record(std.testing.allocator, "long line");
    tracker.record(std.testing.allocator, "\x15"); // ^U kill line
    try std.testing.expect(tracker.atLineStart());

    tracker.record(std.testing.allocator, "long line");
    tracker.record(std.testing.allocator, "\x01"); // ^A 行首（内容不变）→ 保守 unknown
    try std.testing.expect(!tracker.atLineStart());
    tracker.record(std.testing.allocator, "\r");
    try std.testing.expect(tracker.atLineStart());
}

test "palette: query state machine handles multi-byte filter text" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);

    palette.open();
    // CJK 字符进入过滤串（匹配不到命令是预期行为，不得破坏状态机）。
    try std.testing.expectEqual(TextResult.filtered, palette.handleChar(std.testing.allocator, "你"));
    try std.testing.expectEqualStrings("你", palette.query.items);
    try std.testing.expectEqual(@as(usize, 0), palette.matchCount());
    // 退格弹出唯一码点 → 过滤串为空 → 面板随之关闭（退格到空即关闭）。
    try std.testing.expectEqual(KeyResult.close, palette.handleKey(std.testing.allocator, .backspace));
    try std.testing.expectEqual(@as(usize, 0), palette.query.items.len);
    try std.testing.expect(!palette.isOpen());
}

test "palette: reopen drops old adopted text and command suffixes require a separator" {
    var palette: Palette = .{};
    defer palette.deinit(std.testing.allocator);
    palette.open();
    _ = palette.handleChar(std.testing.allocator, "new");
    try std.testing.expectEqual(KeyResult.execute, palette.handleKey(std.testing.allocator, .execute));
    try std.testing.expectEqualStrings("@new", palette.adoptedText().?);
    palette.open();
    try std.testing.expect(palette.adoptedText() == null);
    _ = palette.handleChar(std.testing.allocator, "newest");
    try std.testing.expectEqual(@as(usize, 0), palette.matchCount());
}

test "local editor keeps required parameters local until a valid Enter" {
    var editor: Editor = .{};
    defer editor.deinit(std.testing.allocator);
    try editor.adopt(std.testing.allocator, "@grp");
    try std.testing.expectEqual(Editor.Result.invalid, editor.key(.execute));
    try std.testing.expect(editor.active);
    try std.testing.expect(try editor.insert(std.testing.allocator, " 生产"));
    try std.testing.expectEqual(Editor.Result.execute, editor.key(.execute));
    try std.testing.expectEqualStrings("生产", builtin.parse(editor.text.items).group);
    try std.testing.expectEqual(Editor.Result.cancel, editor.key(.escape));
    try std.testing.expect(!editor.active);
}

test "local editor supports UTF-8 caret editing and never accepts control sequences" {
    var editor: Editor = .{};
    defer editor.deinit(std.testing.allocator);
    try editor.adopt(std.testing.allocator, "@ai 你好");
    _ = editor.key(.left);
    _ = editor.key(.backspace);
    try std.testing.expectEqualStrings("@ai 好", editor.text.items);
    try std.testing.expect(try editor.insert(std.testing.allocator, "很"));
    try std.testing.expectEqualStrings("@ai 很好", editor.text.items);
    try std.testing.expect(!try editor.insert(std.testing.allocator, "\r@up"));
    try std.testing.expect(!try editor.insert(std.testing.allocator, "\x1b[200~"));
    try std.testing.expectEqualStrings("@ai 很好", editor.text.items);
    _ = editor.key(.home);
    _ = editor.key(.delete);
    try std.testing.expectEqualStrings("ai 很好", editor.text.items);
    try std.testing.expectEqual(Editor.Result.invalid, editor.key(.execute));
}

test "partial remote line kills cannot falsely start a local command" {
    var tracker: LineTracker = .{};
    defer tracker.deinit(std.testing.allocator);
    tracker.record(std.testing.allocator, "echo file");
    tracker.record(std.testing.allocator, "\x17");
    try std.testing.expect(!tracker.atLineStart());
    tracker.clearLine();
    tracker.record(std.testing.allocator, "echo file\x1b[D\x7f");
    try std.testing.expect(!tracker.atLineStart());
}

test "local command catalog excludes remote transfer and forwarding but preserves themes" {
    var palette: Palette = .{ .local_session = true };
    defer palette.deinit(std.testing.allocator);
    palette.open();
    try std.testing.expectEqual(builtin.catalog.len - 3, palette.matchCount());
    for (0..palette.matchCount()) |index| {
        const entry = palette.matchAt(index);
        try std.testing.expect(!std.mem.eql(u8, entry.name, "@up"));
        try std.testing.expect(!std.mem.eql(u8, entry.name, "@dl"));
        try std.testing.expect(!std.mem.eql(u8, entry.name, "@socks"));
    }
    _ = palette.handleChar(std.testing.allocator, "theme");
    try std.testing.expectEqualStrings("@theme", palette.matchAt(0).name);
}
