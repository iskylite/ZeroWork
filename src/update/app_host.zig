const std = @import("std");
const ui = @import("ui");
const client = @import("client.zig");
const admission = @import("admission.zig");
const close = @import("close_coordinator.zig");
const identity = @import("../host/identity.zig");
const session = @import("../host/session_host.zig");
const theme = @import("../ui/app_theme.zig");
const View = @import("../ui/app_update_view.zig");
const allocator = std.heap.c_allocator;
pub const Source = union(enum) { job: u64, session: identity.SessionHandle, aux: identity.WindowId };
pub fn Host(comptime Process: type) type {
    return struct {
        const Self = @This();
        process: *Process,
        coordinator: close.Coordinator = .{},
        sources: std.ArrayList(Source) = .empty,
        visible_sources: std.ArrayList(bool) = .empty,
        view: ?*View.View = null,
        view_window: ?identity.WindowId = null,
        phase: enum { idle, confirm, closing, blocked, handoff, cancel_pending, committed } = .idle,
        snapshot: ?[:0]u8 = null,
        original_snapshot: ?[:0]u8 = null,
        started: u64 = 0,
        commit_sent: bool = false,
        confirmation_revision: ?u64 = null,
        exit: bool = false,
        status: client.Status = .{},
        previous: client.Status = .{},
        message: [2048]u8 = @splat(0),
        dirty: bool = true,
        pub fn deinit(self: *Self) void {
            self.coordinator.deinit(allocator);
            self.sources.deinit(allocator);
            self.visible_sources.deinit(allocator);
            if (self.snapshot) |s| allocator.free(s);
            if (self.original_snapshot) |s| allocator.free(s);
            admission.set(false);
        }
        fn note(self: *Self, value: []const u8) void {
            @memset(&self.message, 0);
            @memcpy(self.message[0..@min(value.len, self.message.len - 1)], value[0..@min(value.len, self.message.len - 1)]);
            self.dirty = true;
        }
        fn source(self: *Self, value: Source) !void {
            const visible = switch (value) {
                .aux => |id| self.process.updateAuxReceipt(id) != .released,
                else => true,
            };
            for (self.sources.items, 0..) |old, i| if (std.meta.eql(old, value)) {
                self.visible_sources.items[i] = self.visible_sources.items[i] or visible;
                return;
            };
            try self.sources.ensureUnusedCapacity(allocator, 1);
            try self.visible_sources.ensureUnusedCapacity(allocator, 1);
            self.sources.appendAssumeCapacity(value);
            self.visible_sources.appendAssumeCapacity(visible);
        }
        fn inventory(self: *Self) !void {
            if (self.process.domain.tasks) |tasks| for (0..tasks.manager.count()) |i| if (tasks.manager.progressAt(i)) |p| {
                if (p.state != .succeeded and p.state != .failed and p.state != .cancelled or p.job_cleanup != .released) try self.source(.{ .job = p.job });
            };
            for (self.process.domain.attachments.items) |host| try self.source(.{ .aux = host.window_id });
            for (self.process.domain.sessions.sessions.items) |entry| if (entry.state != .closed) try self.source(.{ .session = entry.handle });
        }
        fn show(self: *Self) !void {
            if (self.view == null) {
                const app = self.process.primary orelse return;
                const nav = Process.navFor(app) orelse return;
                self.view = try View.View.mount(app.cx, nav.settings.?.scope, .{ .context = self, .action = action });
                self.view_window = nav.application_host.?.window_id;
            }
            self.view.?.show();
            self.dirty = true;
        }
        pub fn windowGone(self: *Self, id: identity.WindowId) void {
            if (self.view_window == id) {
                self.view = null;
                self.view_window = null;
            }
        }
        fn action(raw: *anyopaque, a: View.Action) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            switch (a) {
                .release_page => client.zw_update_command(6),
                .cancel => self.cancelInstall(),
                .primary => self.activate() catch |err| {
                    self.note(@errorName(err));
                },
            }
        }
        fn activate(self: *Self) !void {
            switch (self.phase) {
                .confirm => {
                    try self.begin();
                    return;
                },
                .blocked => {
                    for (self.coordinator.work.items) |*work| if (work.receipt == .unknown and work.operation != null) {
                        const original = work.operation.?;
                        const retried = try self.issue(self.sources.items[work.owner - 1]);
                        if (retried != original) return error.CloseOperationChanged;
                        work.receipt = .awaiting;
                    };
                    self.phase = .closing;
                    self.started = now();
                    self.dirty = true;
                    return;
                },
                .idle => {},
                else => return,
            }
            switch (self.status.state) {
                2 => client.zw_update_command(2),
                5, 9, 11 => {
                    char: {
                        var reason: [512]u8 = @splat(0);
                        if (client.zw_update_can_install(&reason, reason.len) == 0) {
                            self.note(std.mem.sliceTo(&reason, 0));
                            break :char;
                        }
                        if (self.process.updateDraftReason()) |reasonText| {
                            self.note(reasonText);
                            return;
                        }
                        try self.inventory();
                        self.confirmation_revision = self.process.updateRevision();
                        self.phase = .confirm;
                        self.dirty = true;
                    }
                },
                else => client.zw_update_command(1),
            }
        }
        fn begin(self: *Self) !void {
            if (self.process.updateDraftReason()) |reason| {
                self.note(reason);
                self.phase = .idle;
                return;
            }
            admission.set(true);
            errdefer admission.set(false);
            if (self.confirmation_revision) |ticket| if (ticket != self.process.updateRevision()) {
                try self.inventory();
                self.confirmation_revision = self.process.updateRevision();
                self.note("工作区已变化，请重新确认");
                admission.set(false);
                return;
            };
            // Revalidate under the admission gate before issuing ANY close.
            const revision = self.process.updateRevision();
            try self.inventory();
            const current = try self.process.updateSnapshot();
            defer allocator.free(current);
            var first: ?[:0]u8 = if (self.original_snapshot == null) try allocator.dupeSentinel(u8, current, 0) else null;
            errdefer if (first) |value| allocator.free(value);
            const saved = blk: {
                if (self.original_snapshot) |original| {
                    var initial = try std.json.parseFromSlice(std.json.Value, allocator, original, .{});
                    defer initial.deinit();
                    var latest = try std.json.parseFromSlice(std.json.Value, allocator, current, .{});
                    defer latest.deinit();
                    try initial.value.object.put(initial.arena.allocator(), "latest", latest.value);
                    const combined = try std.json.Stringify.valueAlloc(allocator, initial.value, .{});
                    defer allocator.free(combined);
                    break :blk try allocator.dupeSentinel(u8, combined, 0);
                }
                break :blk try allocator.dupeSentinel(u8, current, 0);
            };
            errdefer allocator.free(saved);
            if (revision != self.process.updateRevision()) {
                self.phase = .confirm;
                self.note("工作区已变化，请重新确认");
                allocator.free(saved);
                if (first) |value| allocator.free(value);
                admission.set(false);
                return;
            }
            if (client.zw_update_save_snapshot(saved.ptr) == 0) {
                self.phase = .idle;
                self.note("工作区快照保存失败，尚未结束任何任务");
                allocator.free(saved);
                if (first) |value| allocator.free(value);
                admission.set(false);
                return;
            }
            var owners: std.ArrayList(u64) = .empty;
            defer owners.deinit(allocator);
            for (0..self.sources.items.len) |i| try owners.append(allocator, i + 1);
            for (self.coordinator.work.items) |*work| {
                if (work.receipt == .released and self.receipt(self.sources.items[work.owner - 1]) != .released) {
                    work.operation = null;
                    work.receipt = .awaiting;
                }
            }
            try self.coordinator.begin(allocator, owners.items);
            if (first) |value| {
                self.original_snapshot = value;
                first = null;
            }
            if (self.snapshot) |old| allocator.free(old);
            self.snapshot = saved;
            self.coordinator.saved();
            self.phase = .closing;
            self.started = now();
            self.commit_sent = false;
            self.note("");
        }
        fn cancelInstall(self: *Self) void {
            if (self.phase == .committed or self.status.state == 8) return;
            if (self.phase == .handoff or self.phase == .cancel_pending or (self.status.state == 6 or self.status.state == 7)) {
                self.coordinator.cancel();
                self.phase = .cancel_pending;
                client.zw_update_command(5);
                self.note("正在等待安装程序的持久化取消回执…");
                return;
            }
            if (self.status.state == 3 or self.status.state == 4) client.zw_update_command(3);
            const closing = self.coordinator.intent;
            self.coordinator.cancel();
            admission.set(false);
            self.phase = .idle;
            if (closing) self.note("");
            if (self.view) |v| v.hide();
        }
        fn issue(self: *Self, sourceValue: Source) !u64 {
            switch (sourceValue) {
                .job => |job| {
                    try self.process.updateCancelJob(job);
                    return job;
                },
                .aux => |window| {
                    self.process.updateCancelAux(window);
                    return @backingInt(window);
                },
                .session => |handle| {
                    if (self.process.domain.ownerForHandle(handle)) |host| {
                        if (host.legacyForHandle(handle)) |legacy| return (try host.requestCloseLegacy(legacy)).operation_id;
                    }
                    return (try self.process.domain.stopBackgroundOwner(handle)).operation_id;
                },
            }
        }
        fn receipt(self: *Self, sourceValue: Source) close.Receipt {
            return switch (sourceValue) {
                .job => |job| self.process.updateJobReceipt(job),
                .aux => |window| self.process.updateAuxReceipt(window),
                .session => |handle| blk: {
                    const state = self.process.domain.sessions.queryState(handle) orelse break :blk .unknown;
                    break :blk switch (state.lifecycle) {
                        .closed => .released,
                        .cleanup_unknown => .unknown,
                        else => .awaiting,
                    };
                },
            };
        }
        pub fn testRoute(self: *Self, body: []const u8, buffer: []u8) ?[]const u8 {
            const Input = struct { action: []const u8 = "snapshot", theme_name: []const u8 = "sauber" };
            var parsed = std.json.parseFromSlice(Input, allocator, body, .{}) catch return "{\"ok\":false}";
            defer parsed.deinit();
            const command = parsed.value;
            if (std.mem.eql(u8, command.action, "ready")) {
                const Native = struct {
                    extern fn zw_update_test_ready() void;
                };
                Native.zw_update_test_ready();
            }
            if (std.mem.eql(u8, command.action, "open")) client.zw_update_open();
            if (std.mem.eql(u8, command.action, "theme")) {
                self.process.updateTestTheme(command.theme_name) catch return "{\"ok\":false}";
            }
            var writer = std.Io.Writer.fixed(buffer);
            std.json.Stringify.value(.{ .button = if (self.view) |v| .{ .base = v.primary_base.peek().background, .actual = v.primary.getBackground(), .gradient = v.primary.style.gradient(), .variant = v.primary_variant.peek(), .danger = v.danger, .token = theme.current().action_danger } else null, .phase = @tagName(self.phase), .gate = admission.blocked(), .intent = self.coordinator.intent, .batch = self.coordinator.batch, .generation = self.coordinator.generation, .draining = self.coordinator.draining(), .released = self.coordinator.released(), .work = self.coordinator.work.items, .message = std.mem.sliceTo(&self.message, 0) }, .{}, &writer) catch return "{\"ok\":false}";
            return writer.buffered();
        }
        pub fn failed(self: *Self, err: anyerror) void {
            self.note(@errorName(err));
            if (self.phase == .handoff or self.phase == .cancel_pending or self.phase == .committed) return;
            self.coordinator.cancel();
            self.phase = .idle;
            admission.set(false);
        }
        pub fn notifyCloseBlocked(self: *Self) void {
            self.note("请先在更新窗口取消更新，收到取消回执后即可关闭应用。");
            client.zw_update_open();
        }
        pub fn tick(self: *Self) !void {
            client.zw_update_tick();
            client.zw_update_status(&self.status);
            if (!std.meta.eql(self.previous, self.status)) {
                self.previous = self.status;
                self.dirty = true;
            }
            if (client.zw_update_take_present() != 0) try self.show();
            if (self.view_window) |id| if (self.process.domain.ownerForWindow(id) == null) {
                self.view = null;
                self.view_window = null;
            };
            for (self.coordinator.work.items) |work| if (work.operation == null and self.receipt(self.sources.items[work.owner - 1]) == .released) self.coordinator.observeReleased(work.owner);
            // Poll issued operations even after cancellation and before a new plan.
            for (self.coordinator.work.items) |work| if (work.operation) |operation| {
                if (work.receipt != .released) {
                    const receiptValue = self.receipt(self.sources.items[work.owner - 1]);
                    if (receiptValue != work.receipt) {
                        _ = self.coordinator.receive(self.coordinator.batch, work.owner, operation, receiptValue);
                        self.dirty = true;
                    }
                }
            };
            if (self.phase == .closing) {
                if (now() - self.started > 15 * std.time.ns_per_s and self.coordinator.draining() != 0) {
                    self.phase = .blocked;
                    self.note("部分任务尚未确认释放。可继续等待原关闭操作，或取消更新返回工作区。");
                } else if (self.coordinator.next()) |owner| {
                    const op = try self.issue(self.sources.items[owner - 1]);
                    try self.coordinator.issued(owner, op);
                    self.started = now();
                    self.dirty = true;
                } else if (self.coordinator.canPrepare()) {
                    // Final resource inventory: no newly created owner may escape
                    // the frozen plan, including retained/background work.
                    const count = self.sources.items.len;
                    try self.inventory();
                    if (count != self.sources.items.len) {
                        self.coordinator.cancel();
                        self.phase = .idle;
                        admission.set(false);
                        self.note("任务清单发生变化，请重新确认后安装");
                    } else if (self.process.updateFinalReceipt() != .released) {
                        self.phase = .blocked;
                        self.note("仍有后台资源尚未释放，应用未退出。请等待收尾后重试或取消更新。");
                    } else {
                        self.phase = .handoff;
                        const colors = helperColors();
                        client.zw_update_prepare(self.snapshot.?.ptr, &colors);
                        self.dirty = true;
                    }
                }
            }
            if (self.phase == .handoff and self.status.state == 7 and self.coordinator.intent and !self.commit_sent) {
                client.zw_update_command(4);
                self.commit_sent = true;
            }
            if ((self.phase == .handoff or self.phase == .cancel_pending) and self.status.state == 8) {
                self.phase = .committed;
                self.exit = true;
                self.dirty = true;
            }
            if ((self.phase == .cancel_pending or self.phase == .handoff) and self.status.state == 9) {
                self.phase = .idle;
                admission.set(false);
                self.note(self.status.messageText());
            }
            if (self.phase == .handoff and self.status.state == 10) {
                self.coordinator.cancel();
                self.phase = .idle;
                admission.set(false);
                self.note(self.status.messageText());
            }
            if (self.status.state == 11) {
                self.exit = false;
                self.phase = .idle;
                self.coordinator.cancel();
                admission.set(false);
                self.dirty = true;
            }
            if (self.dirty) {
                self.dirty = false;
                try self.render();
            }
        }
        fn render(self: *Self) !void {
            const v = self.view orelse return;
            var details: [2048]u8 = undefined;
            var footer: [128]u8 = undefined;
            var p: View.Presentation = .{ .title = "应用更新", .description = "从官方 GitHub Release 检查新版本", .primary = "检查更新", .show_release = true };
            const custom = std.mem.sliceTo(&self.message, 0);
            var totals: [4]usize = @splat(0);
            var done: [4]usize = @splat(0);
            var pending: [4]usize = @splat(0);
            var unknown: [4]bool = @splat(false);
            var values: [4][96]u8 = undefined;
            var rows: [4]View.Row = undefined;
            var row_count: usize = 0;
            var total: usize = 0;
            var released: usize = 0;
            const task_surface = self.phase == .confirm or self.phase == .closing or self.phase == .blocked or (!self.coordinator.intent and self.coordinator.draining() != 0);
            if (task_surface) {
                for (self.sources.items, 0..) |source_value, index| {
                    if (!self.visible_sources.items[index]) continue;
                    var receipt_value = self.receipt(source_value);
                    var issued = false;
                    for (self.coordinator.work.items) |work| if (work.owner == index + 1) {
                        if (work.operation != null) receipt_value = work.receipt;
                        issued = work.operation != null;
                        break;
                    };
                    if (self.phase == .confirm and self.receipt(source_value) == .released) continue;
                    const category: usize = switch (source_value) {
                        .job => 1,
                        .aux => 2,
                        .session => |handle| blk: {
                            const snapshot = self.process.domain.sessions.queryState(handle) orelse break :blk 3;
                            break :blk if (snapshot.purpose == .interactive and (std.mem.eql(u8, snapshot.protocol_id, "local") or std.mem.eql(u8, snapshot.protocol_id, "ssh"))) 0 else 3;
                        },
                    };
                    totals[category] += 1;
                    total += 1;
                    if (receipt_value == .released) {
                        done[category] += 1;
                        released += 1;
                    } else if (issued) {
                        pending[category] += 1;
                        unknown[category] = unknown[category] or receipt_value == .unknown;
                    }
                }
                for ([_][]const u8{ "终端连接", "文件传输", "AI 与连接测试", "KVM 与后台转发" }, 0..) |label, i| {
                    if (totals[i] == 0) continue;
                    const continuing = totals[i] - done[i] - pending[i];
                    const value = if (self.phase == .confirm) try std.fmt.bufPrint(&values[row_count], "{d} 个", .{totals[i]}) else if (!self.coordinator.intent and pending[i] > 0 and continuing > 0) try std.fmt.bufPrint(&values[row_count], "收尾 {d} / 继续 {d}", .{ pending[i], continuing }) else if (done[i] == totals[i]) try std.fmt.bufPrint(&values[row_count], "已结束 {d}", .{done[i]}) else if (unknown[i]) try std.fmt.bufPrint(&values[row_count], "等待释放 {d}", .{pending[i]}) else if (pending[i] > 0) try std.fmt.bufPrint(&values[row_count], "正在结束 {d}", .{pending[i]}) else if (self.coordinator.intent) try std.fmt.bufPrint(&values[row_count], "等待结束 {d}", .{continuing}) else try std.fmt.bufPrint(&values[row_count], "继续运行 {d}", .{continuing});
                    rows[row_count] = .{ .label = label, .value = value, .tone = if (self.phase == .confirm) .neutral else if (done[i] == totals[i]) .success else if (unknown[i]) .warning else if (pending[i] != 0) .accent else .neutral };
                    row_count += 1;
                }
                p.rows = rows[0..row_count];
            }
            switch (self.phase) {
                .confirm => {
                    p.title = "结束当前工作并安装更新？";
                    p.description = "保存工作区快照后，由 ZeroWork 统一结束以下工作。";
                    p.message = "未完成的传输和 AI 任务将被取消，历史记录会保留。\n已结束的工作不会恢复；断开连接不保证远端命令停止。";
                    p.primary = "结束任务并安装";
                    p.cancel = "取消";
                    p.danger = true;
                    p.show_release = false;
                },
                .closing, .blocked => {
                    p.title = if (self.phase == .blocked) "仍有任务未结束" else "正在结束任务";
                    p.description = if (self.phase == .blocked) "仍在等待资源释放，尚未进入安装阶段。" else "结束完成后，将准备安装更新并重新打开 ZeroWork。";
                    p.message = "取消后不再关闭其他工作，已发出的请求仍会收尾。";
                    p.primary = if (self.phase == .blocked) "继续等待" else "";
                    p.cancel = "取消更新";
                    p.footer = try std.fmt.bufPrint(&footer, "已结束 {d} / {d} 项工作", .{ released, total });
                    p.show_release = false;
                    p.warning = self.phase == .blocked;
                },
                .handoff => {
                    p.title = if (self.commit_sent) "正在确认安装提交" else "正在准备安装";
                    p.description = "工作区快照已保存，全部工作已结束。";
                    p.summary = if (self.commit_sent) "安装程序已就绪，正在确认是否进入安装阶段。\n收到提交回执前，应用不会退出。" else "等待安装程序准备就绪\n此时尚未授权替换应用，仍可取消更新。";
                    p.message = "取消需要安装程序确认，已结束的工作不会恢复。";
                    p.primary = "";
                    p.cancel = "取消更新";
                    p.show_release = false;
                },
                .cancel_pending => {
                    p.title = "正在确认取消更新";
                    p.description = "已发送取消请求，正在等待安装程序确认。";
                    p.summary = "确认取消后，应用将继续运行。\n如果安装提交已生效，将显示安装进度。";
                    p.message = "收到回执前，不会显示“更新已取消”。";
                    p.primary = "";
                    p.cancel = "";
                    p.cancellable = false;
                    p.show_release = false;
                },
                .committed => {
                    p.title = "正在安装更新";
                    p.description = "安装提交已确认，正在退出应用。";
                    p.summary = "独立安装程序会在应用正常退出后替换并验证新版。";
                    p.primary = "";
                    p.cancel = "";
                    p.cancellable = false;
                    p.show_release = false;
                },
                .idle => switch (self.status.state) {
                    1 => {
                        p.title = "正在检查更新";
                        p.description = "正在连接官方 GitHub Release…";
                        p.primary = "";
                    },
                    2 => {
                        p.title = "发现新版本";
                        p.description = try std.fmt.bufPrint(&details, "ZeroWork {s} · Apple Silicon", .{self.status.versionText()});
                        p.summary = self.status.notesText();
                        p.primary = "下载更新";
                    },
                    3 => {
                        p.title = "正在下载更新";
                        p.description = try std.fmt.bufPrint(&details, "已下载 {d:.1} MB / {d:.1} MB", .{ @as(f64, @floatFromInt(self.status.received)) / 1_000_000, @as(f64, @floatFromInt(self.status.expected)) / 1_000_000 });
                        p.summary = "下载完成后将校验完整性、发布签名与应用身份。";
                        p.message = "取消会清除未完成的更新包。";
                        p.primary = "";
                        p.cancel = "取消下载";
                    },
                    4 => {
                        p.title = "正在检查更新包";
                        p.description = "正在检查完整性、发布签名与应用身份。";
                        p.message = "取消会清除未验证的更新包。";
                        p.primary = "";
                        p.cancel = "取消校验";
                    },
                    5, 9, 11 => {
                        p.title = "更新已准备好安装";
                        p.description = try std.fmt.bufPrint(&details, "ZeroWork {s} · 更新包校验通过", .{self.status.versionText()});
                        p.summary = "安装需要退出并重新打开 ZeroWork。\n结束工作前，会先处理草稿并保存工作区快照。";
                        p.primary = "安装并重启";
                        p.cancel = "稍后安装";
                    },
                    10 => {
                        p.title = "更新未完成";
                        p.description = self.status.messageText();
                        p.message = "应用尚未退出。可重试，或从官方发布页下载安装包。";
                        p.primary = "重新检查";
                        p.warning = true;
                    },
                    else => {
                        p.description = self.status.messageText();
                    },
                },
            }
            if (self.phase == .idle and self.coordinator.draining() != 0) {
                p.title = "更新已取消，仍在结束部分工作";
                p.footer = try std.fmt.bufPrint(&footer, "仍有 {d} 项正在收尾", .{self.coordinator.draining()});
                p.description = "已发出的结束请求继续收尾，不会再安装更新。";
                p.summary = "";
                p.message = "其余工作继续运行，已经结束的工作不会恢复。";
                p.primary = "准备再次更新";
                p.cancel = "返回工作区";
                p.show_release = false;
            }
            if (custom.len != 0) p.message = custom;
            try v.update(p);
        }
        fn now() u64 {
            return @intCast(@max(0, @import("../platform/realtime.zig").monotonicNs()));
        }
        fn helperColors() [16]f32 {
            const c = theme.current();
            var result: [16]f32 = undefined;
            for ([_]ui.Color{ c.overlay, c.fg_1, c.fg_2, c.action_accent }, 0..) |color, i| {
                result[i * 4] = @as(f32, @floatFromInt(color.r)) / 255;
                result[i * 4 + 1] = @as(f32, @floatFromInt(color.g)) / 255;
                result[i * 4 + 2] = @as(f32, @floatFromInt(color.b)) / 255;
                result[i * 4 + 3] = @as(f32, @floatFromInt(color.a)) / 255;
            }
            return result;
        }
    };
}
