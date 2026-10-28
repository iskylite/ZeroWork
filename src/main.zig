const std = @import("std");
const applog = @import("platform/applog.zig");
pub const application_test_mode = @import("application_options").test_mode;
const ui = @import("ui");
const App = @import("zenit_app").App;
const MultiWindowApp = @import("zenit_app").MultiWindowApp;
const NativeWindowId = @TypeOf(@as(*App, undefined).windowId());
const ProcessWindows = struct {
    runtime: *MultiWindowApp,
    domain: *application_host_mod.Domain,
    io: std.Io,
    data_paths: *const DataPaths,
    data_cleanup_owner: ?*SettingsHost = null,
    data_cleanup_pending: bool = false,
    data_cleanup_exit: bool = false,
    primary: ?*App = null,
    runtime_config: ?*RuntimeConfig = null,
    font_system: ?@FieldType(App, "font_manager") = null,
    pending: std.ArrayList(PendingWindow) = .empty,
    const PendingWindow = struct {
        source: @import("host/session_host.zig").AttachmentTarget,
        connection: application_host_mod.WindowConnection,
    };

    fn queue(self: *ProcessWindows, source: *application_host_mod.ApplicationHost, host_id: ws.HostId) !void {
        var connection = try source.freezeWindowConnection(host_id);
        errdefer connection.deinit();
        try self.pending.append(std.heap.c_allocator, .{ .source = .{ .window_id = source.window_id, .workspace_id = source.workspace_id }, .connection = connection });
    }

    /// Execute between MultiWindowApp ticks: creating a native App while its
    /// windows array is being rendered would invalidate the runtime iterator.
    fn drain(self: *ProcessWindows, registry: *FontRegistry) void {
        while (self.pending.items.len != 0) {
            var pending = self.pending.orderedRemove(0);
            defer pending.connection.deinit();
            self.open(&pending.connection, registry) catch |err| {
                if (self.domain.ownerForTarget(pending.source)) |source| source.workspace.statusFailure(@errorName(err));
                applog.warn(.workspace, "new window: {s}", .{@errorName(err)});
            };
        }
    }

    fn open(self: *ProcessWindows, connection: *const application_host_mod.WindowConnection, registry: *FontRegistry) !void {
        const app = try self.runtime.createWindowWith(.{
            .io = self.io,
            .font = .{ .fallback_families = @import("platform/ui_fonts.zig").families },
            .window = .{ .width = 1440, .height = 900, .min_width = 860, .min_height = 480, .title = "ZeroWork", .titlebar = .custom_inset, .titlebar_height = shell_styles.outer + shell_styles.title_height, .titlebar_drag_right_inset = 150 },
        }, mountUI);
        // A mounted native window still belongs to this request if later
        // attachment/factory validation fails. Close it through its owner at
        // the next runtime boundary instead of leaving an orphan empty view.
        errdefer _ = self.runtime.closeWindow(app.windowId());
        app.win.setTrafficLightsLayout(shell_styles.outer + 20, shell_styles.outer + shell_styles.title_height / 2, 12);
        installMonospaceFonts(app);
        app.setFontRegistry(registry);
        if (application_test_mode) try verifyUiFontPaths(app);
        const nav: *AppNavHost = @ptrCast(@alignCast(app.cx.root.?.behavior.events.capture_context orelse return error.MissingApplicationController));
        nav.app_runtime = app;
        try nav.loadEmptyLogo();
        if (nav.settings) |settings| settings.app_runtime = app;
        _ = @import("ui/plugin_window_host.zig").Host.mount(app, nav.application_host orelse return error.MissingApplicationController, process_notifications, if (nav.ai) |ai| ai.notification_window else null) catch |err| {
            applog.err(.app, "plugin window services initialization: {s}", .{@errorName(err)});
            return err;
        };
        if (nav.ai) |ai| if (ai.images_view) |view| {
            view.app = app;
        };
        app.setCloseRequestHandler(.{ .context = nav, .request = AppNavHost.nativeCloseRequest, .completed = AppNavHost.nativeCloseCompleted });
        const host = nav.application_host orelse return error.MissingApplicationController;
        _ = host.createWindowConnection(connection) catch |err| {
            host.workspace.statusFailure(@errorName(err));
            return err;
        };
        _ = self.runtime.activateWindow(app.windowId());
        applog.info(.workspace, "workspace ready window={d} workspace={d} shared_sessions={d}", .{ @backingInt(host.window_id), @backingInt(host.workspace_id), self.domain.sessions.sessions.items.len });
    }

    fn deinit(self: *ProcessWindows) void {
        for (self.pending.items) |*pending| pending.connection.deinit();
        self.pending.deinit(std.heap.c_allocator);
        if (self.runtime_config) |runtime| cleanupRuntimeConfig(runtime);
        if (self.font_system) |*fonts| fonts.deinit();
    }
};
var process_windows: ?*ProcessWindows = null;
const FontRegistry = @import("zenit_app").FontRegistry;
var app_font_registry: ?*FontRegistry = null;
fn terminalFamilyId(name: []const u8) u16 {
    const registry = app_font_registry orelse return 0;
    return @backingInt(registry.intern(name) catch return 0);
}
fn applyResolvedTerminalTypography(terminal: *TerminalViewNode, setting: @import("config/config.zig").Ui) anyerror!void {
    const registry = app_font_registry orelse return error.FontUnavailable;
    var font = try @import("config/appearance_font.zig").resolve(terminal.cx.allocator, registry, .{ .family = setting.font_family, .size = @floatFromInt(setting.font_size), .weight = setting.font_weight });
    defer font.deinit(terminal.cx.allocator);
    try terminal.setTypographyFamily(setting.font_size, setting.line_height, @backingInt(font.actual_weight), font.actual_family, font.family_id);
}
const ws = @import("ui/workspace.zig");
const quick_connect_mod = @import("ui/quick_connect.zig");
const hosts_mod = @import("config/hosts.zig");
const wizard_mod = @import("ui/wizard.zig");
const remote_editor = @import("plugins/remote/editor_factory.zig");
const transfer_mod = @import("transfer/manager.zig");
const sftp_engine_mod = @import("transfer/sftp_engine.zig");
const transfer_panel_mod = @import("ui/transfer_panel.zig");
const transfer_manager_view = @import("ui/transfer_manager_view.zig");
const transfer_conflict_view = @import("ui/transfer_conflict_view.zig");
const ssh_session = @import("proto/ssh/session.zig");
const socks5_mod = @import("proto/ssh/socks5_listener.zig");
const TerminalViewNode = @import("ui/terminal_view.zig").TerminalViewNode;
const SessionRuntime = @import("host/runtime_service.zig").Runtime;
const QuickConnect = @import("ui/quick_connect.zig").Model;
const RuntimeConfig = @import("config/runtime_config.zig").RuntimeConfig;
const SettingsController = @import("config/settings_controller.zig").Controller;
const settings_content_view = @import("config/settings_content_view.zig");
const DataPaths = @import("config/paths.zig").Paths;
const MenuState = @import("ui/context_menu_state.zig").State;
const MenuTrigger = @import("ui/context_menu_state.zig").Trigger;
const AiController = @import("ai/float_view.zig").Controller;
const AiManager = @import("ai/turn_manager.zig").Manager;
const ai_provider = @import("ai/provider.zig");
const AiClient = @import("ai/provider_client.zig").Client;
const NativeContext = @import("ai/provider_transport.zig").NativeContext;
const ai_provider_config = @import("ai/provider_config.zig");
const ai_attachments = @import("ai/local_text_attachments.zig");
const ai_attachment_request = @import("ai/local_text_request.zig");
const AiAttachmentReader = @import("host/ai_local_text_snapshot.zig").Reader;
const ai_images = @import("ai/image_attachments.zig");
const AiImageReader = @import("host/ai_image_snapshot.zig").Reader;

const Palette = ws.Palette;
const design = @import("ui/design.zig");
const app_theme = @import("ui/app_theme.zig");
const shell_styles = @import("ui/shell_styles.zig");
const session_menu_mod = @import("ui/session_menu.zig");
const application_host_mod = @import("ui/application_host.zig");
const file_application_mod = @import("ui/file_application_host.zig");
const transfer_dispatch_mod = @import("transfer/engine_dispatch.zig");
const retained_store_mod = @import("host/retained_transfer_store.zig");
const retained_runtime_mod = @import("host/file_transfer_runtime.zig");
const task_domain_mod = @import("host/application_task_domain.zig");
const CollapsedSidebar = @import("ui/sidebar_collapsed_view.zig").View;
const HistoryModel = @import("ui/history_list.zig").Model;
const HistoryArchive = @import("vt/session_archive.zig").Archive;
const NotificationHost = @import("host/notification_host.zig").Host;
var process_notifications: ?*NotificationHost = null;

fn cleanupRuntimeConfig(runtime: *RuntimeConfig) void {
    const allocator = runtime.allocator;
    runtime.deinit();
    allocator.destroy(runtime);
}

fn cleanupDataPaths(paths: *DataPaths) void {
    const allocator = paths.allocator;
    paths.deinit();
    allocator.destroy(paths);
}

const AiHost = struct {
    const TerminalIntent = struct {
        tab: @import("host/identity.zig").TabId,
        source: @import("host/identity.zig").SessionHandle,
        assistant_owner: ai_attachments.Owner,
        selection: ?@import("host/terminal_service.zig").Selection,
        legacy_selection: ?struct { range: @import("vt/engine.zig").Selection, source_version: u64 } = null,
        members: [@import("ai/tool_scope.zig").max_targets]@import("host/identity.zig").SessionHandle = undefined,
        member_count: usize = 0,
    };
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    scope: ?*ui.Scope = null,
    focus_return: ?@import("ui/ai_return_focus.zig").Ticket = null,
    toolbar_trigger: ?*ui.Node = null,
    strip: ?*@import("ui/ai_strip_view.zig").View = null,
    dock: @import("ai/dock_state.zig").State = .{},
    reveal: @import("ai/dock_state.zig").Reveal = .{},
    dock_titlebar: ?*ui.Node = null,
    panel_hover: ?*ui.Signal(bool) = null,
    welcome_logo_texture: ?u32 = null,
    sessions_view: ?*@import("ui/ai_sessions_view.zig").View = null,
    display_conversation: ?u64 = null,
    request_conversation: ?u64 = null,
    select_requested: ?u64 = null,
    delete_requested: ?u64 = null,
    new_requested: bool = false,
    list_requested: bool = false,

    controller: AiController,
    manager: AiManager,
    provider: ai_provider.Provider,
    native_context: ?*NativeContext,
    painted_config_revision: u64 = 0,
    native_client: ?*AiClient,
    native_binding: ?*AiClient.Binding,
    endpoint: []const u8,
    model: []const u8,
    panel: *ui.Node,
    status: *ui.Node,
    feedback: ?*ui.Node = null,
    card_node: *ui.Node,
    prompt: *ui.Signal([]const u8),
    textarea: ?*ui.widgets.input.TextareaState = null,
    composer_input: ?ui.widgets.input.TextareaResult = null,
    composer_node: ?*ui.Node = null,
    settings_host: ?*SettingsHost = null,
    settings_request: ?bool = null,
    send_disabled: ?*ui.Signal(bool) = null,
    send_button: ?*ui.Node = null,
    window_base: ?*ui.Signal(@import("ui/ai_assistant_styles.zig").ButtonStyle) = null,
    window_hovers: [3]?*ui.Signal(?@import("ui/ai_assistant_styles.zig").ButtonStyle) = @splat(null),
    window_icons: [3]?*ui.Node = @splat(null),
    session_icons: [2]?*ui.Node = @splat(null),
    send_base: ?*ui.Signal(@import("ui/ai_assistant_styles.zig").ButtonStyle) = null,
    painted_colors: ?app_theme.Colors = null,
    composer_controls: ?*@import("ui/ai_composer_controls_view.zig").View = null,
    attachments_view: ?*@import("ui/ai_attachments_view.zig").View = null,
    attachment_readers: std.ArrayList(*AiAttachmentReader) = .empty,
    attachment_picker_active: bool = false,
    images_view: ?*@import("ui/ai_image_attachments_view.zig").View = null,
    image_readers: std.ArrayList(*AiImageReader) = .empty,
    request_images: ?ai_images.Bundle = null,
    request_image_refs: std.ArrayList(ai_images.ContentRef) = .empty,
    preflight_image_refs: std.ArrayList([]ai_images.ContentRef) = .empty,
    remote_picker: ?*@import("ui/ai_remote_picker.zig").View = null,
    file_application: ?*file_application_mod.Host = null,
    request_attachments: ?ai_attachments.Bundle = null,
    attachment_preview_holder: ?*ui.Node = null,
    attachment_preview_scroll_y: ?f32 = null,
    composer_hash: ?u64 = null,
    gestures: ?*@import("ui/ai_float_gestures.zig").View = null,
    request_effort: ?ai_provider.Effort = null,
    request_thinking: ?bool = null,
    model_discovery: @import("ai/model_discovery.zig").Service = .{},
    request_vision: bool = false,
    request_image_token_reservation: ?u32 = null,
    image_gate: ?anyerror = null,
    stream_mailbox: @import("ai/stream_mailbox.zig").Mailbox,
    step_mailbox: @import("ai/step_events.zig").Mailbox,
    current_turn: @import("ai/conversation_turn.zig").Turn = .{},
    recall_index: ?usize = null,
    recall_draft: ?[]u8 = null,
    message_action: ?MessageAction = null,
    editing_index: ?usize = null,
    edit_text: ?*ui.Signal([]const u8) = null,

    streaming_label: ?*ui.Node = null,
    live_card: ?*ui.Node = null,
    live_scope: ?*ui.Scope = null,
    live_dirty: bool = false,
    tool_bridge: @import("ui/ai_tools.zig").Bridge,
    tool_results: @import("ai/tool_results.zig").Store,
    approval_view: ?*@import("ui/ai_tool_approval_view.zig").View = null,
    request_tools: [ai_provider.max_tool_definitions]ai_provider.ToolDefinition = undefined,
    request_tools_len: usize = 0,

    // ── Async request engine ─────────────────────────────────────────
    // The provider transport is a SYNCHRONOUS HTTP call that can take
    // seconds (mimo flash round-trips ~1-5s). Running it on the UI thread
    // froze every redraw (window drag, typing, terminal output) until the
    // response arrived. The request now runs on a dedicated worker thread
    // with its OWN std.Io.Threaded instance — std.Io is not thread-safe,
    // and the app's io is owned by the UI thread, so the worker gets a
    // private one it uses exclusively. Results cross back via an atomic
    // state flag consumed by a UI-thread after-layout hook (same pattern
    // as Workspace.PollHook): release-store in the worker, acquire-load
    // in the hook establishes the happens-before for the card data.
    ai_io: ?*std.Io.Threaded = null,
    thread_state: std.atomic.Value(u8) = .init(0), // 0 idle · 1 running · 2 done · 3 failed
    request_cancel: ai_provider.CancelToken = .{},
    /// Worker completion state: 4 means the user explicitly stopped the
    /// request.  It is distinct from provider/network failures so the UI
    /// does not present a normal error after pressing the design's stop
    /// control.
    worker_thread: ?std.Thread = null,
    /// Owned copy of the submitted prompt for the worker (controller's
    /// internal buffer would be overwritten by the next keystroke).
    request_text: ?[]u8 = null,
    failure_label: []const u8 = "AI request failed",
    failure_detail: [1400]u8 = undefined,
    request_failure: ?anyerror = null,
    request_stats: ai_provider.ChatStats = .{ .usage_reported = false },
    recovery_failed: bool = false,
    recovery_pending: ?@import("ui/ai_recovery_view.zig").Envelope = null,
    recovery_cooldown_seconds: u64 = 0,
    answer_only: bool = false,
    retry_prefix_count: usize = 0,
    runtime_config: ?*RuntimeConfig = null,
    card_box: ?*ui.Node = null,
    conversation_viewport: ?*ui.Node = null,
    tail_follow: ?@import("ui/ai_tail_follow.zig").Follow = null,
    stop_button: ?*ui.Node = null,
    input_node: ?*ui.Node = null,
    input_placeholder: ?*ui.Node = null,
    request_config: ?@import("config/runtime_config.zig").Snapshot = null,
    request_context: ?@import("ai/assembler.zig").Assembled = null,
    request_session: ?ws.SessionId = null,
    request_owner: ?@import("ai/tool_scope.zig").Owner = null,
    request_content_owner: ?@import("host/identity.zig").ContentOwner = null,
    request_max_output: u32 = 4096,
    notification_window: ?@import("host/notification_host.zig").WindowId = null,
    request_operation_id: ?u64 = null,
    display_owner: ?@import("ai/tool_scope.zig").Owner = null,
    assistant_states: ?@import("ai/assistant_store.zig").Store = null,
    roster: ?*@import("ui/group_model.zig").Roster = null,
    request_history: @import("ai/wire_history.zig").History = .{},
    wire_history: @import("ai/wire_history.zig").History = .{},
    compaction: @import("ai/context_compaction.zig").Service = .{},

    /// 对话流节点（refresh 时整体重建，样式复刻 mockup-ai-float）。
    conversation: ?*ui.Node = null,
    conversation_scope: ?*ui.Scope = null,
    conversation_dirty: bool = false,
    conversation_bubble_width: ?f32 = null,
    /// 最后一轮提交的用户输入（渲染用户气泡；submit 拷贝所有权）。
    last_user_text: ?[]u8 = null,
    last_user_wire: ?[]u8 = null,
    last_user_attachments: ?ai_attachments.Bundle = null,
    last_user_images: ?ai_images.Bundle = null,
    workspace: ?*ws.Workspace = null,
    application_host: ?*application_host_mod.ApplicationHost = null,
    history: std.ArrayList(HistoryMessage) = .empty,
    const MessageAction = struct { kind: enum { rewind, edit, save, cancel, fork }, index: usize };
    const HistoryMessage = @import("ai/assistant_store.zig").Message;

    fn currentScope(self: *AiHost) ?@import("ai/tool_scope.zig").Scope {
        const workspace = self.workspace orelse return null;
        if (workspace.active_group_view) |id| {
            const roster = self.roster orelse return null;
            const group = roster.findById(std.math.cast(u32, id) orelse return null) orelse return null;
            var scope: @import("ai/tool_scope.zig").Scope = .{ .owner = .{ .group = id }, .members = .{} };
            for (group.members.items) |member| {
                for (workspace.tabs.items) |tab| {
                    if (tab.id != member.pane_id or !self.supportsAssistant(tab)) continue;
                    if (scope.members.len == scope.members.ids.len) return null;
                    scope.members.ids[scope.members.len] = @backingInt(tab.content_owner.session.session_id);
                    scope.members.len += 1;
                }
            }
            return if (scope.members.len == 0) null else scope;
        }
        const active = workspace.active_tab orelse return null;
        if (active >= workspace.tabs.items.len) return null;
        const active_tab = workspace.tabs.items[active];
        if (!self.supportsAssistant(active_tab)) return null;
        const id = @backingInt(active_tab.content_owner.session.session_id);
        return .{ .owner = .{ .session = id }, .members = .{ .ids = .{id} ++ @as([15]u64, @splat(0)), .len = 1 } };
    }

    fn supportsAssistant(self: *AiHost, tab: *const ws.SessionTab) bool {
        if (tab.closing or tab.archived or tab.content_owner != .session) return false;
        const host = self.application_host orelse return false;
        const manifest = host.sessions.manifestFor(tab.content_owner.session) orelse return false;
        return manifest.integration.ai or manifest.ai_context != null;
    }

    fn tabForSession(self: *AiHost, session_id: u64) ?*ws.SessionTab {
        const workspace = self.workspace orelse return null;
        for (workspace.tabs.items) |tab| if (tab.content_owner == .session and @backingInt(tab.content_owner.session.session_id) == session_id) return tab;
        return null;
    }

    fn syncOwner(self: *AiHost) !void {
        const scope = self.currentScope() orelse {
            if (self.gestures) |gestures| gestures.cancel();
            self.controller.model.visible = false;
            self.reveal = .{};
            self.panel.setDisplay(.none);
            return;
        };
        const Owner = @import("ai/tool_scope.zig").Owner;
        if (self.assistant_states == null) self.assistant_states = @import("ai/assistant_store.zig").Store.init(self.allocator);
        const selected_id = (try self.assistant_states.?.get(scope.owner)).id;
        if (self.display_owner) |owner| if (Owner.eql(owner, scope.owner) and self.display_conversation == selected_id) return;
        if (self.gestures) |gestures| gestures.cancel();
        if (self.compaction.job != null) self.compaction.cancel();
        const was_visible = self.controller.model.visible;
        if (self.assistant_states == null) self.assistant_states = @import("ai/assistant_store.zig").Store.init(self.allocator);
        const store = &self.assistant_states.?;
        // Reserve the destination before moving any live state. Allocation
        // failure must leave the currently visible conversation intact.
        _ = try store.get(scope.owner);
        if (self.display_owner) |owner| {
            const draft = try self.allocator.dupe(u8, self.prompt.get());
            errdefer self.allocator.free(draft);
            const saved = store.find(self.display_conversation orelse return) orelse return;
            const saved_id = saved.id;
            const selected = saved.selected;
            const listed = saved.listed;
            const phase = saved.phase;
            const closed = saved.closed;
            const controls = saved.controls;
            saved.controls = .{};
            saved.deinit(self.allocator);
            saved.* = .{ .id = saved_id, .selected = selected, .listed = listed, .phase = phase, .closed = closed, .tool_results = self.tool_results, .controls = controls, .owner = owner, .current_turn = self.current_turn, .history = self.history, .wire_history = self.wire_history, .stream = self.controller.stream, .last_user_text = self.last_user_text, .last_user_wire = self.last_user_wire, .last_user_attachments = self.last_user_attachments, .last_user_images = self.last_user_images, .draft = draft, .model = self.controller.model };
            self.tool_results = @import("ai/tool_results.zig").Store.init(self.allocator);
            self.current_turn = .{};
            self.history = .empty;
            self.wire_history = .{};
            self.controller.stream = @import("ai/card_stream.zig").Stream.init(self.allocator);
            self.last_user_text = null;
            self.last_user_wire = null;
            self.last_user_attachments = null;
            self.last_user_images = null;
        }
        const saved = try store.get(scope.owner);
        self.display_conversation = saved.id;
        const loaded_listed = saved.listed;
        const loaded_phase = saved.phase;
        self.tool_results.deinit();
        self.tool_results = saved.tool_results orelse @import("ai/tool_results.zig").Store.init(self.allocator);
        saved.tool_results = null;
        self.current_turn = saved.current_turn;
        self.history = saved.history;
        self.wire_history = saved.wire_history;
        self.controller.stream.deinit();
        self.controller.stream = saved.stream;
        self.last_user_text = saved.last_user_text;
        self.last_user_wire = saved.last_user_wire;
        self.last_user_attachments = saved.last_user_attachments;
        self.last_user_images = saved.last_user_images;
        if (self.images_view) |view| view.dismiss();
        self.controller.model = saved.model;
        self.controller.model.visible = was_visible;
        if (was_visible) self.controller.model.expanded = true;
        self.prompt.set(saved.draft orelse "");
        if (saved.draft) |draft| self.allocator.free(draft);
        const controls = saved.controls;
        saved.* = .{ .id = selected_id, .listed = loaded_listed, .phase = loaded_phase, .controls = controls, .owner = scope.owner, .stream = @import("ai/card_stream.zig").Stream.init(self.allocator) };
        self.setFeedback("");
        self.image_gate = null;
        self.recall_index = null;
        self.editing_index = null;
        self.edit_text = null;
        if (self.recall_draft) |value| self.allocator.free(value);
        self.recall_draft = null;
        self.display_owner = scope.owner;
        self.conversation_dirty = true;
        self.streaming_label = null;
        self.captureTerminalFocus();
        if (self.tail_follow) |*follow| follow.reset();
        self.controller.model.setPrompt(self.last_user_text orelse "");
    }

    fn remoteScope(raw: *anyopaque, owner: ai_attachments.Owner) ?@import("ai/tool_scope.zig").Scope {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const workspace = self.workspace orelse return null;
        var scope: @import("ai/tool_scope.zig").Scope = .{ .owner = owner, .members = .{} };
        switch (owner) {
            .session => |id| {
                const tab = self.tabForSession(id) orelse return null;
                if (tab.closing) return null;
                scope.members.ids[0] = id;
                scope.members.len = 1;
            },
            .group => |id| {
                const roster = self.roster orelse return null;
                for (roster.groups.items) |group| if (group.id == id) {
                    for (group.members.items) |member| if (member.active) {
                        for (workspace.tabs.items) |tab| if (tab.id == member.pane_id and !tab.closing and tab.content_owner == .session) {
                            if (scope.members.len == scope.members.ids.len) return null;
                            scope.members.ids[scope.members.len] = @backingInt(tab.content_owner.session.session_id);
                            scope.members.len += 1;
                        };
                    };
                };
                if (scope.members.len == 0) return null;
            },
        }
        return scope;
    }
    fn remoteEnsure(raw: *anyopaque, source: @import("ui/ai_remote_picker.zig").Source) !@import("host/file_binding_host.zig").Bindings {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const files = self.file_application orelse return error.FileSourceUnavailable;
        const workspace = self.workspace orelse return error.FileSourceUnavailable;
        const tab = self.tabForSession(@backingInt(source.session.session_id)) orelse return error.StaleOwner;
        if (tab.closing or tab.content_owner != .session or !tab.content_owner.session.eql(source.session)) return error.StaleOwner;
        if (workspace.app_config.transfer.dedicated_connection) return files.ensureReadonlySource(source.session);
        const runtime = tab.runtime orelse return error.FileSourceUnavailable;
        const provider = try runtime.workerPtr().readonlyProvider();
        return files.ensureSharedReadonlySource(source.session, provider);
    }
    fn stageRemote(raw: *anyopaque, owner: ai_attachments.Owner, reference: *ai_attachments.ContentRef) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const scope = remoteScope(raw, owner) orelse return error.StaleOwner;
        const content = reference.content() orelse return error.EmptyAttachmentResult;
        if (content.source != .remote_file) return error.InvalidRemoteSource;
        _ = try scope.validate(&.{@backingInt(content.source.remote_file.owner.session_id)});
        const draft = try self.attachmentDraft(owner);
        const ticket = try draft.begin();
        errdefer _ = draft.cancel(ticket);
        try draft.stage(ticket, reference);
        if (self.display_owner) |display| if (display.eql(owner)) {
            if (self.attachments_view) |view| {
                try view.update(draft);
                try view.restoreCandidate(owner);
            }
        };
        self.cx.requestRedraw();
    }
    fn attachRemote(raw: *anyopaque, owner: ai_attachments.Owner, reference: *ai_attachments.ContentRef) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const scope = remoteScope(raw, owner) orelse return error.StaleOwner;
        const content = reference.content() orelse return error.EmptyAttachmentResult;
        if (content.source != .remote_file) return error.InvalidRemoteSource;
        _ = try scope.validate(&.{@backingInt(content.source.remote_file.owner.session_id)});
        const draft = try self.attachmentDraft(owner);
        const ticket = try draft.begin();
        errdefer _ = draft.cancel(ticket);
        try draft.stage(ticket, reference);
        _ = try draft.attach(ticket);
        if (self.display_owner) |display| if (display.eql(owner)) {
            if (self.attachments_view) |view| try view.update(draft);
        };
        self.cx.requestRedraw();
    }
    fn chooseRemoteFile(self: *AiHost, owner: ai_attachments.Owner) !void {
        const scope = remoteScope(self, owner) orelse return error.StaleOwner;
        const files = self.file_application orelse return error.FileSourceUnavailable;
        const domain = self.application_host orelse return error.FileSourceUnavailable;
        if (self.remote_picker == null) {
            const view = try @import("ui/ai_remote_picker.zig").View.mount(self.cx, self.scope orelse return error.MissingAssistantScope, files.file_host orelse return error.FileSourceUnavailable, .{ .context = self, .ensure = remoteEnsure, .live = remoteScope, .stage = stageRemote, .attach = attachRemote });
            const parent = self.attachment_preview_holder orelse return error.MissingAssistantScope;
            // The holder already has 14px outer padding.
            view.root.setStyleInline(self.allocator, .{ .padding = .{} });
            try parent.appendChild(self.allocator, view.root);
            self.remote_picker = view;
        }
        var sources: [16]@import("ui/ai_remote_picker.zig").Source = undefined;
        var directories: [16]?[]u8 = @splat(null);
        defer for (directories) |directory| if (directory) |bytes| self.allocator.free(bytes);
        var count: usize = 0;
        for (scope.members.ids[0..scope.members.len]) |id| {
            const tab = self.tabForSession(id) orelse continue;
            if (tab.content_owner != .session) continue;
            const state = domain.sessions.queryState(tab.content_owner.session) orelse continue;
            const manifest = domain.sessions.manifestFor(state.handle) orelse continue;
            if (!manifest.integration.auxiliary_readonly and domain.sessions.queryService(state.handle, .file_read) == .unsupported) continue;
            if (tab.runtime) |runtime| directories[count] = runtime.workerPtr().copyCwd(self.allocator) catch null;
            sources[count] = .{ .session = state.handle, .name = tab.titleSlice(), .cwd = directories[count] orelse "", .available = state.lifecycle == .attached and !tab.closing };
            count += 1;
        }
        if (self.attachments_view) |view| view.dismiss();
        if (self.images_view) |view| view.dismiss();
        if (self.attachment_preview_holder) |holder| holder.setDisplay(.flex);
        try self.remote_picker.?.open(owner, sources[0..count]);
    }

    fn imageDraft(self: *AiHost, owner: ai_images.Owner) !*ai_images.Draft {
        if (self.assistant_states == null) self.assistant_states = @import("ai/assistant_store.zig").Store.init(self.allocator);
        return self.assistant_states.?.imageDraft(owner);
    }

    fn chooseImage(self: *AiHost, owner: ai_images.Owner) !void {
        if (self.attachment_picker_active) return error.AttachmentPickerBusy;
        const sdk = self.cx.system_sdk orelse return error.NotSupported;
        self.attachment_picker_active = true;
        defer self.attachment_picker_active = false;
        var buffer: [4096]u8 = undefined;
        const path = try sdk.runDialog(.{ .kind = .open_file, .title = "选择图片（最多 4 张，单张 10 MB）" }, &buffer) orelse return;
        try self.addImagePath(owner, path);
    }

    fn addImagePath(self: *AiHost, owner: ai_images.Owner, path: []const u8) !void {
        if (!self.attachmentOwnerExists(owner)) return error.StaleAttachment;
        const draft = try self.imageDraft(owner);
        if (draft.items.items.len >= ai_images.max_count) return error.TooManyImages;
        try @import("host/ai_image_snapshot.zig").preflight(self.cx.io, path, .{});
        const ticket = try draft.begin(path, .{});
        errdefer _ = draft.remove(ticket.id);
        const reader = try AiImageReader.start(self.allocator, ticket, path, .{});
        errdefer reader.deinit();
        reader.conversation = self.display_conversation orelse 0;
        try self.image_readers.append(self.allocator, reader);
        self.promptChanged(self.prompt.get());
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }

    fn pasteImages(self: *AiHost, owner: ai_images.Owner) !void {
        const sdk = self.cx.system_sdk orelse return error.NotSupported;
        const count = try sdk.clipboardImageCount();
        if (count == 0) return error.NoClipboardImage;
        const draft = try self.imageDraft(owner);
        if (count > ai_images.max_count - @min(ai_images.max_count, draft.items.items.len)) return error.TooManyImages;
        // Capture the clipboard once; retries use these owned bytes.
        for (0..count) |index| {
            var image = (try sdk.clipboardGetImageAlloc(self.allocator, index)) orelse return error.NoClipboardImage;
            defer image.deinit(self.allocator);
            const bytes = image.raw_bytes orelse return error.UnsupportedImage;
            var label: [80]u8 = undefined;
            const name = try std.fmt.bufPrint(&label, "粘贴图片-{d}.png", .{index + 1});
            const ticket = try draft.beginBytes(name, bytes, .{});
            errdefer _ = draft.remove(ticket.id);
            const reader = try AiImageReader.startBytes(self.allocator, ticket, name, bytes, .{});
            errdefer reader.deinit();
            reader.conversation = self.display_conversation orelse 0;
            try self.image_readers.append(self.allocator, reader);
        }
        self.promptChanged(self.prompt.get());
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }

    fn pumpImages(self: *AiHost) !void {
        var index: usize = 0;
        while (index < self.image_readers.items.len) {
            const reader = self.image_readers.items[index];
            if (!self.attachmentOwnerExists(reader.ticket.owner)) reader.cancel();
            if (!reader.poll()) {
                index += 1;
                continue;
            }
            const completion = reader.take().?;
            const conversation = reader.conversation;
            reader.deinit();
            _ = self.image_readers.orderedRemove(index);
            const store = if (self.assistant_states) |*v| v else return;
            const draft = store.imageDraftFor(conversation) orelse {
                var result = completion.result catch continue;
                result.release();
                continue;
            };
            var reference = completion.result catch |err| {
                if (err == error.Cancelled) {
                    _ = draft.remove(completion.ticket.id);
                } else {
                    _ = draft.fail(completion.ticket, err);
                }
                continue;
            };
            draft.complete(completion.ticket, &reference) catch |err| {
                if (err != error.StaleAttachment) _ = draft.fail(completion.ticket, err);
            };
        }
        if (self.images_view) |view| {
            try view.update(if (self.display_owner) |owner| try self.imageDraft(owner) else null);
            if (self.attachments_view) |text_view| text_view.external_count = view.count;
        }
        self.promptChanged(self.prompt.get());
        if (self.image_readers.items.len > 0) self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }

    fn cancelImageReaders(self: *AiHost, owner: ?ai_images.Owner) void {
        var index: usize = 0;
        while (index < self.image_readers.items.len) {
            const reader = self.image_readers.items[index];
            if (owner) |selected| if (!reader.ticket.owner.eql(selected)) {
                index += 1;
                continue;
            };
            const ticket = reader.ticket;
            reader.cancel();
            reader.deinit();
            _ = self.image_readers.orderedRemove(index);
            const draft = self.imageDraft(ticket.owner) catch continue;
            _ = draft.remove(ticket.id);
        }
    }

    fn removeImage(raw: *anyopaque, ticket: ai_images.Ticket) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const draft = try self.imageDraft(ticket.owner);
        if (draft.find(ticket) == null) return error.StaleAttachment;
        for (self.image_readers.items) |reader| if (reader.ticket.eql(ticket)) reader.cancel();
        _ = draft.remove(ticket.id);
        if (self.images_view) |view| if (self.display_owner != null and self.display_owner.?.eql(ticket.owner)) try view.update(draft);
        self.promptChanged(self.prompt.get());
        self.cx.requestRedraw();
    }

    fn retryImage(raw: *anyopaque, ticket: ai_images.Ticket) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        if (!self.attachmentOwnerExists(ticket.owner)) return error.StaleAttachment;
        const draft = try self.imageDraft(ticket.owner);
        const next = try draft.retry(ticket);
        errdefer _ = draft.fail(next, error.ImageReadFailed);
        const item = draft.find(next).?;
        const reader = if (item.source_bytes) |bytes| try AiImageReader.startBytes(self.allocator, next, item.path, bytes, item.limits) else try AiImageReader.start(self.allocator, next, item.path, item.limits);
        errdefer reader.deinit();
        reader.conversation = self.display_conversation orelse 0;
        try self.image_readers.append(self.allocator, reader);
        self.promptChanged(self.prompt.get());
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }

    fn textPreviewVisibility(raw: *anyopaque, visible: bool) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        if (visible) if (self.images_view) |view| view.dismiss();
        attachmentPreviewVisibility(raw, visible);
    }

    fn imagePreviewVisibility(raw: *anyopaque, visible: bool) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        if (visible) {
            if (self.attachments_view) |view| view.dismiss();
            if (self.remote_picker) |picker| picker.close();
        }
        attachmentPreviewVisibility(raw, visible);
    }

    fn previewSentImage(raw: *anyopaque, reference: ai_images.ContentRef) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const view = self.images_view orelse return error.MissingAssistantScope;
        try view.openSentPreview(reference);
    }

    fn appendSentImages(self: *AiHost, parent: *ui.Node, bundle: *const ai_images.Bundle) !void {
        if (bundle.items.len == 0) return;
        if (self.conversation_scope == null) self.conversation_scope = try (self.scope orelse return error.MissingAssistantScope).childScope();
        const view = try @import("ui/ai_image_attachments_view.zig").View.mount(self.cx, self.conversation_scope.?, .{ .context = self, .preview_sent = previewSentImage, .on_error = attachmentViewError }, self.attachment_preview_holder.?);
        if (self.images_view) |draft_view| view.app = draft_view.app;
        try view.updateSent(bundle);
        try parent.appendChild(self.allocator, view.root);
    }

    fn borrowImageRefs(self: *AiHost, bundle: ?ai_images.Bundle) ![]const ai_images.ContentRef {
        const value = bundle orelse return &.{};
        if (value.items.len == 0) return &.{};
        const refs = try self.allocator.alloc(ai_images.ContentRef, value.items.len);
        errdefer self.allocator.free(refs);
        for (value.items, refs) |item, *ref| ref.* = item.reference;
        try self.preflight_image_refs.append(self.allocator, refs);
        return refs;
    }
    fn clearPreflightImageRefs(self: *AiHost) void {
        for (self.preflight_image_refs.items) |refs| self.allocator.free(refs);
        self.preflight_image_refs.clearRetainingCapacity();
    }

    fn attachmentDraft(self: *AiHost, owner: ai_attachments.Owner) !*ai_attachments.Draft {
        if (self.assistant_states == null) self.assistant_states = @import("ai/assistant_store.zig").Store.init(self.allocator);
        return self.assistant_states.?.attachmentDraft(owner);
    }

    /// Explicit menu intent: the pane, assistant domain and selected anchors
    /// were frozen before opening the menu. Never submit or retarget tools.
    fn openTerminalSelection(self: *AiHost, intent: TerminalIntent) !void {
        const workspace = self.workspace orelse return error.MissingAssistantOwner;
        const index = workspace.tabIndexById(intent.tab) orelse return error.StaleOwner;
        const tab = workspace.tabs.items[index];
        if (tab.closing or !tab.content_owner.eql(.{ .session = intent.source }) or tab.terminal == null) return error.StaleOwner;
        const surface = tab.terminal.?.terminal_surface;
        if (surface) |current| if (!current.owner.eql(intent.source)) return error.StaleOwner;
        switch (intent.assistant_owner) {
            .session => |id| if (id != @backingInt(intent.source.session_id)) return error.StaleOwner,
            .group => |id| {
                if (workspace.active_group_view == null or @as(u64, workspace.active_group_view.?) != id) return error.StaleAssistantOwner;
                const current = self.currentScope() orelse return error.StaleAssistantOwner;
                if (!current.owner.eql(intent.assistant_owner)) return error.StaleAssistantOwner;
                _ = try current.validate(&.{@backingInt(intent.source.session_id)});
                if (current.members.len != intent.member_count) return error.StaleAssistantOwner;
                for (intent.members[0..intent.member_count]) |member| {
                    _ = try current.validate(&.{@backingInt(member.session_id)});
                    const original = self.tabForSession(@backingInt(member.session_id)) orelse return error.StaleAssistantOwner;
                    if (original.closing or original.content_owner != .session or !original.content_owner.session.eql(member)) return error.StaleAssistantOwner;
                }
            },
        }
        var reference: ai_attachments.ContentRef = .{};
        defer reference.release();
        if (intent.selection) |selected| {
            const reader = @import("host/ai_terminal_selection.zig");
            var captured = try reader.capture(self.allocator, (surface orelse return error.StaleOwner).service, intent.source, selected, reader.max_service_bytes);
            defer captured.deinit();
            reference = try @import("ai/terminal_text_attachments.zig").createSelection(self.allocator, .{ .owner = captured.owner, .source_name = tab.titleSlice(), .source_version = captured.source_version, .selected_rows = captured.selected_rows, .selection = captured.selection }, captured.bytes, @import("platform/realtime.zig").milliseconds(self));
        }
        if (intent.legacy_selection) |selected| {
            if (surface != null or tab.terminal.?.history.selected != null) return error.StaleSelection;
            var captured = try tab.terminal.?.captureOwnedSelection(self.allocator, intent.source, selected.range, selected.source_version);
            defer captured.deinit();
            reference = try @import("ai/terminal_text_attachments.zig").createSelection(self.allocator, .{ .owner = captured.owner, .source_name = tab.titleSlice(), .source_version = captured.source_version, .selected_rows = captured.selected_rows, .selection = captured.selection, .legacy_range = selected.range }, captured.bytes, @import("platform/realtime.zig").milliseconds(self));
        }
        if (intent.assistant_owner == .session and (workspace.active_tab != index or workspace.active_group_view != null)) workspace.selectTab(index);
        try self.syncOwner();
        const owner = self.display_owner orelse return error.MissingAssistantOwner;
        if (!owner.eql(intent.assistant_owner)) return error.StaleAssistantOwner;
        self.captureTerminalFocus();
        self.controller.model.visible = true;
        self.controller.model.expanded = true;
        self.refresh("AI 助手");
        if (reference.content() != null) {
            const draft = try self.attachmentDraft(owner);
            const ticket = try draft.beginTerminal(intent.source);
            errdefer _ = draft.cancel(ticket);
            try draft.stage(ticket, &reference);
            if (self.attachments_view) |view| try view.update(draft);
            self.promptChanged(self.prompt.get());
        } else if (self.input_node) |input| self.cx.setFocus(input);
        self.cx.requestRedraw();
    }

    fn chooseLocalText(self: *AiHost, owner: ai_attachments.Owner, replacement: ?ai_attachments.Ticket) !void {
        if (self.attachment_picker_active) return error.AttachmentPickerBusy;
        const sdk = self.cx.system_sdk orelse return error.NotSupported;
        const draft = try self.attachmentDraft(owner);
        const ticket = try draft.begin();
        errdefer _ = draft.cancel(ticket);
        self.attachment_picker_active = true;
        defer self.attachment_picker_active = false;
        var buffer: [4096]u8 = undefined;
        const path = try sdk.runDialog(.{ .kind = .open_file, .title = "选择本地文本" }, &buffer) orelse {
            _ = draft.cancel(ticket);
            self.promptChanged(self.prompt.get());
            return;
        };
        if (!draft.contains(ticket) or !self.attachmentOwnerExists(owner)) return error.StaleAttachment;
        const reader = try AiAttachmentReader.start(self.allocator, ticket, path);
        errdefer reader.deinit();
        reader.replaces = replacement;
        reader.conversation = self.display_conversation orelse 0;
        try self.attachment_readers.append(self.allocator, reader);
        self.promptChanged(self.prompt.get());
        if (self.display_owner) |display| if (display.eql(owner)) self.refresh("正在读取本地文本…");
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }

    fn attachmentOwnerExists(self: *AiHost, owner: ai_attachments.Owner) bool {
        return switch (owner) {
            .session => |id| self.tabForSession(id) != null,
            .group => |id| blk: {
                const roster = self.roster orelse break :blk false;
                const workspace = self.workspace orelse break :blk false;
                for (roster.groups.items) |group| if (group.id == id) {
                    for (group.members.items) |member| if (member.active) {
                        for (workspace.tabs.items) |tab| if (tab.id == member.pane_id and tab.terminal != null) break :blk true;
                    };
                    break :blk false;
                };
                break :blk false;
            },
        };
    }

    fn cancelAttachmentReaders(self: *AiHost, owner: ?ai_attachments.Owner) void {
        var index: usize = 0;
        while (index < self.attachment_readers.items.len) {
            const reader = self.attachment_readers.items[index];
            if (owner) |selected| if (!reader.ticket.owner.eql(selected)) {
                index += 1;
                continue;
            };
            const ticket = reader.ticket;
            reader.cancel();
            reader.deinit();
            _ = self.attachment_readers.orderedRemove(index);
            if (self.assistant_states) |*store| {
                const draft = store.attachmentDraft(ticket.owner) catch continue;
                _ = draft.cancel(ticket);
            }
        }
    }

    fn pumpAttachments(self: *AiHost) !void {
        var index: usize = 0;
        while (index < self.attachment_readers.items.len) {
            const reader = self.attachment_readers.items[index];
            if (!self.attachmentOwnerExists(reader.ticket.owner)) reader.cancel();
            if (!reader.poll()) {
                index += 1;
                continue;
            }
            const completion = reader.take().?;
            const replacement = reader.replaces;
            const conversation = reader.conversation;
            reader.deinit();
            _ = self.attachment_readers.orderedRemove(index);
            const store = if (self.assistant_states) |*v| v else return;
            const draft = store.attachmentDraftFor(conversation) orelse {
                var result = completion.result catch continue;
                result.release();
                continue;
            };
            var reference = completion.result catch {
                _ = draft.cancel(completion.ticket);
                continue;
            };
            const byte_count = reference.content().?.bytes.len;
            draft.stageReplacing(completion.ticket, &reference, replacement) catch |err| {
                _ = draft.cancel(completion.ticket);
                if (err != error.StaleAttachment) self.attachmentFailure(completion.ticket, err);
                continue;
            };
            @import("ai/tool_trace.zig").emit(.{ .event = "attachment_preview_ready", .owner = completion.ticket.owner, .draft_epoch = completion.ticket.draft_epoch, .attachment_id = completion.ticket.id, .bytes = byte_count });
            if (self.display_owner) |display| if (display.eql(completion.ticket.owner)) self.refresh("AI 助手");
        }
        if (self.attachments_view) |view| {
            try view.update(if (self.display_owner) |owner| try self.attachmentDraft(owner) else null);
        }
        self.promptChanged(self.prompt.get());
        if (self.attachment_readers.items.len > 0) self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }

    fn attachmentFailure(self: *AiHost, ticket: ai_attachments.Ticket, err: anyerror) void {
        const owner = self.display_owner orelse return;
        if (!owner.eql(ticket.owner)) return;
        const draft = self.attachmentDraft(owner) catch return;
        if (draft.epoch != ticket.draft_epoch) return;
        self.refresh(switch (err) {
            error.LocalTextTooLarge => "文本超过 64 KiB，请选择其他文件",
            error.BinaryLocalText => "此文件不是受支持的文本格式",
            error.InvalidLocalTextEncoding => "文本需要使用 UTF-8 编码",
            error.AccessDenied, error.PermissionDenied => "没有权限读取所选文件",
            error.LocalTextSourceChanged => "文件在读取期间发生变化，请重新选择",
            error.OutOfMemory => "内存不足，未添加附件",
            else => @errorName(err),
        });
    }

    fn removeAttachment(raw: *anyopaque, ticket: ai_attachments.Ticket) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const draft = try self.attachmentDraft(ticket.owner);
        if (draft.epoch != ticket.draft_epoch) return error.StaleAttachment;
        for (self.attachment_readers.items) |reader| if (reader.ticket.eql(ticket)) reader.cancel();
        if (!draft.remove(ticket.id)) return error.StaleAttachment;
        if (self.attachments_view) |view| if (self.display_owner != null and self.display_owner.?.eql(ticket.owner)) try view.update(draft);
        self.promptChanged(self.prompt.get());
        self.cx.requestRedraw();
    }

    fn attachAttachment(raw: *anyopaque, ticket: ai_attachments.Ticket) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        if (!self.attachmentOwnerExists(ticket.owner)) return error.StaleAttachment;
        const draft = try self.attachmentDraft(ticket.owner);
        _ = try draft.attach(ticket);
        if (self.attachments_view) |view| if (self.display_owner != null and self.display_owner.?.eql(ticket.owner)) try view.update(draft);
        self.promptChanged(self.prompt.get());
        self.cx.requestRedraw();
    }

    fn reselectAttachment(raw: *anyopaque, ticket: ai_attachments.Ticket) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        if (!self.attachmentOwnerExists(ticket.owner)) return error.StaleAttachment;
        const draft = try self.attachmentDraft(ticket.owner);
        if (draft.epoch != ticket.draft_epoch) return error.StaleAttachment;
        if (draft.candidate(ticket) == null) {
            var found = false;
            for (draft.items.items) |item| if (item.id == ticket.id) {
                found = true;
                break;
            };
            if (!found) return error.StaleAttachment;
        }
        try self.chooseLocalText(ticket.owner, ticket);
    }

    fn attachmentViewError(raw: *anyopaque, err: anyerror) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        self.refresh(@errorName(err));
    }

    fn previewSentAttachment(raw: *anyopaque, ticket: ai_attachments.Ticket, reference: ai_attachments.ContentRef) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const owner = self.display_owner orelse return error.StaleAttachment;
        if (!owner.eql(ticket.owner)) return error.StaleAttachment;
        const view = self.attachments_view orelse return error.MissingAssistantScope;
        try view.openSentPreview(ticket, reference);
    }

    fn attachmentPreviewVisibility(raw: *anyopaque, visible: bool) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        if (self.attachment_preview_holder) |holder| holder.setDisplay(if (visible) .flex else .none);
        if (self.conversation) |conversation| conversation.setDisplay(if (visible) .none else .flex);
        if (self.tail_follow) |*follow| {
            if (visible) {
                if (self.attachment_preview_scroll_y == null) self.attachment_preview_scroll_y = follow.scroll.state.scroll_y;
                ui.widgets.scroll_area.setScrollY(follow.scroll.state, follow.scroll.content, 0);
            } else if (self.attachment_preview_scroll_y) |offset| {
                ui.widgets.scroll_area.setScrollY(follow.scroll.state, follow.scroll.content, offset);
                self.attachment_preview_scroll_y = null;
            }
        }
        self.cx.requestRedraw();
    }

    fn attachmentPreviewEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *AiHost = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event == .mouse_down) self.dock.pin();
        switch (event) {
            .key_down => |key| if (key.key == .escape) {
                if (self.textarea) |textarea| if (textarea.imeIsComposing()) return .ignored;
                if (self.attachments_view) |view| if (view.escapePreview()) return .stop;
                if (self.images_view) |view| if (view.escapePreview()) return .stop;
            },
            else => {},
        }
        return .ignored;
    }

    fn archiveCommandError(raw: ?*anyopaque, hint: @import("ai/command_error_hint.zig").Hint, preview: []const u8) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw orelse return));
        const notifications = process_notifications orelse return;
        const window = self.notification_window orelse return;
        var command_length = @min(hint.command.len, 3072);
        while (!std.unicode.utf8ValidateSlice(hint.command[0..command_length])) command_length -= 1;
        const detail = try std.fmt.allocPrint(self.allocator, "命令  {s}\n输出  {s}\n退出码 {d}", .{ hint.command[0..command_length], preview, hint.exit_code });
        defer self.allocator.free(detail);
        var owner_name: []const u8 = "会话";
        if (self.workspace) |workspace| for (workspace.tabs.items) |tab| {
            if (tab.content_owner.eql(.{ .session = hint.owner })) {
                owner_name = tab.titleSlice();
                break;
            }
        };
        _ = try notifications.publish(.{ .owner_name = owner_name, .definition_id = "host.command_error", .owner = .{ .window_id = @backingInt(window), .content = .{ .session = hint.owner } }, .operation_id = hint.command_id, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "命令执行失败", .detail = detail, .actions = &.{.{ .kind = .locate_owner, .label = "查看会话" }} });
    }

    fn openCommandError(raw: ?*anyopaque, hint: @import("ai/command_error_hint.zig").Hint) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw orelse return error.MissingAssistantOwner));
        const workspace = self.workspace orelse return error.MissingAssistantOwner;
        var source_index: ?usize = null;
        for (workspace.tabs.items, 0..) |tab, index| if (tab.content_owner.eql(.{ .session = hint.owner }) and !tab.closing and tab.terminal != null) {
            source_index = index;
            break;
        };
        const index = source_index orelse return error.StaleCommandHint;
        const terminal = &workspace.tabs.items[index].terminal.?;
        const surface = terminal.terminal_surface orelse return error.StaleCommandHint;
        if (!surface.owner.eql(hint.owner)) return error.StaleCommandHint;
        const original = terminal.commandErrorHint(hint.owner, hint.command_id) orelse return error.StaleCommandHint;
        if (original.end_sequence != hint.end_sequence or original.exit_code != hint.exit_code) return error.StaleCommandHint;
        const owner: ai_attachments.Owner = .{ .session = @backingInt(hint.owner.session_id) };
        if (self.assistant_states == null) self.assistant_states = @import("ai/assistant_store.zig").Store.init(self.allocator);
        const saved = try self.assistant_states.?.get(owner);
        const existing = if (self.display_owner != null and self.display_owner.?.eql(owner)) self.prompt.get() else saved.draft orelse "";
        const question = try @import("ai/command_error_hint.zig").question(self.allocator, existing, original);
        defer self.allocator.free(question);
        // The explicit hint click opens its original session. Provider work is
        // untouched, and the captured command/context become only a draft.
        workspace.selectTab(index);
        try self.syncOwner();
        if (self.display_owner == null or !self.display_owner.?.eql(owner)) return error.StaleCommandHint;
        self.captureTerminalFocus();
        self.prompt.set(question);
        self.controller.model.visible = true;
        self.controller.model.expanded = true;
        self.refresh("AI 助手");
        if (self.input_node) |input| self.cx.setFocus(input);
    }

    fn selectedControls(self: *AiHost) !*@import("ai/assistant_store.zig").Controls {
        const owner = self.display_owner orelse return error.MissingAssistantOwner;
        const store = if (self.assistant_states) |*value| value else return error.MissingAssistantOwner;
        return &(try store.get(owner)).controls;
    }

    fn effectiveAi(self: *const AiHost) @import("config/config.zig").Ai {
        const runtime = self.runtime_config orelse return .{};
        return self.model_discovery.effective(runtime.value.ai, runtime.value.config_revision);
    }
    fn controlsRevision(self: *const AiHost) u64 {
        const runtime = self.runtime_config orelse return 1;
        return runtime.value.config_revision *% 1000000 +% self.model_discovery.generation;
    }

    fn composerAction(raw: *anyopaque, envelope: @import("ui/ai_composer_controls_view.zig").Envelope) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const scope = self.currentScope() orelse return error.MissingAssistantOwner;
        const runtime = self.runtime_config orelse return error.MissingConfiguration;
        if (!scope.owner.eql(envelope.owner) or envelope.revision != self.controlsRevision()) return error.StaleAssistantControls;
        try self.syncOwner();
        const controls = try self.selectedControls();
        switch (envelope.action) {
            .compact_context => {
                if (self.thread_state.load(.acquire) != 0) return error.AssistantBusy;
                const selected = try ai_provider_config.fromSettingsSelection(self.effectiveAi(), controls.model);
                const reserve = (if (self.request_context) |context| context.tokens else @as(usize, 0)) + self.request_tools_len * 256 + (self.prompt.peek().len + 3) / 4;
                try self.compaction.startReserved(selected, self.compactionIdentity() orelse return error.MissingAssistantOwner, &self.wire_history, reserve);
                self.conversation_dirty = true;
                self.cx.scheduleRedrawAfterNs(33 * 1000000);
            },
            .cancel_compaction => {
                self.compaction.cancel();
                self.conversation_dirty = true;
            },
            .model => |key| {
                const selection: ai_provider_config.ModelSelection = .{ .provider_id = key.provider_id, .model_id = key.model_id };
                _ = try ai_provider_config.fromSettingsSelection(self.effectiveAi(), selection);
                try controls.setModel(self.allocator, selection);
                if (self.compaction.job != null) self.compaction.cancel();
                controls.effort = null;
                controls.thinking = null;
            },
            .permission => |value| controls.permission = value,
            .effort => |value| {
                const key: ai_provider_config.ModelSelection = .{ .provider_id = value.model.provider_id, .model_id = value.model.model_id };
                const selected = try ai_provider_config.fromSettingsSelection(self.effectiveAi(), controls.model);
                if (!std.mem.eql(u8, key.model_id, selected.model)) return error.StaleAssistantControls;
                if (controls.model) |current| {
                    if (!current.eql(key)) return error.StaleAssistantControls;
                } else if (!std.mem.eql(u8, key.provider_id, runtime.value.ai.default_provider)) return error.StaleAssistantControls;
                try ai_provider_config.validateEffort(self.effectiveAi(), key, value.value);
                controls.effort = value.value;
                if (try ai_provider_config.supportsThinking(self.effectiveAi(), key)) controls.thinking = true;
            },
            .thinking => |value| {
                const key: ai_provider_config.ModelSelection = .{ .provider_id = value.model.provider_id, .model_id = value.model.model_id };
                const selected = try ai_provider_config.fromSettingsSelection(self.effectiveAi(), controls.model);
                if (!std.mem.eql(u8, selected.model, key.model_id)) return error.StaleAssistantControls;
                if (controls.model) |current| {
                    if (!current.eql(key)) return error.StaleAssistantControls;
                } else if (!std.mem.eql(u8, key.provider_id, runtime.value.ai.default_provider)) return error.StaleAssistantControls;
                if (!try ai_provider_config.supportsThinking(self.effectiveAi(), key)) return error.UnsupportedThinking;
                controls.thinking = value.enabled;
                if (!value.enabled) controls.effort = null;
            },
            .attachment => |kind| switch (kind) {
                .image => try self.chooseImage(envelope.owner),
                .paste_image => try self.pasteImages(envelope.owner),
                .local_text => try self.chooseLocalText(envelope.owner, null),
                .remote_file => try self.chooseRemoteFile(envelope.owner),
            },
        }
        self.composer_hash = null;
        self.cx.requestRedraw();
    }

    fn compactionIdentity(self: *AiHost) ?@import("ai/context_compaction.zig").Identity {
        const scope = self.currentScope() orelse return null;
        const owner = self.display_owner orelse return null;
        if (!scope.owner.eql(owner)) return null;
        var generation = std.hash.Wyhash.init(0);
        for (scope.members.ids[0..scope.members.len]) |session| {
            const tab = self.tabForSession(session) orelse return null;
            std.hash.autoHash(&generation, tab.content_owner);
        }
        return .{ .owner = owner, .conversation = self.display_conversation orelse return null, .revision = self.controlsRevision(), .scope_generation = generation.final() };
    }

    fn refreshComposer(self: *AiHost) !void {
        if (self.compaction.poll(self.allocator, self.compactionIdentity(), &self.wire_history, self.thread_state.load(.acquire) != 0)) {
            self.composer_hash = null;
            self.conversation_dirty = true;
        }
        if (self.compaction.job != null) self.cx.scheduleRedrawAfterNs(33 * 1000000);
        const view = self.composer_controls orelse return;
        const runtime = self.runtime_config orelse return;
        const owner = self.display_owner orelse {
            try view.update(null);
            self.composer_hash = null;
            return;
        };
        const controls = try self.selectedControls();
        var config = runtime.value;
        if (self.native_binding != null) {
            if (try self.model_discovery.poll(config.ai, config.config_revision, @intCast(wallClockMsTransfer() / 1000))) {
                self.composer_hash = null;
                // Discovery can make a configured model ready without a saved
                // config revision. Rebuild the welcome state at the safe point too.
                self.conversation_dirty = true;
            }
            self.cx.scheduleRedrawAfterNs(if (self.model_discovery.busy()) 33 * 1000000 else @as(u64, @import("ai/model_catalog.zig").refresh_seconds) * 1000000000);
        }
        config.ai = self.effectiveAi();
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, owner);
        std.hash.autoHash(&hash, config.config_revision);
        std.hash.autoHash(&hash, self.thread_state.load(.acquire) == 1);
        std.hash.autoHash(&hash, controls.permission);
        std.hash.autoHash(&hash, controls.effort);
        std.hash.autoHash(&hash, controls.thinking);
        std.hash.autoHash(&hash, self.model_discovery.generation);
        if (controls.model) |key| {
            hash.update(key.provider_id);
            hash.update(key.model_id);
        }
        const selected = ai_provider_config.fromSettingsSelection(config.ai, controls.model) catch null;
        var context_tokens: u64 = 0;
        if (self.requestDisplayed()) {
            if (self.request_context) |context| context_tokens = context.tokens;
        }
        var history_bytes: usize = 0;
        for (self.wire_history.messages) |message| {
            history_bytes += message.content.len;
            for (message.tool_calls) |call| history_bytes += call.name.len + call.arguments.len;
        }
        var response_bytes: usize = 0;
        if (self.thread_state.load(.acquire) != 0) for (self.controller.stream.cards.items) |card| {
            response_bytes += switch (card) {
                .text => |text| text.len,
                .code => |code| code.body.len,
                else => 0,
            };
        };
        const compact_status = if (self.compaction.status_identity != null and self.compactionIdentity() != null and self.compaction.status_identity.?.eql(self.compactionIdentity().?)) self.compaction.status else .idle;
        const can_compact = self.thread_state.load(.acquire) == 0 and self.compaction.job == null and @import("ai/context_compaction.zig").cutoff(self.wire_history.messages) != null;
        std.hash.autoHash(&hash, compact_status);
        std.hash.autoHash(&hash, can_compact);
        const history_tokens = if (selected) |model_config| ai_attachment_request.inputTokens(model_config.chatRequest(.{ .model = model_config.model, .system = "", .messages = self.wire_history.messages, .tool_images = model_config.vision })) catch ((history_bytes + 3) / 4) else (history_bytes + 3) / 4;
        const parts = [_]@import("ui/ai_composer_controls_view.zig").UsagePart{
            .{ .name = "终端上下文", .tokens = context_tokens },
            .{ .name = "对话", .tokens = history_tokens + (response_bytes + 3) / 4 },
            .{ .name = "草稿", .tokens = (self.prompt.peek().len + 3) / 4 },
        };
        const used = parts[0].tokens + parts[1].tokens + parts[2].tokens;
        std.hash.autoHash(&hash, used);
        std.hash.autoHash(&hash, context_tokens);
        const fingerprint = hash.final();
        if (self.composer_hash == fingerprint) return;
        const usage: ?@import("ui/ai_composer_controls_view.zig").Usage = if (selected) |model_config| .{ .used_tokens = used, .limit_tokens = model_config.context_window, .estimated = true, .parts = &parts, .compaction = compact_status, .can_compact = can_compact, .compaction_before = self.compaction.before_tokens, .compaction_after = self.compaction.after_tokens } else null;
        const key: ?@import("ui/ai_composer_controls_view.zig").ModelKey = if (controls.model) |value| .{ .provider_id = value.provider_id, .model_id = value.model_id } else if (selected) |value| .{ .provider_id = config.ai.default_provider, .model_id = value.model } else null;
        try view.update(.{ .owner = owner, .revision = self.controlsRevision(), .providers = config.ai.providers[0..@min(config.ai.provider_count, config.ai.providers.len)], .current = key, .usage = usage, .permission = controls.permission orelse config.ai.permission_mode, .effort = controls.effort, .thinking = controls.thinking, .attachments = .{ .image = true, .paste_image = true, .local_text = true, .remote_file = true }, .editable = true });
        self.composer_hash = fingerprint;
        self.promptChanged(self.prompt.peek());
    }

    fn clearRequestHistory(self: *AiHost) void {
        self.request_history.deinit();
    }

    fn retainCurrentTurn(self: *AiHost) !void {
        var additions: std.ArrayList(HistoryMessage) = .empty;
        defer additions.deinit(self.allocator);
        errdefer for (additions.items) |*message| message.deinit(self.allocator);
        if (self.last_user_text) |text| {
            var message = try (HistoryMessage{ .user = true, .turn = self.current_turn, .text = text, .wire_text = self.last_user_wire, .attachments = self.last_user_attachments, .images = self.last_user_images }).clone(self.allocator);
            additions.append(self.allocator, message) catch |err| {
                message.deinit(self.allocator);
                return err;
            };
        }
        for (self.controller.stream.cards.items) |card| {
            const body = switch (card) {
                .text => |text| text,
                .code => |code| code.body,
                else => continue,
            };
            const copy = try self.allocator.dupe(u8, body);
            additions.append(self.allocator, .{ .user = false, .text = copy }) catch |err| {
                self.allocator.free(copy);
                return err;
            };
        }
        if (self.request_failure != null) {
            var message = try (HistoryMessage{ .user = false, .text = @constCast(self.failure_label) }).clone(self.allocator);
            additions.append(self.allocator, message) catch |err| {
                message.deinit(self.allocator);
                return err;
            };
        }
        try self.history.ensureUnusedCapacity(self.allocator, additions.items.len);
        self.history.appendSliceAssumeCapacity(additions.items);
        self.controller.stream.clearRetainingCapacity();
        self.current_turn.deinit(self.allocator);
    }

    fn setFeedback(self: *AiHost, label: []const u8) void {
        const node = self.feedback orelse return;
        const message = if (std.mem.eql(u8, label, "InvalidImage") or std.mem.eql(u8, label, "UnsupportedImage")) "无法识别此图片，请选择 PNG、JPEG 等有效图片" else if (std.mem.eql(u8, label, "ImageTooLarge")) "图片超过大小或尺寸限制，请缩小后重试" else if (std.mem.eql(u8, label, "TooManyImages")) "最多添加 4 张图片，请先移除已有图片" else if (std.mem.eql(u8, label, "AnimatedImageUnsupported")) "暂不支持动态图，请选择静态图片" else label;
        node.setTextContent(self.allocator, message) catch return;
        node.setDisplay(if (message.len == 0) .none else .flex);
        node.markRenderDirty();
    }

    fn imageGateLabel(problem: anyerror) []const u8 {
        return switch (problem) {
            error.AttachmentsProcessing => "图片处理中，请等待或移除",
            error.ImageAttachmentFailed => "图片读取失败，请重试附件或移除",
            error.ModelDoesNotSupportImages => "当前模型未启用识图，请选择兼容模型或移除图片",
            error.UnsupportedImageProtocol => "当前 Provider 尚未支持图片请求，请选择兼容模型或移除图片",
            error.UnknownImageBudget => "当前模型的图片预算未知，请选择兼容模型或移除图片",
            else => "请先配置可用模型",
        };
    }

    fn refresh(self: *AiHost, label: []const u8) void {
        _ = self.controller.snapshot(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, .{ .x = 0, .y = 0, .width = 1200, .height = 800 });
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        var owner_label: []const u8 = "当前会话";
        if (self.workspace) |workspace| if (self.display_owner) |owner| switch (owner) {
            .session => |session| {
                for (workspace.tabs.items) |tab| if (tab.id == session) {
                    owner_label = tab.titleSlice();
                    break;
                };
            },
            .group => |group_id| if (self.roster) |roster| {
                for (roster.groups.items) |group| if (group.id == group_id) {
                    owner_label = group.name;
                    break;
                };
            },
        };
        self.setFeedback(if (self.recoveryVisible() or std.mem.eql(u8, label, "AI 助手") or
            std.mem.eql(u8, label, "AI Float") or
            std.mem.eql(u8, label, "AI 请求中…") or
            std.mem.eql(u8, label, "AI Float · 请求中") or
            std.mem.eql(u8, label, "AI · 当前助手") or
            std.mem.eql(u8, label, "AI response")) "" else label);
        writer.print("{s}", .{owner_label}) catch return;
        self.status.setTextContent(self.allocator, writer.buffered()) catch return;
        self.status.markRenderDirty();
        // Attachment history owns widget scopes and portal cleanup. Rebuild
        // only at the after-layout safe point, never inside a click callback.
        self.conversation_dirty = true;
        self.updatePresentation();
        if (self.stop_button) |button| {
            const busy = self.thread_state.load(.acquire) == 1 and self.requestDisplayed();
            button.setOpacityRaw(if (busy) 1 else 0);
            button.setHitTestVisible(busy);
            if (self.send_button) |send| {
                send.setOpacityRaw(if (busy) 0 else 1);
                send.setHitTestVisible(!busy);
            }
        }
        self.promptChanged(self.prompt.get());
        self.cx.requestRedraw();
    }

    /// 对话流重建：用户气泡（右缘 acc.07 底 10/10/3/10）+ 每张卡片一个
    /// 响应块（12.5px，code 卡 mono）。卡片数据仍来自 controller.cardView。
    fn pauseConversationFollow(self: *AiHost) void {
        if (self.tail_follow) |*follow| follow.following = false;
    }

    fn markdown(self: *AiHost, value: []const u8) !*ui.Node {
        if (self.conversation_scope == null) self.conversation_scope = try (self.scope orelse return error.MissingAssistantScope).childScope();
        const scope = self.conversation_scope.?;
        return @import("ui/ai_message_view.zig").mountWithWidth(self.cx, scope, value, if (self.card_box) |box| @max(160, box.globalRect().w - 30) else 540);
    }

    fn userMessage(self: *AiHost, index: usize) ?HistoryMessage {
        if (index < self.history.items.len) return if (self.history.items[index].user) self.history.items[index] else null;
        if (index != self.history.items.len) return null;
        return .{ .user = true, .text = self.last_user_text orelse return null, .attachments = self.last_user_attachments, .images = self.last_user_images };
    }
    fn turnAt(self: *AiHost, index: usize) ?*@import("ai/conversation_turn.zig").Turn {
        if (index < self.history.items.len) return if (self.history.items[index].turn) |*turn| turn else null;
        return if (index == self.history.items.len and self.last_user_text != null) &self.current_turn else null;
    }
    const MessageCell = struct {
        host: *AiHost,
        index: usize,
        kind: @FieldType(MessageAction, "kind"),
        fn run(self: *MessageCell) void {
            self.host.message_action = .{ .kind = self.kind, .index = self.index };
            self.host.cx.requestRedraw();
        }
        fn copy(self: *MessageCell) void {
            const value = if (self.kind == .fork) (self.host.turnAt(self.index) orelse return).answer else (self.host.userMessage(self.index) orelse return).text;
            _ = ui.platform_services.clipboardSetText(self.host.cx.system_sdk, value);
        }
    };
    fn messageButton(self: *AiHost, parent: *ui.Node, index: usize, kind: @FieldType(MessageAction, "kind"), asset: ui.SvgAsset, label: []const u8, id: []const u8, copy: bool) !void {
        const cell = try self.conversation_scope.?.createState(MessageCell, .{ .host = self, .index = index, .kind = kind });
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = asset, .icon_size = @as(f32, 13), .a11y_label = label, .base_style = @import("ui/ai_tool_results_styles.zig").button(22), .disabled = !copy and self.thread_state.load(.acquire) != 0, .on_click = if (copy) self.cx.on(MessageCell, cell, MessageCell.copy) else self.cx.on(MessageCell, cell, MessageCell.run) }).mount(self.conversation_scope.?, self.cx);
        button.meta.ownership.meta.test_id = id;
        try parent.appendChild(self.allocator, button);
    }
    fn appendUserMessage(self: *AiHost, parent: *ui.Node, message: HistoryMessage, index: usize, width: f32) !void {
        const cx = self.cx;
        const row = try ui.box(cx, @import("ui/ai_assistant_styles.zig").messageRow(true), .{});
        row.meta.ownership.meta.test_id = "ai.message.user.row";
        const bubble = try ui.box(cx, @import("ui/ai_assistant_styles.zig").userBubble(width), .{});
        bubble.meta.ownership.meta.test_id = "ai.message.user.bubble";
        bubble.setStyleInline(self.allocator, .{ .direction = .column, .gap = 6, .min_width = 0, .flex_shrink = 0 });
        setBubbleCorners(bubble);
        row.setStyleInline(self.allocator, .{ .gap = 4 });
        if ((if (message.attachments) |bundle| bundle.items.len else 0) + (if (message.images) |bundle| bundle.items.len else 0) > 0) {
            const sent = try ui.box(cx, .{ .width = .{ .fit = .{} }, .max_width = @import("ui/ai_assistant_styles.zig").userBubbleMaxWidth(width), .min_width = 0, .direction = .column, .gap = 4, .align_items = .end, .flex_shrink = 0 }, .{});
            sent.meta.ownership.meta.test_id = "ai.message.attachments";
            if (message.attachments) |*bundle| try self.appendSentAttachments(sent, bundle);
            if (message.images) |*bundle| try self.appendSentImages(sent, bundle);
            try row.appendChild(self.allocator, sent);
        }
        if (self.editing_index == index) {
            self.edit_text = try self.conversation_scope.?.createText(message.text, .{});
            const editor = try ui.widgets.Textarea(.{ .value = self.edit_text.?, .rows = 3, .borderless = true }).mountResult(self.conversation_scope.?, cx);
            editor.wrapper.setStyleInline(self.allocator, .{ .width = .{ .px = @max(150, width * 0.65) }, .height = .{ .px = 76 }, .flex_shrink = 0 });
            editor.input.meta.ownership.meta.test_id = "ai.message.edit.input";
            try bubble.appendChild(self.allocator, editor.wrapper);
        } else try bubble.appendChild(self.allocator, try ui.text(cx, message.text, .{ .font_size = 11.5, .wrap = .word, .line_height = 17.0 / 11.5, .color = @import("ui/ai_assistant_styles.zig").userBubbleForeground() }));
        try row.appendChild(self.allocator, bubble);
        const actions = try ui.box(cx, .{ .direction = .row, .gap = 6, .align_items = .center, .height = .{ .px = 22 }, .flex_shrink = 0 }, .{});
        var buffer: [64]u8 = undefined;
        const turn = self.turnAt(index) orelse return;
        const full_time = @import("ui/history_styles.zig").dateLabel(&buffer, @intCast(turn.sent_at_ms));
        const time = if (full_time.len >= 16) full_time[11..16] else full_time;
        const timestamp = try ui.text(cx, time, .{ .font_size = 10.5, .color = app_theme.current().fg_3 });
        timestamp.meta.ownership.meta.test_id = "ai.message.timestamp";
        try actions.appendChild(self.allocator, timestamp);
        try self.messageButton(actions, index, .rewind, ui.icons.copy, "复制用户消息", "ai.message.copy", true);
        try self.messageButton(actions, index, .rewind, ui.icons.get("undo-2").?, "回退并立即清除本回合及后续记录和上下文", "ai.message.rewind", false);
        try self.messageButton(actions, index, if (self.editing_index == index) .save else .edit, if (self.editing_index == index) ui.icons.check else ui.icons.get("pencil").?, if (self.editing_index == index) "保存编辑" else "编辑用户消息", if (self.editing_index == index) "ai.message.edit.save" else "ai.message.edit", false);
        if (self.editing_index == index) try self.messageButton(actions, index, .cancel, ui.icons.x, "取消编辑", "ai.message.edit.cancel", false);
        try row.appendChild(self.allocator, actions);
        try parent.appendChild(self.allocator, row);
    }
    fn appendTurnSteps(self: *AiHost, parent: *ui.Node, turn: *@import("ai/conversation_turn.zig").Turn) !void {
        const view = @import("ui/ai_step_view.zig");
        const now: u64 = @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        if (turn.thinking.items.len > 0) {
            const text = std.mem.trim(u8, turn.thinking.items, " \t\r\n");
            const last_line = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |offset| text[offset + 1 ..] else text;
            try parent.appendChild(self.allocator, try view.mount(self.cx, self.conversation_scope.?, .{ .title = "思考", .projection = last_line, .detail = text, .copy_detail = false, .phase = if (turn.thinking_ended_ms != null or turn.ended_at_ms != null) .succeeded else .running, .elapsed_ms = (turn.thinking_ended_ms orelse now) -| (turn.thinking_started_ms orelse now), .expanded = &turn.thinking_expanded, .test_id = "ai.thinking", .on_toggle = self.cx.on(AiHost, self, pauseConversationFollow) }));
        }
        for (turn.steps.items) |*step| {
            var found = false;
            for (self.tool_results.records.items) |record| if (record.turn_id == turn.id and std.mem.eql(u8, record.call_id, step.call_id)) {
                if (record.total_elapsed_ms == null) record.expanded = step.expanded;
                record.decision = step.decision;
                record.total_elapsed_ms = (step.ended_ms orelse now) -| step.started_ms;
                const result = try @import("ui/ai_tool_results_view.zig").State.mount(self.cx, self.conversation_scope.?, record);
                result.on_toggle = self.cx.on(AiHost, self, pauseConversationFollow);
                for (record.images) |ref| try result.appendImage(ref, if (self.images_view) |images| images.app else null);
                try parent.appendChild(self.allocator, result.root);
                found = true;
                break;
            };
            if (!found) {
                var buffer: [4096]u8 = undefined;
                const projection = if (step.phase == .assembling) std.fmt.bufPrint(&buffer, "准备中 · {s}", .{step.command}) catch step.command else if (step.phase == .approval) std.fmt.bufPrint(&buffer, "待确认 · {s}", .{step.command}) catch step.command else if (step.decision) |approved| std.fmt.bufPrint(&buffer, "{s} · {s}", .{ if (approved) "已批准" else "已拒绝", step.command }) catch step.command else step.command;
                try parent.appendChild(self.allocator, try view.mount(self.cx, self.conversation_scope.?, .{ .title = view.title(step.name), .projection = projection, .detail = step.detail, .phase = step.phase, .elapsed_ms = (step.ended_ms orelse now) -| step.started_ms, .expanded = &step.expanded, .test_id = "ai.step.tool", .on_toggle = self.cx.on(AiHost, self, pauseConversationFollow) }));
            }
        }
    }
    fn appendTurnFooter(self: *AiHost, parent: *ui.Node, index: usize) !void {
        const turn = self.turnAt(index) orelse return;
        const status = @import("ui/ai_turn_status_view.zig");
        const row = try status.mount(self.cx, self.conversation_scope.?, turn, self.welcome_logo_texture);
        if (turn.ended_at_ms != null) {
            try row.appendChild(self.allocator, try status.dot(self.cx));
            try self.messageButton(row, index, .fork, ui.icons.copy, "复制模型正式输出", "ai.turn.copy", true);
            try row.appendChild(self.allocator, try status.dot(self.cx));
            try self.messageButton(row, index, .fork, ui.icons.get("git-fork").?, "分叉为新会话，内容截止此回合", "ai.turn.fork", false);
        }
        try parent.appendChild(self.allocator, row);
    }

    fn truncateTurns(self: *AiHost, index: usize) !void {
        const turn = self.turnAt(index) orelse return error.StaleTurn;
        var before = try @import("ai/wire_history.zig").History.copy(self.allocator, turn.before.messages, "");
        errdefer before.deinit();
        self.wire_history.deinit();
        self.wire_history = before;
        for (self.history.items[index..]) |*message| message.deinit(self.allocator);
        self.history.shrinkRetainingCapacity(index);
        self.controller.stream.clearRetainingCapacity();
        self.current_turn.deinit(self.allocator);
        if (self.last_user_text) |value| self.allocator.free(value);
        self.last_user_text = null;
        if (self.last_user_wire) |value| self.allocator.free(value);
        self.last_user_wire = null;
        if (self.last_user_attachments) |*bundle| bundle.deinit();
        self.last_user_attachments = null;
        if (self.last_user_images) |*bundle| bundle.deinit();
        self.last_user_images = null;
        self.tool_results.keepTurns(self.history.items);
        self.manager.discardTranscript();
        self.clearRequestHistory();
        self.recovery_failed = false;
        self.recovery_pending = null;
        self.request_failure = null;
        self.request_stats = .{ .usage_reported = false };
        self.request_conversation = null;
        self.editing_index = null;
        self.edit_text = null;
        self.compaction.cancel();
        @import("ai/tool_trace.zig").emit(.{ .event = "conversation_rollback", .conversation_id = self.display_conversation, .history_messages = self.wire_history.messages.len, .display_messages = self.history.items.len, .request_history_messages = self.request_history.messages.len, .tool_records = self.tool_results.records.items.len, .manager_cards = self.manager.cards.count(), .manager_transcript = if (self.manager.tool_run) |run| run.messages.items.len else @as(usize, 0) });
    }
    fn processMessageAction(self: *AiHost) !void {
        const action = self.message_action orelse return;
        self.message_action = null;
        if (self.thread_state.load(.acquire) != 0) return error.AssistantBusy;
        const message = self.userMessage(action.index) orelse return error.StaleTurn;
        switch (action.kind) {
            .rewind => {
                const owner = self.display_owner orelse return;
                const draft = try self.attachmentDraft(owner);
                const images = try self.imageDraft(owner);
                var next_files = try ai_attachments.Draft.init(self.allocator, owner);
                defer next_files.deinit();
                next_files.epoch = draft.epoch;
                next_files.next_id = draft.next_id;
                var next_images = try ai_images.Draft.init(self.allocator, owner);
                defer next_images.deinit();
                next_images.epoch = images.epoch;
                next_images.next_id = images.next_id;
                if (message.attachments) |*bundle| try next_files.restore(bundle) else try next_files.clear();
                if (message.images) |*bundle| try next_images.restore(bundle) else try next_images.clear();
                const restored_text = try self.allocator.dupe(u8, message.text);
                defer self.allocator.free(restored_text);
                try self.truncateTurns(action.index);
                self.cancelConversationReaders(self.display_conversation orelse return);
                std.mem.swap(ai_attachments.Draft, draft, &next_files);
                std.mem.swap(ai_images.Draft, images, &next_images);
                self.prompt.set(restored_text);
                self.recall_index = null;
                if (self.recall_draft) |value| self.allocator.free(value);
                self.recall_draft = null;
                self.conversation_dirty = true;
                if (self.assistant_states) |*store| if (self.display_conversation) |id| if (store.find(id)) |state| {
                    state.phase = if (self.history.items.len == 0) .idle else .done;
                };
                if (self.attachments_view) |view| try view.update(draft);
                if (self.images_view) |view| try view.update(images);
                if (self.input_node) |input| self.cx.setFocus(input);
                self.composer_hash = null;
                self.promptChanged(self.prompt.peek());
                self.setFeedback("已回退，原回合及后续记录和上下文已清除");
            },
            .edit => {
                self.editing_index = action.index;
                self.conversation_dirty = true;
            },
            .cancel => {
                self.editing_index = null;
                self.edit_text = null;
                self.conversation_dirty = true;
            },
            .save => {
                const value = (self.edit_text orelse return).peek();
                const copy = try self.allocator.dupe(u8, value);
                errdefer self.allocator.free(copy);
                const owner = self.display_owner orelse return error.StaleTurn;
                const empty: ai_attachments.Bundle = .{ .allocator = self.allocator, .owner = owner, .draft_epoch = 0, .items = &.{} };
                const new_wire = try ai_attachment_request.compose(self.allocator, value, if (message.attachments) |*bundle| bundle else &empty, @import("ai/provider_http.zig").max_request_bytes);
                errdefer self.allocator.free(new_wire);
                const old_wire = if (action.index < self.history.items.len) self.history.items[action.index].wire_text orelse message.text else self.last_user_wire orelse message.text;
                try self.editContext(action.index, old_wire, new_wire);
                if (action.index < self.history.items.len) {
                    const target = &self.history.items[action.index];
                    self.allocator.free(target.text);
                    target.text = copy;
                    if (target.wire_text) |previous| self.allocator.free(previous);
                    target.wire_text = new_wire;
                } else {
                    if (self.last_user_text) |previous| self.allocator.free(previous);
                    self.last_user_text = copy;
                    if (self.last_user_wire) |previous| self.allocator.free(previous);
                    self.last_user_wire = new_wire;
                }
                self.editing_index = null;
                self.edit_text = null;
                self.conversation_dirty = true;
            },
            .fork => try self.forkThrough(action.index),
        }
        self.cx.requestRedraw();
    }
    fn editContext(self: *AiHost, index: usize, original: []const u8, edited: []const u8) !void {
        const History = @import("ai/wire_history.zig").History;
        const target = self.turnAt(index) orelse return error.StaleTurn;
        const offset = target.before.messages.len;
        const Patch = struct { destination: *History, next: History };
        var patches: std.ArrayList(Patch) = .empty;
        defer {
            for (patches.items) |*patch| patch.next.deinit();
            patches.deinit(self.allocator);
        }
        var contexts: std.ArrayList(*History) = .empty;
        defer contexts.deinit(self.allocator);
        try contexts.append(self.allocator, &self.wire_history);
        for (self.history.items) |*m| if (m.turn) |*turn| {
            try contexts.append(self.allocator, &turn.before);
            try contexts.append(self.allocator, &turn.after);
        };
        try contexts.append(self.allocator, &self.current_turn.before);
        try contexts.append(self.allocator, &self.current_turn.after);
        for (contexts.items) |context| if (try context.editedUser(self.allocator, offset, original, edited)) |next| {
            var owned = next;
            patches.append(self.allocator, .{ .destination = context, .next = next }) catch |err| {
                owned.deinit();
                return err;
            };
        };
        for (patches.items) |*patch| {
            patch.destination.deinit();
            patch.destination.* = patch.next;
            patch.next = .{};
        }
        self.compaction.cancel();
    }
    fn forkThrough(self: *AiHost, index: usize) !void {
        const turn = self.turnAt(index) orelse return error.StaleTurn;
        if (turn.ended_at_ms == null) return error.TurnNotComplete;
        const owner = self.display_owner orelse return;
        var transcript: std.ArrayList(HistoryMessage) = .empty;
        defer {
            for (transcript.items) |*m| m.deinit(self.allocator);
            transcript.deinit(self.allocator);
        }
        var end = @min(index + 1, self.history.items.len);
        while (end < self.history.items.len and !self.history.items[end].user) end += 1;
        for (self.history.items[0..end]) |*m| {
            var copy = try m.clone(self.allocator);
            transcript.append(self.allocator, copy) catch |err| {
                copy.deinit(self.allocator);
                return err;
            };
        }
        if (index == self.history.items.len) {
            var current = try (HistoryMessage{ .user = true, .text = self.last_user_text.?, .attachments = self.last_user_attachments, .images = self.last_user_images, .turn = self.current_turn }).clone(self.allocator);
            transcript.append(self.allocator, current) catch |err| {
                current.deinit(self.allocator);
                return err;
            };
            for (self.controller.stream.cards.items) |card| {
                const text = switch (card) {
                    .text => |value| value,
                    .code => |code| code.body,
                    else => continue,
                };
                const copy = try self.allocator.dupe(u8, text);
                transcript.append(self.allocator, .{ .user = false, .text = copy }) catch |err| {
                    self.allocator.free(copy);
                    return err;
                };
            }
        }
        var context = try @import("ai/wire_history.zig").History.copy(self.allocator, turn.after.messages, "");
        defer context.deinit();
        var results = try self.tool_results.cloneTurns(transcript.items);
        defer results.deinit();
        const current_controls = try self.selectedControls();
        var controls: @import("ai/assistant_store.zig").Controls = .{ .permission = current_controls.permission, .effort = current_controls.effort, .thinking = current_controls.thinking };
        defer controls.deinit(self.allocator);
        try controls.setModel(self.allocator, current_controls.model);
        // Hover previews start with an unlisted conversation. Forking must
        // retain its source in the list before selecting the new branch.
        if (self.display_conversation) |id| if (self.assistant_states.?.find(id)) |source| {
            source.listed = true;
        };
        const saved = try self.assistant_states.?.create(owner);
        saved.controls = controls;
        controls = .{};
        saved.model = self.controller.model;
        saved.history = transcript;
        transcript = .empty;
        saved.wire_history = context;
        context = .{};
        saved.tool_results = results;
        results = @import("ai/tool_results.zig").Store.init(self.allocator);
        saved.phase = .done;
        try self.syncOwner();
        self.refresh("AI 助手");
    }
    fn recallPrompt(self: *AiHost, older: bool) bool {
        const input = self.textarea orelse return false;
        const text = input.getText();
        if (input.cursor.hasSelection()) return false;
        const offset = @min(input.cursor.offset, text.len);
        if (older and std.mem.indexOfScalar(u8, text[0..offset], '\n') != null) return false;
        if (!older and std.mem.indexOfScalar(u8, text[offset..], '\n') != null) return false;
        var chosen: ?usize = null;
        if (older) {
            var i = self.recall_index orelse (self.history.items.len + @as(usize, @intFromBool(self.last_user_text != null)));
            while (i > 0) {
                i -= 1;
                if (self.userMessage(i) != null) {
                    chosen = i;
                    break;
                }
            }
            if (chosen == null) return self.recall_index != null;
            if (self.recall_index == null) {
                if (self.recall_draft) |value| self.allocator.free(value);
                self.recall_draft = self.allocator.dupe(u8, text) catch return false;
            }
        } else {
            var i = (self.recall_index orelse return false) + 1;
            while (i <= self.history.items.len) : (i += 1) if (self.userMessage(i) != null) {
                chosen = i;
                break;
            };
        }
        self.recall_index = chosen;
        self.prompt.set(if (chosen) |i| (self.userMessage(i) orelse return false).text else self.recall_draft orelse "");
        self.promptChanged(self.prompt.peek());
        self.cx.requestRedraw();
        return true;
    }

    fn rebuildConversation(self: *AiHost, snap: *const @import("ai/float_view.zig").Snapshot) void {
        const conv = self.conversation orelse return;
        self.conversation_bubble_width = null;
        self.live_card = null;
        self.live_scope = null;
        self.live_dirty = false;
        self.streaming_label = null;
        if (self.cx.pressed_node) |node| if (node.isDescendantOf(conv)) self.cx.cancelPointerInteractions(.explicit);
        if (self.cx.focus_manager.current_focus) |node| if (node.isDescendantOf(conv)) self.cx.clearFocus();
        if (self.conversation_scope) |scope| scope.dispose();
        self.conversation_scope = null;
        // 清空旧流（status 节点不在 conv 内，安全）。
        var count = conv.children.items.len;
        while (count > 0) : (count -= 1) {
            const child = conv.children.items[count - 1];
            self.cx.detachChild(conv, child);
            // Legacy status/card labels are host-owned and reused by refresh.
            if (child != self.status and child != self.card_node) self.cx.destroyDetached(child);
        }
        const cx = self.cx;
        const allocator = cx.allocator;
        const bubble_content_width = @max(0, snap.width - 30);
        self.conversation_scope = (self.scope orelse return).childScope() catch return;
        var user_index: ?usize = null;
        for (self.history.items, 0..) |message, message_index| {
            if (message.user) {
                if (user_index) |previous| self.appendTurnFooter(conv, previous) catch return;
                user_index = message_index;
                self.appendUserMessage(conv, message, message_index, bubble_content_width) catch return;
                if (self.turnAt(message_index)) |turn| self.appendTurnSteps(conv, turn) catch return;
            } else conv.appendChild(allocator, self.markdown(message.text) catch return) catch return;
        }
        if (user_index) |previous| self.appendTurnFooter(conv, previous) catch return;
        if (self.last_user_text) |text| {
            self.appendUserMessage(conv, .{ .user = true, .text = text, .attachments = self.last_user_attachments, .images = self.last_user_images }, self.history.items.len, bubble_content_width) catch return;
            self.appendTurnSteps(conv, &self.current_turn) catch return;
        }
        // 响应卡片
        var index: usize = 0;
        while (index < snap.card_count) : (index += 1) {
            const view = self.controller.cardView(index) orelse continue;
            if (view.kind != .text and view.kind != .code) continue;
            const is_code = view.kind == .code or view.kind == .execution_plan;
            const card = ui.box(cx, if (view.kind == .text) @import("ui/ai_assistant_styles.zig").assistantMessage() else .{
                .width = .fill(),
                .direction = .column,
                .gap = 4,
                .background = if (is_code) app_theme.current().well else app_theme.current().surface_1,
                .border = .{ .width = 0, .radius = 10 },
                .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
            }, .{}) catch return;
            if (view.kind != .text) {
                const title_text = ui.text(cx, view.title, .{
                    .font_size = 10,
                    .font_weight = 600,
                    .color = app_theme.current().fg_3,
                }) catch return;
                card.appendChild(allocator, title_text) catch return;
            }
            const live_text = view.kind == .text and self.thread_state.load(.acquire) == 1;
            const body_text = if (live_text) blk: {
                self.live_scope = self.conversation_scope.?.childScope() catch return;
                self.live_card = card;
                break :blk @import("ui/ai_message_view.zig").mountWithWidth(cx, self.live_scope.?, view.body, if (self.card_box) |box| @max(160, box.globalRect().w - 30) else 540) catch return;
            } else if (view.kind == .text) self.markdown(view.body) catch return else ui.text(cx, view.body, .{
                .font_size = if (is_code) 11 else @import("ui/ai_assistant_styles.zig").body_font_size,
                .color = if (is_code) app_theme.current().ok else app_theme.current().fg_1,
                .wrap = .word,
                .line_height = if (is_code) 1.5 else @import("ui/ai_assistant_styles.zig").body_line_height,
                .use_monospace_font = is_code,
            }) catch return;
            if (index == 0 and view.kind == .text) {
                body_text.meta.ownership.meta.test_id = "ai.response";
            }
            card.appendChild(allocator, body_text) catch return;
            conv.appendChild(allocator, card) catch return;
        }
        if (self.last_user_text != null) self.appendTurnFooter(conv, self.history.items.len) catch return;
        if (self.recoveryVisible()) {
            if (self.conversation_scope == null) self.conversation_scope = (self.scope orelse return).childScope() catch return;
            const run = self.manager.tool_run;
            const safe = run != null and !run.?.uncertain;
            const cooldown = self.manager.cooldownRemainingMs();
            var retained_answer = false;
            for (self.controller.stream.cards.items) |item| switch (item) {
                .text => |text| {
                    if (std.mem.trim(u8, text, " \t\r\n").len > 0 and !std.mem.eql(u8, text, "— 重新尝试答复 —")) {
                        retained_answer = true;
                        break;
                    }
                },
                .code => |code| {
                    if (code.body.len > 0) {
                        retained_answer = true;
                        break;
                    }
                },
                else => {},
            };
            const recovery = @import("ui/ai_recovery_view.zig").mount(cx, self.conversation_scope.?, .{
                .ticket = .{ .owner = self.request_owner.?, .turn = self.manager.turn_id },
                .reason = self.recoveryReason(),
                .retries = self.manager.retry_attempt,
                .max_retries = self.manager.retry_policy.max_attempts,
                .retry_enabled = safe and cooldown == 0,
                .regenerate_enabled = (run == null or !run.?.uncertain) and cooldown == 0,
                .cooldown_seconds = (cooldown + 999) / 1000,
                .retained_answer = retained_answer,
                .has_tool_calls = if (run) |value| value.records.items.len > 0 else false,
            }, .{ .context = self, .enqueue = enqueueRecovery }) catch return;
            conv.appendChild(allocator, recovery) catch return;
        }
        if (snap.card_count == 0 and self.last_user_text == null and self.history.items.len == 0) {
            if (self.conversation_scope == null) self.conversation_scope = (self.scope orelse return).childScope() catch return;
            const Empty = @import("ui/ai_empty_view.zig");
            var recent: [2]Empty.Recent = undefined;
            var recent_times: [2]u64 = .{ 0, 0 };
            var recent_count: usize = 0;
            if (self.assistant_states) |*store| {
                var recent_index = store.states.items.len;
                while (recent_index > 0) {
                    recent_index -= 1;
                    const state = &store.states.items[recent_index];
                    if (state.closed or !state.listed or self.display_conversation == state.id) continue;
                    const title = state.last_user_text orelse blk: {
                        var last = state.history.items.len;
                        while (last > 0) {
                            last -= 1;
                            if (state.history.items[last].user) break :blk state.history.items[last].text;
                        }
                        continue;
                    };
                    var sent_at_ms = state.current_turn.sent_at_ms;
                    for (state.history.items) |message| if (message.turn) |turn| {
                        sent_at_ms = @max(sent_at_ms, turn.sent_at_ms);
                    };
                    var slot: usize = 0;
                    while (slot < recent_count and recent_times[slot] >= sent_at_ms) : (slot += 1) {}
                    if (slot >= recent.len) continue;
                    recent_count = @min(recent_count + 1, recent.len);
                    var move = recent_count - 1;
                    while (move > slot) : (move -= 1) {
                        recent[move] = recent[move - 1];
                        recent_times[move] = recent_times[move - 1];
                    }
                    recent[slot] = .{ .id = state.id, .title = title };
                    recent_times[slot] = sent_at_ms;
                }
            }
            const empty = Empty.mount(cx, self.conversation_scope.?, self.hasSelectedModel(), .{ .context = self, .logo_texture = self.welcome_logo_texture, .recent = recent[0..recent_count], .select = selectConversation, .summarize = emptySummarize, .logs = emptyLogs, .history = emptyHistory, .settings = emptySettings, .ollama = emptyOllama }) catch return;
            conv.appendChild(allocator, empty) catch return;
        }
    }

    fn appendSentAttachments(self: *AiHost, parent: *ui.Node, bundle: *const ai_attachments.Bundle) !void {
        if (bundle.items.len == 0) return;
        if (self.conversation_scope == null) self.conversation_scope = try (self.scope orelse return error.MissingAssistantScope).childScope();
        const view = try @import("ui/ai_attachments_view.zig").View.mount(self.cx, self.conversation_scope.?, .{ .context = self, .preview_sent = AiHost.previewSentAttachment, .on_error = AiHost.attachmentViewError });
        try view.updateSent(bundle);
        try parent.appendChild(self.cx.allocator, view.root);
    }

    fn setBubbleCorners(node: *ui.Node) void {
        const ext = node.style.ensureExtFallible(std.heap.c_allocator) catch return;
        ext.corner_radius = .{ .each = .{ 12, 12, 4, 12 } }; // TL,TR,BR,BL
    }

    fn openFromStrip(self: *AiHost) void {
        self.toggle();
    }
    fn requestDisplayed(self: *AiHost) bool {
        return self.request_conversation != null and self.request_conversation == self.display_conversation;
    }
    fn panelCapture(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *AiHost = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event == .mouse_down) self.dock.pin();
        return .ignored;
    }
    fn updateDock(self: *AiHost) void {
        const strip = self.strip orelse return;
        const before = self.dock.mode;
        const now = @import("platform/realtime.zig").milliseconds(self);
        const strip_rect = strip.root.globalRect();
        const x = self.cx.mouse_x;
        const y = self.cx.mouse_y;
        const strip_hovered = strip.root.style.display != .none and x >= strip_rect.x and x < strip_rect.x + strip_rect.w and y >= strip_rect.y and y < strip_rect.y + strip_rect.h;
        const panel_hovered = if (self.card_box) |card| inside: {
            const rect = card.globalRect();
            break :inside self.controller.model.visible and x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
        } else false;
        self.dock.hover(strip_hovered, panel_hovered, now);
        if (before != self.dock.mode) {
            if (self.dock.mode == .preview) {
                self.syncOwner() catch return;
                self.controller.model.visible = true;
                self.controller.model.expanded = true;
                self.refresh("AI 助手");
            } else if (self.dock.mode == .hidden) self.collapse();
        }
        if (self.dock.mode == .preview or self.dock.enter_at != null) self.cx.scheduleRedrawAfterNs(16 * 1_000_000);
        self.updatePresentation();
    }

    fn updatePresentation(self: *AiHost) void {
        const visible = self.controller.model.visible;
        const frame = self.reveal.update(visible, @import("platform/realtime.zig").milliseconds(self), self.cx.reduced_motion);
        self.panel.setDisplay(if (visible or frame.opacity > 0.001) .flex else .none);
        self.panel.setStyleInline(self.cx.allocator, .{ .opacity = frame.opacity, .translate_y = if (self.cx.reduced_motion) 0 else -6 * (1 - frame.opacity) });
        self.panel.setHitTestVisible(visible);
        if (frame.moving) self.cx.scheduleRedrawAfterNs(16 * 1_000_000);
    }

    fn updateStrip(self: *AiHost) void {
        const strip = self.strip orelse return;
        const pane = if (self.currentScope() != null) region: {
            const workspace = self.workspace orelse break :region null;
            const title = self.dock_titlebar orelse break :region null;
            var rect = workspace.terminal_area.globalRect();
            const title_rect = title.globalRect();
            rect.y = title_rect.y;
            rect.h = title_rect.h;
            break :region rect;
        } else null;
        // File workspaces align with the sidebar. Their toolbar AI entry remains
        // available without reserving or overlaying a strip across the file cards.
        const file_workspace = if (self.workspace) |workspace| blk: {
            if (workspace.active_group_view != null) break :blk false;
            const index = workspace.active_tab orelse break :blk false;
            if (index >= workspace.tabs.items.len) break :blk false;
            const tab = workspace.tabs.items[index];
            const protocol = if (tab.plugin_protocol_id.len > 0) tab.plugin_protocol_id else if (tab.host_snapshot) |saved| saved.value.protocolId() else "";
            break :blk tab.file_scope != null and std.mem.eql(u8, protocol, "sftp");
        } else false;
        const same_owner = self.requestDisplayed();
        const busy = same_owner and self.thread_state.load(.acquire) == 1;
        const pending = same_owner and self.tool_bridge.pendingApproval() != null;
        const state: @import("ui/ai_strip_view.zig").State = if (pending) .approval else if (busy) .working else if (same_owner and self.recoveryVisible()) .failed else if (self.controller.stream.cards.items.len > 0) .success else .idle;
        const now = @import("platform/realtime.zig").milliseconds(self);
        const phase: usize = @intCast(@divTrunc(now, 200));
        strip.update(pane, pane != null and !file_workspace, state, phase, self.controller.model.visible);
    }

    fn toggle(self: *AiHost) void {
        if (self.currentScope() == null) return;
        self.syncOwner() catch return;
        if (!self.controller.model.visible) self.captureTerminalFocus();
        if (self.display_conversation) |id| if (self.assistant_states) |*store| {
            if (store.find(id)) |state| state.listed = true;
        };
        if (self.dock.mode == .preview and self.controller.model.visible) {
            self.dock.pin();
            return;
        }
        self.dock.toggle();
        if (self.controller.model.visible) {
            self.collapse();
            return;
        }
        self.controller.toggle();
        self.controller.model.expanded = self.controller.model.visible;
        self.refresh(if (self.thread_state.load(.acquire) == 1) "AI Float · 请求中" else "AI Float");
        if (self.controller.model.visible) {
            if (self.attachments_view) |view| if (self.display_owner) |owner| view.restoreCandidate(owner) catch {};
            if (self.input_node) |input| self.cx.focus_manager.setFocus(input);
        } else self.restoreTerminalFocus();
    }

    fn ownerPane(self: *AiHost) ?*ui.Node {
        const workspace = self.workspace orelse return null;
        if (workspace.active_group_view) |id| {
            for (workspace.group_views.items) |view| if (view.id == id) return view.root;
            return null;
        }
        const active = workspace.active_tab orelse return null;
        return if (active < workspace.tabs.items.len) workspace.tabs.items[active].root else null;
    }

    fn ownerBounds(self: *AiHost) ?ui.ComputedRect {
        const workspace = self.workspace orelse return null;
        if (workspace.active_group_view) |id| return workspace.groupAssistantBounds(id);
        if (workspace.active_tab) |index| if (index < workspace.tabs.items.len) {
            const tab = workspace.tabs.items[index];
            if (tab.file_scope != null) if (self.file_application) |files| if (files.presentation) |presentation| {
                if (tab.content_owner == .session) return presentation.assistantBounds(tab.content_owner.session);
            };
        };
        return if (self.ownerPane()) |pane| pane.globalRect() else null;
    }

    fn resizeConversationBubbles(self: *AiHost) bool {
        const conversation = self.conversation orelse return false;
        const panel = self.card_box orelse return false;
        const width = panel.globalRect().w;
        if (width <= 0 or self.conversation_bubble_width == width) return false;
        self.conversation_bubble_width = width;
        const max_width = @import("ui/ai_assistant_styles.zig").userBubbleMaxWidth(@max(0, width - 30));
        for (conversation.children.items) |row| {
            const id = row.meta.ownership.meta.test_id orelse continue;
            if (!std.mem.eql(u8, id, "ai.message.user.row")) continue;
            for (row.children.items) |bubble| if (std.mem.eql(u8, bubble.meta.ownership.meta.test_id orelse "", "ai.message.user.bubble") or std.mem.eql(u8, bubble.meta.ownership.meta.test_id orelse "", "ai.message.attachments")) {
                bubble.setStyle(self.cx.allocator, .max_width, max_width);
            };
        }
        return true;
    }

    fn activeTerminalFocus(self: *AiHost) ?@import("ui/ai_return_focus.zig").Ticket {
        const workspace = self.workspace orelse return null;
        const index = workspace.active_tab orelse return null;
        if (index >= workspace.tabs.items.len) return null;
        const tab = workspace.tabs.items[index];
        if (tab.closing or tab.content_owner != .session or tab.terminal == null) return null;
        const surface = tab.terminal.?.terminal_surface orelse return null;
        if (!surface.owner.eql(tab.content_owner.session)) return null;
        return .{ .tab = tab.tab_id, .owner = tab.content_owner, .group = workspace.active_group_view };
    }

    fn captureTerminalFocus(self: *AiHost) void {
        self.focus_return = self.activeTerminalFocus();
    }

    fn restoreTerminalFocus(self: *AiHost) void {
        const captured = self.focus_return orelse return;
        const current = self.activeTerminalFocus() orelse return;
        const workspace = self.workspace orelse return;
        const index = workspace.active_tab orelse return;
        const terminal_input = workspace.tabs.items[index].terminal.?.root;
        _ = @import("ui/ai_return_focus.zig").restore(self.cx, captured, current, terminal_input, self.card_box orelse self.panel, self.toolbar_trigger, if (self.textarea) |textarea| textarea.imeIsComposing() else false);
    }

    fn collapse(self: *AiHost) void {
        self.dock.hide();
        if (self.sessions_view) |view| view.open.set(false);
        if (self.gestures) |gestures| gestures.cancel();
        if (self.composer_controls) |controls| controls.dismiss();
        if (self.attachments_view) |view| view.dismiss();
        if (self.images_view) |view| view.dismiss();
        if (self.remote_picker) |picker| picker.close();
        self.controller.model.visible = false;
        self.refresh("AI 助手");
        self.restoreTerminalFocus();
    }

    fn closeAssistant(self: *AiHost) void {
        self.dock.pin();
        if (self.display_conversation) |id| requestConversationClose(self, id);
    }
    fn requestConversationClose(raw: *anyopaque, id: u64) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        // Transcript and draft contents are idle data. Protect only work that
        // closing this exact conversation would interrupt.
        var active = self.request_conversation == id and self.thread_state.load(.acquire) == 1;
        for (self.attachment_readers.items) |reader| if (reader.conversation == id) {
            active = true;
        };
        for (self.image_readers.items) |reader| if (reader.conversation == id) {
            active = true;
        };
        if (self.compaction.job != null) if (self.compaction.status_identity) |identity| {
            if (identity.conversation == id) active = true;
        };
        if (active) {
            if (self.sessions_view) |view| view.confirm(id);
        } else {
            deleteConversation(self, id);
        }
    }
    fn newConversation(self: *AiHost) void {
        self.dock.pin();
        self.new_requested = true;
        self.cx.requestRedraw();
    }
    fn showConversations(self: *AiHost) void {
        self.dock.pin();
        if (self.sessions_view) |view| if (view.open.peek()) {
            view.open.set(false);
            return;
        };
        self.list_requested = true;
        self.cx.requestRedraw();
    }
    fn selectConversation(raw: *anyopaque, id: u64) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        self.select_requested = id;
        self.cx.requestRedraw();
    }
    fn deleteConversation(raw: *anyopaque, id: u64) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        self.delete_requested = id;
        self.cx.requestRedraw();
    }
    fn conversationOwnerLabel(self: *AiHost, owner: ai_attachments.Owner, buffer: []u8) []const u8 {
        switch (owner) {
            .session => |id| if (self.tabForSession(id)) |tab| {
                return std.fmt.bufPrint(buffer, "{d} · {s}", .{ (self.workspace.?.model.indexOf(tab.tab_id) orelse 0) + 1, tab.titleSlice() }) catch "Tab";
            },
            .group => |id| if (self.roster) |roster| {
                for (roster.groups.items) |group| if (group.id == id) return std.fmt.bufPrint(buffer, "组 · {s}", .{group.name}) catch "会话组";
            },
        }
        return "原 Tab 已关闭";
    }
    fn cancelConversationReaders(self: *AiHost, id: u64) void {
        var i = self.attachment_readers.items.len;
        while (i > 0) {
            i -= 1;
            const reader = self.attachment_readers.items[i];
            if (reader.conversation == id) {
                reader.cancel();
                reader.deinit();
                _ = self.attachment_readers.orderedRemove(i);
            }
        }
        i = self.image_readers.items.len;
        while (i > 0) {
            i -= 1;
            const reader = self.image_readers.items[i];
            if (reader.conversation == id) {
                reader.cancel();
                reader.deinit();
                _ = self.image_readers.orderedRemove(i);
            }
        }
    }
    fn processConversationActions(self: *AiHost) void {
        if (self.new_requested) {
            self.new_requested = false;
            const owner = (self.currentScope() orelse return).owner;
            self.syncOwner() catch return;
            const retained_draft = self.allocator.dupe(u8, self.prompt.get()) catch return;
            defer self.allocator.free(retained_draft);
            _ = self.assistant_states.?.create(owner) catch return;
            self.syncOwner() catch return;
            self.prompt.set(retained_draft);
            self.dock.pin();
            self.controller.model.visible = true;
            self.controller.model.expanded = true;
            self.refresh("AI 助手");
        }
        if (self.select_requested) |id| {
            self.select_requested = null;
            const store = if (self.assistant_states) |*v| v else return;
            const chosen = store.find(id) orelse return;
            const owner = chosen.owner;
            const workspace = self.workspace orelse return;
            switch (owner) {
                .session => |sid| {
                    const tab = self.tabForSession(sid) orelse return;
                    for (workspace.tabs.items, 0..) |item, index| if (item == tab) {
                        workspace.selectTab(index);
                        break;
                    };
                },
                .group => |gid| workspace.openGroup(self.roster orelse return, std.math.cast(u32, gid) orelse return) catch return,
            }
            _ = store.select(id);
            self.syncOwner() catch return;
            self.dock.pin();
            self.controller.model.visible = true;
            self.controller.model.expanded = true;
            self.refresh("AI 助手");
        }
        if (self.delete_requested) |id| {
            self.delete_requested = null;
            const store = if (self.assistant_states) |*v| v else return;
            const target = store.find(id) orelse return;
            const owner = target.owner;
            target.closed = true;
            target.selected = false;
            if (self.request_conversation == id and self.thread_state.load(.acquire) == 1) {
                self.request_cancel.cancel();
                var sources: [16]@import("ai/tool_results.zig").Source = undefined;
                for (self.tool_bridge.resultSources(&sources)) |source| _ = self.tool_bridge.stopOwner(source.owner);
            }
            self.cancelConversationReaders(id);
            if (self.display_conversation == id) {
                self.collapse();
                _ = store.get(owner) catch return;
                self.syncOwner() catch return;
                self.controller.model.visible = false;
                self.refresh("AI 助手");
            }
            if (self.request_conversation != id or self.thread_state.load(.acquire) == 0) store.remove(id);
            if (self.sessions_view) |view| {
                if (view.open.peek()) self.list_requested = true;
            }
        }
        if (self.list_requested) {
            self.list_requested = false;
            const store = if (self.assistant_states) |*v| v else return;
            var entries: std.ArrayList(@import("ui/ai_sessions_view.zig").Entry) = .empty;
            defer {
                for (entries.items) |entry| {
                    self.allocator.free(entry.title);
                    self.allocator.free(entry.owner);
                }
                entries.deinit(self.allocator);
            }
            for (store.states.items) |state| {
                if (state.closed or !state.listed) continue;
                var label_buffer: [256]u8 = undefined;
                const owner_label = self.conversationOwnerLabel(state.owner, &label_buffer);
                const title = (if (self.display_conversation == state.id) self.last_user_text else state.last_user_text) orelse blk: {
                    const messages = if (self.display_conversation == state.id) self.history.items else state.history.items;
                    var last = messages.len;
                    while (last > 0) {
                        last -= 1;
                        if (messages[last].user) break :blk @as(?[]u8, messages[last].text);
                    }
                    break :blk @as(?[]u8, null);
                };
                const owned_title = if (title) |value| self.allocator.dupe(u8, value) catch return else std.fmt.allocPrint(self.allocator, "新会话 #{d}", .{state.id}) catch return;
                const owned_owner = self.allocator.dupe(u8, owner_label) catch {
                    self.allocator.free(owned_title);
                    return;
                };
                entries.append(self.allocator, .{ .id = state.id, .title = owned_title, .owner = owned_owner, .detail = if (self.display_conversation == state.id) self.prompt.peek() else state.draft orelse "空对话", .active = self.display_conversation == state.id, .phase = state.phase }) catch {
                    self.allocator.free(owned_title);
                    self.allocator.free(owned_owner);
                    return;
                };
            }
            if (self.sessions_view) |view| view.show(entries.items) catch {};
        }
    }

    fn maximize(self: *AiHost) void {
        if (self.gestures) |gestures| gestures.toggleMaximized() else self.controller.model.maximized = !self.controller.model.maximized;
        self.cx.requestRedraw();
    }

    fn hasSelectedModel(self: *AiHost) bool {
        if (self.runtime_config == null) return false;
        const controls = self.selectedControls() catch return false;
        _ = ai_provider_config.fromSettingsSelection(self.effectiveAi(), controls.model) catch return false;
        return true;
    }

    fn emptyHistory(raw: *anyopaque) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        self.showConversations();
    }

    fn emptySummarize(raw: *anyopaque) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        // Append to the current owner's draft; never overwrite existing input.
        const previous = self.prompt.peek();
        const next = std.fmt.allocPrint(self.allocator, "{s}{s}请概括终端报错，分析所选文字或最近输出。", .{ previous, if (previous.len == 0) "" else "\n" }) catch return;
        defer self.allocator.free(next);
        self.prompt.set(next);
        self.promptChanged(self.prompt.peek());
        if (self.input_node) |input| self.cx.setFocus(input);
    }

    fn emptyLogs(raw: *anyopaque) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        const owner = self.display_owner orelse return;
        self.chooseLocalText(owner, null) catch |err| self.refresh(@errorName(err));
    }

    fn emptySettings(raw: *anyopaque) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        self.settings_request = false;
        self.cx.requestRedraw();
    }

    fn emptyOllama(raw: *anyopaque) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        self.settings_request = true;
        self.cx.requestRedraw();
    }

    fn composerSettings(raw: *anyopaque) void {
        emptySettings(raw);
    }

    fn openRequestedSettings(self: *AiHost) void {
        const ollama = self.settings_request orelse return;
        self.settings_request = null;
        const settings = self.settings_host orelse return;
        if (settings.busy()) return;
        if (!settings.open) settings.toggle();
        if (!settings.open) return;
        if (self.composer_controls) |controls| controls.dismiss();
        settings.selectPage(4);
        if (ollama) for (settings.controller.model.value.ai.providers[0..settings.controller.model.value.ai.provider_count], 0..) |provider, index| {
            if (provider.kind != .ollama) continue;
            settings.controller.ai_fields.provider_open.put(self.allocator, index, true) catch return;
            settings.controller.ai_fields.connection_open.put(self.allocator, index, true) catch return;
            settings.controller.scroll_offsets[4] = 0;
            break;
        };
        self.cx.requestRedraw();
    }

    fn recoveryReason(self: *AiHost) []const u8 {
        if (self.request_failure != null) return self.failure_label;
        return if (self.request_failure) |err| switch (err) {
            error.ToolOutcomeUnknown => "远端写入结果待核实，请先核查原目标",
            error.Timeout => "请求超时，已保留收到的答复和调用结果",
            error.RequestRejected, error.RateLimited => "服务暂不可用或请求受限，请在冷却结束后重试",
            error.MissingApiKey, error.ProviderFailure => "服务请求失败，请检查 AI 设置",
            else => "连接或答复流中断，已保留收到的内容",
        } else "请求失败，已保留收到的内容";
    }

    fn recoveryVisible(self: *AiHost) bool {
        if (!self.requestDisplayed() or !self.recovery_failed or self.thread_state.load(.acquire) != 0) return false;
        const owner = self.display_owner orelse return false;
        const captured = self.request_owner orelse return false;
        return owner.eql(captured);
    }

    fn enqueueRecovery(raw: *anyopaque, envelope: @import("ui/ai_recovery_view.zig").Envelope) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        if (self.recovery_pending == null) self.recovery_pending = envelope;
        self.cx.requestRedraw();
    }

    // Run at the after-layout safe point, after owner synchronization. Button
    // callbacks never dispose their own conversation scope or change targets.
    fn applyRecovery(self: *AiHost) void {
        const envelope = self.recovery_pending orelse return;
        self.recovery_pending = null;
        if (!self.recoveryVisible() or envelope.ticket.turn != self.manager.turn_id or !envelope.ticket.owner.eql(self.request_owner.?)) return;
        const current = self.currentScope() orelse return;
        if (!current.owner.eql(envelope.ticket.owner)) return;
        const question = self.last_user_text orelse return;
        if (envelope.action == .edit) {
            const previous = self.prompt.peek();
            const text = if (previous.len == 0) self.allocator.dupe(u8, question) else if (std.mem.endsWith(u8, previous, question)) self.allocator.dupe(u8, previous) else std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ previous, question });
            const draft = text catch return;
            defer self.allocator.free(draft);
            self.prompt.set(draft);
            self.promptChanged(self.prompt.peek());
            if (self.input_node) |node| self.cx.setFocus(node);
            return;
        }
        if (self.manager.cooldownRemainingMs() != 0) return;
        if (self.manager.tool_run) |run| if (run.uncertain) return;
        if (envelope.action == .regenerate) {
            // submit allocates a new turn and captures fresh permission/scope.
            // It copies question before changing the retained conversation.
            const draft = self.allocator.dupe(u8, self.prompt.peek()) catch return;
            defer self.allocator.free(draft);
            self.submit(question);
            // This action resubmits the original question, not the next draft.
            self.prompt.set(draft);
            self.promptChanged(self.prompt.peek());
            return;
        }
        if (self.manager.tool_run == null) return;
        // Snapshot/ledger and Provider binding remain frozen. Never call submit
        // or prepare a new bridge for an answer-only continuation.
        const marker = "— 重新尝试答复 —";
        _ = self.manager.cards.append(.{ .text = marker }) catch return;
        self.controller.stream.clearRetainingCapacity();
        for (self.manager.cards.cards.items) |card| _ = self.controller.stream.append(card) catch return;
        self.retry_prefix_count = self.controller.stream.count();
        self.answer_only = true;
        self.request_stats = .{ .usage_reported = false };
        self.request_cancel = .{};
        self.request_failure = null;
        self.thread_state.store(1, .release);
        self.worker_thread = std.Thread.spawn(.{}, workerRun, .{self}) catch {
            self.thread_state.store(0, .release);
            self.request_failure = error.ThreadSpawnFailed;
            self.answer_only = false;
            self.refresh("无法创建请求线程");
            return;
        };
        self.recovery_failed = false;
        self.current_turn.ended_at_ms = null;
        self.refresh("正在重试答复…");
    }

    fn sendPrompt(self: *AiHost) void {
        self.submit(self.prompt.get());
    }

    fn promptChanged(self: *AiHost, text: []const u8) void {
        var ready: usize = 0;
        var processing = self.attachment_picker_active;
        var image_problem: ?anyerror = null;
        var has_images = if (self.last_user_images) |bundle| bundle.items.len > 0 else false;
        for (self.history.items) |message| if (message.images) |bundle| {
            has_images = has_images or bundle.items.len > 0;
        };
        if (self.display_owner) |owner| {
            if (self.attachmentDraft(owner)) |draft| {
                ready = draft.items.items.len;
                processing = processing or draft.pending.items.len != 0;
            } else |_| {}
            if (self.imageDraft(owner)) |draft| {
                has_images = has_images or draft.items.items.len > 0;
                for (draft.items.items) |item| switch (item.state) {
                    .ready => ready += 1,
                    .processing => {
                        processing = true;
                        image_problem = error.AttachmentsProcessing;
                    },
                    .failed => {
                        processing = true;
                        image_problem = error.ImageAttachmentFailed;
                    },
                };
            } else |_| {}
            if (has_images and image_problem == null) {
                const controls = self.selectedControls() catch null;
                const selected = if (self.runtime_config != null) ai_provider_config.fromSettingsSelection(self.effectiveAi(), if (controls) |value| value.model else null) catch null else null;
                if (selected) |config| {
                    if (!config.vision) image_problem = error.ModelDoesNotSupportImages else if (config.kind != .openai_compat) image_problem = error.UnsupportedImageProtocol else if (!config.supportsImageBudget()) image_problem = error.UnknownImageBudget;
                } else image_problem = error.MissingModel;
            }
        }
        if (self.send_disabled) |disabled| disabled.set(!self.hasSelectedModel() or (std.mem.trim(u8, text, " \t\r\n").len == 0 and ready == 0) or processing or image_problem != null or self.thread_state.load(.acquire) == 1);
        const gate_changed = self.image_gate != image_problem;
        self.image_gate = image_problem;
        // Keep the reason visible through unrelated refreshes while sending is
        // blocked. Clearing the last image also clears the obsolete warning.
        if (self.thread_state.load(.acquire) != 1) {
            if (image_problem) |problem| self.setFeedback(imageGateLabel(problem)) else if (gate_changed) self.setFeedback("");
        }
    }

    fn preflightMessages(self: *AiHost, prompt: []const u8) !std.ArrayList(ai_provider.Message) {
        var messages: std.ArrayList(ai_provider.Message) = .empty;
        errdefer messages.deinit(self.allocator);
        const context = &self.wire_history;
        if (context.failure) |err| return err;
        if (context.messages.len >= @import("ai/wire_history.zig").History.max_messages) return error.ToolTranscriptLimit;
        try messages.appendSlice(self.allocator, context.messages);
        try messages.append(self.allocator, .{ .content = prompt });
        return messages;
    }

    fn composerEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *AiHost = @ptrCast(@alignCast(raw orelse return .ignored));
        const textarea = self.textarea orelse return .ignored;
        switch (event) {
            .key_down => |key| if (key.key == .v and key.modifiers.super and !textarea.imeIsComposing()) {
                const sdk = self.cx.system_sdk orelse return .ignored;
                const kinds = sdk.clipboardProbe() catch return .ignored;
                if (!kinds.image) return .ignored;
                const owner = self.display_owner orelse return .ignored;
                self.pasteImages(owner) catch |err| self.refresh(@errorName(err));
                return .stop;
            } else if ((key.key == .up or key.key == .down) and !key.modifiers.super and !key.modifiers.alt and !key.modifiers.shift and !textarea.imeIsComposing()) {
                if (self.recallPrompt(key.key == .up)) return .stop;
            } else if (key.key == .@"return") {
                if (textarea.imeIsComposing()) return .ignored;
                if (key.modifiers.super) {
                    _ = ui.widgets.input.textareaEventHandler(.{ .key_down = .{ .key = .@"return" } }, textarea);
                } else self.sendPrompt();
                return .stop;
            },
            .drag => |drag| {
                if (drag.payload_kind != .file_or_url or textarea.imeIsComposing()) return .ignored;
                if (drag.kind != .dropped) return .handled;
                if (drag.payload_truncated) {
                    self.refresh("拖入文件列表不完整，请重新选择");
                    return .stop;
                }
                const owner = self.display_owner orelse return .ignored;
                var paths = std.mem.splitScalar(u8, drag.paths, '\n');
                while (paths.next()) |path| {
                    if (path.len == 0) continue;
                    self.addImagePath(owner, path) catch |err| {
                        self.refresh(@errorName(err));
                        return .stop;
                    };
                }
                return .stop;
            },
            else => {},
        }
        return .ignored;
    }

    fn submit(self: *AiHost, text: []const u8) void {
        const submitted_at: u64 = @intCast(@max(0, @import("platform/realtime.zig").milliseconds(self)));
        if (self.compaction.job != null) self.compaction.cancel();
        // The on_submit `text` IS the user's input (the zenit Input
        // component's committed buffer). controller.submitInput() reads a
        // SEPARATE ai.input_model buffer that nothing ever fills from the
        // UI, so it always returned null and every Enter was silently
        // dropped — the reason AI submit never fired while quick-connect
        // (which uses the callback text directly) worked.
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        // Input/Signal updates below can invalidate the callback slice.
        const submitted = self.allocator.dupe(u8, trimmed) catch return;
        defer self.allocator.free(submitted);
        const owner_scope = self.currentScope() orelse return;
        const changed_owner = if (self.display_owner) |owner| !@import("ai/tool_scope.zig").Owner.eql(owner, owner_scope.owner) else false;
        self.syncOwner() catch return;
        // A stale editor submit must not carry another assistant's prompt.
        if (changed_owner) {
            self.refresh("已恢复此助手，请在当前输入框发送");
            return;
        }
        if (self.thread_state.load(.acquire) == 0 and self.manager.cooldownRemainingMs() != 0) {
            self.refresh("请求冷却中，请稍后重试");
            return;
        }
        if (self.thread_state.load(.acquire) == 1) {
            self.refresh("AI 正在处理上一条…");
            return;
        }
        if (!self.hasSelectedModel()) {
            // @ai <question> may submit a captured question before it has
            // entered the composer. Keep it with the original owner's draft.
            if (!std.mem.eql(u8, self.prompt.peek(), submitted) and submitted.len != 0) {
                const previous = self.prompt.peek();
                const retained = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ previous, if (previous.len == 0) "" else "\n", submitted }) catch return;
                defer self.allocator.free(retained);
                self.prompt.set(retained);
            }
            self.refresh("请选择模型，或打开 AI 设置配置");
            return;
        }
        const finished = self.thread_state.load(.acquire);
        if (finished >= 2) self.finalizeWorker(finished);
        const reusable = &self.wire_history;
        if (reusable.failure) |err| {
            const label = wireHistoryFailureLabel(err);
            if (self.workspace) |workspace| workspace.status(label);
            self.refresh(label);
            return;
        }
        _ = self.retainToolResults() catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        const attachment_draft = self.attachmentDraft(owner_scope.owner) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        var attachment_bundle = attachment_draft.freeze() catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        defer attachment_bundle.deinit();
        const image_draft = self.imageDraft(owner_scope.owner) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        var image_bundle = image_draft.freeze() catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        defer image_bundle.deinit();
        if (submitted.len == 0 and attachment_bundle.items.len == 0 and image_bundle.items.len == 0) return;
        const workspace = self.workspace orelse return;
        const tab = if (owner_scope.owner == .group) self.tabForSession(owner_scope.members.ids[0]) orelse return else blk: {
            const active = workspace.active_tab orelse return;
            break :blk workspace.tabs.items[active];
        };
        const context_controls = self.selectedControls() catch return;
        const context_config = if (self.native_binding != null) ai_provider_config.fromSettingsSelection(self.effectiveAi(), context_controls.model) catch |err| {
            self.refresh(@errorName(err));
            return;
        } else ai_provider_config.defaults(.openai_compat);
        // Reading the terminal may briefly contend with its worker. Capture
        // before replacing the previous turn's frozen state, so a failed new
        // plan keeps its original recovery actions and request snapshots.
        const prepared_context = if (owner_scope.owner == .group)
            @import("ui/ai_group_context.zig").assemble(self.allocator, self.application_host orelse return, self.roster orelse return, owner_scope, context_config.context_window, workspace.app_config.ai.redact_ip)
        else
            @import("ui/ai_session_context.zig").assemble(self.allocator, self.application_host orelse return, tab.content_owner.session, context_config.context_window, workspace.app_config.ai.redact_ip);
        var captured_context = prepared_context catch |err| {
            self.refresh(if (err == error.WorkerBusy)
                if (self.recovery_failed) "终端正在更新，请稍后重试；原答复和重试入口已保留" else "终端正在更新，请稍后重试"
            else
                @errorName(err));
            return;
        };
        var context_transferred = false;
        defer if (!context_transferred) captured_context.deinit(self.allocator);
        // A fresh question now replaces Provider/context snapshots. Retire old
        // recovery tickets only after the potentially busy read succeeded.
        self.recovery_failed = false;
        self.request_cancel.cancel();
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
        if (self.native_binding) |binding| {
            if (self.request_config) |*old| old.deinit();
            self.request_config = null;
            self.endpoint = "";
            self.model = "";
            const runtime = self.runtime_config orelse return;
            var effective_config = runtime.value;
            effective_config.ai = self.effectiveAi();
            var owned = @import("config/runtime_config.zig").Snapshot.init(self.allocator, effective_config) catch {
                self.refresh("内存不足");
                return;
            };
            const controls = self.selectedControls() catch return;
            const selected = ai_provider_config.fromSettingsSelection(owned.value.ai, controls.model) catch |err| {
                owned.deinit();
                self.refresh(@errorName(err));
                return;
            };
            self.request_config = owned;
            binding.config = selected;
            binding.client.stream_kind = switch (selected.kind) {
                .anthropic => .anthropic,
                .openai_compat => .openai_compat,
                .ollama => .ollama,
            };
            self.endpoint = selected.endpoint;
            self.model = selected.model;
        }
        if (self.request_context) |*previous| previous.deinit(self.allocator);
        self.request_context = captured_context;
        context_transferred = true;
        const selected_config = if (self.native_binding) |binding| binding.config else ai_provider_config.defaults(.openai_compat);
        self.request_session = tab.id;
        self.request_owner = owner_scope.owner;
        self.request_conversation = self.display_conversation;
        if (self.assistant_states) |*store| if (self.display_conversation) |id| {
            if (store.find(id)) |state| state.phase = .running;
        };
        self.dock.pin();
        self.manager.scope = owner_scope;
        const controls = self.selectedControls() catch return;
        if (controls.effort) |effort| ai_provider_config.validateEffort(self.effectiveAi(), controls.model, effort) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        self.request_effort = controls.effort;
        if (controls.thinking != null and !(ai_provider_config.supportsThinking(self.effectiveAi(), controls.model) catch false)) {
            self.refresh("当前模型不支持思考开关");
            return;
        }
        self.request_thinking = controls.thinking;
        self.manager.permission_engine.mode = if ((controls.permission orelse workspace.app_config.ai.permission_mode) == .auto) .auto else .confirm;
        if (owner_scope.owner == .session) if (self.request_context) |*context| {
            const prefix = std.fmt.allocPrint(self.allocator, "assistant_session_id={d}\n{s}", .{ owner_scope.owner.session, context.text }) catch return;
            self.allocator.free(context.text);
            context.text = prefix;
        };
        self.tool_bridge.clear() catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        self.request_tools_len = 0;
        self.manager.tool_host = null;
        self.manager.tool_limits.context_window = selected_config.context_window;
        self.manager.policy_revision = if (self.request_config) |snapshot| snapshot.value.config_revision else 1;
        if (self.application_host) |host| {
            self.tool_bridge.configureFiles(self.file_application);
            self.tool_bridge.configurePolicy(self.manager.permission_engine, self.manager.policy_revision);
            const prepared = if (owner_scope.owner == .group) self.tool_bridge.prepareGroup(host, self.roster orelse return, owner_scope) else self.tool_bridge.prepare(host, tab.content_owner.session);
            if (prepared) |_| {
                self.request_tools_len = self.tool_bridge.fill(&self.request_tools) catch |err| {
                    self.refresh(@errorName(err));
                    return;
                };
                self.manager.tool_host = self.tool_bridge.interface();
            } else |err| {
                @import("ai/tool_trace.zig").emit(.{ .event = "tools_unavailable", .owner = owner_scope.owner, .reason = @errorName(err) });
            }
        }
        @import("ai/tool_trace.zig").emit(.{ .event = "tools_prepared", .conversation_id = self.request_conversation, .turn_id = self.manager.turn_id +| 1, .session_id = tab.id, .local = tab.local, .provider_kind = selected_config.kind, .tools_count = self.request_tools_len });
        var wire: ?[]u8 = ai_attachment_request.compose(self.allocator, submitted, &attachment_bundle, @import("ai/provider_http.zig").max_request_bytes) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        defer if (wire) |bytes| self.allocator.free(bytes);
        defer self.clearPreflightImageRefs();
        var messages = self.preflightMessages(wire.?) catch |err| {
            const label = if (err == error.ToolTranscriptLimit) wireHistoryFailureLabel(err) else @errorName(err);
            workspace.status(label);
            self.refresh(label);
            return;
        };
        defer messages.deinit(self.allocator);
        messages.items[messages.items.len - 1].images = self.borrowImageRefs(image_bundle) catch return;
        self.request_max_output = @min(@as(u32, 4096), @max(selected_config.context_window / 4, 1));
        const configured_request = selected_config.chatRequest(.{ .model = selected_config.model, .effort = self.request_effort, .thinking = self.request_thinking, .system = if (self.request_context) |context| context.text else "", .messages = messages.items, .tools = self.request_tools[0..self.request_tools_len], .tool_table = self.tool_bridge.requestTable(), .tool_images = selected_config.vision, .max_output = self.request_max_output });
        self.request_vision = configured_request.vision;
        self.request_image_token_reservation = configured_request.image_token_reservation;
        const wire_size = @import("ai/provider_http.zig").requestBodySize(selected_config.kind, configured_request, selected_config.context_window) catch |err| {
            self.refresh(if (err == error.RequestTooLarge or err == error.ToolRequestTooLarge) "请求内容超过传输上限，请减少附件" else @errorName(err));
            return;
        };
        ai_attachment_request.checkContext(configured_request, selected_config.context_window) catch |err| {
            if (err == error.ContextBudgetExceeded) {
                var budget_label: [128]u8 = undefined;
                const input = ai_attachment_request.inputTokens(configured_request) catch 0;
                self.refresh(std.fmt.bufPrint(&budget_label, "输入估算 {d} + 输出预留 {d}，超过窗口 {d}", .{ input, self.request_max_output, selected_config.context_window }) catch "上下文超过模型窗口");
            } else self.refresh(@errorName(err));
            return;
        };
        @import("ai/tool_trace.zig").emit(.{ .event = "attachment_request_preflight", .conversation_id = self.request_conversation, .turn_id = self.manager.turn_id +| 1, .history_messages = self.wire_history.messages.len, .owner = owner_scope.owner, .attachments = attachment_bundle.items.len, .wire_bytes = wire_size, .input_tokens_estimate = ai_attachment_request.inputTokens(configured_request) catch 0, .reserved_output = self.request_max_output, .context_window = selected_config.context_window });
        const next_turn = std.math.add(u64, self.manager.turn_id, 1) catch {
            self.refresh("AI 回合编号已用尽");
            return;
        };
        var next_history = @import("ai/wire_history.zig").History.copy(self.allocator, messages.items[0 .. messages.items.len - 1], "") catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        defer next_history.deinit();
        var next_visible = @import("ai/wire_history.zig").History.copy(self.allocator, next_history.messages, "") catch return;
        defer next_visible.deinit();
        var next_user: ?[]u8 = self.allocator.dupe(u8, submitted) catch return;
        defer if (next_user) |value| self.allocator.free(value);
        var next_wire: ?[]u8 = self.allocator.dupe(u8, wire.?) catch return;
        defer if (next_wire) |value| self.allocator.free(value);
        var history_bundle = attachment_draft.freeze() catch return;
        defer history_bundle.deinit();
        var image_history_bundle = image_bundle.retain() catch return;
        defer image_history_bundle.deinit();
        // Prepare image refs before the worker can read request state.
        self.request_image_refs.clearRetainingCapacity();
        self.request_image_refs.ensureTotalCapacity(self.allocator, image_bundle.items.len) catch return;
        for (image_bundle.items) |item| self.request_image_refs.appendAssumeCapacity(item.reference);
        if (self.request_images) |*old| old.deinit();
        self.request_images = image_bundle.retain() catch return;
        var next_meta: @import("ai/conversation_turn.zig").Turn = .{ .id = next_turn, .sent_at_ms = submitted_at, .started_mono_ms = @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms)) };
        defer next_meta.deinit(self.allocator);
        next_meta.before = @import("ai/wire_history.zig").History.copy(self.allocator, next_history.messages, "") catch return;
        // All checks and request-owned allocations precede input consumption.
        self.retainCurrentTurn() catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        self.current_turn = next_meta;
        next_meta = .{};
        self.recall_index = null;
        if (self.recall_draft) |value| self.allocator.free(value);
        self.recall_draft = null;
        if (self.last_user_text) |old| self.allocator.free(old);
        self.last_user_text = null;
        if (self.last_user_wire) |old| self.allocator.free(old);
        self.last_user_wire = null;
        if (self.last_user_attachments) |*old| old.deinit();
        self.last_user_attachments = null;
        if (self.last_user_images) |*old| old.deinit();
        self.last_user_images = null;
        self.clearRequestHistory();
        self.wire_history.deinit();
        self.wire_history = next_visible;
        next_visible = .{};
        self.request_history = next_history;
        next_history = .{};
        if (self.request_text) |old| self.allocator.free(old);
        self.request_text = wire;
        wire = null;
        self.manager.turn_id = next_turn;
        self.request_content_owner = if (owner_scope.owner == .group) .{ .group = .{ .id = @fromBackingInt(@intCast(owner_scope.owner.group)) } } else tab.content_owner;
        self.request_operation_id = if (process_notifications) |notifications| if (self.notification_window) |window| notifications.reserveAiOperation(window) catch null else null else null;
        self.request_cancel = .{};
        self.request_stats = .{ .usage_reported = false };
        self.answer_only = false;
        self.retry_prefix_count = 0;
        self.request_failure = null;
        self.thread_state.store(1, .release);
        const thread = std.Thread.spawn(.{}, workerRun, .{self}) catch {
            self.thread_state.store(0, .release);
            self.failure_label = "无法创建请求线程";
            self.refresh(self.failure_label);
            return;
        };
        self.worker_thread = thread;
        self.recovery_failed = false;
        self.last_user_text = next_user;
        next_user = null;
        self.last_user_wire = next_wire;
        next_wire = null;
        self.controller.setPrompt(self.last_user_text orelse "");
        if (self.tail_follow) |*follow| follow.reset();
        self.prompt.set("");
        _ = attachment_draft.consumeSent(&attachment_bundle) catch unreachable;
        if (attachment_bundle.items.len > 0) {
            self.request_attachments = attachment_bundle;
            attachment_bundle.items = &.{};
            self.last_user_attachments = history_bundle;
            history_bundle.items = &.{};
        }
        _ = image_draft.consumeSent(&image_bundle) catch unreachable;
        self.last_user_images = image_history_bundle;
        image_history_bundle.items = &.{};
        if (self.attachments_view) |view| view.update(attachment_draft) catch {};
        if (self.images_view) |view| view.update(image_draft) catch {};
        self.refresh("AI 请求中…");
    }

    /// Stop is deliberately cooperative: the provider transport checks the
    /// shared token before requests, while reading response frames and while
    /// retry backoff sleeps.  The UI thread never blocks waiting for network
    /// I/O; PollHook joins only after the worker publishes a terminal state.
    fn decideTool(ctx: *anyopaque, sequence: u64, hash: [32]u8, approved: bool) !void {
        const self: *AiHost = @ptrCast(@alignCast(ctx));
        if (self.thread_state.load(.acquire) != 1) return error.StaleApproval;
        const owner = self.display_owner orelse return error.StaleApproval;
        const request = self.request_owner orelse return error.StaleApproval;
        if (!owner.eql(request) or !self.requestDisplayed()) return error.StaleApproval;
        try self.tool_bridge.decide(sequence, hash, approved);
        self.cx.requestRedraw();
    }

    fn stop(self: *AiHost) void {
        if (self.thread_state.load(.acquire) != 1) return;
        const owner = self.display_owner orelse return;
        const request_owner = self.request_owner orelse return;
        if (!@import("ai/tool_scope.zig").Owner.eql(owner, request_owner) or !self.requestDisplayed()) return;
        self.request_cancel.cancel();
        self.refresh("AI 停止中…");
    }

    /// Worker thread body: synchronous provider call on the private io.
    /// Touches NO UI state; the poll hook reads the results after the
    /// state flag flip.
    fn workerRun(self: *AiHost) void {
        if (self.answer_only) {
            self.finishRequest(self.manager.resumeAnswer(self.provider, &self.request_cancel));
            return;
        }
        self.tool_bridge.events = &self.step_mailbox;
        const prompt_copy = self.request_text orelse {
            self.thread_state.store(3, .release);
            return;
        };
        var messages: std.ArrayList(ai_provider.Message) = .empty;
        defer messages.deinit(self.allocator);
        // This owned snapshot is shared with preflight and retains original
        // tool roles, call/result IDs and observation images across user turns.
        messages.appendSlice(self.allocator, self.request_history.messages) catch {
            self.thread_state.store(3, .release);
            return;
        };
        messages.append(self.allocator, .{ .content = prompt_copy, .images = self.request_image_refs.items }) catch {
            self.thread_state.store(3, .release);
            return;
        };
        @import("ai/tool_trace.zig").emit(.{ .event = "request_identity", .conversation_id = self.request_conversation, .turn_id = self.manager.turn_id, .owner = self.request_owner, .history_messages = self.request_history.messages.len });
        const result = self.manager.run(self.provider, .{
            .model = self.model,
            .effort = self.request_effort,
            .thinking = self.request_thinking,
            .vision = self.request_vision,
            .image_token_reservation = self.request_image_token_reservation,
            .system = if (self.request_context) |context| context.text else "",
            .messages = messages.items,
            .tools = self.request_tools[0..self.request_tools_len],
            .tool_table = self.tool_bridge.requestTable(),
            .tool_images = self.request_vision,
            .max_output = self.request_max_output,
            .cancel = &self.request_cancel,
        });
        self.finishRequest(result);
    }

    fn finishRequest(self: *AiHost, result: anyerror!ai_provider.ChatStats) void {
        if (result) |stats| {
            self.request_stats = stats;
            // A provider may finish concurrently with Stop (or may not
            // support mid-stream cancellation). Cancellation wins so a late
            // successful result can never overwrite the stopped UI state.
            if (self.request_cancel.isCancelled()) {
                self.thread_state.store(4, .release);
            } else {
                self.thread_state.store(2, .release);
            }
        } else |err| {
            if (self.request_cancel.isCancelled()) {
                self.thread_state.store(4, .release);
                return;
            }
            self.request_failure = err;
            self.failure_label = if (self.native_context) |context| context.diagnostic.format(&self.failure_detail, err) else std.fmt.bufPrint(&self.failure_detail, "请求失败 · {s}", .{@errorName(err)}) catch @errorName(err);
            applog.warn(.ai, "ai worker turn failed: {s}", .{self.failure_label});
            self.thread_state.store(3, .release);
        }
    }

    /// UI-thread: consumes a finished worker run. Called from the poll hook
    /// only (thread_state release→acquire already ordered the card data).
    fn streamReset(raw: *anyopaque) void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        self.stream_mailbox.reset();
    }

    fn streamDelta(raw: *anyopaque, delta: ai_provider.Delta) !void {
        const self: *AiHost = @ptrCast(@alignCast(raw));
        if (delta == .text) try self.stream_mailbox.append(delta.text);
        if (delta == .thinking) try self.stream_mailbox.appendThinking(delta.thinking);
        if (delta == .tool_plan) {
            const plan = delta.tool_plan;
            const id = plan.call_id orelse return;
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, plan.arguments, .{}) catch null;
            defer if (parsed) |json| json.deinit();
            const command = if (parsed) |json| blk: {
                if (json.value == .object) for ([_][]const u8{ "command", "path" }) |key| if (json.value.object.get(key)) |value| if (value == .string) break :blk value.string;
                break :blk plan.arguments;
            } else plan.arguments;
            try self.step_mailbox.push(.{ .call_id = id, .name = plan.name orelse "工具调用", .command = command, .detail = plan.arguments, .phase = .assembling, .at_ms = @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms)) });
        }
    }

    fn consumeLiveOutput(self: *AiHost) !void {
        const batch = (try self.stream_mailbox.drain()) orelse return;
        defer self.allocator.free(batch.bytes);
        defer self.allocator.free(batch.thinking);
        const same_owner = self.requestDisplayed();
        const stream = if (same_owner) &self.controller.stream else if (self.assistant_states) |*store| &(store.find(self.request_conversation orelse return) orelse return).stream else return;
        if (batch.reset) {
            if (self.answer_only) {
                // Only reset the current attempt, retaining earlier partials.
                var prefix = @import("ai/card_stream.zig").Stream.init(self.allocator);
                defer prefix.deinit();
                for (stream.cards.items[0..@min(self.retry_prefix_count, stream.count())]) |card| _ = try prefix.append(card);
                stream.clearRetainingCapacity();
                for (prefix.cards.items) |card| _ = try stream.append(card);
            } else stream.clearRetainingCapacity();
            if (same_owner) self.streaming_label = null;
        }
        if (batch.bytes.len > 0) {
            const index = if (self.answer_only) self.retry_prefix_count else 0;
            if (stream.cards.items.len <= index) {
                _ = try stream.append(.{ .text = batch.bytes });
            } else try stream.appendText(index, batch.bytes);
        }
        const turn = if (same_owner) &self.current_turn else &(self.assistant_states.?.find(self.request_conversation orelse return) orelse return).current_turn;
        if (batch.reset) {
            turn.thinking.clearRetainingCapacity();
            turn.thinking_started_ms = null;
            turn.thinking_ended_ms = null;
        }
        const now: u64 = @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        if (batch.thinking.len > 0) {
            if (turn.thinking_started_ms == null) turn.thinking_started_ms = now;
            turn.thinking_ended_ms = null;
            try turn.thinking.appendSlice(self.allocator, batch.thinking);
        }
        if (batch.bytes.len > 0 and turn.thinking.items.len > 0 and turn.thinking_ended_ms == null) turn.thinking_ended_ms = now;
        if (same_owner) {
            if (batch.bytes.len > 0 and batch.thinking.len == 0 and !batch.reset and self.live_card != null and !self.answer_only) self.live_dirty = true else self.conversation_dirty = true;
            self.cx.requestRedraw();
        }
    }

    fn refreshLiveMarkdown(self: *AiHost) !bool {
        if (!self.live_dirty) return false;
        self.live_dirty = false;
        const card = self.live_card orelse return false;
        const scope = self.conversation_scope orelse return false;
        const stream = &self.controller.stream;
        if (stream.cards.items.len == 0 or stream.cards.items[0] != .text) return false;
        if (self.cx.pressed_node) |node| if (node.isDescendantOf(card)) self.cx.cancelPointerInteractions(.explicit);
        if (self.cx.focus_manager.current_focus) |node| if (node.isDescendantOf(card)) self.cx.clearFocus();
        if (self.live_scope) |previous| previous.dispose();
        self.live_scope = null;
        while (card.children.items.len > 0) {
            const child = card.children.items[card.children.items.len - 1];
            self.cx.detachChild(card, child);
            self.cx.destroyDetached(child);
        }
        self.live_scope = try scope.childScope();
        const body = try @import("ui/ai_message_view.zig").mountWithWidth(self.cx, self.live_scope.?, stream.cards.items[0].text, if (self.card_box) |box| @max(160, box.globalRect().w - 30) else 540);
        body.meta.ownership.meta.test_id = "ai.response";
        try card.appendChild(self.allocator, body);
        return true;
    }

    fn consumeStepEvents(self: *AiHost) !void {
        const events = try self.step_mailbox.drain();
        defer self.allocator.free(events);
        defer for (events) |event| event.deinit(self.allocator);
        if (events.len == 0) return;
        const same = self.requestDisplayed();
        const turn = if (same) &self.current_turn else &(self.assistant_states.?.find(self.request_conversation orelse return) orelse return).current_turn;
        for (events) |event| {
            try @import("ai/step_events.zig").apply(self.allocator, &turn.steps, event);
            if (turn.thinking.items.len > 0 and turn.thinking_ended_ms == null) turn.thinking_ended_ms = event.at_ms;
        }
        if (same) {
            self.conversation_dirty = true;
            self.cx.requestRedraw();
        }
    }

    fn consumeResult(self: *AiHost) void {
        if (self.request_text) |owned| {
            self.allocator.free(owned);
            self.request_text = null;
        }
        self.clearRequestHistory();
        self.syncOwner() catch return;
        const same_owner = self.requestDisplayed();
        const stream = if (same_owner) &self.controller.stream else &(self.assistant_states.?.find(self.request_conversation orelse return) orelse return).stream;
        stream.clearRetainingCapacity();
        for (self.manager.cards.cards.items) |card| {
            _ = stream.append(card) catch break;
        }
        if (same_owner) self.refresh("AI response");
    }

    fn retainToolResults(self: *AiHost) !bool {
        const run = self.manager.tool_run orelse return false;
        if (run.turn_id != self.manager.turn_id) return false;
        var sources: [16]@import("ai/tool_results.zig").Source = undefined;
        if (self.requestDisplayed()) return self.tool_results.capture(run, self.tool_bridge.resultSources(&sources));
        const store = if (self.assistant_states) |*v| v else return false;
        const state = store.find(self.request_conversation orelse return false) orelse return false;
        if (state.tool_results == null) state.tool_results = @import("ai/tool_results.zig").Store.init(self.allocator);
        return state.tool_results.?.capture(run, self.tool_bridge.resultSources(&sources));
    }

    fn wireHistoryFailureLabel(err: anyerror) []const u8 {
        return if (err == error.ToolTranscriptLimit) "对话上下文已达上限，请新建 AI 会话继续" else "无法保留完整对话上下文，请新建 AI 会话继续";
    }

    fn retainWireHistory(self: *AiHost, completed: bool) !void {
        const run = self.manager.tool_run orelse return;
        if (run.turn_id != self.manager.turn_id) return;
        const owner = self.request_owner orelse return;
        if (!owner.eql(run.scope.owner)) return error.ToolOwnerChanged;
        const store = if (self.assistant_states) |*value| value else return;
        const destination = store.wireHistoryFor(self.request_conversation orelse return, self.display_conversation, &self.wire_history) orelse return;
        // Only the real completed provider answer is appended. Display cards,
        // recovery markers and model claims never become synthetic tool results.
        const next = @import("ai/wire_history.zig").History.copy(self.allocator, run.messages.items, if (completed) self.manager.round_text.items else "") catch |err| {
            destination.failure = err;
            return err;
        };
        destination.deinit();
        destination.* = next;
    }

    fn finalizeWorker(self: *AiHost, state: u8) void {
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
        self.retainWireHistory(state == 2 and self.manager.saw_done) catch |err| {
            self.failure_label = wireHistoryFailureLabel(err);
            if (self.workspace) |workspace| workspace.status(self.failure_label);
        };
        _ = self.retainToolResults() catch |err| failed: {
            self.failure_label = @errorName(err);
            if (self.workspace) |workspace| workspace.status(self.failure_label);
            break :failed false;
        };
        if (self.request_attachments) |*bundle| bundle.deinit();
        self.request_attachments = null;
        if (self.request_images) |*bundle| bundle.deinit();
        self.request_images = null;
        self.request_image_refs.clearRetainingCapacity();
        if (process_notifications) |notifications| if (self.request_operation_id) |operation| if (self.request_content_owner) |owner| {
            var final_answer = false;
            for (self.manager.cards.cards.items) |card| if (card == .text and card.text.len > 0) {
                final_answer = true;
                break;
            };
            const uncertain = if (self.manager.tool_run) |run| uncertain_result: {
                if (run.uncertain) break :uncertain_result true;
                for (run.records.items) |record| if (record.generic_results) |results| {
                    for (results) |result| if (result.receipt.remote_effect_unknown or result.status == .outcome_unknown) break :uncertain_result true;
                };
                break :uncertain_result false;
            } else false;
            const resources_released = if (self.manager.tool_run) |run| released: {
                for (run.records.items) |record| {
                    if (record.outcome) |outcome| {
                        for (outcome.targets) |target| if (!target.local_released) break :released false;
                    } else if (record.generic_results) |results| {
                        for (results) |result| if (!result.receipt.local_released) break :released false;
                    } else if (record.dispatched) break :released false;
                }
                break :released true;
            } else true;
            notifications.publishAi(owner, operation, self.manager.turn_id, .{ .result = if (uncertain) .unverified else if (state == 4) .cancelled else if (state == 2 and self.manager.saw_done) .succeeded else .failed, .resources_released = resources_released, .final_answer = state == 2 and self.manager.saw_done and final_answer and !uncertain, .details = .{ .detail = if (state == 3) self.failure_label else "" } }) catch |err| {
                if (self.workspace) |workspace| workspace.statusFailure(@errorName(err));
            };
            self.request_operation_id = null;
        };
        if (self.manager.tool_run) |run| {
            if (self.workspace) |workspace| for (run.records.items) |record| {
                if (!std.mem.eql(u8, record.name, "run_command")) continue;
                if (record.outcome) |outcome| for (outcome.targets) |target| {
                    if (target.remote_effect_unknown) {
                        if (self.tool_bridge.sourceOwner(target.session_id)) |original| workspace.receiveGroupRemoteEffectUnknown(original);
                    }
                };
            };
            for (run.messages.items) |message| if (message.tool_call_id) |id| {
                @import("ai/tool_trace.zig").emit(.{ .event = "tool_feedback", .turn_id = run.turn_id, .round_index = run.round_index, .call_id = id, .content = message.content });
            };
        }
        // A producer may append between the poll's first drain and its terminal
        // release-store. Join, drain again, and empty the channel before reuse.
        self.consumeLiveOutput() catch |err| {
            self.failure_label = @errorName(err);
        };
        self.consumeStepEvents() catch {};
        const completed_turn = if (self.requestDisplayed()) &self.current_turn else &(self.assistant_states.?.find(self.request_conversation orelse return) orelse return).current_turn;
        completed_turn.ended_at_ms = @intCast(@max(0, @import("platform/realtime.zig").milliseconds(self)));
        for (completed_turn.steps.items) |*step| if (step.ended_ms == null) {
            step.phase = if (state == 4) .cancelled else .failed;
            step.ended_ms = @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        };
        completed_turn.elapsed_ms = @as(u64, @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms))) -| completed_turn.started_mono_ms;
        if (self.request_stats.usage_reported and (state == 2 or state == 4) and (!self.answer_only or completed_turn.input_tokens != null)) {
            completed_turn.input_tokens = (if (self.answer_only) completed_turn.input_tokens orelse 0 else @as(u64, 0)) +| self.request_stats.input_tokens;
            completed_turn.output_tokens = (if (self.answer_only) completed_turn.output_tokens orelse 0 else @as(u64, 0)) +| self.request_stats.output_tokens;
        } else {
            completed_turn.input_tokens = null;
            completed_turn.output_tokens = null;
        }
        if (completed_turn.thinking.items.len > 0 and completed_turn.thinking_ended_ms == null) completed_turn.thinking_ended_ms = @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        if (self.allocator.dupe(u8, if (state == 2) self.manager.round_text.items else "")) |answer| {
            self.allocator.free(completed_turn.answer);
            completed_turn.answer = answer;
        } else |_| {}
        const completed_wire = if (self.requestDisplayed()) &self.wire_history else &self.assistant_states.?.find(self.request_conversation.?).?.wire_history;
        if (@import("ai/wire_history.zig").History.copy(self.allocator, completed_wire.messages, "")) |after| {
            completed_turn.after.deinit();
            completed_turn.after = after;
        } else |_| {}
        self.stream_mailbox.discard();
        self.thread_state.store(0, .release);
        if (self.assistant_states) |*store| if (self.request_conversation) |id| {
            if (store.find(id)) |saved| saved.phase = if (state == 4) .stopped else if (state == 2) .done else .failed;
        };
        self.recovery_failed = state == 3;
        if (state == 3) {
            if (self.request_text) |owned| {
                self.allocator.free(owned);
                self.request_text = null;
            }
            self.clearRequestHistory();
            self.consumeResult();
            if (self.requestDisplayed()) self.refresh(self.failure_label);
        } else {
            self.consumeResult();
            if (state == 4 and self.requestDisplayed()) self.refresh("AI 已停止");
        }
        if (self.assistant_states) |*store| if (self.request_conversation) |id| {
            if (store.find(id)) |saved| if (saved.closed) {
                store.remove(id);
                self.request_conversation = null;
            };
        };
        // Completion of a closed/background conversation also releases the
        // shared request slot. Refresh the displayed composer so its send
        // control does not retain the previous request's hidden/busy state.
        if (!self.requestDisplayed()) self.refresh("AI 助手");
    }

    /// UI-thread poll: one after-layout hook, self-scheduling only while a
    /// request is in flight.
    const PollHook = struct {
        host: *AiHost,

        fn cleanup(self: *PollHook) void {
            self.host.cx.removeAfterLayoutHook(self);
            self.host.allocator.destroy(self);
        }

        fn run(ctx: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
            const self: *PollHook = @ptrCast(@alignCast(ctx));
            const host = self.host;
            host.processConversationActions();
            host.processMessageAction() catch |err| host.setFeedback(@errorName(err));
            host.updateDock();
            host.openRequestedSettings();
            var composer_resized = false;
            if (host.composer_input) |input| if (host.composer_node) |composer| {
                if (host.input_placeholder) |placeholder| {
                    const empty = host.prompt.peek().len == 0 and input.state.ime_preedit_len == 0;
                    placeholder.setDisplay(if (empty) .flex else .none);
                    placeholder.setTextColor(app_theme.current().fg_3);
                }
                const group = if (host.display_owner) |owner| owner == .group else false;
                const approval = if (host.approval_view) |view| view.sequence != null else false;
                const compact = if (host.card_box) |card| card.globalRect().h <= 358 else false;
                composer_resized = @import("ui/ai_composer_sizing.zig").update(host.cx, input, composer, group and approval and compact, if (host.attachments_view) |view| view.height() else 0);
            };
            if (host.application_host) |application| host.tool_bridge.pump(application);
            if (host.thread_state.load(.acquire) == 1) if (host.assistant_states) |*store| if (host.request_conversation) |id| {
                if (store.find(id)) |state| state.phase = if (host.tool_bridge.pendingApproval() != null) .approval else .running;
            };
            if (host.sessions_view) |view| if (host.assistant_states) |*store| {
                for (store.states.items) |state| view.updatePhase(state.id, state.phase);
            };
            if (host.approval_view) |view| {
                const same_owner = host.requestDisplayed();
                view.update(if (same_owner) host.tool_bridge.pendingApproval() else null) catch {};
            }
            const colors = app_theme.current();
            if (host.painted_colors == null or !std.meta.eql(host.painted_colors.?, colors)) {
                const styles = @import("ui/ai_assistant_styles.zig");
                if (host.window_base) |base| base.set(styles.windowControl());
                for (host.window_hovers, 0..) |hover, index| if (hover) |value| value.set(styles.controlHover(switch (index) {
                    0 => .collapse,
                    1 => .maximize,
                    else => .close,
                }));
                for (host.window_icons) |icon| {
                    if (icon) |node| _ = node.setTint(colors.fg_2);
                }
                for (host.session_icons) |icon| if (icon) |node| {
                    _ = node.setTint(colors.fg_2);
                };
                if (host.send_base) |base| base.set(styles.primary());
                if (host.feedback) |node| node.setTextColor(colors.warn);
                host.painted_colors = colors;
                host.refresh("AI 助手");
            }
            const previous_owner = host.display_owner;
            host.syncOwner() catch {};
            host.pumpAttachments() catch |err| host.refresh(@errorName(err));
            host.pumpImages() catch |err| host.refresh(@errorName(err));
            if (host.remote_picker) |picker| {
                picker.safeTick() catch |err| host.refresh(@errorName(err));
                if (picker.open_state and host.display_owner != null and picker.owner != null and !picker.owner.?.eql(host.display_owner.?)) picker.close();
                if (picker.open_state) if (host.attachment_preview_holder) |holder| holder.setDisplay(.flex);
            }
            if (previous_owner != null and host.display_owner != null and !@import("ai/tool_scope.zig").Owner.eql(previous_owner.?, host.display_owner.?)) host.refresh("AI · 当前助手");
            if (host.runtime_config) |runtime| if (host.painted_config_revision != runtime.value.config_revision) {
                host.painted_config_revision = runtime.value.config_revision;
                host.composer_hash = null;
                host.refresh("AI 助手");
            };
            host.refreshComposer() catch |err| {
                host.refresh(@errorName(err));
            };
            host.consumeLiveOutput() catch |err| {
                host.request_cancel.cancel();
                host.refresh(@errorName(err));
            };
            host.consumeStepEvents() catch |err| host.refresh(@errorName(err));
            const state = host.thread_state.load(.acquire);
            if (state >= 2) host.finalizeWorker(state);
            host.applyRecovery();
            host.updateStrip();
            if (host.recoveryVisible()) {
                const seconds = (host.manager.cooldownRemainingMs() + 999) / 1000;
                if (seconds != host.recovery_cooldown_seconds) {
                    host.recovery_cooldown_seconds = seconds;
                    host.conversation_dirty = true;
                }
                if (seconds != 0) host.cx.scheduleRedrawAfterNs(1000 * 1_000_000);
            }
            const rebuild = host.conversation_dirty;
            if (rebuild) {
                host.conversation_dirty = false;
                const snap = host.controller.snapshot(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, .{ .x = 0, .y = 0, .width = 1200, .height = 800 });
                host.rebuildConversation(&snap);
            }
            const live_updated = if (!rebuild) host.refreshLiveMarkdown() catch false else false;
            const bubbles_resized = host.resizeConversationBubbles();
            if (!rebuild and !live_updated and !composer_resized and !bubbles_resized) if (host.tail_follow) |*follow| {
                if ((host.attachments_view == null or !host.attachments_view.?.isPreviewOpen()) and (host.images_view == null or !host.images_view.?.isPreviewOpen())) follow.update();
            };
            if (state == 1) {
                host.cx.scheduleRedrawAfterNs(33 * 1_000_000);
                return if (rebuild or live_updated or composer_resized or bubbles_resized) .needs_layout else .done;
            }
            return if (rebuild or live_updated or composer_resized or bubbles_resized) .needs_layout else .done;
        }
    };

    fn cleanup(self: *AiHost) void {
        self.compaction.deinit();
        self.model_discovery.deinit();
        // Cancel rate-limit waits and join before releasing request-owned state.
        self.request_cancel.cancel();
        self.tool_bridge.shutdown(self.application_host);
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
        self.cancelAttachmentReaders(null);
        self.attachment_readers.deinit(self.allocator);
        self.cancelImageReaders(null);
        self.image_readers.deinit(self.allocator);
        if (self.request_images) |*bundle| bundle.deinit();
        self.request_image_refs.deinit(self.allocator);
        self.clearPreflightImageRefs();
        self.preflight_image_refs.deinit(self.allocator);
        if (self.last_user_images) |*bundle| bundle.deinit();
        if (self.request_attachments) |*bundle| bundle.deinit();
        for (self.history.items) |*message| message.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.clearRequestHistory();
        self.wire_history.deinit();
        if (self.assistant_states) |*store| store.deinit();
        self.manager.deinit();
        // Scope disposes child conversation widgets before this parent cleanup.
        self.tool_results.deinit();
        self.tool_bridge.deinit();
        self.stream_mailbox.deinit();
        self.step_mailbox.deinit();
        self.current_turn.deinit(self.allocator);
        if (self.recall_draft) |value| self.allocator.free(value);
        self.controller.deinit();
        if (self.request_text) |owned| self.allocator.free(owned);
        if (self.last_user_text) |owned| self.allocator.free(owned);
        if (self.last_user_wire) |owned| self.allocator.free(owned);
        if (self.last_user_attachments) |*bundle| bundle.deinit();
        if (self.native_binding) |binding| self.allocator.destroy(binding);
        if (self.native_client) |client| self.allocator.destroy(client);
        if (self.native_context) |context| self.allocator.destroy(context);
        if (self.request_config) |*snapshot| snapshot.deinit();
        if (self.request_context) |*context| context.deinit(self.allocator);
        if (self.ai_io) |io| {
            io.deinit();
            self.allocator.destroy(io);
        }
        self.allocator.destroy(self);
    }
};

const RenameTabCtx = struct {
    menu: *MenuHost,
    tab_index: usize,
    fn submit(self: *@This(), value: []const u8) void {
        const workspace = self.menu.workspace orelse return;
        workspace.renameTab(self.tab_index, value) catch |err| workspace.statusFailure(@errorName(err));
        if (self.menu.rename_input) |node| {
            self.menu.cx.detachChild(self.menu.panel, node);
            self.menu.cx.destroyDetached(node);
            self.menu.rename_input = null;
        }
    }
};

const MenuHost = struct {
    pending_sidebar_action: ?struct { owner: @import("host/identity.zig").AssetOwner, action: @import("ui/sidebar_view.zig").HostAction } = null,

    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    state: MenuState = .{},
    panel: *ui.Node,
    chrome: ?*ui.Node = null,
    popover_open: ?*ui.Signal(bool) = null,
    scope: *ui.Scope,
    /// Rows of the currently rendered menu, rebuilt per show(); row_index →
    /// item index mapping is 1:1 (separators/headers own their row nodes).
    rows: std.ArrayList(*ui.Node) = .empty,
    row_scope: ?*ui.Scope = null,
    item_rows: std.ArrayList(MenuRow) = .empty,
    render_revision: u64 = 0,
    workspace: ?*ws.Workspace = null,
    ai: ?*AiHost = null,
    wizard: ?*wizard_mod.Wizard = null,
    wizard_host: ?*WizardHost = null,
    edit_host_index: ?usize = null,
    /// Host registry index when the menu targets a sidebar row.
    context_host: ?usize = null,
    /// Tab index when the menu targets the tab strip.
    context_tab: ?usize = null,
    anchor: ui.ComputedRect = .{ .x = 0, .y = 40, .w = 0, .h = 0 },
    rename_input: ?*ui.Node = null,
    rename_scope: ?*ui.Scope = null,
    history_host: ?*HistoryHost = null,
    captured_tab: ?@import("host/identity.zig").TabId = null,
    captured_owner: ?@import("host/identity.zig").ContentOwner = null,
    captured_terminal_intent: ?AiHost.TerminalIntent = null,
    captured_host: ?ws.HostId = null,
    captured_asset: ?@import("host/identity.zig").AssetOwner = null,
    asset_action_view: ?*@import("ui/asset_action_view.zig").View = null,
    asset_action_colors: ?app_theme.Colors = null,
    sidebar_search_value: ?*ui.Signal([]const u8) = null,
    using_capture: bool = false,
    settings: ?*SettingsHost = null,
    transfer_host: ?*TransferHost = null,
    global_theme_context: ?*anyopaque = null,
    background_socks: ?*@import("ui/socks_background_host.zig").Host = null,
    global_theme: ?*const fn (*anyopaque) void = null,

    const MenuRow = struct { node: *ui.Node, item_index: usize, enabled: bool, style: *ui.Signal(ui.BoxStyle) };

    fn show(self: *MenuHost, trigger: MenuTrigger) void {
        self.showWith(trigger, null, null);
    }

    /// Full trigger entry: carries the sidebar host / tab strip context the
    /// actions need (open a session for host N, close tab M, …).
    fn showWith(self: *MenuHost, trigger: MenuTrigger, host_index: ?usize, tab_index: ?usize) void {
        // Right-click in the terminal area is the smart action per the design
        // mockups: selection present = copy, empty = paste. The full menu is
        // middle-click.
        if (trigger == .terminal_right_click) {
            self.smartRightClick();
            return;
        }
        const kind = @import("ui/context_menu_state.zig").kindFor(trigger);
        self.context_host = if (kind == .host_asset) host_index else null;
        self.captured_host = if (self.context_host) |index| if (self.workspace) |workspace| workspace.hostId(index) else null else null;
        self.captured_asset = if (self.context_host) |index| if (self.workspace) |workspace| if (index < workspace.registry.hosts.len) workspace.registry.hosts[index].owner() else null else null else null;
        self.context_tab = tab_index orelse if (kind != .host_asset) if (self.workspace) |workspace| workspace.active_tab else null else null;
        self.captured_tab = null;
        self.captured_owner = null;
        self.captured_terminal_intent = null;
        if (self.workspace) |workspace| if (self.context_tab) |index| if (index < workspace.tabs.items.len) {
            self.captured_tab = workspace.tabs.items[index].tab_id;
            self.captured_owner = workspace.tabs.items[index].content_owner;
            if (kind == .terminal) self.captured_terminal_intent = self.terminalIntent(index);
        };
        self.state.show(kind, .{
            .capability_snapshot = self.capabilitiesForTab(self.context_tab),
            .has_saved_connection = if (self.workspace) |workspace| if (self.context_tab) |index| if (index < workspace.tabs.items.len) workspace.tabs.items[index].host_snapshot != null else false else null else null,
            .new_window_available = process_windows != null and self.captured_asset != null,
            .local_session = self.isLocalTarget(),
            .read_only = self.localTargetReadonly(),
            .transfer_available = self.transferTargetAvailable(),
            .has_selection = self.activeHasSelection() and (kind != .terminal or self.captured_terminal_intent != null),
            .multi_tabs = if (self.workspace) |w| w.model.tabs.items.len > 1 else false,
            .background_socks = self.backgroundAvailable(),
            .background_active = if (self.background_socks) |background| if (self.captured_asset) |asset| background.hasAsset(asset) else false else false,
        });
        self.render() catch |err| {
            applog.warn(.ui, "menu render failed: {s}", .{@errorName(err)});
            return;
        };
        if (self.popover_open) |open| open.set(true);
        self.positionPanel();
        self.cx.requestRedraw();
    }

    /// MenuBridge callback: (ctx, trigger, host_index, tab_index, multi_tabs).
    fn sidebarAction(ctx: ?*anyopaque, index: usize, action: @import("ui/sidebar_view.zig").HostAction) void {
        const self: *MenuHost = @ptrCast(@alignCast(ctx orelse return));
        const workspace = self.workspace orelse return;
        if (index >= workspace.registry.hosts.len) return;
        self.pending_sidebar_action = .{ .owner = workspace.registry.hosts[index].owner(), .action = action };
        self.cx.requestRedraw();
    }
    fn drainSidebarAction(self: *MenuHost) void {
        const pending = self.pending_sidebar_action orelse return;
        self.pending_sidebar_action = null;
        const workspace = self.workspace orelse return;
        _ = workspace.registry.get(pending.owner) catch return;
        const index = workspace.registry.indexOf(pending.owner.id) orelse return;
        self.hide();
        self.context_host = index;
        self.captured_host = workspace.hostId(index);
        self.captured_asset = pending.owner;
        self.context_tab = null;
        self.captured_tab = null;
        self.captured_owner = null;
        self.runCapturedAction(if (pending.action == .copy) .clone_host else .edit_host);
    }
    fn bridgeFire(ctx: ?*anyopaque, trigger: MenuTrigger, host_index: usize, tab_index: ?usize, multi_tabs: bool, anchor: ui.ComputedRect) void {
        const self: *MenuHost = @ptrCast(@alignCast(ctx orelse return));
        _ = multi_tabs; // recomputed inside showWith from the live tab count
        self.anchor = anchor;
        self.showWith(trigger, host_index, tab_index);
    }

    fn hide(self: *MenuHost) void {
        if (self.popover_open) |open| open.set(false);
        self.state.dismiss();
        self.cx.requestRedraw();
    }

    fn popoverChanged(self: *MenuHost, open: bool) void {
        if (!open) self.state.dismiss();
    }

    fn popoverAnchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *MenuHost = @ptrCast(@alignCast(raw));
        const host = self.state.open == .host_asset;
        return .{ .x = self.anchor.x + (if (host) self.anchor.w else @as(f32, 0)), .y = self.anchor.y, .w = 0, .h = if (host) 0 else self.anchor.h };
    }

    fn positionPanel(self: *MenuHost) void {
        const width: f32 = if (self.state.open == .host_asset) 258 else if (self.state.context.local_session) (if (self.state.open == .tab or self.state.open == .session_ended) 284 else 280) else if (self.state.open == .tab) 258 else if (self.state.open == .terminal) 280 else 240;
        const local_tab_menu = self.state.context.local_session and (self.state.open == .tab or self.state.open == .session_ended);
        const padding: f32 = if (local_tab_menu) 12 else 14;
        if (self.chrome) |chrome| chrome.setStyleInline(self.allocator, .{ .width = .{ .px = width }, .padding = .{ .left = padding, .right = padding, .top = if (self.state.open == .terminal and !self.state.context.local_session) 17 else padding, .bottom = if (self.state.open == .terminal and !self.state.context.local_session) 17 else padding }, .gap = if (local_tab_menu) 2 else 1 });
        self.panel.setStyle(self.allocator, .width, .fill());
        self.panel.markLayoutDirty();
    }

    fn isLocalTarget(self: *const MenuHost) bool {
        const workspace = self.workspace orelse return false;
        const index = self.context_tab orelse return false;
        return index < workspace.tabs.items.len and workspace.isLocalSession(workspace.tabs.items[index].id);
    }

    fn transferTargetAvailable(self: *MenuHost) bool {
        const transfer = self.transfer_host orelse return false;
        const workspace = self.workspace orelse return false;
        const index = self.context_tab orelse return false;
        if (index >= workspace.tabs.items.len) return false;
        const tab = workspace.tabs.items[index];
        if (tab.closing or tab.archived or tab.failed or tab.runtime == null or tab.content_owner != .session) return false;
        const snapshot = (transfer.application.sessions.capabilitySnapshot(tab.content_owner.session) catch return false) orelse return false;
        return @import("host/actions.zig").project(.upload, snapshot).enabled;
    }

    fn capabilitiesForTab(self: *MenuHost, index: ?usize) ?@import("host/capability_snapshot.zig").Snapshot {
        const workspace = self.workspace orelse return null;
        const selected = index orelse return null;
        if (selected >= workspace.tabs.items.len) return null;
        const owner = workspace.tabs.items[selected].content_owner;
        if (owner != .session) return null;
        const application = if (self.transfer_host) |transfer| transfer.application else if (self.ai) |ai| ai.application_host orelse return null else return null;
        return application.sessions.capabilitySnapshot(owner.session) catch null;
    }

    fn backgroundAvailable(self: *MenuHost) bool {
        if (self.background_socks == null or self.state.open != .host_asset and self.context_host == null) return false;
        const workspace = self.workspace orelse return false;
        const owner = self.captured_asset orelse return false;
        const host = workspace.registry.get(owner) catch return false;
        const manifest = workspace.plugins.find(host.protocolId()) orelse return false;
        return manifest.session_factory != null and manifest.supports(@import("host/plugin_registry.zig").legacyServiceDefinition(.forward)) and @backingInt(owner.id) != 0 and !workspace.shutting_down;
    }

    fn localTargetReadonly(self: *MenuHost) bool {
        if (!self.isLocalTarget()) return false;
        const terminal = self.activeTerminal() orelse return true;
        const owner = self.captured_owner orelse return true;
        return switch (owner) {
            .session => |handle| if (terminal.terminalSnapshot(handle)) |snapshot| snapshot.read_only else true,
            else => true,
        };
    }

    /// Terminal-area right click pastes; dragging copies on release.
    /// The full context menu remains on middle click.
    fn smartRightClick(self: *MenuHost) void {
        if (self.activeTerminal() != null) self.runAction(.paste);
    }

    fn activeTerminal(self: *MenuHost) ?*TerminalViewNode {
        const workspace = self.workspace orelse return null;
        const index = if (self.using_capture or self.state.open != null) blk: {
            const id = self.captured_tab orelse return null;
            const found = workspace.tabIndexById(id) orelse return null;
            if (self.captured_owner) |owner| if (!workspace.tabs.items[found].content_owner.eql(owner)) return null;
            break :blk found;
        } else workspace.active_tab orelse return null;
        if (index >= workspace.tabs.items.len) return null;
        return if (workspace.tabs.items[index].terminal) |*terminal| terminal else null;
    }

    fn terminalIntent(self: *MenuHost, index: usize) ?AiHost.TerminalIntent {
        const workspace = self.workspace orelse return null;
        if (index >= workspace.tabs.items.len) return null;
        const tab = workspace.tabs.items[index];
        if (tab.closing or tab.content_owner != .session or tab.terminal == null) return null;
        const terminal = &tab.terminal.?;
        const surface = terminal.terminal_surface;
        if (surface) |current| if (!current.owner.eql(tab.content_owner.session)) return null;
        if (surface == null and (terminal.worker == null or terminal.history.selected != null)) return null;
        var owner: ai_attachments.Owner = .{ .session = @backingInt(tab.content_owner.session.session_id) };
        var intent: AiHost.TerminalIntent = .{ .tab = tab.tab_id, .source = tab.content_owner.session, .assistant_owner = owner, .selection = if (surface) |current| current.selection else null };
        if (surface == null) {
            const range = terminal.selection.normalized() orelse return null;
            const worker = terminal.worker.?;
            _ = worker.notificationSnapshot(tab.content_owner.session) catch return null;
            intent.legacy_selection = .{ .range = range, .source_version = terminal.selectionSourceVersion() };
        }
        if (workspace.active_group_view != null) {
            const ai = self.ai orelse return null;
            const current = ai.currentScope() orelse return null;
            _ = current.validate(&.{@backingInt(tab.content_owner.session.session_id)}) catch return null;
            owner = current.owner;
            for (current.members.slice()) |member_id| {
                const member = ai.tabForSession(member_id) orelse return null;
                if (member.closing or member.content_owner != .session) return null;
                intent.members[intent.member_count] = member.content_owner.session;
                intent.member_count += 1;
            }
        }
        intent.assistant_owner = owner;
        return intent;
    }

    fn activeHasSelection(self: *MenuHost) bool {
        const terminal = self.activeTerminal() orelse return false;
        return terminal.hasSelection();
    }

    /// Rebuilds the visible menu rows for the open kind from context_menus
    /// data: label + shortcut hint + danger color + selected-row highlight.
    /// Called on show; keyboard moves update the row style signals in place.
    fn render(self: *MenuHost) !void {
        const kind = self.state.open orelse return;
        if (self.render_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        if (self.row_scope) |old_scope| old_scope.dispose();
        self.row_scope = null;
        for (self.rows.items) |row| {
            self.cx.detachChild(self.panel, row);
            self.cx.destroyDetached(row);
        }
        self.rows.clearRetainingCapacity();
        self.item_rows.clearRetainingCapacity();
        self.render_revision += 1;
        const scope = try self.scope.childScope();
        self.row_scope = scope;
        try scope.onCleanup(MenuHost, self, rowScopeEnded);
        const c = app_theme.current();
        if (self.chrome) |chrome| chrome.setBackground(c.overlay);
        const context = self.state.context;
        const host_asset_menu = kind == .host_asset;
        const remote_terminal = kind == .terminal and !context.local_session;
        const local_tab_menu = context.local_session and (kind == .tab or kind == .session_ended);
        if (remote_terminal) {
            const header = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .gap = 6, .margin = .{ .bottom = 8 }, .flex_shrink = 0 }, .{});
            try header.appendChild(self.allocator, try ui.iconTint(self.cx, ui.icons.terminal, c.accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 }));
            const title = try ui.text(self.cx, "终端操作", .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = c.fg_1, .selectable = false });
            title.setStyleInline(self.allocator, .{ .width = .fill(), .flex = 1 });
            try header.appendChild(self.allocator, title);
            const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .a11y_label = "关闭终端操作", .on_click = self.cx.on(MenuHost, self, MenuHost.hide) }).mount(scope, self.cx);
            close.setStyleInline(self.allocator, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .border = .{ .radius = 7, .width = 0, .color = ui.Color.TRANSPARENT } });
            try header.appendChild(self.allocator, close);
            try self.panel.appendChild(self.allocator, header);
            try self.rows.append(self.allocator, header);
        }
        if (host_asset_menu) {
            const name = if (self.captured_asset) |owner| if (self.workspace) |workspace| blk: {
                const host = workspace.registry.get(owner) catch break :blk "主机";
                break :blk host.name;
            } else "主机" else "主机";
            const title = try std.fmt.allocPrint(self.allocator, "主机 · {s}", .{name});
            defer self.allocator.free(title);
            const header = try ui.text(self.cx, title, .{ .font_size = 10.5, .font_weight = 400, .line_height = 16.0 / 10.5, .color = c.fg_3, .text_overflow = .ellipsis, .selectable = false });
            header.setStyleInline(self.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .flex_shrink = 0 });
            try self.panel.appendChild(self.allocator, header);
            try self.rows.append(self.allocator, header);
        }
        const asset_pinned = if (self.captured_asset) |owner| if (self.workspace) |workspace| blk: {
            const host = workspace.registry.get(owner) catch break :blk false;
            break :blk host.pinned;
        } else false else false;
        for (@import("ui/context_menus.zig").items(kind, context), 0..) |item, item_index| {
            if (!@import("ui/context_menus.zig").isVisible(item.action, context)) continue;
            const item_label = if (item.action == .pin_host and asset_pinned) "取消置顶" else if (host_asset_menu) switch (item.action) {
                .clone_host => "复制主机配置",
                .edit_host => "编辑连接配置",
                .history => "历史会话",
                .pin_host => "置顶主机",
                .move_group => "移动到分组",
                .delete_host => "删除主机资产",
                else => item.label,
            } else item.label;
            if (item.separator_before and !host_asset_menu) {
                const line = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 8 }, .margin = ui.Padding.all(4), .flex_shrink = 0 }, .{});
                try self.panel.appendChild(self.allocator, line);
                try self.rows.append(self.allocator, line);
            }
            const enabled = @import("ui/context_menus.zig").isEnabled(item.action, context);
            const selected = enabled and self.state.selected_index == item_index;
            const base = try scope.createSignal(ui.BoxStyle, menuRowStyle(selected));
            const item_click = try self.allocator.create(ItemClick);
            item_click.* = .{ .host = self, .item_index = item_index, .revision = self.render_revision };
            try scope.onCleanup(ItemClick, item_click, ItemClick.cleanup);
            const row = try ui.widgets.Button(.{
                .variant = .ghost,
                .a11y_label = item_label,
                .disabled = !enabled,
                .base_style = base,
                .hover_style = ui.BoxStyle{ .background = c.hover },
                .on_click = self.cx.on(ItemClick, item_click, ItemClick.activate),
                .on_event = onItemEvent,
                .event_context = @as(?*anyopaque, item_click),
            }).mount(scope, self.cx);
            row.setStyleInline(self.allocator, menuRowStyle(selected));
            // Button owns focus, keyboard activation, disabled and pointer
            // behavior. Native visual children express this menu's fixed slots.
            const window_row = host_asset_menu;
            const content = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .width = .fill(), .height = .fill(), .direction = .row, .align_items = .center, .gap = if (remote_terminal or local_tab_menu or window_row) 6 else 8, .padding = if (window_row) .{ .left = 6, .right = 6 } else ui.Padding.all(if (local_tab_menu) 6 else if (remote_terminal) 4 else 0) }, .{});
            row.meta.ownership.meta.test_id = try std.fmt.bufPrint(&item_click.test_id, "context.menu.{s}", .{@tagName(item.action)});
            if (row.behavior.interaction.a11y) |*a11y| a11y.role = .menuitem;
            const host_icon: ?[]const u8 = if (host_asset_menu) switch (item.action) {
                .new_tab => "terminal",
                .edit_host => "sliders-horizontal",
                .move_group => "folder-input",
                else => null,
            } else null;
            const icon = ui.icons.get(host_icon orelse item.icon) orelse ui.icons.get(menuIconName(item.action)) orelse ui.icons.terminal;
            const ink = if (item.danger) c.danger_ink else c.fg_1;
            try content.appendChild(self.allocator, try ui.iconTint(self.cx, icon, if (item.danger) c.danger_ink else c.fg_2, .{ .width = .{ .px = if (local_tab_menu) 16 else if (remote_terminal or window_row) 15 else 14 }, .height = .{ .px = if (local_tab_menu) 16 else if (remote_terminal or window_row) 15 else 14 }, .flex_shrink = 0 }));
            const label = try ui.text(self.cx, item_label, .{ .font_size = if (local_tab_menu or window_row) 11.5 else if (remote_terminal) 11 else 12, .line_height = if (window_row) 17.0 / 11.5 else if (local_tab_menu) 16.0 / 11.5 else if (remote_terminal) 17.0 / 11.0 else 1.4, .color = ink, .text_overflow = .ellipsis, .selectable = false });
            label.setStyleInline(self.allocator, if (host_asset_menu) .{ .flex_shrink = 0, .width = .{ .px = 140 } } else .{ .flex_shrink = 1, .width = .{ .grow = .{ .min = 0 } } });
            try content.appendChild(self.allocator, label);
            if (host_asset_menu) {
                try content.appendChild(self.allocator, try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 1 }, .flex_shrink = 1 }, .{}));
                const hint = try ui.text(self.cx, if (item.action == .new_tab) "双击" else if (item.action == .move_group) "›" else "", .{ .font_size = 10, .line_height = 1.5, .color = c.fg_2, .selectable = false });
                hint.setStyleInline(self.allocator, .{ .width = .{ .px = 38 }, .height = .{ .px = 15 }, .flex_shrink = 0 });
                try content.appendChild(self.allocator, hint);
            } else if (item.shortcut) |hint| try content.appendChild(self.allocator, try ui.text(self.cx, hint, .{ .font_size = 10, .color = c.fg_3, .selectable = false }));
            try row.appendChild(self.allocator, content);
            const mounted_row = row;
            try self.panel.appendChild(self.allocator, mounted_row);
            try self.rows.append(self.allocator, mounted_row);
            try self.item_rows.append(self.allocator, .{ .node = row, .item_index = item_index, .enabled = enabled, .style = base });
        }
        self.panel.markLayoutDirty();
    }

    fn menuRowStyle(selected: bool) ui.BoxStyle {
        const c = app_theme.current();
        return .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .justify = .start, .gap = 8, .padding = .{}, .background = if (selected) c.selection else ui.Color.TRANSPARENT, .border = .{ .width = 0, .color = c.border, .radius = 6 }, .flex_shrink = 0 };
    }
    fn menuIconName(action: @import("ui/context_menus.zig").Action) []const u8 {
        return switch (action) {
            .copy, .clone_host, .clone_session => "copy",
            .paste => "clipboard",
            .ask_ai => "sparkles",
            .toggle_block_selection => "text-select",
            .toggle_timestamp, .history => "history",
            .search => "search",
            .export_selection, .export_session, .download_file => "download",
            .upload_file => "upload",
            .new_tab => "plus",
            .new_window => "app-window",
            .start_background_socks, .manage_background_socks => "plug-zap",
            .edit_host => "settings",
            .pin_host => "pin",
            .move_group => "folder",
            .delete_host => "trash-2",
            .reconnect => "refresh-cw",
            .close_session => "power",
            .rename_tab => "pencil",
            .tab_color => "palette",
            .view_jump_chain => "network",
            .open_theme => "palette",
            .close_others => "x",
        };
    }
    fn rowScopeEnded(self: *MenuHost) void {
        self.row_scope = null;
    }

    /// Keyboard navigation only updates existing widget styles. It never
    /// destroys the button whose event is currently being dispatched.
    fn refreshSelectionVisual(self: *MenuHost) void {
        for (self.item_rows.items) |row| {
            const style = menuRowStyle(row.enabled and row.item_index == self.state.selected_index);
            row.style.set(style);
            row.node.setStyleInline(self.allocator, style);
        }
        self.cx.requestRedraw();
    }

    /// 克隆主机：arena 追加「name 副本」，写回 hosts.toml，重建侧栏。
    fn cloneHostPersist(self: *MenuHost, host_index: usize) !void {
        const workspace = self.workspace orelse return;
        if (host_index >= workspace.registry.hosts.len) return error.InvalidHost;
        const host = workspace.registry.hosts[host_index];
        const name = try std.fmt.allocPrint(self.allocator, "{s}-副本", .{host.name});
        defer self.allocator.free(name);
        _ = try workspace.applyAssetAction(.{ .clone = .{ .owner = self.captured_asset orelse host.owner(), .name = name } });
    }

    fn pinHostPersist(self: *MenuHost, host_index: usize) !void {
        const workspace = self.workspace orelse return;
        if (host_index >= workspace.registry.hosts.len) return error.InvalidHost;
        const host = workspace.registry.hosts[host_index];
        _ = try workspace.applyAssetAction(.{ .pin = .{ .owner = self.captured_asset orelse host.owner(), .pinned = !host.pinned } });
    }

    fn showAssetAction(self: *MenuHost, mode: @import("ui/asset_action_view.zig").Mode, host_index: usize) !void {
        const workspace = self.workspace orelse return error.MissingWorkspace;
        const view = self.asset_action_view orelse return error.ViewUnavailable;
        if (host_index >= workspace.registry.hosts.len) return error.InvalidHost;
        const owner = self.captured_asset orelse workspace.registry.hosts[host_index].owner();
        const host = try workspace.registry.get(owner);
        const group_index = if (host.asset_group_id) |id| workspace.registry.groupIndex(id) else null;
        const Group = @import("ui/asset_action_view.zig").Group;
        const groups = try self.allocator.alloc(Group, workspace.registry.groups.len);
        defer self.allocator.free(groups);
        for (workspace.registry.groups, groups) |group, *destination| destination.* = .{ .reference = .{ .id = group.group_id, .revision = group.revision }, .name = group.name, .host_count = group.ordered_connection_ids.len };
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}@{s}:{d}", .{ host.user, host.host, host.port });
        defer self.allocator.free(endpoint);
        var open_sessions: usize = 0;
        for (workspace.tabs.items) |tab| if (tab.host_snapshot) |snapshot| {
            if (snapshot.value.connection_id == owner.id) open_sessions += 1;
        };
        try view.retheme();
        self.asset_action_colors = app_theme.current();
        try view.show(.{ .mode = mode, .owner = owner, .name = host.name, .endpoint = endpoint, .source_group = if (group_index) |index| .{ .id = workspace.registry.groups[index].group_id, .revision = workspace.registry.groups[index].revision } else null, .source_group_name = if (group_index) |index| workspace.registry.groups[index].name else "未分组", .groups = groups, .open_sessions = open_sessions });
    }

    fn assetActionAnchor(raw: *anyopaque, owner: @import("host/identity.zig").AssetOwner) ?ui.ComputedRect {
        const self: *MenuHost = @ptrCast(@alignCast(raw));
        const workspace = self.workspace orelse return null;
        const index = workspace.registry.indexOf(owner.id) orelse return null;
        for (workspace.host_rows.items) |row| if (row.host_index == index) return row.node.globalRect();
        return null;
    }
    fn assetActionClosed(raw: *anyopaque) void {
        const self: *MenuHost = @ptrCast(@alignCast(raw));
        const workspace = self.workspace orelse return;
        if (self.asset_action_view) |view| if (view.source) |source| {
            if (workspace.registry.indexOf(source.value.owner.id)) |index| for (workspace.host_rows.items) |row| {
                if (row.host_index == index) {
                    self.cx.setFocus(row.view.menu_trigger);
                    return;
                }
            };
        };
        if (workspace.sidebar_chrome) |sidebar| sidebar.focusSearchFallback();
    }
    fn assetActionCompleted(raw: *anyopaque, mode: @import("ui/asset_action_view.zig").Mode) void {
        const self: *MenuHost = @ptrCast(@alignCast(raw));
        if (self.workspace) |workspace| {
            workspace.status(if (mode == .delete) "主机配置已删除，已打开的会话继续运行" else "主机已移动，已打开的会话继续运行");
            if (workspace.sidebar_chrome) |sidebar| sidebar.focusSearchFallback();
        }
    }
    fn submitAssetAction(raw: *anyopaque, request: @import("config/asset_actions.zig").Request) !@import("config/asset_actions.zig").Result {
        const self: *MenuHost = @ptrCast(@alignCast(raw));
        const workspace = self.workspace orelse return error.MissingWorkspace;
        return workspace.applyAssetAction(request);
    }

    fn viewAssetGroup(raw: *anyopaque, group_id: ?@import("host/identity.zig").AssetGroupId) void {
        const self: *MenuHost = @ptrCast(@alignCast(raw));
        const workspace = self.workspace orelse return;
        if (group_id) |id| if (workspace.registry.groupIndex(id) == null) {
            workspace.status("目标分组已不存在");
            return;
        };
        for (workspace.registry.hosts, 0..) |host, index| if (host.asset_group_id == group_id) {
            workspace.selected_host = index;
            if (self.sidebar_search_value) |value| value.set("");
            workspace.setSearch("");
            for (workspace.host_rows.items) |row| if (row.host_index == index) {
                self.cx.setFocus(row.node);
                break;
            };
            return;
        };
        workspace.status("目标分组当前没有主机");
    }

    fn viewAssetSessions(raw: *anyopaque, owner: @import("host/identity.zig").AssetOwner) void {
        const self: *MenuHost = @ptrCast(@alignCast(raw));
        const workspace = self.workspace orelse return;
        for (workspace.tabs.items, 0..) |tab, index| if (tab.host_snapshot) |snapshot| {
            if (snapshot.value.connection_id == owner.id) {
                workspace.selectTab(index);
                return;
            }
        };
        workspace.status("该主机的会话已关闭");
    }

    /// Executes a menu action against the active session. Copy/paste are
    /// fully wired; the rest surface their status on the status bar so the
    /// interaction loop is complete even where the feature lands later.
    fn runAction(self: *MenuHost, action: @import("ui/context_menus.zig").Action) void {
        const workspace = self.workspace orelse return;
        if (self.using_capture) {
            if (self.captured_asset) |owner| {
                _ = workspace.registry.get(owner) catch {
                    workspace.status("主机配置已变化，请重新打开菜单");
                    return;
                };
            }
            if (self.captured_host) |id| self.context_host = workspace.hostIndex(id) orelse return;
            if (self.captured_tab) |id| {
                self.context_tab = workspace.tabIndexById(id) orelse return;
                if (self.captured_owner) |owner| if (!workspace.tabs.items[self.context_tab.?].content_owner.eql(owner)) return;
            }
        } else {
            self.context_host = null;
            self.context_tab = workspace.active_tab;
        }
        var action_context = self.state.context;
        const current_capabilities = self.capabilitiesForTab(self.context_tab);
        if (self.using_capture) if (action_context.capability_snapshot) |captured| {
            const current = current_capabilities orelse return;
            if (!captured.owner.eql(current.owner) or captured.revision != current.revision) {
                workspace.status("会话能力已变化，请重新打开菜单");
                return;
            }
        };
        action_context.capability_snapshot = current_capabilities;
        if (!@import("ui/context_menus.zig").isVisible(action, action_context) or !@import("ui/context_menus.zig").isEnabled(action, action_context)) return;
        switch (action) {
            .copy => {
                const terminal = self.activeTerminal() orelse return;
                const text = terminal.copySelectionText(self.cx.allocator) catch |err| {
                    workspace.statusFailure("复制失败：无法读取选区");
                    applog.warn(.ui, "copySelection: {s}", .{@errorName(err)});
                    return;
                } orelse return;
                defer self.cx.allocator.free(text);
                if (terminal.terminal_surface) |surface| {
                    surface.copySelectionToClipboard(text) catch |err| surface.showError(err);
                } else if (terminal.copySelectionToClipboard(self.cx, text)) workspace.status("已复制选中内容") else workspace.statusFailure("复制失败：剪贴板不可用");
            },
            .paste => {
                const terminal = self.activeTerminal() orelse return;
                const buffer = self.cx.allocator.alloc(u8, 1024 * 1024 + 1) catch {
                    workspace.statusFailure("粘贴失败：内存不足");
                    return;
                };
                defer self.cx.allocator.free(buffer);
                const text = ui.platform_services.clipboardGetText(self.cx.system_sdk, buffer) orelse {
                    workspace.status("剪贴板为空");
                    return;
                };
                terminal.requestPaste(text) catch |err| {
                    workspace.statusFailure(@errorName(err));
                    return;
                };
            },
            .upload_file, .download_file => {
                if (!self.transferTargetAvailable()) return;
                const index = self.context_tab orelse return;
                const owner = workspace.tabs.items[index].content_owner.session;
                const transfer = self.transfer_host orelse return;
                transfer.showSessionTransfer(owner, if (action == .download_file) .download else .upload, null);
            },
            .search => if (self.activeTerminal()) |terminal| terminal.openSearch(),
            .history => {
                if (self.context_host) |host_index| {
                    if (host_index >= workspace.registry.hosts.len) return;
                    if (self.history_host) |history| {
                        history.show(workspace.registry.hosts[host_index].name, .{ .saved_connection = @backingInt((self.captured_asset orelse return).id) }) catch |err| {
                            workspace.statusFailure(@errorName(err));
                        };
                    }
                } else {
                    const terminal = self.activeTerminal() orelse return;
                    if (!terminal.openHistory()) workspace.status("暂无可回溯的终端历史");
                }
            },
            .toggle_timestamp => {
                const terminal = self.activeTerminal() orelse return;
                const enabled = terminal.toggleTimestampGutter();
                workspace.status(if (enabled) "时间戳侧栏已开启" else "时间戳侧栏已关闭");
            },
            .toggle_block_selection => {
                if (self.isLocalTarget()) {
                    workspace.status("按住 ⌥ 并拖动以进行矩形选择");
                    return;
                }
                const terminal = self.activeTerminal() orelse return;
                const enabled = terminal.toggleBlockSelection();
                workspace.status(if (enabled) "矩形块选模式已开启" else "矩形块选模式已关闭");
            },
            .export_selection => {
                const terminal = self.activeTerminal() orelse return;
                const saved = terminal.exportText(self.cx, workspace.io, .selection) catch |err| {
                    workspace.statusFailure(@errorName(err));
                    return;
                };
                if (saved) workspace.status("已导出选中内容");
            },
            .ask_ai => if (self.ai) |ai| {
                const intent = if (self.using_capture) self.captured_terminal_intent else if (self.context_tab) |index| self.terminalIntent(index) else null;
                ai.openTerminalSelection(intent orelse {
                    workspace.status("终端选区来源不可用，请重新选择后打开菜单");
                    return;
                }) catch |err| workspace.statusFailure(@errorName(err));
            },
            .reconnect => {
                const tab_index = self.context_tab orelse workspace.active_tab orelse return;
                workspace.reconnectTab(tab_index) catch |err| workspace.statusFailure(@errorName(err));
            },
            // ── Host asset actions (sidebar right-click) ──────────────
            .start_background_socks => {
                const background = self.background_socks orelse return;
                background.requestStart(self.captured_host orelse return, self.captured_asset orelse return) catch |err| workspace.statusFailure(@errorName(err));
            },
            .manage_background_socks => {
                const background = self.background_socks orelse return;
                background.showAsset(self.captured_asset orelse return, self.anchor);
            },
            .new_tab => {
                if (self.context_tab) |tab| {
                    workspace.newSessionFromTab(tab) catch |err| workspace.statusFailure(@errorName(err));
                } else if (self.context_host) |host| {
                    workspace.newSession(host) catch |err| workspace.statusFailure(@errorName(err));
                }
            },
            .new_window => {
                const process = process_windows orelse return;
                const source = if (self.transfer_host) |transfer| transfer.application else return;
                const asset = self.captured_asset orelse return;
                _ = workspace.registry.get(asset) catch {
                    workspace.status("主机配置已更改，请重新打开菜单");
                    return;
                };
                process.queue(source, self.captured_host orelse return) catch |err| workspace.statusFailure(@errorName(err));
            },
            .clone_host => {
                const host_index = self.context_host orelse return;
                self.cloneHostPersist(host_index) catch |err| {
                    applog.warn(.ui, "clone host failed: {s}", .{@errorName(err)});
                    workspace.statusFailure("克隆主机失败");
                };
            },
            .edit_host => {
                const host_index = self.context_host orelse if (self.context_tab) |tab| blk: {
                    if (tab >= workspace.tabs.items.len) return;
                    break :blk workspace.tabs.items[tab].host_index;
                } else return;
                const host = self.wizard_host orelse return;
                if (host_index >= workspace.registry.hosts.len) return;
                WizardHost.openCapturedAsset(host, workspace.registry.hosts[host_index].owner()) catch |err| {
                    workspace.statusFailure(@errorName(err));
                    return;
                };
                self.edit_host_index = host_index;
            },
            .pin_host => {
                const host_index = self.context_host orelse return;
                self.pinHostPersist(host_index) catch |err| {
                    applog.warn(.ui, "pin host failed: {s}", .{@errorName(err)});
                    workspace.statusFailure("置顶失败");
                };
            },
            .move_group => {
                const host_index = self.context_host orelse return;
                self.showAssetAction(.move, host_index) catch |err| workspace.statusFailure(@errorName(err));
            },
            .delete_host => {
                const host_index = self.context_host orelse return;
                self.showAssetAction(.delete, host_index) catch |err| workspace.statusFailure(@errorName(err));
            },
            // ── Tab actions (tab strip right-click) ───────────────────
            .tab_color => {
                const index = self.context_tab orelse return;
                if (index >= workspace.tabs.items.len) return;
                workspace.showTabColor(workspace.tabs.items[index].tab_id);
            },
            .rename_tab => {
                const tab_index = self.context_tab orelse return;
                if (tab_index >= workspace.tabs.items.len) return;
                workspace.beginRenameTab(workspace.tabs.items[tab_index].id) catch |err| workspace.statusFailure(@errorName(err));
                self.hide();
                self.state.dismiss();
            },
            .clone_session => {
                const tab_index = self.context_tab orelse return;
                if (tab_index >= workspace.tabs.items.len) return;
                workspace.duplicateSessionFromTab(tab_index) catch |err| {
                    workspace.statusFailure(@errorName(err));
                };
            },
            .view_jump_chain => {
                const tab_index = self.context_tab orelse return;
                if (tab_index >= workspace.tabs.items.len) return;
                const host = workspace.tabHost(tab_index) orelse return;
                if (host.jump_chain.len == 0) {
                    workspace.status("直连（无跳板）");
                } else {
                    var buffer: [256]u8 = undefined;
                    var writer = std.Io.Writer.fixed(&buffer);
                    writer.print("跳板链路：{d} 跳", .{host.jump_chain.len}) catch return;
                    for (host.jump_chain) |hop| writer.print(" · {s}", .{hop}) catch break;
                    workspace.status(writer.buffered());
                }
            },
            .open_theme => {
                if (self.global_theme) |show_theme| {
                    show_theme(self.global_theme_context orelse return);
                } else if (self.settings) |settings| {
                    if (!settings.open) settings.toggle();
                    settings.selectPage(0);
                }
            },
            .export_session => {
                const Export = @import("ui/session_export.zig");
                const tab_index = self.context_tab orelse workspace.active_tab orelse return;
                if (tab_index >= workspace.tabs.items.len) return;
                const source_tab = workspace.tabs.items[tab_index];
                const runtime = source_tab.runtime;
                const local_service = if (source_tab.local) blk: {
                    const terminal_view = source_tab.terminal orelse break :blk null;
                    const surface = terminal_view.terminal_surface orelse break :blk null;
                    break :blk @as(?@import("host/terminal_service.zig").Service, surface.service);
                } else null;
                if (runtime == null and local_service == null) {
                    workspace.status("会话尚未连接");
                    return;
                }
                const capture: Export.SessionCapture = .{ .tab_id = source_tab.tab_id, .owner = source_tab.content_owner };
                const format = Export.Format.parse(workspace.app_config.log.export_format) catch |err| {
                    workspace.statusFailure(@errorName(err));
                    return;
                };
                const sdk = self.cx.system_sdk orelse return;
                var path_buffer: [4096]u8 = undefined;
                const path = sdk.runDialog(.{ .kind = .save_file, .title = format.defaultFilename() }, &path_buffer) catch |err| {
                    workspace.statusFailure(@errorName(err));
                    return;
                };
                const destination = path orelse return;
                const current_index = workspace.tabIndexById(capture.tab_id) orelse return;
                const current_tab = workspace.tabs.items[current_index];
                if (!capture.matches(current_tab.tab_id, current_tab.content_owner) or current_tab.runtime != runtime or current_tab.closing) {
                    workspace.status("StaleExportOwner");
                    return;
                }
                const Jobs = @import("ui/session_export_jobs.zig");
                const manager = Jobs.Manager.forCx(self.cx) orelse return;
                if (manager.job != null) {
                    workspace.status("日志正在导出中");
                    return;
                }
                const source: Jobs.Source = if (local_service) |service| blk: {
                    const surface = (current_tab.terminal orelse return).terminal_surface orelse return;
                    if (!surface.service.binding.eql(service.binding)) return;
                    break :blk .{ .live = service.recordingLease() catch |err| {
                        workspace.statusFailure(@errorName(err));
                        return;
                    } };
                } else if (runtime) |current| blk: {
                    if (current.torn_down) return;
                    break :blk .{ .frozen = current.captureExport(std.heap.c_allocator) catch |err| {
                        workspace.statusFailure(@errorName(err));
                        return;
                    } };
                } else return;
                manager.start(source, format, destination) catch |err| workspace.statusFailure(@errorName(err));
            },
            .close_others => {
                const tab_index = self.context_tab orelse return;
                workspace.requestCloseOthers(tab_index);
            },
            .close_session => {
                const tab_index = self.context_tab orelse workspace.active_tab orelse return;
                if (tab_index < workspace.tabs.items.len) workspace.requestCloseTab(tab_index);
            },
        }
    }

    fn runCapturedAction(self: *MenuHost, action: @import("ui/context_menus.zig").Action) void {
        self.using_capture = true;
        defer self.using_capture = false;
        self.runAction(action);
    }

    /// Each rendered set owns its callbacks. The revision prevents delayed
    /// accessibility/pointer activation from targeting a newer menu capture.
    const ItemClick = struct {
        host: *MenuHost,
        item_index: usize,
        revision: u64,
        test_id: [64]u8 = undefined,
        fn activate(self: *ItemClick) void {
            if (self.revision != self.host.render_revision or self.host.state.open == null) return;
            self.host.state.selected_index = self.item_index;
            if (self.host.state.handle(.enter)) |action| {
                self.host.hide();
                self.host.runCapturedAction(action);
            }
        }
        fn cleanup(self: *ItemClick) void {
            self.host.allocator.destroy(self);
        }
    };

    fn onItemEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const item: *ItemClick = @ptrCast(@alignCast(context orelse return .ignored));
        if (item.revision != item.host.render_revision or item.host.state.open == null) return .ignored;
        if (event == .mouse_enter) {
            item.host.state.selected_index = item.item_index;
            item.host.refreshSelectionVisual();
        }
        return .ignored;
    }

    fn onEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const self: *MenuHost = @ptrCast(@alignCast(context orelse return .ignored));
        switch (event) {
            .mouse_down => |mouse| if (mouse.button == .right) {
                self.show(.terminal_right_click);
                return .handled;
            } else if (mouse.button == .middle) {
                self.show(.terminal_middle_click);
                return .handled;
            },
            .key_down => |key| if (self.state.open != null) switch (key.key) {
                .up => {
                    _ = self.state.handle(.up);
                    self.refreshSelectionVisual();
                    return .handled;
                },
                .down => {
                    _ = self.state.handle(.down);
                    self.refreshSelectionVisual();
                    return .handled;
                },
                .@"return" => {
                    if (self.state.handle(.enter)) |action| {
                        self.hide();
                        self.runCapturedAction(action);
                    }
                    return .handled;
                },
                .escape => {
                    _ = self.state.handle(.escape);
                    self.hide();
                    return .handled;
                },
                else => {},
            },
            else => {},
        }
        return .ignored;
    }

    fn cleanup(self: *MenuHost) void {
        if (self.rename_scope) |scope| scope.dispose();
        // The parent already disposed Popover and row child scopes.
        self.row_scope = null;
        self.item_rows.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Host-scoped closed-session history modal.  Rows are built only from the
/// durable session archive; no design-time sample records are ever inserted.
const HistoryHost = struct {
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    workspace: ?*ws.Workspace,
    panel: *ui.Node,
    card: *ui.Node,
    list: *ui.Node,
    scroll: *ui.Node,
    scroll_state: *ui.widgets.scroll_area.ScrollState,
    scroll_content: *ui.Node,
    archive: HistoryArchive,
    model: HistoryModel,
    scope: *ui.Scope,
    row_scope: ?*ui.Scope = null,
    archive_dir_owned: bool = false,
    colors: app_theme.Colors,

    fn show(self: *HistoryHost, host: []const u8, source: @import("ui/history_list.zig").SourceFilter) !void {
        const H = @import("ui/history_styles.zig");
        H.repaint(self.card, self.colors);
        self.colors = app_theme.current();
        try self.model.refresh(source);
        // Keep the modal wholly reachable on short windows.  The list itself
        // is the scroll container; header/footer remain fixed and visible.
        // Do not allow a real history row to make the card extend below the
        // viewport (the design has a bounded floating card, not page scroll).
        const viewport_h = self.cx.viewport.height;
        const viewport_w = self.cx.viewport.width;
        const max_card_h = @max(180, viewport_h - 24);
        const max_scroll_h = @max(116, max_card_h - 48);
        const desired_scroll_h: f32 = if (self.model.len() == 0) 116 else 52 + @as(f32, @floatFromInt(self.model.len())) * H.row_height + @as(f32, @floatFromInt(self.model.len() - 1)) * H.row_gap;
        const scroll_h = @min(max_scroll_h, @min(312, desired_scroll_h));
        self.scroll.style.height = .{ .px = scroll_h };
        // ScrollArea keeps its viewport in state rather than deriving it from
        // the node style on every frame.  Update both when the modal opens or
        // the window is resized, otherwise maxScrollY() can remain based on
        // the initial 92px viewport and rows near the bottom stay unreachable.
        self.scroll_state.viewport_height = scroll_h;
        self.scroll_state.external_content_height = true;
        self.scroll_state.content_height = desired_scroll_h;
        self.card.setStyleInline(self.allocator, H.card());
        self.card.style.width = .{ .px = @min(560, @max(280, viewport_w - 24)) };
        self.card.markLayoutDirty();
        self.scroll.markLayoutDirty();
        try self.rebuild(host);
        self.panel.setDisplay(.flex);
        // Capture Escape and button keyboard activation in the modal itself;
        // without an explicit focus target, the previously focused terminal
        // can consume the event and leave the history scrim stranded.
        self.panel.behavior.interaction.focusable = true;
        self.cx.setFocus(self.panel);
        self.cx.requestRedraw();
    }

    fn close(self: *HistoryHost) void {
        self.panel.setDisplay(.none);
        var focus_restored = false;
        if (self.workspace) |workspace| {
            if (workspace.active_tab) |index| {
                if (index < workspace.tabs.items.len) {
                    self.cx.setFocus((if (workspace.tabs.items[index].terminal) |*terminal| terminal.root else workspace.tabs.items[index].root));
                    focus_restored = true;
                }
            }
        }
        if (!focus_restored) {
            // The modal can be opened from a host menu before a workspace tab
            // exists. Do not leave keyboard focus on the hidden panel.
            self.cx.setFocus(self.cx.root);
        }
        self.cx.requestRedraw();
    }

    fn rebuild(self: *HistoryHost, host: []const u8) !void {
        if (self.row_scope) |scope| scope.dispose();
        self.row_scope = null;
        while (self.list.children.items.len > 0) {
            const old = self.list.children.items[self.list.children.items.len - 1];
            self.cx.detachChild(self.list, old);
            self.cx.destroyDetached(old);
        }
        const rows = try ui.Scope.init(self.allocator, self.scope, self.cx.owner);
        self.row_scope = rows;
        const H = @import("ui/history_styles.zig");
        // Host is display text only; refresh uses the captured stable source identity.
        const identity_text = try std.fmt.allocPrint(self.allocator, "主机  {s}", .{host});
        defer self.allocator.free(identity_text);
        try self.list.appendChild(self.cx.allocator, try ui.text(self.cx, identity_text, H.text(12, 400, true)));
        if (self.model.len() == 0) {
            const empty = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 64 }, .align_items = .center, .justify = .center, .flex_shrink = 0 }, .{});
            const title = try ui.text(self.cx, "还没有会话历史", H.emptyTitle());
            title.meta.ownership.meta.test_id = "history.empty";
            try empty.appendChild(self.cx.allocator, title);
            try self.list.appendChild(self.cx.allocator, empty);
            return;
        }
        for (self.model.entries.items, 0..) |entry, index| {
            var date_buffer: [64]u8 = undefined;
            var duration_buffer: [64]u8 = undefined;
            var exit_buffer: [32]u8 = undefined;
            const row = try ui.box(self.cx, H.row(), .{});
            row.meta.ownership.meta.test_id = "history.record";
            const metadata = try ui.box(self.cx, H.metadata(), .{});
            const date = try ui.text(self.cx, H.dateLabel(&date_buffer, entry.started_ms), H.text(12, 500, false));
            date.setStyleInline(self.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
            try metadata.appendChild(self.cx.allocator, date);
            const duration = try ui.text(self.cx, H.durationLabel(&duration_buffer, entry.duration_ms), H.text(11, 400, true));
            duration.setStyleInline(self.allocator, .{ .width = .{ .px = if (entry.duration_ms >= std.time.ms_per_hour) 81 else 46 }, .flex_shrink = 0 });
            try metadata.appendChild(self.cx.allocator, duration);
            const chip = try ui.box(self.cx, H.chip(), .{});
            const exit_text = if (entry.exit_code) |code| std.fmt.bufPrint(&exit_buffer, "exit {d}", .{code}) catch "exit ?" else "连接中断";
            const exit_label = try ui.text(self.cx, exit_text, H.text(10.5, 500, true));
            exit_label.setStyleInline(self.allocator, .{ .width = .{ .px = if (entry.exit_code == null) 56 else 48 }, .flex_shrink = 0 });
            try chip.appendChild(self.cx.allocator, exit_label);
            try metadata.appendChild(self.cx.allocator, chip);
            try row.appendChild(self.cx.allocator, metadata);
            const actions = try ui.box(self.cx, H.actions(), .{});
            try actions.appendChild(self.cx.allocator, try @import("ui/history_row.zig").mount(self.cx, rows, @ptrCast(self), onRowAction, index, .export_cast));
            try actions.appendChild(self.cx.allocator, try @import("ui/history_row.zig").mount(self.cx, rows, @ptrCast(self), onRowAction, index, .replay));
            try row.appendChild(self.cx.allocator, actions);
            try self.list.appendChild(self.cx.allocator, row);
        }
    }

    fn onRowAction(raw: *anyopaque, index: usize, action: @import("ui/history_row.zig").Action) void {
        const self: *HistoryHost = @ptrCast(@alignCast(raw));
        self.runRowAction(index, action) catch |err| {
            if (self.workspace) |workspace| workspace.status(if (err == error.FileNotFound) "历史录制文件不存在" else @errorName(err));
        };
    }

    fn runRowAction(self: *HistoryHost, index: usize, action: @import("ui/history_row.zig").Action) !void {
        const path = try self.model.replayPath(index);
        const entry = self.model.at(index) orelse return error.InvalidHistoryIndex;
        switch (action) {
            .replay => {
                const data = try self.archive.dir.readFileAlloc(self.archive.io, path, self.allocator, .limited(128 * 1024 * 1024));
                defer self.allocator.free(data);
                var timeline = try @import("ui/history_cast.zig").load(self.allocator, data);
                defer timeline.deinit();
                const workspace = self.workspace orelse return error.WorkspaceUnavailable;
                try workspace.openArchivedSession(entry.host, entry.user, &timeline);
                self.close();
            },
            .export_cast => {
                const Export = @import("ui/session_export.zig");
                const workspace = self.workspace orelse return error.WorkspaceUnavailable;
                const format = try Export.Format.parse(workspace.app_config.log.export_format);
                const captured_path = try self.allocator.dupe(u8, path);
                defer self.allocator.free(captured_path);
                const capture: Export.ArchiveCapture = .{ .id = entry.id, .cast_path = captured_path };
                const sdk = self.cx.system_sdk orelse return error.NativeDialogUnavailable;
                var path_buffer: [4096]u8 = undefined;
                const target = try sdk.runDialog(.{ .kind = .save_file, .title = format.defaultFilename() }, &path_buffer);
                const destination = target orelse return;
                var valid = false;
                for (self.model.entries.items) |current| if (capture.matches(current)) {
                    valid = true;
                    break;
                };
                if (!valid) return error.StaleExportOwner;
                const Jobs = @import("ui/session_export_jobs.zig");
                const manager = Jobs.Manager.forCx(self.cx) orelse return error.WorkspaceUnavailable;
                if (manager.job != null) return error.ExportInProgress;
                const lease = try @import("vt/session_archive.zig").acquireLease(std.heap.c_allocator, self.archive.io, self.archive.dir, captured_path);
                try manager.start(.{ .archive = lease }, format, destination);
            },
        }
    }

    fn onClose(raw: *anyopaque) void {
        const self: *HistoryHost = @ptrCast(@alignCast(raw));
        self.close();
    }

    fn onPanelEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const self: *HistoryHost = @ptrCast(@alignCast(context orelse return .ignored));
        switch (event) {
            .key_down => |key| if (key.key == .escape) {
                self.close();
                return .handled;
            },
            else => {},
        }
        return .ignored;
    }

    fn cleanup(self: *HistoryHost) void {
        // Child scopes are disposed before parent cleanup by Scope.
        self.model.deinit();
        if (self.archive_dir_owned) self.archive.dir.close(self.archive.io);
        self.allocator.destroy(self);
    }
};

const SettingsHost = struct {
    const RecordCleanup = @import("host/record_cleanup.zig");
    const RecordCleanupView = @import("ui/record_cleanup_view.zig");
    const DataCleanupView = @import("ui/application_data_cleanup_view.zig");
    const CleanupOrigin = struct { draft_id: u64, page: usize, scroll: f32, focus: ?ui.hit.NodeHandle };
    const ThemeRegistry = @import("config/theme_registry.zig").Registry;
    const AppearanceWorker = @import("config/appearance_ui_worker.zig").Worker;
    const AppearanceContext = @import("config/appearance_ui_context.zig").Context;
    const AppearanceCommand = @import("config/appearance_ui_context.zig").Command;
    const FontResolved = @import("config/appearance_font.zig").Resolved;
    const AppearanceApply = @import("config/appearance_apply.zig");
    const BackgroundTexture = @import("ui/background_texture.zig").Texture;
    const DecisionKind = enum { close, reset };
    notification_window: ?@import("host/notification_host.zig").WindowId = null,
    application_host: ?*application_host_mod.ApplicationHost = null,
    recorded_keys: @import("config/keybindings.zig").Map = .{},
    recording: bool = false,
    keybinding_recorder: ?*@import("config/keybinding_picker.zig").Recorder = null,
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    scope: *ui.Scope,
    controller: SettingsController,
    runtime: *RuntimeConfig,
    io: std.Io,
    panel: *ui.Node,
    status: *ui.Node,
    /// Left navigation list (rebuilt on page switch for the highlight).
    nav_list: *ui.Node = undefined,
    navigation: ?*ui.Node = null,
    header_title: ?*ui.Node = null,
    header_icon: ?*ui.Node = null,
    layout: ?*ui.Node = null,
    /// Right content column (rebuilt on page switch / save / discard).
    content: *ui.Node = undefined,
    open: bool = false,
    content_scope: ?*ui.Scope = null,
    nav_scope: ?*ui.Scope = null,
    picker_nodes: std.ArrayList(*ui.Node) = .empty,
    card: ?*ui.Node = null,
    search_input: ?ui.widgets.input.InputResult = null,
    picker: ?*ui.Node = null,
    providers: ?*@import("config/ai_provider_settings.zig").ProviderView = null,
    pending_rebuild: bool = false,
    workspace: ?*ws.Workspace = null,
    mounted_page: ?settings_content_view.Mounted = null,
    mounted_page_index: usize = 0,
    mounted_filtered: bool = false,
    mounted_theme_library_open: bool = false,
    mounted_plugin_preview: ?@import("config/plugin_page.zig").PreviewKind = null,
    search_scroll_offsets: [8]f32 = @splat(0),
    plugin_preview_scroll_offsets: [2][7]f32 = @splat(@splat(0)),
    focus_return: ?*ui.Node = null,
    decision_open: ?*ui.Signal(bool) = null,
    decision_title: ?*ui.Signal([]const u8) = null,
    decision_message: ?*ui.Signal([]const u8) = null,
    decision_dialog: ?*ui.Node = null,
    decision_icon: ?*ui.Node = null,
    decision_title_node: ?*ui.Node = null,
    decision_message_node: ?*ui.Node = null,
    decision_notice: ?*ui.Node = null,
    native_close_waiter: ?*bool = null,
    decision_kind: DecisionKind = .close,
    restore_scroll: bool = false,
    decision_cancel: ?*ui.Node = null,
    decision_cancel_label: ?*ui.Signal([]const u8) = null,
    decision_save: ?*ui.Node = null,
    decision_discard: ?*ui.Node = null,
    decision_reset: ?*ui.Node = null,
    record_cleanup: ?RecordCleanup.Controller = null,
    record_cleanup_dir: ?std.Io.Dir = null,
    record_cleanup_view: ?*RecordCleanupView.View = null,
    record_cleanup_material: ?*@import("ui/background_layers.zig").View = null,
    record_cleanup_origin: ?CleanupOrigin = null,
    data_cleanup_view: ?*DataCleanupView.View = null,
    data_cleanup_origin: ?CleanupOrigin = null,
    registry: ThemeRegistry = undefined,
    appearance_state: AppearanceApply.State = undefined,
    appearance_context: AppearanceContext = undefined,
    resource_worker: ?AppearanceWorker = null,
    resource_dir: ?std.Io.Dir = null,
    appearance_initialized: bool = false,
    font_result: ?FontResolved = null,
    font_problem: ?anyerror = null,
    installation: ?@import("config/theme_registry.zig").Installation = null,
    pending_save: ?bool = null,
    pending_discard_close: bool = false,
    loading_saved_background: bool = false,
    app_runtime: ?*App = null,
    draft_texture: ?BackgroundTexture = null,
    pending_texture: ?BackgroundTexture = null,
    committed_texture: ?BackgroundTexture = null,
    preview_scope: ?*ui.Scope = null,
    preview_root: ?*ui.Node = null,
    preview_actions: ?settings_content_view.MaterialPreview = null,
    preview_viewport: ?*ui.Node = null,
    /// Renderer publication is installed by the application host. It shares
    /// this State/Registry with the instantaneous status theme transaction.
    on_appearance_publish: ?*const fn (*SettingsHost) void = null,
    on_material_preview: ?*const fn (*SettingsHost, bool) void = null,

    const settings_pages_mod = @import("config/settings_pages.zig");
    const settings_values_mod = @import("config/settings_values.zig");

    fn initAppearance(self: *SettingsHost) !void {
        self.registry = try ThemeRegistry.init(self.allocator);
        errdefer self.registry.deinit();
        const directory = try std.Io.Dir.cwd().openDir(self.io, self.dataDirectory(), .{});
        errdefer directory.close(self.io);
        self.resource_worker = try AppearanceWorker.init(self.allocator, self.io, directory, "themes/favorites.json");
        errdefer self.resource_worker.?.deinit();
        self.resource_dir = directory;
        self.appearance_state = .{ .allocator = self.allocator };
        self.appearance_context = .{ .registry = &self.registry, .runtime = self.runtime, .context = self, .request = appearanceCommand, .busy = appearanceBusy, .font_status = fontStatus, .mount_image = mountAppearanceImage, .mount_material_preview = mountAppearanceMaterial };
        self.resource_worker.?.background_preflight = .{ .context = self, .prepare = prepareDraftTexture, .complete = completeDraftTexture };
        try self.resource_worker.?.loadLibrary(&self.registry);
        self.appearance_initialized = true;
    }

    /// Includes the shared registry lease and deferred Save/Discard. Native
    /// close waits on this same gate instead of invalidating a worker's owner.
    fn busy(self: *const SettingsHost) bool {
        return self.controller.state() == .saving or self.pending_save != null or self.pending_discard_close or if (self.resource_worker) |*worker| worker.busy() else false;
    }
    fn appearanceBusy(raw: *anyopaque) bool {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        return self.busy();
    }
    fn fontStatus(raw: *anyopaque) @import("config/appearance_ui_context.zig").FontStatus {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        return .{ .family_id = if (self.font_result) |font| font.family_id else 0, .actual_family = if (self.font_result) |font| font.actual_family else "", .fallback = if (self.font_result) |font| font.fallback_reason != null else false, .problem = if (self.font_problem) |problem| @errorName(problem) else null };
    }
    fn validateFont(self: *SettingsHost) void {
        const registry = app_font_registry orelse {
            self.font_problem = error.FontUnavailable;
            return;
        };
        const setting = self.controller.model.value.ui;
        if (self.font_problem == null) if (self.font_result) |font| {
            if (std.mem.eql(u8, font.requested_family, setting.font_family) and font.requested_size == @as(f32, @floatFromInt(setting.font_size)) and std.mem.eql(u8, @tagName(font.requested_weight), setting.font_weight)) return;
        };
        const resolved = @import("config/appearance_font.zig").resolve(self.allocator, registry, .{ .family = setting.font_family, .size = @floatFromInt(setting.font_size), .weight = setting.font_weight }) catch |err| {
            self.font_problem = err;
            if (self.mounted_page) |page| page.refreshFooter();
            return;
        };
        if (self.font_result) |*previous| previous.deinit(self.allocator);
        self.font_result = resolved;
        self.font_problem = null;
        if (self.mounted_page) |page| page.refreshFooter();
    }
    fn appearanceCommand(raw: *anyopaque, command: AppearanceCommand) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        const worker = if (self.resource_worker) |*value| value else return;
        const dispatched = @import("config/appearance_ui_picker.zig").dispatch(self.cx, worker, &self.controller, &self.registry, self.runtime.value.ui.theme, command) catch |err| {
            self.controller.theme_library.problem = err;
            self.refresh(@errorName(err));
            self.pending_rebuild = true;
            return;
        };
        if (dispatched) {
            self.appearance_context.selected_image_path = worker.selectedPath();
            self.pending_rebuild = true;
        } else switch (command) {
            .validate_font => self.validateFont(),
            .draft_values_changed => {
                self.validateFont();
                self.loadCurrentBackground();
                if (self.controller.model.value.ui.materials.background.path.len == 0) {
                    worker.clearSelectedPath();
                    self.appearance_context.selected_image_path = "";
                }
                if (self.on_material_preview) |update| update(self, self.appearance_context.preview_active);
                // TextInput and IME remain mounted during ordinary edits.
                if (self.mounted_page) |page| page.refreshFooter();
            },
            .preview_material => |active| self.setMaterialPreview(active),
            .restore_materials => {
                if (self.busy()) return;
                self.controller.restoreMaterials(self.runtime) catch |err| {
                    self.refresh(@errorName(err));
                    return;
                };
                if (self.draft_texture) |*texture| texture.deinit();
                self.draft_texture = null;
                worker.clearSelectedPath();
                self.appearance_context.selected_image_path = "";
                self.loadCurrentBackground();
                self.pending_rebuild = true;
                if (self.on_material_preview) |update| update(self, self.appearance_context.preview_active);
            },
            else => {},
        }
        self.cx.requestRedraw();
    }
    fn loadCurrentBackground(self: *SettingsHost) void {
        const worker = if (self.resource_worker) |*value| value else return;
        const selected = self.controller.model.value.ui.materials.background;
        if (!selected.enabled or selected.path.len == 0 or worker.busy()) return;
        if (self.controller.background.canSave(selected)) return;
        var request = self.controller.requestBackground(selected.path) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        self.loading_saved_background = std.mem.eql(u8, selected.path, self.runtime.value.ui.materials.background.path);
        worker.startBackground(&request) catch |err| {
            self.loading_saved_background = false;
            _ = self.controller.failBackground(request.request, err);
            request.deinit();
            self.refresh(@errorName(err));
        };
    }
    /// Called by the application's safe hook even while the settings panel is
    /// hidden. It never destroys a node from inside its own input callback.
    fn poll(self: *SettingsHost) bool {
        self.pollRecordCleanup();
        if (self.data_cleanup_view) |view| if (view.open.get() and view.mode == .confirm) view.setBlocked(self.dataCleanupBlocked()) catch {};
        const worker = if (self.resource_worker) |*value| value else return false;
        if (!worker.busy()) return false;
        const result = worker.poll(&self.controller, &self.registry, self.runtime.value.ui.theme);
        self.appearance_context.selected_image_path = worker.selectedPath();
        if (result.pending) {
            self.cx.requestRedraw();
            return false;
        }
        if (result.problem) |problem| {
            self.controller.theme_library.problem = if (result.kind == .background) self.controller.theme_library.problem else problem;
            self.refresh(@errorName(problem));
        }
        if (result.kind == .load_library) {
            self.validateFont();
            if (self.registry.get(self.runtime.value.ui.theme)) |current| {
                app_theme.selectTokens(current.ui_tokens);
                self.cx.setTheme(app_theme.widgetTheme(app_theme.currentName()));
            }
            self.loadCurrentBackground();
            if (self.on_appearance_publish) |publish| publish(self);
        }
        if (result.kind == .background and self.loading_saved_background) {
            self.loading_saved_background = false;
            if (result.problem == null and result.changed) if (self.controller.background.last_good) |good| {
                if (std.mem.eql(u8, good.path, self.runtime.value.ui.materials.background.path)) {
                    const saved_asset = self.copyAsset(good) catch |err| {
                        self.refresh(@errorName(err));
                        self.pending_rebuild = true;
                        return true;
                    };
                    if (self.appearance_state.asset) |*old| old.deinit(self.allocator);
                    self.appearance_state.asset = saved_asset;
                    if (self.committed_texture) |*old| old.deinit();
                    self.committed_texture = self.draft_texture;
                    self.draft_texture = null;
                    if (self.on_appearance_publish) |publish| publish(self);
                }
            };
        }
        if (result.kind == .installation) self.installation = worker.takeInstallation();
        if (result.kind == .abort_installation) {
            if (worker.takeInstallation()) |receipt| {
                self.installation = receipt;
                self.pending_discard_close = false;
            } else if (self.pending_discard_close) {
                self.pending_discard_close = false;
                self.discardAndClose();
            }
        }
        if (self.pending_save) |close_after_save| {
            self.pending_save = null;
            if (result.problem == null) self.saveWithClose(close_after_save);
        }
        if (result.changed or result.problem != null) {
            self.pending_rebuild = true;
            if (self.on_material_preview) |update| update(self, self.appearance_context.preview_active);
        }
        if (self.mounted_page) |page| page.refreshFooter();
        self.cx.requestRedraw();
        return result.changed;
    }
    fn prepareDraftTexture(raw: *anyopaque, prepared: *const @import("config/background_asset.zig").Prepared) !void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        const app = self.app_runtime orelse return error.RendererNotReady;
        if (self.pending_texture) |*old| old.deinit();
        self.pending_texture = null;
        self.pending_texture = try @import("ui/background_texture.zig").upload(app, prepared);
    }
    fn completeDraftTexture(raw: *anyopaque, accepted: bool) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        if (accepted) {
            if (self.draft_texture) |*old| old.deinit();
            self.draft_texture = self.pending_texture;
        } else if (self.pending_texture) |*failed| failed.deinit();
        self.pending_texture = null;
    }
    fn mountAppearanceImage(raw: *anyopaque, cx: *ui.Cx, _: *ui.Scope, width: f32, height: f32) !*ui.Node {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        const texture = self.draft_texture orelse self.committed_texture orelse return ui.iconTint(cx, ui.icons.image, app_theme.current().fg_3, .{ .width = .{ .px = width }, .height = .{ .px = height } });
        const frame = try ui.box(cx, .{ .width = .{ .px = width }, .height = .{ .px = height }, .overflow = .hidden, .overflow_hidden = true, .border = .{ .radius = 5 }, .flex_shrink = 0 }, .{});
        const scale = @max(width / @as(f32, @floatFromInt(texture.width)), height / @as(f32, @floatFromInt(texture.height)));
        const image_width = @as(f32, @floatFromInt(texture.width)) * scale;
        const image_height = @as(f32, @floatFromInt(texture.height)) * scale;
        const image = try ui.image(cx, texture.id, .{ .position = .absolute, .width = .{ .px = image_width }, .height = .{ .px = image_height } });
        image.setStyleInline(cx.allocator, .{ .inset = .{ .left = .{ .px = (width - image_width) / 2 }, .top = .{ .px = (height - image_height) / 2 } } });
        try frame.appendChild(cx.allocator, image);
        return frame;
    }
    const MaterialPreviewHook = struct {
        host: *SettingsHost,
        cx: *ui.Cx,
        frame: *ui.Node,
        view: *@import("ui/background_layers.zig").View,
        fn run(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const rect = self.frame.globalRect();
            if (rect.w <= 0 or rect.h <= 0) return .done;
            const texture = self.host.draft_texture orelse self.host.committed_texture;
            const image: ?@import("ui/background_layers.zig").Image = if (texture) |value| .{ .id = value.id, .width = value.width, .height = value.height, .repeating = value.repeating } else null;
            self.view.update(image, self.host.controller.model.value.ui.materials, rect.w, rect.h) catch {};
            return .done;
        }
        fn cleanup(self: *@This()) void {
            self.cx.removeAfterLayoutHook(self);
            self.cx.allocator.destroy(self);
        }
    };
    fn mountAppearanceMaterial(raw: *anyopaque, cx: *ui.Cx, scope: *ui.Scope, width: f32, height: f32) !*ui.Node {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        const frame = try ui.box(cx, .{ .width = if (width > 0) .{ .px = width } else .fill(), .height = .{ .px = height }, .min_width = 0, .overflow = .hidden, .overflow_hidden = true, .composited_group = true, .background = app_theme.baseColors().app, .border = .{ .radius = 8 }, .flex_shrink = 0 }, .{});
        frame.meta.ownership.meta.test_id = "settings.background.material.surface";
        const view = try @import("ui/background_layers.zig").View.mount(cx, scope);
        view.root.meta.ownership.meta.test_id = "settings.background.material.layer";
        try frame.appendChild(cx.allocator, view.root);
        const hook = try cx.allocator.create(MaterialPreviewHook);
        hook.* = .{ .host = self, .cx = cx, .frame = frame, .view = view };
        try scope.onCleanup(MaterialPreviewHook, hook, MaterialPreviewHook.cleanup);
        try cx.addAfterLayoutHook(hook, MaterialPreviewHook.run);
        return frame;
    }
    fn setMaterialPreview(self: *SettingsHost, active: bool) void {
        if (active and self.busy()) return;
        if (active) self.rememberScroll() else self.mounted_page = null;
        self.appearance_context.preview_active = active;
        self.panel.setDisplay(if (active) .none else .flex);
        self.pending_rebuild = true;
        if (self.preview_root) |root| root.setDisplay(if (active) .flex else .none);
        if (self.on_material_preview) |update| update(self, active);
        self.cx.requestRedraw();
    }

    fn refresh(self: *SettingsHost, prefix: []const u8) void {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print("{s}{s}", .{ prefix, if (self.controller.model.dirty) " · 未保存" else "" }) catch return;
        self.status.setTextContent(self.allocator, writer.buffered()) catch return;
        self.status.setDisplay(.none);
        if (self.mounted_page) |page| page.status_label.setTextContent(self.allocator, writer.buffered()) catch {};
        self.status.markRenderDirty();
        self.cx.requestRedraw();
    }

    fn toggle(self: *SettingsHost) void {
        if (self.busy()) return;
        if (self.open) if (self.providers) |providers| if (providers.hasModelEditor()) {
            _ = providers.consumeEscape();
            return;
        };
        if (self.open) {
            switch (self.controller.requestClose()) {
                .blocked_saving => return,
                .confirmation_required => {
                    self.showDecision(.close) catch |err| self.refresh(@errorName(err));
                    return;
                },
                .allow => self.closeNow(),
            }
        } else {
            self.controller.discardLatest(self.runtime) catch |err| {
                self.refresh(@errorName(err));
                return;
            };
            self.open = true;
            self.validateFont();
            self.loadCurrentBackground();
            self.panel.setDisplay(.flex);
            self.status.setDisplay(.none);
            self.pending_rebuild = true;
        }
        self.cx.requestRedraw();
    }

    fn closeNow(self: *SettingsHost) void {
        if (self.installation != null) {
            self.discardAndClose();
            return;
        }
        self.rememberScroll();
        if (self.appearance_initialized) {
            self.registry.discard(self.controller.draft_id);
            self.appearance_context.preview_active = false;
            if (self.preview_root) |root| root.setDisplay(.none);
            if (self.on_material_preview) |update| update(self, false);
        }
        self.open = false;
        self.panel.setDisplay(.none);
        if (self.record_cleanup_view) |view| view.hide();
        self.record_cleanup_origin = null;
        if (self.decision_open) |open| open.set(false);
        if (self.workspace) |workspace| {
            if (workspace.active_tab) |active| {
                if (active < workspace.tabs.items.len) {
                    self.cx.setFocus((if (workspace.tabs.items[active].terminal) |*terminal| terminal.root else workspace.tabs.items[active].root));
                    self.cx.requestRedraw();
                    return;
                }
            }
        }
        if (self.focus_return) |trigger| self.cx.setFocus(trigger);
        self.cx.requestRedraw();
    }

    fn searchChanged(self: *SettingsHost, query: []const u8) void {
        self.controller.setSearch(query) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        self.pending_rebuild = true;
        self.cx.requestRedraw();
    }

    fn rememberScroll(self: *SettingsHost) void {
        if (self.mounted_page) |page| self.mountedScrollOffset().* = page.scroll_state.scroll_y;
    }

    // Save against the mounted view, not the already changed search/page state.
    // A short preview or empty search must not replace the list's reading position.
    fn mountedScrollOffset(self: *SettingsHost) *f32 {
        if (self.mounted_page_index == 0 and self.mounted_theme_library_open and !self.mounted_filtered) return &self.controller.theme_library.scroll;
        if (self.mounted_plugin_preview) |preview| return &self.plugin_preview_scroll_offsets[@intFromBool(self.mounted_filtered)][@backingInt(preview)];
        if (self.mounted_filtered) return &self.search_scroll_offsets[self.mounted_page_index];
        return &self.controller.scroll_offsets[self.mounted_page_index];
    }

    fn selectPage(self: *SettingsHost, index: usize) void {
        if (self.busy()) return;
        self.rememberScroll();
        self.controller.setSearch("") catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        if (self.search_input) |input| {
            if (input.value) |value| value.set("") else _ = input.state.setText("");
        }
        self.controller.model.selectPage(index);
        self.controller.model.selectKey(0);
        self.pending_rebuild = true;
        self.status.setDisplay(.none);
    }

    fn save(self: *SettingsHost) void {
        self.saveWithClose(false);
    }

    fn saveWithClose(self: *SettingsHost, close_after_save: bool) void {
        if (self.busy()) return;
        if (self.mounted_page) |page| if (page.isComposing()) return;
        if (self.providers) |providers| if (providers.isComposing() or providers.hasModelEditor()) return;
        if (!self.controller.model.dirty) {
            if (close_after_save) self.closeNow();
            return;
        }
        self.validateFont();
        if (self.font_problem) |problem| {
            self.refresh(@errorName(problem));
            if (self.mounted_page) |page| page.refreshFooter();
            return;
        }
        var staged_count: usize = 0;
        for (self.registry.records.items) |record| if (record.staged_for == self.controller.draft_id) {
            staged_count += 1;
        };
        if (self.installation) |*receipt| {
            const valid = receipt.ready and receipt.draft_id == self.controller.draft_id and receipt.entries.len == staged_count;
            if (!valid) {
                self.resource_worker.?.abortInstallation(receipt) catch |err| {
                    self.refresh(@errorName(err));
                    return;
                };
                self.installation = null;
                self.pending_save = close_after_save;
                self.cx.requestRedraw();
                return;
            }
        } else if (staged_count != 0) {
            self.resource_worker.?.prepareInstallation(&self.registry, self.controller.draft_id) catch |err| {
                self.refresh(@errorName(err));
                return;
            };
            self.pending_save = close_after_save;
            if (self.mounted_page) |page| page.refreshFooter();
            self.cx.requestRedraw();
            return;
        }
        var request = self.controller.beginSave(self.runtime, close_after_save) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        defer request.deinit();
        // A new CPU image gets an owned copy before commit. The draft retains
        // its last good pixels on any allocation, preflight or Config failure.
        var asset: ?@import("config/background_asset.zig").Prepared = null;
        defer if (asset) |*image| image.deinit(self.allocator);
        const background = request.prepared.owned.?.value.ui.materials.background;
        if (background.enabled and (self.appearance_state.asset == null or !std.mem.eql(u8, self.appearance_state.asset.?.path, background.path) or if (self.controller.background.last_good) |draft_asset| draft_asset.asset_revision != self.appearance_state.asset.?.asset_revision else false)) {
            const good = self.controller.background.last_good orelse {
                _ = self.controller.failSave(&request, error.BackgroundNotPrepared);
                self.refresh("BackgroundNotPrepared");
                return;
            };
            asset = self.copyAsset(good) catch |err| {
                _ = self.controller.failSave(&request, err);
                self.refresh(@errorName(err));
                return;
            };
        }
        var prepared = AppearanceApply.prepare(self.allocator, &self.registry, &request.prepared, &self.appearance_state, AppearanceApply.Typography.fromResolved(self.font_result.?), if (asset) |*image| image else null, .{ .context = self, .check = prepareSaveTexture }) catch |err| {
            if (self.pending_texture) |*texture| texture.deinit();
            self.pending_texture = null;
            _ = self.controller.failSave(&request, err);
            self.refresh(@errorName(err));
            self.pending_rebuild = true;
            return;
        };
        asset = null; // AppearanceApply owns the copy from here.
        defer prepared.deinit();
        defer {
            if (self.pending_texture) |*texture| texture.deinit();
            self.pending_texture = null;
        }
        const completed = self.appearance_state.completeSettings(self.io, std.Io.Dir.cwd(), &self.registry, &self.controller, self.runtime, &request, &prepared, if (self.installation) |*receipt| receipt else null) catch |err| {
            if (self.pending_texture) |*texture| texture.deinit();
            self.pending_texture = null;
            self.refresh(@errorName(err));
            self.pending_rebuild = true;
            return;
        };
        if (!completed) return;
        if (self.installation) |*receipt| receipt.deinit();
        self.installation = null;
        if (self.pending_texture) |texture| {
            if (self.committed_texture) |*old| old.deinit();
            self.committed_texture = texture;
            self.pending_texture = null;
        } else if (self.draft_texture) |texture| {
            if (self.committed_texture) |*old| old.deinit();
            self.committed_texture = texture;
            self.draft_texture = null;
        }
        if (self.appearance_state.theme) |theme| {
            app_theme.selectTokens(theme.ui_tokens);
            self.cx.setTheme(app_theme.widgetTheme(app_theme.currentName()));
        }
        if (self.on_appearance_publish) |publish| publish(self);
        self.applyRuntimeSettings();
        self.pending_rebuild = true;
        self.status.setDisplay(.none);
        if (self.controller.close_ready) self.closeNow();
        self.cx.requestRedraw();
    }

    fn copyAsset(self: *SettingsHost, image: @import("config/background_asset.zig").Prepared) !@import("config/background_asset.zig").Prepared {
        const path = try self.allocator.dupe(u8, image.path);
        errdefer self.allocator.free(path);
        return .{ .draft_id = image.draft_id, .asset_revision = image.asset_revision, .path = path, .image = .{ .width = image.image.width, .height = image.image.height, .pixels = try self.allocator.dupe(u8, image.image.pixels) } };
    }
    /// The status palette commits only this field against the latest Runtime;
    /// an unrelated settings draft and its raw validation errors stay owned.
    fn immediateTheme(self: *SettingsHost, id: []const u8) !void {
        if (!self.appearance_initialized) return error.AppearanceUnavailable;
        if (self.busy()) return error.AppearanceBusy;
        const record = self.registry.get(id) orelse return error.UnknownTheme;
        if (record.staged_for != null) return error.ThemeNotPrepared;
        const registry = app_font_registry orelse return error.FontUnavailable;
        const setting = self.runtime.value.ui;
        var resolved = try @import("config/appearance_font.zig").resolve(self.allocator, registry, .{ .family = setting.font_family, .size = @floatFromInt(setting.font_size), .weight = setting.font_weight });
        defer resolved.deinit(self.allocator);
        var candidate = self.runtime.value;
        candidate.ui.theme = record.id;
        var config = try self.runtime.prepare(candidate);
        defer config.deinit();
        var resource = try AppearanceApply.prepare(self.allocator, &self.registry, &config, &self.appearance_state, AppearanceApply.Typography.fromResolved(resolved), null, .{ .context = self, .check = prepareSaveTexture });
        defer resource.deinit();
        defer {
            if (self.pending_texture) |*texture| texture.deinit();
            self.pending_texture = null;
        }
        try self.appearance_state.commit(self.io, std.Io.Dir.cwd(), &self.registry, self.runtime, &config, &resource, null);
        if (self.pending_texture) |texture| {
            if (self.committed_texture) |*previous| previous.deinit();
            self.committed_texture = texture;
            self.pending_texture = null;
        }
        app_theme.selectTokens(self.appearance_state.theme.?.ui_tokens);
        self.cx.setTheme(app_theme.widgetTheme(app_theme.currentName()));
        if (!self.controller.model.dirty) try self.controller.discardLatest(self.runtime);
        self.applyRuntimeSettings();
        if (self.on_appearance_publish) |publish| publish(self);
        self.pending_rebuild = true;
        self.cx.requestRedraw();
    }
    fn prepareSaveTexture(raw: *anyopaque, image: *const @import("config/background_asset.zig").Prepared) !void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        if (self.controller.background.last_good) |draft| {
            if (self.draft_texture != null and draft.asset_revision == image.asset_revision and std.mem.eql(u8, draft.path, image.path)) return;
        }
        if (self.appearance_state.asset) |saved| {
            if (self.committed_texture != null and std.mem.eql(u8, saved.path, image.path)) return;
        }
        try prepareDraftTexture(raw, image);
    }

    fn applyRuntimeSettings(self: *SettingsHost) void {
        if (!@import("platform/app_icon.zig").apply(self.runtime.value.ui.icon_background)) self.refresh("无法更新 Dock 图标，请重启应用后重试");
        if (process_notifications) |notifications| notifications.updatePolicy(self.runtime.value.notify) catch |err| self.refresh(@errorName(err));
        if (self.workspace) |workspace| {
            const setting = self.runtime.value.ui;
            const font = self.appearance_state.layout.?.font;
            for (workspace.tabs.items) |tab| {
                if (tab.terminal == null) continue;
                tab.terminal.?.setTypographyFamily(setting.font_size, setting.line_height, font.weight, font.actual_family, font.family_id) catch {};
                tab.terminal.?.setCursorStyle(if (std.mem.eql(u8, setting.cursor_style, "bar")) .bar else if (std.mem.eql(u8, setting.cursor_style, "underline")) .underline else .block);
                tab.terminal.?.setInputLineHighlight(setting.input_line_highlight) catch {};
                tab.terminal.?.setTimestampGutter(setting.timestamp_gutter);
                // Keep the live terminal behavior in sync with the saved
                // completion toggle. New sessions receive the same value from
                // Workspace.mount; existing tabs must update immediately after
                // Settings → Save without rebuilding their terminal trees.
                tab.terminal.?.completion_enabled = self.runtime.value.completion.enabled;
                tab.terminal.?.refreshCompletionState();
            }
        }
    }

    fn discard(self: *SettingsHost) void {
        self.showDecision(.reset) catch |err| self.refresh(@errorName(err));
    }

    fn showDecision(self: *SettingsHost, kind: DecisionKind) !void {
        if (self.decision_open == null) {
            const open = try self.scope.createSignal(bool, false);
            const title = try self.scope.createText("", .{});
            const message = try self.scope.createText("", .{});
            const modal = try ui.widgets.Modal(.{ .open = open, .width = @as(f32, 480), .max_height = @as(f32, 208), .background = app_theme.current().overlay, .close_on_overlay = false }).mount(self.scope, self.cx);
            if (!modal.portaled) try self.panel.appendChild(self.allocator, modal.overlay);
            modal.dialog.style.width = .{ .px = 480 };
            modal.dialog.style.height = .{ .px = 208 };
            modal.dialog.style.padding = ui.Padding.ZERO;
            modal.dialog.meta.ownership.meta.test_id = "settings.confirmation";
            if (self.record_cleanup_material) |material| try material.isolate(self.scope, modal.dialog);
            modal.body.style.width = .fill();
            modal.body.style.height = .fill();
            modal.body.style.direction = .column;
            modal.body.style.padding = .{ .left = 14, .right = 14, .top = 17, .bottom = 16 };
            modal.body.style.gap = 9;
            const header = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 30 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6 }, .{});
            self.decision_dialog = modal.dialog;
            self.decision_icon = try ui.iconTint(self.cx, ui.icons.circle_help, app_theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } });
            self.decision_title_node = try ui.textFmt(self.cx, self.scope, "{s}", .{title}, .{ .font_size = 13, .font_weight = 700, .color = app_theme.current().fg_1 });
            try header.appendChild(self.allocator, self.decision_icon.?);
            try header.appendChild(self.allocator, self.decision_title_node.?);
            try header.appendChild(self.allocator, try ui.spacer(self.cx));
            const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .a11y_label = "返回设置", .on_click = self.cx.on(SettingsHost, self, cancelDecision) }).mount(self.scope, self.cx);
            shell_styles.toolbarButton(self.allocator, close);
            close.setStyleInline(self.allocator, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 } });
            try header.appendChild(self.allocator, close);
            try modal.body.appendChild(self.allocator, header);
            self.decision_message_node = try ui.textFmt(self.cx, self.scope, "{s}", .{message}, .{ .font_size = 11.5, .color = app_theme.current().fg_2, .wrap = .word });
            self.decision_notice = try ui.text(self.cx, "保存失败保留草稿；恢复默认值也需保存后生效。", .{ .font_size = 10.5, .color = app_theme.current().fg_2, .wrap = .word });
            try modal.body.appendChild(self.allocator, self.decision_message_node.?);
            try modal.body.appendChild(self.allocator, self.decision_notice.?);
            try modal.body.appendChild(self.allocator, try ui.spacer(self.cx));
            const actions = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 34 }, .flex_shrink = 0, .direction = .row, .gap = 6 }, .{});
            const cancel_label = try self.scope.createText("继续编辑", .{});
            const cancel = try ui.widgets.Button(.{ .label = cancel_label, .variant = .secondary, .on_click = self.cx.on(SettingsHost, self, cancelDecision) }).mount(self.scope, self.cx);
            cancel.setStyleInline(self.allocator, .{ .width = .{ .px = 112 }, .height = .{ .px = 34 } });
            cancel.meta.ownership.meta.test_id = "settings.confirmation.cancel";
            try actions.appendChild(self.allocator, cancel);
            try actions.appendChild(self.allocator, try ui.spacer(self.cx));
            const discard_button = try ui.widgets.Button(.{ .label = "放弃", .variant = .secondary, .on_click = self.cx.on(SettingsHost, self, discardAndClose) }).mount(self.scope, self.cx);
            discard_button.setStyleInline(self.allocator, .{ .width = .{ .px = 80 }, .height = .{ .px = 34 } });
            discard_button.meta.ownership.meta.test_id = "settings.confirmation.discard";
            try actions.appendChild(self.allocator, discard_button);
            const save_button = try ui.widgets.Button(.{ .label = "保存关闭", .variant = .primary, .on_click = self.cx.on(SettingsHost, self, saveAndClose) }).mount(self.scope, self.cx);
            save_button.setStyleInline(self.allocator, .{ .width = .{ .px = 104 }, .height = .{ .px = 34 } });
            save_button.meta.ownership.meta.test_id = "settings.confirmation.save";
            try actions.appendChild(self.allocator, save_button);
            const reset = try ui.widgets.Button(.{ .label = "恢复", .variant = .primary, .on_click = self.cx.on(SettingsHost, self, confirmReset) }).mount(self.scope, self.cx);
            reset.setStyleInline(self.allocator, .{ .width = .{ .px = 96 }, .height = .{ .px = 34 } });
            reset.meta.ownership.meta.test_id = "settings.confirmation.reset";
            try actions.appendChild(self.allocator, reset);
            try modal.body.appendChild(self.allocator, actions);
            self.decision_open = open;
            self.decision_title = title;
            self.decision_message = message;
            self.decision_cancel = cancel;
            self.decision_cancel_label = cancel_label;
            self.decision_save = save_button;
            self.decision_discard = discard_button;
            self.decision_reset = reset;
        }
        // This retained modal outlives settings content rebuilds. Refresh its
        // explicit paint slots before reopening, without replacing the draft,
        // signal bindings or the controls that restore focus.
        const colors = app_theme.current();
        self.decision_dialog.?.setBackground(colors.overlay);
        _ = self.decision_icon.?.setTint(colors.accent);
        self.decision_title_node.?.setTextColor(colors.fg_1);
        self.decision_message_node.?.setTextColor(colors.fg_2);
        self.decision_notice.?.setTextColor(colors.fg_2);
        self.decision_kind = kind;
        self.decision_cancel_label.?.set(if (kind == .close) "继续编辑" else "取消");
        self.decision_cancel.?.setStyle(self.allocator, .width, .{ .px = if (kind == .close) @as(f32, 112) else 96 });
        self.decision_title.?.set(if (kind == .close) "未保存的设置" else "恢复默认设置？");
        self.decision_message.?.set(if (kind == .close) "主题预览与其他分类的编辑尚未保存。" else "载入默认值草稿？默认主题 Sauber；保存前仍可放弃。");
        self.decision_save.?.setDisplay(if (kind == .close) .flex else .none);
        self.decision_discard.?.setDisplay(if (kind == .close) .flex else .none);
        self.decision_reset.?.setDisplay(if (kind == .reset) .flex else .none);
        self.decision_open.?.set(true);
        self.cx.requestRedraw();
    }

    fn cancelDecision(self: *SettingsHost) void {
        if (self.native_close_waiter) |pending| pending.* = false;
        if (self.decision_open) |open| open.set(false);
    }
    fn discardAndClose(self: *SettingsHost) void {
        if (self.busy()) return;
        if (self.installation) |*receipt| {
            self.resource_worker.?.abortInstallation(receipt) catch |err| {
                self.refresh(@errorName(err));
                return;
            };
            self.installation = null;
            self.pending_discard_close = true;
            self.cx.requestRedraw();
            return;
        }
        self.registry.discard(self.controller.draft_id);
        self.controller.discardLatest(self.runtime) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        self.validateFont();
        if (self.resource_worker) |*worker| worker.clearSelectedPath();
        self.appearance_context.selected_image_path = "";
        if (self.draft_texture) |*texture| texture.deinit();
        self.draft_texture = null;
        self.closeNow();
    }
    fn revertDraft(self: *SettingsHost) void {
        if (self.busy() or self.installation != null) return;
        self.controller.discardLatest(self.runtime) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        self.registry.discard(self.controller.draft_id);
        self.validateFont();
        if (self.resource_worker) |*worker| worker.clearSelectedPath();
        self.appearance_context.selected_image_path = "";
        if (self.draft_texture) |*texture| texture.deinit();
        self.draft_texture = null;
        self.pending_rebuild = true;
        self.cx.requestRedraw();
    }

    fn saveAndClose(self: *SettingsHost) void {
        self.saveWithClose(true);
    }
    fn confirmReset(self: *SettingsHost) void {
        if (self.busy()) return;
        self.controller.resetDefaults();
        self.cancelDecision();
        self.pending_rebuild = true;
        self.cx.requestRedraw();
    }

    /// Edits one key through the settings-value boundary (validation +
    /// dirty marking). Editing does NOT rebuild the row — the control the
    /// user is typing in must keep focus; the status line reports errors.
    fn editKey(self: *SettingsHost, key: settings_pages_mod.ConfigKey, value: settings_values_mod.Value) void {
        self.controller.editKey(key.section, key.key, value) catch |err| {
            var buffer: [128]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            writer.print("{s}: {s}.{s}", .{ @errorName(err), key.section, key.key }) catch return;
            self.status.setTextContent(self.allocator, writer.buffered()) catch return;
            self.status.markRenderDirty();
            return;
        };
        self.refresh("设置");
    }

    /// Full rebuild: navigation highlight + content rows.
    fn rebuildAll(self: *SettingsHost) void {
        if (self.appearance_context.preview_active) {
            self.rebuildPreview() catch |err| self.refresh(@errorName(err));
            return;
        }
        self.rebuildNav() catch |err| {
            applog.warn(.ui, "settings nav rebuild failed: {s}", .{@errorName(err)});
        };
        self.rebuildContent() catch |err| {
            applog.warn(.ui, "settings content rebuild failed: {s}", .{@errorName(err)});
        };
        self.rebuildPreview() catch |err| self.refresh(@errorName(err));
    }

    fn rebuildPreview(self: *SettingsHost) !void {
        if (self.preview_scope) |old| old.dispose();
        self.preview_scope = null;
        self.preview_actions = null;
        if (self.preview_root) |old| {
            if (old.parent) |parent| self.cx.detachChild(parent, old);
            self.cx.destroyDetached(old);
        }
        self.preview_root = null;
        if (!self.appearance_context.preview_active) return;
        const scope = try self.scope.childScope();
        self.preview_scope = scope;
        const mounted = try settings_content_view.mountMaterialPreviewActions(self.cx, scope, &self.controller, .{ .context = self, .changed = contentChanged, .request_edit = requestContentEdit, .action = contentAction, .appearance = &self.appearance_context });
        const area = if (self.preview_viewport) |viewport| viewport.globalRect() else ui.ComputedRect{ .x = 0, .y = 0, .w = self.cx.viewport.width, .h = self.cx.viewport.height };
        const width = @min(@as(f32, 660), @max(@as(f32, 1), area.w - 32));
        mounted.root.setStyleInline(self.allocator, .{ .position = .absolute, .width = .{ .px = width }, .height = .{ .px = 48 }, .inset = .{ .left = .{ .px = area.x + (area.w - width) / 2 }, .bottom = .{ .px = 58 } }, .z_index = 11000 });
        self.preview_root = mounted.root;
        self.preview_actions = mounted;
        try self.cx.root.?.appendChild(self.allocator, mounted.root);
    }

    /// Detaches all children of `node` (same pattern as QuickConnectHost and
    /// MenuHost rebuilds — nodes stay owned by the scope for cleanup).
    fn clearChildren(node: *ui.Node) void {
        var count = node.children.items.len;
        while (count > 0) : (count -= 1) {
            node.removeChild(node.children.items[count - 1]);
        }
    }

    fn rebuildNav(self: *SettingsHost) !void {
        if (self.nav_scope) |old| old.dispose();
        self.nav_scope = null;
        while (self.nav_list.children.items.len > 0) {
            const child = self.nav_list.children.items[self.nav_list.children.items.len - 1];
            self.cx.detachChild(self.nav_list, child);
            self.cx.destroyDetached(child);
        }
        const nav_scope = try self.scope.childScope();
        self.nav_scope = nav_scope;
        const c = app_theme.current();
        const current = self.controller.model.page_index;
        const icons = [_]ui.SvgAsset{ ui.icons.palette, ui.icons.keyboard, ui.icons.network, ui.icons.arrow_down_up, ui.icons.sparkles, ui.icons.plug, ui.icons.bell, ui.icons.database };
        for (settings_pages_mod.pages, 0..) |page, index| {
            const selected = index == current;
            const click = try self.cx.allocator.create(SettingsNavClick);
            click.* = .{ .host = self, .page_index = index };
            try nav_scope.onCleanup(SettingsNavClick, click, SettingsNavClick.cleanup);
            const btn = try ui.widgets.Button(.{ .a11y_label = page.name, .variant = .ghost, .disabled = self.controller.state() == .saving, .on_click = self.cx.on(SettingsNavClick, click, SettingsNavClick.activate), .base_style = ui.BoxStyle{ .width = .fill(), .height = .{ .px = 36 }, .flex_shrink = 0, .direction = .row, .justify = .start, .gap = 8, .padding = .{ .left = 6, .right = 6 }, .background = if (selected) c.selection else ui.Color.TRANSPARENT, .border = .{ .width = 0, .color = c.border, .radius = 7 } } }).mount(nav_scope, self.cx);
            btn.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 36 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .justify = .start, .gap = 8, .padding = .{ .left = 6, .right = 6 }, .background = if (selected) c.selection else ui.Color.TRANSPARENT, .border = .{ .width = 0, .color = c.border, .radius = 7 } });
            try btn.appendChild(self.cx.allocator, try ui.iconTint(self.cx, icons[index], if (selected) c.accent else c.fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 }));
            try btn.appendChild(self.cx.allocator, try ui.text(self.cx, page.name, .{ .font_size = 12, .font_weight = if (selected) @as(u16, 600) else 400, .color = if (selected) c.fg_1 else c.fg_2 }));
            const test_ids = [_][]const u8{ "settings.nav.appearance", "settings.nav.keys", "settings.nav.ssh", "settings.nav.transfer", "settings.nav.ai", "settings.nav.plugins", "settings.nav.notifications", "settings.nav.data" };
            btn.meta.ownership.meta.test_id = test_ids[index];
            try self.nav_list.appendChild(self.cx.allocator, btn);
        }
    }

    fn rebuildContent(self: *SettingsHost) !void {
        var focus: ?settings_content_view.FocusSnapshot = null;
        if (self.mounted_page) |page| {
            if (self.mounted_page_index == self.controller.model.page_index) focus = try page.captureFocus(self.allocator);
        }
        defer if (focus) |*snapshot| snapshot.deinit(self.allocator);
        self.rememberScroll();
        self.mounted_page = null;
        self.dismissPicker();
        self.providers = null;
        if (self.content_scope) |old| old.dispose();
        self.content_scope = null;
        // Scope callbacks are released while their nodes remain valid. Detach
        // and free the nodes immediately afterwards, including hidden pickers.
        for (self.picker_nodes.items) |node| {
            if (node.parent) |parent| self.cx.detachChild(parent, node);
            self.cx.destroyDetached(node);
        }
        self.picker_nodes.clearRetainingCapacity();
        while (self.content.children.items.len > 0) {
            const child = self.content.children.items[self.content.children.items.len - 1];
            self.cx.detachChild(self.content, child);
            self.cx.destroyDetached(child);
        }
        const page_scope = try self.scope.childScope();
        self.content_scope = page_scope;
        self.content.style.padding = ui.Padding.ZERO;
        if (self.card) |card| {
            card.setStyleInline(self.allocator, .{
                .height = .{ .px = settings_content_view.constrainedModalHeight(self.controller.model.page_index, self.cx.viewport.height) },
                .width = .{ .px = @max(1, @min(@import("ui/v3_geometry.zig").settings_width, self.cx.viewport.width - 32)) },
            });
        }
        const view = try settings_content_view.mountPage(self.cx, page_scope, &self.controller, .{
            .context = @ptrCast(self),
            .changed = contentChanged,
            .request_edit = requestContentEdit,
            .action = contentAction,
            .action_state = contentActionState,
            .mount_providers = mountProviders,
            .mount_provider_action = mountProviderAction,
            .read = readContentValue,
            .edit = editContentValue,
            .authorization_help = notificationAuthorizationHelp,
            .authorization_feedback = notificationAuthorizationFeedback,
            .keybindings = &self.controller.model.value.keys,
            .appearance = if (self.appearance_initialized) &self.appearance_context else null,
        });
        self.mounted_page = view;
        self.mounted_page_index = self.controller.model.page_index;
        self.mounted_filtered = self.controller.search_query.len != 0;
        self.mounted_theme_library_open = self.mounted_page_index == 0 and self.controller.theme_library.open;
        self.mounted_plugin_preview = if (self.mounted_page_index == 5) self.controller.plugin_page.preview_kind else null;
        self.restore_scroll = true;
        try self.content.appendChild(self.allocator, view.root);
        if (focus) |snapshot| _ = view.restoreFocus(snapshot);
        self.cx.requestRedraw();
    }

    fn restoreScroll(self: *SettingsHost) bool {
        if (self.appearance_context.preview_active) return false;
        if (!self.restore_scroll) return false;
        const page = self.mounted_page orelse return false;
        self.restore_scroll = false;
        // after_layout precedes ScrollArea's before_render size refresh.
        // Use its public laid-out nodes so setScrollY does not clamp to zero.
        page.scroll_state.viewport_height = @max(0, page.scroll_container.globalRect().h - page.scroll_container.style.padding.vertical());
        page.scroll_state.content_height = page.scroll_content.globalRect().h;
        ui.widgets.scroll_area.setScrollY(page.scroll_state, page.scroll_content, self.mountedScrollOffset().*);
        return true;
    }

    fn findSettingsText(node: *ui.Node, label: []const u8) ?*ui.Node {
        if (node.getText()) |text| if (std.mem.eql(u8, text.content, label)) return node;
        for (node.children.items) |child| if (findSettingsText(child, label)) |found| return found;
        return null;
    }

    fn readContentValue(raw: *anyopaque, key: settings_content_view.Key) ?settings_values_mod.Value {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, key.section, "data")) {
            if (std.mem.eql(u8, key.key, "config_path")) return .{ .text = self.runtime.path };
            if (std.mem.eql(u8, key.key, "hosts_path")) return .{ .text = (self.workspace orelse return null).hosts_path };
        }
        if (std.mem.eql(u8, key.section, "data") and std.mem.eql(u8, key.key, "config_dir")) {
            return .{ .text = std.fs.path.dirname(self.runtime.path) orelse self.runtime.path };
        }
        if (std.mem.eql(u8, key.section, "data")) if (process_windows) |process| {
            if (std.mem.eql(u8, key.key, "cache_dir")) return .{ .text = process.data_paths.cache_directory };
            if (std.mem.eql(u8, key.key, "logs_dir")) return .{ .text = process.data_paths.diagnostic_directory };
        };
        return null;
    }

    fn notificationAuthorizationHelp(_: *anyopaque) []const u8 {
        return if (process_notifications) |notifications| notifications.authorizationHelp() else "当前无法使用系统通知。";
    }

    fn notificationAuthorizationFeedback(_: *anyopaque) ?[]const u8 {
        return if (process_notifications) |notifications| notifications.authorization_feedback else null;
    }

    fn editContentValue(raw: *anyopaque, key: settings_content_view.Key, value: settings_values_mod.Value) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        const before = settings_values_mod.read(self.controller.model.value, key.section, key.key);
        self.controller.editKey(key.section, key.key, value) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        const event_switch = std.mem.eql(u8, key.section, "notify") and
            (std.mem.eql(u8, key.key, "transfer_done") or std.mem.eql(u8, key.key, "reconnect") or std.mem.eql(u8, key.key, "ai_ready"));
        if (event_switch and before != null and before.? == .boolean and !before.?.boolean and value == .boolean and value.boolean) {
            if (process_notifications) |notifications| if (self.notification_window) |window| {
                notifications.requestAuthorization(window) catch |err| {
                    self.refresh(if (err == error.AuthorizationRequestPending) "正在等待系统通知授权结果…" else @errorName(err));
                    return;
                };
                self.refresh("正在等待系统通知授权结果…");
            };
        }
    }

    fn contentChanged(raw: *anyopaque) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        self.pending_rebuild = true;
        self.cx.requestRedraw();
    }

    fn contentAction(raw: *anyopaque, action: settings_content_view.Action) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        switch (action) {
            .save => {
                self.save();
                return;
            },
            .revert => {
                self.revertDraft();
                return;
            },
            .reset_defaults => {
                self.discard();
                return;
            },
            .open_config_dir => {
                self.openConfigDirectory() catch |err| self.refresh(@errorName(err));
                return;
            },
            .export_logs => {
                self.exportLogs() catch |err| self.refresh(@errorName(err));
                return;
            },
            .clear_all => {
                self.showDataCleanup() catch |err| self.refresh(@errorName(err));
                return;
            },
            .clear_logs => {
                self.clearLogs() catch |err| self.refresh(if (err == error.LiveSessionActive) "请先结束活动会话" else @errorName(err));
                return;
            },
            .import_theme => {
                self.importTheme() catch |err| self.refresh(@errorName(err));
                return;
            },
            .credential_help => {
                self.refresh("凭据由 macOS 钥匙串保管；访问权限在实际读取或保存时由系统确认。");
                return;
            },
        }
        if (action == .save) self.applyRuntimeSettings();
        self.pending_rebuild = true;
        self.cx.requestRedraw();
    }

    fn dataDirectory(self: *SettingsHost) []const u8 {
        return std.fs.path.dirname(self.runtime.path) orelse ".";
    }

    fn importTheme(self: *SettingsHost) !void {
        if (self.busy()) return error.AppearanceBusy;
        const request = try self.controller.requestThemeImport();
        appearanceCommand(self, .{ .pick_theme = request });
    }

    /// Reveal the resolved user-data directory using the platform's normal
    /// file manager.  The settings value is the actual runtime path, so this
    /// action never opens a guessed or hard-coded HOME location.
    fn openConfigDirectory(self: *SettingsHost) !void {
        const directory = self.dataDirectory();
        const argv = [_][]const u8{ "open", directory };
        var result = try std.process.run(self.allocator, self.io, .{
            .argv = &argv,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (!result.term.success()) return error.OpenConfigDirectoryFailed;
        self.refresh("已打开配置目录");
    }

    /// Explicit diagnostics only. Capture the bounded original files before
    /// AppKit's nested picker; later output and rotation do not expand them.
    fn exportLogs(self: *SettingsHost) !void {
        const Export = @import("host/diagnostic_export.zig");
        const Sequence = struct {
            var next: u64 = 1;
        };
        const sdk = self.cx.system_sdk orelse return error.NativeDialogUnavailable;
        if (Sequence.next == 0) return error.DiagnosticOperationExhausted;
        const operation_id = Sequence.next;
        Sequence.next = if (Sequence.next == std.math.maxInt(u64)) 0 else Sequence.next + 1;
        var capture_failure: Export.Failure = .{};
        var plan = Export.Plan.capture(self.allocator, self.io, self.dataDirectory(), .{ .operation_id = operation_id, .failure = &capture_failure, .diagnostic_directory = if (process_windows) |process| process.data_paths.diagnostic_directory else null }) catch |err| {
            if (err == error.NoDiagnosticLogs) {
                self.refresh("暂无可导出的诊断日志");
                return;
            }
            var message: [240]u8 = undefined;
            self.refresh(std.fmt.bufPrint(&message, "读取诊断日志失败 · {s} · {s}", .{ capture_failure.sourceName(), @errorName(err) }) catch "读取诊断日志失败");
            return;
        };
        defer plan.deinit();
        var path_buffer: [4096]u8 = undefined;
        const target = (try sdk.runDialog(.{ .kind = .save_file, .title = "zerowork-diagnostics.tar.gz" }, &path_buffer)) orelse return;
        plan.write(target, .{}) catch |err| {
            var message: [240]u8 = undefined;
            const phase = if (plan.failure.stage == .publish) "发布诊断日志失败" else "写入诊断日志失败";
            self.refresh(std.fmt.bufPrint(&message, "{s} · {s} · {s}", .{ phase, plan.failure.sourceName(), @errorName(err) }) catch phase);
            return;
        };
        self.refresh("应用诊断日志已导出");
    }

    /// Rechecked at dispatch across every process-owned window and resource domain.
    fn dataCleanupBlocked(self: *SettingsHost) ?[]const u8 {
        if (self.hasActiveCleanupSessions()) return "请先结束所有窗口的活动会话与后台连接";
        const process = process_windows orelse return "应用生命周期尚未就绪";
        if (process.data_cleanup_owner) |owner| if (owner != self) return "另一窗口正在清除应用数据";
        if (process.pending.items.len != 0) return "请等待新窗口创建完成";
        if (process.domain.tasks) |tasks| {
            for (0..tasks.manager.count()) |index| if (tasks.manager.progressAt(index)) |job| {
                switch (job.state) {
                    .succeeded, .failed, .cancelled => if (job.job_cleanup != .released) return "请等待传输资源释放",
                    else => return "请先结束全部传输任务",
                }
            };
            for (tasks.auxiliary_connections.items) |connection| if (!connection.released) return "请先结束后台传输连接";
            for (tasks.retained_connections.items) |connection| if (!connection.released) return "请先结束后台传输连接";
            for (tasks.shared_connections.items) |connection| if (!connection.released) return "请先结束共享传输连接";
        }
        for (process.runtime.windows.items) |managed| {
            const root = managed.app.cx.root orelse continue;
            const nav: *AppNavHost = @ptrCast(@alignCast(root.behavior.events.capture_context orelse continue));
            if (nav.native_close_pending) return "请等待窗口关闭完成";
            if (nav.settings) |settings| {
                if (settings.busy() or settings.installation != null) return "请先完成设置资源操作";
                if (settings.record_cleanup) |*operation| if (operation.running) return "正在清理会话记录";
            }
            if (nav.wizard_host) |wizard| if (wizard.probe_controller.jobs.items.len != 0) return "请先结束连接测试";
            if (nav.ai) |ai| {
                if (ai.thread_state.load(.acquire) != 0 or ai.model_discovery.busy() or ai.attachment_readers.items.len != 0 or ai.image_readers.items.len != 0) return "请先结束 AI 请求与文件读取";
            }
        }
        return null;
    }

    fn showDataCleanup(self: *SettingsHost) !void {
        if (process_windows) |process| if (process.data_cleanup_owner != null) return error.CleanupAlreadyRunning;
        if (self.data_cleanup_view == null) self.data_cleanup_view = try DataCleanupView.View.mount(self.cx, self.scope, .{ .context = self, .action = dataCleanupAction });
        self.rememberScroll();
        const focused = if (self.mounted_page) |page| findSettingsTestId(page.root, "settings.data.clear_all") else self.cx.focus_manager.getFocused();
        self.data_cleanup_origin = .{ .draft_id = self.controller.draft_id, .page = self.mounted_page_index, .scroll = self.mountedScrollOffset().*, .focus = if (focused) |node| self.cx.node_registry.handleFor(node) else null };
        const view = self.data_cleanup_view.?;
        if (self.record_cleanup_material) |material| try material.isolate(self.scope, view.dialog);
        try view.showConfirmation();
        try view.setBlocked(self.dataCleanupBlocked());
    }

    fn dataCleanupAction(raw: *anyopaque, action: DataCleanupView.Action) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        const process = process_windows orelse return;
        switch (action) {
            .dismiss => {
                // After destructive work starts, returning to editable stale
                // snapshots would recreate data. Failure dismissal only exits.
                if (process.data_cleanup_owner != null) {
                    process.data_cleanup_exit = true;
                    return;
                }
                const origin = self.data_cleanup_origin orelse return;
                self.data_cleanup_origin = null;
                if (!self.open or origin.draft_id != self.controller.draft_id or origin.page != self.mounted_page_index) return;
                self.mountedScrollOffset().* = origin.scroll;
                if (self.mounted_page) |page| {
                    ui.widgets.scroll_area.setScrollY(page.scroll_state, page.scroll_content, origin.scroll);
                    if (self.cx.node_registry.resolve(origin.focus, null)) |node| self.cx.setFocus(node);
                }
                self.cx.requestRedraw();
            },
            .confirm, .retry => {
                const origin = self.data_cleanup_origin orelse return;
                if (!self.open or origin.draft_id != self.controller.draft_id) return;
                if (self.dataCleanupBlocked()) |reason| {
                    if (self.data_cleanup_view) |view| view.setBlocked(reason) catch {};
                    return;
                }
                process.data_cleanup_owner = self;
                process.data_cleanup_pending = true;
                if (self.data_cleanup_view) |view| view.updateWorking() catch {};
                self.cx.requestRedraw();
            },
        }
    }

    fn requireCleanupReceipt(receipt: anytype, awaiting: *bool) !void {
        switch (receipt) {
            .released => {},
            .awaiting => awaiting.* = true,
            .unknown => return error.CleanupResourcesUnknown,
        }
    }

    /// Idle controllers can still own an asynchronous native file worker.
    /// Drain its real shutdown receipt before removing any persistent data.
    fn quiesceDataWriters(_: *SettingsHost, process: *ProcessWindows) !void {
        const deadline = @import("platform/realtime.zig").monotonicNs() + 5 * std.time.ns_per_s;
        while (true) {
            var awaiting = false;
            for (process.runtime.windows.items) |managed| {
                const root = managed.app.cx.root orelse continue;
                const nav: *AppNavHost = @ptrCast(@alignCast(root.behavior.events.capture_context orelse continue));
                if (nav.ai) |ai| if (ai.remote_picker) |picker| if (!picker.shutdown()) {
                    awaiting = true;
                };
                if (nav.file_application) |files| try requireCleanupReceipt(files.shutdownStep(), &awaiting);
                if (nav.application_host) |host| _ = try host.safeTick();
            }
            try requireCleanupReceipt(process.domain.local_adapter.shutdownStep(), &awaiting);
            if (process.domain.tasks) |tasks| try requireCleanupReceipt(tasks.shutdownStep(), &awaiting);
            if (process.domain.backgrounds) |backgrounds| try requireCleanupReceipt(backgrounds.shutdownStep(), &awaiting);
            if (!awaiting) return;
            if (@import("platform/realtime.zig").monotonicNs() >= deadline) return error.CleanupResourcesNotReleased;
            var unused: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&unused, 0, 2);
        }
    }

    /// Runs between native ticks after the confirmation frame, with all writers idle.
    fn performDataCleanup(self: *SettingsHost) void {
        const process = process_windows orelse return;
        if (self.dataCleanupBlocked()) |reason| {
            process.data_cleanup_owner = null;
            if (self.data_cleanup_view) |view| {
                view.showConfirmation() catch {};
                view.setBlocked(reason) catch {};
            }
            return;
        }
        self.quiesceDataWriters(process) catch |err| {
            self.dataCleanupFailure("后台资源", err);
            return;
        };
        @import("config/data_lifecycle.zig").beginReset(self.io, process.data_paths) catch |err| {
            self.dataCleanupFailure("清除标记", err);
            return;
        };
        applog.shutdown();
        @import("config/credential_store.zig").eraseScope() catch |err| {
            self.dataCleanupFailure("钥匙串", err);
            return;
        };
        const report = @import("config/data_lifecycle.zig").eraseOwned(self.io, process.data_paths) catch |err| {
            self.dataCleanupFailure("应用目录", err);
            return;
        };
        for (report.items[0..report.count]) |item| if (item.failure) |err| {
            self.dataCleanupFailure(switch (item.area) {
                .data => "应用数据",
                .cache => "缓存",
                .diagnostic => "诊断日志",
                .legacy => "旧数据",
            }, err);
            return;
        };
        process.data_cleanup_exit = true;
    }

    fn dataCleanupFailure(self: *SettingsHost, area: []const u8, err: anyerror) void {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "{s}清除失败：{s}。部分内容可能已删除；可重试或退出，应用不会继续保存配置。", .{ area, @errorName(err) }) catch "清除未完成，请重试或退出应用。";
        if (self.data_cleanup_view) |view| {
            view.showFailure(message, true) catch {};
            view.cancel_label.setTextContent(self.allocator, "退出应用") catch {};
        }
        self.cx.requestRedraw();
    }

    fn clearLogs(self: *SettingsHost) !void {
        try RecordCleanup.requireIdle(self.hasActiveCleanupSessions());
        if (self.record_cleanup) |*operation| if (operation.running) return error.CleanupAlreadyRunning;
        if (self.record_cleanup_view == null) self.record_cleanup_view = try RecordCleanupView.View.mount(self.cx, self.scope, .{ .context = self, .action = recordCleanupAction });
        self.rememberScroll();
        const focused = if (self.mounted_page) |page| findSettingsTestId(page.root, "settings.data.clear_logs") else self.cx.focus_manager.getFocused();
        self.record_cleanup_origin = .{ .draft_id = self.controller.draft_id, .page = self.mounted_page_index, .scroll = self.mountedScrollOffset().*, .focus = if (focused) |node| self.cx.node_registry.handleFor(node) else null };
        const view = self.record_cleanup_view.?;
        if (self.record_cleanup_material) |material| try material.isolate(self.scope, view.dialog);
        if (self.record_cleanup) |*operation| {
            if (operation.progress().failed != 0) {
                try self.updateRecordCleanup();
                view.showResult();
                return;
            }
        }
        // No enumeration or file mutation occurs before explicit confirmation.
        try view.showConfirmation();
    }

    fn hasActiveCleanupSessions(self: *SettingsHost) bool {
        if (self.application_host) |host| {
            for (host.sessions.sessions.items) |entry| switch (entry.state) {
                .closed => {},
                .ended, .failed => if (entry.create_cleanup != .released) return true,
                .creating, .ready, .attached, .closing, .cleanup_unknown => return true,
            };
        } else if (self.workspace) |workspace| {
            for (workspace.tabs.items) |tab| if (!tab.archived) return true;
        }
        return false;
    }

    fn recordCleanupAction(raw: *anyopaque, action: RecordCleanupView.Action) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        switch (action) {
            .dismiss => self.restoreCleanupOrigin(),
            .confirm, .retry => self.startRecordCleanup(action == .retry) catch |err| {
                if (self.record_cleanup_view) |view| view.showProblem(err);
                self.refresh(if (err == error.LiveSessionActive) "请先结束活动会话" else @errorName(err));
            },
        }
    }

    fn startRecordCleanup(self: *SettingsHost, retry: bool) !void {
        const origin = self.record_cleanup_origin orelse return error.CleanupConfirmationExpired;
        if (origin.draft_id != self.controller.draft_id or !self.open) return error.CleanupConfirmationExpired;
        try RecordCleanup.requireIdle(self.hasActiveCleanupSessions());
        if (self.record_cleanup) |*operation| {
            if (operation.running) return error.CleanupAlreadyRunning;
            if (retry and operation.progress().failed != 0) {
                try operation.retryFailed(false);
                try self.updateRecordCleanup();
                return;
            }
        }
        self.releaseRecordCleanup();
        const directory = try std.Io.Dir.cwd().openDir(self.io, self.dataDirectory(), .{ .follow_symlinks = false });
        errdefer directory.close(self.io);
        var operation = try RecordCleanup.Controller.freeze(self.allocator, self.io, directory, self.hasActiveCleanupSessions());
        errdefer operation.deinit();
        try operation.begin(self.hasActiveCleanupSessions());
        self.record_cleanup_dir = directory;
        self.record_cleanup = operation;
        self.updateRecordCleanup() catch |err| self.refresh(@errorName(err));
        self.cx.requestRedraw();
    }

    fn pollRecordCleanup(self: *SettingsHost) void {
        const operation = if (self.record_cleanup) |*value| value else return;
        if (!operation.running) return;
        _ = operation.step(self.hasActiveCleanupSessions()) catch |err| {
            if (self.record_cleanup_view) |view| view.showProblem(err);
            operation.running = false;
            return;
        };
        self.updateRecordCleanup() catch |err| self.refresh(@errorName(err));
        self.cx.requestRedraw();
    }

    fn updateRecordCleanup(self: *SettingsHost) !void {
        const operation = if (self.record_cleanup) |*value| value else return;
        const progress = operation.progress();
        var index_missing = false;
        for (operation.records.items) |record| if (record.state == .failed and record.key != null and record.files.items.len != 0) {
            var all_removed = true;
            for (record.files.items) |file| all_removed = all_removed and file.removed;
            index_missing = index_missing or all_removed;
        };
        if (self.record_cleanup_view) |view| try view.update(progress, operation.firstFailure(), index_missing);
        var buffer: [128]u8 = undefined;
        self.refresh(try std.fmt.bufPrint(&buffer, "已清理 {d} 项 · 失败 {d} 项{s}", .{ progress.deleted, progress.failed, if (progress.done()) "" else " · 处理中" }));
    }

    fn restoreCleanupOrigin(self: *SettingsHost) void {
        const origin = self.record_cleanup_origin orelse return;
        self.record_cleanup_origin = null;
        if (!self.open or origin.draft_id != self.controller.draft_id or origin.page != self.mounted_page_index) return;
        self.mountedScrollOffset().* = origin.scroll;
        if (self.mounted_page) |page| {
            ui.widgets.scroll_area.setScrollY(page.scroll_state, page.scroll_content, origin.scroll);
            const target = self.cx.node_registry.resolve(origin.focus, null) orelse findSettingsTestId(page.root, "settings.data.clear_logs");
            if (target) |node| self.cx.setFocus(node);
        }
        self.cx.requestRedraw();
    }

    fn findSettingsTestId(node: *ui.Node, id: []const u8) ?*ui.Node {
        if (node.meta.ownership.meta.test_id) |actual| if (std.mem.eql(u8, actual, id)) return node;
        for (node.children.items) |child| if (findSettingsTestId(child, id)) |found| return found;
        return null;
    }

    fn releaseRecordCleanup(self: *SettingsHost) void {
        if (self.record_cleanup) |*operation| operation.deinit();
        self.record_cleanup = null;
        if (self.record_cleanup_dir) |directory| directory.close(self.io);
        self.record_cleanup_dir = null;
    }

    fn contentActionState(raw: *anyopaque, action: settings_content_view.Action) settings_content_view.ActionState {
        if (action != .clear_logs and action != .clear_all) return .{};
        if (action == .clear_all) {
            const self: *SettingsHost = @ptrCast(@alignCast(raw));
            if (self.dataCleanupBlocked()) |reason| return .{ .enabled = false, .reason = reason };
            return .{};
        }
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        if (self.record_cleanup) |*operation| if (operation.running) return .{ .enabled = false, .reason = "正在清理会话记录" };
        if (self.hasActiveCleanupSessions()) return .{ .enabled = false, .reason = "请先结束活动会话" };
        return .{};
    }

    fn mountProviders(raw: *anyopaque, cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        const providers = try @import("config/ai_provider_settings.zig").ProviderView.mountWithHooks(cx, scope, &self.controller, .{ .context = raw, .changed = providersChanged });
        self.providers = providers;
        return providers.root;
    }

    fn providersChanged(raw: *anyopaque) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        if (self.mounted_page) |page| page.refreshFooter();
        self.cx.requestRedraw();
    }

    fn mountProviderAction(raw: *anyopaque, cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        const providers = self.providers orelse return error.ProviderViewUnavailable;
        return providers.mountAddProviderAction(scope, cx);
    }

    fn requestContentEdit(raw: *anyopaque, key: settings_content_view.Key, anchor: *ui.Node) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        self.dismissPicker();
        const page_scope = self.content_scope orelse return;
        if (std.mem.eql(u8, key.section, "keys")) {
            self.recorded_keys = self.controller.model.value.keys;
            const recorder = @import("config/keybinding_picker.zig").mount(self.cx, page_scope, self.card orelse self.panel, anchor, &self.recorded_keys, key.key, .{
                .context = raw,
                .changed = recordedKeysChanged,
                .dismiss = dismissPickerCallback,
            }) catch return;
            self.picker = recorder.root;
            self.keybinding_recorder = recorder;
            self.recording = true;
            if (!recorder.portaled) {
                self.picker_nodes.append(self.allocator, recorder.root) catch return;
                (self.card orelse self.panel).appendChild(self.allocator, recorder.root) catch return;
            }
            recorder.focus();
            return;
        }
        const picker = @import("config/settings_picker.zig").mount(self.cx, page_scope, self.card orelse self.panel, anchor, &self.controller, key, .{
            .context = raw,
            .committed = contentChanged,
            .dismiss = dismissPickerCallback,
            .choose_directory = chooseSettingsDirectory,
        }) catch |err| {
            if (err != error.NativeDirectoryPickerDelegated) self.refresh(@errorName(err));
            return;
        };
        self.picker = picker.root;
        self.picker_nodes.append(self.allocator, picker.root) catch return;
        (self.card orelse self.panel).appendChild(self.allocator, picker.root) catch return;
        self.cx.requestRedraw();
    }

    fn dismissPicker(self: *SettingsHost) void {
        if (self.keybinding_recorder) |recorder| {
            recorder.close();
            self.keybinding_recorder = null;
        } else if (self.picker) |picker| picker.setDisplay(.none);
        self.picker = null;
        self.recording = false;
    }

    fn recordedKeysChanged(raw: *anyopaque) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        self.controller.editKeys(self.recorded_keys) catch return;
        self.pending_rebuild = true;
    }

    fn dismissPickerCallback(raw: *anyopaque) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        self.dismissPicker();
    }

    fn chooseSettingsDirectory(raw: *anyopaque, controller: *SettingsController, key: settings_content_view.Key) void {
        const self: *SettingsHost = @ptrCast(@alignCast(raw));
        const sdk = self.cx.system_sdk orelse return;
        var buffer: [4096]u8 = undefined;
        const directory = (sdk.runDialog(.{ .kind = .pick_folder }, &buffer) catch return) orelse return;
        controller.editKey(key.section, key.key, .{ .text = directory }) catch |err| {
            self.refresh(@errorName(err));
            return;
        };
        self.pending_rebuild = true;
        self.cx.requestRedraw();
    }

    fn rebuildLegacyContent(self: *SettingsHost) !void {
        const p = ws.Palette.fromTheme();
        const model = &self.controller.model;
        const page = model.page();

        // Header: page title + description.
        try self.content.appendChild(self.cx.allocator, try ui.text(self.cx, page.name, .{ .font_size = 13, .font_weight = 700, .color = p.fg }));
        try self.content.appendChild(self.cx.allocator, try ui.text(self.cx, page.description, .{ .font_size = 11, .color = p.fg_muted }));

        // Rows: one per settings key of this page — mockup .row spec:
        // min-h 38, 8px 纵向 padding；.rn 标签列（.t 12.5·500
        // + .d 10 fg3），右侧控件列。
        var key_buffer: [16]settings_pages_mod.ConfigKey = undefined;
        const page_keys = model.pageKeys(&key_buffer);
        for (page_keys) |key| {
            const row = try ui.box(self.cx, .{
                .width = .fill(),
                .direction = .row,
                .align_items = .center,
                .gap = 12,
                .padding = .{ .left = 0, .right = 0, .top = 8, .bottom = 8 },
            }, .{});
            // zenit flex 只是权重：主轴撑满必须显式 .width = .fill()。
            const labels = try ui.box(self.cx, .{ .direction = .column, .gap = 1, .flex = 1, .width = .fill(), .min_width = 0 }, .{});
            try labels.appendChild(self.cx.allocator, try ui.text(self.cx, key.key, .{ .font_size = 12.5, .font_weight = 500, .color = p.fg }));
            try labels.appendChild(self.cx.allocator, try ui.text(self.cx, key.section, .{ .font_size = 10, .color = p.fg_muted }));
            try row.appendChild(self.cx.allocator, labels);
            try row.appendChild(self.cx.allocator, try self.valueControl(key));
            try self.content.appendChild(self.cx.allocator, row);
        }

        self.cx.requestRedraw();
    }

    /// Builds the value control for one key: Inputs for text/number values,
    /// a toggle button for booleans.
    fn valueControl(self: *SettingsHost, key: settings_pages_mod.ConfigKey) !*ui.Node {
        const p = ws.Palette.fromTheme();
        const value = settings_values_mod.read(self.controller.model.value, key.section, key.key) orelse
            return ui.text(self.cx, "—", .{ .font_size = 11, .color = p.fg_muted });
        const click = try self.cx.allocator.create(SettingsEditCell);
        click.* = .{ .host = self, .key = key };
        switch (value) {
            .text, .unsigned, .decimal => {
                var initial_buffer: [128]u8 = undefined;
                var writer = std.Io.Writer.fixed(&initial_buffer);
                switch (value) {
                    .text => |text| writer.print("{s}", .{text}) catch {},
                    .unsigned => |number| writer.print("{d}", .{number}) catch {},
                    .decimal => |number| writer.print("{d}", .{number}) catch {},
                    else => {},
                }
                return design.input(self.cx, self.scope, .{
                    .value = writer.buffered(),
                    .placeholder = key.key,
                    .on_change = self.cx.on(SettingsEditCell, click, SettingsEditCell.onChange),
                }, .{});
            },
            .boolean => |enabled| {
                const ControlVariant = @import("ui").widgets.ControlVariant;
                const btn = try ui.widgets.Button(.{
                    .label = if (enabled) "已开启" else "已关闭",
                    .variant = if (enabled) ControlVariant.primary else ControlVariant.secondary,
                }).mount(self.scope, self.cx);
                btn.behavior.events.on_click = .{ .callback = onSettingsToggleClick, .context = @ptrCast(click) };
                return btn;
            },
        }
    }

    fn cleanup(self: *SettingsHost) void {
        self.releaseRecordCleanup();
        if (self.appearance_initialized) {
            self.resource_worker.?.shutdown(&self.registry) catch |err| {
                applog.warn(.ui, "appearance worker shutdown failed: {s}", .{@errorName(err)});
                if (self.resource_worker.?.takeInstallation()) |value| {
                    var failed = value;
                    failed.deinit();
                }
            };
            if (self.installation) |*receipt| {
                self.resource_worker.?.abortInstallation(receipt) catch |err| {
                    applog.warn(.ui, "appearance installation cleanup could not start: {s}", .{@errorName(err)});
                    receipt.deinit();
                };
                self.installation = null;
            }
            self.resource_worker.?.shutdown(&self.registry) catch |err| {
                applog.warn(.ui, "appearance installation cleanup failed: {s}", .{@errorName(err)});
                if (self.resource_worker.?.takeInstallation()) |value| {
                    var failed = value;
                    failed.deinit();
                }
            };
            self.resource_worker.?.deinit();
            if (self.font_result) |*font| font.deinit(self.allocator);
            if (self.pending_texture) |*texture| texture.deinit();
            if (self.draft_texture) |*texture| texture.deinit();
            if (self.committed_texture) |*texture| texture.deinit();
            self.appearance_state.deinit();
            self.registry.deinit();
            if (self.resource_dir) |directory| directory.close(self.io);
        }
        self.picker_nodes.deinit(self.allocator);
        self.controller.deinit();
        self.allocator.destroy(self);
    }
};

const SettingsNavClick = struct {
    host: *SettingsHost,
    page_index: usize,

    fn activate(self: *SettingsNavClick) void {
        self.host.selectPage(self.page_index);
    }

    fn cleanup(self: *SettingsNavClick) void {
        self.host.allocator.destroy(self);
    }
};

fn onSettingsNavClick(raw: *anyopaque) void {
    const click: *SettingsNavClick = @ptrCast(@alignCast(raw));
    click.host.selectPage(click.page_index);
}

const SettingsEditCell = struct {
    host: *SettingsHost,
    key: @import("config/settings_pages.zig").ConfigKey,

    fn onChange(self: *SettingsEditCell, text: []const u8) void {
        const values = @import("config/settings_values.zig");
        const current = values.read(self.host.controller.model.value, self.key.section, self.key.key) orelse return;
        switch (current) {
            .text => self.host.editKey(self.key, .{ .text = text }),
            .unsigned => {
                const parsed = std.fmt.parseInt(u32, std.mem.trim(u8, text, " "), 10) catch return;
                self.host.editKey(self.key, .{ .unsigned = parsed });
            },
            .decimal => {
                const parsed = std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch return;
                self.host.editKey(self.key, .{ .decimal = parsed });
            },
            else => {},
        }
    }
};

fn onSettingsToggleClick(raw: *anyopaque) void {
    const cell: *SettingsEditCell = @ptrCast(@alignCast(raw));
    const values = @import("config/settings_values.zig");
    const current = values.read(cell.host.controller.model.value, cell.key.section, cell.key.key) orelse return;
    if (current == .boolean) {
        cell.host.editKey(cell.key, .{ .boolean = !current.boolean });
        // Rebuild so the toggle button label/state refreshes.
        cell.host.rebuildAll();
    }
}

/// Root-level keyboard shortcuts (⌘B sidebar, ⌘K quick connect).
const AppNavHost = struct {
    file_application: ?*file_application_mod.Host = null,
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    quick: QuickConnect,
    quick_panel: *ui.Node,
    quick_host: ?*QuickConnectHost = null,
    sidebar_panel: *ui.Node = undefined,
    sidebar_grip: ?*ui.Node = null,
    sidebar_drag_width: f32 = @import("ui/sidebar_model.zig").default_width,
    sidebar_alignment_pending_before_drag: bool = true,
    sidebar_full: ?*ui.Node = null,
    sidebar_empty: ?*ui.Node = null,
    collapsed_sidebar: ?*CollapsedSidebar = null,
    settings: ?*SettingsHost = null,
    ai: ?*AiHost = null,
    quick_backdrop: ?*ui.Node = null,
    session_details: ?*ui.Node = null,
    socks_chip: ?*ui.Node = null,
    status_bar: ?*ui.Node = null,
    title_controls: ?*ui.Node = null,
    title_bar: ?*ui.Node = null,
    transfer_anchor: ?*ui.Node = null,
    notification_anchor: ?*ui.Node = null,
    help_overlay: ?*ui.Node = null,
    last_width: f32 = 0,
    last_height: f32 = 0,
    window_focused: ?bool = null,
    workspace: ?*ws.Workspace = null,
    wizard: ?*wizard_mod.Wizard = null,
    wizard_host: ?*WizardHost = null,
    transfer_host: ?*TransferHost = null,
    connection_details_host: ?*@import("ui/connection_details_host.zig").Host = null,
    asset_group_host: ?*@import("ui/asset_group_host.zig").Host = null,
    menu_host: ?*MenuHost = null,
    roster: @import("ui/group_model.zig").Roster = undefined,
    broadcasts: std.ArrayList(@import("ui/broadcast_controller.zig").Approval) = .empty,
    broadcast_view: ?*@import("ui/broadcast_view.zig").View = null,
    broadcast_epoch: u64 = 1,
    socks_host: ?*Socks5Host = null,
    ime_composing: bool = false,
    app_runtime: ?*App = null,
    native_close_pending: bool = false,
    native_close_started: bool = false,
    application_host: ?*application_host_mod.ApplicationHost = null,
    connection_host: ?*@import("ui/connection_host.zig").Host = null,
    probe_connection_host: ?*@import("ui/probe_connection_host.zig").Host = null,
    session_menu: ?*session_menu_mod.View = null,
    session_menu_anchor: ?*ui.Node = null,
    local_close_view: ?*@import("ui/local_close_view.zig").View = null,
    pending_command_creations: std.ArrayList(struct { source: @import("host/identity.zig").SessionHandle, command_id: u64, created: @import("host/identity.zig").SessionHandle }) = .empty,
    local_drop: ?struct { tab: @import("host/identity.zig").TabId, owner: @import("host/identity.zig").SessionHandle, input_id: u64 } = null,

    local_status_view: ?*@import("ui/local_status_view.zig").View = null,
    status_detail_view: ?*@import("ui/status_detail_view.zig").View = null,
    status_theme_view: ?*@import("ui/status_theme_view.zig").View = null,
    local_status_hash: ?u64 = null,
    local_status_revision: u64 = 0,
    background_view: ?*@import("ui/background_layers.zig").View = null,
    shell_root: ?*ui.Node = null,
    material_pane: ?*ui.Node = null,
    appearance_ui_hash: ?u64 = null,
    appearance_theme: *shell_styles.ThemePublication = undefined,
    empty_choose_label: ?*ui.Signal([]const u8) = null,
    empty_choose_icon: ?*ui.Signal(?ui.SvgAsset) = null,
    empty_has_hosts: ?bool = null,
    host_artwork: [@import("ui/host_os_assets.zig").pixels.len]?u32 = @splat(null),
    empty_logo_texture: ?u32 = null,
    ai_logo_texture: ?u32 = null,
    chrome: struct {
        toolbar_tint: ?*ui.Signal(?ui.Color) = null,
        transfer_badge: ?*ui.Node = null,
        empty_icon: ?*ui.Node = null,
        empty_title: ?*ui.Node = null,
        empty_description: ?*ui.Node = null,
        empty_actions: [2]?struct { node: *ui.Node, style: *ui.Signal(ui.BoxStyle) } = .{ null, null },
        sidebar_title: ?*ui.Node = null,
        sidebar_search: ?*ui.Node = null,
        sidebar_search_icon: ?*ui.Node = null,
        sidebar_search_input: ?ui.widgets.input.InputResult = null,
        sidebar_footer: ?*ui.Node = null,
        sidebar_footer_label: ?*ui.Node = null,
        sidebar_empty_label: ?*ui.Node = null,
        sidebar_empty_button: ?*ui.Node = null,
    } = .{},

    last_status_sample_ms: f64 = -1000,

    fn nativeCloseRequest(raw: *anyopaque, window_id: NativeWindowId, _: App.CloseReason) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const app = self.app_runtime orelse return;
        if (process_windows) |process| if (process.data_cleanup_owner != null) {
            process.data_cleanup_exit = true;
            return;
        };
        if (window_id != app.windowId() or self.native_close_pending) return;
        self.native_close_pending = true;
        self.native_close_started = false;
        if (self.transfer_host) |transfer| transfer.closeManagerPopover();
        if (self.settings) |settings| if (settings.open) settings.toggle();
        self.cx.requestRedraw();
    }

    fn nativeCloseCompleted(raw: *anyopaque, window_id: NativeWindowId) bool {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const app = self.app_runtime orelse return false;
        if (window_id != app.windowId()) return false;
        const host = self.application_host orelse return false;
        host.completeWindowClose() catch |err| {
            applog.warn(.workspace, "window close completion: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    fn showSessionMenu(self: *AppNavHost) void {
        if (self.session_menu) |menu| if (self.session_menu_anchor) |anchor| {
            if (menu.isOpen()) {
                menu.hide();
            } else {
                if (self.workspace) |workspace| {
                    var entries: std.ArrayList(session_menu_mod.Saved) = .empty;
                    defer entries.deinit(self.cx.allocator);
                    for (workspace.registry.hosts) |host| entries.append(self.cx.allocator, .{ .owner = host.owner(), .name = host.name, .icon = @import("ui/session_icon.zig").forHost(workspace.plugins, host.protocolId(), @import("ui/session_os_cache.zig").load(workspace.allocator, workspace.io, workspace.hosts_path, host)) }) catch return;
                    menu.setAll(entries.items) catch return;
                    var recent: std.ArrayList(session_menu_mod.Saved) = .empty;
                    defer recent.deinit(self.cx.allocator);
                    for (0..workspace.recent_connections.len) |rank| {
                        const owner = workspace.recent_connections.resolve(rank, &workspace.registry) orelse continue;
                        for (entries.items) |entry| if (entry.owner.id == owner.id) {
                            recent.append(self.cx.allocator, entry) catch return;
                            break;
                        };
                        if (recent.items.len == 3) break;
                    }
                    menu.setSaved(recent.items) catch return;
                }
                menu.show(anchor) catch |err| applog.warn(.workspace, "session menu: {s}", .{@errorName(err)});
            }
        };
    }

    fn savedSession(raw: *anyopaque, owner: @import("host/identity.zig").AssetOwner) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const workspace = self.workspace orelse return;
        _ = workspace.registry.get(owner) catch |err| {
            workspace.statusFailure(@errorName(err));
            return;
        };
        const index = workspace.registry.indexOf(owner.id) orelse return;
        workspace.newSession(index) catch |err| workspace.statusFailure(@errorName(err));
    }

    fn newSessionProfile(raw: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        if (self.wizard_host) |host| {
            host.selected_group = null;
            host.refreshAssets() catch return;
            remote_editor.loadDraft(host.wizard, .{}) catch return;
            host.wizard.show();
        }
    }

    fn newSftpProfile(raw: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const host = self.wizard_host orelse return;
        host.selected_group = null;
        host.refreshAssets() catch return;
        remote_editor.loadDraft(host.wizard, .{ .protocol = .sftp, .port = 22 }) catch return;
        host.wizard.show();
    }
    fn quickSession(raw: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        self.toggleQuickConnect();
    }

    fn newLocalSession(raw: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const workspace = self.workspace orelse return;
        workspace.newLocalSession(null) catch |err| {
            workspace.statusFailure(@errorName(err));
            applog.warn(.workspace, "local session: {s}", .{@errorName(err)});
        };
    }

    fn newLocalSessionClick(self: *AppNavHost) void {
        newLocalSession(self);
    }

    fn toggleSidebar(self: *AppNavHost) void {
        self.quick.toggleSidebar();
        self.applySidebar();
        self.cx.requestRedraw();
    }

    fn resizeSidebar(event: ui.interaction.drag.Event, raw: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        switch (event.phase) {
            .start => {
                self.sidebar_drag_width = self.quick.sidebar.expanded_width;
                self.sidebar_alignment_pending_before_drag = self.quick.sidebar.initial_width_pending;
                self.quick.sidebar.initial_width_pending = false;
            },
            .move, .end => {
                self.quick.sidebar.expanded_width = std.math.clamp(self.sidebar_drag_width + event.delta.x, 220, @min(480, @max(220, self.cx.viewport.width - 480)));
                if (event.phase == .end) if (self.settings) |settings| {
                    var candidate = settings.runtime.value;
                    candidate.ui.sidebar_width = self.quick.sidebar.expanded_width;
                    settings.runtime.save(self.cx.io, std.Io.Dir.cwd(), candidate) catch |err| {
                        std.log.err("failed to save sidebar width: {s}", .{@errorName(err)});
                        if (self.workspace) |workspace| workspace.statusFailure("侧栏宽度保存失败");
                    };
                };
            },
            .cancel => {
                self.quick.sidebar.expanded_width = self.sidebar_drag_width;
                self.quick.sidebar.initial_width_pending = self.sidebar_alignment_pending_before_drag;
            },
        }
        self.applySidebar();
        self.cx.requestRedraw();
    }

    fn applySidebar(self: *AppNavHost) void {
        self.sidebar_panel.setDisplay(if (self.quick.sidebar.collapsed) .none else .flex);
        self.sidebar_panel.setStyle(self.allocator, .width, .{ .px = self.quick.sidebar.expanded_width });
        if (self.sidebar_grip) |grip| grip.setDisplay(if (self.quick.sidebar.collapsed) .none else .flex);
        if (self.collapsed_sidebar) |collapsed| collapsed.setCollapsed(self.quick.sidebar.collapsed);
    }

    fn homeConnect(self: *AppNavHost) void {
        if (self.workspace) |workspace| if (workspace.registry.hosts.len == 0) {
            if (self.wizard) |wizard| wizard.show();
            return;
        };
        self.toggleQuickConnect();
    }
    fn loadEmptyLogo(self: *AppNavHost) !void {
        const app = self.app_runtime orelse return;
        if (self.ai_logo_texture == null) {
            var mascot = try @import("config/background_asset.zig").decode(self.allocator, @import("app_icon_assets").ai_assistant, .{});
            defer mascot.deinit(self.allocator);
            self.ai_logo_texture = try app.renderer.image_renderer.loadTexture(mascot.width, mascot.height, mascot.pixels);
            if (self.ai) |ai| ai.welcome_logo_texture = self.ai_logo_texture;
        }
        const node = self.chrome.empty_icon orelse return;
        if (self.empty_logo_texture != null) return;
        var image = try @import("config/background_asset.zig").decode(self.allocator, @import("app_icon_assets").transparent, .{});
        defer image.deinit(self.allocator);
        const texture = try app.renderer.image_renderer.loadTexture(image.width, image.height, image.pixels);
        self.empty_logo_texture = texture;
        node.setImage(.{ .texture_id = texture });
        node.markRenderDirty();
    }

    fn paintHostArtwork(self: *AppNavHost, node: *ui.Node) void {
        const app = self.app_runtime orelse return;
        if (node.getImage()) |image| {
            if (!ui.Color.eql(image.tint, ui.Color.WHITE)) _ = node.setTint(ui.Color.WHITE);
            return;
        }
        const icon = node.getIcon() orelse return;
        const assets = @import("ui/host_os_assets.zig");
        const index = assets.index(icon.icon_id) orelse return;
        if (self.host_artwork[index] == null) self.host_artwork[index] = app.renderer.image_renderer.loadTexture(72, 72, assets.pixels[index]) catch return;
        node.setIcon(null);
        node.setImage(.{ .texture_id = self.host_artwork[index].?, .tint = ui.Color.WHITE });
        node.markRenderDirty();
    }
    fn syncHostArtwork(self: *AppNavHost) void {
        const workspace = self.workspace orelse return;
        for (workspace.host_rows.items) |row| self.paintHostArtwork(row.view.dot);
        if (self.session_menu) |menu| if (menu.isOpen()) {
            for (menu.saved_rows.items) |row| self.paintHostArtwork(row.icon);
            for (menu.more_rows.items) |row| self.paintHostArtwork(row.icon);
        };
    }
    fn syncHomeConnect(self: *AppNavHost) void {
        const workspace = self.workspace orelse return;
        const has_hosts = workspace.registry.hosts.len > 0;
        if (self.empty_has_hosts == has_hosts) return;
        self.empty_has_hosts = has_hosts;
        if (self.empty_choose_label) |label| label.set(if (has_hosts) "快速连接" else "新建连接");
        if (self.empty_choose_icon) |icon| icon.set(if (has_hosts) @import("ui/quick_connect_icon.zig").asset else ui.icons.plus);
        if (self.chrome.empty_description) |node| node.setTextContent(self.allocator, if (has_hosts) "直接打开本地终端，或从左侧选择已保存的 SSH / SFTP 连接。" else "直接打开本地终端，或新建一个 SSH / SFTP 连接。") catch {};
    }
    fn toggleQuickConnect(self: *AppNavHost) void {
        const host = self.quick_host orelse return;
        if (host.view.isOpen()) host.close() else host.show() catch |err| {
            if (self.workspace) |workspace| workspace.statusFailure(@errorName(err));
        };
        self.cx.requestRedraw();
    }

    fn hookRun(ctx: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *AppNavHost = @ptrCast(@alignCast(ctx));
        if (self.menu_host) |menu| menu.drainSidebarAction();
        if (self.wizard_host) |host| if (self.workspace) |workspace| {
            if (remote_editor.editor(host.wizard)) |editor| editor.setScrollbackDefault(workspace.app_config.ui.scrollback_limit);
        };
        if (process_windows) |process| if (process.data_cleanup_owner != null) return .done;
        if (self.quick_host) |host| if (host.view.isOpen()) host.refreshAssets() catch |err| {
            if (self.workspace) |workspace| workspace.statusFailure(@errorName(err));
        };
        if (self.workspace) |workspace| {
            const menu_owner = if (self.menu_host) |menu| if (menu.state.open == .host_asset) menu.captured_asset else null else null;
            workspace.setSidebarMenuOwner(menu_owner);
        }
        if (self.menu_host) |menu| if (menu.asset_action_view) |view| if (view.isVisible()) {
            const colors = app_theme.current();
            if (menu.asset_action_colors == null or !std.meta.eql(menu.asset_action_colors.?, colors)) {
                view.retheme() catch {};
                menu.asset_action_colors = colors;
            }
        };
        if (self.app_runtime) |app| {
            const focused = app.win.isFocused();
            if (self.window_focused == true and !focused) {
                self.ime_composing = false;
                if (self.workspace) |workspace| {
                    workspace.setCommandHeld(false);
                    workspace.finishRecentTabSwitch();
                }
            }
            self.window_focused = focused;
        }
        if (self.settings) |settings| _ = settings.poll();
        self.refreshAppearance() catch |err| applog.warn(.ui, "appearance publication: {s}", .{@errorName(err)});
        // AppKit reports only controls occupying the client header. In native
        // fullscreen its hidden header has none; zoom/maximize keeps them.
        const title_chrome_changed = if (self.app_runtime) |app|
            if (self.title_bar) |bar| shell_styles.syncTitleChrome(self.allocator, bar, app.chromeState()) else false
        else
            false;
        if (self.application_host) |host| {
            _ = host.safeTick() catch |err| {
                applog.warn(.workspace, "host receipt: {s}", .{@errorName(err)});
                return .done;
            };
        }
        self.pollCommandCreations();
        if (self.local_close_view) |view| if (view.session) |id| if (self.workspace) |workspace| {
            const tab = workspace.sessionTab(id);
            if (tab == null or workspace.confirming_id == null or workspace.confirming_id.? != tab.?.tab_id) view.cancel();
        };
        if (self.native_close_pending) {
            if (self.settings) |settings| {
                if (settings.busy()) {
                    self.cx.requestRedraw();
                    return .done;
                }
                const decision_open = if (settings.decision_open) |open| open.get() else false;
                if (settings.open and !decision_open) settings.toggle();
            }
            const settings_open = if (self.settings) |settings| settings.open else false;
            if (!settings_open) if (self.application_host) |host| {
                if (self.wizard_host) |wizard_host| wizard_host.probe_controller.cancelAll();
                if (self.native_close_started and !host.windowClosePending()) {
                    self.native_close_pending = false;
                    self.native_close_started = false;
                    return .done;
                }
                if (!self.native_close_started) {
                    _ = host.requestWindowClose() catch |err| {
                        self.native_close_pending = false;
                        applog.warn(.workspace, "window close request: {s}", .{@errorName(err)});
                        return .done;
                    };
                    self.native_close_started = true;
                }
                // Keep the original file host alive while cancelled picker
                // reads deliver their terminal response and retire their key.
                const remote_released = if (self.ai) |ai| if (ai.remote_picker) |picker| picker.shutdown() else true else true;
                if (host.windowCloseReady()) if (self.app_runtime) |app| {
                    if (!remote_released) {
                        self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
                        return .done;
                    }
                    // A test owns app-scoped native resources outside the tab
                    // batch. Its controller retires only after real release.
                    if (self.wizard_host) |wizard_host| if (wizard_host.probe_controller.jobs.items.len != 0) {
                        self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
                        return .done;
                    };
                    if (host.domain.attachments.items.len == 1) if (self.transfer_host) |transfer| {
                        if (transfer.tasks.shutdownStep() != .released) {
                            self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
                            return .done;
                        }
                    };
                    _ = app.commitClose();
                };
            };
        }
        if (self.settings) |settings| if (settings.open) {
            if (self.session_menu) |menu| if (menu.isOpen()) menu.hide();
        };
        if (self.settings) |settings| if (settings.pending_rebuild) {
            const composing = (if (settings.mounted_page) |page| page.isComposing() else false) or (if (settings.providers) |providers| providers.isComposing() else false);
            if (!composing) {
                settings.pending_rebuild = false;
                settings.rebuildAll();
                return .needs_layout;
            }
        };
        if (self.settings) |settings| if (settings.restoreScroll()) return .needs_layout;
        const width = self.cx.viewport.width;
        self.syncHomeConnect();
        self.syncHostArtwork();
        var sidebar_width_changed = false;
        if (self.quick.sidebar.initial_width_pending) if (self.workspace) |workspace| if (workspace.visibleLocalTerminalTabRect()) |rect| {
            const left = if (self.sidebar_panel.parent) |row| row.globalRect().x else shell_styles.outer;
            sidebar_width_changed = self.quick.sidebar.alignInitialWidth(rect.x + rect.w, left, width);
            if (sidebar_width_changed) self.applySidebar();
        };
        const sidebar_width: ui.Sizing = .{ .px = self.quick.sidebar.expanded_width };
        if (!std.meta.eql(self.sidebar_panel.style.width, sidebar_width)) {
            self.applySidebar();
            sidebar_width_changed = true;
        }
        const before = self.quick.sidebar.collapsed;
        if (self.settings) |settings| {
            self.quick.sidebar.applyCommittedPreference(settings.runtime.value.ui.sidebar_collapsed, width);
        } else self.quick.sidebar.updateForWindow(width);
        if (self.workspace) |workspace| _ = self.quick.sidebar.setSessionCount(workspace.tabs.items.len);
        const resize = @abs(width - self.last_width) > 0.5 or @abs(self.cx.viewport.height - self.last_height) > 0.5;
        self.last_width = width;
        self.last_height = self.cx.viewport.height;
        if (self.settings) |settings| if (settings.card) |card| {
            const expected_width: ui.Sizing = .{ .px = @max(1, @min(@import("ui/v3_geometry.zig").settings_width, self.cx.viewport.width - 32)) };
            const expected_height: ui.Sizing = .{ .px = settings_content_view.constrainedModalHeight(settings.controller.model.page_index, self.cx.viewport.height) };
            const navigation_width: ui.Sizing = .{ .px = if (width < 950) @import("ui/v3_geometry.zig").settings_sidebar_compact else @import("ui/v3_geometry.zig").settings_sidebar };
            if (settings.navigation) |navigation| if (!std.meta.eql(navigation.style.width, navigation_width)) navigation.setStyle(self.allocator, .width, navigation_width);
            if (settings.layout) |layout| {
                const gap: f32 = if (width < 950) 10 else 16;
                if (layout.style.gap != gap) layout.setStyle(self.allocator, .gap, gap);
            }
            if (resize or !std.meta.eql(card.style.width, expected_width) or !std.meta.eql(card.style.height, expected_height)) {
                settings.panel.style.padding = .{};
                if (settings.layout) |layout| layout.setStyle(self.allocator, .gap, if (width < 950) @as(f32, 10) else @as(f32, 16));
                if (settings.navigation) |navigation| navigation.setStyleInline(self.allocator, .{ .width = .{ .px = if (width < 950) @import("ui/v3_geometry.zig").settings_sidebar_compact else @import("ui/v3_geometry.zig").settings_sidebar } });
                card.setStyleInline(self.allocator, .{
                    .padding = .{},
                    .height = .{ .px = settings_content_view.constrainedModalHeight(settings.controller.model.page_index, self.cx.viewport.height) },
                    .width = .{ .px = @max(0, @min(@import("ui/v3_geometry.zig").settings_width, self.cx.viewport.width - 32)) },
                });
            }
        };
        if (before != self.quick.sidebar.collapsed) self.applySidebar();

        if (self.workspace) |workspace| {
            const no_hosts = workspace.registry.hosts.len == 0 and workspace.registry.groups.len == 0;
            if (workspace.sidebar_chrome) |sidebar| sidebar.setSearchAvailable(workspace.registry.hosts.len != 0);
            if (self.title_controls) |controls| controls.setDisplay(.flex);
            if (self.sidebar_full) |full| full.setDisplay(if (no_hosts) .none else .flex);
            if (self.sidebar_empty) |empty| empty.setDisplay(if (no_hosts) .flex else .none);
            const has_session = workspace.active_tab != null or workspace.active_group_view != null;
            if (self.ai) |ai| if (ai.toolbar_trigger) |trigger| trigger.setDisplay(if (has_session) .flex else .none);
            if (self.chrome.transfer_badge) |badge| {
                const count = if (self.transfer_host) |transfer| transfer.manager.count() else 0;
                badge.setDisplay(if (count == 0) .none else .flex);
                if (count != 0 and badge.children.items.len != 0) {
                    var count_buffer: [24]u8 = undefined;
                    const label = std.fmt.bufPrint(&count_buffer, "{d}", .{count}) catch "";
                    badge.children.items[0].setTextContent(self.allocator, label) catch {};
                }
            }
            if (self.transfer_host) |transfer| {
                const pane: ?*ui.Node = if (workspace.active_tab) |active| if (active < workspace.tabs.items.len) workspace.tabs.items[active].root else null else null;
                transfer.panel.setPaneAnchor(pane);
            }
            if (self.ai) |ai| if (ai.ownerBounds()) |pane| {
                const owner_bounds: @import("ai/float_model.zig").Rect = .{ .x = pane.x, .y = pane.y, .width = pane.w, .height = pane.h };
                const window_bounds: @import("ai/float_model.zig").Rect = .{ .x = 0, .y = 0, .width = self.cx.viewport.width, .height = self.cx.viewport.height };
                if (ai.gestures) |gestures| gestures.updateBounds(owner_bounds, window_bounds);
                const composer_height: f32 = if (ai.composer_node) |node| if (node.style.height == .px) node.style.height.px else 90 else 90;
                const rect = ai.controller.model.rect(owner_bounds, window_bounds);
                const parent = ai.panel.parent orelse ai.panel;
                const parent_rect = parent.globalRect();
                const ext = ai.panel.style.ensureExtPanic(self.allocator);
                const ai_geometry_changed = ai.panel.style.width != .px or @abs(ai.panel.style.width.px - rect.width) > 0.5 or if (ai.card_box) |card| card.style.height != .px or @abs(card.style.height.px - rect.height) > 0.5 else false;
                const position_changed = ext.inset.left != .px or ext.inset.top != .px or @abs(ext.inset.left.px - (rect.x - parent_rect.x)) > 0.5 or @abs(ext.inset.top.px - (rect.y - parent_rect.y)) > 0.5;
                ext.inset = .{ .left = .{ .px = rect.x - parent_rect.x }, .top = .{ .px = rect.y - parent_rect.y } };
                ai.panel.style.width = .{ .px = rect.width };
                if (ai.card_box) |card| {
                    card.style.width = .{ .px = rect.width };
                    card.style.height = .{ .px = rect.height };
                    if (ai_geometry_changed) card.markLayoutDirty();
                }
                if (ai.conversation_viewport) |viewport| {
                    const desired_height = @max(0, rect.height - 54 - composer_height);
                    if (viewport.style.height != .px or @abs(viewport.style.height.px - desired_height) > 0.5) {
                        viewport.style.height = .{ .px = desired_height };
                        viewport.markLayoutDirty();
                    }
                }
                if (resize or ai_geometry_changed or position_changed) ai.panel.markLayoutDirty();
            };
            const group_active = workspace.active_group_view != null;
            const local_active = !group_active and if (workspace.active_tab) |index| index < workspace.tabs.items.len and workspace.isLocalSession(workspace.tabs.items[index].id) else false;
            const terminal_active = if (workspace.active_tab) |index| index < workspace.tabs.items.len and workspace.tabs.items[index].terminal != null else false;
            const status_capabilities = if (self.application_host) |application| if (workspace.active_tab) |index| if (index < workspace.tabs.items.len and workspace.tabs.items[index].content_owner == .session) application.sessions.capabilitySnapshot(workspace.tabs.items[index].content_owner.session) catch null else null else null else null;
            const route_status = if (status_capabilities) |snapshot| @import("host/actions.zig").project(.open_route_details, snapshot).visible else false;
            const transfer_status = if (status_capabilities) |snapshot| @import("host/actions.zig").project(.upload, snapshot).visible else false;
            const forward_status = if (status_capabilities) |snapshot| @import("host/actions.zig").project(.toggle_socks, snapshot).visible else false;
            if (self.session_details) |details| details.setDisplay(if (has_session and route_status) .flex else .none);
            if (self.socks_chip) |chip| chip.setDisplay(if (forward_status) .flex else .none);
            if (self.status_bar) |bar| bar.setDisplay(if (local_active or (has_session and !terminal_active and !route_status and !transfer_status)) .none else .flex);
            if (self.connection_details_host) |host| if (host.ssh_status.controls) |controls| {
                controls.sidebar_width = self.quick.sidebar.width();
                self.refreshBroadcastStatus(controls);
            };
            if (self.local_status_view) |view| {
                view.root.setDisplay(if (local_active) .flex else .none);
                view.setSidebarCollapsed(self.quick.sidebar.collapsed);
                view.layoutForWidth(@max(0, self.cx.viewport.width - 2 * shell_styles.outer));
            }
            if (self.collapsed_sidebar) |restore| {
                const destination = if (local_active and self.local_status_view != null) self.local_status_view.?.root else self.status_bar;
                if (destination) |bar| if (restore.root.parent != bar) {
                    if (restore.root.parent) |parent| parent.removeChild(restore.root);
                    bar.insertChildBefore(self.allocator, restore.root, if (bar.children.items.len != 0) bar.children.items[0] else null) catch {};
                };
            }
            self.refreshLocalStatus(local_active) catch |err| applog.warn(.ui, "local status: {s}", .{@errorName(err)});
            if (self.status_detail_view) |view| {
                if (self.local_status_view) |status_view| view.reanchor(status_view.root.globalRect().y);
                view.flush() catch |err| applog.warn(.ui, "status detail: {s}", .{@errorName(err)});
            }
            if (!has_session) {
                if (self.ai) |ai| {
                    ai.controller.model.visible = false;
                    ai.controller.model.expanded = false;
                    ai.panel.setDisplay(.none);
                }
            }
        }

        return if (before != self.quick.sidebar.collapsed or resize or title_chrome_changed or sidebar_width_changed) .needs_layout else .done;
    }

    fn onEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const self: *AppNavHost = @ptrCast(@alignCast(context orelse return .ignored));
        if (process_windows) |process| if (process.data_cleanup_owner) |owner| {
            return if (self.settings == owner) .ignored else .handled;
        };
        if (self.asset_group_host) |host| if (host.isVisible()) switch (event) {
            .key_down, .key_up => return .ignored,
            .drag => return .stop,
            else => {},
        };
        if (self.connection_host) |host| if (host.blocksGlobalActions()) switch (event) {
            .key_down, .key_up => return .ignored,
            .drag => return .stop,
            else => {},
        };
        if (self.probe_connection_host) |host| if (host.blocksGlobalActions()) switch (event) {
            .key_down, .key_up => return .ignored,
            .drag => return .stop,
            else => {},
        };
        if (self.connection_details_host) |host| if (host.blocksGlobalActions()) switch (event) {
            .key_down, .key_up => return .ignored,
            .drag => return .stop,
            else => {},
        };
        if (self.menu_host) |menu| if (menu.asset_action_view) |view| if (view.isVisible()) switch (event) {
            .key_down, .key_up => return .ignored,
            .drag => return .stop,
            else => {},
        };
        if (self.transfer_host) |transfer| if (transfer.conflict_view) |view| if (view.isVisible()) switch (event) {
            .key_down, .key_up => return .ignored,
            .drag => return .stop,
            else => {},
        };
        switch (event) {
            .drag => |drag| return self.localDrag(drag),
            .key_down => |key| {
                if (self.workspace) |workspace| workspace.setCommandHeld(key.modifiers.super);
                if (self.ime_composing) return .ignored;
                if (key.key == .escape) {
                    if (self.transfer_host) |transfer| if (transfer.session_panel) |panel| if (panel.root.style.display != .none) {
                        panel.hide();
                        return .stop;
                    };
                    if (self.transfer_host) |transfer| if (transfer.manager_panel) |panel| if (panel.root.style.display != .none) {
                        transfer.closeManagerPopover();
                        return .stop;
                    };
                    if (self.menu_host) |menu| if (menu.state.open != null) {
                        menu.hide();
                        return .stop;
                    };
                    if (self.status_theme_view) |view| if (view.isOpen()) {
                        view.hide();
                        return .stop;
                    };
                    if (self.status_detail_view) |view| if (view.controller.popover != null) {
                        view.hide();
                        return .stop;
                    };
                }
                if (self.session_menu) |menu| if (menu.isOpen()) {
                    const result = menu.handleKey(key.key);
                    if (result != .ignored) return result;
                    if (key.modifiers.super) return .stop;
                    return .ignored;
                };
                if (self.settings) |settings| if (settings.recording) return .ignored;
                if (self.settings) |settings| if (settings.open) {
                    if (settings.decision_open) |open| if (open.peek()) return .ignored;
                    if (key.key == .escape) {
                        if (settings.appearance_context.preview_active) {
                            settings.setMaterialPreview(false);
                            return .stop;
                        }
                        if (settings.mounted_page) |page| if (page.consumeEscape()) return .stop;
                        if (settings.providers) |providers| if (providers.consumeEscape()) return .stop;
                        if (settings.picker != null) settings.dismissPicker() else settings.toggle();
                        return .stop;
                    }
                    if (!(key.modifiers.super and key.key == .comma)) return .ignored;
                };
                if (((key.key == .tab and key.modifiers.ctrl) or (key.key == .r and key.modifiers.super and key.modifiers.shift)) and self.recentTabBlocked()) return .ignored;
                if (self.workspace) |workspace| {
                    const handled = workspace.handleTabKey(key.key, key.modifiers);
                    if (handled != .ignored) return handled;
                }
                if (key.key == .escape) {
                    if (self.socks_host) |socks| if (socks.exposure) |exposure| if (exposure.visible) {
                        exposure.hide();
                        return .stop;
                    };
                    if (self.wizard) |wizard| if (wizard.root) |root| if (root.style.display != .none) {
                        wizard.cancel();
                        return .stop;
                    };
                    if (self.transfer_host) |transfer| if (transfer.panel.isVisible()) {
                        transfer.panel.hide();
                        return .stop;
                    };
                    if (self.socks_host) |socks| if (socks.config) |config| if (config.visible) {
                        config.hide();
                        return .stop;
                    };
                    if (self.socks_host) |socks| if (socks.info) |info| if (info.root.style.display != .none) {
                        info.hide();
                        return .stop;
                    };
                    if (self.workspace) |workspace| if (workspace.cancelRenameTab()) return .handled;
                    if (self.menu_host) |menu| {
                        if (menu.rename_input) |input| {
                            menu.cx.detachChild(menu.panel, input);
                            menu.cx.destroyDetached(input);
                            menu.rename_input = null;
                            menu.hide();
                            return .handled;
                        }
                        if (menu.state.open != null) {
                            menu.state.dismiss();
                            menu.hide();
                            return .handled;
                        }
                    }
                    if (self.help_overlay) |help| {
                        if (help.style.display != .none) {
                            help.setDisplay(.none);
                            return .handled;
                        }
                    }
                    if (self.settings) |settings| if (settings.open) {
                        if (settings.providers) |providers| if (providers.consumeEscape()) return .handled;
                        if (settings.picker != null) {
                            settings.dismissPicker();
                            return .handled;
                        }
                        settings.toggle();
                        return .handled;
                    };
                    if (self.quick.quick_connect_open) {
                        self.toggleQuickConnect();
                        return .handled;
                    }
                }
                if (!key.modifiers.super) return .ignored;
                if (self.workspace) |workspace| {
                    if (workspace.app_config.keys.match(key.key, key.modifiers)) |action| switch (action) {
                        .new_tab => {
                            self.showSessionMenu();
                            return .handled;
                        },
                        .close_tab => {
                            workspace.requestCloseActive();
                            return .handled;
                        },
                        .split_vertical, .split_horizontal => {
                            self.bindGroupWorkspace(workspace);
                            workspace.splitGroup(&self.roster, action == .split_horizontal) catch |err| workspace.statusFailure(@errorName(err));
                            return .handled;
                        },
                        .quick_connect => {
                            self.toggleQuickConnect();
                            return .handled;
                        },
                        .sidebar => {
                            self.toggleSidebar();
                            return .handled;
                        },
                        .ai => {
                            if (self.ai) |ai| ai.toggle();
                            return .handled;
                        },
                        .search => {
                            if (self.menu_host) |menu| if (menu.activeTerminal()) |terminal| terminal.openSearch();
                            return .handled;
                        },
                        .upload => {
                            if (self.transfer_host) |transfer| transfer.openPanel();
                            return .handled;
                        },
                        .copy => {
                            // When the AI composer is visible, let the focused
                            // Zenit Input consume clipboard shortcuts. Routing
                            // Cmd-C through the terminal menu would copy the
                            // active pane instead of the prompt.
                            if (self.focusedTextEditor()) return .ignored;
                            if (self.menu_host) |menu| {
                                if (menu.activeTerminal()) |terminal| {
                                    if (!terminal.hasSelection()) _ = terminal.pushText("\x03") else menu.runAction(.copy);
                                }
                            }
                            return .stop;
                        },
                        .paste => {
                            // Same focus rule for Cmd-V: the AI Input owns the
                            // paste event while its floating panel is open;
                            // never inject clipboard text into the SSH PTY.
                            if (self.focusedTextEditor()) return .ignored;
                            if (self.menu_host) |menu| menu.runAction(.paste);
                            return .stop;
                        },
                        .tab_1, .tab_2, .tab_3, .tab_4, .tab_5, .tab_6, .tab_7, .tab_8, .tab_9 => {
                            const index = @backingInt(action) - @backingInt(@import("config/keybindings.zig").Action.tab_1);
                            workspace.selectTabOrdinal(index);
                            return .handled;
                        },
                        .previous_tab, .next_tab => {
                            workspace.selectAdjacentTab(action == .next_tab);
                            return .handled;
                        },
                        else => {},
                    };
                }
                if (key.key == .n) {
                    if (self.wizard) |wizard| wizard.show();
                    return .handled;
                }
                if (key.key == .comma) {
                    if (self.settings) |settings| settings.toggle();
                    return .handled;
                }
                return .ignored;
            },
            .key_up => |key| {
                if (self.workspace) |workspace| {
                    workspace.setCommandHeld(key.modifiers.super);
                    if (!key.modifiers.ctrl) workspace.finishRecentTabSwitch();
                }
                return .ignored;
            },
            .ime_preedit => |preedit| {
                self.ime_composing = preedit.text.len > 0;
                return .ignored;
            },
            .ime_commit => {
                self.ime_composing = false;
                return .ignored;
            },
            .blur => {
                self.ime_composing = false;
                return .ignored;
            },
            else => return .ignored,
        }
    }

    fn recentTabBlocked(self: *AppNavHost) bool {
        if (self.focusedTextEditor() or self.quick.quick_connect_open) return true;
        if (self.menu_host) |menu| if (menu.state.open != null) return true;
        if (self.wizard) |wizard| if (wizard.root) |root| if (root.style.display != .none) return true;
        if (self.transfer_host) |transfer| if (transfer.panel.isVisible()) return true;
        if (self.socks_host) |socks| {
            if (socks.exposure) |view| if (view.visible) return true;
            if (socks.config) |view| if (view.visible) return true;
            if (socks.info) |view| if (view.root.style.display != .none) return true;
        }
        if (self.help_overlay) |view| if (view.style.display != .none) return true;
        if (self.ai) |ai| if (ai.controller.model.visible) return true;
        return false;
    }

    fn focusedTextEditor(self: *AppNavHost) bool {
        const focused = self.cx.focus_manager.getFocused() orelse return false;
        // Terminal is also a text-input client for IME. It retains its own
        // clipboard policy; all other editors consume native clipboard keys.
        if (self.workspace) |workspace| {
            for (workspace.tabs.items) |tab| if (tab.terminal != null and focused == tab.terminal.?.root) return false;
        }
        return focused.behavior.interaction.text_input_client != null;
    }

    fn importHosts(self: *AppNavHost) void {
        self.importHostsFile() catch |err| {
            if (self.workspace) |workspace| workspace.statusFailure(@errorName(err));
        };
    }

    fn importHostsFile(self: *AppNavHost) !void {
        const workspace = self.workspace orelse return error.WorkspaceUnavailable;
        const sdk = self.cx.system_sdk orelse return error.NativeDialogUnavailable;
        var buffer: [4096]u8 = undefined;
        const path = (try sdk.runDialog(.{ .kind = .open_file, .title = "导入 hosts.toml" }, &buffer)) orelse return;
        var imported = try @import("config/store.zig").loadHostsForImport(self.cx.io, std.Io.Dir.cwd(), self.allocator, path);
        defer imported.deinit();
        // Parse and validate the complete file before changing live assets.
        for (imported.hosts) |host| try host.validate();
        const previous = workspace.registry.hosts;
        errdefer workspace.registry.hosts = previous;
        for (imported.hosts) |host| _ = try workspace.appendHost(host);
        try workspace.saveRegistry();
        try workspace.rebuildSidebar();
        workspace.status("已导入主机配置");
    }

    fn cleanup(self: *AppNavHost) void {
        if (self.app_runtime) |app| if (self.ai_logo_texture) |id| app.renderer.image_renderer.unloadTexture(id);
        if (self.app_runtime) |app| if (self.empty_logo_texture) |id| app.renderer.image_renderer.unloadTexture(id);
        if (self.app_runtime) |app| for (self.host_artwork) |texture| if (texture) |id| app.renderer.image_renderer.unloadTexture(id);
        self.cx.removeAfterLayoutHook(self);
        if (self.ai) |ai| {
            ai.request_cancel.cancel();
            ai.tool_bridge.shutdown(self.application_host);
            if (ai.worker_thread) |thread| {
                thread.join();
                ai.worker_thread = null;
            }
            if (ai.remote_picker) |picker| {
                if (picker.shutdown()) picker.release() catch {};
            }
            ai.file_application = null;
            ai.application_host = null;
        }
        const application_host = self.application_host;
        self.application_host = null;
        const file_application = self.file_application;
        const files_released = if (file_application) |files| files.shutdownStep() == .released else true;
        if (application_host) |host| host.deinit();
        if (files_released) if (file_application) |files| files.deinit() catch {};
        for (self.broadcasts.items) |*approval| approval.deinit(self.allocator);
        self.broadcasts.deinit(self.allocator);
        self.pending_command_creations.deinit(self.allocator);
        self.roster.deinit();
        if (self.cx.root) |root| {
            if (root.behavior.events.capture_context == @as(?*anyopaque, @ptrCast(self))) {
                root.behavior.events.on_event_capture = null;
                root.behavior.events.capture_context = null;
            }
        }
        self.quick.deinit();
        self.allocator.destroy(self);
    }

    fn collapsedSearch(ctx: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(ctx));
        self.toggleQuickConnect();
    }

    fn localDropMarker(_: *AppNavHost, _: ui.HandlerRef.DropPayload) void {}

    fn localDrag(self: *AppNavHost, drag: ui.events.DragEvent) ui.events.EventResult {
        if (drag.kind == .exited) {
            if (drag.session_ended) self.local_drop = null;
            return .ignored;
        }
        const workspace = self.workspace orelse return .ignored;
        if (drag.kind == .entered or drag.kind == .updated) {
            if (self.local_drop != null) return .ignored;
            const index = workspace.active_tab orelse return .ignored;
            if (index >= workspace.tabs.items.len) return .ignored;
            const tab = workspace.tabs.items[index];
            if (!tab.local or tab.closing or self.cx.focus_manager.getFocused() != tab.terminal.?.root) return .ignored;
            const rect = tab.terminal.?.root.globalRect();
            if (drag.x < rect.x or drag.y < rect.y or drag.x >= rect.x + rect.w or drag.y >= rect.y + rect.h) return .ignored;
            const owner = switch (tab.content_owner) {
                .session => |owner| owner,
                else => return .ignored,
            };
            self.local_drop = .{ .tab = tab.tab_id, .owner = owner, .input_id = tab.terminal.?.root.id };
            return .ignored;
        }
        if (drag.kind != .dropped) return .ignored;
        const captured = self.local_drop orelse return .ignored;
        self.local_drop = null;
        const index = workspace.tabIndexById(captured.tab) orelse return .stop;
        const tab = workspace.tabs.items[index];
        if (!tab.local or tab.closing or workspace.active_tab != index or !tab.content_owner.eql(.{ .session = captured.owner }) or tab.terminal.?.root.id != captured.input_id or self.cx.focus_manager.getFocused() != tab.terminal.?.root) return .stop;
        const rect = tab.terminal.?.root.globalRect();
        if (drag.x < rect.x or drag.y < rect.y or drag.x >= rect.x + rect.w or drag.y >= rect.y + rect.h) return .stop;
        if (drag.payload_truncated or drag.payload_kind != .file_or_url or self.ime_composing) {
            workspace.status(if (self.ime_composing) "请先完成输入法组字再插入路径" else "无法插入：拖入的文件列表不完整或不是本地路径");
            return .stop;
        }
        var paths = @import("local/path_input.zig").decodeDropPaths(self.allocator, drag.paths) catch |err| {
            workspace.statusFailure(@errorName(err));
            return .stop;
        };
        defer paths.deinit();
        if (paths.paths.len == 0) return .stop;
        tab.terminal.?.insertLocalPaths(captured.owner, paths.paths) catch |err| workspace.statusFailure(@errorName(err));
        return .stop;
    }

    fn globalThemeBusy(raw: *anyopaque) bool {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        return if (self.settings) |settings| settings.busy() else true;
    }
    fn selectGlobalTheme(raw: *anyopaque, id: []const u8) !void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const settings = self.settings orelse return error.SettingsUnavailable;
        try settings.immediateTheme(id);
        self.cx.requestRedraw();
    }
    fn manageGlobalThemes(raw: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const settings = self.settings orelse return;
        if (settings.busy()) return;
        if (!settings.open) settings.toggle();
        if (settings.appearance_context.preview_active) settings.setMaterialPreview(false);
        settings.controller.theme_library.open = true;
        settings.appearance_context.library_dismissed = false;
        settings.selectPage(0);
        settings.pending_rebuild = true;
        self.cx.requestRedraw();
    }
    fn showGlobalTheme(raw: *anyopaque, trigger: *ui.Node) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const settings = self.settings orelse return;
        const view = self.status_theme_view orelse return;
        if (self.status_detail_view) |detail| detail.hide();
        view.update(settings.runtime.value.ui.theme, settings.registry.revision, settings.runtime.value.config_revision) catch |err| {
            if (self.workspace) |workspace| workspace.statusFailure(@errorName(err));
            return;
        };
        const top = if (self.local_status_view) |status_view| if (status_view.root.style.display != .none) status_view.root.globalRect().y else if (self.status_bar) |bar| bar.globalRect().y else trigger.globalRect().y else trigger.globalRect().y;
        view.show(trigger, top) catch |err| {
            if (self.workspace) |workspace| workspace.statusFailure(@errorName(err));
        };
    }
    fn showThemeFromMenu(raw: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const status_view = self.local_status_view orelse return;
        showGlobalTheme(raw, if (status_view.theme_button.style.display != .none) status_view.theme_button else status_view.more_button);
    }

    fn refreshAppearance(self: *AppNavHost) !void {
        const settings = self.settings orelse return;
        if (!settings.appearance_initialized) return;
        const runtime = settings.runtime.value;
        const record = settings.registry.get(runtime.ui.theme) orelse return;
        const preview = settings.appearance_context.preview_active;
        const materials = if (preview) settings.controller.model.value.ui.materials else runtime.ui.materials;
        const texture = if (preview) settings.draft_texture orelse settings.committed_texture else settings.committed_texture;
        const image: ?@import("ui/background_layers.zig").Image = if (texture) |value| .{ .id = value.id, .width = value.width, .height = value.height, .repeating = value.repeating } else null;
        const showing = materials.background.enabled and image != null;
        _ = app_theme.setMaterialParameters(materials.background.transparency, @floatFromInt(materials.blur_px));
        _ = app_theme.setMaterialVisible(showing);
        if (self.status_theme_view) |view| {
            try view.update(runtime.ui.theme, settings.registry.revision, runtime.config_revision);
            try view.flush();
        }
        var hash = std.hash.Wyhash.init(0);
        hash.update(record.id);
        std.hash.autoHash(&hash, record.ui_tokens);
        std.hash.autoHash(&hash, showing);
        std.hash.autoHash(&hash, .{ @as(u32, @bitCast(materials.background.transparency)), materials.blur_px });
        const fingerprint = hash.final();
        if (self.appearance_ui_hash != fingerprint) {
            app_theme.selectTokens(record.ui_tokens);
            self.appearance_theme.publish(self.cx, app_theme.widgetTheme(app_theme.currentName()));
            if (settings.open) settings.pending_rebuild = true;
            self.rethemeChrome();
            if (self.local_status_view) |view| view.retheme();
            if (self.transfer_host) |transfer| transfer.panel.retheme();
            if (self.transfer_host) |transfer| {
                if (transfer.manager_panel) |panel| panel.retheme();
                if (transfer.session_panel) |panel| panel.retheme();
                for (transfer.workspace.tabs.items) |tab| for (tab.transfer_trays) |tray| {
                    if (tray) |panel| panel.retheme();
                };
            }
            if (self.transfer_host) |transfer| if (transfer.conflict_view) |view| view.retheme() catch {};
            if (self.file_application) |files| files.retheme();
            self.local_status_hash = null;
            if (self.status_detail_view) |view| view.dirty = true;
            if (self.workspace) |workspace| {
                workspace.palette = ws.Palette.fromTheme();
                for (workspace.tabs.items) |tab| if (tab.terminal != null and !tab.local) {
                    tab.terminal.?.setThemeColors(app_theme.current().fg_1, app_theme.current().border, app_theme.current().accent);
                };
                try workspace.rebuildSidebar();
                try workspace.rebuildTabBar();
            }
            if (self.collapsed_sidebar) |collapsed| try collapsed.refresh();
            self.appearance_ui_hash = fingerprint;
        }
        const theme_revision = settings.appearance_state.theme_revision +| runtime.config_revision;
        if (self.workspace) |workspace| for (workspace.tabs.items) |tab| {
            if (tab.terminal == null) continue;
            if (tab.local and tab.terminal.?.root.behavior.events.on_drop == null) {
                tab.terminal.?.root.behavior.events.on_drop = ui.Cx.dropHandlerFrom(AppNavHost, self, localDropMarker);
                tab.terminal.?.root.markLayoutDirty();
            }
            tab.terminal.?.setTerminalTheme(.{ .revision = theme_revision, .cursor_shape = std.meta.stringToEnum(@FieldType(@import("vt/theme.zig").Theme, "cursor_shape"), runtime.ui.cursor_style) orelse .bar, .foreground = record.theme.fg, .background = record.theme.bg, .cursor = record.theme.cursor, .selection = record.theme.selection orelse record.ui_tokens.selection, .ansi = record.theme.ansi }) catch |err| {
                if (err != error.WorkerBusy) return err;
            };
        };
        if (self.background_view) |view| try view.update(image, materials, self.cx.viewport.width, self.cx.viewport.height);
        if (self.shell_root) |root| root.setBackground(ui.Color.TRANSPARENT);
        if (self.material_pane) |pane| {
            var background = shell_styles.pane(self.cx.tokens).background;
            // File pages own two sibling cards; their shared layout stays clear.
            if (self.workspace) |workspace| if (workspace.model.active) |active| {
                for (workspace.tabs.items) |tab| if (tab.tab_id == active and tab.terminal == null) {
                    background = ui.Color.TRANSPARENT;
                    break;
                };
            };
            pane.setStyleInline(self.allocator, .{ .background = background });
        }
        if (self.workspace) |workspace| for (workspace.tabs.items) |tab| {
            tab.root.setBackground(ui.Color.TRANSPARENT);
            if (tab.terminal) |*terminal| terminal.root.setBackground(ui.Color.TRANSPARENT);
        };
    }

    /// Retained plain nodes do not replay styles when the widget theme changes.
    /// Update only paint; keep draft input, focus, node IDs and shell geometry.
    fn rethemeChrome(self: *AppNavHost) void {
        const c = app_theme.current();
        if (self.settings) |settings| if (settings.header_title) |title| title.setTextColor(c.fg_1);
        if (self.settings) |settings| if (settings.header_icon) |icon| {
            _ = icon.setTint(c.accent);
        };
        if (self.settings) |settings| if (settings.search_input) |input| settings_content_view.styles.paintSearch(self.cx, &input);
        if (self.chrome.toolbar_tint) |tint| tint.set(c.fg_2);
        if (self.chrome.transfer_badge) |badge| badge.setBackground(c.ok);
        if (self.chrome.empty_title) |node| node.setTextColor(c.fg_1);
        if (self.chrome.empty_description) |node| node.setTextColor(c.fg_2);
        for (self.chrome.empty_actions, 0..) |entry, index| if (entry) |action| {
            const style = shell_styles.emptyButton(index == 0);
            action.style.set(style);
            action.node.setStyleInline(self.allocator, style);
        };
        if (self.chrome.sidebar_title) |node| node.setTextColor(c.fg_1);
        if (self.chrome.sidebar_search) |node| {
            node.setBackground(c.well);
            node.setBorderColor(c.well_border);
        }
        if (self.chrome.sidebar_search_icon) |node| node.setTextColor(c.fg_3);
        if (self.chrome.sidebar_search_input) |input| {
            input.state.tokens = self.cx.tokens;
            input.state.placeholder_color = c.fg_1;
            input.state.dirty = true;
            if (input.state.text_display_node) |node| node.setTextColor(c.fg_1);
            input.input_container.markRenderDirty();
        }
        if (self.chrome.sidebar_footer) |node| {
            node.setBackground(c.well);
            node.setBorderColor(c.border);
        }
        if (self.chrome.sidebar_footer_label) |node| node.setTextColor(c.fg_2);
        if (self.chrome.sidebar_empty_label) |node| node.setTextColor(c.fg_3);
        if (self.chrome.sidebar_empty_button) |node| node.setStyle(self.allocator, .gradient, .{ .from = c.action_accent, .to = c.action_accent_2, .direction = .diagonal });
    }

    fn showLocalStatusDetail(raw: *anyopaque, kind: @import("ui/status_controller.zig").Kind, trigger: *ui.Node) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const view = self.local_status_view orelse return;
        const detail = self.status_detail_view orelse return;
        const owner = view.currentOwner() orelse return;
        const workspace = self.workspace orelse return;
        const index = workspace.active_tab orelse return;
        if (index >= workspace.tabs.items.len or !workspace.tabs.items[index].content_owner.eql(.{ .session = owner })) return;
        detail.show(kind, trigger, view.root.globalRect().y, view.encoding_button.style.display == .none or view.grid_button.style.display == .none) catch |err| workspace.statusFailure(@errorName(err));
    }

    fn refreshLocalStatus(self: *AppNavHost, active: bool) !void {
        const view = self.local_status_view orelse return;
        const detail = self.status_detail_view orelse return;
        if (!active) {
            if (detail.controller.source) |source| detail.invalidate(source.value.owner);
            self.local_status_hash = null;
            return;
        }
        const workspace = self.workspace orelse return;
        const index = workspace.active_tab orelse return;
        if (index >= workspace.tabs.items.len) return;
        const tab = workspace.tabs.items[index];
        const owner = switch (tab.content_owner) {
            .session => |owner| owner,
            else => return,
        };
        const owner_changed = if (view.currentOwner()) |previous| !previous.eql(owner) else true;
        if (!owner_changed and self.cx.frame_time_ms - self.last_status_sample_ms < 300) return;
        self.last_status_sample_ms = self.cx.frame_time_ms;
        const host = self.application_host orelse return;
        const process = host.localProcess(tab.id) catch |err| switch (err) {
            error.WorkerBusy => if (owner_changed) null else return,
            else => null,
        };
        var cwd = host.localCwd(tab.id, self.allocator) catch |err| switch (err) {
            error.WorkerBusy => if (owner_changed) null else return,
            else => null,
        };
        defer if (cwd) |*value| value.deinit(self.allocator);
        const snapshot = host.terminalSnapshot(tab.id);
        const grid: ?@import("ui/local_status_view.zig").Grid = if (snapshot) |value| .{ .cols = value.projection.cols, .rows = value.projection.rows, .revision = value.geometry_revision } else null;
        const directory: ?[]const u8 = if (cwd) |value| value.value else null;
        const readonly = if (snapshot) |value| value.read_only else false;
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, owner);
        std.hash.autoHash(&hash, process);
        std.hash.autoHash(&hash, grid);
        std.hash.autoHash(&hash, readonly);
        if (directory) |value| hash.update(value);
        const fingerprint = hash.final();
        if (self.local_status_hash == fingerprint) return;
        if (self.local_status_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        self.local_status_revision += 1;
        const revision = self.local_status_revision;
        try view.update(.{ .owner = owner, .source_revision = revision, .process = process, .cwd = directory, .grid = grid, .encoding = if (snapshot != null) .utf8 else .unknown });
        try detail.update(.{ .owner = .{ .session = owner }, .owner_kind = .local, .source_revision = revision, .identity_label = "Local Terminal", .encoding = if (snapshot != null) .utf8 else .unknown, .grid = if (grid) |value| .{ .cols = value.cols, .rows = value.rows, .revision = value.revision } else null, .cwd = directory, .read_only = readonly });
        self.local_status_hash = fingerprint;
    }

    fn showLocalClose(raw: ?*anyopaque, session_id: ws.SessionId) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return));
        const workspace = self.workspace orelse return;
        const view = self.local_close_view orelse {
            workspace.resolveLocalCloseConfirmation(session_id, false);
            workspace.status("无法显示本地进程关闭确认");
            return;
        };
        var risk = if (self.application_host) |host| host.localCloseRisk(session_id, self.allocator) catch null else null;
        defer if (risk) |*snapshot| snapshot.deinit(self.allocator);
        view.show(session_id, if (risk) |*snapshot| snapshot else null) catch |err| {
            workspace.resolveLocalCloseConfirmation(session_id, false);
            workspace.statusFailure(@errorName(err));
        };
    }

    fn resolveLocalClose(raw: *anyopaque, session_id: ws.SessionId, accepted: bool) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const workspace = self.workspace orelse return;
        workspace.resolveLocalCloseConfirmation(session_id, accepted);
    }

    fn closeRisk(raw: ?*anyopaque, session_id: ws.SessionId) ws.CloseRisk {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return .{}));
        var risk: ws.CloseRisk = .{};
        if (self.transfer_host) |transfer| {
            const owner = if (self.application_host) |host| host.ownerForLegacy(session_id) else null;
            for (0..transfer.manager.count()) |index| {
                const progress = transfer.manager.progressAt(index).?;
                const original = TransferHost.jobOwner(transfer, progress.job);
                if (owner == null or original == null or !original.?.eql(owner.?)) continue;
                if (progress.job_cleanup != .released or (progress.state != .succeeded and progress.state != .failed and progress.state != .cancelled)) risk.transfer = true;
            }
        }
        if (self.socks_host) |socks| risk.socks = socks.hasLive(session_id);
        if (self.ai) |ai| if (self.application_host) |host| if (host.ownerForLegacy(session_id)) |owner| {
            risk.ai_write = ai.tool_bridge.writeRisk(owner);
        };
        return risk;
    }

    fn closeImpact(raw: ?*anyopaque, session_id: ws.SessionId) @import("ui/group_close_controller.zig").Impact {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return .{}));
        var result: @import("ui/group_close_controller.zig").Impact = .{};
        const owner = if (self.application_host) |host| host.ownerForLegacy(session_id) else null;
        var details: [512]u8 = undefined;
        var length: usize = 0;
        if (self.transfer_host) |transfer| {
            var hash = std.hash.Wyhash.init(0);
            var count: usize = 0;
            for (0..transfer.manager.count()) |index| {
                const progress = transfer.manager.progressAt(index).?;
                const original = TransferHost.jobOwner(transfer, progress.job);
                if (owner == null or original == null or !original.?.eql(owner.?)) continue;
                if (progress.job_cleanup == .released and (progress.state == .succeeded or progress.state == .failed or progress.state == .cancelled)) continue;
                std.hash.autoHash(&hash, progress.job);
                std.hash.autoHash(&hash, progress.attempt);
                std.hash.autoHash(&hash, progress.state);
                std.hash.autoHash(&hash, progress.job_cleanup);
                if (progress.job_cleanup == .unknown) result.unknown = 1;
                count += 1;
            }
            if (count != 0) {
                result.transfer = hash.final();
                const text = std.fmt.bufPrint(details[length..], "传输 {d} 项", .{count}) catch "";
                length += text.len;
            }
        }
        if (self.socks_host) |socks| {
            const snapshot = socks.closeImpact(session_id);
            result.socks = snapshot.socks;
            result.unknown |= snapshot.unknown;
            if (snapshot.detail_len != 0) {
                const text = std.fmt.bufPrint(details[length..], "{s}{s}", .{ if (length == 0) @as([]const u8, "") else "；", snapshot.detailText() }) catch "";
                length += text.len;
            }
        }
        if (self.ai) |ai| {
            if (owner) |original| {
                const snapshot = ai.tool_bridge.closeImpact(original);
                result.ai = snapshot.ai;
                result.unknown |= snapshot.unknown;
                if (snapshot.detail_len != 0) {
                    const text = std.fmt.bufPrint(details[length..], "{s}{s}", .{ if (length == 0) @as([]const u8, "") else "；", snapshot.detailText() }) catch "";
                    length += text.len;
                }
                for (ai.tool_results.records.items) |record| for (record.targets) |target| {
                    const source = target.source orelse continue;
                    if (!source.eql(original) or !target.result.remote_effect_unknown) continue;
                    var hash = std.hash.Wyhash.init(result.ai);
                    std.hash.autoHash(&hash, source);
                    std.hash.autoHash(&hash, record.turn_id);
                    hash.update(record.call_id);
                    result.ai = hash.final();
                    result.remote_effect_unknown = true;
                };
                if (result.remote_effect_unknown) {
                    const text = std.fmt.bufPrint(details[length..], "{s}远端执行结果待核实", .{if (length == 0) @as([]const u8, "") else "；"}) catch "";
                    length += text.len;
                }
            }
            if (ai.request_owner) |request| {
                const owns = switch (request) {
                    .session => |id| if (owner) |original| @backingInt(original.session_id) == id else false,
                    .group => |id| if (self.roster.findById(std.math.cast(u32, id) orelse 0)) |group| group.contains(session_id) else false,
                };
                if (owns and ai.thread_state.load(.acquire) == 1) {
                    var hash = std.hash.Wyhash.init(result.ai);
                    std.hash.autoHash(&hash, request);
                    std.hash.autoHash(&hash, ai.request_operation_id);
                    if (ai.request_text) |prompt| hash.update(prompt);
                    result.ai = hash.final();
                    const text = std.fmt.bufPrint(details[length..], "{s}AI 请求处理中", .{if (length == 0) @as([]const u8, "") else "；"}) catch "";
                    length += text.len;
                }
            }
        }
        result.setDetail(details[0..length]);
        return result;
    }

    fn closeStep(raw: *anyopaque, session_id: ws.SessionId, step: application_host_mod.CloseStep) application_host_mod.CloseReceipt {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        switch (step) {
            .pause_transfers => if (self.transfer_host) |transfer| {
                const owner = if (self.application_host) |host| host.ownerForLegacy(session_id) else null;
                if (owner) |original| return transfer.retainForClose(original) catch |err| {
                    applog.warn(.transfer, "retain original transfer: {s}", .{@errorName(err)});
                    return .unknown;
                };
            },
            .stop_ai => if (self.ai) |ai| {
                if (self.application_host) |host| if (host.ownerForLegacy(session_id)) |owner| {
                    if (ai.remote_picker) |picker| switch (picker.stopSource(owner)) {
                        .released => {},
                        .awaiting => return .awaiting,
                        .unknown => return .unknown,
                    };
                    const receipt = ai.tool_bridge.stopOwner(owner);
                    if (receipt != .released) return receipt;
                };
                if (ai.request_owner) |owner| switch (owner) {
                    .session => |id| if (ai.tabForSession(id) != null and ai.tabForSession(id).?.id == session_id and ai.thread_state.load(.acquire) == 1) {
                        ai.request_cancel.cancel();
                        return .awaiting;
                    },
                    .group => {},
                };
            },
            .release_forwards => if (self.socks_host) |socks| return socks.closeForSession(session_id),
            .release_content => {
                _ = self.roster.leavePane(session_id);
            },
            .close_protocol => {},
        }
        return .released;
    }

    fn cleanupSession(raw: ?*anyopaque, session_id: ws.SessionId) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return));
        _ = self.roster.leavePane(session_id);
        if (self.transfer_host) |transfer| if (transfer.session_id == session_id) {
            const owner = if (self.application_host) |host| host.ownerForLegacy(session_id) else null;
            for (0..transfer.manager.count()) |index| {
                const progress = transfer.manager.progressAt(index).?;
                const original = TransferHost.jobOwner(transfer, progress.job);
                if (owner == null or original == null or !original.?.eql(owner.?)) continue;
                if (progress.state == .running or progress.state == .queued or progress.state == .retry_wait) transfer.manager.pause(progress.job) catch {};
            }
        };
        if (self.socks_host) |socks| _ = socks.stopForSession(session_id);
    }

    fn collapsedNew(ctx: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(ctx));
        if (self.wizard) |wizard| wizard.show();
    }

    fn collapsedHostAction(ctx: *anyopaque, owner: @import("host/identity.zig").AssetOwner, action: @import("ui/sidebar_collapsed_view.zig").HostAction) void {
        const self: *AppNavHost = @ptrCast(@alignCast(ctx));
        const workspace = self.workspace orelse return;
        _ = workspace.registry.get(owner) catch {
            workspace.status("主机配置已变化，请重新打开详情");
            return;
        };
        const index = workspace.registry.indexOf(owner.id) orelse return;
        switch (action) {
            .connect => workspace.newSession(index) catch |err| workspace.statusFailure(@errorName(err)),
            .edit => {
                const menu = self.menu_host orelse return;
                menu.hide();
                menu.context_host = index;
                menu.captured_host = workspace.hostId(index);
                menu.captured_asset = owner;
                menu.context_tab = null;
                menu.captured_tab = null;
                menu.captured_owner = null;
                menu.runCapturedAction(.edit_host);
            },
        }
    }

    fn collapsedExpand(ctx: *anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(ctx));
        self.toggleSidebar();
    }

    fn broadcastFacts(self: *AppNavHost, group_id: u32) ![]@import("ui/broadcast_controller.zig").Fact {
        const BC = @import("ui/broadcast_controller.zig");
        var facts: std.ArrayList(BC.Fact) = .empty;
        errdefer facts.deinit(self.allocator);
        const group = self.roster.findById(group_id) orelse return error.UnknownGroup;
        const workspace = self.workspace orelse return error.NoWorkspace;
        for (group.members.items) |member| for (workspace.tabs.items) |tab| {
            if (tab.id != member.pane_id or tab.terminal == null) continue;
            const view = &tab.terminal.?;
            const application = self.application_host orelse continue;
            if (view.terminal_surface == null) {
                const runtime = tab.runtime orelse continue;
                const owner = application.ownerForLegacy(tab.id) orelse continue;
                const capabilities = (application.sessions.capabilitySnapshot(owner) catch continue) orelse continue;
                var projection = runtime.copyProjection(self.allocator) catch continue;
                defer projection.deinit(self.allocator);
                try facts.append(self.allocator, .{ .handle = owner, .membership_revision = member.membership_revision, .writable = member.active and !tab.closing and !tab.failed and runtime.isConnected() and runtime.isAttached() and view.history.selected == null and @import("host/actions.zig").project(.toggle_broadcast, capabilities).enabled, .capability_revision = capabilities.revision, .mode_revision = projection.mode_revision });
                continue;
            }
            const surface = view.terminal_surface.?;
            // Use the owned displayed snapshot for source facts. A transient
            // worker lock during accepted input must not erase the source;
            // recipient submission still validates live owner/mode/writability.
            const snapshot = surface.snapshot orelse continue;
            if (!snapshot.owner.eql(surface.owner)) continue;
            const capabilities = (application.sessions.capabilitySnapshot(snapshot.owner) catch continue) orelse continue;
            try facts.append(self.allocator, .{ .handle = snapshot.owner, .membership_revision = member.membership_revision, .writable = member.active and !snapshot.read_only and !tab.closing and view.history.selected == null and @import("host/actions.zig").project(.toggle_broadcast, capabilities).enabled, .capability_revision = capabilities.revision, .mode_revision = snapshot.projection.mode_revision, .input_revision = snapshot.input_revision });
        };
        return facts.toOwnedSlice(self.allocator);
    }

    fn refreshBroadcastStatus(self: *AppNavHost, controls: *@import("ui/ssh_status_host.zig").Controls) void {
        const workspace = self.workspace orelse return;
        for (workspace.tabs.items) |tab| {
            var enabled = false;
            if (self.application_host) |application| if (application.ownerForLegacy(tab.id)) |handle| {
                for (self.broadcasts.items) |approval| if (approval.enabled and approval.source.handle.eql(handle)) {
                    enabled = true;
                    break;
                };
            };
            workspace.setGroupMemberBroadcast(tab.id, enabled);
        }
        const group_id = workspace.active_group_view;
        controls.broadcast_button.setDisplay(if (group_id != null) .flex else .none);
        controls.broadcast_button.behavior.events.on_click = .{ .context = self, .callback = openBroadcastStatus };
        var participants: usize = 0;
        var running = false;
        if (group_id) |id| if (self.broadcastFor(id)) |approval| if (approval.enabled) {
            running = true;
            const facts = self.broadcastFacts(id) catch return;
            defer self.allocator.free(facts);
            if (@import("ui/broadcast_controller.zig").Approval.valid(approval.source, facts)) participants += 1;
            for (approval.targets) |target| if (target.selected and @import("ui/broadcast_controller.zig").Approval.valid(target.fact, facts)) {
                participants += 1;
            };
        };
        var buffer: [64]u8 = undefined;
        const wide = self.cx.viewport.width >= 1000;
        const label = if (wide) (if (running) std.fmt.bufPrint(&buffer, "广播 · {d}", .{participants}) catch "广播" else "广播") else if (running) std.fmt.bufPrint(&buffer, "{d}", .{participants}) catch "" else "";
        if (!std.mem.eql(u8, controls.broadcast_label.getText().?.content, label)) {
            controls.broadcast_label.setTextContent(self.allocator, label) catch {};
            controls.broadcast_style.set(@import("ui/status_connection_styles.zig").metricTrigger(if (wide) 86 else if (running) 48 else 28));
            controls.broadcast_label.setStyleInline(self.allocator, @import("ui/status_connection_styles.zig").metricLabel(if (wide) 86 else 48));
        }
        controls.broadcast_label.setDisplay(if (label.len == 0) .none else .flex);
        _ = controls.broadcast_icon.setTint(if (running) app_theme.current().accent else app_theme.current().fg_2);
        const label_color = if (running) app_theme.current().accent else app_theme.current().fg_2;
        if (!std.meta.eql(controls.broadcast_label.getText().?.color, label_color)) controls.broadcast_label.setTextColor(label_color);
        controls.broadcast_button.behavior.interaction.a11y.?.label = if (running) "组广播 · 已开启 · 查看参与终端" else "组广播 · 已关闭";
    }
    fn openBroadcastStatus(raw: ?*anyopaque) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return));
        const workspace = self.workspace orelse return;
        const group = workspace.active_group_view orelse return;
        const index = workspace.active_tab orelse return;
        if (index >= workspace.tabs.items.len) return;
        self.requestBroadcast(group, workspace.tabs.items[index].id);
    }

    fn broadcastFor(self: *AppNavHost, id: u32) ?*@import("ui/broadcast_controller.zig").Approval {
        for (self.broadcasts.items) |*approval| if (approval.group_id == id) return approval;
        return null;
    }

    pub fn requestBroadcast(self: *AppNavHost, group_id: u32, source_id: u64) void {
        const workspace = self.workspace orelse return;
        const group = self.roster.findById(group_id) orelse return;
        const facts = self.broadcastFacts(group_id) catch |err| {
            workspace.statusFailure(@errorName(err));
            return;
        };
        defer self.allocator.free(facts);
        if (self.broadcastFor(group_id)) |old| {
            if (old.enabled) {
                self.showBroadcast(old, facts);
                return;
            }
            old.deinit(self.allocator);
            for (self.broadcasts.items, 0..) |item, index| if (item.group_id == group_id) {
                _ = self.broadcasts.orderedRemove(index);
                break;
            };
        }
        var source: ?@import("ui/broadcast_controller.zig").Fact = null;
        for (facts) |fact| if (self.application_host != null and self.application_host.?.legacyForHandle(fact.handle) == source_id) {
            source = fact;
            break;
        };
        const approval = @import("ui/broadcast_controller.zig").prepare(self.allocator, group_id, group.membership_revision, source orelse {
            workspace.status("请选择在线可写的来源终端");
            return;
        }, facts) catch |err| {
            workspace.statusFailure(@errorName(err));
            return;
        };
        self.broadcasts.append(self.allocator, approval) catch {
            var owned = approval;
            owned.deinit(self.allocator);
            return;
        };
        self.showBroadcast(self.broadcastFor(group_id).?, facts);
    }

    fn toggleMemberBroadcast(self: *AppNavHost, group_id: u32, source_id: u64) void {
        const workspace = self.workspace orelse return;
        const application = self.application_host orelse return;
        const handle = application.ownerForLegacy(source_id) orelse return;
        if (self.broadcastFor(group_id)) |old| {
            const stop_only = old.enabled and old.source.handle.eql(handle);
            self.stopBroadcast(group_id);
            if (stop_only) return;
        }
        const group = self.roster.findById(group_id) orelse return;
        const facts = self.broadcastFacts(group_id) catch return;
        defer self.allocator.free(facts);
        const BC = @import("ui/broadcast_controller.zig");
        const source = for (facts) |fact| {
            if (fact.handle.eql(handle)) break fact;
        } else return;
        var approval = BC.prepare(self.allocator, group_id, group.membership_revision, source, facts) catch |err| {
            workspace.statusFailure(@errorName(err));
            return;
        };
        approval.approve(group.membership_revision, facts) catch |err| {
            approval.deinit(self.allocator);
            workspace.status(if (err == error.NoRecipients) "没有在线可写的接收终端" else "连接未就绪");
            return;
        };
        self.broadcasts.append(self.allocator, approval) catch {
            approval.deinit(self.allocator);
            return;
        };
        if (workspace.sessionTab(source_id)) |tab| if (tab.terminal) |*view| {
            view.local_state.broadcast = true;
        };
        self.broadcast_epoch +|= 1;
        self.cx.requestRedraw();
    }

    fn showBroadcast(self: *AppNavHost, approval: *@import("ui/broadcast_controller.zig").Approval, facts: []const @import("ui/broadcast_controller.zig").Fact) void {
        const workspace = self.workspace orelse return;
        const application = self.application_host orelse return;
        const group = self.roster.findById(approval.group_id) orelse return;
        const details = self.connection_details_host orelse return;
        const controls = details.ssh_status.controls orelse return;
        const BV = @import("ui/broadcast_view.zig");
        const BC = @import("ui/broadcast_controller.zig");
        if (self.broadcast_view == null) self.broadcast_view = BV.View.mount(self.cx, workspace.scope, .{ .context = self, .resolve = resolveBroadcast, .select = selectBroadcastMember }) catch return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var members: std.ArrayList(BV.Member) = .empty;
        for (group.members.items) |member| {
            const tab = workspace.sessionTab(member.pane_id) orelse continue;
            const owner = application.ownerForLegacy(tab.id);
            const source = if (owner) |handle| approval.source.handle.eql(handle) else false;
            var selected = source;
            var available = source and BC.Approval.valid(approval.source, facts);
            if (owner) |handle| for (approval.targets) |target| if (target.fact.handle.eql(handle)) {
                selected = target.selected;
                available = BC.Approval.valid(target.fact, facts);
                break;
            };
            var live_writable = false;
            if (owner) |handle| for (facts) |fact| if (fact.handle.eql(handle)) {
                live_writable = fact.writable;
                break;
            };
            const unavailable_reason = if (owner == null) "无终端" else if (live_writable) "需重新开启" else "不可写";
            const endpoint = if (tab.local) "本机 · zsh" else if (tab.host_snapshot) |host| std.fmt.allocPrint(allocator, "{s}@{s}:{d}", .{ host.value.user, host.value.host, host.value.port }) catch return else "无终端服务";
            members.append(allocator, .{ .id = tab.id, .owner = owner, .name = std.fmt.allocPrint(allocator, "{s} · #{d}", .{ tab.titleSlice(), tab.id }) catch return, .endpoint = endpoint, .source = source, .selected = selected, .available = available, .unavailable_reason = unavailable_reason }) catch return;
        }
        self.broadcast_view.?.show(.{ .group = approval.group_id, .name = group.name, .running = approval.enabled, .can_enable = BC.Approval.valid(approval.source, facts) and approval.effective(facts) > 0, .members = members.items }, controls.broadcast_button) catch {};
    }

    fn selectBroadcastMember(raw: *anyopaque, group_id: u32, owner: @import("host/identity.zig").SessionHandle, selected: bool) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const approval = self.broadcastFor(group_id) orelse return;
        const facts = self.broadcastFacts(group_id) catch return;
        defer self.allocator.free(facts);
        approval.select(owner, selected, facts) catch |err| {
            if (self.workspace) |workspace| workspace.statusFailure(@errorName(err));
            self.showBroadcast(approval, facts);
            return;
        };
        if (approval.enabled and approval.effective(facts) == 0) {
            // Explicit deselection of the last recipient stops delivery. A disconnected
            // recipient alone still preserves the existing zero-effective-target contract.
            approval.enabled = false;
            if (self.application_host) |application| if (application.legacyForHandle(approval.source.handle)) |id| {
                if (self.workspace.?.sessionTab(id)) |tab| if (tab.terminal) |*view| {
                    view.local_state.broadcast = false;
                };
            };
        }
        self.broadcast_epoch +|= 1;
        self.showBroadcast(approval, facts);
    }

    fn resolveBroadcast(raw: *anyopaque, group_id: u32, accepted: bool) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw));
        const approval = self.broadcastFor(group_id) orelse return;
        if (approval.enabled) {
            if (accepted) self.stopBroadcast(group_id);
            return;
        }
        if (!accepted) {
            self.stopBroadcast(group_id);
            return;
        }
        const group = self.roster.findById(group_id) orelse return;
        const facts = self.broadcastFacts(group_id) catch return;
        defer self.allocator.free(facts);
        approval.approve(group.membership_revision, facts) catch |err| {
            if (self.workspace) |workspace| workspace.statusFailure(@errorName(err));
            return;
        };
        if (self.application_host) |application| if (application.legacyForHandle(approval.source.handle)) |id| {
            if (self.workspace.?.sessionTab(id)) |tab| if (tab.terminal) |*view| {
                view.local_state.broadcast = true;
            };
        };
        self.broadcast_epoch +|= 1;
        self.showBroadcast(approval, facts);
    }

    pub fn stopBroadcast(self: *AppNavHost, group_id: u32) void {
        for (self.broadcasts.items, 0..) |*approval, index| if (approval.group_id == group_id) {
            if (self.application_host) |application| if (application.legacyForHandle(approval.source.handle)) |id| {
                if (self.workspace.?.sessionTab(id)) |tab| if (tab.terminal) |*view| {
                    view.local_state.broadcast = false;
                };
            };
            approval.deinit(self.allocator);
            _ = self.broadcasts.orderedRemove(index);
            self.broadcast_epoch +|= 1;
            break;
        };
        if (self.broadcast_view) |view| if (view.group_id == group_id) view.dismiss();
        self.cx.requestRedraw();
    }

    fn onServiceBroadcast(raw: ?*anyopaque, source: @import("host/identity.zig").SessionHandle, event: u64, payload: @import("ui/broadcast_event.zig").Payload) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return));
        var context = BroadcastSend{ .host = self, .payload = payload };
        defer context.seen.deinit(self.allocator);
        for (self.broadcasts.items) |*approval| {
            if (!approval.enabled or !approval.source.handle.eql(source)) continue;
            const facts = self.broadcastFacts(approval.group_id) catch continue;
            defer self.allocator.free(facts);
            approval.dispatch(approval.source, event, facts, &context, BroadcastSend.send) catch |err| {
                if (self.workspace) |workspace| workspace.status(switch (err) {
                    error.StaleSource => "广播输入未发送：来源会话状态已变化，请重新执行 @sync on 确认。",
                    error.DisconnectedTerminal, error.EndedSession => "广播输入未发送：接收会话已断开。",
                    error.PendingPaste => "广播输入未发送：接收会话有待确认的粘贴，请先处理。",
                    else => @errorName(err),
                });
            };
            if (self.broadcast_view) |view| if (view.group_id == approval.group_id and view.open.get()) self.showBroadcast(approval, facts);
        }
    }

    const BroadcastSend = struct {
        host: *AppNavHost,
        payload: @import("ui/broadcast_event.zig").Payload,
        seen: std.ArrayList(@import("host/identity.zig").SessionHandle) = .empty,
        fn send(raw: *anyopaque, handle: @import("host/identity.zig").SessionHandle) !void {
            const self: *BroadcastSend = @ptrCast(@alignCast(raw));
            for (self.seen.items) |previous| if (previous.eql(handle)) return;
            try self.seen.append(self.host.allocator, handle);
            const workspace = self.host.workspace orelse return error.NoWorkspace;
            const application = self.host.application_host orelse return error.UnsupportedService;
            const capabilities = (try application.sessions.capabilitySnapshot(handle)) orelse return error.StaleOwner;
            if (!@import("host/actions.zig").project(.toggle_broadcast, capabilities).enabled) return error.CapabilityUnavailable;
            for (workspace.tabs.items) |tab| {
                if (application.legacyForHandle(handle) != tab.id or tab.terminal == null) continue;
                if (tab.terminal.?.terminal_surface == null) {
                    const view = &tab.terminal.?;
                    const runtime = tab.runtime orelse return error.EndedSession;
                    const bytes = switch (self.payload) {
                        .bytes => |value| try self.host.allocator.dupe(u8, value),
                        .key => |key| try runtime.encodeKey(key, self.host.allocator),
                        .paste => |value| blk: {
                            var projection = try runtime.copyProjection(self.host.allocator);
                            defer projection.deinit(self.host.allocator);
                            break :blk if (projection.modes.bracketed_paste) try std.mem.concat(self.host.allocator, u8, &.{ "\x1b[200~", value, "\x1b[201~" }) else try self.host.allocator.dupe(u8, value);
                        },
                    };
                    defer self.host.allocator.free(bytes);
                    try view.receiveBroadcast(bytes);
                    return;
                }
                const surface = tab.terminal.?.terminal_surface.?;
                if (!surface.owner.eql(handle) or tab.terminal.?.history.selected != null) return error.StaleOwner;
                if (surface.pending_paste != null or surface.paste_requested != null or surface.pending.items.len > 0) return error.PendingPaste;
                const status = try surface.service.status();
                if (!status.writable or !status.owner.eql(handle)) return error.ReadOnlyTerminal;
                const sequence = surface.next_input;
                // Reserve the sequence before submission so no accepted target is repeated.
                surface.next_input = try std.math.add(u64, surface.next_input, 1);
                switch (self.payload) {
                    .bytes => |bytes| {
                        _ = try surface.service.write(.{ .input_sequence = sequence, .mode_revision = status.mode_revision, .bytes = bytes });
                    },
                    .key => |key| {
                        _ = try surface.service.writeKey(.{ .input_sequence = sequence, .mode_revision = status.mode_revision, .event = key });
                    },
                    .paste => |text| {
                        var paste = try surface.service.preparePaste(self.host.allocator, text);
                        defer paste.deinit(self.host.allocator);
                        _ = try surface.service.commitPaste(paste, sequence, true);
                    },
                }
                return;
            }
            return error.EndedSession;
        }
    };

    fn broadcastPasteStamp(raw: ?*anyopaque, source: @import("host/identity.zig").SessionHandle) u64 {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return 0));
        var hash = std.hash.Wyhash.init(self.broadcast_epoch);
        var found = false;
        for (self.broadcasts.items) |approval| {
            if (!approval.enabled or !approval.source.handle.eql(source)) continue;
            found = true;
            const group = self.roster.findById(approval.group_id) orelse return 1;
            std.hash.autoHash(&hash, group.membership_revision);
            const facts = self.broadcastFacts(approval.group_id) catch return 1;
            defer self.allocator.free(facts);
            for (facts) |fact| {
                std.hash.autoHash(&hash, fact);
            }
        }
        return if (found) hash.final() else 0;
    }

    fn onTerminalInput(raw: ?*anyopaque, source: *TerminalViewNode, bytes: []const u8) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return));
        const workspace = self.workspace orelse return;
        const application = self.application_host orelse return;
        for (workspace.tabs.items) |tab| {
            if (tab.terminal == null or &tab.terminal.? != source) continue;
            const owner = application.ownerForLegacy(tab.id) orelse return;
            source.broadcast_event = std.math.add(u64, source.broadcast_event, 1) catch return;
            onServiceBroadcast(raw, owner, source.broadcast_event, .{ .bytes = bytes });
            return;
        }
    }

    fn bindGroupWorkspace(self: *AppNavHost, workspace: *ws.Workspace) void {
        workspace.group_roster = &self.roster;
        workspace.group_action_context = self;
        workspace.group_action = groupWorkspaceAction;
    }

    fn groupWorkspaceAction(raw: ?*anyopaque, group_id: u32, session_id: u64, action: ws.GroupAction) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return));
        const workspace = self.workspace orelse return;
        if (action == .stop_broadcast) {
            self.stopBroadcast(group_id);
            return;
        }
        if (action == .stop_group_ai) {
            if (self.ai) |ai| {
                if (ai.request_owner) |owner| if (owner == .group and owner.group == group_id) ai.request_cancel.cancel();
                _ = ai.tool_bridge.stopGroup(group_id);
                ai.cx.requestRedraw();
            }
            return;
        }
        if (workspace.groupClosing(group_id)) {
            workspace.status("组正在关闭，暂不能修改成员");
            return;
        }
        const group = self.roster.findById(group_id) orelse return;
        switch (action) {
            .pin => {
                self.roster.pin(group.name, if (group.pinned_pane == session_id) null else session_id) catch |err| {
                    workspace.statusFailure(@errorName(err));
                    return;
                };
                workspace.refreshGroup(group_id);
            },
            .leave => {
                self.roster.leave(group.name, session_id) catch |err| {
                    workspace.statusFailure(@errorName(err));
                    return;
                };
                workspace.refreshGroup(group_id);
            },
            .close_member => if (workspace.tabIndex(session_id)) |index| workspace.requestCloseTab(index),
            .broadcast => self.requestBroadcast(group_id, session_id),
            .toggle_broadcast => self.toggleMemberBroadcast(group_id, session_id),
            .split_side, .split_stack => {
                if (workspace.tabIndex(session_id)) |index| workspace.active_tab = index;
                workspace.splitGroup(&self.roster, action == .split_stack) catch |err| workspace.statusFailure(@errorName(err));
            },
            .stop_broadcast, .stop_group_ai => unreachable,
        }
    }

    fn finishOwnedCommand(self: *AppNavHost, owner: @import("host/identity.zig").SessionHandle, id: u64, state: TerminalViewNode.CommandRecordState, text: []const u8) void {
        const workspace = self.workspace orelse return;
        for (workspace.tabs.items) |tab| {
            if (tab.terminal) |*terminal| if (terminal.commandRecordOwner()) |current| {
                if (current.eql(owner)) {
                    _ = terminal.finishCommandRecord(owner, id, state, text);
                    return;
                }
            };
        }
    }
    fn pollCommandCreations(self: *AppNavHost) void {
        const application = self.application_host orelse return;
        var i: usize = 0;
        while (i < self.pending_command_creations.items.len) {
            const pending = &self.pending_command_creations.items[i];
            const snapshot = application.sessions.queryState(pending.created);
            if (snapshot) |state| switch (state.lifecycle) {
                .creating, .ready => {
                    i += 1;
                    continue;
                },
                .attached => self.finishOwnedCommand(pending.source, pending.command_id, .success, "新会话已连接"),
                else => {
                    const failure = for (application.mappings.items) |*mapping| {
                        if (mapping.handle.eql(pending.created) and mapping.failure_len > 0) break mapping.failure[0..mapping.failure_len];
                    } else "新会话未建立，连接详情保留在目标页签";
                    self.finishOwnedCommand(pending.source, pending.command_id, .failure, failure);
                },
            } else self.finishOwnedCommand(pending.source, pending.command_id, .failure, "新会话已失效");
            _ = self.pending_command_creations.orderedRemove(i);
        }
    }
    fn onLocalCommandFrom(raw: ?*anyopaque, origin: *TerminalViewNode, text: []const u8, executed: bool) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return));
        const workspace = self.workspace orelse return;
        const application = self.application_host orelse return;
        const owner = origin.commandRecordOwner();
        const command_id = origin.active_command_record;
        const parsed = @import("ui/builtin_commands.zig").parse(text);
        const creates = switch (parsed) {
            .new_session, .duplicate => true,
            else => false,
        };
        if (creates and owner != null and command_id != null) self.pending_command_creations.ensureUnusedCapacity(self.allocator, 1) catch {
            _ = origin.finishCommandRecord(owner.?, command_id.?, .failure, "无法记录新会话结果");
            return;
        };
        for (workspace.tabs.items, 0..) |tab, index| {
            if (tab.terminal == null or &tab.terminal.? != origin or tab.closing) continue;
            workspace.active_tab = index;
            const before = application.sessions.sessions.items.len;
            workspace.command_output = origin;
            defer workspace.command_output = null;
            onLocalCommand(raw, text, executed);
            if (!executed) return;
            if (parsed == .upload or parsed == .download) return;
            if (owner) |source| if (command_id) |id| {
                if (creates and application.sessions.sessions.items.len > before) {
                    const created = application.sessions.sessions.items[before].handle;
                    self.pending_command_creations.appendAssumeCapacity(.{ .source = source, .command_id = id, .created = created });
                    self.finishOwnedCommand(source, id, .pending, "正在建立新会话…");
                } else {
                    self.finishOwnedCommand(source, id, .success, switch (parsed) {
                        .help => "已打开内置指令帮助",
                        .ai => "已打开 AI 助手",
                        .group => "已加入终端组",
                        .pin => "已更新组内置顶状态",
                        .sync => "已更新组广播请求",
                        .theme => |name| if (name == null) "已打开主题选择器" else "已应用主题选择",
                        .socks => "已提交 SOCKS5 转发请求",
                        else => "内置指令已执行",
                    });
                }
            };
            return;
        }
    }
    fn commandSuccess(self: *AppNavHost, text: []const u8) void {
        const workspace = self.workspace orelse return;
        if (workspace.command_output) |terminal| {
            if (terminal.commandRecordOwner()) |owner| if (terminal.active_command_record) |id| {
                _ = terminal.finishCommandRecord(owner, id, .success, text);
                return;
            };
        }
        workspace.status(text);
    }
    fn onLocalCommand(raw: ?*anyopaque, text: []const u8, executed: bool) void {
        const self: *AppNavHost = @ptrCast(@alignCast(raw orelse return));
        if (!executed) return;
        const workspace = self.workspace orelse return;
        const active = workspace.active_tab orelse return;
        if (active >= workspace.tabs.items.len) return;
        switch (@import("ui/builtin_commands.zig").parse(text)) {
            .new_session => workspace.newSessionFromTab(active) catch |err| workspace.statusFailure(@errorName(err)),
            .help => {
                if (workspace.command_output != null) {
                    var buffer: [4096]u8 = undefined;
                    const help = @import("ui/builtin_dispatch.zig").formatHelp(self.allocator, &buffer) catch |err| {
                        workspace.statusFailure(@errorName(err));
                        return;
                    };
                    self.commandSuccess(help);
                } else if (self.help_overlay) |help| help.setDisplay(.flex) else workspace.status("内置指令帮助暂不可用");
            },
            .ai => |question| if (self.ai) |ai| {
                ai.syncOwner() catch |err| {
                    workspace.statusFailure(@errorName(err));
                    return;
                };
                if (!ai.controller.model.visible) ai.toggle();
                ai.dock.pin();
                if (question.len > 0) {
                    const previous = ai.prompt.peek();
                    const draft = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ previous, if (previous.len == 0) "" else "\n", question }) catch {
                        workspace.status("无法保留 AI 问题草稿");
                        return;
                    };
                    defer self.allocator.free(draft);
                    ai.prompt.set(draft);
                    ai.promptChanged(ai.prompt.peek());
                }
                if (ai.input_node) |input| self.cx.setFocus(input);
            } else workspace.status("AI 运维助手暂不可用"),
            .upload => |source| if (self.transfer_host) |transfer| {
                transfer.requestCommandTransfer(active, .upload, source) catch |err| workspace.status(@errorName(err));
            } else workspace.status("传输面板暂不可用"),
            .download => |download| if (self.transfer_host) |transfer| {
                transfer.requestCommandTransfer(active, .download, download.remote_path) catch |err| workspace.status(@errorName(err));
            } else workspace.status("传输面板暂不可用"),
            .group => |name| {
                if (name.len == 0) {
                    workspace.status("@grp 需要组名");
                    return;
                }
                const pane_id: ws.SessionId = workspace.tabs.items[active].id;
                self.bindGroupWorkspace(workspace);
                if (workspace.active_group_view) |id| if (workspace.groupClosing(id)) {
                    workspace.status("组正在关闭，暂不能修改成员");
                    return;
                };
                if (std.ascii.eqlIgnoreCase(name, "off") or std.ascii.eqlIgnoreCase(name, "leave")) {
                    const old_group = workspace.active_group_view;
                    const removed = self.roster.leavePane(pane_id);
                    if (old_group) |id| workspace.refreshGroup(id);
                    workspace.selectTab(active);
                    self.commandSuccess(if (removed) "已退出终端组" else "当前未加入该组");
                } else {
                    if (self.roster.find(name)) |existing| if (workspace.groupClosing(existing.id)) {
                        workspace.status("组正在关闭，暂不能修改成员");
                        return;
                    };
                    const joined = self.roster.join(name, pane_id, 0xff1351f6) catch {
                        workspace.statusFailure("加入终端组失败");
                        return;
                    };
                    workspace.openGroup(&self.roster, joined.id) catch |err| workspace.statusFailure(@errorName(err));
                }
            },
            .duplicate => workspace.duplicateSessionFromTab(active) catch |err| workspace.statusFailure(@errorName(err)),
            .pin => {
                // Pin only changes member presentation order.
                const pane_id: ws.SessionId = workspace.tabs.items[active].id;
                var found = false;
                var names: [64][]const u8 = undefined;
                var name_count: usize = 0;
                for (self.roster.groups.items) |group| {
                    if (!group.contains(pane_id)) continue;
                    if (name_count == names.len) break;
                    names[name_count] = group.name;
                    name_count += 1;
                }
                for (names[0..name_count]) |name| {
                    const group = self.roster.find(name) orelse continue;
                    const next: ?u64 = if (group.pinned_pane == pane_id) null else pane_id;
                    self.roster.pin(name, next) catch |err| {
                        workspace.statusFailure(@errorName(err));
                        continue;
                    };
                    workspace.refreshGroup(group.id);
                    found = true;
                }
                if (!found) workspace.status("当前会话未加入终端组") else self.commandSuccess(if (name_count > 0 and (self.roster.find(names[0]).?.pinned_pane == pane_id)) "已置顶当前会话" else "已取消会话置顶");
            },
            .socks => |request| if (self.socks_host) |socks| {
                const original = workspace.tabs.items[active].id;
                if (request.enabled) {
                    if (!socks.hasLive(original)) socks.commandToggle(request.port);
                } else if (socks.hasLive(original)) {
                    _ = socks.stopForSession(original);
                } else {
                    self.commandSuccess("SOCKS5 转发当前已停止");
                }
            } else workspace.status("SOCKS5 转发暂不可用"),
            .literal => |literal| if (workspace.tabs.items[active].terminal) |*terminal| {
                _ = terminal.pushText(literal);
            },
            // These commands are applied inside TerminalViewNode before the
            // workspace observer is normally called. Keep explicit cases so
            // the observer remains exhaustive if a caller routes one here.
            .sync => |enabled| {
                const source_id = workspace.tabs.items[active].id;
                var found = false;
                for (self.roster.groups.items) |group| if (group.contains(source_id)) {
                    found = true;
                    if (enabled) self.requestBroadcast(group.id, source_id) else self.stopBroadcast(group.id);
                    break;
                };
                if (!found) workspace.status("请先加入终端组");
            },
            .theme => |name| {
                if (name) |id| {
                    const settings = self.settings orelse {
                        workspace.status("@theme：主题设置暂不可用");
                        return;
                    };
                    const target = if (std.mem.eql(u8, id, "default")) "dark" else id;
                    if (settings.registry.get(target) == null) {
                        workspace.status("@theme：主题名称不存在。执行 @theme 打开主题选择器。");
                        return;
                    }
                    selectGlobalTheme(self, target) catch |err| workspace.statusFailure(@errorName(err));
                } else showThemeFromMenu(self);
            },
            .timestamp, .log => {},
            .invalid => |invalid| workspace.status(switch (invalid.reason) {
                .missing_parameter => "命令缺少必要参数",
                .unexpected_parameter => "命令参数不符合设计格式",
                .invalid_switch => "命令开关只支持 on/off",
                .invalid_port => "端口参数无效",
                .invalid_path => "路径参数无效",
            }),
            .not_command => workspace.status("未知本地命令，未发送到远端"),
        }
        self.cx.requestRedraw();
    }
};

// ── Click contexts for plain-node interactive elements ──────────────

const NavClick = struct {
    host: *AppNavHost,
    kind: enum { sidebar, quick_connect, wizard, transfer, session_menu },
};

fn onNavClick(raw: *anyopaque) void {
    const ctx: *NavClick = @ptrCast(@alignCast(raw));
    switch (ctx.kind) {
        .session_menu => ctx.host.showSessionMenu(),
        .sidebar => ctx.host.toggleSidebar(),
        .quick_connect => ctx.host.toggleQuickConnect(),
        .wizard => if (ctx.host.wizard) |wiz| wiz.show(),
        .transfer => if (ctx.host.transfer_host) |th| th.toggleManager(),
    }
}

/// Quick Connect (⌘K) host: live filter over the saved hosts registry with
/// keyboard/click connect, mirroring docs/SPEC/mockups/mockup-quickconnect.
/// The panel content is rebuilt from workspace.registry data on every query
/// change — no static mock rows.
const QuickConnectHost = struct {
    const QuickView = @import("ui/quick_connect_view.zig");
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    workspace: *ws.Workspace,
    view: *QuickView.View = undefined,
    nav: ?*AppNavHost = null,
    painted_revision: ?u64 = null,

    fn refreshAssets(self: *QuickConnectHost) !void {
        const revision = self.workspace.registry.revision;
        if (self.painted_revision == revision) return;
        var assets: std.ArrayList(QuickView.SavedAsset) = .empty;
        defer assets.deinit(self.allocator);
        for (self.workspace.registry.hosts) |host| {
            if (@backingInt(host.connection_id) == 0) continue;
            try assets.append(self.allocator, .{ .owner = host.owner(), .name = host.name, .host = host.host, .user = host.user, .port = host.port, .group = host.group, .hops = host.jump_chain.len, .protocol = host.protocol, .os = @import("ui/session_os_cache.zig").load(self.allocator, self.workspace.io, self.workspace.hosts_path, host) });
        }
        // Recency only reorders real saved identities; never fabricate fallback recent rows.
        var ordered: std.ArrayList(QuickView.SavedAsset) = .empty;
        defer ordered.deinit(self.allocator);
        for (0..self.workspace.recent_connections.len) |rank| {
            const owner = self.workspace.recent_connections.resolve(rank, &self.workspace.registry) orelse continue;
            for (assets.items) |entry| if (entry.owner.id == owner.id) {
                try ordered.append(self.allocator, entry);
                break;
            };
        }
        for (assets.items) |entry| {
            var present = false;
            for (ordered.items) |previous| if (previous.owner.id == entry.owner.id) {
                present = true;
                break;
            };
            if (!present) try ordered.append(self.allocator, entry);
        }
        try self.view.update(revision, ordered.items);
        self.painted_revision = revision;
    }
    fn show(self: *QuickConnectHost) !void {
        self.painted_revision = null;
        try self.refreshAssets();
        try self.view.show();
        if (self.nav) |nav| nav.quick.quick_connect_open = true;
    }
    fn close(self: *QuickConnectHost) void {
        self.view.hide();
    }
    fn closed(raw: *anyopaque) void {
        const self: *QuickConnectHost = @ptrCast(@alignCast(raw));
        if (self.nav) |nav| nav.quick.quick_connect_open = false;
    }
    fn saved(raw: *anyopaque, owner: @import("host/identity.zig").AssetOwner) !void {
        const self: *QuickConnectHost = @ptrCast(@alignCast(raw));
        _ = try self.workspace.registry.get(owner);
        const index = self.workspace.registry.indexOf(owner.id) orelse return error.AssetNotFound;
        try self.workspace.newSession(index);
    }
    fn temporary(raw: *anyopaque, target: quick_connect_mod.ParsedTarget) !void {
        const self: *QuickConnectHost = @ptrCast(@alignCast(raw));
        const name = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ target.host, target.port });
        defer self.allocator.free(name);
        try self.workspace.newTemporarySession(.{ .name = name, .host = target.host, .port = target.port, .user = target.user orelse return error.MissingUser });
    }
    fn newProfile(raw: *anyopaque, target: ?quick_connect_mod.ParsedTarget, query: []const u8) !void {
        const self: *QuickConnectHost = @ptrCast(@alignCast(raw));
        const nav = self.nav orelse return error.ApplicationUnavailable;
        const host = nav.wizard_host orelse return error.WizardUnavailable;
        if (host.wizard.root) |root| if (root.style.display != .none) return error.WizardBusy;
        host.selected_group = null;
        try host.refreshAssets();
        try remote_editor.loadDraft(host.wizard, if (target) |value| .{ .name = value.host, .host = value.host, .user = value.user orelse "", .port = value.port } else .{ .name = query });
        host.wizard.show();
    }
    fn cleanup(self: *QuickConnectHost) void {
        self.allocator.destroy(self);
    }
};

/// Sidebar search box host: routes Input on_change into Workspace.setSearch,
/// which live-filters the host list (previously a static placeholder).
const SearchHost = struct {
    allocator: std.mem.Allocator,
    workspace: *ws.Workspace,

    fn onChange(self: *SearchHost, text: []const u8) void {
        self.workspace.setSearch(text);
    }

    fn cleanup(self: *SearchHost) void {
        self.allocator.destroy(self);
    }
};

fn caseInsensitiveContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    for (haystack[0 .. haystack.len - needle.len + 1], 0..) |_, index| {
        var matches = true;
        for (needle, 0..) |n, offset| {
            if (std.ascii.toLower(haystack[index + offset]) != std.ascii.toLower(n)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

const AiClick = struct {
    host: *AiHost,

    fn onClick(self: *AiClick) void {
        self.host.toggle();
    }
};

const AiStopClick = struct {
    host: *AiHost,
};

fn onAiStopClick(raw: *anyopaque) void {
    const click: *AiStopClick = @ptrCast(@alignCast(raw));
    click.host.stop();
}

/// Legacy free-function trampoline for behavior.events.on_click sites.
fn onAiToggleClickLegacy(raw: *anyopaque) void {
    const ctx: *AiClick = @ptrCast(@alignCast(raw));
    ctx.host.toggle();
}

// ── Region builders ─────────────────────────────────────────────────

fn mountTitleBar(cx: *ui.Cx, scope: *ui.Scope, p: Palette, settings_host: *SettingsHost, workspace: *ws.Workspace, ai_host: *AiHost, nav_host: *AppNavHost) !*ui.Node {
    const bar = try ui.boxStyled(cx, shell_styles.title, .{});
    bar.meta.ownership.meta.test_id = "workspace.titlebar";
    nav_host.title_bar = bar;
    const icon_tint = try scope.createSignal(?ui.Color, p.fg_secondary);
    nav_host.chrome.toolbar_tint = icon_tint;
    const controls = try ui.box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 6 }, .{});
    nav_host.title_controls = controls;
    controls.setDisplay(.flex);
    try bar.appendChild(cx.allocator, controls);
    // Live tab strip: Workspace appends/removes/selects tab nodes here.
    try controls.appendChild(cx.allocator, workspace.tab_bar);
    const tab_add = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.plus, .icon_tint = icon_tint, .a11y_label = "新建会话", .on_click = cx.on(AppNavHost, nav_host, AppNavHost.showSessionMenu) }).mount(scope, cx);
    shell_styles.titleToolbarButton(cx.allocator, tab_add);
    tab_add.meta.ownership.meta.test_id = "toolbar.new_session";
    nav_host.session_menu_anchor = tab_add;
    try controls.appendChild(cx.allocator, tab_add);
    try controls.appendChild(cx.allocator, try ui.spacer(cx));
    const actions = try ui.hstack(cx, .{ .gap = 5, .align_items = .center, .flex_shrink = 0 }, .{});
    try controls.appendChild(cx.allocator, actions);
    const quick_click = try cx.allocator.create(NavClick);
    quick_click.* = .{ .host = nav_host, .kind = .quick_connect };
    try actions.appendChild(cx.allocator, try titleIcon(cx, scope, "⚡", icon_tint, false, onNavClick, @ptrCast(quick_click)));
    const xfer_click = try cx.allocator.create(NavClick);
    xfer_click.* = .{ .host = nav_host, .kind = .transfer };
    const transfer_anchor = try transferIcon(cx, scope, icon_tint, nav_host, onNavClick, @ptrCast(xfer_click));
    nav_host.transfer_anchor = transfer_anchor;
    try actions.appendChild(cx.allocator, transfer_anchor);
    const ai_click = try cx.allocator.create(AiClick);
    ai_click.* = .{ .host = ai_host };
    const ai_trigger = try titleIcon(cx, scope, "✨", icon_tint, false, onAiToggleClickLegacy, @ptrCast(ai_click));
    ai_host.toolbar_trigger = ai_trigger;
    try actions.appendChild(cx.allocator, ai_trigger);
    const notification_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.bell, .icon_size = @as(f32, 16), .icon_tint = icon_tint, .a11y_label = "通知" }).mount(scope, cx);
    shell_styles.titleToolbarButton(cx.allocator, notification_button);
    notification_button.meta.ownership.meta.test_id = "toolbar.notifications";
    nav_host.notification_anchor = notification_button;
    try actions.appendChild(cx.allocator, notification_button);
    const settings_click = try cx.allocator.create(SettingsNavClick);
    settings_click.* = .{ .host = settings_host, .page_index = 0 };
    const settings_trigger = try titleIcon(cx, scope, "⚙️", icon_tint, true, onSettingsTitleClick, @ptrCast(settings_click));
    settings_host.focus_return = settings_trigger;
    try actions.appendChild(cx.allocator, settings_trigger);
    return bar;
}

/// 标题栏图标：30×28、圆角 7、透明底（mockup .icn）。
fn titleIcon(cx: *ui.Cx, scope: *ui.Scope, icon: []const u8, color: *ui.Signal(?ui.Color), _: bool, callback: *const fn (*anyopaque) void, ctx: *anyopaque) !*ui.Node {
    const asset = if (std.mem.eql(u8, icon, "⚡")) @import("ui/quick_connect_icon.zig").asset else if (std.mem.eql(u8, icon, "✨")) ui.icons.sparkles else ui.icons.settings;
    const label = if (std.mem.eql(u8, icon, "⚡")) "快捷连接" else if (std.mem.eql(u8, icon, "✨")) "AI 助手" else "偏好设置";
    const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = asset, .icon_size = @as(f32, 16), .icon_tint = color, .a11y_label = label, .on_click = ui.Handler(void){ .callback = callback, .context = ctx } }).mount(scope, cx);
    shell_styles.titleToolbarButton(cx.allocator, button);
    button.meta.ownership.meta.test_id = if (std.mem.eql(u8, icon, "⚡")) "toolbar.quick_connect" else if (std.mem.eql(u8, icon, "✨")) "toolbar.ai" else "toolbar.settings";
    return button;
}

/// ⇅ 传输图标（含右上角计数徽标）。
fn transferIcon(cx: *ui.Cx, scope: *ui.Scope, tint: *ui.Signal(?ui.Color), nav_host: *AppNavHost, on_click: anytype, ctx: *anyopaque) !*ui.Node {
    const icn = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.arrow_down_up, .icon_size = @as(f32, 16), .icon_tint = tint, .a11y_label = "全局传输管理器", .on_click = ui.Handler(void){ .callback = on_click, .context = ctx } }).mount(scope, cx);
    shell_styles.titleToolbarButton(cx.allocator, icn);
    icn.meta.ownership.meta.test_id = "toolbar.transfers";
    const badge = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 1 }, .right = .{ .px = 0 } },
        .height = .{ .px = 13 },
        .width = .{ .px = 13 },
        .align_items = .center,
        .justify = .center,
        .background = app_theme.current().ok,
        .border = .{ .width = 0, .color = app_theme.current().ok, .radius = 7 },
    }, .{});
    badge.appendChild(cx.allocator, try ui.text(cx, "0", .{ .font_size = 8.5, .font_weight = 600, .color = .WHITE })) catch {};
    nav_host.chrome.transfer_badge = badge;
    try icn.appendChild(cx.allocator, badge);
    return icn;
}

/// Settings 图标回调：打开设置模态（与 ⌘, 同效）。
fn onSettingsTitleClick(raw: *anyopaque) void {
    const click: *SettingsNavClick = @ptrCast(@alignCast(raw));
    click.host.toggle();
}

fn mountSidebar(cx: *ui.Cx, scope: *ui.Scope, p: Palette, workspace: *ws.Workspace, nav_host: *AppNavHost) !*ui.Node {
    _ = p;
    const Sidebar = @import("ui/sidebar_view.zig");
    const search_host = try cx.allocator.create(SearchHost);
    search_host.* = .{ .allocator = cx.allocator, .workspace = workspace };
    try scope.onCleanup(SearchHost, search_host, SearchHost.cleanup);
    if (workspace.sidebar_bridge.new_host == null) {
        workspace.sidebar_bridge.context = nav_host;
        workspace.sidebar_bridge.new_host = struct {
            fn run(raw: ?*anyopaque, _: ?Sidebar.GroupRef) void {
                const host: *AppNavHost = @ptrCast(@alignCast(raw orelse return));
                if (host.wizard) |wizard| wizard.show();
            }
        }.run;
    }
    const view = try Sidebar.View.mount(cx, scope, workspace.sidebar_list, .{
        .context = nav_host,
        .local = AppNavHost.newLocalSession,
        .collapse = struct {
            fn run(raw: *anyopaque) void {
                const host: *AppNavHost = @ptrCast(@alignCast(raw));
                host.toggleSidebar();
            }
        }.run,
        .search_changed = cx.on(SearchHost, search_host, SearchHost.onChange),
        .bridge = workspace.sidebar_bridge,
    });
    workspace.sidebar_chrome = view;
    nav_host.sidebar_full = view.full;
    nav_host.sidebar_empty = view.empty;
    nav_host.chrome.sidebar_search_input = view.search;
    view.setSearchAvailable(workspace.registry.hosts.len != 0);
    const empty = workspace.registry.hosts.len == 0 and workspace.registry.groups.len == 0;
    view.full.setDisplay(if (empty) .none else .flex);
    view.empty.setDisplay(if (empty) .flex else .none);
    return view.root;
}

fn mountStatusBar(cx: *ui.Cx, scope: *ui.Scope, p: Palette, status_node: *ui.Node) !@import("ui/ssh_status_host.zig").StatusBar {
    _ = p;
    return @import("ui/ssh_status_host.zig").mountStatusBar(cx, scope, status_node);
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const data_paths = try cx.allocator.create(DataPaths);
    data_paths.* = try DataPaths.forApplication(cx.allocator);
    try scope.onCleanup(DataPaths, data_paths, cleanupDataPaths);
    const config_path = data_paths.config;
    const hosts_path = data_paths.hosts;
    const app_config = if (process_windows) |process| blk: {
        if (process.runtime_config) |existing| break :blk existing;
        const runtime = try std.heap.c_allocator.create(RuntimeConfig);
        errdefer std.heap.c_allocator.destroy(runtime);
        runtime.* = try RuntimeConfig.loadOrDefault(cx.io, std.Io.Dir.cwd(), std.heap.c_allocator, config_path);
        process.runtime_config = runtime;
        break :blk runtime;
    } else blk: {
        const runtime = try cx.allocator.create(RuntimeConfig);
        runtime.* = try RuntimeConfig.loadOrDefault(cx.io, std.Io.Dir.cwd(), cx.allocator, config_path);
        try scope.onCleanup(RuntimeConfig, runtime, cleanupRuntimeConfig);
        break :blk runtime;
    };
    if (!@import("platform/app_icon.zig").apply(app_config.value.ui.icon_background)) std.log.warn("Dock icon could not be applied", .{});
    if (process_notifications) |notifications| try notifications.updatePolicy(app_config.value.notify);
    app_theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(app_config.value.ui.theme));
    cx.setTheme(app_theme.widgetTheme(app_theme.currentName()));
    const p = Palette.fromTheme();

    // ── Overlay panels (hidden by default) ──────────────────────────
    // AI Float（mockup-ai-float .af）：锚 pane 顶中央（top14 居中），600 宽
    // 浮窗。外层为全宽定位容器（display 切换目标），内层 .af 卡片承载视觉。
    const ai_panel = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 14 }, .left = .{ .px = 0 }, .right = .{ .px = 0 } },
        .z_index = 200,
        .width = .fill(),
        .direction = .row,
        .justify = .center,
        .align_items = .start,
    }, .{});
    ai_panel.setDisplay(.none);
    const ai_styles = @import("ui/ai_assistant_styles.zig");
    const ai_host = try cx.allocator.create(AiHost);
    const ai_card_box = try ui.boxStyled(cx, ai_styles.panel, .{});
    ai_card_box.meta.ownership.meta.test_id = "ai.panel";
    const grip_row = try ui.boxStyled(cx, ai_styles.gripRow, .{});
    try grip_row.appendChild(cx.allocator, try ui.boxStyled(cx, ai_styles.grip, .{}));
    try ai_card_box.appendChild(cx.allocator, grip_row);
    const ai_window_base = try scope.createSignal(ai_styles.ButtonStyle, ai_styles.windowControl());
    const ai_window_hovers = [_]*ui.Signal(?ai_styles.ButtonStyle){
        try scope.createSignal(?ai_styles.ButtonStyle, ai_styles.controlHover(.collapse)),
        try scope.createSignal(?ai_styles.ButtonStyle, ai_styles.controlHover(.maximize)),
        try scope.createSignal(?ai_styles.ButtonStyle, ai_styles.controlHover(.close)),
    };
    const ai_header = try ui.boxStyled(cx, ai_styles.header, .{});
    try ai_header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.sparkles, app_theme.current().accent, ai_styles.regionIcon()));
    try ai_header.appendChild(cx.allocator, try ui.textStyled(cx, ai_styles.title, "AI 助手"));
    const ai_status = try ui.textStyled(cx, ai_styles.ownerText, "");
    ai_status.setStyleInline(cx.allocator, .{ .max_width = 144, .min_width = 0 });
    const ai_owner_pill = try ui.boxStyled(cx, ai_styles.ownerPill, .{});
    ai_owner_pill.meta.ownership.meta.test_id = "ai.owner";
    try ai_owner_pill.appendChild(cx.allocator, ai_status);
    try ai_header.appendChild(cx.allocator, ai_owner_pill);
    try ai_header.appendChild(cx.allocator, try ui.spacer(cx));
    const ai_new = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "新建 AI 会话", .base_style = ai_window_base, .hover_style = ai_window_hovers[0], .on_click = cx.on(AiHost, ai_host, AiHost.newConversation) }).mount(scope, cx);
    ai_new.meta.ownership.meta.test_id = "ai.session.new";
    const ai_new_icon = try ui.iconTint(cx, ui.icons.plus, app_theme.current().fg_2, ai_styles.icon());
    try ai_new.appendChild(cx.allocator, ai_new_icon);
    try ai_header.appendChild(cx.allocator, ai_new);
    const ai_sessions = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "AI 会话列表", .base_style = ai_window_base, .hover_style = ai_window_hovers[0], .on_click = cx.on(AiHost, ai_host, AiHost.showConversations) }).mount(scope, cx);
    ai_sessions.meta.ownership.meta.test_id = "ai.sessions";
    const ai_sessions_icon = try ui.iconTint(cx, ui.icons.get("messages-square").?, app_theme.current().fg_2, ai_styles.icon());
    try ai_sessions.appendChild(cx.allocator, ai_sessions_icon);
    try ai_header.appendChild(cx.allocator, ai_sessions);
    const ai_collapse = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "收起 AI 助手", .base_style = ai_window_base, .hover_style = ai_window_hovers[0], .on_click = cx.on(AiHost, ai_host, AiHost.collapse) }).mount(scope, cx);
    ai_collapse.meta.ownership.meta.test_id = "ai.collapse";
    const ai_collapse_icon = try ui.iconTint(cx, ui.icons.get("minus").?, app_theme.current().fg_2, ai_styles.windowIcon());
    try ai_collapse.appendChild(cx.allocator, ai_collapse_icon);
    try ai_header.appendChild(cx.allocator, ai_collapse);
    const ai_maximize = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "放大或还原 AI 助手", .base_style = ai_window_base, .hover_style = ai_window_hovers[1], .on_click = cx.on(AiHost, ai_host, AiHost.maximize) }).mount(scope, cx);
    ai_maximize.meta.ownership.meta.test_id = "ai.maximize";
    const ai_maximize_icon = try ui.iconTint(cx, ui.icons.get("maximize-2").?, app_theme.current().fg_2, ai_styles.windowIcon());
    try ai_maximize.appendChild(cx.allocator, ai_maximize_icon);
    try ai_header.appendChild(cx.allocator, ai_maximize);
    const ai_close = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "关闭 AI 助手", .base_style = ai_window_base, .hover_style = ai_window_hovers[2], .on_click = cx.on(AiHost, ai_host, AiHost.closeAssistant) }).mount(scope, cx);
    ai_close.meta.ownership.meta.test_id = "ai.close";
    const ai_close_icon = try ui.iconTint(cx, ui.icons.x, app_theme.current().fg_2, ai_styles.windowIcon());
    try ai_close.appendChild(cx.allocator, ai_close_icon);
    try ai_header.appendChild(cx.allocator, ai_close);
    try ai_card_box.appendChild(cx.allocator, ai_header);
    const ai_card = try ui.textStyled(cx, ai_styles.secondary, "");
    const ai_conversation = try ui.boxStyled(cx, ai_styles.conversation, .{});
    try ai_conversation.appendChild(cx.allocator, ai_card);
    const ai_scroll = try ui.widgets.ScrollArea(.{ .height = 276, .direction = .vertical }).mount(scope, cx);
    ai_scroll.container.meta.ownership.meta.test_id = "ai.conversation.viewport";
    ai_scroll.content.setStyleInline(cx.allocator, .{ .will_change_transform = false });
    ai_scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .margin = .{ .bottom = 6 }, .overflow_hidden = true, .composited_group = true });
    try ai_scroll.content.appendChild(cx.allocator, ai_conversation);
    try ai_card_box.appendChild(cx.allocator, ai_scroll.container);
    const ai_prompt = try scope.createText("", .{});
    var native_context: ?*NativeContext = null;
    var native_client: ?*AiClient = null;
    var native_binding: ?*AiClient.Binding = null;
    var ai_native_io: ?*std.Io.Threaded = null;
    var ai_provider_instance: ai_provider.Provider = undefined;
    // Bootstrap the transport from saved settings. Sending validates the exact
    // current selection and credentials before any network request.
    const provider_config = ai_provider_config.fromSettings(app_config.value.ai) catch ai_provider_config.defaults(.openai_compat);
    {
        // Dedicated io instance for the AI worker thread: std.Io is not
        // thread-safe and the UI thread owns cx.io. The worker runs the
        // synchronous HTTP call on this private instance exclusively.
        const ai_io = try cx.allocator.create(std.Io.Threaded);
        ai_io.* = .init(std.heap.c_allocator, .{});
        ai_native_io = ai_io;
        const context = try cx.allocator.create(NativeContext);
        context.* = .{ .io = ai_io.io() };
        native_context = context;
        // The provider chain captures POINTERS: Binding.asProvider stores
        // ctx = *Binding and Binding holds client: *AiClient. These MUST
        // outlive mountUI's stack frame — as locals the worker thread
        // dereferenced dead stack memory after mountUI returned (SIGSEGV
        // in transport.request, and the pre-async "AI request failed"
        // ghost). Heap-allocate both; AiHost.cleanup frees them.
        const client_ptr = try cx.allocator.create(AiClient);
        client_ptr.* = AiClient.native(cx.allocator, context, switch (provider_config.kind) {
            .anthropic => .anthropic,
            else => .openai_compat,
        });
        native_client = client_ptr;
        const binding_ptr = try cx.allocator.create(AiClient.Binding);
        binding_ptr.* = .{ .client = client_ptr, .config = provider_config };
        native_binding = binding_ptr;
        ai_provider_instance = binding_ptr.asProvider();
    }
    const endpoint = provider_config.endpoint;
    const model = provider_config.model;
    ai_host.* = .{ .allocator = cx.allocator, .cx = cx, .scope = scope, .controller = AiController.init(cx.allocator), .manager = AiManager.init(cx.allocator), .stream_mailbox = @import("ai/stream_mailbox.zig").Mailbox.init(cx.allocator), .step_mailbox = @import("ai/step_events.zig").Mailbox.init(cx.allocator), .tool_bridge = @import("ui/ai_tools.zig").Bridge.init(std.heap.c_allocator), .tool_results = @import("ai/tool_results.zig").Store.init(cx.allocator), .provider = ai_provider_instance, .native_context = native_context, .native_client = native_client, .native_binding = native_binding, .endpoint = endpoint, .model = model, .panel = ai_panel, .status = ai_status, .card_node = ai_card, .prompt = ai_prompt, .conversation = ai_conversation };
    ai_host.manager.observer = .{ .context = ai_host, .reset = AiHost.streamReset, .delta = AiHost.streamDelta };
    ai_host.window_base = ai_window_base;
    for (ai_window_hovers, 0..) |hover, index| ai_host.window_hovers[index] = hover;
    ai_host.window_icons = .{ ai_collapse_icon, ai_maximize_icon, ai_close_icon };
    ai_host.session_icons = .{ ai_new_icon, ai_sessions_icon };
    for ([_]*ui.Node{ ai_collapse, ai_maximize, ai_close }, ai_host.window_icons, 0..) |button, icon_node, index| {
        const hovered = try ui.hooks.useHover(scope, button);
        try scope.createEffect(.{ .hovered = hovered, .icon = icon_node.?, .index = index, .theme = try cx.themeSignal(scope) }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.theme.get();
                const colors = app_theme.current();
                _ = ctx.icon.setTint(if (!ctx.hovered.get()) colors.fg_2 else switch (ctx.index) {
                    0 => colors.warn,
                    1 => colors.ok,
                    else => colors.danger,
                });
            }
        }.run);
    }

    ai_host.sessions_view = try @import("ui/ai_sessions_view.zig").View.mount(cx, scope, ai_sessions, .{ .context = ai_host, .select = AiHost.selectConversation, .request_close = AiHost.requestConversationClose, .remove = AiHost.deleteConversation });
    try ai_header.appendChild(cx.allocator, ai_host.sessions_view.?.root);
    ai_host.panel_hover = try ui.hooks.useHover(scope, ai_card_box);
    ai_card_box.behavior.events.on_event_capture = AiHost.panelCapture;
    ai_card_box.behavior.events.capture_context = ai_host;
    ai_host.runtime_config = app_config;
    ai_host.card_box = ai_card_box;
    ai_host.conversation_viewport = ai_scroll.container;
    ai_host.tail_follow = .{ .scroll = ai_scroll };
    try scope.onCleanup(AiHost, ai_host, AiHost.cleanup);
    ai_host.gestures = try @import("ui/ai_float_gestures.zig").View.mount(cx, scope, ai_card_box, grip_row, &ai_host.controller.model);
    // Own the AI-threaded io AFTER the full struct literal above (the
    // literal resets every unlisted field, so assigning earlier leaked).
    if (ai_native_io) |io| ai_host.ai_io = io;
    // Result poller: consumes worker-thread completions on the UI thread
    // (self-scheduling only while a request is in flight). Registered
    // AFTER the AiHost cleanup entry: scope teardown is reverse-order, so
    // the poll hook is gone before the worker may be joined.
    const ai_poll = try cx.allocator.create(AiHost.PollHook);
    ai_poll.* = .{ .host = ai_host };
    try cx.addAfterLayoutHook(ai_poll, AiHost.PollHook.run);
    try scope.onCleanup(AiHost.PollHook, ai_poll, AiHost.PollHook.cleanup);
    ai_host.approval_view = try @import("ui/ai_tool_approval_view.zig").View.mount(cx, scope, .{ .context = ai_host, .decide = AiHost.decideTool });
    try ai_scroll.content.appendChild(cx.allocator, ai_host.approval_view.?.root);
    const ai_preview_holder = try ui.boxStyled(cx, @import("ui/ai_attachments_styles.zig").inlineHolder, .{});
    ai_preview_holder.setDisplay(.none);
    try ai_scroll.content.insertChildBefore(cx.allocator, ai_preview_holder, ai_conversation);
    ai_host.attachment_preview_holder = ai_preview_holder;
    ai_host.attachments_view = try @import("ui/ai_attachments_view.zig").View.mountInline(cx, scope, .{ .context = ai_host, .remove = AiHost.removeAttachment, .attach = AiHost.attachAttachment, .reselect = AiHost.reselectAttachment, .preview_visibility = AiHost.textPreviewVisibility, .on_error = AiHost.attachmentViewError }, ai_preview_holder);
    ai_card_box.behavior.events.capture_context = ai_host;
    ai_card_box.behavior.events.on_event_capture = AiHost.attachmentPreviewEvent;
    ai_host.images_view = try @import("ui/ai_image_attachments_view.zig").View.mount(cx, scope, .{ .context = ai_host, .remove = AiHost.removeImage, .retry = AiHost.retryImage, .visibility = AiHost.imagePreviewVisibility, .on_error = AiHost.attachmentViewError }, ai_preview_holder);

    try ai_host.images_view.?.shareRail(ai_host.attachments_view.?.rail.content);
    ai_host.attachments_view.?.external_rail = ai_host.images_view.?.root;
    const ai_feedback = try ui.text(cx, "", .{ .font_size = 11, .line_height = 1.4, .wrap = .word, .color = app_theme.current().warn });
    ai_feedback.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0, .padding = .{ .left = 14, .right = 14, .top = 4, .bottom = 4 } });
    ai_feedback.meta.ownership.meta.test_id = "ai.feedback";
    ai_feedback.setDisplay(.none);
    ai_host.feedback = ai_feedback;
    try ai_card_box.appendChild(cx.allocator, ai_feedback);
    const ai_input_row = try ui.boxStyled(cx, ai_styles.composer, .{});
    ai_styles.finishComposer(cx, ai_input_row);
    try ai_input_row.appendChild(cx.allocator, ai_host.attachments_view.?.root);
    const ai_input = try ui.widgets.Textarea(.{ .value = ai_prompt, .borderless = true, .rows = 1, .placeholder = "继续提问，或 / 引用远程文件…", .on_change = cx.on(AiHost, ai_host, AiHost.promptChanged) }).mountResult(scope, cx);
    ai_input.wrapper.setStyleInline(cx.allocator, ai_styles.input());
    ai_input.input.setStyleInline(cx.allocator, ai_styles.input());
    ai_host.input_node = ai_input.input;
    ai_host.textarea = ai_input.state;
    ai_host.composer_input = ai_input;
    ai_host.composer_node = ai_input_row;
    @import("ui/ai_composer_sizing.zig").configure(ai_input);
    ai_input.input.meta.ownership.meta.test_id = "ai.prompt";
    const ai_placeholder = try ui.text(cx, "继续提问，或 / 引用远程文件…", .{ .font_size = 12, .line_height = 1.5, .color = app_theme.current().fg_3 });
    ai_placeholder.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 10 }, .top = .{ .px = 8 } }, .max_width = 540 });
    ai_placeholder.meta.ownership.meta.test_id = "ai.prompt.placeholder";
    ai_placeholder.setHitTestVisible(false);
    ai_host.input_placeholder = ai_placeholder;
    try ai_input.wrapper.appendChild(cx.allocator, ai_placeholder);
    ai_input.input.behavior.events.capture_context = ai_host;
    ai_input.input.behavior.events.on_event_capture = AiHost.composerEvent;
    try ai_input_row.appendChild(cx.allocator, ai_input.wrapper);
    const composer_controls = try @import("ui/ai_composer_controls_view.zig").View.mount(cx, scope, .{ .context = ai_host, .action = AiHost.composerAction, .open_settings = AiHost.composerSettings });
    ai_host.composer_controls = composer_controls;
    const ai_controls = composer_controls.trailing;
    const ai_send_base = try scope.createSignal(ai_styles.ButtonStyle, ai_styles.primary());
    ai_host.send_base = ai_send_base;
    const ai_stop_btn = try ui.widgets.Button(.{ .a11y_label = "停止生成", .variant = .primary, .base_style = ai_send_base, .on_click = cx.on(AiHost, ai_host, AiHost.stop) }).mount(scope, cx);
    try ai_stop_btn.appendChild(cx.allocator, try ui.boxStyled(cx, ai_styles.stopIcon, .{}));
    ai_stop_btn.meta.ownership.meta.test_id = "ai.stop";
    ai_stop_btn.setOpacityRaw(0);
    ai_stop_btn.setHitTestVisible(false);
    ai_host.stop_button = ai_stop_btn;
    try ai_controls.appendChild(cx.allocator, ai_stop_btn);
    const ai_send_disabled = try scope.createSignal(bool, true);
    ai_host.send_disabled = ai_send_disabled;
    const ai_send = try ui.widgets.Button(.{ .variant = .primary, .a11y_label = "发送问题", .base_style = ai_send_base, .disabled = ai_send_disabled, .on_click = cx.on(AiHost, ai_host, AiHost.sendPrompt) }).mount(scope, cx);
    ai_send.meta.ownership.meta.test_id = "ai.send";
    ai_host.send_button = ai_send;
    try ai_send.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("arrow-up").?, app_theme.current().fg_1, ai_styles.icon()));
    try ai_controls.appendChild(cx.allocator, ai_send);
    try ai_input_row.appendChild(cx.allocator, composer_controls.root);
    try ai_card_box.appendChild(cx.allocator, ai_input_row);
    try ai_panel.appendChild(cx.allocator, ai_card_box);

    // Frozen V3 settings: centered shell, independently scrolling navigation and content.
    const settings_panel = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .width = .fill(),
        .height = .fill(),
        .z_index = 400,
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.BLACK.withAlpha(102),
    }, .{});
    settings_panel.setDisplay(.none);
    const settings_card = try ui.boxStyled(cx, shell_styles.settingsPanel, .{});
    settings_card.meta.ownership.meta.test_id = "settings.panel";
    try settings_panel.appendChild(cx.allocator, settings_card);
    const settings_header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = @import("ui/v3_geometry.zig").settings_header }, .flex_shrink = 0, .direction = .row, .align_items = .center, .padding = .{ .left = 18, .right = 18, .top = 15, .bottom = 10 }, .gap = 10 }, .{});
    const settings_header_icon = try ui.iconTint(cx, ui.icons.settings, app_theme.current().accent, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } });
    settings_header_icon.meta.ownership.meta.test_id = "settings.header.icon";
    try settings_header.appendChild(cx.allocator, settings_header_icon);
    const settings_header_title = try ui.text(cx, "偏好设置", .{ .font_size = 14, .font_weight = 700, .color = app_theme.current().fg_1 });
    settings_header_title.meta.ownership.meta.test_id = "settings.header.title";
    try settings_header.appendChild(cx.allocator, settings_header_title);
    try settings_header.appendChild(cx.allocator, try ui.spacer(cx));
    try settings_card.appendChild(cx.allocator, settings_header);
    const settings_body = try ui.boxStyled(cx, shell_styles.settingsBody, .{});
    settings_body.setStyle(cx.allocator, .gap, if (cx.viewport.width < 950) @as(f32, 10) else @as(f32, 16));
    try settings_card.appendChild(cx.allocator, settings_body);
    const settings_nav = try ui.boxStyled(cx, shell_styles.settingsNavigation, .{});
    settings_nav.style.gap = 10;
    settings_nav.meta.ownership.meta.test_id = "settings.navigation";
    try settings_body.appendChild(cx.allocator, settings_nav);

    const settings_nav_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    settings_nav_scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
    settings_nav_scroll.container.meta.ownership.meta.test_id = "settings.navigation.scroll";
    const settings_nav_list = settings_nav_scroll.content;
    settings_nav_list.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 5 });
    try settings_nav.appendChild(cx.allocator, settings_nav_scroll.container);
    const settings_identity = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 24 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 6 }, .{});
    try settings_identity.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.lock, p.fg_secondary, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
    try settings_identity.appendChild(cx.allocator, try ui.text(cx, "本地设置", .{ .font_size = 11, .color = p.fg_secondary }));
    try settings_nav.appendChild(cx.allocator, settings_identity);
    const settings_right = try ui.boxStyled(cx, shell_styles.settingsContent, .{});
    settings_right.setStyle(cx.allocator, .padding, ui.Padding{ .right = 4 });
    const settings_content = try ui.boxStyled(cx, shell_styles.settingsContent, .{});
    try settings_right.appendChild(cx.allocator, settings_content);
    try settings_body.appendChild(cx.allocator, settings_right);
    const settings_host = try cx.allocator.create(SettingsHost);
    settings_host.* = .{ .allocator = cx.allocator, .cx = cx, .scope = scope, .controller = try SettingsController.init(cx.allocator, app_config.value), .runtime = app_config, .io = cx.io, .panel = settings_panel, .status = undefined };
    ai_host.settings_host = settings_host;
    settings_host.nav_list = settings_nav_list;
    settings_host.navigation = settings_nav;
    settings_host.header_title = settings_header_title;
    settings_host.header_icon = settings_header_icon;
    settings_host.layout = settings_body;
    settings_host.content = settings_content;
    settings_host.card = settings_card;
    const settings_search_result = try ui.widgets.Input(.{ .placeholder = "搜索设置…", .leading_icon_asset = ui.icons.search, .width = @as(f32, 282), .on_change = cx.on(SettingsHost, settings_host, SettingsHost.searchChanged) }).mountResult(scope, cx);
    settings_host.search_input = settings_search_result;
    const settings_search = settings_search_result.node;
    settings_search.style.height = .{ .px = 32 };
    settings_search.meta.ownership.meta.test_id = "settings.search";
    try settings_header.appendChild(cx.allocator, settings_search);
    const settings_close = try ui.widgets.Button(.{ .icon_asset = ui.icons.x, .icon_only = true, .a11y_label = "关闭偏好设置", .variant = .ghost, .on_click = cx.on(SettingsHost, settings_host, SettingsHost.toggle) }).mount(scope, cx);
    shell_styles.toolbarButton(cx.allocator, settings_close);
    settings_close.setStyleInline(cx.allocator, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 } });
    settings_close.meta.ownership.meta.test_id = "settings.close";
    try settings_header.appendChild(cx.allocator, settings_close);
    try scope.onCleanup(SettingsHost, settings_host, SettingsHost.cleanup);
    // Kept outside replaceable page scopes; shown only on a concrete error.
    const settings_status = try ui.text(cx, "", .{ .font_size = 10.5, .color = p.fg_secondary });
    settings_status.setDisplay(.none);
    settings_status.style.flex_shrink = 0;
    try settings_right.appendChild(cx.allocator, settings_status);
    settings_host.status = settings_status;
    try settings_host.initAppearance();

    const menu_host = try cx.allocator.create(MenuHost);
    menu_host.* = .{ .allocator = cx.allocator, .cx = cx, .panel = undefined, .scope = scope };
    const menu_open = try scope.createSignal(bool, false);
    menu_host.popover_open = menu_open;
    const menu_popover = try ui.widgets.Popover(.{ .open = menu_open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = menu_host, .getRect = MenuHost.popoverAnchor } }, .position = .bottom_start, .width = 258, .offset = .{ .static = 4 }, .viewport_padding = 8, .shift_main_axis = true, .size_policy = .fit_content, .close_on_escape = false, .on_open_change = cx.on(MenuHost, menu_host, MenuHost.popoverChanged) }).mount(scope, cx);
    menu_popover.wrapper.style.position = .absolute;
    menu_popover.wrapper.style.width = .{ .px = 0 };
    menu_popover.wrapper.style.height = .{ .px = 0 };
    const menu_panel = menu_popover.content;
    menu_host.panel = menu_panel;
    menu_host.chrome = menu_popover.chrome;
    menu_host.scope = menu_popover.scope;
    menu_popover.chrome.setStyleInline(cx.allocator, .{ .padding = ui.Padding.all(14), .gap = 1, .background = app_theme.current().overlay, .border = .{ .width = 0, .color = p.border, .radius = 14 } });
    menu_panel.style.gap = 1;
    menu_popover.chrome.meta.ownership.meta.test_id = "context.menu";
    menu_panel.behavior.events.event_context = @ptrCast(menu_host);
    menu_panel.behavior.events.on_event_capture = MenuHost.onEvent;
    try scope.onCleanup(MenuHost, menu_host, MenuHost.cleanup);

    // Closed-session history modal (mounted once; rows are rebuilt from the
    // durable archive when the host-menu action opens it).
    const history_panel = try ui.box(cx, .{
        .position = .absolute,
        .width = .fill(),
        .height = .fill(),
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .z_index = 500,
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.rgba(0, 0, 0, 64),
    }, .{});
    const history_styles = @import("ui/history_styles.zig");
    const history_card = try ui.box(cx, history_styles.card(), .{});
    history_card.meta.ownership.meta.test_id = "history.panel";
    const history_head = try ui.box(cx, history_styles.header(), .{});
    try history_head.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.history, app_theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 }));
    try history_head.appendChild(cx.allocator, try ui.text(cx, "历史会话", .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = p.fg }));
    try history_head.appendChild(cx.allocator, try ui.spacer(cx));
    const history_close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .a11y_label = "关闭历史会话", .base_style = history_styles.close() }).mount(scope, cx);
    history_close.meta.ownership.meta.test_id = "history.close";
    const history_list = try ui.box(cx, history_styles.list(), .{});
    try history_head.appendChild(cx.allocator, history_close);
    try history_card.appendChild(cx.allocator, history_head);
    const history_scroll_result = try ui.widgets.ScrollArea(.{ .height = 116, .direction = .vertical }).mount(scope, cx);
    try history_scroll_result.content.appendChild(cx.allocator, history_list);
    try history_card.appendChild(cx.allocator, history_scroll_result.container);
    try history_panel.appendChild(cx.allocator, history_card);
    history_panel.setDisplay(.none);
    const history_host = try cx.allocator.create(HistoryHost);
    history_host.* = .{ .allocator = cx.allocator, .cx = cx, .scope = scope, .workspace = null, .colors = app_theme.current(), .panel = history_panel, .card = history_card, .list = history_list, .scroll = history_scroll_result.container, .scroll_state = history_scroll_result.state, .scroll_content = history_scroll_result.content, .archive = .{ .allocator = cx.allocator, .io = cx.io, .dir = std.Io.Dir.cwd() }, .model = undefined };
    try std.Io.Dir.cwd().createDirPath(cx.io, data_paths.directory);
    history_host.archive.dir = try std.Io.Dir.cwd().openDir(cx.io, data_paths.directory, .{});
    history_host.archive_dir_owned = true;
    history_host.model = HistoryModel.init(cx.allocator, &history_host.archive);
    history_panel.behavior.events.event_context = @ptrCast(history_host);
    history_panel.behavior.events.on_event_capture = HistoryHost.onPanelEvent;
    history_close.behavior.events.on_click = .{ .callback = HistoryHost.onClose, .context = @ptrCast(history_host) };
    try scope.onCleanup(HistoryHost, history_host, HistoryHost.cleanup);
    menu_host.history_host = history_host;
    menu_host.settings = settings_host;

    // ── Root shell ──────────────────────────────────────────────────
    const root = try ui.boxStyled(cx, shell_styles.root, .{});
    root.meta.ownership.meta.test_id = "workspace.shell";
    // App.runWith already provides cx.root and its popover portal. Keep that
    // runtime-owned root: replacing it bypasses viewport layout constraints.

    const status_text = try ui.text(cx, "未连接", .{ .font_size = 11, .color = p.fg_secondary });

    const main_row = try ui.boxStyled(cx, shell_styles.body, .{});
    main_row.meta.ownership.meta.test_id = "workspace.body";

    // Workspace owns host data, sidebar rows, tab strip nodes and sessions.
    const sidebar_list = try ui.box(cx, .{ .width = .fill(), .direction = .column }, .{});
    const tab_strip = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 6 }, .{});
    const content_stack = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .direction = .column }, .{});
    const history_card_host = try ui.box(cx, .{ .width = .fill(), .direction = .column, .flex_shrink = 0 }, .{});
    history_card_host.meta.ownership.meta.test_id = "workspace.history.slot";
    history_card_host.setDisplay(.none);
    try content_stack.appendChild(cx.allocator, history_card_host);
    const terminal_area = try ui.boxStyled(cx, shell_styles.pane, .{});
    terminal_area.meta.ownership.meta.test_id = "workspace.pane";
    terminal_area.style.flex_shrink = 1;
    try content_stack.appendChild(cx.allocator, terminal_area);
    // Empty workspace keeps the Local / saved-connection entry points.
    // The pane owns its background so this child cannot cover its rounded corners.
    const empty_state = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .gap = 0,
    }, .{});
    const empty_guide = try ui.boxStyled(cx, shell_styles.emptyGuide, .{});
    empty_guide.meta.ownership.meta.test_id = "workspace.empty";
    const empty_icon_box = try ui.boxStyled(cx, shell_styles.emptyIcon, .{});
    empty_icon_box.meta.ownership.meta.test_id = "workspace.empty.icon";
    const empty_icon = try ui.box(cx, .{ .width = .{ .px = 88 }, .height = .{ .px = 88 }, .flex_shrink = 0 }, .{});
    try empty_icon_box.appendChild(cx.allocator, empty_icon);
    try empty_guide.appendChild(cx.allocator, empty_icon_box);
    const empty_title = try ui.textStyled(cx, shell_styles.emptyTitle, "打开终端，开始工作");
    empty_title.style.height = .{ .px = 24 };
    empty_title.style.flex_shrink = 0;
    try empty_guide.appendChild(cx.allocator, empty_title);
    const empty_description = try ui.textStyled(cx, shell_styles.emptyDescription, "直接打开本地终端，或从左侧选择已保存的 SSH / SFTP 连接。");
    empty_description.style.height = .{ .px = 18.15 };
    empty_description.style.flex_shrink = 0;
    try empty_guide.appendChild(cx.allocator, empty_description);
    const empty_btns = try ui.boxStyled(cx, shell_styles.emptyActions, .{});
    const empty_local_style = try scope.createSignal(ui.BoxStyle, shell_styles.emptyButton(true));
    const empty_choose_style = try scope.createSignal(ui.BoxStyle, shell_styles.emptyButton(false));
    const empty_local = try ui.widgets.Button(.{ .label = "本地终端", .icon_asset = ui.icons.terminal, .icon_size = @as(f32, 17), .icon_tint = ui.Color.WHITE, .variant = .primary, .base_style = empty_local_style }).mount(scope, cx);
    empty_local.setStyleInline(cx.allocator, shell_styles.emptyButton(true));
    empty_local.meta.ownership.meta.test_id = "workspace.empty.local";
    @import("ui/sidebar_view.zig").setFocusRing(empty_local);
    try empty_btns.appendChild(cx.allocator, empty_local);
    const empty_choose_label = try scope.createText("快速连接", .{});
    const empty_choose_icon = try scope.createSignal(?ui.SvgAsset, @import("ui/quick_connect_icon.zig").asset);
    const empty_choose = try ui.widgets.Button(.{ .label = empty_choose_label, .icon_asset = empty_choose_icon, .icon_size = @as(f32, 17), .variant = .secondary, .base_style = empty_choose_style }).mount(scope, cx);
    empty_choose.setStyleInline(cx.allocator, shell_styles.emptyButton(false));
    empty_choose.meta.ownership.meta.test_id = "workspace.empty.choose";
    @import("ui/sidebar_view.zig").setFocusRing(empty_choose);
    try empty_btns.appendChild(cx.allocator, empty_choose);
    try empty_guide.appendChild(cx.allocator, empty_btns);
    try empty_state.appendChild(cx.allocator, empty_guide);
    try terminal_area.appendChild(cx.allocator, empty_state);

    const workspace = try ws.Workspace.init(
        cx.allocator,
        cx,
        scope,
        cx.io,
        &app_config.value,
        hosts_path,
        sidebar_list,
        tab_strip,
        terminal_area,
        empty_state,
    );
    workspace.history_card_host = history_card_host;
    workspace.status_node = status_text;
    settings_host.workspace = workspace;
    workspace.font_family_resolver = terminalFamilyId;
    workspace.terminal_typography_resolver = applyResolvedTerminalTypography;
    ai_host.workspace = workspace;
    workspace.error_hint_handler = .{ .context = ai_host, .on_open = AiHost.openCommandError, .on_notice = AiHost.archiveCommandError };
    menu_host.workspace = workspace;
    history_host.workspace = workspace;
    _ = try @import("ui/session_export_jobs.zig").Manager.mount(cx, scope, .{
        .context = workspace,
        .publish = struct {
            fn publish(raw: *anyopaque, message: []const u8) void {
                const target: *ws.Workspace = @ptrCast(@alignCast(raw));
                target.status(message);
            }
        }.publish,
    });
    menu_host.ai = ai_host;
    // Wizard is mounted below; MenuHost receives the live pointers after
    // WizardHost initialization so edit actions can reuse the same draft UI.

    // Wire the menu seam: sidebar/tab triggers flow Workspace → MenuHost.
    workspace.menu_bridge = .{ .context = @ptrCast(menu_host), .fire = MenuHost.bridgeFire, .host_action = MenuHost.sidebarAction };
    applog.info(.ui, "workspace ready: hosts={d} ui={s}x{s}", .{ workspace.registry.hosts.len, "1280", "800" });

    const quick_host = try cx.allocator.create(QuickConnectHost);
    quick_host.* = .{ .allocator = cx.allocator, .cx = cx, .workspace = workspace };
    try scope.onCleanup(QuickConnectHost, quick_host, QuickConnectHost.cleanup);
    quick_host.view = try @import("ui/quick_connect_view.zig").View.mount(cx, scope, .{ .context = quick_host, .saved = QuickConnectHost.saved, .temporary = QuickConnectHost.temporary, .new_profile = QuickConnectHost.newProfile, .closed = QuickConnectHost.closed });
    const quick_panel = quick_host.view.root;
    try quick_host.refreshAssets();

    const nav_host = try cx.allocator.create(AppNavHost);
    nav_host.* = .{ .allocator = cx.allocator, .cx = cx, .quick = QuickConnect.init(cx.allocator), .quick_panel = quick_panel, .settings = settings_host, .ai = ai_host, .roster = @import("ui/group_model.zig").Roster.init(cx.allocator) };
    if (app_config.value.ui.sidebar_width) |width| {
        const available = if (cx.viewport.width > 0) @min(480, @max(220, cx.viewport.width - 480)) else 480;
        nav_host.quick.sidebar.expanded_width = @min(width, available);
        nav_host.quick.sidebar.initial_width_pending = false;
    }
    nav_host.appearance_theme = try cx.bindState(shell_styles.ThemePublication, .{});
    nav_host.empty_choose_label = empty_choose_label;
    nav_host.empty_choose_icon = empty_choose_icon;
    nav_host.chrome.empty_icon = empty_icon;
    nav_host.chrome.empty_title = empty_title;
    nav_host.chrome.empty_description = empty_description;
    nav_host.chrome.empty_actions = .{ .{ .node = empty_local, .style = empty_local_style }, .{ .node = empty_choose, .style = empty_choose_style } };
    ai_host.roster = &nav_host.roster;
    quick_host.nav = nav_host;
    nav_host.quick_host = quick_host;
    empty_choose.behavior.events.on_click = cx.on(AppNavHost, nav_host, AppNavHost.homeConnect);
    empty_local.behavior.events.on_click = cx.on(AppNavHost, nav_host, AppNavHost.newLocalSessionClick);
    nav_host.workspace = workspace;
    nav_host.shell_root = root;
    nav_host.material_pane = terminal_area;
    settings_host.preview_viewport = terminal_area;
    const background_view = try @import("ui/background_layers.zig").View.mount(cx, scope);
    nav_host.background_view = background_view;
    settings_host.record_cleanup_material = background_view;
    try background_view.isolate(scope, history_card);
    try background_view.isolate(scope, settings_card);
    try background_view.isolate(scope, ai_card_box);
    if (ai_host.approval_view) |approval| try background_view.isolate(scope, approval.card);
    if (ai_host.composer_controls) |controls| for (controls.popups[0..controls.popup_count]) |popup| {
        try background_view.isolate(popup.widget.scope, popup.widget.chrome);
    };
    if (ai_host.attachments_view) |attachments| if (attachments.popup) |popup| try background_view.isolate(popup.scope, popup.chrome);
    try background_view.isolate(quick_host.view.scope, quick_host.view.chrome);
    try background_view.isolate(menu_popover.scope, menu_popover.chrome);
    if (cx.root) |window_root| try window_root.insertChildBefore(cx.allocator, background_view.root, if (window_root.children.items.len != 0) window_root.children.items[0] else null);

    settings_host.native_close_waiter = &nav_host.native_close_pending;
    const session_menu = try session_menu_mod.View.mount(cx, scope, .{ .context = nav_host, .new_profile = AppNavHost.newSessionProfile, .new_sftp = AppNavHost.newSftpProfile, .quick = AppNavHost.quickSession, .local = AppNavHost.newLocalSession, .saved = AppNavHost.savedSession });
    session_menu.root.style.position = .absolute;
    session_menu.root.style.width = .{ .px = 0 };
    session_menu.root.style.height = .{ .px = 0 };
    nav_host.session_menu = session_menu;
    try background_view.isolate(session_menu.scope, session_menu.chrome);
    try root.appendChild(cx.allocator, session_menu.root);
    nav_host.local_close_view = try @import("ui/local_close_view.zig").View.mount(cx, scope, .{ .context = nav_host, .resolve = AppNavHost.resolveLocalClose });
    try background_view.isolate(scope, nav_host.local_close_view.?.dialog);
    workspace.close_bridge = .{ .context = @ptrCast(nav_host), .risk = AppNavHost.closeRisk, .impact = AppNavHost.closeImpact, .cleanup = AppNavHost.cleanupSession, .confirm = AppNavHost.showLocalClose };
    const file_application = try file_application_mod.Host.create(cx.allocator, workspace);
    const application_host = (if (process_windows) |process|
        application_host_mod.ApplicationHost.initInDomain(process.domain, workspace, file_application.plugin())
    else
        application_host_mod.ApplicationHost.initWithFilePlugin(cx.allocator, workspace, file_application.plugin())) catch |err| {
        _ = file_application.shutdownStep();
        file_application.deinit() catch {};
        return err;
    };
    file_application.bind(application_host) catch |err| {
        file_application.abortInitialization();
        application_host.deinit();
        if (file_application.released) file_application.deinit() catch {};
        return err;
    };
    nav_host.file_application = file_application;
    nav_host.application_host = application_host;
    settings_host.application_host = application_host;
    ai_host.application_host = application_host;
    ai_host.file_application = file_application;
    application_host.install();
    application_host.setCloseExtension(nav_host, AppNavHost.closeStep);
    settings_host.controller.plugin_page.refreshRegistry(application_host.registry(), workspace.app_config.config_revision);
    workspace.command_bridge = .{ .context = @ptrCast(nav_host), .on_command = AppNavHost.onLocalCommand, .on_command_from = AppNavHost.onLocalCommandFrom };
    workspace.input_bridge = .{ .context = @ptrCast(nav_host), .on_input = AppNavHost.onTerminalInput, .on_service_input = AppNavHost.onServiceBroadcast, .paste_stamp = AppNavHost.broadcastPasteStamp };
    for (workspace.tabs.items) |tab| if (tab.terminal) |*terminal| {
        terminal.input_observer = .{ .context = @ptrCast(nav_host), .on_input = AppNavHost.onTerminalInput, .on_service_input = AppNavHost.onServiceBroadcast, .paste_stamp = AppNavHost.broadcastPasteStamp };
    };
    root.behavior.events.event_context = @ptrCast(nav_host);
    // Capture once at the runtime root. A second capture on this subtree
    // processes .handled again (e.g. cancel editor then close settings).
    // With no focused control, Zenit sends keys to the runtime root. Route
    // application shortcuts there as well as through the business subtree.
    if (cx.root) |app_root| {
        app_root.behavior.events.capture_context = @ptrCast(nav_host);
        app_root.behavior.events.on_event_capture = AppNavHost.onEvent;
    }
    try scope.onCleanup(AppNavHost, nav_host, AppNavHost.cleanup);

    const sidebar = try mountSidebar(cx, scope, p, workspace, nav_host);
    if (workspace.sidebar_chrome) |view| try background_view.isolate(view.new_menu.scope, view.new_menu.chrome);
    nav_host.sidebar_panel = sidebar;
    try main_row.appendChild(cx.allocator, sidebar);
    const sidebar_grip = try ui.box(cx, .{ .width = .{ .px = 8 }, .height = .fill(), .margin = .{ .left = -8, .right = -8 }, .flex_shrink = 0, .cursor = .ew_resize, .hit_behavior = .@"opaque" }, .{});
    sidebar_grip.meta.ownership.meta.test_id = "sidebar.resize";
    _ = try ui.interaction.drag.Binding.attach(scope, cx, sidebar_grip, .{ .axis = .horizontal, .activation_distance = 1 }, AppNavHost.resizeSidebar, nav_host);
    nav_host.sidebar_grip = sidebar_grip;
    try main_row.appendChild(cx.allocator, sidebar_grip);
    const collapsed_sidebar = try CollapsedSidebar.mount(cx, scope, workspace, .{
        .context = @ptrCast(nav_host),
        .search = AppNavHost.collapsedSearch,
        .new_host = AppNavHost.collapsedNew,
        .expand = AppNavHost.collapsedExpand,
        .host_action = AppNavHost.collapsedHostAction,
    });
    nav_host.collapsed_sidebar = collapsed_sidebar;

    try main_row.appendChild(cx.allocator, content_stack);
    const help_overlay = try ui.box(cx, .{
        .position = .absolute,
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.rgba(236, 255, 244, 102),
        .z_index = 250,
    }, .{});
    try help_overlay.appendChild(cx.allocator, try @import("ui/command_help_view.zig").mountCard(cx));
    help_overlay.setDisplay(.none);
    try terminal_area.appendChild(cx.allocator, help_overlay);
    nav_host.help_overlay = help_overlay;
    try root.appendChild(cx.allocator, main_row);

    const title_bar = try mountTitleBar(cx, scope, p, settings_host, workspace, ai_host, nav_host);
    try root.insertChildBefore(cx.allocator, title_bar, main_row);
    try root.insertChildBefore(cx.allocator, settings_panel, main_row);
    ai_host.strip = try @import("ui/ai_strip_view.zig").View.mount(cx, scope, cx.on(AiHost, ai_host, AiHost.openFromStrip));
    ai_host.dock_titlebar = title_bar;
    try root.appendChild(cx.allocator, ai_host.strip.?.root);
    try root.appendChild(cx.allocator, ai_panel);
    try root.insertChildBefore(cx.allocator, quick_panel, main_row);
    try root.insertChildBefore(cx.allocator, menu_popover.wrapper, main_row);
    try root.insertChildBefore(cx.allocator, history_panel, main_row);

    const status_bar = try mountStatusBar(cx, scope, p, status_text);
    // The workspace routes live grid dimensions into this label.
    workspace.grid_node = status_bar.grid;
    nav_host.session_details = status_bar.details;
    nav_host.socks_chip = status_bar.socks_chip;
    nav_host.status_bar = status_bar.bar;
    try status_bar.bar.insertChildBefore(cx.allocator, collapsed_sidebar.root, if (status_bar.bar.children.items.len != 0) status_bar.bar.children.items[0] else null);
    try root.appendChild(cx.allocator, status_bar.bar);
    const theme_picker = try @import("ui/status_theme_view.zig").View.mount(cx, scope, &settings_host.registry, .{ .context = nav_host, .select = AppNavHost.selectGlobalTheme, .manage = AppNavHost.manageGlobalThemes, .busy = AppNavHost.globalThemeBusy });
    nav_host.status_theme_view = theme_picker;
    try background_view.isolate(theme_picker.scope, theme_picker.chrome);
    try root.appendChild(cx.allocator, theme_picker.root);
    menu_host.global_theme_context = nav_host;
    menu_host.global_theme = AppNavHost.showThemeFromMenu;
    const local_status = try @import("ui/local_status_view.zig").View.mount(cx, scope, .{ .context = nav_host, .detail = AppNavHost.showLocalStatusDetail, .theme = AppNavHost.showGlobalTheme });
    local_status.root.setDisplay(.none);
    nav_host.local_status_view = local_status;
    try root.appendChild(cx.allocator, local_status.root);
    const status_detail = try @import("ui/status_detail_view.zig").View.mount(cx, scope, .{ .context = nav_host, .theme = AppNavHost.showThemeFromMenu });
    nav_host.status_detail_view = status_detail;
    try background_view.isolate(status_detail.scope, status_detail.chrome);
    try root.appendChild(cx.allocator, status_detail.root);

    // ── 统一传输呈现：进程任务域 + 面板 + 进度行 ──────────
    const transfer_host = try cx.allocator.create(TransferHost);
    const tasks = application_host.domain.tasks orelse return error.TaskDomainUnavailable;
    transfer_host.* = .{
        .allocator = tasks.allocator,
        .cx = cx,
        .workspace = workspace,
        .panel = undefined,
        .tasks = tasks,
        .dispatch = &tasks.dispatch,
        .application = application_host,
        .files = file_application,
        .settings = settings_host,
        .manager = &tasks.manager,
        .retained_store = &tasks.retained_store,
    };
    try scope.onCleanup(TransferHost, transfer_host, TransferHost.cleanup);
    const tp_root = try transfer_host.panel_mounted(cx, scope);
    try background_view.isolate(transfer_host.panel.scope, transfer_host.panel.card);
    try root.appendChild(cx.allocator, tp_root);
    transfer_host.progress_slot = status_bar.progress_slot;
    const ticker = try @import("ui/status_transfer_view.zig").View.mount(cx, scope, cx.on(TransferHost, transfer_host, TransferHost.showCurrentTransfers));
    transfer_host.status_transfer = ticker;
    try status_bar.progress_slot.appendChild(cx.allocator, ticker.root);
    const session_tasks = try transfer_manager_view.mount(cx, scope, transfer_host.manager, .{ .context = transfer_host, .action = TransferHost.managerAction, .scope_choices = TransferHost.transferScopeChoices, .owner = TransferHost.jobOwner, .owner_label = TransferHost.jobOwnerLabel, .can_reveal = TransferHost.canReveal, .open_sftp = TransferHost.requestSessionSftp, .open_manager = TransferHost.requestGlobalManager });
    transfer_host.session_panel = session_tasks;
    session_tasks.root.meta.ownership.meta.test_id = "transfer.session";
    session_tasks.setAnchor(ticker.root);
    try background_view.isolate(session_tasks.scope, session_tasks.root);
    try root.appendChild(cx.allocator, session_tasks.root);
    nav_host.transfer_host = transfer_host;
    menu_host.transfer_host = transfer_host;
    file_application.setTransferHandler(.{ .context = transfer_host, .submit = TransferHost.showFileTransfer, .confirm = TransferHost.confirmFileTransfer, .export_start = TransferHost.exportFileTransfer, .export_poll = TransferHost.pollFileExport, .export_cancel = TransferHost.cancelFileExport });
    const download_list = try transfer_manager_view.mountGlobalPopover(cx, scope, transfer_host.manager, .{ .context = transfer_host, .action = TransferHost.managerAction, .owner = TransferHost.jobOwner, .owner_label = TransferHost.jobOwnerLabel, .scope_choices = TransferHost.transferScopeChoices, .can_reveal = TransferHost.canReveal });
    transfer_host.manager_panel = download_list;
    try background_view.isolate(download_list.scope, download_list.root);
    transfer_host.conflict_view = try transfer_conflict_view.View.mount(cx, scope, .{ .context = transfer_host, .decision = TransferHost.conflictDecision, .defer_conflict = TransferHost.deferConflict });
    try background_view.isolate(scope, transfer_host.conflict_view.?.dialog);
    if (nav_host.transfer_anchor) |anchor| download_list.setAnchor(anchor);
    try root.appendChild(cx.allocator, download_list.root);
    try cx.addAfterLayoutHook(transfer_host, TransferHost.hookRun);

    if (process_notifications) |notifications| {
        const notification_hook = try NotificationWindowHook.mount(cx, scope, notifications, workspace, settings_host, nav_host, transfer_host);
        settings_host.notification_window = notification_hook.id;
        ai_host.notification_window = notification_hook.id;
        workspace.setNotificationAttentionBridge(.{ .context = notification_hook, .has_dot = NotificationWindowHook.hasDot });
    }

    // ── SOCKS5 动态转发：chip 开关 + 独立连接 ────────────────────────
    const socks_host = try cx.allocator.create(Socks5Host);
    socks_host.* = try Socks5Host.init(cx.allocator, cx, workspace, application_host, data_paths.known_hosts);
    socks_host.bindAuthentication();
    socks_host.chip_label = status_bar.socks_label;
    socks_host.chip = status_bar.socks_chip;
    const socks_info = try @import("ui/socks_info_view.zig").mount(cx, scope, .{ .context = @ptrCast(socks_host), .action = Socks5Host.infoAction });
    socks_host.info = socks_info;
    try background_view.isolate(socks_info.scope, socks_info.root);
    if (!socks_info.portaled) try root.appendChild(cx.allocator, socks_info.wrapper);
    const socks_config = try @import("ui/socks_config_view.zig").View.mount(cx, scope, .{
        .context = @ptrCast(socks_host),
        .save = Socks5Host.saveConfig,
        .test_cb = Socks5Host.testConfig,
        .cancel = Socks5Host.cancelConfig,
        .confirm_exposure = Socks5Host.confirmExposure,
    });
    socks_host.config = socks_config;
    if (!socks_config.portaled) try root.appendChild(cx.allocator, socks_config.root);
    const exposure = try @import("ui/socks_exposure_confirm.zig").View.mount(cx, scope, .{ .context = @ptrCast(socks_host), .confirm = Socks5Host.exposureConfirmed, .cancel = Socks5Host.exposureCancelled });
    socks_host.exposure = exposure;
    if (!exposure.portaled) try root.appendChild(cx.allocator, exposure.root);
    nav_host.socks_host = socks_host;
    status_bar.socks_chip.behavior.events.on_click = .{ .callback = onSocksChipClick, .context = @ptrCast(socks_host) };
    try scope.onCleanup(Socks5Host, socks_host, Socks5Host.cleanup);
    try cx.addAfterLayoutHook(socks_host, Socks5Host.hookRun);
    const background_socks = try @import("ui/socks_background_host.zig").Host.mount(cx, scope, workspace, application_host, socks_host.backend);
    menu_host.background_socks = background_socks;
    try status_bar.bar.insertChildBefore(cx.allocator, background_socks.view.remote_entry, status_bar.controls.theme_button);
    try local_status.root.insertChildBefore(cx.allocator, background_socks.view.local_entry, local_status.theme_button);
    try root.appendChild(cx.allocator, background_socks.view.popover.wrapper);
    if (!background_socks.exposure.portaled) try root.appendChild(cx.allocator, background_socks.exposure.root);
    try background_view.isolate(background_socks.view.popover.scope, background_socks.view.popover.chrome);
    try background_view.isolate(background_socks.exposure.scope, background_socks.exposure.card);
    try background_view.isolate(exposure.scope, exposure.card);
    try background_view.isolate(socks_config.scope, socks_config.card);
    try socks_config.bindMaterial(background_view);

    // 新建连接向导：bindState 存活至 Cx 销毁；on_result 由 WizardHost 处理
    // （.saved → Draft 深拷贝转 HostConfig 存盘 + 建连；.cancelled → 忽略）。
    const wiz = try cx.bindState(wizard_mod.Wizard, .{});
    const wiz_host = try cx.allocator.create(WizardHost);
    wiz_host.* = .{ .allocator = cx.allocator, .workspace = workspace, .wizard = wiz, .application_host = application_host, .cx_ptr = cx, .probe_controller = @import("ui/wizard_probe.zig").Controller.init(cx.allocator, &application_host.sessions.journal) };
    wiz.setRegistry(application_host.registry());
    wiz.connection_configs = @import("host/connection_config_resolver.zig").Resolver.init(&workspace.registry);
    wiz.on_envelope = WizardHost.submitEnvelope;
    wiz.envelope_context = wiz_host;
    wiz.on_editor_mounted = WizardHost.configureEditor;
    wiz.editor_mounted_context = wiz_host;
    try root.appendChild(cx.allocator, try wiz.mount(cx, scope));
    if (wiz.modal) |dialog| try background_view.isolate(wiz.scope, dialog);
    const child_editor = try @import("ui/plugin_editor_host.zig").Host.mount(cx, scope, wiz, application_host.registry(), .{ .context = wiz_host, .save = WizardHost.saveEnvelope });
    try root.appendChild(cx.allocator, child_editor.root);
    if (child_editor.host.child.modal) |dialog| try background_view.isolate(child_editor.host.child.scope, dialog);
    try wiz_host.refreshAssets();
    try scope.onCleanup(WizardHost, wiz_host, WizardHost.cleanup);
    try cx.addAfterLayoutHook(wiz_host, WizardHost.hookRun);
    nav_host.wizard = wiz;
    nav_host.wizard_host = wiz_host;
    nav_host.menu_host = menu_host;
    menu_host.wizard = wiz;
    menu_host.wizard_host = wiz_host;
    if (nav_host.chrome.sidebar_search_input) |input| menu_host.sidebar_search_value = input.value;
    nav_host.connection_host = try @import("ui/connection_host.zig").Host.mount(cx, scope, workspace, application_host);
    try background_view.isolate(nav_host.connection_host.?.progress.scope, nav_host.connection_host.?.progress.dialog);
    nav_host.probe_connection_host = try @import("ui/probe_connection_host.zig").Host.mount(cx, scope, &wiz_host.probe_controller, wiz, wiz.authentication_area);
    wiz_host.probe_presentation = nav_host.probe_connection_host;
    menu_host.asset_action_view = try @import("ui/asset_action_view.zig").View.mount(cx, scope, .{ .context = menu_host, .submit = MenuHost.submitAssetAction, .anchor = MenuHost.assetActionAnchor, .completed = MenuHost.assetActionCompleted, .close = MenuHost.assetActionClosed, .view_group = MenuHost.viewAssetGroup, .view_sessions = MenuHost.viewAssetSessions });
    try background_view.isolate(menu_host.asset_action_view.?.scope, menu_host.asset_action_view.?.dialog);
    const details_host = try @import("ui/connection_details_host.zig").Host.mount(cx, scope, workspace, application_host, status_bar.chain_trigger, status_bar.chain_icon, status_bar.chain_hover, status_bar.bar);
    details_host.bindEditor(wiz_host, WizardHost.openCapturedAsset);
    details_host.bindStatus(status_bar.controls, nav_host, AppNavHost.showGlobalTheme);
    nav_host.connection_details_host = details_host;
    try details_host.view.setMaterial(background_view);
    try background_view.isolate(details_host.logs.scope, details_host.logs.dialog);
    try background_view.isolate(details_host.ssh_status.info.scope, details_host.ssh_status.info.chrome);
    try background_view.isolate(details_host.ssh_status.detail.scope, details_host.ssh_status.detail.chrome);
    nav_host.asset_group_host = try @import("ui/asset_group_host.zig").Host.mount(cx, scope, workspace, .{ .context = wiz_host, .open = WizardHost.openInAssetGroup });
    try background_view.isolate(scope, nav_host.asset_group_host.?.view.dialog);
    try cx.addAfterLayoutHook(nav_host, AppNavHost.hookRun);
    return root;
}

/// Draft is borrowed during the callback; persistence and async work own copies.
fn hostFromDraft(draft: wizard_mod.Draft) !hosts_mod.HostConfig {
    return draft.toHostConfig();
}

fn freeDraft(allocator: std.mem.Allocator, draft: wizard_mod.Draft) void {
    var owned = draft;
    owned.deinit(allocator);
}

fn onWizardResultTrampoline(ctx: *anyopaque, result: wizard_mod.Result) anyerror!?wizard_mod.SaveReceipt {
    const self: *WizardHost = @ptrCast(@alignCast(ctx));
    return self.onWizardResult(result);
}

const WizardHost = struct {
    allocator: std.mem.Allocator,
    workspace: *ws.Workspace,
    wizard: *wizard_mod.Wizard,
    application_host: *application_host_mod.ApplicationHost,
    cx_ptr: *ui.Cx,
    assets: []wizard_mod.Draft = &.{},
    edit_host_index: ?usize = null,
    selected_group: ?@import("config/asset_actions.zig").GroupRef = null,

    probe_library: ?ssh_session.Library = null,
    probe_controller: @import("ui/wizard_probe.zig").Controller,
    probe_presentation: ?*@import("ui/probe_connection_host.zig").Host = null,

    fn configureEditor(raw: *anyopaque, instance: @import("host/plugin_ui_contract.zig").EditorInstance) !void {
        const self: *WizardHost = @ptrCast(@alignCast(raw));
        const state = remote_editor.fromInstance(instance) orelse return;
        state.on_result = onWizardResultTrampoline;
        state.result_context = self;
        state.editor.on_test = startProbe;
        state.editor.test_ctx = self;
        state.editor.setSshDefaults(self.workspace.app_config.ssh.connect_timeout_sec, self.workspace.app_config.ssh.keepalive_sec);
        state.editor.setScrollbackDefault(self.workspace.app_config.ui.scrollback_limit);
        try state.editor.setAssets(self.assets);
        try self.installEditorGroups(&state.editor);
    }

    fn submitEnvelope(raw: *anyopaque, value: @import("config/connection_envelope.zig").Envelope, intent: @import("host/plugin_ui_contract.zig").SubmitIntent) !void {
        const self: *WizardHost = @ptrCast(@alignCast(raw));
        const manifest = self.application_host.registry().find(value.protocol_id) orelse return error.UnknownPlugin;
        const contribution = manifest.connection orelse return error.ConnectionEditorUnavailable;
        try value.validate();
        if (value.payload_version != contribution.payload_version) return error.UnsupportedPayloadVersion;
        try contribution.validate_payload(value.payload);
        if (intent == .probe) return error.ProbeUnsupported;
        if (intent == .temporary) {
            if (contribution.create_kind != .saved_or_temporary) return error.SaveRequired;
            _ = try self.application_host.openEnvelope(value, try self.application_host.dispatcher.issue());
            return;
        }
        const owner = try saveEnvelope(self, value);
        if (intent == .save_and_open) {
            var saved = value;
            saved.id = owner.id;
            saved.revision = owner.revision;
            _ = self.application_host.openEnvelope(saved, try self.application_host.dispatcher.issue()) catch |err| {
                // The asset transaction has committed. A failed connection must
                // leave one saved asset, rather than invite another save.
                self.workspace.statusFailure(@errorName(err));
                applog.warn(.ui, "saved plugin connection open: {s}", .{@errorName(err)});
                return;
            };
        }
    }

    fn saveEnvelope(raw: *anyopaque, value: @import("config/connection_envelope.zig").Envelope) !@import("host/identity.zig").AssetOwner {
        const self: *WizardHost = @ptrCast(@alignCast(raw));
        const manifest = self.application_host.registry().find(value.protocol_id) orelse return error.UnknownPlugin;
        const contribution = manifest.connection orelse return error.ConnectionEditorUnavailable;
        try value.validate();
        if (value.payload_version != contribution.payload_version) return error.UnsupportedPayloadVersion;
        try contribution.validate_payload(value.payload);
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const record = try @import("config/connection_envelope.zig").toHostConfig(arena.allocator(), value);
        const expected: ?@import("host/identity.zig").AssetOwner = if (@backingInt(value.id) == 0) null else .{ .id = value.id, .revision = value.revision };
        const owner = try self.commitHost(expected, record);
        self.edit_host_index = null;
        self.workspace.rebuildSidebar() catch |err| applog.warn(.ui, "saved plugin asset sidebar refresh: {s}", .{@errorName(err)});
        return owner;
    }

    fn openInAssetGroup(raw: *anyopaque, reference: ?@import("config/asset_actions.zig").GroupRef) !void {
        const self: *WizardHost = @ptrCast(@alignCast(raw));
        if (self.wizard.isVisible()) return error.WizardAlreadyOpen;
        var group_name: ?[]const u8 = null;
        if (reference) |group| {
            const index = self.workspace.registry.groupIndex(group.id) orelse return error.StaleGroup;
            const current = self.workspace.registry.groups[index];
            if (current.revision != group.revision) return error.StaleGroup;
            group_name = current.name;
        }
        try self.refreshAssets();
        self.edit_host_index = null;
        self.selected_group = reference;
        try remote_editor.loadDraft(self.wizard, .{ .group = group_name });
        self.wizard.show();
    }

    fn openCapturedAsset(raw: *anyopaque, owner: @import("host/identity.zig").AssetOwner) !void {
        const self: *WizardHost = @ptrCast(@alignCast(raw));
        // An existing draft must be dismissed explicitly before replacing it.
        if (self.wizard.isVisible()) return error.WizardAlreadyOpen;
        _ = try self.workspace.registry.get(owner);
        const index = self.workspace.registry.indexOf(owner.id) orelse return error.StaleAsset;
        try self.refreshAssets();
        self.edit_host_index = index;
        self.selected_group = null;
        const record = self.workspace.registry.hosts[index];
        const manifest = self.application_host.registry().find(record.protocolId()) orelse return error.UnknownPlugin;
        _ = manifest.connection orelse return error.ConnectionEditorUnavailable;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        try self.wizard.loadEnvelope(try @import("config/connection_envelope.zig").fromLegacy(arena.allocator(), record));
        self.wizard.show();
    }

    fn startProbe(raw: *anyopaque, draft: *const wizard_mod.Draft) void {
        const self: *WizardHost = @ptrCast(@alignCast(raw));
        self.probe_controller.cancelAll();
        const editor = remote_editor.editor(self.wizard) orelse return;
        if (self.probe_library == null) self.probe_library = ssh_session.Library.init() catch {
            editor.setTestResult(.{ .fail = "SSH 库初始化失败" });
            return;
        };
        _ = self.probe_controller.start(draft.*, self.workspace.registry.hosts, self.workspace.app_config.*, editor.test_generation, &self.probe_library.?) catch |err| {
            editor.setTestResult(.{ .fail = @errorName(err) });
            return;
        };
        self.cx_ptr.requestRedraw();
    }

    fn releaseAssets(self: *WizardHost, assets: []wizard_mod.Draft) void {
        for (assets) |*asset| asset.deinit(self.allocator);
        if (assets.len > 0) self.allocator.free(assets);
    }

    fn installEditorGroups(self: *WizardHost, editor: *@import("plugins/remote/editor.zig").RemoteEditor) !void {
        const names = try self.allocator.alloc([]const u8, self.workspace.registry.groups.len);
        defer self.allocator.free(names);
        for (self.workspace.registry.groups, 0..) |group, index| names[index] = group.name;
        try editor.setGroups(names);
    }

    fn refreshAssets(self: *WizardHost) !void {
        if (remote_editor.editor(self.wizard)) |editor| {
            editor.setSshDefaults(self.workspace.app_config.ssh.connect_timeout_sec, self.workspace.app_config.ssh.keepalive_sec);
            editor.setScrollbackDefault(self.workspace.app_config.ui.scrollback_limit);
        }
        const next = try remote_editor.projectAssets(self.allocator, self.workspace.registry.hosts);
        errdefer self.releaseAssets(next);
        // Install the replacement before freeing slices borrowed by the wizard.
        if (remote_editor.editor(self.wizard)) |editor| {
            try editor.setAssets(next);
            try self.installEditorGroups(editor);
        }
        self.releaseAssets(self.assets);
        self.assets = next;
    }

    fn assetsCurrent(self: *WizardHost) bool {
        return remote_editor.assetsCurrent(self.assets, self.workspace.registry.hosts);
    }

    fn hookRun(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *WizardHost = @ptrCast(@alignCast(raw));
        if (self.probe_presentation) |presentation| presentation.presentProgress() catch |err| {
            applog.warn(.ui, "connection test progress unavailable: {s}", .{@errorName(err)});
        };
        var index: usize = 0;
        while (index < self.probe_controller.jobs.items.len) {
            const job = self.probe_controller.jobs.items[index];
            const state = self.probe_controller.poll(job) catch |err| {
                applog.warn(.ui, "connection test result pending: {s}", .{@errorName(err)});
                index += 1;
                continue;
            };
            switch (state) {
                .pending => {
                    if (remote_editor.editor(self.wizard)) |editor| {
                        if (job.generation != editor.test_generation) job.cancel();
                    } else job.cancel();
                    index += 1;
                },
                .finished => |outcome| {
                    if (self.probe_presentation) |presentation| presentation.presentJob(job) catch |err| {
                        applog.warn(.ui, "connection final test presentation: {s}", .{@errorName(err)});
                    };
                    var buffer: [160]u8 = undefined;
                    const message = if (outcome.failure) |failure| @errorName(failure) else std.fmt.bufPrint(&buffer, "连接成功 · {d} ms", .{outcome.elapsed_ms}) catch "连接成功";
                    if (remote_editor.editor(self.wizard)) |editor| _ = editor.setTestResultForDraft(outcome.generation, outcome.draft_id, outcome.draft_revision, if (outcome.failure != null) .{ .fail = message } else .{ .ok = message });
                    self.probe_controller.retire(job) catch |err| {
                        applog.warn(.ui, "connection test cleanup pending: {s}", .{@errorName(err)});
                        index += 1;
                    };
                },
            }
        }
        if (self.probe_controller.jobs.items.len != 0) self.cx_ptr.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        if (self.assetsCurrent()) return .done;
        self.refreshAssets() catch |err| {
            applog.warn(.ui, "wizard assets refresh failed: {s}", .{@errorName(err)});
            return .done;
        };
        return .needs_layout;
    }

    fn cleanup(self: *WizardHost) void {
        self.cx_ptr.removeAfterLayoutHook(self);
        self.probe_controller.deinit();
        if (self.probe_library) |*library| library.deinit();
        if (remote_editor.editor(self.wizard)) |editor| editor.assets = &.{};
        self.releaseAssets(self.assets);
        self.allocator.destroy(self);
    }

    fn onWizardResult(self: *WizardHost, result: wizard_mod.Result) !?wizard_mod.SaveReceipt {
        switch (result) {
            .cancelled => {
                self.probe_controller.cancelAll();
                self.edit_host_index = null;
                self.selected_group = null;
                return null;
            },
            .save_only => |draft| {
                const owned = try draft.dupe(self.allocator);
                defer freeDraft(self.allocator, owned);
                const host = try owned.toPersistentHostConfig();
                const owner = try self.commitHost(owned.source_owner, host);
                self.edit_host_index = null;
                self.workspace.rebuildSidebar() catch |err| applog.warn(.ui, "saved host sidebar refresh failed: {s}", .{@errorName(err)});
                return .{ .owner = owner };
            },
            .saved => |draft| {
                const owned = try draft.dupe(self.allocator);
                defer freeDraft(self.allocator, owned);
                return try self.connectDraft(owned);
            },
        }
    }

    fn connectDraft(self: *WizardHost, draft: wizard_mod.Draft) !wizard_mod.SaveReceipt {
        const host = try draft.toHostConfig();
        const owner = try self.commitHost(draft.source_owner, try draft.toPersistentHostConfig());
        // Persistence already succeeded. A subsequent retry targets this
        // receipt's asset rather than appending another copy of the draft.
        self.edit_host_index = null;
        self.workspace.rebuildSidebar() catch |err| applog.warn(.ui, "saved host sidebar refresh failed: {s}", .{@errorName(err)});
        self.workspace.newSessionWithCredentials(owner, host.password, host.key_passphrase) catch |err| {
            applog.warn(.ui, "saved connection open failed: {s}", .{@errorName(err)});
            return .{ .owner = owner, .open_failure = err };
        };
        return .{ .owner = owner };
    }

    fn commitHost(self: *WizardHost, expected: ?@import("host/identity.zig").AssetOwner, host: hosts_mod.HostConfig) !@import("host/identity.zig").AssetOwner {
        try self.workspace.identities.appendHosts(self.allocator, self.workspace.registry.hosts.len);
        if (expected == null) try self.workspace.identities.hosts.ensureTotalCapacity(self.allocator, self.workspace.registry.hosts.len + 1);
        var transaction = try @import("config/store.zig").HostsTransaction.init(self.allocator, &self.workspace.registry);
        defer transaction.deinit();
        const candidate = &transaction.candidate.?;
        var persistent = host;
        if (self.selected_group) |reference| {
            const index = candidate.groupIndex(reference.id) orelse return error.StaleGroup;
            const group = candidate.groups[index];
            if (group.revision != reference.revision) return error.StaleGroup;
            if (std.mem.eql(u8, persistent.group orelse "", group.name)) persistent.asset_group_id = group.group_id;
        }
        // Login-password persistence is explicitly selected by the editor.
        // The host transaction stores it in Keychain and writes only a ref.
        persistent.key_passphrase = null;
        persistent.totp_secret = null;
        const owner = if (expected) |baseline| blk: {
            const previous = try candidate.get(baseline);
            var value = persistent;
            value.pinned = previous.pinned;
            value.ts_default = previous.ts_default;
            value.unknown_fields = previous.unknown_fields;
            value.unknown_options = previous.unknown_options;
            value.unknown_auth = previous.unknown_auth;
            value.asset_group_id = if (std.mem.eql(u8, value.group orelse "", previous.group orelse "")) previous.asset_group_id else null;
            break :blk try candidate.update(baseline, value);
        } else try candidate.add(persistent);
        try transaction.commit(self.workspace.io, std.Io.Dir.cwd(), self.workspace.hosts_path, &self.workspace.registry);
        self.selected_group = null;
        self.workspace.identities.appendHosts(self.allocator, self.workspace.registry.hosts.len) catch unreachable;
        return owner;
    }
};

/// Window presentation borrows task services; providers own native transfers.
/// （执行）。独立模式使用无 shell 的专用 Runtime；共享模式把 SFTP
/// 请求交回原 SSH Worker 的邮箱，原 Worker 是唯一 native IO owner。
const NotificationWindowHook = struct {
    host: *NotificationHost,
    cx: *ui.Cx,
    workspace: *ws.Workspace,
    settings: *SettingsHost,
    nav: *AppNavHost,
    transfer: *TransferHost,
    id: @import("host/notification_host.zig").WindowId,
    was_active: bool = false,

    fn mount(cx: *ui.Cx, scope: *ui.Scope, host: *NotificationHost, workspace: *ws.Workspace, settings: *SettingsHost, nav: *AppNavHost, transfer: *TransferHost) !*NotificationWindowHook {
        const self = try cx.allocator.create(NotificationWindowHook);
        self.* = .{ .host = host, .cx = cx, .workspace = workspace, .settings = settings, .nav = nav, .transfer = transfer, .id = undefined };
        self.id = host.registerWindow(.{ .context = self, .owns = owns, .activate = activate, .feedback = feedback, .owner_name = ownerName, .result_presented = resultPresented, .transfer_presented = transferPresented }) catch |err| {
            cx.allocator.destroy(self);
            return err;
        };
        scope.onCleanup(NotificationWindowHook, self, cleanup) catch |err| {
            host.removeWindow(self.id);
            cx.allocator.destroy(self);
            return err;
        };
        if (nav.notification_anchor) |trigger| _ = try @import("ui/notification_history.zig").View.mount(cx, scope, host, trigger);
        workspace.status_feedback = .{ .context = self, .publish = publishStatus };
        if (nav.application_host) |application| application.file_failure = .{ .context = self, .publish = publishFileFailure };
        try cx.addAfterLayoutHook(self, run);
        return self;
    }
    fn painted(node: *ui.Node) bool {
        if (node.globalRect().w <= 0 or node.globalRect().h <= 0) return false;
        var ancestor: ?*ui.Node = node;
        while (ancestor) |value| : (ancestor = value.parent) {
            if (value.style.display == .none or value.isPaintSkipped()) return false;
        }
        return true;
    }
    fn ownerName(raw: *anyopaque, owner: @import("host/identity.zig").ContentOwner) []const u8 {
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw));
        for (self.workspace.tabs.items) |tab| if (tab.content_owner.eql(owner)) return tab.titleSlice();
        return "原会话已关闭";
    }
    fn resultPresented(raw: *anyopaque, kind: @import("host/notification_coordinator.zig").Kind, owner: @import("host/identity.zig").ContentOwner) bool {
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw));
        if (!self.cx.window_active) return false;
        if (kind == .ai_ready) {
            const ai = self.nav.ai orelse return false;
            const request_owner = ai.request_content_owner orelse return false;
            return request_owner.eql(owner) and ai.controller.model.visible and ai.controller.model.expanded and painted(ai.panel) and
                ai.request_conversation != null and ai.request_conversation == ai.display_conversation and
                ai.request_owner != null and ai.display_owner != null and std.meta.eql(ai.request_owner.?, ai.display_owner.?);
        }
        if (kind == .reconnect) for (self.workspace.tabs.items) |tab| {
            if (tab.content_owner.eql(owner) and painted(tab.root)) return true;
        };
        return false;
    }
    fn transferPresented(raw: *anyopaque, job: u64) bool {
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw));
        if (!self.cx.window_active) return false;
        if (self.transfer.manager_panel) |panel| if (painted(panel.root) and panel.presents(job)) return true;
        if (self.transfer.session_panel) |panel| if (painted(panel.root) and panel.presents(job)) return true;
        for (self.workspace.tabs.items) |tab| for (tab.transfer_trays) |tray| {
            if (tray) |panel| if (painted(panel.root) and panel.presents(job)) return true;
        };
        return false;
    }
    fn publishFileFailure(raw: *anyopaque, owner: @import("host/identity.zig").SessionHandle, message: []const u8) void {
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw));
        self.host.publishFeedbackSeverity(self.id, .{ .session = owner }, message, .failure) catch |err| applog.warn(.ui, "file creation failure notification: {s}", .{@errorName(err)});
        self.cx.requestRedraw();
    }
    fn publishStatus(raw: *anyopaque, owner: ?@import("host/identity.zig").ContentOwner, message: []const u8, kind: ws.Workspace.StatusKind) void {
        if (kind != .failure) return;
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw));
        const source = owner orelse return;
        self.host.publishFeedbackSeverity(self.id, source, message, .failure) catch |err| applog.warn(.ui, "failure feedback: {s}", .{@errorName(err)});
    }
    fn cleanup(self: *NotificationWindowHook) void {
        self.cx.removeAfterLayoutHook(self);
        self.workspace.setNotificationAttentionBridge(.{});
        self.workspace.status_feedback = null;
        if (self.nav.application_host) |application| application.file_failure = null;
        self.host.removeWindow(self.id);
        self.cx.allocator.destroy(self);
    }
    fn hasDot(raw: ?*anyopaque, owner: @import("host/identity.zig").ContentOwner) bool {
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw orelse return false));
        return self.host.coordinator.hasDot(owner);
    }
    fn owns(raw: *anyopaque, target: @import("host/notification_coordinator.zig").Target) bool {
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw));
        if (target.kind == .transfer_done) for (self.transfer.tasks.job_owners.items) |job| {
            if (job.job == target.operation_id and target.owner.eql(.{ .session = job.owner })) return true;
        };
        for (self.workspace.tabs.items) |tab| if (tab.content_owner.eql(target.owner)) return true;
        return false;
    }
    fn activate(raw: *anyopaque, target: @import("host/notification_coordinator.zig").Target) bool {
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw));
        if (self.workspace.shutting_down) return false;
        if (target.kind == .transfer_done) for (self.transfer.tasks.job_owners.items) |job| {
            if (job.job != target.operation_id or !target.owner.eql(.{ .session = job.owner })) continue;
            if (self.transfer.manager_panel) |panel| {
                panel.refresh(wallClockMsTransfer(), .{ .window_chunks = self.workspace.app_config.transfer.window_chunks, .chunk_kb = self.workspace.app_config.transfer.chunk_kb }) catch return false;
                panel.show();
                self.transfer.manager_visible = true;
                if (self.nav.app_runtime) |app| app.win.activate();
                self.cx.requestRedraw();
                return true;
            }
        };
        for (self.workspace.tabs.items, 0..) |tab, index| {
            if (!tab.content_owner.eql(target.owner) or tab.closing) continue;
            self.workspace.selectTab(index);
            if (self.nav.app_runtime) |app| app.win.activate();
            if (target.kind == .ai_ready) if (self.nav.ai) |ai| if (!ai.controller.model.visible) ai.toggle();
            self.cx.requestRedraw();
            return true;
        }
        return false;
    }
    fn feedback(raw: *anyopaque, message: []const u8) void {
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw));
        if (self.workspace.shutting_down) return;
        if (self.settings.open and self.settings.controller.model.page_index == 6) self.settings.refresh(message) else self.workspace.status(message);
        self.cx.requestRedraw();
    }
    fn observeReconnect(self: *NotificationWindowHook, tab: *ws.SessionTab) void {
        const runtime = tab.runtime orelse return;
        const state = runtime.reconnectSnapshot() orelse return;
        const key = state.key orelse return;
        if (key.owner != .session or !tab.content_owner.eql(.{ .session = key.owner.session }) or key.attempt_id == null) return;
        if (state.phase == .active and key.attempt_id.? > 1) {
            self.host.publishReconnectDetails(tab.content_owner, key.operation_id, key.attempt_id.?, .recovered, .{ .object = tab.titleSlice() }) catch |err| applog.warn(.app, "reconnect notification: {s}", .{@errorName(err)});
        } else if ((state.phase == .waiting or state.phase == .releasing) and state.failure != null) {
            self.host.publishReconnectDetails(tab.content_owner, key.operation_id, key.attempt_id.?, if (state.was_attached) .disconnected else .failed, .{ .object = tab.titleSlice(), .detail = @import("ui/connection_progress_view.zig").failureText(state.failure) }) catch |err| applog.warn(.app, "disconnect notification: {s}", .{@errorName(err)});
        }
    }
    fn run(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *NotificationWindowHook = @ptrCast(@alignCast(raw));
        if (self.workspace.shutting_down) return .done;
        if (self.cx.window_active and !self.was_active) self.host.refreshAuthorization() catch |err| {
            if (err != error.NotificationUnavailable) applog.warn(.app, "notification authorization refresh: {s}", .{@errorName(err)});
        };
        self.was_active = self.cx.window_active;
        const receipt = self.host.poll() catch |err| blk: {
            applog.warn(.app, "system notification receipt: {s}", .{@errorName(err)});
            break :blk @import("host/notification_host.zig").Poll{};
        };
        if (receipt.settings_changed and self.settings.open and self.settings.controller.model.page_index == 6) self.settings.pending_rebuild = true;
        const clock = @import("host/notification_host.zig").localClock() catch return .done;
        for (self.workspace.tabs.items, 0..) |tab, index| {
            if (tab.closing or tab.archived or tab.content_owner != .session or tab.terminal == null) continue;
            self.observeReconnect(tab);
            const terminal = if (tab.terminal) |*value| value else continue;
            const owner = tab.content_owner.session;
            const facts: @import("host/terminal_service.zig").NotificationSnapshot = if (terminal.terminal_surface) |surface| blk: {
                const status = surface.service.status() catch continue;
                if (!status.owner.eql(owner)) continue;
                break :blk status.notification();
            } else if (tab.runtime) |runtime| runtime.workerPtr().notificationSnapshot(owner) catch continue else continue;
            if (facts.output_sequence != 0) _ = self.host.coordinator.observeOutput(tab.content_owner, facts.output_sequence) catch false;
            if (facts.bell_count != 0) {
                const bell = self.host.coordinator.observeBell(tab.content_owner, facts.bell_count, clock) catch continue;
                if (!bell.duplicate and @import("platform/runtime_mode.zig").automation) std.debug.print("NOTIFICATION_BELL {{\"owner_id\":{d},\"owner_generation\":{d},\"sequence\":{d},\"duplicate\":{},\"disposition\":\"{s}\",\"failure\":\"{s}\"}}\n", .{ @backingInt(owner.session_id), owner.generation, facts.bell_count, bell.duplicate, @tagName(bell.sound.disposition), if (bell.sound.failure) |failure| @errorName(failure) else "" });
            }
            const visible = self.cx.window_active and self.workspace.active_tab == index and self.workspace.active_group_view == null and !self.settings.open and (if (self.nav.ai) |ai| !ai.controller.model.visible else true) and self.cx.focus_manager.getFocused() == terminal.root;
            if (visible) {
                if (terminal.notificationReadSequence(owner)) |sequence| {
                    if (sequence == facts.output_sequence) {
                        const read = self.host.coordinator.markRead(tab.content_owner, sequence, true);
                        if (read and @import("platform/runtime_mode.zig").automation) std.debug.print("NOTIFICATION_READ {{\"owner_id\":{d},\"owner_generation\":{d},\"through_sequence\":{d}}}\n", .{ @backingInt(owner.session_id), owner.generation, sequence });
                    }
                }
            }
        }
        self.workspace.refreshNotificationAttention();
        // Native callback threads only queue values. A bounded main-thread
        // wake-up drains receipts/clicks even when terminal output is idle.
        self.cx.scheduleRedrawAfterNs(250 * std.time.ns_per_ms);
        return .done;
    }
};

const TransferHost = struct {
    files: *file_application_mod.Host,
    tasks: *task_domain_mod.Domain,
    retained_store: *retained_store_mod.Store,
    dispatch: *transfer_dispatch_mod.Dispatch,
    application: *application_host_mod.ApplicationHost,
    file_binding: ?@import("host/session_host.zig").ServiceHandle = null,
    file_conflict_context: ?transfer_mod.Conflict.Context = null,
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    workspace: *ws.Workspace,
    panel: *transfer_panel_mod.Panel,
    manager: *transfer_mod.Manager,
    last_job: ?transfer_mod.JobId = null,
    /// 状态栏进度行容器（mountStatusBar 注入）。
    progress_slot: ?*ui.Node = null,
    /// 终态失败只报一次。
    failure_reported: std.atomic.Value(u8) = .init(0),
    settings: ?*SettingsHost = null,
    manager_panel: ?*transfer_manager_view.Panel = null,
    session_panel: ?*transfer_manager_view.Panel = null,
    status_transfer: ?*@import("ui/status_transfer_view.zig").View = null,
    transfer_preview: bool = false,
    transfer_pinned: bool = false,
    transfer_suppressed: bool = false,
    transfer_leave_ms: ?u64 = null,
    ticker_scope: ?transfer_manager_view.Scope = null,
    ticker_scope_arena: ?std.heap.ArenaAllocator = null,
    ticker_last_refresh_ms: u64 = 0,
    ticker_started_ms: u64 = 0,
    conflict_view: ?*transfer_conflict_view.View = null,
    conflict_job: ?transfer_mod.JobId = null,
    conflict_manual: bool = false,
    conflict_presented: bool = false,
    manager_visible: bool = false,
    manager_open_requested: bool = false,
    cwd_pending: ?struct { owner: @import("host/identity.zig").SessionHandle, started: u64 } = null,
    reveal_requested: ?struct { job: transfer_mod.JobId, attempt: u8, owner: @import("host/identity.zig").SessionHandle } = null,
    sftp_open_requested: bool = false,
    manager_last_refresh_ms: u64 = 0,
    session_id: ?ws.SessionId = null,
    session_owner: ?@import("host/identity.zig").SessionHandle = null,

    command_picker: ?CommandPicker = null,
    picker_running: bool = false,

    const CommandPicker = struct {
        owner: @import("host/identity.zig").SessionHandle,
        operation: @import("host/operation.zig").OperationKey,
        capability_revision: u64,
        command_id: ?u64,
        mode: transfer_panel_mod.Data.Mode,
        source: [:0]u8,
        started: u64,
    };

    extern fn zw_pick_upload_files(initial: [*:0]const u8, context: *anyopaque, receive: *const fn (*anyopaque, [*:0]const u8) callconv(.c) c_int) c_int;

    const PickedFiles = struct {
        allocator: std.mem.Allocator,
        paths: std.ArrayList([]const u8) = .empty,
        fn receive(raw: *anyopaque, path: [*:0]const u8) callconv(.c) c_int {
            const self: *PickedFiles = @ptrCast(@alignCast(raw));
            const owned = self.allocator.dupe(u8, std.mem.span(path)) catch return 0;
            self.paths.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                return 0;
            };
            return 1;
        }
        fn deinit(self: *PickedFiles) void {
            for (self.paths.items) |path| self.allocator.free(path);
            self.paths.deinit(self.allocator);
        }
    };

    fn finishPicker(self: *TransferHost, request: CommandPicker, state: TerminalViewNode.CommandRecordState, message: []const u8) void {
        if (request.command_id) |id| {
            for (self.workspace.tabs.items) |tab| {
                if (tab.terminal) |*terminal| if (terminal.commandRecordOwner()) |owner| {
                    if (owner.eql(request.owner)) {
                        _ = terminal.finishCommandRecord(owner, id, state, message);
                        self.cx.requestRedraw();
                        return;
                    }
                };
            }
        }
        self.workspace.status(message);
    }

    fn validatePicker(self: *TransferHost, request: CommandPicker) !void {
        const state = self.application.sessions.queryState(request.owner) orelse return error.TransferOwnerExpired;
        const capabilities = (try self.application.sessions.capabilitySnapshot(request.owner)) orelse return error.TransferOwnerExpired;
        if (state.lifecycle != .attached) return error.TransferSessionNotAttached;
        if (!state.create_operation.eql(request.operation)) return error.TransferOwnerExpired;
        if (capabilities.revision != request.capability_revision) return error.StaleCapabilityRevision;
        // The SSH transfer service is opened lazily after selection. Require
        // declaration and authorization here, not an already-open SFTP channel.
        const transfer_capability = for (capabilities.services) |service| {
            if (std.mem.eql(u8, service.key.name, "transfer")) break service;
        } else return error.TransferUnsupported;
        if (!transfer_capability.declared or !transfer_capability.authorized) return error.TransferNotAuthorized;
        const tab = self.workspace.sessionTab(self.application.legacyForHandle(request.owner) orelse return error.TransferOwnerExpired) orelse return error.TransferOwnerExpired;
        if (tab.closing or tab.archived or tab.failed or tab.runtime == null) return error.TransferOwnerExpired;
    }

    fn requestCommandTransfer(self: *TransferHost, index: usize, mode: transfer_panel_mod.Data.Mode, source: ?[]const u8) !void {
        if (self.command_picker != null or self.picker_running) return error.FileSelectionInProgress;
        const tab = self.workspace.tabs.items[index];
        const owner = switch (tab.content_owner) {
            .session => |value| value,
            else => return error.TransferOwnerExpired,
        };
        const state = self.application.sessions.queryState(owner) orelse return error.TransferOwnerExpired;
        const capabilities = (try self.application.sessions.capabilitySnapshot(owner)) orelse return error.TransferOwnerExpired;
        const request: CommandPicker = .{
            .owner = owner,
            .operation = state.create_operation,
            .capability_revision = capabilities.revision,
            .command_id = if (self.workspace.command_output) |terminal| terminal.active_command_record else null,
            .mode = mode,
            .source = try self.allocator.dupeSentinel(u8, source orelse "", 0),
            .started = wallClockMsTransfer(),
        };
        errdefer self.allocator.free(request.source);
        try self.validatePicker(request);
        try self.validateNewTransferPolicy();
        if (mode == .upload) try tab.runtime.?.workerPtr().requestCurrentDirectory();
        self.command_picker = request;
        self.finishPicker(request, .pending, if (mode == .upload) "正在读取上传目标目录…" else "等待选择下载保存位置…");
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }

    fn runCommandPicker(self: *TransferHost, request: CommandPicker, remote_dir: []const u8) !bool {
        try self.validatePicker(request);
        const policy = self.workspace.app_config.transfer;
        var files: PickedFiles = .{ .allocator = self.allocator };
        defer files.deinit();
        var buffer: [4096]u8 = undefined;
        var local_dir: []const u8 = "";
        if (request.mode == .upload) {
            const result = zw_pick_upload_files(request.source, &files, PickedFiles.receive);
            if (result < 0) return error.FileSelectionFailed;
            if (result == 0 or files.paths.items.len == 0) return false;
        } else {
            const sdk = self.cx.system_sdk orelse return error.NativeDialogUnavailable;
            const home = try @import("platform/account.zig").home(self.allocator);
            defer self.allocator.free(home);
            const initial = try @import("config/transfer_defaults.zig").downloadDirectory(self.allocator, policy.download_dir, home);
            defer self.allocator.free(initial);
            local_dir = (try sdk.runDialog(.{ .kind = .pick_folder, .title = "选择下载保存位置", .default_path = initial }, &buffer)) orelse return false;
        }
        // AppKit runs a nested event loop. Revalidate the captured session,
        // rather than using whichever tab happens to be active afterwards.
        try self.validatePicker(request);
        const sources: []const []const u8 = if (request.mode == .upload) files.paths.items else &.{request.source};
        const spec = try transfer_panel_mod.buildSpec(.{
            .mode = request.mode,
            .owner = request.owner,
            .sources = sources,
            .remote_dir = remote_dir,
            .local_dir = local_dir,
            .resume_transfer = policy.@"resume",
            .md5 = policy.verify_md5,
        });
        try self.submitSessionTransfer(request.owner, spec);
        return true;
    }

    fn pollCommandPicker(self: *TransferHost) void {
        const request = self.command_picker orelse return;
        self.validatePicker(request) catch |err| {
            self.command_picker = null;
            defer self.allocator.free(request.source);
            self.finishPicker(request, .failure, @errorName(err));
            return;
        };
        var cwd: ?[]u8 = null;
        defer if (cwd) |value| self.allocator.free(value);
        if (request.mode == .upload) {
            const tab = self.workspace.sessionTab(self.application.legacyForHandle(request.owner).?).?;
            cwd = tab.runtime.?.workerPtr().copyCwd(self.allocator) catch null;
            if (cwd == null or cwd.?.len == 0) {
                if (wallClockMsTransfer() -| request.started < 5000) {
                    self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
                    return;
                }
                self.command_picker = null;
                defer self.allocator.free(request.source);
                self.finishPicker(request, .failure, "无法读取当前远程目录，请在终端空闲时重新执行 @up");
                return;
            }
        }
        self.command_picker = null;
        defer self.allocator.free(request.source);
        self.picker_running = true;
        defer self.picker_running = false;
        const submitted = self.runCommandPicker(request, cwd orelse "") catch |err| {
            self.finishPicker(request, .failure, @errorName(err));
            return;
        };
        self.finishPicker(request, .success, if (!submitted) "已取消选择，未添加传输任务" else if (request.mode == .upload) "已加入上传队列" else "已加入下载队列");
    }

    const AuxiliaryConnection = task_domain_mod.AuxiliaryConnection;

    const SharedConnection = task_domain_mod.SharedConnection;

    fn ensureShared(self: *TransferHost, owner: @import("host/identity.zig").SessionHandle) !@import("host/session_host.zig").SharedTransferStart {
        for (self.tasks.shared_connections.items) |connection| if (connection.owner.eql(owner) and !connection.released) {
            if (!self.application.sessions.bindingIsLive(connection.binding)) return error.TransferNotReady;
            try self.files.mux.?.register(connection.binding, connection.service.engine());
            try self.files.mux.?.setCleanupGuard(connection.binding, connection.service.cleanupGuard());
            return .{ .binding = connection.binding, .key = connection.key };
        };
        try self.tasks.shared_connections.ensureUnusedCapacity(self.allocator, 1);
        const legacy = self.application.legacyForHandle(owner) orelse return error.TransferOwnerExpired;
        const tab = self.workspace.sessionTab(legacy) orelse return error.TransferOwnerExpired;
        const runtime = tab.runtime orelse return error.TransferOwnerExpired;
        if (runtime.torn_down) return error.TransferOwnerExpired;
        const start = try self.application.sessions.beginSharedTransfer(owner);
        const service = try runtime.workerPtr().transferService(start.binding);
        self.tasks.shared_connections.appendAssumeCapacity(.{ .owner = owner, .binding = start.binding, .key = start.key, .service = service });
        if (!self.application.sessions.sharedTransferReady(start.binding, start.key)) return error.StaleBinding;
        try self.files.mux.?.register(start.binding, service.engine());
        try self.files.mux.?.setCleanupGuard(start.binding, service.cleanupGuard());
        return start;
    }

    fn pollShared(self: *TransferHost) !void {
        for (self.tasks.shared_connections.items) |*connection| {
            if (connection.released) continue;
            if (connection.service.faulted.load(.acquire)) {
                _ = self.application.sessions.sharedTransferReleased(connection.binding, connection.key, .awaiting);
                if (connection.fault_retained) continue;
                if (try self.retainShared(connection, connection.key, true) == .released) connection.fault_retained = true;
            }
        }
    }

    fn ensureAuxiliary(self: *TransferHost, owner: @import("host/identity.zig").SessionHandle) !@import("host/session_host.zig").AuxiliaryTransferStart {
        try self.tasks.auxiliary_connections.ensureUnusedCapacity(self.allocator, 1);
        const start = try self.application.sessions.beginAuxiliaryTransfer(owner);
        var exists = false;
        for (self.tasks.auxiliary_connections.items) |connection| if (!connection.released and connection.binding.eql(start.binding)) {
            if (connection.closing) return error.CleanupNotReleased;
            exists = true;
            break;
        };
        if (!exists) {
            self.tasks.auxiliary_connections.appendAssumeCapacity(.{ .owner = owner, .binding = start.binding, .key = start.key });
            const hooks = self.files.transfer_host.?.hooks();
            hooks.start(hooks.context, .{ .binding = start.binding, .source = .{ .owner = owner, .create_key = start.key, .open_key = start.key, .spec = start.spec } }) catch |err| {
                self.tasks.auxiliary_connections.items[self.tasks.auxiliary_connections.items.len - 1].closing = true;
                return err;
            };
        }
        return start;
    }

    // Reject an invalid new policy before connection creation or authentication.
    // Retained resume uses the original frozen JobSpec and never enters here.
    fn validateNewTransferPolicy(self: *const TransferHost) !void {
        const policy = self.workspace.app_config.transfer;
        try @import("transfer/window_policy.zig").validateWindowPolicy(policy.chunk_kb, policy.window_chunks, policy.max_tasks);
    }

    fn submitSessionTransfer(self: *TransferHost, owner: @import("host/identity.zig").SessionHandle, spec: transfer_mod.JobSpec) !void {
        try self.validateNewTransferPolicy();
        try self.tasks.job_owners.ensureUnusedCapacity(self.allocator, 1);
        if (self.tasks.next_transfer_intent == std.math.maxInt(u64)) return error.IntentIdExhausted;
        const dedicated = self.workspace.app_config.transfer.dedicated_connection;
        const binding = if (dedicated) (try self.ensureAuxiliary(owner)).binding else (try self.ensureShared(owner)).binding;
        const original = self.application.sessions.queryState(owner) orelse return error.StaleSession;
        const remote: @import("transfer/conflict.zig").Endpoint = .{ .sftp = .{
            .binding_id = binding.binding_id,
            .binding_generation = binding.binding_generation,
            .resource_owner = binding.resource_owner,
            .origin_session = owner,
            .connection_snapshot_id = original.create_operation.operation_id,
        } };
        const local: @import("transfer/conflict.zig").Endpoint = .{ .local_fs = self.files.local_service.?.endpoint };
        var captured = spec;
        captured.chunk_kb = self.workspace.app_config.transfer.chunk_kb;
        captured.window_chunks = self.workspace.app_config.transfer.window_chunks;
        captured.pacing_kbps = if (dedicated) 0 else self.workspace.app_config.transfer.shared_pacing_kbps;
        captured.session_id = @backingInt(owner.session_id);
        captured.transfer_binding = binding;
        captured.conflict_context = .{
            .intent_id = self.tasks.next_transfer_intent,
            .original_owner = owner,
            .resource_owner = binding.resource_owner,
            .source_endpoint = if (spec.direction == .upload) local else remote,
            .target_endpoint = if (spec.direction == .upload) remote else local,
        };
        self.tasks.next_transfer_intent += 1;
        const id = if (dedicated) try self.manager.enqueueWaitingBinding(captured) else try self.manager.enqueue(captured);
        self.tasks.job_owners.appendAssumeCapacity(.{ .job = id, .owner = owner });
        if (@import("platform/runtime_mode.zig").automation) std.debug.print("FILE_SESSION_TRANSFER_ENQUEUED {{\"job\":{d},\"owner_id\":{d},\"owner_generation\":{d},\"binding_id\":{d},\"binding_generation\":{d},\"dedicated_connection\":{},\"pacing_kbps\":{d}}}\n", .{ id, @backingInt(owner.session_id), owner.generation, binding.binding_id, binding.binding_generation, dedicated, captured.pacing_kbps });
        self.last_job = id;
        self.panel.hide();
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }

    fn pollAuxiliary(self: *TransferHost) !void {
        const hooks = self.files.transfer_host.?.hooks();
        for (self.tasks.auxiliary_connections.items) |*connection| {
            if (connection.released) continue;
            if (self.files.transfer_host.?.fault(connection.binding, connection.key)) |fault| {
                if (try self.retainFault(fault) == .released) connection.released = true;
                continue;
            }
            const state = self.application.sessions.queryState(connection.owner) orelse continue;
            // The original close hook owns pause/export and exact release.
            if (state.lifecycle == .closing or state.lifecycle == .cleanup_unknown) continue;
            if (state.lifecycle == .closed) connection.closing = true;
            if (connection.closing) {
                const receipt = hooks.close(hooks.context, .{ .owner = connection.owner, .binding = connection.binding, .create_key = connection.key, .operation = connection.key });
                if (receipt == .released) {
                    _ = try self.application.sessions.auxiliaryTransferReleased(connection.binding, connection.key, .released);
                    connection.released = true;
                }
                continue;
            }
            var needed = false;
            for (0..self.manager.count()) |index| {
                const progress = self.manager.progressAt(index).?;
                const binding = self.manager.transferBinding(progress.job) orelse continue;
                if (binding.eql(connection.binding) and self.manager.retainedOwner(progress.job) == null and (progress.job_cleanup != .released or (progress.state != .succeeded and progress.state != .failed and progress.state != .cancelled))) {
                    needed = true;
                    break;
                }
            }
            if (!needed) {
                connection.closing = true;
                continue;
            }
            if (!self.application.sessions.bindingIsLive(connection.binding)) {
                switch (hooks.poll(hooks.context, connection.binding, connection.key)) {
                    .pending => continue,
                    .ready => |binding| {
                        if (!binding.eql(connection.binding) or !try self.application.sessions.auxiliaryTransferReady(binding, connection.key)) return error.StaleBinding;
                        continue;
                    },
                    .failed => {
                        for (0..self.manager.count()) |index| {
                            const progress = self.manager.progressAt(index).?;
                            const binding = self.manager.transferBinding(progress.job) orelse continue;
                            if (binding.eql(connection.binding) and progress.state == .queued and progress.attempt == 0) try self.manager.pause(progress.job);
                        }
                        connection.closing = true;
                        self.workspace.statusFailure("传输连接失败，请重试");
                        continue;
                    },
                }
            }
            if (!self.files.mux.?.isRegistered(connection.binding)) continue;
            for (0..self.manager.count()) |index| {
                const progress = self.manager.progressAt(index).?;
                const binding = self.manager.transferBinding(progress.job) orelse continue;
                if (binding.eql(connection.binding) and progress.attempt == 0 and (progress.state == .queued or progress.state == .paused) and self.manager.retainedOwner(progress.job) == null) try self.manager.releaseBindingWait(progress.job, binding);
            }
        }
    }

    const RetainedConnection = task_domain_mod.RetainedConnection;

    fn resumeRetained(self: *TransferHost, id: transfer_mod.JobId) !void {
        const owner = self.manager.retainedOwner(id) orelse return error.UnknownRetainedJob;
        const progress = self.manager.progress(id) orelse return error.UnknownJob;
        if (progress.state != .paused or progress.job_cleanup != .released) return error.InvalidState;
        var exists = false;
        for (self.tasks.retained_connections.items) |connection| if (!connection.released and std.meta.eql(connection.owner, owner)) {
            if (connection.closing) return error.CleanupNotReleased;
            exists = true;
            break;
        };
        if (!exists) {
            try self.tasks.retained_connections.ensureUnusedCapacity(self.allocator, 1);
            const start = try self.application.sessions.beginRetainedTransfer(owner.id, owner.original_handle);
            self.tasks.retained_connections.appendAssumeCapacity(.{ .owner = owner, .binding = start.binding, .key = start.key });
            const hooks = self.files.transfer_host.?.hooks();
            hooks.start(hooks.context, .{ .binding = start.binding, .source = .{
                .owner = owner.original_handle,
                .retained_owner = owner.id,
                .create_key = start.key,
                .open_key = start.key,
                .spec = start.spec,
            } }) catch |err| {
                self.tasks.retained_connections.items[self.tasks.retained_connections.items.len - 1].closing = true;
                return err;
            };
        }
        try self.manager.queueRetainedResume(id, progress.attempt, owner);
    }

    const RetainedImport = struct {
        host: *TransferHost,
        connection: *RetainedConnection,
        checkpoint: ?*sftp_engine_mod.OwnedCheckpoint,
        original: transfer_mod.JobSpec,
        job_id: transfer_mod.JobId,
        attempt: u8,
        spec: transfer_mod.JobSpec,
        fn native(raw: *anyopaque) anyerror!transfer_mod.EngineJobId {
            const self: *RetainedImport = @ptrCast(@alignCast(raw));
            if (self.checkpoint) |checkpoint| return self.host.files.transfer_host.?.importPaused(self.connection.binding, self.connection.key, checkpoint, self.spec);
            return self.host.files.transfer_host.?.startRetainedDraft(self.connection.binding, self.connection.key, .{ .original = self.original, .job_id = self.job_id, .attempt = self.attempt, .next = self.spec });
        }
        fn mux(raw: *anyopaque) anyerror!transfer_mod.EngineJobId {
            const self: *RetainedImport = @ptrCast(@alignCast(raw));
            return self.host.files.mux.?.importPaused(self.connection.binding, self, native);
        }
    };

    fn retainedConnectionNeeded(self: *TransferHost, connection: RetainedConnection) bool {
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            const owner = self.manager.retainedOwner(progress.job) orelse continue;
            if (!std.meta.eql(owner, connection.owner)) continue;
            if (self.manager.engineJob(progress.job) == null) {
                if (progress.state == .queued) return true;
            } else if (self.manager.transferBinding(progress.job)) |binding| {
                if (binding.eql(connection.binding) and (progress.job_cleanup != .released or (progress.state != .succeeded and progress.state != .failed and progress.state != .cancelled))) return true;
            }
        }
        return false;
    }

    fn pollRetained(self: *TransferHost) !void {
        _ = try self.retained_store.poll();
        const hooks = self.files.transfer_host.?.hooks();
        for (self.tasks.retained_connections.items) |*connection| {
            if (connection.released) continue;
            if (self.files.transfer_host.?.fault(connection.binding, connection.key)) |fault| {
                if (try self.retainFault(fault) == .released) connection.released = true;
                continue;
            }
            if (connection.closing) {
                const receipt = hooks.close(hooks.context, .{ .owner = connection.owner.original_handle, .binding = connection.binding, .create_key = connection.key, .operation = connection.key });
                if (receipt == .released) {
                    _ = try self.application.sessions.retainedTransferReleased(connection.binding, connection.key, .released);
                    connection.released = true;
                }
                continue;
            }
            if (!self.retainedConnectionNeeded(connection.*)) {
                connection.closing = true;
                continue;
            }
            if (!self.application.sessions.bindingIsLive(connection.binding)) {
                switch (hooks.poll(hooks.context, connection.binding, connection.key)) {
                    .pending => continue,
                    .ready => |binding| {
                        if (!binding.eql(connection.binding) or !try self.application.sessions.retainedTransferReady(binding, connection.key)) return error.StaleBinding;
                        // The next FileTransferHost safeTick registers its Mux.
                        continue;
                    },
                    .failed => {
                        connection.closing = true;
                        for (0..self.manager.count()) |index| {
                            const progress = self.manager.progressAt(index).?;
                            const original = self.manager.retainedOwner(progress.job) orelse continue;
                            if (std.meta.eql(original, connection.owner) and progress.state == .queued and self.manager.engineJob(progress.job) == null) try self.manager.pause(progress.job);
                        }
                        self.workspace.statusFailure("传输连接失败，请重试");
                        continue;
                    },
                }
            }
            var live_jobs = false;
            for (0..self.manager.count()) |index| {
                const progress = self.manager.progressAt(index).?;
                const owner = self.manager.retainedOwner(progress.job) orelse continue;
                if (!std.meta.eql(owner, connection.owner)) continue;
                if (self.manager.engineJob(progress.job) != null) {
                    if (self.manager.transferBinding(progress.job)) |binding| {
                        if (binding.eql(connection.binding) and (progress.job_cleanup != .released or (progress.state != .succeeded and progress.state != .failed and progress.state != .cancelled))) live_jobs = true;
                    }
                    continue;
                }
                if (progress.state != .queued) continue;
                live_jobs = true;
                if (!self.manager.canAcceptRetainedResume(progress.job, progress.attempt)) continue;
                // Started jobs require a real checkpoint. Never-started
                // drafts use the separately validated fresh-preflight entry.
                const checkpoint = self.retained_store.checkpoint(progress.job, progress.attempt);
                if (checkpoint == null and progress.attempt != 0) {
                    try self.manager.pause(progress.job);
                    self.workspace.status("任务恢复数据不可用");
                    continue;
                }
                const frozen = self.manager.retainedSpec(progress.job, progress.attempt) orelse return error.StaleAttempt;
                var spec = frozen;
                spec.transfer_binding = connection.binding;
                if (spec.conflict_context) |*context| {
                    context.job = progress.job;
                    context.attempt = @as(u32, progress.attempt) + 1;
                    context.resource_owner = connection.binding.resource_owner;
                    switch (context.source_endpoint) {
                        .sftp => |*endpoint| {
                            endpoint.binding_id = connection.binding.binding_id;
                            endpoint.binding_generation = connection.binding.binding_generation;
                            endpoint.resource_owner = connection.binding.resource_owner;
                            endpoint.origin_session = connection.owner.original_handle;
                        },
                        else => {},
                    }
                    switch (context.target_endpoint) {
                        .sftp => |*endpoint| {
                            endpoint.binding_id = connection.binding.binding_id;
                            endpoint.binding_generation = connection.binding.binding_generation;
                            endpoint.resource_owner = connection.binding.resource_owner;
                            endpoint.origin_session = connection.owner.original_handle;
                        },
                        else => {},
                    }
                }
                try self.manager.validateRetainedResume(progress.job, progress.attempt, spec);
                var import = RetainedImport{ .host = self, .connection = connection, .checkpoint = checkpoint, .original = frozen, .job_id = progress.job, .attempt = progress.attempt, .spec = spec };
                const engine_id = self.dispatch.importBoundPaused(&import, RetainedImport.mux) catch |err| switch (err) {
                    error.TransferNotReady, error.StaleBinding => continue,
                    else => {
                        if (checkpoint == null or checkpoint.?.describe() != null) try self.manager.pause(progress.job);
                        self.workspace.statusFailure(@errorName(err));
                        continue;
                    },
                };
                try self.manager.acceptRetainedResume(progress.job, progress.attempt, spec, engine_id);
                if (checkpoint != null) try self.retained_store.consumeImported(progress.job, progress.attempt);
            }
            if (!live_jobs) connection.closing = true;
        }
    }

    const RetainedClose = task_domain_mod.RetainedClose;

    fn retainShared(self: *TransferHost, connection: *SharedConnection, key: @import("host/operation.zig").OperationKey, fault: bool) !application_host_mod.CloseReceipt {
        for (self.tasks.retained_closes.items) |record| if (record.shared_binding != null and record.shared_binding.?.eql(connection.binding) and record.key.eql(key)) return self.finishSharedRetain(connection, record);
        var count: usize = 0;
        var has_jobs = false;
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            const binding = self.manager.transferBinding(progress.job) orelse continue;
            if (!binding.eql(connection.binding) or self.manager.retainedOwner(progress.job) != null) continue;
            if (progress.state == .succeeded or progress.state == .failed or progress.state == .cancelled) {
                if (progress.job_cleanup == .unknown) return .unknown;
                if (progress.job_cleanup != .released) return .awaiting;
                continue;
            }
            has_jobs = true;
            if (progress.state == .running or progress.state == .queued or progress.state == .retry_wait) try self.manager.pause(progress.job);
            const current = self.manager.progress(progress.job).?;
            if (current.job_cleanup == .unknown) return .unknown;
            if (current.state != .paused or current.job_cleanup != .released) return .awaiting;
            if (self.manager.engineJob(progress.job)) |outer| {
                const proxy = try self.dispatch.pausedBoundRoute(outer);
                const native = try self.files.mux.?.pausedNativeId(proxy, binding);
                if (!connection.service.backend.canExportPaused(native)) return .awaiting;
                count += 1;
            }
        }
        if (!has_jobs) return self.releaseSharedRoute(connection);
        const retained_id = if (fault) try self.application.sessions.retainFaultTransferSource(connection.binding, key) else try self.application.sessions.retainTransferSource(connection.owner);
        try self.tasks.retained_closes.ensureUnusedCapacity(self.allocator, 1);
        var installed = false;
        const record = try self.allocator.create(RetainedClose);
        errdefer if (!installed) self.allocator.destroy(record);
        const jobs = try self.allocator.alloc(retained_runtime_mod.RetainJob, count);
        errdefer if (!installed) self.allocator.free(jobs);
        const owned = try self.allocator.alloc(retained_runtime_mod.RetainedJob, count);
        errdefer if (!installed) self.allocator.free(owned);
        var cursor: usize = 0;
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            const binding = self.manager.transferBinding(progress.job) orelse continue;
            if (!binding.eql(connection.binding) or progress.state != .paused or self.manager.retainedOwner(progress.job) != null) continue;
            if (self.manager.engineJob(progress.job)) |outer| {
                const proxy = try self.dispatch.pausedBoundRoute(outer);
                const native = try self.files.mux.?.pausedNativeId(proxy, binding);
                if (!connection.service.backend.canExportPaused(native)) return error.CheckpointNotReleased;
                jobs[cursor] = .{ .job_id = progress.job, .attempt = progress.attempt, .proxy_id = proxy, .native_id = native };
                owned[cursor] = .{ .original = jobs[cursor] };
                cursor += 1;
            }
        }
        const batch = if (fault) try self.retained_store.prepareFault(connection.owner, connection.binding, key, retained_id, count) else try self.retained_store.prepareBinding(connection.owner, key, retained_id, count, connection.binding);
        record.* = .{ .owner = connection.owner, .key = key, .retained_id = retained_id, .jobs = jobs, .batch = batch, .fault_binding = if (fault) connection.binding else null, .shared_binding = connection.binding, .pending = .{ .allocator = self.allocator, .owner = connection.owner, .retained_owner = retained_id, .close_key = key, .binding = connection.binding, .jobs = owned } };
        self.tasks.retained_closes.appendAssumeCapacity(record);
        installed = true;
        return self.finishSharedRetain(connection, record);
    }

    fn releaseSharedRoute(self: *TransferHost, connection: *SharedConnection) !application_host_mod.CloseReceipt {
        connection.service.requestClose();
        const receipt: application_host_mod.CloseReceipt = switch (connection.service.closeReceipt()) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        };
        if (receipt != .released) return receipt;
        self.files.mux.?.detach(connection.binding) catch |err| switch (err) {
            error.JobsActive, error.CleanupPending => return .awaiting,
            error.CleanupUnknown => return .unknown,
            error.UnknownBinding => {},
            else => return err,
        };
        if (!self.application.sessions.sharedTransferReleased(connection.binding, connection.key, .released)) return error.StaleBinding;
        try connection.service.routingReleased(connection.binding);
        connection.released = true;
        return .released;
    }

    fn finishSharedRetain(self: *TransferHost, connection: *SharedConnection, record: *RetainedClose) !application_host_mod.CloseReceipt {
        if (record.complete) return .released;
        if (record.pending) |*payload| {
            for (payload.jobs) |*job| if (job.checkpoint == null) {
                job.checkpoint = try connection.service.backend.exportPaused(job.original.native_id);
            };
            connection.service.requestClose();
            switch (connection.service.closeReceipt()) {
                .awaiting => return .awaiting,
                .unknown => return .unknown,
                .released => {},
            }
            try self.retained_store.accept(record.batch, payload);
            record.pending = null;
        }
        if (record.batch.payload != null) try self.retained_store.adopt(record.batch);
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            const binding = self.manager.transferBinding(progress.job) orelse continue;
            if (!binding.eql(connection.binding) or progress.state != .paused) continue;
            if (self.manager.engineJob(progress.job) != null) return error.RetainedRouteNotRetired;
            try self.manager.retainPaused(progress.job, progress.attempt, null, .{ .id = record.retained_id, .original_handle = connection.owner });
        }
        try self.applyDeferredCancels(record);
        const receipt = try self.releaseSharedRoute(connection);
        if (receipt == .released) record.complete = true;
        return receipt;
    }

    fn retainFault(self: *TransferHost, fault: @import("host/file_transfer_host.zig").FaultSnapshot) !application_host_mod.CloseReceipt {
        for (self.tasks.retained_closes.items) |record| if (record.fault_binding != null and record.fault_binding.?.eql(fault.binding) and record.key.eql(fault.key)) return self.finishRetainedClose(record);
        var count: usize = 0;
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            const binding = self.manager.transferBinding(progress.job) orelse continue;
            if (!binding.eql(fault.binding)) continue;
            if (progress.state == .succeeded or progress.state == .failed or progress.state == .cancelled) {
                if (progress.job_cleanup == .unknown) return .unknown;
                if (progress.job_cleanup != .released) return .awaiting;
                continue;
            }
            if (progress.state == .running or progress.state == .queued or progress.state == .retry_wait) try self.manager.pause(progress.job);
            const paused = self.manager.progress(progress.job).?;
            if (paused.job_cleanup == .unknown) return .unknown;
            if (paused.state != .paused or paused.job_cleanup != .released) return .awaiting;
            if (self.manager.engineJob(progress.job) != null) count += 1;
        }
        const id = try self.application.sessions.retainFaultTransferSource(fault.binding, fault.key);
        try self.tasks.retained_closes.ensureUnusedCapacity(self.allocator, 1);
        var installed = false;
        const record = try self.allocator.create(RetainedClose);
        errdefer if (!installed) self.allocator.destroy(record);
        const jobs = try self.allocator.alloc(retained_runtime_mod.RetainJob, count);
        errdefer if (!installed) self.allocator.free(jobs);
        var cursor: usize = 0;
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            const binding = self.manager.transferBinding(progress.job) orelse continue;
            if (!binding.eql(fault.binding) or progress.state != .paused) continue;
            if (self.manager.engineJob(progress.job)) |outer| {
                const proxy = try self.dispatch.pausedBoundRoute(outer);
                jobs[cursor] = .{ .job_id = progress.job, .attempt = progress.attempt, .proxy_id = proxy, .native_id = try self.files.mux.?.pausedNativeId(proxy, binding) };
                cursor += 1;
            }
        }
        const batch = try self.retained_store.prepareFault(fault.owner, fault.binding, fault.key, id, count);
        record.* = .{ .owner = fault.owner, .key = fault.key, .retained_id = id, .jobs = jobs, .batch = batch, .fault_binding = fault.binding };
        self.tasks.retained_closes.appendAssumeCapacity(record);
        installed = true;
        return self.finishRetainedClose(record);
    }

    /// The original close cannot advance until native checkpoints have moved
    /// into application storage and both original proxy routes are retired.
    fn retainForClose(self: *TransferHost, owner: @import("host/identity.zig").SessionHandle) !application_host_mod.CloseReceipt {
        const state = self.application.sessions.queryState(owner) orelse return error.StaleSession;
        const key = state.close_operation orelse return error.StaleCloseOperation;
        for (self.tasks.shared_connections.items) |*connection| if (connection.owner.eql(owner) and !connection.released) {
            const receipt = try self.retainShared(connection, key, false);
            if (receipt != .released) return receipt;
        };
        for (self.tasks.retained_closes.items) |record| if (record.shared_binding == null and record.owner.eql(owner) and record.key.eql(key)) return self.finishRetainedClose(record);
        const backend = self.files.transfer_host orelse return error.TransferHostUnavailable;
        // Revoke automatic stale-session cancellation before waiting for pause.
        backend.prepareRetain(owner, key) catch |err| switch (err) {
            error.TransferHostClosing => {
                // Authentication failure may already be releasing the original
                // backend. Wait for that exact receipt, then retry preparation.
                const hooks = backend.hooks();
                for (self.tasks.auxiliary_connections.items) |*connection| {
                    if (!connection.owner.eql(owner) or connection.released) continue;
                    connection.closing = true;
                    const receipt = hooks.close(hooks.context, .{ .owner = owner, .binding = connection.binding, .create_key = connection.key, .operation = key });
                    if (receipt != .released) return receipt;
                    connection.released = true;
                }
                return .awaiting;
            },
            else => return err,
        };
        var count: usize = 0;
        var has_jobs = false;
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            const original = jobOwner(self, progress.job) orelse continue;
            if (!original.eql(owner)) continue;
            if (self.manager.retainedOwner(progress.job) != null) continue;
            if (progress.state == .succeeded or progress.state == .failed or progress.state == .cancelled) {
                if (progress.job_cleanup == .unknown) return .unknown;
                if (progress.job_cleanup != .released) return .awaiting;
                continue;
            }
            has_jobs = true;
            if (progress.state == .running or progress.state == .queued or progress.state == .retry_wait) try self.manager.pause(progress.job);
            const current = self.manager.progress(progress.job).?;
            if (current.job_cleanup == .unknown) return .unknown;
            if (current.state != .paused or current.job_cleanup != .released) return .awaiting;
            if (self.manager.engineJob(progress.job) != null) count += 1;
        }
        if (!has_jobs) {
            const hooks = backend.hooks();
            for (self.tasks.auxiliary_connections.items) |*connection| {
                if (!connection.owner.eql(owner) or connection.released) continue;
                connection.closing = true;
                const receipt = hooks.close(hooks.context, .{ .owner = owner, .binding = connection.binding, .create_key = connection.key, .operation = key });
                if (receipt != .released) return receipt;
                connection.released = true;
            }
            return .released;
        }
        const retained_id = try self.application.sessions.retainTransferSource(owner);
        try self.tasks.retained_closes.ensureUnusedCapacity(self.allocator, 1);
        var installed = false;
        const record = try self.allocator.create(RetainedClose);
        errdefer if (!installed) self.allocator.destroy(record);
        const jobs = try self.allocator.alloc(retained_runtime_mod.RetainJob, count);
        errdefer if (!installed) self.allocator.free(jobs);
        var cursor: usize = 0;
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            const original = jobOwner(self, progress.job) orelse continue;
            if (!original.eql(owner) or progress.state != .paused or self.manager.retainedOwner(progress.job) != null) continue;
            if (self.manager.engineJob(progress.job)) |outer_id| {
                const binding = self.manager.transferBinding(progress.job) orelse return error.TransferBindingRequired;
                const proxy_id = try self.dispatch.pausedBoundRoute(outer_id);
                const native_id = try self.files.mux.?.pausedNativeId(proxy_id, binding);
                jobs[cursor] = .{ .job_id = progress.job, .attempt = progress.attempt, .proxy_id = proxy_id, .native_id = native_id };
                cursor += 1;
            }
        }
        const batch = try self.retained_store.prepare(owner, key, retained_id, count);
        record.* = .{ .owner = owner, .key = key, .retained_id = retained_id, .jobs = jobs, .batch = batch };
        self.tasks.retained_closes.appendAssumeCapacity(record);
        installed = true;
        return self.finishRetainedClose(record);
    }

    fn finishRetainedClose(self: *TransferHost, record: *RetainedClose) !application_host_mod.CloseReceipt {
        if (record.complete) return .released;
        const backend = self.files.transfer_host orelse return error.TransferHostUnavailable;
        if (record.batch.payload == null) {
            const receipt = if (record.fault_binding) |binding| try backend.retainFault(binding, record.key, record.retained_id, record.jobs) else try backend.retainPaused(record.owner, record.key, record.retained_id, record.jobs);
            if (receipt != .released) return receipt;
            if (record.pending == null) record.pending = if (record.fault_binding) |binding| try backend.takeFaultRetained(binding, record.key) else try backend.takeRetained(record.owner, record.key);
            if (record.pending) |*payload| {
                // Retain the moved batch in this stable record on rejection.
                try self.retained_store.accept(record.batch, payload);
                record.pending = null;
            } else if (record.jobs.len != 0) return error.RetainedBatchMissing;
        }
        if (record.batch.payload != null) try self.retained_store.adopt(record.batch);
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            const original = jobOwner(self, progress.job) orelse continue;
            if (!original.eql(record.owner) or progress.state != .paused or self.manager.retainedOwner(progress.job) != null) continue;
            if (record.fault_binding) |binding| {
                const current = self.manager.transferBinding(progress.job) orelse continue;
                if (!current.eql(binding)) continue;
            }
            if (self.manager.engineJob(progress.job) != null) return error.RetainedRouteNotRetired;
            try self.manager.retainPaused(progress.job, progress.attempt, null, .{ .id = record.retained_id, .original_handle = record.owner });
        }
        try self.applyDeferredCancels(record);
        record.complete = true;
        return .released;
    }

    fn applyDeferredCancels(self: *TransferHost, record: *RetainedClose) !void {
        for (record.deferred_cancel.items) |id| {
            const progress = self.manager.progress(id) orelse return error.UnknownJob;
            if (progress.state == .cancelled and progress.job_cleanup == .released) continue;
            const owner = self.manager.retainedOwner(id) orelse return error.RetainedRouteNotRetired;
            try self.retained_store.cancel(id, progress.attempt);
            try self.manager.retainedCancelReceipt(id, progress.attempt, owner, .awaiting);
        }
        record.deferred_cancel.clearRetainingCapacity();
    }

    fn jobOwnerLabel(raw: *anyopaque, job: transfer_mod.JobId) []const u8 {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        const owner = jobOwner(raw, job) orelse return "归属未知";
        for (self.workspace.tabs.items) |tab| if (tab.content_owner == .session and tab.content_owner.session.eql(owner)) return tab.titleSlice();
        return "原会话已关闭";
    }
    fn transferScopeChoices(raw: *anyopaque, a: std.mem.Allocator) ![]const transfer_manager_view.ScopeChoice {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        var choices: std.ArrayList(transfer_manager_view.ScopeChoice) = .empty;
        for (self.workspace.tabs.items) |tab| {
            if (tab.content_owner != .session) continue;
            const owner = tab.content_owner.session;
            var has_tasks = false;
            for (self.tasks.job_owners.items) |record| if (record.owner.eql(owner) and self.manager.progress(record.job) != null) {
                has_tasks = true;
                break;
            };
            if (has_tasks) try choices.append(a, .{ .label = try a.dupe(u8, tab.titleSlice()), .scope = .{ .session = owner } });
        }
        return choices.items;
    }

    fn jobOwner(raw: *anyopaque, job: transfer_mod.JobId) ?@import("host/identity.zig").SessionHandle {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        for (self.tasks.job_owners.items) |record| if (record.job == job) return record.owner;
        return null;
    }

    const RevealLocation = struct { direction: transfer_mod.Direction, remote_dir: []const u8, local_dir: []const u8 };
    fn revealSpec(self: *TransferHost, job_id: transfer_mod.JobId, attempt: u8) ?RevealLocation {
        for (self.manager.jobs.items) |job| if (job.id == job_id) return .{ .direction = job.spec.direction, .remote_dir = job.spec.remote_dir, .local_dir = job.spec.local_dir };
        const spec = self.manager.retainedSpec(job_id, attempt) orelse return null;
        return .{ .direction = spec.direction, .remote_dir = spec.remote_dir, .local_dir = spec.local_dir };
    }
    fn canReveal(raw: *anyopaque, job_id: transfer_mod.JobId) bool {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        if (self.workspace.shutting_down) return false;
        const progress = self.manager.progress(job_id) orelse return false;
        if (progress.state != .succeeded) return false;
        const spec = self.revealSpec(job_id, progress.attempt) orelse return false;
        const owner = jobOwner(raw, job_id) orelse return false;
        if (spec.direction == .download) return std.fs.path.isAbsolute(spec.local_dir) and std.mem.indexOfScalar(u8, spec.local_dir, 0) == null;
        if (!std.fs.path.isAbsolute(spec.remote_dir)) return false;
        const presentation = self.files.presentation orelse return false;
        const model = presentation.modelFor(owner) orelse return false;
        const projection = model.projection() orelse return false;
        if (!projection.owner.eql(owner) or !projection.panes[1].navigation_enabled or (projection.panes[1].state != .ready and projection.panes[1].state != .empty)) return false;
        for (self.workspace.tabs.items) |tab| if (tab.content_owner.eql(.{ .session = owner }) and !tab.closing and !tab.failed and !tab.archived) return true;
        return false;
    }
    fn revealCompleted(self: *TransferHost, job_id: transfer_mod.JobId, attempt: u8, owner: @import("host/identity.zig").SessionHandle) !void {
        const progress = self.manager.progress(job_id) orelse return error.StaleTask;
        if (progress.attempt != attempt or !canReveal(self, job_id)) return error.LocationUnavailable;
        if (!(jobOwner(self, job_id) orelse return error.TransferOwnerExpired).eql(owner)) return error.TransferOwnerExpired;
        const spec = self.revealSpec(job_id, attempt) orelse return error.StaleTask;
        if (spec.direction == .download) {
            const directory = try std.Io.Dir.cwd().openDir(self.workspace.io, spec.local_dir, .{});
            directory.close(self.workspace.io);
            const argv = [_][]const u8{ "open", spec.local_dir };
            var result = try std.process.run(self.allocator, self.workspace.io, .{ .argv = &argv, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);
            if (!result.term.success()) return error.OpenTransferDirectoryFailed;
        } else {
            const presentation = self.files.presentation orelse return error.FileSourceUnavailable;
            const model = presentation.modelFor(owner) orelse return error.FileSourceUnavailable;
            const projection = model.projection() orelse return error.FileProjectionUnavailable;
            const pane = projection.panes[1];
            try model.handle(.{ .side = .remote, .stamp = pane.stamp, .projection_revision = projection.revision, .selection_revision = pane.selection_revision, .action = .{ .navigate = .{ .requested_path = spec.remote_dir, .base_directory = pane.resolved_path } } });
            for (self.workspace.tabs.items, 0..) |tab, index| if (tab.content_owner.eql(.{ .session = owner })) {
                self.workspace.selectTab(index);
                break;
            };
        }
        if (self.session_panel) |panel| panel.dismiss();
        self.closeManagerPopover();
    }
    fn requestGlobalManager(raw: *anyopaque, _: transfer_manager_view.Scope) void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        self.manager_open_requested = true;
        self.cx.requestRedraw();
    }
    fn requestSessionSftp(raw: *anyopaque) void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        self.sftp_open_requested = true;
        self.cx.requestRedraw();
    }
    fn showExistingSftp(self: *TransferHost) void {
        // The frozen workspace action switches to an existing SFTP session.
        // Resolve at the safe point; no new connection or transfer is implied.
        for (self.workspace.tabs.items, 0..) |tab, index| {
            if (tab.closing or tab.archived) continue;
            const protocol = if (tab.plugin_protocol_id.len > 0) tab.plugin_protocol_id else if (tab.host_snapshot) |saved| saved.value.protocolId() else "";
            if (!std.mem.eql(u8, protocol, "sftp")) continue;
            self.workspace.selectTab(index);
            if (self.session_panel) |panel| panel.dismiss();
            return;
        }
        self.workspace.status("尚未打开 SFTP，请从已保存的 SFTP 连接进入");
    }
    fn showGlobalManager(self: *TransferHost) void {
        const panel = self.manager_panel orelse return;
        if (self.workspace.shutting_down) return;
        if (self.session_panel) |session_panel| session_panel.hide();
        panel.selected_scope = .all;
        panel.refresh(wallClockMsTransfer(), .{
            .window_chunks = self.workspace.app_config.transfer.window_chunks,
            .chunk_kb = self.workspace.app_config.transfer.chunk_kb,
        }) catch |err| self.workspace.statusFailure(@errorName(err));
        panel.show();
        self.manager_visible = true;
        self.manager_last_refresh_ms = 0;
        self.cx.requestRedraw();
    }
    fn toggleManager(self: *TransferHost) void {
        const panel = self.manager_panel orelse return;
        if (self.session_panel) |session_panel| session_panel.hide();
        if (panel.root.style.display != .none) {
            self.closeManagerPopover();
            return;
        }
        self.showGlobalManager();
    }

    fn closeManagerPopover(self: *TransferHost) void {
        if (self.manager_panel) |panel| panel.hide();
        self.manager_visible = false;
        self.cx.requestRedraw();
    }

    fn managerAction(raw: *anyopaque, id: transfer_mod.JobId, action: transfer_manager_view.Action) void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        if (action == .reveal) {
            const progress = self.manager.progress(id) orelse return;
            if (!canReveal(raw, id)) {
                self.workspace.status("原任务位置当前不可用");
                return;
            }
            self.reveal_requested = .{ .job = id, .attempt = progress.attempt, .owner = jobOwner(raw, id) orelse return };
            self.cx.requestRedraw();
            return;
        }
        // Exported checkpoints move exactly once while their former native
        // route is retiring. Preserve a cancel made in that interval and
        // deliver it to the Store after adoption, never to a handed-off ID.
        for (self.tasks.retained_closes.items) |record| if (!record.complete) {
            for (record.jobs) |job| if (job.job_id == id) {
                if (action == .cancel) {
                    for (record.deferred_cancel.items) |queued| if (queued == id) return;
                    record.deferred_cancel.append(self.allocator, id) catch |err| {
                        self.workspace.statusFailure(@errorName(err));
                        return;
                    };
                    self.workspace.status("正在取消任务");
                    self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
                } else self.workspace.status("任务状态正在同步，请稍后重试");
                return;
            };
        };
        if (self.manager.retainedOwner(id) != null and self.manager.engineJob(id) == null) {
            const progress = self.manager.progress(id) orelse return;
            switch (action) {
                .resume_transfer, .retry => self.resumeRetained(id) catch |err| self.workspace.statusFailure(@errorName(err)),
                .cancel => {
                    if (progress.attempt == 0) {
                        self.manager.retainedCancelReceipt(id, progress.attempt, self.manager.retainedOwner(id).?, .released) catch |err| self.workspace.statusFailure(@errorName(err));
                    } else {
                        self.retained_store.cancel(id, progress.attempt) catch |err| {
                            self.workspace.statusFailure(@errorName(err));
                            return;
                        };
                        self.manager.retainedCancelReceipt(id, progress.attempt, self.manager.retainedOwner(id).?, .awaiting) catch |err| self.workspace.statusFailure(@errorName(err));
                    }
                },
                else => {},
            }
            self.manager_last_refresh_ms = 0;
            self.cx.requestRedraw();
            return;
        }
        if (action == .resume_transfer or action == .retry) {
            const progress = self.manager.progress(id) orelse return;
            if (progress.attempt == 0 and progress.state == .paused) if (self.manager.transferBinding(id)) |binding| if (!self.application.sessions.bindingIsLive(binding)) {
                const owner = jobOwner(self, id) orelse return;
                const start = self.ensureAuxiliary(owner) catch |err| {
                    self.workspace.statusFailure(@errorName(err));
                    return;
                };
                self.manager.rebindWaitingDraft(id, start.binding) catch |err| self.workspace.statusFailure(@errorName(err));
                self.cx.requestRedraw();
                return;
            };
        }
        if (action == .retry or action == .resume_transfer) {
            const original = jobOwner(raw, id) orelse {
                self.workspace.status("任务归属已失效");
                return;
            };
            if (self.manager.transferBinding(id)) |binding| {
                if (!self.application.sessions.bindingIsLive(binding) or (binding.resource_owner == .session and !binding.resource_owner.session.eql(original)) or (binding.resource_owner == .retained_transfer and (binding.origin_session == null or !binding.origin_session.?.eql(original)))) {
                    self.workspace.status("任务所属文件连接已失效");
                    return;
                }
            } else {
                self.workspace.status("任务缺少有效传输服务，请新建传输");
                return;
            }
        }
        switch (action) {
            .resolve_conflict => {
                self.conflict_job = id;
                self.conflict_manual = true;
                self.conflict_presented = false;
                self.refreshConflict() catch |err| self.workspace.statusFailure(@errorName(err));
            },
            .pause => self.manager.pause(id) catch |err| self.workspace.status(if (err == error.UnsupportedPause) "当前连接不支持暂停" else @errorName(err)),
            .resume_transfer => self.manager.resumeJob(id) catch |err| self.workspace.status(if (err == error.UnsupportedResume or err == error.SafeResumeUnavailable) "当前任务不支持安全续传" else @errorName(err)),
            .cancel => self.manager.cancel(id) catch |err| self.workspace.statusFailure(@errorName(err)),
            .retry => self.manager.retry(id) catch |err| self.workspace.statusFailure(@errorName(err)),
            else => {},
        }
        self.manager_last_refresh_ms = 0;
        self.cx.requestRedraw();
    }

    fn conflictDecision(raw: *anyopaque, request: transfer_mod.Conflict.Request) !void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        const key = request.key();
        if (self.conflict_job == null or self.conflict_job.? != key.job) return error.StaleConflict;
        try self.manager.resolveConflict(key.job, request);
        self.cx.requestRedraw();
    }

    fn deferConflict(raw: *anyopaque, key: @import("transfer/conflict.zig").Key) !void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        if (self.conflict_job == null or self.conflict_job.? != key.job) return error.StaleConflict;
        var snapshot = (try self.manager.conflictSnapshot(self.allocator, key.job)) orelse return error.StaleConflict;
        defer snapshot.deinit();
        const actual = switch (snapshot.value.pending) {
            .choice => |prompt| prompt.key,
            else => return error.StaleConflict,
        };
        if (!std.meta.eql(actual, key)) return error.StaleConflict;
        try self.manager.pause(key.job);
        self.conflict_job = null;
        self.conflict_manual = false;
        self.conflict_presented = false;
        if (self.conflict_view) |view| view.hide();
        self.cx.requestRedraw();
    }

    fn refreshConflict(self: *TransferHost) !void {
        const view = self.conflict_view orelse return;
        if (self.conflict_job == null) {
            for (0..self.manager.count()) |index| {
                const progress = self.manager.progressAt(index).?;
                if (progress.state == .running and progress.conflict_waiting) {
                    var candidate = (try self.manager.conflictSnapshot(self.allocator, progress.job)) orelse continue;
                    const has_context = candidate.value.context != null;
                    candidate.deinit();
                    if (!has_context) continue;
                    self.conflict_job = progress.job;
                    break;
                }
            }
        }
        const job = self.conflict_job orelse return;
        if (self.conflict_presented and !view.isVisible()) {
            self.conflict_job = null;
            self.conflict_manual = false;
            self.conflict_presented = false;
            return;
        }
        var snapshot = (try self.manager.conflictSnapshot(self.allocator, job)) orelse {
            self.conflict_job = null;
            self.conflict_manual = false;
            self.conflict_presented = false;
            view.hide();
            return;
        };
        defer snapshot.deinit();
        // Legacy jobs without a frozen Context cannot authorize decisions.
        // Their read-only explanation opens only on an explicit list action.
        if (snapshot.value.context == null and !self.conflict_manual) {
            self.conflict_job = null;
            return;
        }
        try view.show(snapshot.value);
        self.conflict_presented = true;
        try view.flush();
    }

    fn openPanel(self: *TransferHost) void {
        self.showPanel(.{ .mode = .upload });
        self.cx.requestRedraw();
    }

    fn showConfirmation(self: *TransferHost, data: transfer_panel_mod.Data) void {
        const defaults = @import("config/transfer_defaults.zig");
        var captured = defaults.confirmation(self.workspace.app_config.transfer, data);
        if (captured.mode != .download or captured.local_dir.len > 0) {
            self.panel.show(captured);
            return;
        }
        const home = @import("platform/account.zig").home(self.allocator) catch null;
        defer if (home) |value| self.allocator.free(value);
        const initial = defaults.downloadDirectory(self.allocator, self.workspace.app_config.transfer.download_dir, home) catch {
            self.panel.show(captured);
            return;
        };
        defer self.allocator.free(initial);
        captured.local_dir = initial;
        // Panel.show stores the path in an owning text signal. A suggestion
        // deliberately does not create the AppKit directory-selection receipt.
        self.panel.show(captured);
    }

    fn showSessionTransfer(self: *TransferHost, owner: @import("host/identity.zig").SessionHandle, mode: transfer_panel_mod.Data.Mode, source: ?[]const u8) void {
        const capabilities = (self.application.sessions.capabilitySnapshot(owner) catch {
            self.workspace.statusFailure("传输失败：无法读取原会话状态");
            return;
        }) orelse {
            self.workspace.statusFailure("传输失败：原会话已失效");
            return;
        };
        const availability = @import("host/actions.zig").project(if (mode == .upload) .upload else .download, capabilities);
        if (!availability.enabled) {
            self.workspace.status(availability.reason);
            return;
        }
        const tab_id = self.application.legacyForHandle(owner) orelse return;
        const tab = self.workspace.sessionTab(tab_id) orelse return;
        if (tab.closing or tab.archived or tab.failed or tab.runtime == null) {
            self.workspace.statusFailure("传输失败：需要在线的 SSH 会话");
            return;
        }
        const host = if (tab.host_snapshot) |snapshot| snapshot.value else {
            self.workspace.statusFailure("传输失败：缺少主机配置");
            return;
        };
        const cwd = if (mode == .upload) tab.runtime.?.workerPtr().copyCwd(self.allocator) catch null else null;
        defer if (cwd) |value| self.allocator.free(value);
        self.file_binding = null;
        self.file_conflict_context = null;
        self.showConfirmation(.{ .mode = mode, .owner = owner, .endpoint = host.host, .host_name = tab.titleSlice(), .available = true, .sources = if (source) |value| &.{value} else &.{}, .local_dir = "", .remote_dir = cwd orelse "", .edit_remote_source = mode == .download, .require_directory_selection = mode == .download });
        if (mode == .upload) self.requestUploadDirectory(owner, tab.runtime.?.workerPtr());
        self.cx.requestRedraw();
    }

    fn requestUploadDirectory(self: *TransferHost, owner: @import("host/identity.zig").SessionHandle, runtime: *@import("host/runtime_service.zig").Runtime) void {
        runtime.requestCurrentDirectory() catch {
            self.workspace.status("无法读取当前远程目录，请重试");
            return;
        };
        self.panel.remote_dir_sig.set("");
        self.panel.remote_hint.setTextContent(self.allocator, "正在读取当前终端目录…") catch {};
        self.cwd_pending = .{ .owner = owner, .started = wallClockMsTransfer() };
        self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
    }

    fn showPanel(self: *TransferHost, data: transfer_panel_mod.Data) void {
        self.file_binding = null;
        self.file_conflict_context = null;
        const index = self.workspace.active_tab orelse return;
        const tab = self.workspace.tabs.items[index];
        var captured = data;
        captured.owner = switch (tab.content_owner) {
            .session => |handle| handle,
            else => null,
        };
        const host = self.workspace.tabHost(index);
        captured.endpoint = if (host) |value| value.host else "本机";
        captured.host_name = tab.titleSlice();
        captured.available = host != null and !tab.closing and !tab.archived and !tab.failed and tab.runtime != null;
        captured.unavailable_reason = "当前会话无法进行远程文件传输";
        self.showConfirmation(captured);
        if (data.mode == .upload and data.remote_dir.len == 0 and captured.available) if (captured.owner) |owner| self.requestUploadDirectory(owner, tab.runtime.?.workerPtr());
    }

    fn showFileTransfer(raw: *anyopaque, intent: @import("host/file_workspace_controller.zig").FrozenTransfer, binding: @import("host/session_host.zig").ServiceHandle) !void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        const tab_id = self.application.legacyForHandle(intent.owner) orelse return error.TransferOwnerExpired;
        const tab = self.workspace.sessionTab(tab_id) orelse return error.TransferOwnerExpired;
        if (!tab.file_ready or tab.closing or !self.application.sessions.bindingIsLive(binding)) return error.TransferOwnerExpired;
        const host = tab.host_snapshot.?.value;
        if (self.tasks.next_transfer_intent == std.math.maxInt(u64)) return error.IntentIdExhausted;
        const conflict_context: transfer_mod.Conflict.Context = .{
            .intent_id = self.tasks.next_transfer_intent,
            .original_owner = intent.owner,
            .resource_owner = binding.resource_owner,
            .source_endpoint = switch (intent.source.endpoint) {
                .local_fs => |value| .{ .local_fs = value },
                .sftp => |value| .{ .sftp = value },
            },
            .target_endpoint = switch (intent.destination.endpoint) {
                .local_fs => |value| .{ .local_fs = value },
                .sftp => |value| .{ .sftp = value },
            },
        };
        self.tasks.next_transfer_intent += 1;
        const upload = intent.source.endpoint == .local_fs;
        self.showConfirmation(.{ .mode = if (upload) .upload else .download, .owner = intent.owner, .endpoint = host.host, .host_name = host.name, .available = true, .sources = intent.paths, .local_dir = if (upload) intent.source.directory else intent.destination.directory, .remote_dir = if (upload) intent.destination.directory else intent.source.directory });
        self.file_binding = binding;
        self.file_conflict_context = conflict_context;
        self.cx.requestRedraw();
    }

    fn exportFileTransfer(raw: *anyopaque, intent: @import("host/file_workspace_controller.zig").FrozenTransfer, binding: @import("host/session_host.zig").ServiceHandle) !u64 {
        if (intent.source.endpoint != .sftp or intent.destination.endpoint != .local_fs) return error.InvalidExportDirection;
        return enqueueFileTransfer(raw, intent, binding, .{ .resume_transfer = false, .md5_check = true });
    }

    fn cancelFileExport(raw: *anyopaque, id: u64) void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        self.manager.cancel(id) catch |err| applog.warn(.transfer, "file export cancellation: {s}", .{@errorName(err)});
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }

    fn pollFileExport(raw: *anyopaque, id: u64) @import("ui/file_workspace_presentation.zig").ExportStatus {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        const progress = self.manager.progress(id) orelse return .failed;
        return switch (progress.state) {
            .succeeded => .succeeded,
            .failed => .failed,
            .cancelled => .cancelled,
            else => .pending,
        };
    }

    fn confirmFileTransfer(raw: *anyopaque, intent: @import("host/file_workspace_controller.zig").FrozenTransfer, binding: @import("host/session_host.zig").ServiceHandle, options: @import("ui/file_copy_view.zig").Options) !void {
        _ = try enqueueFileTransfer(raw, intent, binding, options);
    }

    fn enqueueFileTransfer(raw: *anyopaque, intent: @import("host/file_workspace_controller.zig").FrozenTransfer, binding: @import("host/session_host.zig").ServiceHandle, options: @import("ui/file_copy_view.zig").Options) !u64 {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        try self.validateNewTransferPolicy();
        const tab_id = self.application.legacyForHandle(intent.owner) orelse return error.TransferOwnerExpired;
        const tab = self.workspace.sessionTab(tab_id) orelse return error.TransferOwnerExpired;
        if (!tab.file_ready or tab.closing or binding.resource_owner != .session or !binding.resource_owner.session.eql(intent.owner) or !self.application.sessions.bindingIsLive(binding)) return error.TransferOwnerExpired;
        if (self.tasks.next_transfer_intent == std.math.maxInt(u64)) return error.IntentIdExhausted;
        try self.tasks.job_owners.ensureUnusedCapacity(self.allocator, 1);
        const upload = intent.source.endpoint == .local_fs;
        const captured: transfer_mod.JobSpec = .{
            .session_id = @backingInt(intent.owner.session_id),
            .transfer_binding = binding,
            .direction = if (upload) .upload else .download,
            .sources = intent.paths,
            .local_dir = if (upload) intent.source.directory else intent.destination.directory,
            .remote_dir = if (upload) intent.destination.directory else intent.source.directory,
            .resume_transfer = options.resume_transfer,
            .md5_check = options.md5_check,
            .chunk_kb = self.workspace.app_config.transfer.chunk_kb,
            .window_chunks = self.workspace.app_config.transfer.window_chunks,
            .conflict_context = .{
                .intent_id = self.tasks.next_transfer_intent,
                .original_owner = intent.owner,
                .resource_owner = binding.resource_owner,
                .source_endpoint = switch (intent.source.endpoint) {
                    .local_fs => |v| .{ .local_fs = v },
                    .sftp => |v| .{ .sftp = v },
                },
                .target_endpoint = switch (intent.destination.endpoint) {
                    .local_fs => |v| .{ .local_fs = v },
                    .sftp => |v| .{ .sftp = v },
                },
            },
        };
        const id = try self.manager.enqueue(captured);
        self.tasks.next_transfer_intent += 1;
        self.tasks.job_owners.appendAssumeCapacity(.{ .job = id, .owner = intent.owner });
        if (@import("platform/runtime_mode.zig").automation) std.debug.print("FILE_TRANSFER_ENQUEUED {{\"job\":{d},\"owner_id\":{d},\"owner_generation\":{d},\"binding_id\":{d},\"binding_generation\":{d},\"md5_check\":{},\"resume_transfer\":{},\"chunk_kb\":{d},\"window_chunks\":{d},\"max_tasks\":{d}}}\n", .{ id, @backingInt(intent.owner.session_id), intent.owner.generation, binding.binding_id, binding.binding_generation, captured.md5_check, captured.resume_transfer, captured.chunk_kb, captured.window_chunks, self.manager.concurrency });
        self.last_job = id;
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
        return id;
    }

    /// 创建 Panel 实例并 mount；回调指向自身。返回浮层根节点。
    fn panel_mounted(self: *TransferHost, cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
        const panel = try cx.allocator.create(transfer_panel_mod.Panel);
        panel.* = .{};
        self.panel = panel;
        const root = try panel.mount(cx, scope);
        panel.on_submit = onTransferSubmit;
        panel.on_submit_frozen = onTransferSubmitFrozen;
        panel.submit_ctx = @ptrCast(self);
        panel.on_cancel = onTransferCancel;
        panel.on_browse = browseSource;
        panel.on_replace_source = replaceSource;
        panel.on_local_directory = browseDirectory;
        return root;
    }

    fn browseSource(raw: *anyopaque) void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        const revision = self.panel.source_revision;
        var buffer: [4096]u8 = undefined;
        const path = ui.platform_services.openFilePanel(self.cx.system_sdk, &buffer) orelse return;
        self.panel.replaceSource(0, revision, path) catch |err| self.panel.setError(@errorName(err));
        self.cx.requestRedraw();
    }

    fn replaceSource(raw: *anyopaque, index: usize, revision: u64) void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        var buffer: [4096]u8 = undefined;
        const path = ui.platform_services.openFilePanel(self.cx.system_sdk, &buffer) orelse return;
        self.panel.replaceSource(index, revision, path) catch |err| self.panel.setError(@errorName(err));
        self.cx.requestRedraw();
    }

    fn browseDirectory(raw: *anyopaque) void {
        const self: *TransferHost = @ptrCast(@alignCast(raw));
        const sdk = self.cx.system_sdk orelse return;
        const ticket = self.panel.directoryTicket() catch return;
        const state = self.application.sessions.queryState(ticket.owner) orelse return;
        const capabilities = (self.application.sessions.capabilitySnapshot(ticket.owner) catch return) orelse return;
        if (!@import("host/actions.zig").project(if (self.panel.mode == .upload) .upload else .download, capabilities).enabled) return;
        const operation = state.create_operation;
        // Keep this path alive across AppKit's nested run loop. Cancelling
        // yields no selection and never changes the confirmation's receipt.
        const initial = self.allocator.dupe(u8, self.panel.local_dir_sig.peek()) catch return;
        defer self.allocator.free(initial);
        var buffer: [4096]u8 = undefined;
        const path = (sdk.runDialog(.{ .kind = .pick_folder, .default_path = initial }, &buffer) catch return) orelse return;
        const current = self.application.sessions.queryState(ticket.owner) orelse return;
        const current_capabilities = (self.application.sessions.capabilitySnapshot(ticket.owner) catch return) orelse return;
        if (current_capabilities.revision != capabilities.revision or current.lifecycle != .attached or !current.create_operation.eql(operation)) return;
        self.panel.applyDirectorySelection(ticket, path) catch return;
        self.cx.requestRedraw();
    }

    fn hookRun(ctx: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *TransferHost = @ptrCast(@alignCast(ctx));
        self.poll();
        self.updateTransferPreview();
        return .done;
    }

    fn submit(self: *TransferHost, spec: transfer_mod.JobSpec) void {
        const owner = self.panel.capturedOwner() orelse return;
        self.submitFrozen(owner, spec) catch |err| self.panel.setError(@errorName(err));
    }

    fn submitFrozen(self: *TransferHost, owner: @import("host/identity.zig").SessionHandle, spec: transfer_mod.JobSpec) !void {
        try self.validateNewTransferPolicy();
        if (self.file_binding) |binding| {
            if (binding.resource_owner != .session or !binding.resource_owner.session.eql(owner) or !self.application.sessions.bindingIsLive(binding)) return error.TransferOwnerExpired;
            try self.tasks.job_owners.ensureUnusedCapacity(self.allocator, 1);
            var captured = spec;
            captured.chunk_kb = self.workspace.app_config.transfer.chunk_kb;
            captured.window_chunks = self.workspace.app_config.transfer.window_chunks;
            captured.transfer_binding = binding;
            captured.conflict_context = self.file_conflict_context orelse return error.MissingConflictContext;
            captured.session_id = @backingInt(owner.session_id);
            const id = try self.manager.enqueue(captured);
            self.tasks.job_owners.appendAssumeCapacity(.{ .job = id, .owner = owner });
            if (@import("platform/runtime_mode.zig").automation) std.debug.print("FILE_TRANSFER_ENQUEUED {{\"job\":{d},\"owner_id\":{d},\"owner_generation\":{d},\"binding_id\":{d},\"binding_generation\":{d},\"md5_check\":{},\"resume_transfer\":{},\"chunk_kb\":{d},\"window_chunks\":{d},\"max_tasks\":{d}}}\n", .{ id, @backingInt(owner.session_id), owner.generation, binding.binding_id, binding.binding_generation, captured.md5_check, captured.resume_transfer, captured.chunk_kb, captured.window_chunks, self.manager.concurrency });
            self.last_job = id;
            self.file_binding = null;
            self.file_conflict_context = null;
            self.panel.hide();
            self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
            return;
        }
        const index = for (self.workspace.tabs.items, 0..) |tab, index| {
            if (tab.content_owner.eql(.{ .session = owner })) break index;
        } else return error.TransferOwnerExpired;
        const tab = self.workspace.tabs.items[index];
        if (!tab.content_owner.eql(.{ .session = owner }) or tab.closing or tab.archived or tab.failed or tab.runtime == null) return error.TransferOwnerExpired;
        try self.submitSessionTransfer(owner, spec);
    }

    fn refreshCompletedTransfers(self: *TransferHost) void {
        const presentation = self.files.presentation orelse return;
        captures: for (self.tasks.job_owners.items, 0..) |*captured, captured_index| {
            for (self.tasks.job_owners.items[0..captured_index]) |previous| if (previous.job == captured.job) continue :captures;
            const progress = self.manager.progress(captured.job) orelse continue;
            if (progress.state != .succeeded or progress.job_cleanup != .released) continue;
            for (self.manager.jobs.items) |job| {
                if (job.id != captured.job) continue;
                const context = job.spec.conflict_context orelse break;
                if (!context.original_owner.eql(captured.owner)) break;
                const upload = job.spec.direction == .upload;
                if ((upload and context.target_endpoint != .sftp) or (!upload and context.target_endpoint != .local_fs)) break;
                _ = captured.directory_refresh.update(progress, .{ .owner = captured.owner, .endpoint = switch (context.target_endpoint) {
                    .local_fs => |value| .{ .local_fs = value },
                    .sftp => |value| .{ .sftp = value },
                }, .side = if (upload) .remote else .local, .directory = if (upload) job.spec.remote_dir else job.spec.local_dir }, presentation.modelFor(captured.owner)) catch |err| {
                    applog.warn(.transfer, "completed transfer directory refresh: {s}", .{@errorName(err)});
                    self.workspace.statusFailure("传输已完成，目标目录刷新失败，请重新读取");
                    break;
                };
                break;
            }
        }
    }

    /// after-layout 轮询：连接完成→消费挂起任务；活跃→tick + 进度行。
    fn poll(self: *TransferHost) void {
        if (!self.picker_running) self.pollCommandPicker();
        if (self.cwd_pending) |pending| cwd: {
            if (!self.panel.open.peek()) {
                self.cwd_pending = null;
                break :cwd;
            }
            const id = self.application.legacyForHandle(pending.owner) orelse {
                self.cwd_pending = null;
                break :cwd;
            };
            const tab = self.workspace.sessionTab(id) orelse {
                self.cwd_pending = null;
                break :cwd;
            };
            const runtime = tab.runtime orelse {
                self.cwd_pending = null;
                break :cwd;
            };
            const path = runtime.workerPtr().copyCwd(self.allocator) catch null;
            defer if (path) |value| self.allocator.free(value);
            if (path) |value| {
                self.panel.remote_dir_sig.set(value);
                self.panel.remote_hint.setTextContent(self.allocator, "已自动填入执行 @up 时的远程目录") catch {};
                self.cwd_pending = null;
            } else if (wallClockMsTransfer() -| pending.started > 5000) {
                self.panel.remote_hint.setTextContent(self.allocator, "未能读取当前目录，请在终端空闲时重新执行 @up") catch {};
                self.cwd_pending = null;
            } else self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
        }
        if (self.reveal_requested) |request| {
            self.reveal_requested = null;
            self.revealCompleted(request.job, request.attempt, request.owner) catch |err| self.workspace.statusFailure(@errorName(err));
        }
        if (self.manager_open_requested) {
            self.manager_open_requested = false;
            self.showGlobalManager();
        }
        if (self.sftp_open_requested) {
            self.sftp_open_requested = false;
            self.showExistingSftp();
        }
        self.pollShared() catch |err| applog.warn(.transfer, "shared transfer receipt: {s}", .{@errorName(err)});
        self.pollAuxiliary() catch |err| applog.warn(.transfer, "auxiliary transfer receipt: {s}", .{@errorName(err)});
        self.pollRetained() catch |err| {
            applog.warn(.transfer, "retained transfer receipt: {s}", .{@errorName(err)});
        };
        if (self.manager_panel) |panel| self.manager_visible = panel.root.style.display != .none;
        if (self.manager_visible) {
            const now = wallClockMsTransfer();
            if (now -| self.manager_last_refresh_ms >= 250) {
                self.manager_last_refresh_ms = now;
                if (self.manager_panel) |panel| {
                    panel.refresh(now, .{
                        .window_chunks = self.workspace.app_config.transfer.window_chunks,
                        .chunk_kb = self.workspace.app_config.transfer.chunk_kb,
                    }) catch |err| applog.warn(.transfer, "transfer window refresh: {s}", .{@errorName(err)});
                }
            }
        }
        self.refreshProgressRow();
        if (self.manager.count() != 0) {
            // Lower limits stop new scheduling until existing jobs drain;
            // accepted jobs keep their own frozen transfer policy.
            _ = self.tasks.tick(wallClockMsTransfer(), self.workspace.app_config.transfer.max_tasks) catch |err| applog.warn(.transfer, "application task tick: {s}", .{@errorName(err)});
            self.refreshCompletedTransfers();
            if (process_notifications) |notifications| for (self.tasks.job_owners.items) |captured| {
                const progress = self.manager.progress(captured.job) orelse continue;
                if (progress.job_cleanup != .released or (progress.state != .succeeded and progress.state != .failed and progress.state != .cancelled)) continue;
                const completed_job = for (self.manager.jobs.items) |job| {
                    if (job.id == captured.job) break job;
                } else continue;
                const notify_complete = completed_job.spec.notify_complete;
                var transfer_object_buffer: [1024]u8 = undefined;
                const first_source = if (completed_job.spec.sources.len > 0) std.fs.path.basename(completed_job.spec.sources[0]) else "文件传输";
                const transfer_object = if (completed_job.spec.sources.len > 1) std.fmt.bufPrint(&transfer_object_buffer, "{s} 等 {d} 项", .{ first_source, completed_job.spec.sources.len }) catch first_source else first_source;
                notifications.publishTransfer(.{ .session = captured.owner }, progress.job, progress.attempt, .{ .result = if (progress.state == .succeeded) .succeeded else if (progress.state == .failed) .failed else .cancelled, .resources_released = true, .notify_complete = notify_complete, .details = .{ .object = transfer_object, .detail = if (progress.failure) |failure| @import("ui/transfer_manager_view.zig").failureLabel(failure) else "" } }) catch |err| applog.warn(.app, "transfer notification: {s}", .{@errorName(err)});
            };
            if (@import("platform/runtime_mode.zig").automation) for (self.tasks.job_owners.items) |*captured| {
                const progress = self.manager.progress(captured.job) orelse continue;
                const v = progress.verification orelse continue;
                if (progress.state != .succeeded or v.state != .passed or v.source_md5 == null or v.target_md5 == null or captured.verification_trace_attempt == progress.attempt) continue;
                std.debug.print("FILE_TRANSFER_MANAGER_VERIFICATION {{\"job\":{d},\"attempt\":{d},\"owner_id\":{d},\"owner_generation\":{d},\"state\":\"{s}\",\"verification_state\":\"{s}\",\"source_md5\":\"{s}\",\"target_md5\":\"{s}\"}}\n", .{ progress.job, progress.attempt, @backingInt(captured.owner.session_id), captured.owner.generation, @tagName(progress.state), @tagName(v.state), std.fmt.bytesToHex(v.source_md5.?, .lower), std.fmt.bytesToHex(v.target_md5.?, .lower) });
                captured.verification_trace_attempt = progress.attempt;
            };
            // 终态上抛：失败原因可见（成功不打扰）。
            if (self.manager.progressAt(self.manager.count() - 1)) |snap| {
                if (snap.state == .failed and self.failure_reported.swap(1, .acq_rel) == 0) {
                    const reason: []const u8 = if (snap.failure) |f| switch (f) {
                        .connection => "连接失败",
                        .timeout => "超时",
                        .permission_denied => "权限不足",
                        .not_found => "文件不存在",
                        .checksum => "校验失败",
                        .invalid_request => "参数错误",
                        .conflict => "冲突",
                        .protocol => "协议错误",
                        .io => "IO 错误",
                    } else "未知错误";
                    var buffer: [96]u8 = undefined;
                    var writer = std.Io.Writer.fixed(&buffer);
                    writer.print("传输失败：{s}（已重试 {d} 次）", .{ reason, snap.attempt }) catch {};
                    self.workspace.status(writer.buffered());
                }
            }
        }
        self.refreshConflict() catch |err| applog.warn(.transfer, "transfer conflict presentation: {s}", .{@errorName(err)});
        const busy = self.manager.count() > 0;
        if (busy) self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
    }

    fn currentTransferScope(self: *TransferHost, a: std.mem.Allocator) !?transfer_manager_view.Scope {
        if (self.workspace.active_group_view) |id| {
            const roster = self.workspace.group_roster orelse return null;
            const group = roster.findById(id) orelse return null;
            var members: std.ArrayList(@import("host/identity.zig").SessionHandle) = .empty;
            for (group.members.items) |member| {
                if (!member.active) continue;
                for (self.workspace.tabs.items) |tab| {
                    if (tab.id != member.pane_id or tab.content_owner != .session or tab.archived or tab.closing) continue;
                    try members.append(a, tab.content_owner.session);
                    break;
                }
            }
            if (members.items.len == 0) return null;
            return .{ .sessions = .{ .members = members.items, .revision = group.membership_revision } };
        }
        const index = self.workspace.active_tab orelse return null;
        if (index >= self.workspace.tabs.items.len) return null;
        const tab = self.workspace.tabs.items[index];
        if (tab.archived or tab.closing or tab.content_owner != .session) return null;
        const snapshot = (try self.application.sessions.capabilitySnapshot(tab.content_owner.session)) orelse return null;
        if (!@import("host/actions.zig").project(.upload, snapshot).visible) return null;
        return .{ .session = tab.content_owner.session };
    }
    fn showCurrentTransfers(self: *TransferHost) void {
        const panel = self.session_panel orelse return;
        if (panel.root.style.display != .none and self.transfer_pinned) {
            panel.hide();
            self.transfer_pinned = false;
            self.transfer_suppressed = true;
            return;
        }
        self.transfer_pinned = true;
        self.openCurrentTransfers();
    }
    fn openCurrentTransfers(self: *TransferHost) void {
        self.ticker_last_refresh_ms = 0;
        self.refreshProgressRow();
        const captured = self.ticker_scope orelse return;
        const panel = self.session_panel orelse return;
        self.closeManagerPopover();
        panel.selected_scope = captured;
        panel.refresh(wallClockMsTransfer(), .{ .window_chunks = self.workspace.app_config.transfer.window_chunks, .chunk_kb = self.workspace.app_config.transfer.chunk_kb }) catch return;
        panel.show();
        self.transfer_preview = true;
    }
    fn updateTransferPreview(self: *TransferHost) void {
        const ticker = self.status_transfer orelse return;
        const panel = self.session_panel orelse return;
        const x = self.cx.mouse_x;
        const y = self.cx.mouse_y;
        const trigger = ticker.root.globalRect();
        const inside = ticker.root.isDisplayedInTree() and x >= trigger.x and x <= trigger.x + trigger.w and y >= trigger.y and y <= trigger.y + trigger.h;
        const shown = panel.root.style.display != .none;
        if (self.transfer_preview and !shown) {
            self.transfer_preview = false;
            self.transfer_pinned = false;
            self.transfer_suppressed = true;
        }
        if (!inside) self.transfer_suppressed = false;
        if (inside and !shown and !self.transfer_suppressed) self.openCurrentTransfers();
        if (!self.transfer_preview or self.transfer_pinned) return;
        const rect = panel.root.globalRect();
        const in_panel = x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h;
        if (inside or in_panel) self.transfer_leave_ms = null else {
            const now = wallClockMsTransfer();
            if (self.transfer_leave_ms) |started| {
                if (now -| started >= 150) {
                    panel.dismiss();
                    self.transfer_preview = false;
                    self.transfer_leave_ms = null;
                }
            } else self.transfer_leave_ms = now;
        }
        self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
    }
    const FileTrayLink = struct {
        tab: *ws.SessionTab,
        index: usize,
        fn release(self: *@This()) void {
            self.tab.transfer_trays[self.index] = null;
        }
    };
    fn refreshFileTrays(self: *TransferHost, now: u64) void {
        const presentation = self.files.presentation orelse return;
        for (self.workspace.tabs.items) |tab| {
            if (tab.content_owner != .session or tab.closing or tab.archived) continue;
            const owner = tab.content_owner.session;
            const scope = presentation.transferScopeFor(owner) orelse continue;
            for ([_]@import("ui/file_workspace_view.zig").Side{ .local, .remote }, 0..) |side, index| {
                const slot = presentation.transferSlotFor(owner, side) orelse continue;
                if (tab.transfer_trays[index] == null) {
                    const panel = transfer_manager_view.mountSessionTray(self.cx, scope, self.manager, .{ .context = self, .action = managerAction, .scope_choices = transferScopeChoices, .owner = jobOwner, .owner_label = jobOwnerLabel, .can_reveal = canReveal, .open_sftp = requestSessionSftp, .open_manager = requestGlobalManager }) catch continue;
                    panel.setDirectionFilter(if (side == .local) .upload else .download);
                    const link = scope.createState(FileTrayLink, .{ .tab = tab, .index = index }) catch continue;
                    scope.onCleanup(FileTrayLink, link, FileTrayLink.release) catch continue;
                    slot.appendChild(self.allocator, panel.root) catch continue;
                    tab.transfer_trays[index] = panel;
                }
                const panel = tab.transfer_trays[index].?;
                panel.selected_scope = .{ .session = owner };
                panel.refresh(now, .{ .window_chunks = self.workspace.app_config.transfer.window_chunks, .chunk_kb = self.workspace.app_config.transfer.chunk_kb }) catch continue;
                panel.show();
            }
        }
    }
    fn refreshProgressRow(self: *TransferHost) void {
        const view = self.status_transfer orelse return;
        const now = wallClockMsTransfer();
        var next_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer next_arena.deinit();
        const next = self.currentTransferScope(next_arena.allocator()) catch return;
        const changed = if (next) |scope| if (self.ticker_scope) |previous| !transfer_manager_view.scopeEql(scope, previous) else true else self.ticker_scope != null;
        if (changed) {
            // Dismiss before freeing: the open panel's selection can point into
            // the retained roster until refresh has copied its snapshot.
            if (self.session_panel) |panel| panel.dismiss();
            if (self.ticker_scope_arena) |*arena| arena.deinit();
            self.ticker_scope_arena = next_arena;
            next_arena = std.heap.ArenaAllocator.init(self.allocator);
            self.ticker_scope = next;
            self.ticker_started_ms = now;
            self.ticker_last_refresh_ms = 0;
        }
        view.root.setDisplay(if (self.ticker_scope == null) .none else .flex);
        const captured = self.ticker_scope orelse return;
        if (now -| self.ticker_last_refresh_ms < 250) return;
        self.ticker_last_refresh_ms = now;
        self.refreshFileTrays(now);
        var active: usize = 0;
        var running: usize = 0;
        var waiting: usize = 0;
        var latest: ?usize = null;
        for (0..self.manager.count()) |index| {
            const value = self.manager.progressAt(index) orelse continue;
            if (!transfer_manager_view.belongs(captured, self.tasks.ownerForJob(value.job))) continue;
            latest = index;
            if (value.state == .running) running += 1;
            if (value.state == .queued or value.state == .retry_wait) waiting += 1;
            if (value.state != .succeeded and value.state != .failed and value.state != .cancelled) active += 1;
        }
        var chosen = latest;
        if (active > 0) {
            var target = @as(usize, @intCast((now -| self.ticker_started_ms) / 3000)) % active;
            for (0..self.manager.count()) |index| {
                const value = self.manager.progressAt(index) orelse continue;
                if (!transfer_manager_view.belongs(captured, self.tasks.ownerForJob(value.job)) or value.state == .succeeded or value.state == .failed or value.state == .cancelled) continue;
                if (target == 0) {
                    chosen = index;
                    break;
                }
                target -= 1;
            }
        }
        if (chosen) |index| {
            const value = self.manager.progressAt(index).?;
            var pct_buffer: [32]u8 = undefined;
            var count_buffer: [48]u8 = undefined;
            const fraction: f32 = if (value.total_bytes == 0) 0 else @min(1, @as(f32, @floatFromInt(value.done_bytes)) / @as(f32, @floatFromInt(value.total_bytes)));
            const pct = if (value.state == .running) (if (value.total_bytes == 0) "传输中" else std.fmt.bufPrint(&pct_buffer, "{d:.0}%", .{fraction * 100}) catch "") else transfer_manager_view.phaseLabel(std.meta.stringToEnum(transfer_manager_view.Phase, @tagName(value.state)) orelse .queued);
            const counts = std.fmt.bufPrint(&count_buffer, "{d}传·{d}候", .{ running, waiting }) catch "";
            view.update(self.manager.sourceName(index) orelse "传输任务", pct, counts, fraction, self.manager.jobs.items[index].spec.direction == .upload);
        } else view.update("传输 · 空闲", "", "", 0, false);
        if (self.session_panel) |panel| if (panel.root.style.display != .none) {
            panel.refresh(now, .{ .window_chunks = self.workspace.app_config.transfer.window_chunks, .chunk_kb = self.workspace.app_config.transfer.chunk_kb }) catch {};
        };
    }

    fn cleanup(self: *TransferHost) void {
        if (self.command_picker) |request| self.allocator.free(request.source);
        self.cx.removeAfterLayoutHook(self);
        if (self.ticker_scope_arena) |*arena| arena.deinit();
        // Native transfer resources are exclusively owned by the process task
        // domain and provider bindings; a window only releases its presenter.
        self.allocator.destroy(self);
    }
};

fn onTransferSubmit(ctx: *anyopaque, spec: transfer_mod.JobSpec) void {
    TransferHost.submit(@ptrCast(@alignCast(ctx)), spec);
}

fn onTransferSubmitFrozen(ctx: *anyopaque, owner: @import("host/identity.zig").SessionHandle, spec: transfer_mod.JobSpec) !void {
    const host: *TransferHost = @ptrCast(@alignCast(ctx));
    try host.submitFrozen(owner, spec);
}

fn onSocksChipClick(raw: *anyopaque) void {
    const host: *Socks5Host = @ptrCast(@alignCast(raw));
    host.showInfo();
}

fn onTransferCancel(ctx: *anyopaque) void {
    const self: *TransferHost = @ptrCast(@alignCast(ctx));
    self.panel.hide();
    self.file_binding = null;
    self.cx.requestRedraw();
}

/// Snapshot-only presentation over the original SessionHost SOCKS owner.
const Socks5Host = @import("ui/socks_application_host.zig").Host;

fn wallClockMsTransfer() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn dataStartupAlert(err: anyerror, reset_pending: bool) bool {
    const Native = struct {
        extern fn zw_data_startup_alert([*:0]const u8, c_int, [*]const u8, usize) c_int;
    };
    const icon = @import("app_icon_assets").transparent;
    return Native.zw_data_startup_alert(@errorName(err), if (reset_pending) 1 else 0, icon.ptr, icon.len) != 0;
}

pub fn main() !void {
    @import("vt/input_timing.zig").configure();
    @import("vt/output_timing.zig").configure();
    try @import("platform/ui_fonts.zig").register();
    const presentation = @import("platform/presentation_wakeup.zig");
    presentation.wake_fn = struct {
        fn wake() void {
            @FieldType(App, "win").postEmptyEvent();
        }
    }.wake;

    var data_paths = try DataPaths.forApplication(std.heap.c_allocator);
    defer data_paths.deinit();
    var scope_lock = @import("platform/data_scope_lock.zig").Lock.acquire(std.heap.c_allocator, data_paths.directory, data_paths.is_override) catch |err| {
        _ = dataStartupAlert(err, false);
        return err;
    };
    defer scope_lock.release();
    var io_threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer io_threaded.deinit();
    const lifecycle = @import("config/data_lifecycle.zig");
    const credentials = @import("config/credential_store.zig");
    try credentials.configureScope(data_paths.directory, data_paths.is_override);
    _ = lifecycle.prepare(io_threaded.io(), &data_paths) catch |err| {
        if (err == error.ResetIncomplete and dataStartupAlert(err, true)) {
            credentials.eraseScope() catch |failure| {
                _ = dataStartupAlert(failure, false);
                return failure;
            };
            const report = try lifecycle.eraseOwned(io_threaded.io(), &data_paths);
            for (report.items[0..report.count]) |item| if (item.failure) |failure| {
                _ = dataStartupAlert(failure, false);
                return failure;
            };
            return;
        }
        if (err != error.ResetIncomplete) _ = dataStartupAlert(err, false);
        return err;
    };
    @import("config/store.zig").prepareCredentials(io_threaded.io(), std.Io.Dir.cwd(), std.heap.c_allocator, data_paths.config, data_paths.hosts) catch |err| {
        if ((err == error.CredentialDenied or err == error.CredentialLocked) and dataStartupAlert(err, false)) {
            credentials.authorizeScope() catch |failure| {
                // Do not offer another authorization loop after cancel/denial.
                _ = dataStartupAlert(error.CredentialAuthorizationFailed, false);
                return failure;
            };
            @import("config/store.zig").prepareCredentials(io_threaded.io(), std.Io.Dir.cwd(), std.heap.c_allocator, data_paths.config, data_paths.hosts) catch |failure| {
                _ = dataStartupAlert(error.CredentialAuthorizationFailed, false);
                return failure;
            };
        } else {
            if (err != error.CredentialDenied and err != error.CredentialLocked) _ = dataStartupAlert(err, false);
            return err;
        }
    };
    applog.init(.{}, io_threaded.io());
    defer applog.shutdown();
    applog.info(.app, "ZeroWork starting", .{});
    const notifications = try NotificationHost.create(std.heap.c_allocator, .{});
    defer notifications.destroy();
    process_notifications = notifications;
    defer process_notifications = null;
    var contributions = try @import("plugins/application_plugins.zig").Bundle(@import("application_options").plugin_fixture).init(std.heap.c_allocator);
    defer contributions.deinit();
    const domain = try application_host_mod.Domain.initWithContributions(std.heap.c_allocator, true, contributions.manifests(), contributions.renderers());
    for (domain.sessions.registry.manifests()) |manifest| for (manifest.notifications) |definition| try notifications.registerDefinition(definition);
    var windows = MultiWindowApp.init(std.heap.c_allocator, .{ .shared_gpu = true });
    var process: ProcessWindows = .{ .runtime = &windows, .domain = domain, .io = io_threaded.io(), .data_paths = &data_paths };
    defer {
        domain.deinit();
        process.deinit();
    }
    process.font_system = try @FieldType(App, "font_manager").init(std.heap.c_allocator, io_threaded.io());
    process.font_system.?.setDefaultFamily("Inter Variable");
    process_windows = &process;
    defer process_windows = null;
    var registry = FontRegistry.init(std.heap.c_allocator);
    defer registry.deinit();
    defer {
        @import("ui/plugin_window_host.zig").Host.prepareShutdown(domain);
        windows.deinit();
    }
    const app = try windows.createWindow(.{
        .io = io_threaded.io(),
        .font = .{ .fallback_families = @import("platform/ui_fonts.zig").families },
        .window = .{ .width = 1440, .height = 900, .min_width = 860, .min_height = 480, .title = "ZeroWork", .titlebar = .custom_inset, .titlebar_height = shell_styles.outer + shell_styles.title_height, .titlebar_drag_right_inset = 150 },
    });
    process.primary = app;
    app.win.setTrafficLightsLayout(shell_styles.outer + 20, shell_styles.outer + shell_styles.title_height / 2, 12);
    installMonospaceFonts(app);
    registry.setFontSystem(&process.font_system.?);
    app.setFontRegistry(&registry);
    if (application_test_mode) try verifyUiFontPaths(app);
    app_font_registry = &registry;
    defer app_font_registry = null;
    try app.mount(mountUI);
    const nav: *AppNavHost = @ptrCast(@alignCast(app.cx.root.?.behavior.events.capture_context orelse return error.MissingApplicationController));
    nav.app_runtime = app;
    try nav.loadEmptyLogo();
    if (nav.settings) |settings| settings.app_runtime = app;
    _ = @import("ui/plugin_window_host.zig").Host.mount(app, nav.application_host orelse return error.MissingApplicationController, process_notifications, if (nav.ai) |ai| ai.notification_window else null) catch |err| {
        applog.err(.app, "plugin window services initialization: {s}", .{@errorName(err)});
        return err;
    };
    if (nav.ai) |ai| if (ai.images_view) |view| {
        view.app = app;
    };
    app.setCloseRequestHandler(.{ .context = nav, .request = AppNavHost.nativeCloseRequest, .completed = AppNavHost.nativeCloseCompleted });
    @import("ui/multiwindow_test_routes.zig").install(domain, &windows);
    // The callback has no Cx/window pointer and remains valid through worker cleanup.
    while (windows.shouldContinue()) {
        const changed = presentation.take();
        if (changed) for (windows.windows.items) |managed| managed.app.cx.requestRedraw();
        // A native empty event interrupts a blocking tick; consume its publication
        // at this next loop boundary without another timed wait before painting.
        windows.config.pump_timeout_ms = if (changed) 0 else 16;
        if (!try windows.tick()) break;
        @import("vt/input_timing.zig").frameReturned();
        if (process.data_cleanup_exit) break;
        if (process.data_cleanup_pending) {
            process.data_cleanup_pending = false;
            if (process.data_cleanup_owner) |owner| owner.performDataCleanup();
            if (process.data_cleanup_exit) break;
        }
        if (process.data_cleanup_owner == null) process.drain(&registry);
    }
}

/// Terminal cell geometry depends on a TRUE monospace font: the VT grid maps
/// 1 column = 1 advance, and syncGridSize derives cols from the measured
/// advance. Zenit's stock macOS FontSelector never registers the mono group
/// (mono_count stays 0), so `use_monospace` silently fell back to the
/// proportional UI font (Helvetica Neue) — its wide "M" advance (~11.6px at
/// 13pt) inflated every cell, halved the visible column count and rendered
/// the terminal with visible inter-glyph gaps. Registering Menlo in the mono
/// slots (regular/bold/italic/bold-italic) makes selectMonospaceWeighted
/// return a real fixed-advance face for both shaping and rendering.
// Exercise the renderer selector, contextual and legacy measurement hooks,
// and the same shaped run used by input caret/selection in test builds.
fn verifyUiFontPaths(app: *App) !void {
    const samples = [_][]const u8{ "Local Terminal", "worker 为什么反复重启？先检查日志。", "Inter caret ssdf 🈶" };
    const actual = app.fonts[0].debugName(std.heap.c_allocator) orelse return error.UiFontUnavailable;
    defer std.heap.c_allocator.free(actual);
    applog.info(.app, "UI font actual={s} family={s}", .{ actual, app.resolved_font_family orelse "missing" });
    for (samples) |sample| {
        const size: f32 = 11.5;
        const draw = app.font_selector.measureTextWidthWithProps(sample, .{ .font_size = size });
        const contextual = app.cx.text.measure_ctx_fn.?(app.cx.text.measure_ctx.?, sample.ptr, sample.len, size, 400, false);
        const legacy = app.cx.text.measure_fn.?(sample.ptr, sample.len, size, 400, false);
        const shaped = app.cx.text.measureTextWidth(sample, size, 400, false);
        applog.info(.app, "UI font paths text={s} draw={d:.4} context={d:.4} legacy={d:.4} shaped={d:.4}", .{ sample, draw, contextual, legacy, shaped });
        if (@abs(draw - contextual) > 0.05 or @abs(draw - legacy) > 0.05 or @abs(draw - shaped) > 0.05) return error.UiFontPathMismatch;
    }
}

fn installMonospaceFonts(app: *App) void {
    const Presence = struct {
        extern fn coretext_family_exists(family: [*:0]const u8) c_int;
    };
    // CoreText may return a proportional substitute for an absent family.
    // Check availability before registering the shared command/log font role.
    const family: [:0]const u8 = if (Presence.coretext_family_exists("JetBrains Mono") != 0) "JetBrains Mono" else "Menlo";
    app.font_selector.mono_count = 0;
    app.font_selector.mono_bold_count = 0;
    app.font_selector.mono_italic_count = 0;
    app.font_selector.mono_bold_italic_count = 0;
    // findFont's descriptor is a struct literal: the enum field values
    // (.regular/.bold/.normal/.italic) coerce to the backend's own
    // FontWeight/FontStyle, so no type import is needed.
    const attempts = [_]struct { size: f32, bold: bool, italic: bool }{
        .{ .size = 13, .bold = false, .italic = false },
        .{ .size = 13, .bold = true, .italic = false },
        .{ .size = 13, .bold = false, .italic = true },
        .{ .size = 13, .bold = true, .italic = true },
        .{ .size = 14, .bold = false, .italic = false },
        .{ .size = 14, .bold = true, .italic = false },
    };
    for (attempts) |attempt| {
        const font = app.font_manager.findFont(.{
            .family = family,
            .size = attempt.size,
            .weight = if (attempt.bold) .bold else .regular,
            .style = if (attempt.italic) .italic else .normal,
        }) catch continue;
        font.setScaleFactor(app.scale);
        if (attempt.bold and attempt.italic) {
            if (app.font_selector.mono_bold_italic_count == 0) {
                app.font_selector.mono_bold_italic_fonts[0] = font;
                app.font_selector.mono_bold_italic_count = 1;
            }
        } else if (attempt.italic) {
            if (app.font_selector.mono_italic_count == 0) {
                app.font_selector.mono_italic_fonts[0] = font;
                app.font_selector.mono_italic_count = 1;
            }
        } else if (attempt.bold) {
            if (app.font_selector.mono_bold_count < app.font_selector.mono_bold_fonts.len) {
                app.font_selector.mono_bold_fonts[app.font_selector.mono_bold_count] = font;
                app.font_selector.mono_bold_count += 1;
            }
        } else {
            if (app.font_selector.mono_count < app.font_selector.mono_fonts.len) {
                app.font_selector.mono_fonts[app.font_selector.mono_count] = font;
                app.font_selector.mono_count += 1;
            }
        }
    }
    applog.info(.app, "monospace slots: mono={d} bold={d} italic={d} bold_italic={d}", .{
        app.font_selector.mono_count,
        app.font_selector.mono_bold_count,
        app.font_selector.mono_italic_count,
        app.font_selector.mono_bold_italic_count,
    });
}

test "settings retained decision repaints Dark creation after close Light reopen without replacing draft or modal" {
    const before = app_theme.currentName();
    defer app_theme.select(before);
    app_theme.select(.dark);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const panel = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = panel;
    var controller = try SettingsController.init(std.testing.allocator, .{});
    defer controller.deinit();
    try controller.editKey("ui", "font_size", .{ .unsigned = 18 });
    var host: SettingsHost = .{ .allocator = std.testing.allocator, .cx = cx, .scope = scope, .controller = controller, .runtime = undefined, .io = std.testing.io, .panel = panel, .status = panel };
    try host.showDecision(.reset);
    cx.frame_count += 1;
    cx.frame_time_ms += 16;
    _ = cx.render();
    const dialog = host.decision_dialog.?;
    const title = host.decision_title_node.?;
    const draft = host.controller.draft_id;
    host.cancelDecision();
    cx.frame_count += 1;
    cx.frame_time_ms += 16;
    _ = cx.render();
    app_theme.select(.light);
    cx.setTheme(app_theme.widgetTheme(.light));
    try host.showDecision(.close);
    cx.frame_count += 1;
    cx.frame_time_ms += 16;
    _ = cx.render();
    try std.testing.expectEqual(dialog, host.decision_dialog.?);
    try std.testing.expectEqual(title, host.decision_title_node.?);
    try std.testing.expectEqual(app_theme.current().overlay, dialog.getBackground());
    try std.testing.expectEqual(app_theme.current().fg_1, title.getText().?.color);
    try std.testing.expectEqual(app_theme.current().fg_2, host.decision_message_node.?.getText().?.color);
    try std.testing.expectEqual(app_theme.current().fg_2, host.decision_notice.?.getText().?.color);
    try std.testing.expectEqual(draft, host.controller.draft_id);
    try std.testing.expectEqual(@as(u8, 18), host.controller.model.value.ui.font_size);
    try std.testing.expect(host.controller.model.dirty);
    host.cancelDecision();
    try std.testing.expect(!host.decision_open.?.get());
}
