//! Standalone AI page: three-column shell. The assistant surface itself is
//! attached by the main window into center_slot; conversation state, tools and
//! workers stay owned by AiHost.
const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const shell = @import("../../ui/ai_workspace_shell.zig");
const bridge = @import("../../ui/ai_standalone_bridge.zig");
const files = bridge.WorkspacePreview;
const diff = @import("../../ai/workspace_turn_diff.zig");
const diff_job = @import("workspace_diff_job.zig");
const file_identity = @import("../../host/local_workspace.zig").Identity;
const DiffKey = struct { authority: @import("../../ai/host_tools.zig").Context, turn_id: u64 };
const file_wait_ns = 5 * std.time.ns_per_s;

// One latest intent per lane. Selection never needs to wait for a superseded
// filesystem call, and a tree reload does not clear or cancel a file preview.
const FileWork = struct {
    pending: bool = false,
    announced: bool = false,
    deadline_ns: i96 = 0,
    job: ?*files.Job = null,
    path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn enqueue(self: *FileWork, path: []const u8, now: i96) bool {
        if (path.len >= self.path.len) return false;
        if (self.pending and std.mem.eql(u8, self.path[0..self.len], path)) return false;
        self.retire();
        @memmove(self.path[0..path.len], path);
        self.len = path.len;
        self.pending = true;
        self.announced = false;
        self.deadline_ns = now + file_wait_ns;
        return true;
    }

    fn retire(self: *FileWork) void {
        self.pending = false;
        const job = self.job orelse return;
        self.job = null;
        job.cancel();
        job.release();
    }
};

pub const View = struct {
    shell: *shell.View,
    bridge_slot: bridge.Slot = undefined,

    stamp: ?files.Stamp = null,
    auto_opened_workspace: ?files.Stamp = null,
    reference_trial: bool = false,
    preview_pin: ?bridge.WorkspaceText.Pin = null,
    preview_file: ?file_identity = null,
    diff_key: ?DiffKey = null,
    diff_pending: bool = false,
    diff_job: ?*diff_job.Job = null,
    diff_epoch: u64 = 0,
    diff_deadline_ns: i96 = 0,
    ticket: ?bridge.WorkspaceTicket = null,
    epoch: u64 = 0,
    tree_work: FileWork = .{},
    preview_work: FileWork = .{},
    preview_good: bool = false,
    expanded: [std.Io.Dir.max_path_bytes]u8 = undefined,
    expanded_len: usize = 0,

    fn request(self: *View, mode: files.Mode, path: []const u8) void {
        if (self.stamp == null) return;
        const work = if (mode == .list) &self.tree_work else &self.preview_work;
        if (!work.enqueue(path, std.Io.Clock.awake.now(self.shell.cx.io).nanoseconds)) return;
        if (mode == .read) {
            self.clearPreviewApproval();
            self.epoch +%= 1;
        }
        self.shell.cx.requestRedraw();
    }
    fn selectFile(raw: ?*anyopaque, path: []const u8) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        if (self.stamp == null) return;
        for (self.shell.files.items) |row| {
            if (!std.mem.eql(u8, path, row.path)) continue;
            switch (row.kind) {
                .directory => self.request(.list, if (row.expanded) std.fs.path.dirname(path) orelse "" else path),
                .file => self.request(.read, path),
                .symlink => {
                    self.discardPreview();
                    shell.preview_notice(self.shell, "为避免离开工作区，不打开符号链接。") catch {};
                },
            }
            return;
        }
    }
    fn showHistory(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        bridge.dispatch(&self.bridge_slot, .history);
    }
    fn chooseWorkspace(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        bridge.dispatch(&self.bridge_slot, .{ .choose_workspace = self.ticket orelse return });
    }
    fn clearPin(self: *View) void {
        self.preview_pin = null;
        shell.set_preview_reference_available(self.shell, false);
    }
    fn retireDiff(self: *View) void {
        self.diff_pending = false;
        const active = self.diff_job orelse return;
        self.diff_job = null;
        active.cancel();
        active.release();
    }
    fn clearPreviewApproval(self: *View) void {
        self.clearPin();
        self.preview_file = null;
        self.retireDiff();
        shell.set_preview_diff_offer(self.shell, false);
    }
    fn choosePreviewMode(raw: ?*anyopaque, mode: shell.PreviewMode) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        if (!self.shell.preview_diff_available or self.preview_file == null) return;
        if (mode == .source) {
            self.retireDiff();
            shell.show_preview_diff_status(self.shell, "") catch {};
            return;
        }
        if (self.diff_pending or self.diff_job != null) return;
        self.diff_pending = true;
        shell.show_preview_diff_status(self.shell, "正在核验当前回合的修改回执…") catch {};
        self.shell.cx.requestRedraw();
    }
    fn sameDiffReceipt(active: *const diff_job.Job, current: bridge.DiffAccess) bool {
        if (!active.current.authority.eql(current.authority) or active.current.turn_id != current.turn_id) return false;
        const index = active.matched_index orelse return true;
        const frozen = &active.records.items[index];
        for (current.records) |record| {
            if (!diff_job.eligible(record, current.authority, current.turn_id) or !std.mem.eql(u8, record.call_id, frozen.call_id)) continue;
            const latest = record.host.?;
            const prior = frozen.host.?;
            return latest.status == prior.status and std.meta.eql(latest.receipt, prior.receipt) and std.mem.eql(u8, latest.content, prior.content);
        }
        return false;
    }
    fn presentDiff(self: *View, active: *const diff_job.Job) !void {
        const verdict = active.result catch |err| return shell.show_preview_diff_status(self.shell, switch (err) {
            error.WorkspaceChanged, error.FileNotFound, error.FileChanged => "文件已变化。请重新预览文件，再查看回执。",
            else => "回执当前无法核验；已保留源码。",
        });
        switch (verdict) {
            .not_applicable => try shell.show_preview_diff_status(self.shell, "当前回合没有找到此文件可核验的单笔修改；已保留源码。"),
            .unverified => try shell.show_preview_diff_status(self.shell, "这笔修改尚未核验，不能显示差异；已保留源码。"),
            .expired => try shell.show_preview_diff_status(self.shell, "这笔修改的差异内容已过期；已保留源码。"),
            .unavailable => try shell.show_preview_diff_status(self.shell, "这笔修改没有可核验的差异内容；已保留源码。"),
            .change => |value| {
                const a = self.shell.cx.allocator;
                var out = std.Io.Writer.Allocating.init(a);
                defer out.deinit();
                for (value.diff.lines) |line| {
                    try out.writer.print("{c}{d} {s}", .{ if (line.kind == .add) @as(u8, '+') else '-', line.number, line.text });
                    if (!std.mem.endsWith(u8, line.text, "\n")) try out.writer.writeByte('\n');
                }
                if (value.diff.lines.len == 0) try out.writer.writeAll(if (value.diff.truncated) "差异内容超过显示上限。" else "这笔修改没有文本差异。");
                const caption = if (value.diff.truncated) "已核验的单笔修改 · 仅显示片段" else "已核验的单笔修改 · 不代表整个回合";
                try shell.show_verified_preview_diff(self.shell, caption, out.written());
            },
        }
    }
    fn advanceDiff(self: *View, source: ?files.Source, access: ?bridge.DiffAccess) !void {
        const key: ?DiffKey = if (access) |visible| .{ .authority = visible.authority, .turn_id = visible.turn_id } else null;
        if (!std.meta.eql(key, self.diff_key)) {
            self.retireDiff();
            self.diff_key = key;
            try shell.show_preview_diff_status(self.shell, "");
        }
        const offered = self.preview_file != null and self.shell.preview_path.len != 0 and source != null and access != null and
            hasReceipt(access.?);
        shell.set_preview_diff_offer(self.shell, offered);
        if (!offered) {
            self.retireDiff();
            return;
        }
        const current = access.?;
        const stamp = source.?.stamp;
        if (self.diff_job) |active| {
            if (self.diff_epoch != self.epoch or !std.meta.eql(stamp, active.selection.stamp) or
                !std.meta.eql(self.preview_file, @as(?file_identity, active.selection.file)) or
                !std.mem.eql(u8, self.shell.preview_path, active.selection.relative))
            {
                self.retireDiff();
            } else if (active.done.load(.acquire)) {
                self.diff_job = null;
                defer active.release();
                if (sameDiffReceipt(active, current)) {
                    try self.presentDiff(active);
                } else {
                    try shell.show_preview_diff_status(self.shell, "可见回执已变化，请重新核验；已保留源码。");
                }
            } else if (std.Io.Clock.awake.now(self.shell.cx.io).nanoseconds >= self.diff_deadline_ns) {
                self.retireDiff();
                try shell.show_preview_diff_status(self.shell, "核验超时，可稍后再试；已保留源码。");
            } else {
                self.shell.cx.scheduleRedrawAfterNs(32 * std.time.ns_per_ms);
                return;
            }
        }
        if (!self.diff_pending) return;
        self.diff_pending = false;
        self.diff_job = diff_job.Job.start(.{ .source = source.?, .authority = current.authority, .turn_id = current.turn_id }, .{
            .stamp = stamp,
            .relative = self.shell.preview_path,
            .file = self.preview_file.?,
        }, current.records) catch |err| {
            try shell.show_preview_diff_status(self.shell, if (err == error.DiffBusy) "当前有其他核验正在运行；已保留源码。" else "回执暂不能核验；已保留源码。");
            return;
        };
        self.diff_epoch = self.epoch;
        self.diff_deadline_ns = std.Io.Clock.awake.now(self.shell.cx.io).nanoseconds + file_wait_ns;
        self.shell.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }
    fn hasReceipt(access: bridge.DiffAccess) bool {
        for (access.records) |record| if (diff_job.eligible(record, access.authority, access.turn_id)) return true;
        return false;
    }
    fn referenceFile(raw: ?*anyopaque, path: []const u8) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        if (!self.reference_trial) return;
        bridge.dispatch(&self.bridge_slot, .{ .reference_workspace_file = .{ .stamp = self.stamp orelse return, .relative = path, .pin = self.preview_pin orelse return } });
        self.clearPin(); // A new approval always needs a newly loaded preview.
    }
    fn refreshFiles(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        self.request(.list, self.expanded[0..self.expanded_len]);
    }
    fn refreshPreview(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        if (self.shell.preview_path.len != 0) self.request(.read, self.shell.preview_path);
    }
    fn discardPreview(self: *View) void {
        self.clearPreviewApproval();
        self.preview_good = false;
        self.epoch +%= 1;
        self.preview_work.retire();
    }
    fn closePreview(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        self.discardPreview();
        shell.dismiss_preview(self.shell) catch {};
    }
    fn previewError(err: anyerror) []const u8 {
        return switch (err) {
            error.AmbiguousLink => "为避免显示工作区外的内容，不预览有多个硬链接的文件。",
            error.BinaryFile, error.NotRegularFile => "此文件不是受支持的文本或图片。",
            error.ImageTooLarge => "图片超过预览上限（6 MiB、边长 4096 或总像素 419 万）。",
            error.AnimatedImageUnsupported => "不支持预览动画图片。",
            error.InvalidImage, error.UnsupportedImage => "无法解码这张图片。",
            error.ImageMemoryBudgetExceeded => "图片预览内存不足，请关闭其他预览后重试。",
            error.ImagePreviewUnavailable => "当前窗口无法显示图片预览。",
            error.FileChanged, error.FileNotFound => "文件已变化，请刷新后重试。",
            error.PreviewDepthLimit => "已达到目录展开深度上限。",
            error.PreviewTimedOut => "读取超时，请检查工作区是否可用，再刷新。",
            error.NotesStoreProtected => "此目录需在笔记工作区中查看。",
            error.WorkspaceChanged => "工作区目录已变化，请重新选择。",
            else => "无法读取，请检查工作区路径与读取权限，再刷新。",
        };
    }
    fn autoOpenWorkspace(self: *View, stamp: files.Stamp) void {
        if (self.shell.compact) return;
        if (self.auto_opened_workspace) |seen| {
            if (seen.revision == stamp.revision and std.meta.eql(seen.root, stamp.root) and
                std.meta.eql(seen.fence.conversation, stamp.fence.conversation)) return;
        }
        self.auto_opened_workspace = stamp;
        shell.set_inspector_open(self.shell, true);
    }
    fn present(self: *View, job: *const files.Job) !void {
        const result = job.result catch |err| return self.presentFailure(job.mode, err);
        switch (result) {
            .listing => |listing| {
                @memcpy(self.expanded[0..job.path.len], job.path);
                self.expanded_len = job.path.len;
                var rows: [files.max_rows]shell.FileRow = undefined;
                for (listing.rows, 0..) |e, i| rows[i] = .{ .path = e.path, .name = std.fs.path.basename(e.path), .kind = @fromBackingInt(@intCast(@backingInt(e.kind))), .depth = e.depth, .expanded = e.expanded };
                try shell.set_files(self.shell, rows[0..listing.rows.len]);
                try shell.show_file_tree_status(self.shell, if (listing.limited) "目录较大，仅显示部分条目。" else if (listing.rows.len == 0) "目录为空。" else "");
            },
            .text => |t| {
                const a = self.shell.cx.allocator;
                const title = if (t.limited) try std.fmt.allocPrint(a, "{s}（{s}）", .{ std.fs.path.basename(job.path), if (t.line_limited) @as([]const u8, "仅前 256 行") else "仅前 16 KiB" }) else null;
                defer if (title) |name| a.free(name);
                try shell.set_file_preview(self.shell, title orelse std.fs.path.basename(job.path), job.path, "", t.bytes);
                self.preview_good = true;
                try shell.show_preview_status(self.shell, "");
                self.preview_file = t.file;
                if (self.reference_trial) {
                    self.preview_pin = bridge.WorkspaceText.pinText(job.path, t) catch null;
                    shell.set_preview_reference_available(self.shell, self.preview_pin != null);
                }
            },
            .image => |reference| {
                const image = reference.content() orelse return self.presentFailure(.read, error.InvalidImage);
                shell.set_image_preview(self.shell, job.path, image.width, image.height, image.pixels) catch |err| return self.presentFailure(.read, err);
                self.preview_good = true;
                try shell.show_preview_status(self.shell, "");
            },
        }
    }

    fn presentFailure(self: *View, mode: files.Mode, err: anyerror) !void {
        if (err == error.WorkspaceChanged) {
            self.discardPreview();
            self.tree_work.retire();
            self.expanded_len = 0;
            try shell.dismiss_preview(self.shell);
            try shell.set_files(self.shell, &.{});
            return shell.show_file_tree_status(self.shell, previewError(err));
        }
        if (mode == .list) return shell.show_file_tree_status(self.shell, previewError(err));
        if (!self.preview_good) return shell.show_preview_status(self.shell, previewError(err));
        const a = self.shell.cx.allocator;
        const warning = try std.fmt.allocPrint(a, "{s} 已保留上次预览。", .{previewError(err)});
        defer a.free(warning);
        try shell.show_preview_status(self.shell, warning);
    }

    fn driveFiles(self: *View, work: *FileWork, source: files.Source, mode: files.Mode, start: *const fn (files.Source, files.Mode, []const u8) anyerror!*files.Job) !void {
        if (!work.pending) return;
        const path = work.path[0..work.len];
        if (!work.announced) {
            work.announced = true;
            if (mode == .list) {
                try shell.show_file_tree_status(self.shell, "正在读取文件列表…");
            } else {
                const same_preview = self.preview_good and std.mem.eql(u8, path, self.shell.preview_path);
                if (!same_preview) {
                    self.preview_good = false;
                    try shell.start_preview(self.shell, path);
                }
                try shell.show_preview_status(self.shell, if (same_preview) "正在刷新…" else "正在读取…");
            }
        }
        if (work.job) |job| {
            if (!std.meta.eql(job.stamp, source.stamp) or !std.mem.eql(u8, path, job.path)) {
                work.retire();
                return;
            }
            if (job.done.load(.acquire)) {
                work.job = null;
                work.pending = false;
                defer job.release();
                return self.present(job);
            }
        }
        if (std.Io.Clock.awake.now(self.shell.cx.io).nanoseconds >= work.deadline_ns) {
            work.retire();
            return self.presentFailure(mode, error.PreviewTimedOut);
        }
        if (work.job == null) {
            work.job = start(source, mode, path) catch |err| switch (err) {
                // A retired kernel call can still own a shared worker slot.
                // Keep only the latest authorized intent until its deadline.
                error.PreviewBusy => null,
                else => {
                    work.retire();
                    return self.presentFailure(mode, err);
                },
            };
        }
        self.shell.cx.scheduleRedrawAfterNs(32 * std.time.ns_per_ms);
    }
    // Called at the window's frame boundary. Actions only enqueue work; never
    // destroy a file row or release a selected path from its own click stack.
    fn setWorkspace(raw: *anyopaque, ticket: ?bridge.WorkspaceTicket, source: ?files.Source, access: ?bridge.DiffAccess) !void {
        const self: *View = @ptrCast(@alignCast(raw));
        const stamp = if (source) |s| @as(?files.Stamp, s.stamp) else null;
        const reference_trial = if (source) |s| s.reference_trial else false;
        if (!std.meta.eql(stamp, self.stamp) or !std.meta.eql(ticket, self.ticket) or reference_trial != self.reference_trial) {
            self.discardPreview();
            self.reference_trial = reference_trial;
            self.stamp = stamp;
            self.ticket = ticket;
            self.expanded_len = 0;
            self.tree_work.retire();
            try shell.bind_files(self.shell, if (source) |s| std.fs.path.basename(s.workspace.directory.?) else null, ticket != null);
            if (source != null) self.request(.list, "");
        }
        // Returning to the same workspace after switching tabs must not undo
        // the person's deliberate decision to close its inspector.
        if (stamp) |current| self.autoOpenWorkspace(current);
        if (source) |s| {
            try self.driveFiles(&self.tree_work, s, .list, files.Job.start);
            try self.driveFiles(&self.preview_work, s, .read, files.Job.start);
        }
        try self.advanceDiff(source, access);
    }

    fn setTitle(self: *View, value: []const u8) !void {
        const name = if (value.len != 0) value else "新对话";
        if (self.shell.title_node.getText()) |text| {
            if (std.mem.eql(u8, text.content, name)) return;
        }
        try shell.set_title(self.shell, name);
    }

    fn unmount(raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        bridge.unregister(&self.bridge_slot);
        self.retireDiff();
        self.tree_work.retire();
        self.preview_work.retire();
    }

    fn setBadge(raw: *anyopaque, value: []const u8) void {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.shell.scope_badge_node.getText()) |text| {
            if (std.mem.eql(u8, text.content, value)) return;
        }
        shell.set_scope_badge(self.shell, value) catch {};
    }

    fn setConversations(raw: *anyopaque, title: []const u8, rows: []const shell.Conversation, can_open_global_history: bool) !void {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.shell.history_button) |button| {
            const display: @TypeOf(button.style.display) = if (can_open_global_history) .flex else .none;
            if (button.style.display != display) button.setDisplay(display);
        }
        try self.setTitle(title);
        try shell.set_sessions(self.shell, rows);
    }

    fn newConversation(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        bridge.dispatch(&self.bridge_slot, .new_chat);
    }

    fn previewConversation(raw: ?*anyopaque, id: []const u8) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        const numeric_id = std.fmt.parseInt(u64, id, 10) catch return;
        bridge.dispatch(&self.bridge_slot, .{ .preview = numeric_id });
    }

    fn pinConversation(raw: ?*anyopaque, id: []const u8, desired: bool) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        bridge.dispatch(&self.bridge_slot, .{ .pin = .{ .id = std.fmt.parseInt(u64, id, 10) catch return, .value = desired } });
    }

    fn deleteConversation(raw: ?*anyopaque, id: []const u8) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        bridge.dispatch(&self.bridge_slot, .{ .delete = std.fmt.parseInt(u64, id, 10) catch return });
    }

    fn setHost(raw: *anyopaque, index: usize, node: ?*ui.Node) !void {
        const self: *View = @ptrCast(@alignCast(raw));
        const tab: shell.InspectorTab = switch (index) {
            0 => .members,
            1 => .board,
            2 => .graph,
            3 => .rounds,
            else => return error.InspectorHostUnavailable,
        };
        try shell.set_inspector_host(self.shell, tab, node);
    }

    // ContentUpdate supplies the plugin tab label, not a conversation title.
    fn update(_: *anyopaque, _: contract.ContentUpdate) anyerror!void {}

    fn focusChanged(_: *anyopaque, _: bool) void {}

    fn presentationChanged(_: *anyopaque, _: contract.ContentPresentation) void {}
};

pub fn mount(request: contract.ContentMount) !contract.RendererInstance {
    const cx = request.cx;
    const scope = request.scope;
    const view = try scope.createState(View, .{ .shell = undefined });
    view.shell = try shell.mount(.{
        .cx = cx,
        .scope = scope,
        .parent = request.slot,
        .title = "新对话",
        .scope_badge = "独立 AI · 未关联会话",
        .inspector_open = false,
        .files_unavailable_reason = "选择此对话的本地工作区后，可在这里浏览和预览。",
        .preview_texture_backend = if (request.frame_sink) |sink| sink.backend else null,
        .preview_reference_requires_approval = true,
        .callbacks = .{ .context = view, .new_chat = View.newConversation, .show_history = View.showHistory, .select_conversation = View.previewConversation, .pin_conversation = View.pinConversation, .delete_conversation = View.deleteConversation, .choose_workspace = View.chooseWorkspace, .refresh_files = View.refreshFiles, .refresh_preview = View.refreshPreview, .close_preview = View.closePreview, .select_file = View.selectFile, .insert_file_reference = View.referenceFile, .choose_preview_mode = View.choosePreviewMode },
    });
    var pages: [bridge.inspector_pages]?*ui.Node = @splat(null);
    pages[0] = shell.inspector_page(view.shell, .members);
    pages[1] = shell.inspector_page(view.shell, .board);
    pages[2] = shell.inspector_page(view.shell, .graph);
    pages[3] = shell.inspector_page(view.shell, .rounds);
    view.bridge_slot = .{ .owner = request.owner, .center = view.shell.center_slot, .pages = pages, .context = view, .set_badge = View.setBadge, .set_host = View.setHost, .set_conversations = View.setConversations, .set_workspace = View.setWorkspace };
    bridge.register(&view.bridge_slot);
    return .{ .context = view, .vtable = &.{ .update = View.update, .focus_changed = View.focusChanged, .unmount = View.unmount, .presentation_changed = View.presentationChanged } };
}

test "standalone workspace preview opens real file through mounted native tree and revokes stale results" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const local = @import("../../host/local_workspace.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "folder", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "folder/readme.txt", .data = "disk, not a sample\nsecond line\n" });
    try tmp.dir.symLink(io, "folder/readme.txt", "link", .{});
    const abs = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(abs);
    var bound = try local.inspect(a, io, abs);
    defer bound.deinit(a);
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const owner = @import("../../host/identity.zig").SessionHandle{ .session_id = @fromBackingInt(42), .generation = 13 };
    const plugin = try mount(.{ .cx = cx, .scope = scope, .slot = cx.root.?, .owner = owner, .connection = .{ .name = "AI", .protocol_id = "ai", .payload = "{}" } });
    defer plugin.vtable.unmount(plugin.context);
    const self: *View = @ptrCast(@alignCast(plugin.context));
    const ticket: bridge.WorkspaceTicket = .{ .conversation = .generate(), .revision = bound.revision, .scope_revision = 13 };
    const source = files.Source{ .stamp = .{ .owner = owner, .fence = .{ .agent = .generate(), .conversation = ticket.conversation, .binding = 1, .environment = 1 }, .revision = bound.revision, .scope_revision = 13, .root = bound.directory_identity.? }, .workspace = bound, .data_root = "" };
    const harness = struct {
        fn drain(v: *View, handle: @TypeOf(owner), t: bridge.WorkspaceTicket, src: files.Source) !void {
            for (0..400) |_| {
                bridge.setWorkspace(handle, t, src);
                if (!v.tree_work.pending and !v.preview_work.pending) return;
                try std.testing.io.sleep(.fromMilliseconds(5), .awake);
            }
            return error.Timeout;
        }
        fn click(c: *ui.Cx, n: *ui.Node) void {
            c.layout();
            const r = n.globalRect();
            c.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
            c.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        }
        // Keep the worker reference unfinished, like a read stuck inside the
        // mounted filesystem. There is no sleep or timing race in this test.
        fn stall(v: *View, src: files.Source) !*files.Job {
            v.request(.read, "folder/readme.txt");
            const job = try std.heap.c_allocator.create(files.Job);
            job.* = .{ .arena = .init(std.heap.c_allocator), .source = src, .stamp = src.stamp, .mode = .read, .path = "folder/readme.txt" };
            v.preview_work.job = job;
            return job;
        }
        fn saturated(_: files.Source, _: files.Mode, _: []const u8) anyerror!*files.Job {
            return error.PreviewBusy;
        }
    };
    try harness.drain(self, owner, ticket, source);
    try std.testing.expect(self.shell.inspector_open);
    try std.testing.expectEqual(@as(usize, 2), self.shell.files.items.len);
    harness.click(cx, self.shell.file_list.children.items[0]); // expand the folder
    try harness.drain(self, owner, ticket, source);
    try std.testing.expectEqualStrings("folder/readme.txt", self.shell.files.items[1].path);
    harness.click(cx, self.shell.file_list.children.items[1]);
    try harness.drain(self, owner, ticket, source);
    try std.testing.expectEqualStrings("disk, not a sample\nsecond line\n", self.shell.preview_code.getText().?.content);
    try std.testing.expect(self.shell.preview_gutter.style.display == .flex);
    harness.click(cx, self.shell.file_list.children.items[2]);
    try std.testing.expectEqualStrings("", self.shell.preview_source);
    try std.testing.expect(std.mem.indexOf(u8, self.shell.preview_placeholder.getText().?.content, "符号链接") != null);
    harness.click(cx, self.shell.file_list.children.items[1]);
    bridge.setWorkspace(owner, ticket, source); // read dispatched, result not yet consumed
    try std.testing.expect(self.preview_work.job != null);
    bridge.setWorkspace(owner, null, null);
    try std.testing.expectEqual(@as(usize, 0), self.shell.files.items.len);
    try std.testing.expect(self.shell.file_scroll.container.style.display == .none);
    for (0..400) |_| {
        bridge.setWorkspace(owner, null, null);
        if (self.preview_work.job == null) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    } else return error.Timeout;
    try std.testing.expectEqualStrings("", self.shell.preview_source);

    shell.set_inspector_open(self.shell, false);
    try harness.drain(self, owner, ticket, source);
    try std.testing.expect(!self.shell.inspector_open);
    shell.set_inspector_open(self.shell, true);
    const stale = try harness.stall(self, source);
    defer stale.release();
    self.request(.read, stale.path); // duplicate clicks do not spawn another reader
    try std.testing.expect(self.preview_work.pending and self.preview_work.job == stale);
    var next_ticket = ticket;
    var next_scope = source;
    next_ticket.scope_revision += 1;
    next_scope.stamp.scope_revision += 1;
    next_scope.stamp.fence.environment += 1;
    // The same working directory can have a new grant/environment generation.
    // An unresponsive old read must neither paint nor block the new listing.
    bridge.setWorkspace(owner, next_ticket, next_scope);
    try std.testing.expect(stale.canceled.load(.acquire));
    try std.testing.expect(self.tree_work.job != null and self.preview_work.job == null);
    try harness.drain(self, owner, next_ticket, next_scope);
    try std.testing.expectEqual(@as(usize, 2), self.shell.files.items.len);
    stale.result = .{ .text = .{ .bytes = "superseded result", .limited = false, .line_limited = false } };
    stale.done.store(true, .release);
    bridge.setWorkspace(owner, next_ticket, next_scope);
    try std.testing.expectEqualStrings("", self.shell.preview_source);

    const timed_out = try harness.stall(self, next_scope);
    defer timed_out.release();
    self.preview_work.deadline_ns = 0;
    bridge.setWorkspace(owner, next_ticket, next_scope);
    try std.testing.expect(self.preview_work.job == null and timed_out.canceled.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, self.shell.preview_status.getText().?.content, "超时") != null);
    // A user can still browse the current directory and explicitly retry.
    harness.click(cx, self.shell.file_list.children.items[0]);
    try harness.drain(self, owner, next_ticket, next_scope);
    harness.click(cx, self.shell.file_list.children.items[1]);
    try harness.drain(self, owner, next_ticket, next_scope);
    try std.testing.expectEqualStrings("disk, not a sample\nsecond line\n", self.shell.preview_source);

    // Simulate the shared worker cap without manipulating global state. The
    // good content survives while the latest refresh waits for admission.
    try tmp.dir.writeFile(io, .{ .sub_path = "folder/readme.txt", .data = "new disk content" });
    harness.click(cx, self.shell.preview_refresh.?);
    try self.driveFiles(&self.preview_work, next_scope, .read, harness.saturated);
    try std.testing.expect(self.preview_work.pending and self.preview_work.job == null);
    try std.testing.expectEqualStrings("disk, not a sample\nsecond line\n", self.shell.preview_source);
    try std.testing.expectEqualStrings("正在刷新…", self.shell.preview_status.getText().?.content);
    try harness.drain(self, owner, next_ticket, next_scope);
    try std.testing.expectEqualStrings("new disk content", self.shell.preview_source);

    try tmp.dir.deleteFile(io, "folder/readme.txt");
    harness.click(cx, self.shell.preview_refresh.?);
    try harness.drain(self, owner, next_ticket, next_scope);
    try std.testing.expectEqualStrings("new disk content", self.shell.preview_source);
    try std.testing.expect(std.mem.endsWith(u8, self.shell.preview_status.getText().?.content, "已保留上次预览。"));
    cx.layout();
    const height = self.shell.preview_box.globalRect().h;
    const grip = self.shell.preview_grip.globalRect();
    const x = grip.x + grip.w / 2;
    const y = grip.y + grip.h / 2;
    cx.handleMouseMove(x, y);
    try std.testing.expectEqual(ui.CursorShape.ns_resize, cx.current_cursor);
    cx.handleMouseDown(x, y, .{});
    cx.handleMouseMove(x, y - 74);
    cx.handleMouseUp(x, y - 74);
    cx.layout();
    try std.testing.expect(self.shell.preview_box.globalRect().h > height + 40);
    harness.click(cx, self.shell.preview_close);
    try std.testing.expect(!self.shell.preview_visible);
    try std.testing.expectEqualStrings("", self.shell.preview_source);
    try std.testing.expect(self.shell.file_scroll.container.style.display == .flex);

    // A delayed previous selection is not allowed to repaint even if the
    // new request belongs to exactly the same workspace and conversation.
    try tmp.dir.writeFile(io, .{ .sub_path = "folder/other.txt", .data = "latest selection" });
    const earlier = try harness.stall(self, next_scope);
    defer earlier.release();
    self.request(.read, "folder/other.txt");
    try std.testing.expect(earlier.canceled.load(.acquire));
    try harness.drain(self, owner, next_ticket, next_scope);
    earlier.result = .{ .text = .{ .bytes = "late old selection", .limited = false, .line_limited = false } };
    earlier.done.store(true, .release);
    bridge.setWorkspace(owner, next_ticket, next_scope);
    try std.testing.expectEqualStrings("folder/other.txt", self.shell.preview_path);
    try std.testing.expectEqualStrings("latest selection", self.shell.preview_source);
}
