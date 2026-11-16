const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");

/// V0.7 §3.7 template actions: create/copy/delete write through
/// Controller.setRoleTemplates (validated, dirty-tracked, persisted on save).
const TemplateAction = struct {
    bound: *binding.Binding,
    index: usize,
    copy: bool = false,
    create: bool = false,
    edit: bool = false,
    /// Inline slot editor node (edit mode only). Toggle display on run.
    editor: ?*ui.Node = null,
    /// Slot effort selects (edit mode only), slot order parent..batch.
    effort_signals: ?[5]*ui.Signal(?[]const u8) = null,
    fn run(self: *TemplateAction) void {
        const a = self.bound.controller.allocator;
        const current = self.bound.controller.model.value.ai.child_role_templates;
        // 编辑：切换行内编辑器显示（首次点击由挂载时预建并隐藏）。
        if (self.edit) {
            if (self.editor) |node| {
                node.setDisplay(if (node.style.display == .flex) .none else .flex);
                self.bound.cx.requestRedraw();
            }
            return;
        }
        var next: std.ArrayList(@import("../ai_role_templates.zig").Stored) = .empty;
        if (self.create) {
            next.append(a, .{ .name = "新模板" }) catch return;
        } else if (self.copy) {
            if (self.index >= current.len) return;
            const source = current[self.index];
            const cloned = @import("../ai_role_templates.zig").Stored{ .name = std.fmt.allocPrint(a, "{s} 副本", .{source.name}) catch return, .models = source.models, .efforts = source.efforts };
            next.append(a, cloned) catch return;
        }
        for (current, 0..) |template, position| {
            if (!self.create and !self.copy and position == self.index) continue;
            next.append(a, template) catch return;
        }
        self.bound.controller.setRoleTemplates(next.items) catch {
            next.deinit(a);
            return;
        };
        next.deinit(a);
        // The controller dirty-tracks the edit; 保存 persists it.
    }
    /// 编辑器槽位值写回：读取 effort select 信号并持久化。
    fn commitSlots(self: *TemplateAction) void {
        const a = self.bound.controller.allocator;
        const current = self.bound.controller.model.value.ai.child_role_templates;
        if (self.index >= current.len) return;
        const signals = self.effort_signals orelse return;
        var updated = current[self.index];
        const names = [_][]const u8{ "none", "low", "medium", "high", "xhigh", "max", "ultra" };
        for (signals, 0..) |signal, slot| {
            const text = signal.peek() orelse continue;
            // "inherit"（继承）清除该槽 effort；具名档位写入。
            if (std.mem.eql(u8, text, "inherit")) {
                updated.efforts[slot] = null;
                continue;
            }
            for (names) |name| if (std.mem.eql(u8, text, name)) {
                updated.efforts[slot] = std.meta.stringToEnum(@import("../../ai/provider.zig").Effort, name);
            };
        }
        var next: std.ArrayList(@import("../ai_role_templates.zig").Stored) = .empty;
        defer next.deinit(a);
        for (current, 0..) |template, position| {
            next.append(a, if (position == self.index) updated else template) catch return;
        }
        self.bound.controller.setRoleTemplates(next.items) catch return;
    }
};
const draft = @import("../settings_ai_draft.zig");
const controls = @import("settings_controls.zig");

pub fn matchesProviders(query: []const u8) bool {
    return binding.matches(query, "Provider 模型 API Key 地址 endpoint anthropic OpenAI 兼容 Ollama");
}

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const page = try controls.Page.create(cx, bound, "settings.ai");
    const query = bound.controller.search_query;
    if (matchesProviders(query)) try page.root.appendChild(cx.allocator, try bound.providers(cx));
    if (binding.matches(query, "权限 确认 执行 自动执行 permission_mode")) {
        const section = try page.section("权限", "执行前的默认确认方式", ui.icons.shield, 24, "settings.ai.permissions", null);
        try section.select(.{ .section = "ai", .key = "permission_mode" }, "默认权限模式", "确认后执行：执行命令前确认。自动执行：授权范围内可自动运行命令和工具，包括组内写操作。", &[_]ui.widgets.SelectOption{ .{ .value = "confirm", .label = "确认后执行" }, .{ .value = "auto", .label = "自动执行" } }, null);
    }
    if (binding.matches(query, "运行方式 执行 批处理 交互式 自行判断 每次询问 execution_mode 保留 任务结束 空闲后关闭 保留任务会话 session_retention")) {
        const section = try page.section("运行方式", "全局默认；对话可以单独调整", ui.icons.terminal, 28, "settings.ai.execution", null);
        try section.select(.{ .section = "ai", .key = "execution_mode" }, "默认运行方式", "交互式由助手按任务选择使用当前终端或新建工作会话。", &[_]ui.widgets.SelectOption{
            .{ .value = "auto", .label = "自行判断" },
            .{ .value = "ask", .label = "每次询问" },
            .{ .value = "isolated_exec", .label = "批处理" },
            .{ .value = "interactive", .label = "交互式" },
        }, null);
        try section.select(.{ .section = "ai", .key = "session_retention" }, "任务会话处理", "空闲后关闭、每次询问或保留任务会话。只作用于随后由 AI 创建的资源；已有终端和已创建资源保留原策略。", &[_]ui.widgets.SelectOption{
            .{ .value = "auto_idle", .label = "空闲后关闭" },
            .{ .value = "ask", .label = "每次询问" },
            .{ .value = "keep", .label = "保留任务会话" },
        }, null);
    }
    if (binding.matches(query, "对话 跟进行为 排队 引导 follow_up_mode queue steer")) {
        const section = try page.section("对话", "AI 工作时如何处理新消息", ui.icons.get("messages-square").?, 29, "settings.ai.conversation", null);
        try section.select(.{ .section = "ai", .key = "follow_up_mode" }, "跟进行为", "引导：补充到当前任务。排队：当前任务完成后依次处理。仅影响新发送的消息；⌘⇧Enter 使用另一种行为。", &[_]ui.widgets.SelectOption{
            .{ .value = "steer", .label = "引导", .test_id = "settings.follow_up_mode.steer" },
            .{ .value = "queue", .label = "排队", .test_id = "settings.follow_up_mode.queue" },
        }, null);
    }
    if (binding.matches(query, "子 Agent 默认上下文 独立 继承 复用策略 每次新建 优先复用 模型决定 预算 并发 上限 child_context_mode child_reuse_policy child_max_active child_request_concurrency model_slots")) {
        const section = try page.section("子 Agent", "只用于之后创建的子配置；已有子配置保持原选择", ui.icons.get("messages-square").?, 30, "settings.ai.children", null);
        try section.select(.{ .section = "ai", .key = "child_context_mode" }, "默认上下文", "独立上下文从任务材料开始；继承上下文复制创建时已消费的合法历史。显式创建参数优先。", &[_]ui.widgets.SelectOption{
            .{ .value = "independent", .label = "独立上下文", .test_id = "settings.child_context.independent" },
            .{ .value = "inherit", .label = "继承当前上下文", .test_id = "settings.child_context.inherit" },
        }, null);
        try section.select(.{ .section = "ai", .key = "child_reuse_policy" }, "默认复用策略", "每次新建默认不可自动复用；优先复用会提示模型先列出并选择明确候选；模型决定默认保守，仍需显式设置可复用。宿主不会按名称悄悄替换。", &[_]ui.widgets.SelectOption{
            .{ .value = "new", .label = "每次新建", .test_id = "settings.child_reuse.new" },
            .{ .value = "prefer_reuse", .label = "优先复用", .test_id = "settings.child_reuse.prefer_reuse" },
            .{ .value = "model", .label = "模型决定", .test_id = "settings.child_reuse.model" },
        }, null);
        // V0.7 §2.3: configurable budgets. Defaults keep the V0.4 values;
        // ranges are enforced with localized errors in the settings schema.
        try section.input(.{ .section = "ai", .key = "child_max_active" }, "子任务预算 · 每任务最大活跃数", "1–16。默认 4。只对新根任务生效；16 是内存护栏不可突破。", null);
        try section.input(.{ .section = "ai", .key = "child_request_concurrency" }, "子任务预算 · 每任务并发模型请求", "1–8。默认 2。只对新根任务生效。", null);
        try section.input(.{ .section = "ai", .key = "model_slots" }, "子任务预算 · 进程级模型请求槽", "2–8。默认 4。进程启动时生效。", null);
    }
    if (binding.matches(query, "多智能体 编排 模式 停滞 催父 轮次 swarm swarm_mode_default swarm_stall_minutes swarm_stall_parent_minutes boost_max_rounds")) {
        const section = try page.section("多智能体", "Swarm 编排默认与停滞检测", ui.icons.get("network").?, 31, "settings.ai.swarm", null);
        try section.select(.{ .section = "ai", .key = "swarm_mode_default" }, "会话初始编排模式", "新会话的初始档位。Auto 由宿主按信号+实质自动判定；Swarm 多子并行；Boost 深度攻坚（仅手动进入）。", &[_]ui.widgets.SelectOption{
            .{ .value = "auto", .label = "Auto 自动判定" },
            .{ .value = "swarm", .label = "Swarm 多子并行" },
            .{ .value = "boost", .label = "Boost 深度攻坚" },
        }, null);
        try section.input(.{ .section = "ai", .key = "swarm_stall_minutes" }, "停滞第一级阈值（分钟）", "1–30。默认 3。全部子空闲且板上无新帖达到阈值后唤醒父。", null);
        try section.input(.{ .section = "ai", .key = "swarm_stall_parent_minutes" }, "停滞第二级阈值（分钟）", "1–30。默认 2。父被唤醒后仍无动作达到阈值后面板警示并桌面通知。", null);
        try section.input(.{ .section = "ai", .key = "boost_max_rounds" }, "Boost 轮次上限", "1–8。默认 5。单条实现→挑战→修复链的轮次上限；父可声明更小值。", null);
        // V0.7 §3.7: custom role-template management — interactive rows with
        // copy/delete actions plus a create button. The editor dialog writes
        // through Controller.setRoleTemplates; the built-in 均衡 template is
        // implicit (never listed, never removable).
        const templates = bound.controller.model.value.ai.child_role_templates;
        var title_buffer: [96]u8 = undefined;
        for (templates, 0..) |template, index| {
            const title = try std.fmt.bufPrint(&title_buffer, "模板 {d} · {s}", .{ index + 1, template.name });
            try section.readonly(title, "自定义角色模板；模式菜单中可选择。复制/删除按钮在同一行右侧。");
            const actions = try ui.box(cx, .{ .direction = .row, .gap = 6, .flex_shrink = 0 }, .{});
            actions.meta.ownership.meta.test_id = try std.fmt.bufPrint(&title_buffer, "settings.template.row.{d}", .{index});
            const edit = try ui.widgets.Button(.{ .variant = .ghost, .label = "编辑", .on_click = cx.on(TemplateAction, try bound.scope.createState(TemplateAction, .{ .bound = bound, .index = index, .edit = true }), TemplateAction.run) }).mount(bound.scope, cx);
            edit.meta.ownership.meta.test_id = try std.fmt.bufPrint(&title_buffer, "settings.template.edit.{d}", .{index});
            try actions.appendChild(cx.allocator, edit);
            const copy = try ui.widgets.Button(.{ .variant = .ghost, .label = "复制", .on_click = cx.on(TemplateAction, try bound.scope.createState(TemplateAction, .{ .bound = bound, .index = index, .copy = true }), TemplateAction.run) }).mount(bound.scope, cx);
            copy.meta.ownership.meta.test_id = try std.fmt.bufPrint(&title_buffer, "settings.template.copy.{d}", .{index});
            try actions.appendChild(cx.allocator, copy);
            const del = try ui.widgets.Button(.{ .variant = .ghost, .label = "删除", .on_click = cx.on(TemplateAction, try bound.scope.createState(TemplateAction, .{ .bound = bound, .index = index, .copy = false }), TemplateAction.run) }).mount(bound.scope, cx);
            del.meta.ownership.meta.test_id = try std.fmt.bufPrint(&title_buffer, "settings.template.delete.{d}", .{index});
            try actions.appendChild(cx.allocator, del);
            try section.body.appendChild(cx.allocator, actions);
            // V0.7 §3.7 slot editor: per-slot effort select (planner/
            // verifier/worker/batch; parent 槽仅展示，不可选)。默认"继承"
            // （null）；选择后经 commitSlots 持久化到该模板槽位。
            const edit_state = try bound.scope.createState(TemplateAction, .{ .bound = bound, .index = index, .edit = true });
            const editor = try ui.box(cx, .{ .direction = .column, .gap = 6, .padding = ui.Padding.all(8), .border = .{ .width = 1, .radius = 8 }, .flex_shrink = 0 }, .{});
            editor.meta.ownership.meta.test_id = try std.fmt.bufPrint(&title_buffer, "settings.template.editor.{d}", .{index});
            editor.setDisplay(.none);
            var signals: [5]*ui.Signal(?[]const u8) = undefined;
            const slot_names = [_][]const u8{ "父（继承）", "planner", "verifier", "worker", "batch" };
            for (0..5) |slot| {
                if (slot == 0) {
                    try editor.appendChild(cx.allocator, try ui.textStyled(cx, @import("settings_controls.zig").S.note, "父槽：始终继承当前会话模型"));
                    signals[0] = try bound.scope.createSignal(?[]const u8, null);
                    continue;
                }
                const line = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 }, .{});
                try line.appendChild(cx.allocator, try ui.textStyled(cx, @import("settings_controls.zig").S.note, slot_names[slot]));
                signals[slot] = try bound.scope.createSignal(?[]const u8, null);
                const select = try ui.widgets.Select(.{
                    .options = &[_]ui.widgets.SelectOption{
                        .{ .value = "inherit", .label = "继承" },
                        .{ .value = "none", .label = "关闭" },
                        .{ .value = "low", .label = "低" },
                        .{ .value = "medium", .label = "中" },
                        .{ .value = "high", .label = "高" },
                        .{ .value = "xhigh", .label = "较高" },
                        .{ .value = "max", .label = "最高" },
                    },
                    .placeholder = "继承",
                    .value = ui.Model(?[]const u8){ .controlled = .{ .signal = signals[slot] } },
                    .width = 120,
                }).mount(bound.scope, cx);
                select.trigger.meta.ownership.meta.test_id = try std.fmt.bufPrint(&title_buffer, "settings.template.editor.effort.{d}", .{slot});
                try line.appendChild(cx.allocator, select.wrapper);
                try editor.appendChild(cx.allocator, line);
            }
            edit_state.editor = editor;
            edit_state.effort_signals = signals;
            // 选择即写回（无独立保存按钮——脏标由 controller 管理）：
            // 每个 effort select 变化立即经 commitSlots 持久化。
            for (signals, 0..) |signal, slot| {
                try bound.scope.createEffect(.{ .action = edit_state, .selected = signal }, struct {
                    fn paint(state: anytype) void {
                        _ = state.selected.get();
                        state.action.commitSlots();
                    }
                }.paint);
                _ = slot;
            }
            try section.body.appendChild(cx.allocator, editor);
        }
        if (templates.len == 0) try section.readonly("角色模板", "仅内置「均衡」模板（全部槽继承）。");
        const create = try ui.widgets.Button(.{ .variant = .secondary, .label = "新建模板", .on_click = cx.on(TemplateAction, try bound.scope.createState(TemplateAction, .{ .bound = bound, .index = templates.len, .copy = false, .create = true }), TemplateAction.run) }).mount(bound.scope, cx);
        create.meta.ownership.meta.test_id = "settings.template.create";
        try section.body.appendChild(cx.allocator, create);
    }
        if (binding.matches(query, "上下文 来源 脱敏 隐私 IP 主机 用户 redact_ip")) {
        const section = try page.section("上下文", "连接身份与敏感信息", ui.icons.file_text, 25, "settings.ai.context", null);
        try section.toggle(.{ .section = "ai", .key = "redact_ip" }, "隐藏连接身份", "隐藏 SSH 连接的 IP、主机名和用户名。终端正文与附件仍按原文发送，请检查敏感内容。", null);
    }
    if (binding.matches(query, "附件 图片 本地 文本 文件 引用 attachment")) {
        const section = try page.section("附件", "图片和本地文本的大小限制", ui.icons.paperclip, 26, "settings.ai.attachments", null);
        try section.readonly("图片上限", "最多 4 张 · 单张 10 MB");
        try section.readonly("本地文本上限", "UTF-8 · 64 KiB");
    }
    if (binding.matches(query, "其他行为 默认 Provider 错误 提示 error_hint default_provider 步骤默认显示 步骤 聚合 折叠 展开 step_display")) {
        const section = try page.section("其他行为", "默认服务提供方与错误提示", ui.icons.settings, 27, "settings.ai.behavior", null);
        const options = try bound.scope.allocator.alloc(ui.widgets.SelectOption, bound.controller.model.value.ai.provider_count);
        defer bound.scope.allocator.free(options);
        var count: usize = 0;
        for (bound.controller.model.value.ai.providers[0..bound.controller.model.value.ai.provider_count]) |provider| {
            const text = try controls.owned(bound.scope, draft.providerName(provider));
            options[count] = .{ .value = text, .label = text, .disabled = !provider.enabled or !draft.eligible(provider) };
            count += 1;
        }
        if (count != 0) try section.select(.{ .section = "ai", .key = "default_provider" }, "默认服务提供方", "新对话默认使用的模型服务。", options[0..count], null);
        try section.select(.{ .section = "ai", .key = "step_display" }, "步骤默认显示", "只决定新步骤组的初始状态；已有组和手动收展状态保持不变。", &[_]ui.widgets.SelectOption{ .{ .value = "collapsed", .label = "折叠", .test_id = "settings.step_display.collapsed" }, .{ .value = "expanded", .label = "展开", .test_id = "settings.step_display.expanded" } }, null);
        try section.toggle(.{ .section = "ai", .key = "error_hint" }, "错误轻提示", "命令失败时显示助手入口。", null);
    }
    if (binding.matches(query, "本地技能 技能 SKILL MCP 服务 工具 导入 stdio HTTP 环境变量 请求头")) if (bound.hooks.mount_extensions) |mount| try page.root.appendChild(cx.allocator, try mount(bound.hooks.context, cx, bound.scope));
    return page.finish();
}
