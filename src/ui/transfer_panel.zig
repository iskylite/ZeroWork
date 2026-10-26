//! Production upload/download/drop confirmation view. Original PNGs define the
//! presentation; fields and callbacks carry real session and transfer state.
//! Mount once, wire callbacks, then show(Data). Submitted JobSpec borrows panel
//! scratch storage for the synchronous callback only.

const std = @import("std");
const ui = @import("ui");
const transfer = @import("../transfer/manager.zig");

// ── 设计 token（值与 design_tokens.zig 一致，本地定义避免依赖 mockup 基建） ──

const T = @import("app_theme.zig");
const S = @import("transfer_styles.zig");
const identity = @import("../host/identity.zig");
fn alpha(color: ui.Color, value: u8) ui.Color {
    return color.withAlpha(value);
}

pub const Data = struct {
    pub const Mode = enum { upload, download };
    pub const Presentation = enum { command, drop };

    mode: Mode,
    owner: ?identity.SessionHandle = null,
    endpoint: []const u8 = "",
    available: bool = true,
    unavailable_reason: []const u8 = "",
    presentation: Presentation = .command,
    /// Dashed target is a drag-hover affordance, not persistent confirmation UI.
    drag_hover: bool = false,
    host_name: []const u8 = "",
    source_size: []const u8 = "",
    source_detail: []const u8 = "",
    link_text: []const u8 = "",
    remote_target: []const u8 = "",
    recent: []const RecentFile = &.{},
    /// 初始填充源文件输入框（show 时以 ", " 连接展示）。
    sources: []const []const u8 = &.{},
    remote_dir: []const u8 = "",
    local_dir: []const u8 = "",
    /// Ordinary SSH form accepts one remote source; file-card selections stay frozen.
    edit_remote_source: bool = false,
    /// This form must obtain its local directory from a matching picker receipt.
    require_directory_selection: bool = false,
    /// 下载模式重命名（upload 无 rename，组装时强制 null）。
    rename: []const u8 = "",
    /// 字段名与 JobSpec.resume_transfer 对齐（`resume` 在 Zig 0.17 是保留字，
    /// 不能用作字段名）。
    resume_transfer: bool = true,
    md5: bool = false,
    notify_complete: bool = true,
};

pub const RecentFile = struct {
    path: []const u8,
    icon: []const u8 = "📄",
    label: []const u8,
    detail: []const u8 = "",
};

pub const ValidationError = error{
    MissingSources,
    MissingRemoteDirectory,
    MissingLocalDirectory,
    InvalidRename,
};

/// Data → JobSpec 组装 + 校验（守卫与 transfer.Manager.enqueue 一致：
/// upload 必须有 remote_dir，download 必须有 local_dir，rename 仅单文件）。
/// 返回的 spec 借用 data 的切片内存，调用方需保证回调期间有效。
pub fn buildSpec(data: Data) ValidationError!transfer.JobSpec {
    if (data.sources.len == 0) return error.MissingSources;
    for (data.sources) |source| {
        if (source.len == 0 or std.mem.indexOfScalar(u8, source, 0) != null or std.mem.indexOfAny(u8, source, "\r\n") != null) return error.MissingSources;
    }
    switch (data.mode) {
        .upload => if (data.remote_dir.len == 0) return error.MissingRemoteDirectory,
        .download => {
            if (data.local_dir.len == 0) return error.MissingLocalDirectory;
            if (data.rename.len > 0 and (data.sources.len != 1 or
                std.mem.indexOfScalar(u8, data.rename, '/') != null or
                std.mem.indexOfScalar(u8, data.rename, '\\') != null or
                std.mem.indexOfScalar(u8, data.rename, 0) != null or
                !std.unicode.utf8ValidateSlice(data.rename) or
                std.mem.eql(u8, data.rename, ".") or std.mem.eql(u8, data.rename, ".."))) return error.InvalidRename;
        },
    }
    return switch (data.mode) {
        .upload => .{
            .session_id = if (data.owner) |owner| @backingInt(owner.session_id) else 0,
            .direction = .upload,
            .sources = data.sources,
            .remote_dir = data.remote_dir,
            .local_dir = data.local_dir,
            .rename = null, // upload 无 rename
            .resume_transfer = data.resume_transfer,
            .md5_check = data.md5,
            .notify_complete = data.notify_complete,
        },
        .download => .{
            .session_id = if (data.owner) |owner| @backingInt(owner.session_id) else 0,
            .direction = .download,
            .sources = data.sources,
            .remote_dir = data.remote_dir,
            .local_dir = data.local_dir,
            .rename = if (data.rename.len > 0) data.rename else null,
            .resume_transfer = data.resume_transfer,
            .md5_check = data.md5,
            .notify_complete = data.notify_complete,
        },
    };
}

/// 校验失败的用户可读提示（状态行红字）。
pub fn validationMessage(err: ValidationError) []const u8 {
    return switch (err) {
        error.MissingSources => "请先选择要传输的文件",
        error.MissingRemoteDirectory => "上传需要填写远程目录",
        error.MissingLocalDirectory => "下载需要填写保存目录",
        error.InvalidRename => "另存名称仅支持单个文件，不能包含路径分隔符",
    };
}

// ── 格式化（状态栏进度行用，独立 pub 便于复用与测试） ────────────────

/// 百分比：done/total → "68%"；total==0 → "--%"；done≥total → "100%"。
/// 整数截断（与 mockup 68% 一致），不做四舍五入。
pub fn formatPercent(buffer: []u8, done: u64, total: u64) []const u8 {
    if (total == 0) return std.fmt.bufPrint(buffer, "--%", .{}) catch buffer[0..0];
    const pct: u64 = if (done >= total) 100 else done * 100 / total;
    return std.fmt.bufPrint(buffer, "{d}%", .{pct}) catch buffer[0..0];
}

/// 速度自适应：<1 MiB → "KB/s"（整数），<1 GiB → "MB/s"（1 位小数），否则 GB/s。
pub fn formatSpeed(buffer: []u8, speed_bps: u64) []const u8 {
    const bytes_f: f64 = @floatFromInt(speed_bps);
    const mib = bytes_f / (1024.0 * 1024.0);
    if (mib >= 1024.0) {
        return std.fmt.bufPrint(buffer, "{d:.1} GB/s", .{mib / 1024.0}) catch buffer[0..0];
    }
    if (mib >= 1.0) {
        return std.fmt.bufPrint(buffer, "{d:.1} MB/s", .{mib}) catch buffer[0..0];
    }
    return std.fmt.bufPrint(buffer, "{d:.0} KB/s", .{bytes_f / 1024.0}) catch buffer[0..0];
}

// ── 状态栏进度行（复刻 mockup-main 右侧：🚀 + 文件名 + 110×4 进度条 + % + 速度） ──

/// 进度条填充宽（f64 中间量避免 done×110 溢出 u64）。
fn progressFillWidth(done: u64, total: u64) f32 {
    const bar_w: f64 = 110.0;
    if (total == 0) return 0;
    if (done >= total) return @floatFromInt(110);
    const w = @as(f64, @floatFromInt(done)) * bar_w / @as(f64, @floatFromInt(total));
    return @floatCast(w);
}

fn progressPctColor(state: transfer.State) ui.Color {
    return switch (state) {
        .failed, .cancelled => T.current().danger_ink,
        else => T.current().ok,
    };
}

/// 纯函数：每次调用建新节点（状态栏重建即弃，无需信号/脏标记）。
pub fn progressRow(cx: *ui.Cx, name: []const u8, done: u64, total: u64, speed_bps: u64, state: transfer.State) !*ui.Node {
    const row_node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .flex_shrink = 0,
    }, .{});
    try row_node.appendChild(cx.allocator, try txt(cx, "🚀", 11, 400, T.current().fg_2));
    try row_node.appendChild(cx.allocator, try txt(cx, name, 11, 400, T.current().fg_2));
    // 110×4 圆角进度条：底 rgba(0,0,0,.08)，填充渐变 grn→#34D399。
    const pbar = try ui.box(cx, .{
        .width = .{ .px = 110 },
        .height = .{ .px = 4 },
        .background = ui.Color.rgba(0, 0, 0, 20),
        .border = .{ .width = 0, .color = T.current().border, .radius = 2 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try pbar.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = progressFillWidth(done, total) },
        .height = .fill(),
        .gradient = .{ .from = T.current().ok, .to = T.current().ok, .direction = .horizontal },
        .border = .{ .width = 0, .color = T.current().ok, .radius = 2 },
    }, .{}));
    try row_node.appendChild(cx.allocator, pbar);
    var pct_buf: [16]u8 = undefined;
    try row_node.appendChild(cx.allocator, try txt(cx, formatPercent(&pct_buf, done, total), 11, 500, progressPctColor(state)));
    var speed_buf: [24]u8 = undefined;
    try row_node.appendChild(cx.allocator, try txt(cx, formatSpeed(&speed_buf, speed_bps), 11, 400, alpha(T.current().fg_2, 140)));
    return row_node;
}

// ── 统一传输面板 ─────────────────────────────────────────────────────

pub const max_sources = 64;
const Scratch = struct {
    sources: [65536]u8 = undefined,
    remote: [4096]u8 = undefined,
    local: [4096]u8 = undefined,
    rename: [1024]u8 = undefined,
    items: [max_sources][]const u8 = undefined,
};
pub const DirectoryTicket = struct {
    owner: identity.SessionHandle,
    source_revision: u64,
    source_hash: u64,
};
const PathField = struct {
    row: *ui.Node,
    input: ui.widgets.input.InputResult,
};
const SourceControl = struct {
    panel: *Panel,
    index: usize,
    revision: u64,
    fn replace(self: *SourceControl) void {
        const p = self.panel;
        if (p.source_revision != self.revision) return;
        if (p.on_replace_source) |call| call(p.submit_ctx, self.index, self.revision) else if (self.index == 0) {
            if (p.on_browse) |call| call(p.submit_ctx);
        }
    }
    fn remove(self: *SourceControl) void {
        self.panel.removeSource(self.index, self.revision) catch |err| self.panel.setError(@errorName(err));
    }
};
pub const Panel = struct {
    cx: *ui.Cx = undefined,
    scope: *ui.Scope = undefined,
    root: *ui.Node = undefined,
    card: *ui.Node = undefined,
    body: *ui.Node = undefined,
    header: *ui.Node = undefined,
    viewport: ?ui.widgets.ScrollAreaResult = null,
    pane_anchor_id: ?u32 = null,
    open: *ui.Signal(bool) = undefined,
    disabled: *ui.Signal(bool) = undefined,
    sources_sig: *ui.Signal([]const u8) = undefined,
    remote_dir_sig: *ui.Signal([]const u8) = undefined,
    local_dir_sig: *ui.Signal([]const u8) = undefined,
    rename_sig: *ui.Signal([]const u8) = undefined,
    source_rows: *ui.Node = undefined,
    download_source_row: *ui.Node = undefined,
    local_input: ui.widgets.input.InputResult = undefined,
    local_input_client: ?ui.TextInputClient = null,
    directory_selection: *ui.Signal([]const u8) = undefined,
    directory_source_revision: u64 = 0,
    directory_source_hash: u64 = 0,
    edit_remote_source: bool = false,
    require_directory_selection: bool = false,
    source_scope: ?*ui.Scope = null,
    source_summary: *ui.Node = undefined,
    source_hint: *ui.Node = undefined,
    remote_row: *ui.Node = undefined,
    local_row: *ui.Node = undefined,
    rename_row: *ui.Node = undefined,
    remote_hint: *ui.Node = undefined,
    identity_box: *ui.Node = undefined,
    identity_name: *ui.Node = undefined,
    identity_endpoint: *ui.Node = undefined,
    identity_route: *ui.Node = undefined,
    title: *ui.Node = undefined,
    icon: *ui.Node = undefined,
    download_icon: *ui.Node = undefined,
    footer: *ui.Node = undefined,
    primary: *ui.Node = undefined,
    primary_style: *ui.Signal(ui.BoxStyle) = undefined,
    option_style: *ui.Signal(ui.BoxStyle) = undefined,
    primary_label: *ui.Signal([]const u8) = undefined,
    status_row: *ui.Node = undefined,
    status_text: *ui.Node = undefined,
    resume_label: *ui.Signal([]const u8) = undefined,
    md5_label: *ui.Signal([]const u8) = undefined,
    notify_label: *ui.Signal([]const u8) = undefined,
    mode: Data.Mode = .upload,
    drop: bool = false,
    drop_target_file: bool = false,
    captured_owner: ?identity.SessionHandle = null,
    resume_transfer: bool = true,
    md5: bool = false,
    notify_complete: bool = true,
    available: bool = true,
    unavailable_reason: *ui.Signal([]const u8) = undefined,
    source_size: *ui.Signal([]const u8) = undefined,
    source_revision: u64 = 0,
    source_hash: u64 = 0,
    sources_dirty: bool = false,
    source_count: usize = 0,
    showing: bool = false,
    scratch: Scratch = .{},
    paint_colors: T.Colors = undefined,
    on_submit: ?*const fn (*anyopaque, transfer.JobSpec) void = null,
    on_submit_frozen: ?*const fn (*anyopaque, identity.SessionHandle, transfer.JobSpec) anyerror!void = null,
    submit_ctx: *anyopaque = undefined,
    on_cancel: ?*const fn (*anyopaque) void = null,
    on_browse: ?*const fn (*anyopaque) void = null,
    on_local_directory: ?*const fn (*anyopaque) void = null,
    on_replace_source: ?*const fn (*anyopaque, usize, u64) void = null,
    on_sources_changed: ?*const fn (*anyopaque, u64) void = null,

    /// Returns an attachment node for legacy callers. Modal owns its portal;
    /// when portaled this is an inert anchor, never the already-mounted overlay.
    pub fn mount(self: *Panel, cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
        self.* = .{ .cx = cx, .scope = scope, .paint_colors = T.current() };
        self.open = try scope.createSignal(bool, false);
        self.disabled = try scope.createSignal(bool, true);
        self.sources_sig = try scope.createText("", .{});
        self.remote_dir_sig = try scope.createText("", .{});
        self.local_dir_sig = try scope.createText("", .{});
        self.directory_selection = try scope.createText("", .{});
        self.rename_sig = try scope.createText("", .{});
        self.source_size = try scope.createText("", .{});
        self.unavailable_reason = try scope.createText("", .{});
        self.primary_style = try scope.createSignal(ui.BoxStyle, S.confirmationPrimary());
        self.option_style = try scope.createSignal(ui.BoxStyle, S.option());
        self.primary_label = try scope.createText("开始上传", .{});
        self.resume_label = try scope.createText("", .{});
        self.md5_label = try scope.createText("", .{});
        self.notify_label = try scope.createText("", .{});
        const modal = try ui.widgets.Modal(.{ .open = self.open, .width = @as(f32, 520), .max_height = @as(f32, 10000), .close_on_overlay = false, .overlay_color = ui.Color.TRANSPARENT, .on_open_change = cx.on(Panel, self, openChanged) }).mount(scope, cx);
        self.root = modal.overlay;
        self.card = modal.dialog;
        self.body = modal.body;
        self.root.meta.ownership.meta.test_id = "transfer.confirmation.overlay";
        self.card.meta.ownership.meta.test_id = "transfer.confirmation";
        self.card.setStyleInline(cx.allocator, S.confirmation(460));
        modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = ui.Padding.all(0), .min_height = 0 });
        self.header = try ui.box(cx, S.confirmationHeader(), .{});
        try modal.body.appendChild(cx.allocator, self.header);
        self.icon = try ui.iconTint(cx, ui.icons.upload, T.current().accent, S.icon(18));
        try self.header.appendChild(cx.allocator, self.icon);
        self.download_icon = try ui.iconTint(cx, ui.icons.download, T.current().accent, S.icon(18));
        self.download_icon.setDisplay(.none);
        try self.header.appendChild(cx.allocator, self.download_icon);
        self.title = try self.text(self.header, "上传文件", 13, 700, false);
        self.title.setStyleInline(cx.allocator, S.flexibleLabel());
        _ = try self.iconButton(self.header, scope, "关闭传输确认", "transfer.confirmation.close", "x", close);
        const inner = try ui.box(cx, S.confirmationInner(), .{});
        try modal.body.appendChild(cx.allocator, inner);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, S.viewport());
        scroll.content.setStyleInline(cx.allocator, S.confirmationStack());
        self.viewport = scroll;
        try inner.appendChild(cx.allocator, scroll.container);
        self.identity_box = try ui.box(cx, S.confirmationIdentity(), .{});
        try scroll.content.appendChild(cx.allocator, self.identity_box);
        self.identity_name = try self.text(self.identity_box, "", 12, 500, false);
        self.identity_endpoint = try self.text(self.identity_box, "", 10.5, 400, true);
        self.identity_route = try self.text(self.identity_box, "", 10.5, 400, true);
        self.source_rows = try ui.box(cx, S.confirmationSources(), .{});
        try scroll.content.appendChild(cx.allocator, self.source_rows);
        const source_field = try self.field(scroll.content, "远程文件", "file", self.sources_sig, "输入远端文件或目录", null);
        self.download_source_row = source_field.row;
        self.download_source_row.setDisplay(.none);
        source_field.input.input_container.meta.ownership.meta.test_id = "transfer.remote_source";
        self.source_hint = try self.text(scroll.content, "", 10.5, 400, true);
        self.source_hint.setStyleInline(cx.allocator, S.confirmationHint());
        self.remote_row = (try self.field(scroll.content, "远程目录", "folder", self.remote_dir_sig, "", null)).row;
        self.remote_row.meta.ownership.meta.test_id = "transfer.remote_directory";
        self.remote_hint = try self.text(scroll.content, "跟随打开时的终端目录", 10.5, 400, true);
        self.remote_hint.setStyleInline(cx.allocator, S.confirmationHint());
        const local_field = try self.field(scroll.content, "保存到", "folder", self.local_dir_sig, "选择本地目录", directory);
        self.local_row = local_field.row;
        self.local_input = local_field.input;
        self.local_input_client = local_field.input.input_container.behavior.interaction.text_input_client;
        self.local_input.input_container.meta.ownership.meta.test_id = "transfer.local_directory.input";
        self.local_row.meta.ownership.meta.test_id = "transfer.local_directory";
        self.rename_row = (try self.field(scroll.content, "另存名称", "file", self.rename_sig, "保留原名", null)).row;
        self.rename_row.meta.ownership.meta.test_id = "transfer.rename";
        self.source_summary = try self.text(scroll.content, "", 10.5, 400, true);
        self.source_summary.setStyleInline(cx.allocator, S.confirmationHint());
        const chips = try ui.box(cx, S.row(24, 6), .{});
        try scroll.content.appendChild(cx.allocator, chips);
        const resume_button = try ui.widgets.Button(.{ .label = self.resume_label, .variant = .ghost, .base_style = self.option_style, .on_click = cx.on(Panel, self, toggleResume) }).mount(scope, cx);
        try chips.appendChild(cx.allocator, resume_button);
        const md5_button = try ui.widgets.Button(.{ .label = self.md5_label, .variant = .ghost, .base_style = self.option_style, .on_click = cx.on(Panel, self, toggleMd5) }).mount(scope, cx);
        try chips.appendChild(cx.allocator, md5_button);
        const notify_button = try ui.widgets.Button(.{ .label = self.notify_label, .variant = .ghost, .base_style = self.option_style, .on_click = cx.on(Panel, self, toggleNotify) }).mount(scope, cx);
        notify_button.meta.ownership.meta.test_id = "transfer.confirmation.notify";
        try chips.appendChild(cx.allocator, notify_button);
        self.status_row = try ui.box(cx, S.errorLine(), .{});
        try inner.appendChild(cx.allocator, self.status_row);
        self.status_text = try self.text(self.status_row, "", 11, 400, true);
        self.status_text.setTextColor(T.current().danger_ink);
        self.status_row.setDisplay(.none);
        try inner.appendChild(cx.allocator, try ui.box(cx, S.gap(10), .{}));
        self.footer = try ui.box(cx, S.row(34, 8), .{});
        self.footer.setStyleInline(cx.allocator, .{ .justify = .end });
        try inner.appendChild(cx.allocator, self.footer);
        _ = try self.iconButton(self.footer, scope, "取消传输", "transfer.confirmation.cancel", "x", close);
        self.primary = try ui.widgets.Button(.{ .label = self.primary_label, .variant = .primary, .disabled = self.disabled, .base_style = self.primary_style, .on_click = cx.on(Panel, self, handleSubmit) }).mount(scope, cx);
        self.primary.meta.ownership.meta.test_id = "transfer.confirmation.submit";
        try self.footer.appendChild(cx.allocator, self.primary);
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(Panel, self, cleanup);
        try scope.createEffect(self, fieldsChanged);
        if (!modal.portaled) return modal.overlay;
        return ui.box(cx, .{ .display = .none }, .{});
    }
    fn cleanup(self: *Panel) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn text(self: *Panel, parent: *ui.Node, value: []const u8, size: f32, weight: u16, secondary: bool) !*ui.Node {
        const node = try ui.text(self.cx, "", S.text(size, weight, secondary));
        try node.setTextContent(self.cx.allocator, value);
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn iconButton(self: *Panel, parent: *ui.Node, scope: *ui.Scope, label: []const u8, test_id: []const u8, icon: []const u8, comptime callback: fn (*Panel) void) !*ui.Node {
        const node = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get(icon), .icon_size = 16, .a11y_label = label, .base_style = S.action(22), .on_click = self.cx.on(Panel, self, callback) }).mount(scope, self.cx);
        node.meta.ownership.meta.test_id = test_id;
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn field(self: *Panel, parent: *ui.Node, label: []const u8, icon: []const u8, signal: *ui.Signal([]const u8), placeholder: []const u8, comptime callback: ?fn (*Panel) void) !PathField {
        const row = try ui.box(self.cx, S.pathRow(), .{});
        try parent.appendChild(self.cx.allocator, row);
        try row.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get(icon).?, T.current().fg_2, S.icon(16)));
        const caption = try self.text(row, label, 10.5, 400, true);
        caption.setStyleInline(self.cx.allocator, S.label(72));
        const result = try ui.widgets.Input(.{ .value = signal, .embedded = true, .placeholder = placeholder, .placeholder_color = T.current().fg_2, .on_change = if (signal == self.sources_sig) self.cx.on(Panel, self, sourceEdited) else self.cx.on(Panel, self, fieldEdited) }).mountResult(self.scope, self.cx);
        result.state.font_size = 11;
        result.state.line_height = S.path_line_height;
        result.state.dirty = true;
        if (result.state.text_display_node) |node| if (node.getText()) |value| {
            var next = value;
            next.font_size = 11;
            next.line_height = S.path_line_height / 11.0;
            next.use_monospace_font = true;
            node.setText(next);
        };
        result.node.setStyleInline(self.cx.allocator, S.flexibleLabel());
        try row.appendChild(self.cx.allocator, result.node);
        if (callback) |call| _ = try self.iconButton(row, self.scope, "选择本地保存目录", "transfer.directory.choose", "folder-open", call);
        return .{ .row = row, .input = result };
    }
    pub fn show(self: *Panel, data: Data) void {
        self.showing = true;
        defer self.showing = false;
        self.mode = data.mode;
        self.edit_remote_source = data.mode == .download and data.edit_remote_source;
        self.require_directory_selection = data.mode == .download and data.require_directory_selection;
        self.directory_selection.set("");
        self.local_input.state.readonly = self.require_directory_selection;
        self.local_input.input_container.behavior.interaction.text_input_client = if (self.require_directory_selection) null else self.local_input_client;
        if (self.local_input.input_container.behavior.interaction.a11y) |*a11y| a11y.readonly = self.require_directory_selection;
        self.drop = data.presentation == .drop;
        self.drop_target_file = self.drop and data.remote_target.len > 0;
        self.captured_owner = data.owner;
        self.available = data.available;
        self.unavailable_reason.set(data.unavailable_reason);
        self.source_size.set(data.source_size);
        self.resume_transfer = data.resume_transfer;
        self.md5 = data.md5;
        self.notify_complete = data.notify_complete;
        self.source_revision +%= 1;
        const joined = std.mem.join(self.cx.allocator, "\n", data.sources) catch {
            self.setError("无法读取所选文件");
            return;
        };
        defer self.cx.allocator.free(joined);
        self.source_hash = std.hash.Wyhash.hash(0, joined);
        self.sources_sig.set(joined);
        self.remote_dir_sig.set(if (self.drop and data.remote_target.len > 0) data.remote_target else data.remote_dir);
        // The initial suggestion is visible, but only applyDirectorySelection
        // records the matching picker receipt required by spec().
        self.local_dir_sig.set(data.local_dir);
        self.rename_sig.set(data.rename);
        const upload = data.mode == .upload;
        self.title.setTextContent(self.cx.allocator, if (self.drop) "确认拖放上传" else if (upload) "上传文件" else "下载文件") catch {};
        self.icon.setDisplay(if (upload) .flex else .none);
        self.download_icon.setDisplay(if (upload) .none else .flex);
        self.primary_label.set(if (upload) "开始上传" else "开始下载");
        var name: [512]u8 = undefined;
        const identity_text = if (data.owner) |owner| std.fmt.bufPrint(&name, "所属会话 · {s} #{d}", .{ data.host_name, @backingInt(owner.session_id) }) catch data.host_name else if (data.host_name.len > 0) data.host_name else "未指定会话";
        self.identity_name.setTextContent(self.cx.allocator, identity_text) catch {};
        self.identity_endpoint.setTextContent(self.cx.allocator, data.endpoint) catch {};
        self.identity_route.setTextContent(self.cx.allocator, data.link_text) catch {};
        self.identity_endpoint.setDisplay(if (data.endpoint.len > 0) .flex else .none);
        self.identity_route.setDisplay(if (data.link_text.len > 0) .flex else .none);
        self.source_rows.setDisplay(if (self.edit_remote_source) .none else .flex);
        self.download_source_row.setDisplay(if (self.edit_remote_source) .flex else .none);
        self.local_row.setDisplay(if (upload) .none else .flex);
        self.rename_row.setDisplay(if (upload) .none else .flex);
        self.remote_row.setDisplay(if (upload) .flex else .none);
        self.remote_hint.setDisplay(if (upload) .flex else .none);
        self.source_hint.setDisplay(if (upload and !self.drop) .flex else .none);
        self.source_summary.setDisplay(if (upload) .none else .flex);
        self.sources_dirty = true;
        self.applyOptions();
        self.setError(null);
        self.validateFields();
        self.open.set(true);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *Panel) void {
        self.open.set(false);
        self.cx.requestRedraw();
    }
    pub fn isVisible(self: *const Panel) bool {
        return self.open.peek();
    }
    pub fn directoryTicket(self: *Panel) !DirectoryTicket {
        if (!self.isVisible() or self.mode != .download or !self.available) return error.StaleSelection;
        const owner = self.captured_owner orelse return error.StaleOwner;
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return error.StaleOwner;
        const sources = try self.sourceSlices();
        if (sources.len == 0) {
            self.setError(submitMessage(error.MissingSources));
            return error.MissingSources;
        }
        self.validateRemoteSource(sources) catch |err| {
            self.setError(submitMessage(err));
            return err;
        };
        return .{ .owner = owner, .source_revision = self.source_revision, .source_hash = std.hash.Wyhash.hash(0, self.sources_sig.peek()) };
    }
    pub fn applyDirectorySelection(self: *Panel, ticket: DirectoryTicket, path: []const u8) !void {
        if (!self.isVisible() or self.mode != .download or !self.available or self.source_revision != ticket.source_revision or
            std.hash.Wyhash.hash(0, self.sources_sig.peek()) != ticket.source_hash) return error.StaleSelection;
        const owner = self.captured_owner orelse return error.StaleOwner;
        if (!owner.eql(ticket.owner)) return error.StaleOwner;
        if (!std.fs.path.isAbsolute(path) or path.len > self.scratch.local.len or std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfAny(u8, path, "\r\n") != null) return error.InvalidLocalDirectory;
        self.directory_source_revision = ticket.source_revision;
        self.directory_source_hash = ticket.source_hash;
        self.directory_selection.set(path);
        self.local_dir_sig.set(path);
        self.setError(null);
        self.validateFields();
    }
    pub fn capturedOwner(self: *const Panel) ?identity.SessionHandle {
        return self.captured_owner;
    }
    pub fn requestCancel(self: *Panel) void {
        self.hide();
        if (self.on_cancel) |call| call(self.submit_ctx);
    }
    fn close(self: *Panel) void {
        self.requestCancel();
    }
    fn openChanged(self: *Panel, value: bool) void {
        if (!value) self.requestCancel();
    }
    fn directory(self: *Panel) void {
        if (self.on_local_directory) |call| call(self.submit_ctx);
    }
    pub fn setPaneAnchor(self: *Panel, pane: ?*ui.Node) void {
        if (self.isVisible() and self.pane_anchor_id != null) return;
        const next = if (pane) |node| node.id else null;
        if (self.pane_anchor_id == next) return;
        self.pane_anchor_id = next;
        self.card.markLayoutDirty();
        self.cx.requestRedraw();
    }
    pub fn setLinkText(self: *Panel, value: []const u8) void {
        self.identity_route.setTextContent(self.cx.allocator, value) catch {};
        self.identity_route.setDisplay(if (value.len > 0) .flex else .none);
        self.cx.requestRedraw();
    }
    pub fn setError(self: *Panel, value: ?[]const u8) void {
        if (value) |message| {
            self.status_text.setTextContent(self.cx.allocator, message) catch {};
            self.status_row.setDisplay(.flex);
        } else self.status_row.setDisplay(.none);
        self.cx.requestRedraw();
    }
    fn sourceEdited(self: *Panel, value: []const u8) void {
        if (self.require_directory_selection) {
            // The path remains a suggestion for the next picker. Editing a
            // source revokes its receipt, so the new source cannot reuse it.
            self.directory_selection.set("");
        }
        self.fieldEdited(value);
    }
    fn fieldEdited(self: *Panel, _: []const u8) void {
        self.setError(null);
        self.validateFields();
    }
    fn fieldsChanged(self: *Panel) void {
        const sources = self.sources_sig.get();
        _ = self.remote_dir_sig.get();
        _ = self.local_dir_sig.get();
        _ = self.rename_sig.get();
        _ = self.source_size.get();
        const hash = std.hash.Wyhash.hash(0, sources);
        if (hash != self.source_hash) {
            self.source_hash = hash;
            self.source_revision +%= 1;
            self.sources_dirty = true;
            if (!self.showing) self.source_size.set("");
            if (self.on_sources_changed) |call| call(self.submit_ctx, self.source_revision);
        }
        self.sources_dirty = true;
        self.validateFields();
        self.card.markLayoutDirty();
        self.cx.requestRedraw();
    }
    fn sourceSlices(self: *Panel) ![]const []const u8 {
        const joined = self.sources_sig.peek();
        if (joined.len > self.scratch.sources.len) return error.FieldTooLong;
        @memcpy(self.scratch.sources[0..joined.len], joined);
        var iter = std.mem.tokenizeScalar(u8, self.scratch.sources[0..joined.len], '\n');
        var n: usize = 0;
        while (iter.next()) |path| {
            if (n == max_sources) return error.TooManySources;
            self.scratch.items[n] = path;
            n += 1;
        }
        return self.scratch.items[0..n];
    }
    fn validateRemoteSource(self: *const Panel, sources: []const []const u8) !void {
        if (self.edit_remote_source and (sources.len != 1 or !std.fs.path.isAbsolute(sources[0]) or
            !std.unicode.utf8ValidateSlice(sources[0]) or std.mem.indexOfAny(u8, sources[0], "\r\n\x00") != null)) return error.InvalidRemoteSource;
    }
    fn spec(self: *Panel) !transfer.JobSpec {
        const sources = try self.sourceSlices();
        if (sources.len == 0) return error.MissingSources;
        try self.validateRemoteSource(sources);
        if (self.require_directory_selection and (self.directory_selection.peek().len == 0 or
            self.directory_source_revision != self.source_revision or
            self.directory_source_hash != std.hash.Wyhash.hash(0, self.sources_sig.peek()) or
            !std.mem.eql(u8, self.directory_selection.peek(), self.local_dir_sig.peek()))) return error.MissingDirectorySelection;
        const remote = try copyValue(self.remote_dir_sig.peek(), &self.scratch.remote);
        const local = try copyValue(self.local_dir_sig.peek(), &self.scratch.local);
        const rename = try copyValue(self.rename_sig.peek(), &self.scratch.rename);
        var result = try buildSpec(.{ .mode = self.mode, .owner = self.captured_owner, .sources = sources, .remote_dir = remote, .local_dir = local, .rename = rename, .resume_transfer = self.resume_transfer, .md5 = self.md5, .notify_complete = self.notify_complete });
        if (self.drop_target_file and sources.len == 1 and remote.len > 0) {
            result.remote_dir = std.fs.path.dirname(remote) orelse return error.MissingRemoteDirectory;
            result.rename = std.fs.path.basename(remote);
        }
        return result;
    }
    fn validateFields(self: *Panel) void {
        const owner_valid = if (self.captured_owner) |owner| @backingInt(owner.session_id) != 0 and owner.generation != 0 else false;
        const owner_known = self.on_submit_frozen == null or owner_valid;
        const valid = if (self.spec()) |_| true else |_| false;
        self.disabled.set(!self.available or !valid or !owner_known or (self.on_submit == null and self.on_submit_frozen == null));
    }
    pub fn handleSubmit(self: *Panel) void {
        if (!self.available) {
            self.setError(if (self.unavailable_reason.peek().len > 0) self.unavailable_reason.peek() else "此连接暂时无法传输");
            return;
        }
        const value = self.spec() catch |err| {
            self.setError(submitMessage(err));
            return;
        };
        if (self.on_submit_frozen) |call| {
            const owner = self.captured_owner orelse {
                self.setError("请选择有效的目标会话");
                return;
            };
            if (@backingInt(owner.session_id) == 0 or owner.generation == 0) {
                self.setError("请选择有效的目标会话");
                return;
            }
            call(self.submit_ctx, owner, value) catch |err| {
                self.setError(submitMessage(err));
                return;
            };
        } else if (self.on_submit) |call| call(self.submit_ctx, value) else {
            self.setError("当前传输服务不可用");
            return;
        }
    }
    pub fn replaceSource(self: *Panel, index: usize, revision: u64, path: []const u8) !void {
        if (self.source_revision != revision) return error.StaleSelection;
        const sources = try self.sourceSlices();
        if ((index >= sources.len and !(index == 0 and sources.len == 0)) or path.len == 0) return error.StaleSelection;
        if (std.mem.indexOfScalar(u8, path, '\n') != null) return error.InvalidSource;
        var changed: [max_sources][]const u8 = undefined;
        @memcpy(changed[0..sources.len], sources);
        changed[index] = path;
        const joined = try std.mem.join(self.cx.allocator, "\n", changed[0..@max(@as(usize, 1), sources.len)]);
        defer self.cx.allocator.free(joined);
        self.sources_sig.set(joined);
        self.setError(null);
    }
    pub fn removeSource(self: *Panel, index: usize, revision: u64) !void {
        if (self.source_revision != revision) return error.StaleSelection;
        const sources = try self.sourceSlices();
        if (index >= sources.len) return error.StaleSelection;
        var changed: [max_sources][]const u8 = undefined;
        var n: usize = 0;
        for (sources, 0..) |path, i| if (i != index) {
            changed[n] = path;
            n += 1;
        };
        const joined = try std.mem.join(self.cx.allocator, "\n", changed[0..n]);
        defer self.cx.allocator.free(joined);
        self.sources_sig.set(joined);
        self.setError(null);
    }
    fn renderSources(self: *Panel) !void {
        self.sources_dirty = false;
        // Blur a replaced row while its widget handlers still own their scope.
        // Disposing first would leave the focused Button's blur context freed.
        for (self.source_rows.children.items) |child| self.cx.invalidateReferencesTo(child);
        if (self.source_scope) |scope| scope.dispose();
        self.source_scope = null;
        while (self.source_rows.children.items.len > 0) {
            const child = self.source_rows.children.items[self.source_rows.children.items.len - 1];
            self.cx.detachChild(self.source_rows, child);
            self.cx.destroyDetached(child);
        }
        const scope = try self.scope.childScope();
        self.source_scope = scope;
        const sources = self.sourceSlices() catch |err| {
            self.setError(submitMessage(err));
            return;
        };
        self.source_count = sources.len;
        const count = @max(@as(usize, 1), sources.len);
        for (0..count) |index| {
            const row = try ui.box(self.cx, S.pathRow(), .{});
            try self.source_rows.appendChild(self.cx.allocator, row);
            try row.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.file, T.current().fg_2, S.icon(16)));
            const caption = try self.text(row, if (self.mode == .upload) "本地文件" else "远程文件", 10.5, 400, true);
            caption.setStyleInline(self.cx.allocator, S.label(72));
            const path = try self.text(row, if (sources.len == 0) "请选择文件" else sources[index], 11, 400, false);
            path.setStyleInline(self.cx.allocator, S.flexibleLabel());
            if (path.getText()) |value| {
                var mono = value;
                mono.use_monospace_font = true;
                path.setText(mono);
            }
            if (self.mode == .upload) {
                const state = try scope.createState(SourceControl, .{ .panel = self, .index = index, .revision = self.source_revision });
                const replace = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get("folder-open"), .a11y_label = "替换本地文件", .base_style = S.action(20), .disabled = self.on_replace_source == null and (index != 0 or self.on_browse == null), .on_click = self.cx.on(SourceControl, state, SourceControl.replace) }).mount(scope, self.cx);
                replace.meta.ownership.meta.test_id = "transfer.source.replace";
                const hint = try ui.widgets.Popover(.{ .trigger = .hover, .tier = .tooltip, .position = .top, .close_on_escape = true, .close_on_outside_click = false, .max_width = @as(f32, 520), .max_height = @as(f32, 120), .size_policy = .fit_or_scroll, .open_delay_ms = @as(f32, 200), .prewarm_hidden_layout = false }).mount(scope, self.cx);
                hint.wrapper.setStyleInline(self.cx.allocator, .{ .flex_shrink = 0 });
                hint.content.setStyleInline(self.cx.allocator, S.sourceHint());
                hint.content.meta.ownership.meta.test_id = "transfer.source.hint";
                hint.content.behavior.interaction.a11y = .{ .role = .tooltip };
                _ = try self.text(hint.content, "替换本地文件", 11, 500, false);
                const hint_path = try self.text(hint.content, if (sources.len > 0) sources[index] else "选择一个本地文件", 11, 400, true);
                hint_path.setStyleInline(self.cx.allocator, .{ .max_width = 480 });
                if (hint_path.getText()) |value| {
                    var next = value;
                    next.wrap = .word;
                    hint_path.setText(next);
                }
                try hint.trigger.appendChild(self.cx.allocator, replace);
                try row.appendChild(self.cx.allocator, hint.wrapper);
                const focus = try ui.hooks.useFocusState(scope, self.cx, replace);
                try scope.createEffect(.{ .focused = focus.focused, .open = hint.open.? }, struct {
                    fn update(value: anytype) void {
                        value.open.set(value.focused.get());
                    }
                }.update);
                const remove = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .a11y_label = "移除此文件", .base_style = S.action(20), .disabled = sources.len == 0, .on_click = self.cx.on(SourceControl, state, SourceControl.remove) }).mount(scope, self.cx);
                remove.meta.ownership.meta.test_id = "transfer.source.remove";
                try row.appendChild(self.cx.allocator, remove);
            }
        }
        var summary: [160]u8 = undefined;
        const value = try std.fmt.bufPrint(&summary, "{d} 个文件{s}{s}", .{ sources.len, if (self.source_size.peek().len > 0) " · " else "", self.source_size.peek() });
        try self.source_hint.setTextContent(self.cx.allocator, value);
        try self.source_summary.setTextContent(self.cx.allocator, value);
    }
    fn applyOptions(self: *Panel) void {
        self.resume_label.set(if (self.resume_transfer) "断点续传 · 开" else "断点续传 · 关");
        self.md5_label.set(if (self.md5) "MD5 校验 · 开" else "MD5 校验 · 关");
        self.notify_label.set(if (self.notify_complete) "完成通知 · 开" else "完成通知 · 关");
    }
    fn toggleResume(self: *Panel) void {
        self.resume_transfer = !self.resume_transfer;
        self.applyOptions();
    }
    fn toggleMd5(self: *Panel) void {
        self.md5 = !self.md5;
        self.applyOptions();
    }
    fn toggleNotify(self: *Panel) void {
        self.notify_complete = !self.notify_complete;
        self.applyOptions();
    }
    pub fn retheme(self: *Panel) void {
        S.repaint(self.root, self.paint_colors);
        self.paint_colors = T.current();
        self.primary_style.set(S.confirmationPrimary());
        self.option_style.set(S.option());
        self.card.setStyleInline(self.cx.allocator, S.confirmation(self.naturalHeight()));
        self.sources_dirty = true;
        self.card.markLayoutDirty();
        self.cx.requestRedraw();
    }
    fn naturalHeight(self: *const Panel) f32 {
        var content: f32 = 0;
        if (self.viewport) |viewport| {
            // A ScrollArea's fitted box can still carry the previous viewport
            // height while the modal is resizing. Measure its visible rows so
            // the final options row cannot disappear below that old height.
            var count: usize = 0;
            for (viewport.content.children.items) |child| {
                if (child.style.display == .none or child.style.position == .absolute) continue;
                content += child.rectFromWorldOrFallback().h;
                count += 1;
            }
            if (count > 1) content += viewport.content.style.gap * @as(f32, @floatFromInt(count - 1));
        }
        const error_height = if (self.status_row.style.display != .none) self.status_row.globalRect().h else 0;
        return content + S.confirmation_chrome_height + error_height;
    }
    pub fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const p: *Panel = @ptrCast(@alignCast(raw));
        if (!p.isVisible()) return .done;
        // ModalPanel's default body has 16px padding. Reassert the explicit
        // component override after native mounting/styles have settled; otherwise
        // this second padding clips the last options row by 32px.
        const padding = p.body.style.padding;
        if (padding.top != 0 or padding.right != 0 or padding.bottom != 0 or padding.left != 0) {
            p.body.setStyleInline(p.cx.allocator, .{ .padding = ui.Padding.all(0) });
            return .needs_layout;
        }
        if (p.sources_dirty) {
            p.renderSources() catch |err| p.setError(submitMessage(err));
            return .needs_layout;
        }
        const parent = p.root.parent orelse return .done;
        const bounds = parent.globalRect();
        if (bounds.w <= 0 or bounds.h <= 0) return .done;
        var area = bounds;
        var anchored = false;
        if (p.pane_anchor_id) |anchor| if (findNode(p.cx.root orelse return .done, anchor)) |node| {
            area = node.globalRect();
            anchored = true;
        };
        const width = @max(@as(f32, 1), @min(@as(f32, 520), @min(area.w, bounds.w) - 24));
        const height = @max(@as(f32, 1), @min(p.naturalHeight(), @min(area.h, bounds.h) - 24));
        if (p.card.style.width.px != width or p.card.style.height.px != height) {
            p.card.setStyleInline(p.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height } });
            return .needs_layout;
        }
        if (anchored) {
            const containing = (p.card.parent orelse return .done).globalRect();
            const x = std.math.clamp(area.x - containing.x + (area.w - width) / 2, @as(f32, 12), @max(@as(f32, 12), containing.w - width - 12));
            const y = std.math.clamp(area.y - containing.y + (area.h - height) / 2, @as(f32, 12), @max(@as(f32, 12), containing.h - height - 12));
            const ext = p.card.style.getExt();
            if (p.card.style.position != .absolute or ext.inset.left != .px or ext.inset.top != .px or ext.inset.left.px != x or ext.inset.top.px != y) {
                p.card.setStyleInline(p.cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = x }, .top = .{ .px = y } } });
                return .needs_layout;
            }
        } else if (p.card.style.position == .absolute) {
            p.card.setStyleInline(p.cx.allocator, .{ .position = .relative, .inset = .{} });
            return .needs_layout;
        }
        return .done;
    }
};
fn copyValue(value: []const u8, buffer: []u8) ![]const u8 {
    if (value.len > buffer.len) return error.FieldTooLong;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}
fn submitMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingSources => "请先选择要传输的文件",
        error.MissingRemoteDirectory => "上传需要填写远程目录",
        error.MissingLocalDirectory => "下载需要填写保存目录",
        error.InvalidRename => "另存名称不能包含路径分隔符，且只支持单个文件",
        error.MissingDirectorySelection => "请选择本地保存目录",
        error.InvalidLocalDirectory => "请选择有效的本地保存目录",
        error.InvalidRemoteSource => "请输入远端文件或目录的绝对路径",
        error.TooManySources => "一次最多传输 64 个文件，请分批选择",
        error.FieldTooLong => "路径过长，请重新选择",
        error.StaleSelection => "源文件已变化，请重新选择",
        error.StaleOwner, error.OwnerClosed => "原会话已失效，请重新打开传输",
        else => @errorName(err),
    };
}
fn findNode(node: *ui.Node, node_id: u32) ?*ui.Node {
    if (node.id == node_id) return node;
    for (node.children.items) |child| if (findNode(child, node_id)) |found| return found;
    return null;
}

fn txt(cx: *ui.Cx, value: []const u8, size: f32, weight: u16, color: ui.Color) !*ui.Node {
    const node = try ui.text(cx, "", .{ .font_size = size, .font_weight = weight, .color = color, .line_height = 1.5 });
    try node.setTextContent(cx.allocator, value);
    return node;
}

test "refAllDecls forces analysis of the full mounting path" {
    std.testing.refAllDecls(Panel);
    std.testing.refAllDecls(@This());
}

test "buildSpec assembles upload spec and enforces remote dir" {
    const data: Data = .{
        .mode = .upload,
        .sources = &.{ "/tmp/a.tar.gz", "/tmp/b.bin" },
        .remote_dir = "/home/ubuntu/",
        .local_dir = "",
        .rename = "ignored-for-upload",
        .resume_transfer = true,
        .md5 = false,
    };
    const spec = try buildSpec(data);
    try std.testing.expect(spec.direction == .upload);
    try std.testing.expectEqual(@as(usize, 2), spec.sources.len);
    try std.testing.expectEqualStrings("/tmp/a.tar.gz", spec.sources[0]);
    try std.testing.expectEqualStrings("/home/ubuntu/", spec.remote_dir);
    try std.testing.expect(spec.rename == null); // upload 无 rename
    try std.testing.expect(spec.resume_transfer);
    try std.testing.expect(!spec.md5_check);

    try std.testing.expectError(error.MissingRemoteDirectory, buildSpec(.{ .mode = .upload, .sources = &.{"/tmp/a"}, .remote_dir = "" }));
    try std.testing.expectError(error.MissingSources, buildSpec(.{ .mode = .upload, .sources = &.{}, .remote_dir = "/x" }));
    try std.testing.expectError(error.MissingSources, buildSpec(.{ .mode = .upload, .sources = &.{""}, .remote_dir = "/x" }));
}

test "buildSpec assembles download spec with optional rename and enforces local dir" {
    const base: Data = .{
        .mode = .download,
        .sources = &.{"/var/log/app.log"},
        .remote_dir = "/var/log",
        .local_dir = "~/Downloads/",
        .rename = "app-k8s.log",
        .md5 = true,
    };
    const spec = try buildSpec(base);
    try std.testing.expect(spec.direction == .download);
    try std.testing.expectEqualStrings("/var/log", spec.remote_dir);
    try std.testing.expectEqualStrings("~/Downloads/", spec.local_dir);
    try std.testing.expectEqualStrings("app-k8s.log", spec.rename.?);
    try std.testing.expect(spec.md5_check);
    try std.testing.expect(spec.resume_transfer); // 默认开启

    var no_resume = base;
    no_resume.resume_transfer = false;
    try std.testing.expect(!(try buildSpec(no_resume)).resume_transfer);

    var no_rename = base;
    no_rename.rename = "";
    try std.testing.expect((try buildSpec(no_rename)).rename == null); // 空串 → null

    try std.testing.expectError(error.MissingLocalDirectory, buildSpec(.{ .mode = .download, .sources = &.{"/a"}, .local_dir = "" }));
    try std.testing.expectError(error.InvalidRename, buildSpec(.{ .mode = .download, .sources = &.{ "/a", "/b" }, .local_dir = "~/d", .rename = "x" }));
}

test "formatPercent and formatSpeed boundaries" {
    var buf: [32]u8 = undefined;
    // percent：0 总量、0、部分、恰好、溢出、整数截断
    try std.testing.expectEqualStrings("--%", formatPercent(&buf, 0, 0));
    try std.testing.expectEqualStrings("0%", formatPercent(&buf, 0, 100));
    try std.testing.expectEqualStrings("68%", formatPercent(&buf, 68, 100));
    try std.testing.expectEqualStrings("100%", formatPercent(&buf, 100, 100));
    try std.testing.expectEqualStrings("100%", formatPercent(&buf, 250, 100));
    try std.testing.expectEqualStrings("0%", formatPercent(&buf, 1, 1000));

    // speed：0、恰好 1 KiB、MiB 临界、恰好 1 MiB、亚临界舍入、恰好/超过 1 GiB
    try std.testing.expectEqualStrings("0 KB/s", formatSpeed(&buf, 0));
    try std.testing.expectEqualStrings("1 KB/s", formatSpeed(&buf, 1024));
    try std.testing.expectEqualStrings("1023 KB/s", formatSpeed(&buf, 1023 * 1024));
    try std.testing.expectEqualStrings("1.0 MB/s", formatSpeed(&buf, 1024 * 1024));
    try std.testing.expectEqualStrings("12.4 MB/s", formatSpeed(&buf, 13_002_342));
    try std.testing.expectEqualStrings("1.0 GB/s", formatSpeed(&buf, 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("2.0 GB/s", formatSpeed(&buf, 2 * 1024 * 1024 * 1024));
}

test "progressRow builds with proportional fill" {
    var ctx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try ui.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 28 } }, .{});
    ctx.root = root;

    const row_node = try progressRow(ctx, "app.tar.gz", 68, 100, 13_002_342, .running);
    try root.appendChild(std.testing.allocator, row_node);
    try std.testing.expectEqual(@as(usize, 5), row_node.children.items.len); // 🚀 名 进度条 % 速度
    const fill = row_node.children.items[2].children.items[0];
    try std.testing.expectEqualStrings("px", @tagName(fill.style.width));
    try std.testing.expectApproxEqAbs(@as(f32, 74.8), fill.style.width.px, 0.01); // 68% × 110

    const empty = try progressRow(ctx, "e", 0, 100, 0, .queued);
    try root.appendChild(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(f32, 0), empty.children.items[2].children.items[0].style.width.px);

    const full = try progressRow(ctx, "f", 300, 100, 0, .succeeded);
    try root.appendChild(std.testing.allocator, full);
    try std.testing.expectEqual(@as(f32, 110), full.children.items[2].children.items[0].style.width.px);
}
