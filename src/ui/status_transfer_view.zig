//! One fixed-width current-session summary; the owner is captured by its host.
const std = @import("std");
const ui = @import("ui");
const S = @import("status_transfer_styles.zig");
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    row: *ui.Node,
    name: *ui.Node,
    percent: *ui.Node,
    counts: *ui.Node,
    fill: *ui.Node,
    track: *ui.Node,
    chevron: *ui.Node,
    upload: *ui.Node,
    download: *ui.Node,
    idle_icon: *ui.Node,
    hover: *ui.Signal(?S.ButtonStyle),
    colors: S.theme.Colors,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, on_click: anytype) !*View {
        const self = try scope.createState(View, undefined);
        const hover = try scope.createSignal(?S.ButtonStyle, S.hover());
        const root = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "查看当前会话传输任务", .base_style = S.button(), .hover_style = hover, .on_click = on_click }).mount(scope, cx);
        root.meta.ownership.meta.test_id = "status.transfer";
        const row = try ui.box(cx, S.row(), .{});
        try root.appendChild(cx.allocator, row);
        const upload = try ui.iconTint(cx, ui.icons.get("arrow-up-right").?, S.theme.current().accent, S.icon());
        const download = try ui.iconTint(cx, ui.icons.get("arrow-down-left").?, S.theme.current().accent, S.icon());
        const idle_icon = try ui.iconTint(cx, ui.icons.arrow_down_up, S.theme.current().fg_2, S.icon());
        try row.appendChild(cx.allocator, idle_icon);
        try row.appendChild(cx.allocator, upload);
        try row.appendChild(cx.allocator, download);
        const name = try ui.text(cx, "传输 · 空闲", S.text(true));
        name.setStyleInline(cx.allocator, S.label(104));
        name.meta.ownership.meta.test_id = "status.transfer.name";
        try row.appendChild(cx.allocator, name);
        const percent = try ui.text(cx, "", S.text(false));
        percent.setStyleInline(cx.allocator, S.label(44));
        try row.appendChild(cx.allocator, percent);
        const counts = try ui.text(cx, "", S.text(false));
        counts.setStyleInline(cx.allocator, S.label(46));
        try row.appendChild(cx.allocator, counts);
        const chevron = try ui.iconTint(cx, ui.icons.chevron_up, S.theme.current().fg_2, S.icon());
        chevron.setDisplay(.none);
        try row.appendChild(cx.allocator, chevron);
        const track = try ui.box(cx, S.track(), .{});
        const fill = try ui.box(cx, S.fill(0), .{});
        try track.appendChild(cx.allocator, fill);
        try root.appendChild(cx.allocator, track);
        self.* = .{ .cx = cx, .root = root, .row = row, .name = name, .percent = percent, .counts = counts, .fill = fill, .track = track, .chevron = chevron, .upload = upload, .download = download, .idle_icon = idle_icon, .hover = hover, .colors = S.theme.current() };
        return self;
    }
    pub fn update(self: *View, name: []const u8, pct: []const u8, counts: []const u8, fraction: f32, upload: bool) void {
        const colors = S.theme.current();
        if (!std.meta.eql(colors, self.colors)) {
            self.root.setBackground(ui.Color.TRANSPARENT);
            self.name.setTextColor(colors.fg_1);
            self.percent.setTextColor(colors.fg_2);
            self.counts.setTextColor(colors.fg_2);
            self.fill.setBackground(colors.accent);
            self.track.setBackground(colors.well);
            _ = self.chevron.setTint(colors.fg_2);
            _ = self.upload.setTint(colors.accent);
            _ = self.download.setTint(colors.accent);
            self.hover.set(S.hover());
            self.colors = colors;
        }
        for ([_]*ui.Node{ self.name, self.percent, self.counts }, [_][]const u8{ std.fs.path.basename(name), pct, counts }) |node, value| {
            if (!std.mem.eql(u8, node.getText().?.content, value)) node.setTextContent(self.cx.allocator, value) catch {};
        }
        const idle = pct.len == 0 and counts.len == 0;
        self.root.setStyleInline(self.cx.allocator, .{ .width = if (idle) .{ .fit = .{} } else .{ .px = 264 } });
        self.row.setStyleInline(self.cx.allocator, if (idle) .{
            .position = .relative,
            .inset = .{},
            .width = .{ .fit = .{} },
            .height = .{ .px = 26 },
            .direction = .row,
            .align_items = .center,
            .gap = 6,
            .padding = .{ .left = 7, .right = 7 },
        } else S.row());
        self.name.setStyleInline(self.cx.allocator, .{ .width = if (idle) .{ .fit = .{} } else .{ .px = 104 } });
        self.track.setDisplay(if (idle) .none else .flex);
        self.percent.setDisplay(if (idle) .none else .flex);
        self.counts.setDisplay(if (idle) .none else .flex);
        self.name.setTextColor(if (idle) colors.fg_2 else colors.fg_1);
        _ = self.download.setTint(if (idle) colors.fg_2 else colors.accent);

        self.idle_icon.setDisplay(if (idle) .flex else .none);
        _ = self.idle_icon.setTint(colors.fg_2);
        self.upload.setDisplay(if (!idle and upload) .flex else .none);
        self.download.setDisplay(if (!idle and !upload) .flex else .none);
        self.root.setBackgroundRaw(ui.Color.TRANSPARENT);
        const width = 248 * std.math.clamp(fraction, 0, 1);
        if (self.fill.style.width.px != width) self.fill.setStyleInline(self.cx.allocator, S.fill(width));
    }
};
