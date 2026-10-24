//! One fixed-width current-session summary; the owner is captured by its host.
const std = @import("std");
const ui = @import("ui");
const S = @import("status_transfer_styles.zig");
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    name: *ui.Node,
    percent: *ui.Node,
    counts: *ui.Node,
    fill: *ui.Node,
    track: *ui.Node,
    chevron: *ui.Node,
    upload: *ui.Node,
    download: *ui.Node,
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
        try row.appendChild(cx.allocator, upload);
        try row.appendChild(cx.allocator, download);
        const name = try ui.text(cx, "暂无传输", S.text(true));
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
        try row.appendChild(cx.allocator, chevron);
        const track = try ui.box(cx, S.track(), .{});
        const fill = try ui.box(cx, S.fill(0), .{});
        try track.appendChild(cx.allocator, fill);
        try root.appendChild(cx.allocator, track);
        self.* = .{ .cx = cx, .root = root, .name = name, .percent = percent, .counts = counts, .fill = fill, .track = track, .chevron = chevron, .upload = upload, .download = download, .hover = hover, .colors = S.theme.current() };
        return self;
    }
    pub fn update(self: *View, name: []const u8, pct: []const u8, counts: []const u8, fraction: f32, upload: bool) void {
        const colors = S.theme.current();
        if (!std.meta.eql(colors, self.colors)) {
            self.root.setBackground(colors.surface_2);
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
        self.upload.setDisplay(if (upload) .flex else .none);
        self.download.setDisplay(if (upload) .none else .flex);
        const width = 248 * std.math.clamp(fraction, 0, 1);
        if (self.fill.style.width.px != width) self.fill.setStyleInline(self.cx.allocator, S.fill(width));
    }
};
