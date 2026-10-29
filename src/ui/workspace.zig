const std = @import("std");
const applog = @import("../platform/applog.zig");
const ui = @import("ui");
const design = @import("design.zig");
const tab_rename = @import("tab_rename.zig");
const lifecycle = @import("session_lifecycle.zig");
const TerminalViewNode = @import("terminal_view.zig").TerminalViewNode;
const Tombstone = @import("session_tombstone.zig").Tombstone;
const host_key_confirmation = @import("host_key_confirmation.zig");
const SessionRuntime = @import("../host/runtime_service.zig").Runtime;
const RuntimeReleaseReceipt = @import("../host/runtime_service.zig").ReleaseReceipt;
const ResourceLedger = @import("../proto/ssh/session.zig").ResourceLedger;
const TextSlot = @import("../vt/text_slot.zig").TextSlot;
const hosts_mod = @import("../config/hosts.zig");
const store = @import("../config/store.zig");
const config_mod = @import("../config/config.zig");
const auth_challenge = @import("../proto/ssh/auth_challenge.zig");
const identity = @import("../host/identity.zig");
const OperationKey = @import("../host/operation.zig").OperationKey;
const workspace_model = @import("workspace_model.zig");
const tab_layout = @import("tab_strip_layout.zig");
const tab_styles = @import("workspace_tab_styles.zig");
const app_theme = @import("app_theme.zig");
const tab_picker = @import("tab_picker.zig");
const tab_color_picker = @import("tab_color_picker.zig");
const host_actions = @import("../host/actions.zig");
const keybindings = @import("../config/keybindings.zig");
const terminal_service = @import("../host/terminal_service.zig");
const local_styles = @import("local_session_styles.zig");
const RemoteNotice = @import("remote_session_notice.zig");
const session_icon = @import("session_icon.zig");
const group_view = @import("group_workspace_model.zig");
const group_close = @import("group_close_controller.zig");
const group_close_view = @import("group_close_view.zig");
const group_styles = @import("group_workspace_styles.zig");
const group_model = @import("group_model.zig");
const sidebar_view = @import("sidebar_view.zig");
const plugin_registry = @import("../host/plugin_registry.zig");
const plugin_ui = @import("../host/plugin_ui_contract.zig");
const envelopes = @import("../config/connection_envelope.zig");

var tab_ids: identity.Allocator(identity.TabId) = .{};
var history_ids: identity.Allocator(identity.HistoryId) = .{};

pub const Palette = struct {
    bg: ui.Color,
    chrome: ui.Color,
    sidebar: ui.Color,
    fg: ui.Color,
    fg_secondary: ui.Color,
    fg_muted: ui.Color,
    accent: ui.Color,
    border: ui.Color,
    green: ui.Color,
    red: ui.Color,
    status_bg: ui.Color,
    terminal_bg: ui.Color,

    pub fn fromTheme() Palette {
        const colors = app_theme.current();
        return .{
            .bg = colors.app,
            .chrome = colors.surface_1,
            .sidebar = colors.surface_1,
            .fg = colors.fg_1,
            .fg_secondary = colors.fg_2,
            .fg_muted = colors.fg_3,
            .accent = colors.accent,
            .border = colors.border,
            .green = colors.ok,
            .red = colors.danger,
            .status_bg = colors.surface_1,
            .terminal_bg = colors.terminal,
        };
    }
};

pub fn hex(rgba: u32) ui.Color {
    return ui.Color.hex(@truncate(rgba >> 8));
}

pub fn dot(cx: *ui.Cx, size: f32, color: ui.Color) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = size },
        .height = .{ .px = size },
        .background = color,
        .border = .{ .width = 0, .color = color, .radius = size / 2 },
    }, .{});
}

pub fn separator(cx: *ui.Cx, p: Palette) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = 1 },
        .height = .{ .px = 14 },
        .margin = .{ .top = 0, .right = 6, .bottom = 0, .left = 6 },
        .background = p.border,
    }, .{});
}

pub const HostId = lifecycle.HostId;
pub const SessionId = lifecycle.SessionId;
const HostSnapshot = lifecycle.Snapshot(hosts_mod.HostConfig);
pub const removed_host_index = std.math.maxInt(usize);

/// One open session tab: UI nodes + live runtime (null until connected).
pub const SessionTab = struct {
    group_broadcast_enabled: bool = false,
    tab_color: ?u32 = null,
    id: SessionId,
    tab_id: identity.TabId,
    content_owner: identity.ContentOwner,
    generation: u64 = 1,
    host_id: HostId,
    /// Compatibility position for asset editing only; never a transport target.
    host_index: usize,
    host_snapshot: ?HostSnapshot,
    title: [64]u8 = undefined,
    title_len: usize = 0,
    root: *ui.Node,
    terminal: ?TerminalViewNode = null,
    file_ready: bool = false,
    content_ready: bool = false,
    runtime: ?*SessionRuntime = null,
    failed: bool = false,
    archived: bool = false,
    archive_document: ?*@import("history_archive.zig").Document = null,
    /// A task creation is not selectable or a group member until ready commit.
    owned_pending: bool = false,
    owned_origin: bool = false,
    closing: bool = false,
    local: bool = false,
    detected_os: session_icon.Os = .unknown,
    local_scope: ?*ui.Scope = null,
    remote_notice_scope: ?*ui.Scope = null,
    remote_notice: ?*RemoteNotice.View = null,
    remote_retrying: bool = false,
    remote_retry_deadline: ?i128 = null,
    file_scope: ?*ui.Scope = null,
    transfer_trays: [2]?*@import("transfer_manager_view.zig").Panel = .{ null, null },
    plugin_renderer: ?plugin_ui.RendererInstance = null,
    plugin_protocol_id: []const u8 = "",
    local_bound: bool = false,
    local_state: LocalState = .starting,
    local_banner: ?*ui.Node = null,
    local_spinner: ?*ui.Node = null,
    local_ended_icon: ?*ui.Node = null,
    local_failure_icon: ?*ui.Node = null,
    local_message: ?*ui.Node = null,
    local_detail: ?*ui.Node = null,
    local_cancel: ?*ui.Node = null,
    local_close: ?*ui.Node = null,
    local_retry: ?*ui.Node = null,
    local_new: ?*ui.Node = null,

    pub fn ticket(self: *const SessionTab) lifecycle.Ticket {
        return .{ .session_id = self.id, .generation = self.generation };
    }

    pub fn titleSlice(self: *const SessionTab) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn setTitle(self: *SessionTab, name: []const u8) void {
        var n = @min(name.len, self.title.len);
        while (n > 0 and !std.unicode.utf8ValidateSlice(name[0..n])) n -= 1;
        @memcpy(self.title[0..n], name[0..n]);
        self.title_len = n;
    }
};

/// Normalize and validate a user supplied session-tab title.
///
/// Tab names are presentation state owned by the session, so they must not
/// mutate the host asset.  Trimming surrounding whitespace keeps inline
/// editing from producing titles that only look empty, while control bytes
/// (including newlines) are rejected because they make the tab strip
/// ambiguous.  The storage bound is explicit rather than silently truncating
/// a name typed by the user.
fn normalizeTabName(name: []const u8) ![]const u8 {
    return tab_rename.normalize(name);
}

const HostRow = struct {
    node: *ui.Node,
    name_node: *ui.Node,
    host_index: usize,
    click_ctx: *ClickCtx,
    view: *sidebar_view.HostRow,
};

const TabNode = struct {
    node: *ui.Node,
    holder: *ui.Node,
    icon: *ui.Node,
    type_icon: *ui.Node,
    label: *ui.Node,
    close: *ui.Node,
    tab_id: identity.TabId,
    tab_index: usize,
    select_ctx: *ClickCtx,
    close_ctx: *ClickCtx,
};

/// Danger accent of the close-confirmation card
/// (docs/SPEC/mockups/mockup-close-confirm.png).
const danger_red = ui.Color.rgba(0xDC, 0x26, 0x26, 255);

/// One risk row on the close-confirmation card: category label plus the
/// detail text node. The mockup-close-confirm rule list ships all rows
/// (SSH/传输/AI/SOCKS5/历史); rows for subsystems without live state are
/// hidden at show time via setRiskVisible (setRiskDetail rewrites details).
const CloseRiskRow = struct {
    category: []const u8,
    detail_node: *ui.Node,
    row_node: *ui.Node,
};

/// Heap cell carrying (workspace, payload) through the void* handler seam.
///
/// Lifetime: host cells live until workspace cleanup. Tab cells are reclaimed
/// only by the deferred tab-bar rebuild, after event dispatch has returned.
/// Stable session IDs prevent pending clicks from targeting shifted indices.
const ClickCtx = struct {
    workspace: *Workspace,
    index: usize,
    tab_generation: u64 = 0,
    node: ?*ui.Node = null,
    host_id: ?lifecycle.HostId = null,
    asset_owner: ?identity.AssetOwner = null,
    session_id: ?SessionId = null,
    tab_id: ?identity.TabId = null,
    hovered: bool = false,
    drag_binding: ?*ui.interaction.drag.Binding = null,
    test_id: [48]u8 = undefined,
};

/// Menu trigger seam: main.zig owns the menu panel + renderer (MenuHost);
/// Workspace owns host/tab context data. The bridge carries the trigger plus
/// the exact context the menu needs to build/enable rows, without exposing
/// Workspace internals across the module boundary.
pub const MenuBridge = struct {
    host_action: ?*const fn (?*anyopaque, usize, sidebar_view.HostAction) void = null,
    context: ?*anyopaque = null,
    fire: ?*const fn (ctx: ?*anyopaque, trigger: Trigger, host_index: usize, tab_index: ?usize, multi_tabs: bool, anchor: ui.ComputedRect) void = null,

    pub const Trigger = @import("context_menu_state.zig").Trigger;

    pub fn fireHost(self: *MenuBridge, trigger: Trigger, host_index: usize, anchor: ui.ComputedRect) void {
        const f = self.fire orelse return;
        f(self.context, trigger, host_index, null, false, anchor);
    }

    pub fn fireTab(self: *MenuBridge, trigger: Trigger, tab_index: usize, multi_tabs: bool, anchor: ui.ComputedRect) void {
        const f = self.fire orelse return;
        f(self.context, trigger, 0, tab_index, multi_tabs, anchor);
    }
};

pub const CloseRisk = struct {
    transfer: bool = false,
    ai_write: bool = false,
    socks: bool = false,
    local_process: bool = false,
    local_unknown: bool = false,
    pub fn any(self: CloseRisk) bool {
        return self.transfer or self.ai_write or self.socks or self.local_process or self.local_unknown;
    }
};

pub const CloseBridge = struct {
    context: ?*anyopaque = null,
    risk: ?*const fn (?*anyopaque, SessionId) CloseRisk = null,
    impact: ?*const fn (?*anyopaque, SessionId) group_close.Impact = null,
    close_state: ?*const fn (?*anyopaque, SessionId) ?group_close.MemberState = null,
    cleanup: ?*const fn (?*anyopaque, SessionId) void = null,
    request_close: ?*const fn (?*anyopaque, identity.TabId, identity.ContentOwner) CloseResult = null,
    confirm: ?*const fn (?*anyopaque, SessionId) void = null,
};
pub const CloseResult = enum { released, awaiting, unknown, rejected };
pub const NotificationAttentionBridge = struct {
    context: ?*anyopaque = null,
    has_dot: ?*const fn (?*anyopaque, identity.ContentOwner) bool = null,
};

pub const BackgroundForwardBridge = struct {
    context: ?*anyopaque = null,
    badge: ?*const fn (?*anyopaque, identity.AssetOwner) ?sidebar_view.ForwardBadge = null,
};
pub const WindowCloseBridge = struct {
    context: ?*anyopaque = null,
    cancelled: ?*const fn (?*anyopaque, u64) void = null,
};
/// Additional native file connections reuse the same authentication UI while
/// keeping their own original operation and worker-owned challenge bridges.
pub const ExternalAuthentication = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) ?auth_challenge.Snapshot,
    submit: *const fn (*anyopaque, auth_challenge.RequestIdentity, auth_challenge.Reply) anyerror!void,
    cancel: *const fn (*anyopaque, auth_challenge.RequestIdentity) bool,
    host: *const fn (*anyopaque, auth_challenge.RequestIdentity) ?hosts_mod.HostConfig,
    parent: *const fn (*anyopaque, auth_challenge.RequestIdentity) ?*ui.Node,
    host_key: *const fn (*anyopaque, auth_challenge.RequestIdentity) ?host_key_confirmation.Request,
    totp: ?*const fn (*anyopaque, auth_challenge.RequestIdentity, @import("../proto/ssh/totp_prefill.zig").Time) anyerror!?@import("../proto/ssh/totp_prefill.zig").Suggestion = null,
};

pub const SessionBridge = struct {
    context: ?*anyopaque = null,
    create: ?*const fn (?*anyopaque, hosts_mod.HostConfig, HostId, usize, []const u8) anyerror!void = null,
    recreate: ?*const fn (?*anyopaque, SessionId) anyerror!void = null,
    reuse: ?*const fn (?*anyopaque, SessionId) anyerror!void = null,
    connected: ?*const fn (?*anyopaque, SessionId, u64) void = null,
    failed: ?*const fn (?*anyopaque, SessionId, u64, []const u8) void = null,
    cleanup: ?*const fn (?*anyopaque, SessionId, u64) void = null,
    cleanup_status: ?*const fn (?*anyopaque, SessionId, u64, RuntimeReleaseReceipt) void = null,
    create_local: ?*const fn (?*anyopaque, ?[]const u8) anyerror!void = null,
    duplicate_local: ?*const fn (?*anyopaque, SessionId) anyerror!void = null,
    retry_local: ?*const fn (?*anyopaque, SessionId) anyerror!void = null,
    retry_ssh: ?*const fn (?*anyopaque, SessionId) anyerror!void = null,
};
pub const LocalState = enum { starting, running, exited, failed, closing, cleanup_unknown };
pub const TerminalTypographyConfig = @FieldType(config_mod.Config, "ui");

fn fontWeight(name: []const u8) u16 {
    if (std.mem.eql(u8, name, "bold")) return 700;
    if (std.mem.eql(u8, name, "medium")) return 500;
    if (std.mem.eql(u8, name, "light")) return 300;
    return 400;
}
fn cursorStyle(name: []const u8) TerminalViewNode.CursorStyle {
    if (std.mem.eql(u8, name, "bar")) return .bar;
    if (std.mem.eql(u8, name, "underline")) return .underline;
    return .block;
}

pub const GroupAction = enum { pin, leave, close_member, toggle_broadcast, broadcast, split_side, split_stack, stop_broadcast, stop_group_ai };

pub const Workspace = struct {
    recent_connections: @import("quick_connect.zig").RecentList = .{},
    plugins: plugin_registry.Registry = .{},
    content_services: ?plugin_ui.ContentServicesFactory = null,

    font_family_resolver: ?*const fn ([]const u8) u16 = null,
    terminal_typography_resolver: ?*const fn (*TerminalViewNode, TerminalTypographyConfig) anyerror!void = null,
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    scope: *ui.Scope,
    io: std.Io,
    app_config: *const config_mod.Config,
    palette: Palette,

    registry: hosts_mod.Registry,
    identities: lifecycle.Identities = .{},
    hosts_path: []const u8,

    sidebar_list: *ui.Node,
    sidebar_bridge: sidebar_view.Bridge = .{},
    background_forward_bridge: BackgroundForwardBridge = .{},
    sidebar_scope: ?*ui.Scope = null,
    sidebar_chrome: ?*sidebar_view.View = null,
    default_group_row: ?*sidebar_view.GroupRow = null,
    default_group_collapsed: bool = false,
    default_group_forced_open: bool = false,
    host_rows: std.ArrayList(HostRow) = .empty,
    group_headers: std.ArrayList(*ui.Node) = .empty,
    group_rows: std.ArrayList(*sidebar_view.GroupRow) = .empty,
    search_query: [128]u8 = undefined,
    search_len: usize = 0,
    selected_host: ?usize = null,

    tab_bar: *ui.Node,
    model: workspace_model.Model,
    picker: workspace_model.Picker = .{},
    strip_root: ?*ui.Node = null,
    strip_content: ?*ui.Node = null,
    strip_viewport: ?*ui.Node = null,
    strip_widths: std.ArrayList(f32) = .empty,
    strip_advances: std.ArrayList(f32) = .empty,
    strip_offset: f32 = 0,
    strip_geometry: tab_layout.Result = .{ .mode = .normal, .viewport = 0, .content = 0, .offset = 0, .can_scroll_left = false, .can_scroll_right = false },
    header_width: f32 = 0,
    reveal_active: bool = false,
    command_held: bool = false,
    drag_tab: ?identity.TabId = null,
    drag_gap: ?*ui.Node = null,
    drag_binding: ?*ui.interaction.drag.Binding = null,
    drag_pointer_x: f32 = 0,
    picker_view: ?*tab_picker.View = null,
    color_picker: ?*tab_color_picker.View = null,
    picker_anchor: ?*ui.Node = null,
    picker_focus_return: ?identity.TabId = null,
    rename_scope: ?*ui.Scope = null,
    rename_request: ?workspace_model.Rename = null,
    rename_pending: bool = false,
    close_targets: std.ArrayList(workspace_model.CloseTarget) = .empty,
    close_cursor: usize = 0,
    window_close_request: ?u64 = null,
    window_close_reconcile: bool = false,
    window_close_bridge: WindowCloseBridge = .{},
    close_receipts: std.ArrayList(workspace_model.CloseTarget) = .empty,
    tabs: std.ArrayList(*SessionTab) = .empty,
    tab_nodes: std.ArrayList(TabNode) = .empty,
    /// Incremented by every tab-bar rebuild. Cells stamped with an older
    /// generation belong to removed nodes and are ignored by the trampolines.
    tab_generation: u64 = 0,
    tab_scope: ?*ui.Scope = null,
    rename_session: ?SessionId = null,
    rename_draft: std.ArrayList(u8) = .empty,
    rename_editor: ?*tab_rename.Editor = null,
    tab_rebuild_pending: bool = false,
    active_tab: ?usize = null,
    /// Set only by a rendered group workspace. Membership alone never makes
    /// an independently opened session tab a group-owned AI conversation.
    active_group_view: ?u32 = null,

    group_roster: ?*group_model.Roster = null,
    group_views: std.ArrayList(*group_view.View) = .empty,
    group_action_context: ?*anyopaque = null,
    group_action: ?*const fn (?*anyopaque, u32, u64, GroupAction) void = null,
    group_present_pending: bool = false,
    pending_split: ?struct { group: u32, session: SessionId, revision: u64 } = null,

    terminal_area: *ui.Node,
    history_card_host: ?*ui.Node = null,
    empty_state: *ui.Node,
    status_node: ?*ui.Node = null,
    status_feedback: ?struct { context: *anyopaque, publish: *const fn (*anyopaque, ?identity.ContentOwner, []const u8, StatusKind) void } = null,
    command_output: ?*TerminalViewNode = null,
    creation_group: ?u32 = null,
    owned_creation_pending: bool = false,
    prepared_group_views: usize = 0,
    creation_tab_color: ?u32 = null,
    /// Status-bar grid-size label; bound to the active tab's terminal so the
    /// live PTY dimensions (frame_cols/frame_rows) replace the static text.
    grid_node: ?*ui.Node = null,
    /// Context-menu trigger seam (sidebar host rows, tab strip); owned by
    /// main.zig's MenuHost. Null keeps the legacy direct-connect behavior.
    menu_bridge: MenuBridge = .{},
    command_bridge: TerminalViewNode.PaletteObserver = .{ .on_command = ignoreCommand },
    input_bridge: ?TerminalViewNode.InputObserver = null,
    terminal_takeover_handler: ?@import("terminal_view.zig").TakeoverHandler = null,
    error_hint_handler: ?@import("../ai/command_error_hint.zig").Handler = null,
    close_bridge: CloseBridge = .{},
    notification_attention_bridge: NotificationAttentionBridge = .{},
    session_bridge: SessionBridge = .{},
    pending_shared_connection: ?@import("../host/runtime_service.zig").SharedLease = null,
    external_auth: ?ExternalAuthentication = null,
    close_others_keep: ?SessionId = null,
    // ── Close-confirmation card (see requestCloseTab) ─────────────────
    /// Tab index whose close is awaiting user confirmation; null while no
    /// card is up.
    confirming_tab: ?usize = null,
    confirming_id: ?identity.TabId = null,
    /// Full-cover scrim over terminal_area: absolute, centered content,
    /// high z-index, translucent background.
    confirm_root: ?*ui.Node = null,
    /// The white card node; keyboard focus target while the card is up.
    confirm_card: ?*ui.Node = null,
    /// Title text node, rewritten with the pending tab's name on show.
    confirm_title: ?*ui.Node = null,
    /// Risk rows (category + live detail text node), mounted once. Array so
    /// the upcoming 传输/AI/SOCKS5 rows can be appended without reworking
    /// the card layout.
    confirm_risk_rows: std.ArrayList(CloseRiskRow) = .empty,
    click_ctxs: std.ArrayList(*ClickCtx) = .empty,
    connect_jobs: std.ArrayList(*ConnectJob) = .empty,
    poll_hook: ?*PollHook = null,
    shutting_down: bool = false,
    host_key_job: ?*ConnectJob = null,
    host_key_generation: u64 = 0,
    host_key_root: ?*ui.Node = null,
    host_key_card: ?*ui.Node = null,
    host_key_detail: ?*ui.Node = null,
    host_key_changed_button: ?*ui.Node = null,
    auth_job: ?*ConnectJob = null,
    authentication_ui_ready: bool = false,
    auth_generation: u64 = 0,
    auth_root: ?*ui.Node = null,
    auth_card: ?*ui.Node = null,
    auth_detail: ?*ui.Node = null,
    auth_input: ?*ui.Signal([]const u8) = null,

    pub fn init(
        allocator: std.mem.Allocator,
        cx: *ui.Cx,
        scope: *ui.Scope,
        io: std.Io,
        app_config: *const config_mod.Config,
        hosts_path: []const u8,
        sidebar_list: *ui.Node,
        tab_bar: *ui.Node,
        terminal_area: *ui.Node,
        empty_state: *ui.Node,
    ) !*Workspace {
        applog.info(.workspace, "init: loading hosts from {s}", .{hosts_path});
        const registry = store.loadHosts(io, std.Io.Dir.cwd(), allocator, hosts_path) catch |err| blk: {
            applog.err(.workspace, "loadHosts({s}) failed: {s}", .{ hosts_path, @errorName(err) });
            break :blk hosts_mod.Registry{ .arena = std.heap.ArenaAllocator.init(allocator), .hosts = &.{} };
        };
        applog.info(.workspace, "hosts loaded: {d} entries", .{registry.hosts.len});
        const self = try allocator.create(Workspace);
        self.* = .{
            .allocator = allocator,
            .cx = cx,
            .scope = scope,
            .io = io,
            .app_config = app_config,
            .palette = Palette.fromTheme(),
            .registry = registry,
            .hosts_path = hosts_path,
            .sidebar_list = sidebar_list,
            .tab_bar = tab_bar,
            .model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) },
            .terminal_area = terminal_area,
            .empty_state = empty_state,
        };
        current_workspace = self;
        try scope.onCleanup(Workspace, self, cleanup);
        try self.rebuildSidebar();
        try self.rebuildTabBar();
        try self.mountCloseConfirm();
        return self;
    }

    pub fn configureIdentity(self: *Workspace, window: identity.WindowId, workspace: identity.WorkspaceId) void {
        self.model.window = window;
        self.model.workspace = workspace;
    }

    fn cleanup(self: *Workspace) void {
        self.shutting_down = true;
        self.sidebar_scope = null; // child scopes already disposed by parent
        self.sidebar_chrome = null;
        self.default_group_row = null;
        self.tab_scope = null; // child scopes already disposed by parent before this cleanup
        self.rename_editor = null;
        if (self.poll_hook) |hook| {
            self.cx.removeAfterLayoutHook(hook);
            self.allocator.destroy(hook);
            self.poll_hook = null;
        }
        // Connect jobs own snapshots and no UI pointers. Cancel and join all
        // remaining attempts before any workspace storage is released.
        for (self.connect_jobs.items) |job| {
            job.cancelled.store(true, .release);
            job.host_key_bridge.cancel();
            job.auth_bridge.cancel();
        }
        for (self.connect_jobs.items) |job| {
            if (job.thread) |thread| thread.join();
            ConnectJob.destroy(job);
        }
        self.connect_jobs.deinit(self.allocator);
        self.rename_draft.deinit(self.allocator);
        for (self.group_views.items) |view| {
            view.deinit(self.allocator);
            self.allocator.destroy(view);
        }
        self.group_views.deinit(self.allocator);
        self.model.deinit();
        self.picker.deinit(self.allocator);
        self.strip_widths.deinit(self.allocator);
        self.strip_advances.deinit(self.allocator);
        self.close_targets.deinit(self.allocator);
        self.close_receipts.deinit(self.allocator);
        for (self.tabs.items) |tab| {
            // FrameHook and SessionRuntime scope entries run BEFORE this
            // (reverse-registration order): hooks are gone and runtimes are
            // torn down+destroyed by their sole owners. Here we only release
            // tab-owned state — touching tab.runtime now would dereference
            // freed memory (the 0x10 quit crash).
            if (tab.terminal) |*terminal| {
                terminal.removeFrameHook(self.cx);
                terminal.clearPendingPaste();
                terminal.releaseBuffers(self.cx);
            }
            if (tab.plugin_protocol_id.len != 0) self.allocator.free(tab.plugin_protocol_id);
            // Child scopes dispose before this workspace cleanup. Native
            // renderers must register resource cleanup in their own scope.
            if (tab.host_snapshot) |*snapshot| snapshot.deinit();
            if (tab.archive_document) |document| document.destroy();
            self.allocator.destroy(tab);
        }
        for (self.click_ctxs.items) |cell| self.allocator.destroy(cell);
        self.tabs.deinit(self.allocator);
        self.tab_nodes.deinit(self.allocator);
        self.host_rows.deinit(self.allocator);
        self.group_headers.deinit(self.allocator);
        self.group_rows.deinit(self.allocator);
        self.click_ctxs.deinit(self.allocator);
        self.confirm_risk_rows.deinit(self.allocator);
        self.identities.deinit(self.allocator);
        self.registry.deinit();
        if (current_workspace == self) current_workspace = null;
        self.allocator.destroy(self);
    }

    fn newClickCtx(self: *Workspace, index: usize) !*ClickCtx {
        const cell = try self.allocator.create(ClickCtx);
        cell.* = .{ .workspace = self, .index = index, .host_id = self.identities.hostAt(index), .asset_owner = if (@backingInt(self.registry.hosts[index].connection_id) == 0) null else self.registry.hosts[index].owner() };
        try self.click_ctxs.append(self.allocator, cell);
        return cell;
    }

    /// Tab-bar variant: stamps the current bar generation so the trampolines
    /// can reject events routed through nodes of an already-rebuilt bar.
    fn newTabClickCtx(self: *Workspace, index: usize) !*ClickCtx {
        const cell = try self.allocator.create(ClickCtx);
        cell.* = .{ .workspace = self, .index = index, .tab_generation = self.tab_generation, .session_id = if (self.tabIndexById(self.model.tabs.items[index].id)) |at| self.tabs.items[at].id else null, .tab_id = self.model.tabs.items[index].id };
        try self.click_ctxs.append(self.allocator, cell);
        return cell;
    }

    fn onClickTrampoline(raw: *anyopaque) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(raw));
        const id = cell.host_id orelse return;
        const index = cell.workspace.identities.hostIndex(id) orelse return;
        cell.workspace.selected_host = index;
        cell.workspace.refreshSelection();
    }

    /// Full mouse handler on host rows: single click selects, double click
    /// connects, right click selects + connects (temp menu shortcut until the
    /// context menu component lands).
    fn onHostEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const cell: *ClickCtx = @ptrCast(@alignCast(context orelse return .ignored));
        const self = cell.workspace;
        const id = cell.host_id orelse return .ignored;
        const index = self.identities.hostIndex(id) orelse return .ignored;
        switch (event) {
            // zenit 事件契约：右键不合成 click（event_dispatcher 只为左键合成），
            // 右键菜单必须在 mouse_down 捕获。
            .mouse_down => |mouse| {
                if (mouse.button == .right) {
                    self.logHostSelection(index, "right-click menu");
                    self.selected_host = index;
                    self.refreshSelection();
                    const node = cell.node orelse return .ignored;
                    self.menu_bridge.fireHost(.host_right_click, index, node.globalRect());
                    return .handled;
                }
                return .ignored;
            },
            .click => |click| {
                if (click.button != .left) return .handled;
                self.logHostSelection(index, "click select");
                self.selected_host = index;
                self.refreshSelection();
                return .handled;
            },
            .double_click => |click| {
                if (click.button != .left) return .ignored;
                self.logHostSelection(index, "double-click connect");
                self.selected_host = index;
                self.refreshSelection();
                self.openSession(index) catch |err| self.statusFailure(@errorName(err));
                return .handled;
            },
            else => return .ignored,
        }
    }

    /// True when the cell belongs to a tab bar that has since been rebuilt.
    /// Such cells stay allocated (dispatcher may still reference them) but
    /// must never act.
    fn isStaleTabCell(self: *const Workspace, cell: *const ClickCtx) bool {
        return cell.tab_generation != self.tab_generation;
    }

    fn onSelectTabTrampoline(raw: *anyopaque) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(raw));
        const self = cell.workspace;
        // Resolve stable identity because a close may shift indices before
        // the deferred tab-bar rebuild has run.
        if (self.isStaleTabCell(cell)) return;
        const id = cell.tab_id orelse return;
        if (cell.session_id != null and self.rename_session == cell.session_id) return;
        self.activateTabId(id);
    }

    fn onCloseTabTrampoline(raw: *anyopaque) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(raw));
        const self = cell.workspace;
        if (self.isStaleTabCell(cell)) return;
        const id = cell.tab_id orelse return;
        if (self.groupIdByTab(id)) |group| self.requestCloseGroup(group) else if (self.tabIndexById(id)) |index| self.requestCloseTab(index);
    }

    /// Tab strip context menu / middle-click close (capture phase; the
    /// select/close click trampolines keep the bubble phase).
    fn onTabBoxEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const cell: *ClickCtx = @ptrCast(@alignCast(context orelse return .ignored));
        const self = cell.workspace;
        if (self.isStaleTabCell(cell)) return .ignored;
        const tab_id = cell.tab_id orelse return .ignored;
        if (self.groupIdByTab(tab_id)) |group| {
            if (event == .mouse_down and event.mouse_down.button == .middle) {
                self.requestCloseGroup(group);
                return .stop;
            }
            if (event == .double_click and !self.groupClosing(group)) {
                self.beginRenamePresentation(tab_id) catch {};
                return .stop;
            }
            return .ignored;
        }
        const index = self.tabIndexById(tab_id) orelse return .ignored;
        const id = self.tabs.items[index].id;
        switch (event) {
            // 右键/中键不合成 click（zenit 契约同上），在 mouse_down 捕获。
            .mouse_down => |mouse| {
                if (mouse.button == .right) {
                    const node = cell.node orelse return .ignored;
                    self.menu_bridge.fireTab(.tab_right_click, index, self.model.tabs.items.len > 1, node.globalRect());
                    return .handled;
                }
                if (mouse.button == .middle) {
                    self.requestCloseTab(index);
                    return .handled;
                }
                return .ignored;
            },
            .double_click => {
                if (self.tabs.items[index].closing or self.rename_session == id) return .ignored;
                self.beginRenameTab(id) catch {};
                return .stop;
            },
            else => {},
        }
        return .ignored;
    }

    fn logHostSelection(self: *Workspace, index: usize, action: []const u8) void {
        if (index < self.registry.hosts.len) {
            applog.debug(.ui, "host row {s}: {s}", .{ action, self.registry.hosts[index].name });
        }
    }

    pub fn hostId(self: *const Workspace, index: usize) ?HostId {
        return self.identities.hostAt(index);
    }

    pub fn hostIndex(self: *const Workspace, id: HostId) ?usize {
        return self.identities.hostIndex(id);
    }

    /// The running session owns this snapshot even when its asset is deleted.
    pub fn tabHost(self: *const Workspace, index: usize) ?hosts_mod.HostConfig {
        if (index >= self.tabs.items.len) return null;
        return if (self.tabs.items[index].host_snapshot) |snapshot| snapshot.value else null;
    }

    pub fn activeHost(self: *const Workspace) ?hosts_mod.HostConfig {
        return self.tabHost(self.active_tab orelse return null);
    }

    pub fn tabIndex(self: *const Workspace, id: SessionId) ?usize {
        for (self.tabs.items, 0..) |tab, index| if (tab.id == id) return index;
        return null;
    }

    pub fn tabIndexById(self: *const Workspace, id: identity.TabId) ?usize {
        for (self.tabs.items, 0..) |tab, index| if (tab.tab_id == id) return index;
        return null;
    }

    pub fn visibleLocalTerminalTabRect(self: *const Workspace) ?ui.ComputedRect {
        if (self.tab_rebuild_pending or self.model.dragging) return null;
        const viewport = (self.strip_viewport orelse return null).globalRect();
        if (viewport.w <= 0) return null;
        for (self.tab_nodes.items) |cell| {
            const index = self.tabIndexById(cell.tab_id) orelse continue;
            if (!self.tabs.items[index].local) continue;
            const rect = cell.node.globalRect();
            if (rect.w > 0 and rect.x >= viewport.x - 0.5 and rect.x + rect.w <= viewport.x + viewport.w + 0.5) return rect;
        }
        return null;
    }

    pub fn sessionTab(self: *const Workspace, id: SessionId) ?*SessionTab {
        return if (self.tabIndex(id)) |index| self.tabs.items[index] else null;
    }

    pub fn bindSessionOwner(self: *Workspace, id: SessionId, handle: identity.SessionHandle) !void {
        const tab = self.sessionTab(id) orelse return error.InvalidTab;
        if (!tab.owned_pending) try self.model.replaceOwner(tab.tab_id, tab.content_owner, .{ .session = handle });
        tab.content_owner = .{ .session = handle };
    }

    /// Validate identities and reserve every fallible structure before making
    /// the pending terminal a member. This is the sole owned member commit.
    pub fn commitOwnedSession(self: *Workspace, group_owner: identity.GroupOwner, handle: identity.SessionHandle, id: SessionId) !u64 {
        const tab = self.sessionTab(id) orelse return error.StaleSession;
        if (!tab.content_owner.eql(.{ .session = handle }) or tab.closing or tab.archived or tab.terminal == null) return error.StaleSession;
        const group_id = std.math.cast(u32, @backingInt(group_owner.id)) orelse return error.UnknownGroup;
        const roster = self.group_roster orelse return error.UnknownGroup;
        const group = roster.findById(group_id) orelse return error.UnknownGroup;
        if (self.groupClosing(group_id)) return error.GroupClosing;
        const parent = self.groupTabId(group_id) orelse return error.GroupNotOpen;
        const parent_index = self.model.indexOf(parent) orelse return error.GroupNotOpen;
        if (!self.model.tabs.items[parent_index].owner.eql(.{ .group = group_owner })) return error.StaleReference;
        if (!tab.owned_pending) {
            if (group.contains(id) and self.model.tabs.items[self.model.indexOf(tab.tab_id) orelse return error.TabClosed].container == parent) return group.membership_revision;
            return error.MembershipCommitFailed;
        }
        if (group.contains(id)) return error.MembershipCommitFailed;
        const revision = try identity.advance(group.membership_revision);
        try group.members.ensureUnusedCapacity(roster.allocator, 1);
        const ambient = self.creation_group;
        self.creation_group = null;
        defer self.creation_group = ambient;
        tab.owned_pending = false;
        errdefer tab.owned_pending = true;
        try self.installTabModel(tab);
        // No fallible work remains after publication of membership.
        const model_tab = &self.model.tabs.items[self.model.indexOf(tab.tab_id).?];
        model_tab.container = parent;
        self.model.active = parent;
        group.members.appendAssumeCapacity(.{ .pane_id = id, .membership_revision = revision });
        group.membership_revision = revision;
        self.active_group_view = group_id;
        self.group_present_pending = true;
        if (self.groupView(group_id)) |view| view.dirty = true;
        self.tab_rebuild_pending = true;
        self.cx.requestRedraw();
        return revision;
    }

    fn findTicket(self: *const Workspace, ticket: lifecycle.Ticket) ?*SessionTab {
        const index = self.tabIndex(ticket.session_id) orelse return null;
        const tab = self.tabs.items[index];
        return if (tab.ticket().matches(ticket)) tab else null;
    }

    /// Adds a config with workspace-owned storage. Persistence is explicit so
    /// quick-connect can also create temporary process-local assets.
    pub fn appendHost(self: *Workspace, host: hosts_mod.HostConfig) !usize {
        try host.validate();
        try self.identities.appendHosts(self.allocator, self.registry.hosts.len);
        const arena = self.registry.arena.allocator();
        const value = try lifecycle.cloneValue(hosts_mod.HostConfig, arena, host);
        const next = try arena.alloc(hosts_mod.HostConfig, self.registry.hosts.len + 1);
        @memcpy(next[0..self.registry.hosts.len], self.registry.hosts);
        next[next.len - 1] = value;
        try self.identities.appendHosts(self.allocator, next.len);
        self.registry.hosts = next;
        return next.len - 1;
    }

    /// Removes the asset only. Session snapshots and stable IDs are retained.
    pub fn applyAssetAction(self: *Workspace, request: @import("../config/asset_actions.zig").Request) !@import("../config/asset_actions.zig").Result {
        try self.identities.appendHosts(self.allocator, self.registry.hosts.len);
        const selected = if (self.selected_host) |position| self.hostId(position) else null;
        // Reserve the only potentially growing process-local projection before
        // committing. A disk failure must not publish a new sidebar identity.
        if (request == .clone) try self.identities.hosts.ensureTotalCapacity(self.allocator, self.registry.hosts.len + 1);
        const result = try @import("../config/asset_actions.zig").apply(self.allocator, self.io, std.Io.Dir.cwd(), self.hosts_path, &self.registry, request);
        switch (result.kind) {
            .clone => self.identities.appendHosts(self.allocator, self.registry.hosts.len) catch unreachable,
            .delete => _ = self.identities.removeHost(result.previous_index) catch unreachable,
            .pin, .move => {},
        }
        self.refreshAssetPositions(selected);
        self.rebuildSidebar() catch |err| {
            // Persistence succeeded. Do not turn a paint/allocation failure
            // into an action failure that would invite duplicating the write.
            applog.warn(.ui, "asset saved; sidebar refresh failed: {s}", .{@errorName(err)});
            self.statusFailure("配置已保存，列表刷新失败");
        };
        return result;
    }

    pub fn removeHost(self: *Workspace, index: usize) !void {
        if (index >= self.registry.hosts.len) return error.InvalidHost;
        try self.identities.appendHosts(self.allocator, self.registry.hosts.len);
        const selected = if (self.selected_host) |position| self.hostId(position) else null;
        const next = try self.registry.arena.allocator().alloc(hosts_mod.HostConfig, self.registry.hosts.len - 1);
        @memcpy(next[0..index], self.registry.hosts[0..index]);
        @memcpy(next[index..], self.registry.hosts[index + 1 ..]);
        try self.saveHostSlice(next);
        _ = try self.identities.removeHost(index);
        self.registry.hosts = next;
        self.refreshAssetPositions(selected);
        try self.rebuildSidebar();
    }

    /// The asset moves to the first position of its own group, as shown by
    /// the sidebar menu. Running sessions continue to target their snapshots.
    pub fn pinHost(self: *Workspace, index: usize) !void {
        if (index >= self.registry.hosts.len) return error.InvalidHost;
        try self.identities.appendHosts(self.allocator, self.registry.hosts.len);
        const group = self.registry.hosts[index].group orelse "";
        var target: usize = 0;
        while (target < index and !std.mem.eql(u8, self.registry.hosts[target].group orelse "", group)) target += 1;
        if (target == index) return;
        const selected = if (self.selected_host) |position| self.hostId(position) else null;
        const next = try self.registry.arena.allocator().dupe(hosts_mod.HostConfig, self.registry.hosts);
        const picked = next[index];
        std.mem.copyBackwards(hosts_mod.HostConfig, next[target + 1 .. index + 1], next[target..index]);
        next[target] = picked;
        try self.saveHostSlice(next);
        try self.identities.moveHost(index, target);
        self.registry.hosts = next;
        self.refreshAssetPositions(selected);
        try self.rebuildSidebar();
    }

    pub fn replaceHost(self: *Workspace, index: usize, host: hosts_mod.HostConfig) !void {
        if (index >= self.registry.hosts.len) return error.InvalidHost;
        try host.validate();
        try self.identities.appendHosts(self.allocator, self.registry.hosts.len);
        const arena = self.registry.arena.allocator();
        const next = try arena.dupe(hosts_mod.HostConfig, self.registry.hosts);
        next[index] = try lifecycle.cloneValue(hosts_mod.HostConfig, arena, host);
        try self.saveHostSlice(next);
        self.registry.hosts = next;
        try self.rebuildSidebar();
    }

    fn saveHostSlice(self: *Workspace, hosts: []hosts_mod.HostConfig) !void {
        var candidate = self.registry;
        candidate.hosts = hosts;
        try store.saveHosts(self.io, std.Io.Dir.cwd(), self.hosts_path, candidate);
    }

    fn refreshAssetPositions(self: *Workspace, selected: ?HostId) void {
        self.selected_host = if (selected) |id| self.hostIndex(id) else null;
        for (self.tabs.items) |tab| tab.host_index = self.hostIndex(tab.host_id) orelse removed_host_index;
    }

    /// 把当前注册表原子写回 hosts.toml（菜单 clone/pin/delete 持久化共用）。
    pub fn saveRegistry(self: *Workspace) !void {
        try store.saveHosts(self.io, std.Io.Dir.cwd(), self.hosts_path, self.registry);
    }

    pub const StatusKind = enum { info, failure };

    pub fn status(self: *Workspace, text: []const u8) void {
        self.statusWithKind(text, .info);
    }
    pub fn statusFailure(self: *Workspace, text: []const u8) void {
        self.statusWithKind(text, .failure);
    }
    pub fn reportFailure(self: *Workspace, owner: identity.ContentOwner, text: []const u8) void {
        if (self.status_feedback) |feedback| feedback.publish(feedback.context, owner, text, .failure);
    }
    fn statusWithKind(self: *Workspace, text: []const u8, kind: StatusKind) void {
        if (self.command_output) |terminal| {
            terminal.showCommandMessage(text);
            return;
        }
        if (self.status_feedback) |feedback| feedback.publish(feedback.context, if (self.active_tab) |index| (if (index < self.tabs.items.len) self.tabs.items[index].content_owner else null) else null, text, kind);
        const target = self.status_node orelse return;
        target.setTextContent(self.allocator, text) catch return;
        target.markRenderDirty();
        self.cx.requestRedraw();
    }

    // ── Sidebar: data-driven host list from hosts.toml ───────────────

    pub fn setSidebarMenuOwner(self: *Workspace, owner: ?identity.AssetOwner) void {
        for (self.host_rows.items) |row| {
            const captured = row.click_ctx.asset_owner;
            row.view.setMenuOpen(owner != null and captured != null and std.meta.eql(owner.?, captured.?));
        }
    }

    pub fn setSidebarBridge(self: *Workspace, bridge: sidebar_view.Bridge) !void {
        self.sidebar_bridge = bridge;
        if (self.sidebar_chrome) |chrome| chrome.setBridge(bridge);
        try self.rebuildSidebar();
    }

    pub fn setBackgroundForwardBridge(self: *Workspace, bridge: BackgroundForwardBridge) void {
        self.background_forward_bridge = bridge;
        self.refreshBackgroundForwardBadges();
    }
    pub fn refreshBackgroundForwardBadges(self: *Workspace) void {
        for (self.host_rows.items) |row| {
            const owner = row.click_ctx.asset_owner orelse continue;
            row.view.setForwardBadge(self.backgroundForwardBadge(owner));
        }
    }
    fn backgroundForwardBadge(self: *Workspace, owner: identity.AssetOwner) ?sidebar_view.ForwardBadge {
        const bridge = self.background_forward_bridge;
        return if (bridge.badge) |read| read(bridge.context, owner) else null;
    }

    pub fn rebuildSidebar(self: *Workspace) !void {
        // Preserve an interrupted group's visible height across the registry's
        // safe-boundary row rebuild; persistence still owns the final state.
        const FoldFrame = struct { reference: sidebar_view.GroupRef, collapsed: bool, height: f32, animating: bool };
        var folds: std.ArrayList(FoldFrame) = .empty;
        defer folds.deinit(self.allocator);
        for (self.group_rows.items) |row| if (row.reference) |reference| {
            try folds.append(self.allocator, .{ .reference = reference, .collapsed = row.collapsed, .height = row.disclosure.root.globalRect().h, .animating = row.disclosure.animating });
        };
        try self.identities.appendHosts(self.allocator, self.registry.hosts.len);
        if (self.default_group_row) |row| if (!self.default_group_forced_open) {
            self.default_group_collapsed = row.collapsed;
        };
        self.default_group_row = null;
        // End focus/hover while handlers still own their scope. The rows below
        // are rebuilt only after the originating event has returned.
        for (self.sidebar_list.children.items) |child| self.cx.invalidateReferencesTo(child);
        if (self.sidebar_scope) |old| old.dispose();
        self.sidebar_scope = null;
        while (self.sidebar_list.children.items.len > 0) {
            const child = self.sidebar_list.children.items[self.sidebar_list.children.items.len - 1];
            self.cx.detachChild(self.sidebar_list, child);
            self.cx.destroyDetached(child);
        }
        self.host_rows.clearRetainingCapacity();
        self.group_headers.clearRetainingCapacity();
        self.group_rows.clearRetainingCapacity();
        const scope = try self.scope.childScope();
        self.sidebar_scope = scope;
        self.sidebar_list.setStyleInline(self.allocator, sidebar_view.styles.list());
        const query = self.search_query[0..self.search_len];
        self.default_group_forced_open = query.len > 0;
        for (0..self.registry.groups.len + 1) |group_index| {
            const group = if (group_index == 0) null else self.registry.groups[group_index - 1];
            const group_id = if (group) |value| value.group_id else null;
            var matches: std.ArrayList(usize) = .empty;
            defer matches.deinit(self.allocator);
            const ids = try self.registry.orderedIds(self.allocator, group_id);
            defer self.allocator.free(ids);
            var count: usize = 0;
            for (ids) |id| {
                const index = self.registry.indexOf(id) orelse continue;
                count += 1;
                if (self.sidebarMatches(index, query)) try matches.append(self.allocator, index);
            }
            // Unsaved quick-connect entries have a runtime host identity only.
            if (group_id == null) for (self.registry.hosts, 0..) |host, index| {
                if (@backingInt(host.connection_id) != 0) continue;
                count += 1;
                if (self.sidebarMatches(index, query)) try matches.append(self.allocator, index);
            };
            if (group == null and count == 0) continue;
            if (query.len > 0 and matches.items.len == 0 and !matchesFold(if (group) |value| value.name else "默认分组", query)) continue;
            const section = try sidebar_view.GroupRow.mount(self.cx, scope, .{
                .reference = if (group) |value| .{ .id = value.group_id, .revision = value.revision } else null,
                .name = if (group) |value| value.name else "默认分组",
                .count = count,
                .collapsed = if (query.len > 0) false else if (group) |value| value.collapsed else self.default_group_collapsed,
                .color = if (group) |value| sidebarGroupColor(value.color) else null,
            }, self.sidebar_bridge);
            if (group == null) self.default_group_row = section;
            try self.sidebar_list.appendChild(self.allocator, section.root);
            try self.group_headers.append(self.allocator, section.root);
            try self.group_rows.append(self.allocator, section);
            if (section.reference) |reference| for (folds.items) |fold| {
                if (fold.reference.id == reference.id and (fold.collapsed != section.collapsed or fold.animating)) {
                    section.disclosure.motion = .{ .value = fold.height, .target = fold.height, .from = fold.height };
                    section.disclosure.animating = true;
                    section.disclosure.root.setStyle(self.allocator, .height, .{ .px = fold.height });
                    break;
                }
            };
            for (matches.items) |index| {
                const host = self.registry.hosts[index];
                const context = try self.newClickCtx(index);
                const route = try self.sidebarRoute(host);
                defer self.allocator.free(route);
                const detail = try std.fmt.allocPrint(self.allocator, "{s}@{s}:{d}", .{ host.user, host.host, host.port });
                defer self.allocator.free(detail);
                const row = try sidebar_view.HostRow.mount(self.cx, scope, .{
                    .name = host.name,
                    .kind = if (host.protocol == .sftp) .file else .terminal,
                    .icon = session_icon.forHost(self.plugins, host.protocolId(), @import("session_os_cache.zig").load(self.allocator, self.io, self.hosts_path, host)),
                    .protocol = host.protocolId(),
                    .supports_route = if (self.plugins.find(host.protocolId())) |plugin| plugin.supports(@import("../host/plugin_registry.zig").legacyServiceDefinitions(&.{.route})[0]) else false,
                    .detail = detail,
                    .route = route,
                    .hops = if (host.route.len > 0) host.route.len else host.jump_chain.len,
                    .online = self.hostOnline(index),
                    .selected = self.selected_host == index,
                    .forward = self.backgroundForwardBadge(host.owner()),
                }, .{ .context = context, .select = onSidebarSelect, .connect = onSidebarConnect, .menu = onSidebarMenu, .action = onSidebarAction });
                context.node = row.node;
                try section.members.appendChild(self.allocator, row.node);
                try self.host_rows.append(self.allocator, .{ .node = row.node, .name_node = row.name, .host_index = index, .click_ctx = context, .view = row });
            }
        }
        if (query.len > 0 and self.host_rows.items.len == 0 and self.group_headers.items.len == 0) {
            const empty = try ui.box(self.cx, .{ .width = .fill(), .padding = ui.Padding.all(12) }, .{});
            _ = try sidebar_view.text(self.cx, empty, "未找到匹配的主机或分组", 11, 400, true);
            try self.sidebar_list.appendChild(self.allocator, empty);
        }
        self.cx.requestRedraw();
    }

    fn sidebarMatches(self: *Workspace, index: usize, query: []const u8) bool {
        const host = self.registry.hosts[index];
        return query.len == 0 or matchesFold(host.name, query) or matchesFold(host.host, query) or matchesFold(host.group orelse "", query);
    }
    fn sidebarRoute(self: *Workspace, host: hosts_mod.HostConfig) ![]const u8 {
        const hops = if (host.route.len > 0) host.route.len else host.jump_chain.len;
        const parts = try self.allocator.alloc([]const u8, hops + 2);
        defer self.allocator.free(parts);
        parts[0] = "本机";
        for (0..hops) |i| parts[i + 1] = if (host.route.len > 0) if (self.registry.indexOf(host.route[i])) |position| self.registry.hosts[position].name else "缺失的跳板" else host.jump_chain[i];
        parts[hops + 1] = host.name;
        return std.mem.join(self.allocator, " → ", parts);
    }
    fn sidebarIndex(cell: *ClickCtx) ?usize {
        if (cell.asset_owner) |owner| {
            _ = cell.workspace.registry.get(owner) catch return null;
            return cell.workspace.registry.indexOf(owner.id);
        }
        return cell.workspace.identities.hostIndex(cell.host_id orelse return null);
    }
    fn onSidebarAction(raw: *anyopaque, action: sidebar_view.HostAction) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(raw));
        const index = sidebarIndex(cell) orelse return;
        const run = cell.workspace.menu_bridge.host_action orelse return;
        run(cell.workspace.menu_bridge.context, index, action);
    }
    fn onSidebarSelect(raw: *anyopaque) void {
        onSidebarConnect(raw);
    }
    fn onSidebarConnect(raw: *anyopaque) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(raw));
        const index = sidebarIndex(cell) orelse return;
        cell.workspace.selected_host = index;
        cell.workspace.refreshSelection();
        cell.workspace.newSession(index) catch |err| cell.workspace.statusFailure(@errorName(err));
    }
    fn onSidebarMenu(raw: *anyopaque, node: *ui.Node) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(raw));
        const index = sidebarIndex(cell) orelse return;
        cell.workspace.selected_host = index;
        cell.workspace.refreshSelection();
        cell.workspace.menu_bridge.fireHost(.host_right_click, index, node.globalRect());
    }
    fn sidebarGroupColor(value: []const u8) ?ui.Color {
        if (value.len == 7 and value[0] == '#') return ui.Color.hex(std.fmt.parseInt(u24, value[1..], 16) catch return null);
        if (std.mem.eql(u8, value, "blue") or std.mem.eql(u8, value, "purple")) return app_theme.current().accent;
        if (std.mem.eql(u8, value, "green")) return app_theme.current().ok;
        if (std.mem.eql(u8, value, "orange")) return app_theme.current().warn;
        return null;
    }

    /// mockup-main 侧栏状态点：有存活会话（runtime 已连接）的主机为绿，
    /// 其余灰（#CBD5E1）。失败会话由页签红点表达，主机行不标红。
    pub fn hostOnline(self: *Workspace, host_index: usize) bool {
        for (self.tabs.items) |tab| {
            if (tab.host_id != self.identities.hostAt(host_index) or tab.failed) continue;
            if (tab.terminal) |*terminal| {
                if (tab.runtime != null and terminal.tombstone.state == .active) return true;
            } else if (tab.file_ready) return true;
        }
        return false;
    }

    fn refreshSelection(self: *Workspace) void {
        for (self.host_rows.items) |row| row.view.setSelected(self.selected_host == row.host_index);
        self.cx.requestRedraw();
    }

    pub fn setSearch(self: *Workspace, query: []const u8) void {
        const n = @min(query.len, self.search_query.len);
        @memcpy(self.search_query[0..n], query[0..n]);
        self.search_len = n;
        self.rebuildSidebar() catch return;
    }

    // ── Tabs ─────────────────────────────────────────────────────────

    pub fn rebuildTabBar(self: *Workspace) !void {
        try self.startPollLoop();
        self.tab_rebuild_pending = true;
        self.cx.requestRedraw();
    }

    /// The menu passes its captured TabId, never the current active session.
    pub fn showTabColor(self: *Workspace, id: identity.TabId) void {
        const index = self.tabIndexById(id) orelse return;
        if (self.tabs.items[index].closing) return;
        const anchor = for (self.tab_nodes.items) |cell| {
            if (cell.tab_id == id) break cell.node;
        } else return;
        if (self.color_picker == null) {
            const view = tab_color_picker.View.mount(self.cx, self.scope, .{ .context = self, .commit = commitTabColor }) catch return;
            view.root.style.width = .{ .px = 0 };
            view.root.style.height = .{ .px = 0 };
            self.tab_bar.appendChild(self.allocator, view.root) catch return;
            self.color_picker = view;
        }
        self.color_picker.?.show(@backingInt(id), anchor);
    }

    fn commitTabColor(raw: *anyopaque, owner: u64, color: u32) bool {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        const index = self.tabIndexById(@fromBackingInt(owner)) orelse return false;
        const tab = self.tabs.items[index];
        if (tab.closing) return false;
        tab.tab_color = color;
        self.rebuildTabBar() catch return false;
        return true;
    }

    pub fn setNotificationAttentionBridge(self: *Workspace, bridge: NotificationAttentionBridge) void {
        self.notification_attention_bridge = bridge;
        self.refreshNotificationAttention();
    }

    /// Tab titles have no trailing notification marker. Host read tracking
    /// remains independent of the tab's connection icon and custom title color.
    pub fn refreshNotificationAttention(_: *Workspace) void {}

    fn installTabModel(self: *Workspace, tab: *SessionTab) !void {
        tab.tab_color = self.creation_tab_color;
        if (self.owned_creation_pending) {
            tab.owned_pending = true;
            tab.owned_origin = true;
            tab.root.setDisplay(.none);
            return;
        }
        try self.model.tabs.ensureUnusedCapacity(self.allocator, self.prepared_group_views + 1);
        try self.model.recent.ensureUnusedCapacity(self.allocator, self.prepared_group_views + 1);
        try self.model.append(tab.tab_id, tab.content_owner, tab.titleSlice());
        errdefer self.model.completeClose(tab.tab_id, tab.content_owner) catch {};
        const detail = if (tab.host_snapshot) |saved| blk: {
            const protocol = saved.value.protocolId();
            const fallback = try std.ascii.allocUpperString(self.allocator, protocol);
            defer self.allocator.free(fallback);
            const kind = if (tab.archived) "只读历史" else if (self.plugins.find(protocol)) |manifest| manifest.display_name else fallback;
            break :blk try std.fmt.allocPrint(self.allocator, "{s}@{s}:{d} · {s}", .{ saved.value.user, saved.value.host, saved.value.port, kind });
        } else try self.allocator.dupe(u8, if (tab.local) "本机 · macOS · /bin/zsh" else if (self.plugins.find(tab.plugin_protocol_id)) |manifest| manifest.display_name else tab.titleSlice());
        defer self.allocator.free(detail);
        try self.model.setDetails(tab.tab_id, detail);
        if (self.creation_group) |group_id| if (self.group_roster) |roster| if (roster.findById(group_id)) |group| {
            if (!self.groupClosing(group_id) and tab.terminal != null and !tab.archived) {
                _ = try roster.join(group.name, tab.id, group.color);
                if (self.groupTabId(group_id)) |parent| try self.model.setContainer(tab.tab_id, parent);
                self.active_group_view = group_id;
                self.group_present_pending = true;
                if (self.groupView(group_id)) |view| view.dirty = true;
            }
        };
        self.reveal_active = true;
    }

    fn measureTabs(self: *Workspace) !void {
        const count = self.model.visibleCount();
        try self.strip_advances.resize(self.allocator, count);
        try self.strip_widths.resize(self.allocator, count);
        const family = if (self.font_family_resolver) |resolve| resolve("Inter Variable") else 0;
        for (self.strip_advances.items, 0..) |*advance, ordinal| {
            const tab = &self.model.tabs.items[self.model.visibleAt(ordinal).?];
            // Match the visual line used by native Text's ellipsis check.
            // Round outward so adding/removing the 76px chrome cannot round
            // a fractional title width down and spuriously truncate it.
            const line = self.cx.text.visualLine(.{ .text = tab.name(), .font_family = if (family != 0) "Inter Variable" else "system", .font_family_id = family, .font_size = tab_styles.title_font, .font_weight = tab_styles.title_weight }) catch {
                advance.* = @ceil(self.cx.text.measureTextWidth(tab.name(), tab_styles.title_font, tab_styles.title_weight, false));
                continue;
            };
            advance.* = @ceil(line.width);
        }
        self.header_width = @max(0, self.cx.viewport.width - 2 * @import("shell_styles.zig").outer);
        self.strip_geometry = try tab_layout.calculate(self.header_width, self.strip_advances.items, self.strip_widths.items, self.strip_offset);
        if (self.reveal_active) {
            if (self.model.active) |id| {
                if (self.model.visibleIndexOf(id)) |index| self.strip_geometry.offset = try tab_layout.reveal(self.strip_geometry, self.strip_widths.items, index);
            }
            self.reveal_active = false;
        }
        self.strip_offset = self.strip_geometry.offset;
        // Revealing the active tab can change the calculated offset. Arrow
        // gates must reflect that final viewport, including after a resize.
        self.strip_geometry.can_scroll_left = self.strip_offset > 0;
        self.strip_geometry.can_scroll_right = self.strip_offset < @max(0, self.strip_geometry.content - self.strip_geometry.viewport);
    }

    fn renderTabBar(self: *Workspace) !void {
        if (self.model.dragging) return;
        if (self.tab_scope) |old_scope| old_scope.dispose();
        self.tab_scope = null;
        if (self.strip_root) |old| {
            self.cx.detachChild(self.tab_bar, old);
            self.cx.destroyDetached(old);
        }
        self.strip_root = null;
        self.strip_content = null;
        self.strip_viewport = null;
        self.drag_gap = null;
        self.picker_anchor = null;
        var cell_index: usize = 0;
        while (cell_index < self.click_ctxs.items.len) {
            const cell = self.click_ctxs.items[cell_index];
            if (cell.tab_id != null) {
                _ = self.click_ctxs.orderedRemove(cell_index);
                self.allocator.destroy(cell);
            } else cell_index += 1;
        }
        if (self.tab_generation == std.math.maxInt(u64)) return error.RevisionExhausted;
        self.tab_generation += 1;
        self.tab_nodes.clearRetainingCapacity();
        try self.measureTabs();
        const scope = try self.scope.childScope();
        self.tab_scope = scope;
        const overflow = self.strip_geometry.mode == .overflow;
        const viewport_width = if (overflow) self.strip_geometry.viewport else self.strip_geometry.content;
        const strip_width = viewport_width + (if (overflow) @as(f32, 88) else 0);
        // The initially empty strip has already participated in the title
        // layout. Its new size must invalidate the parent's child-size cache.
        self.tab_bar.setStyle(self.allocator, .width, .{ .px = strip_width });
        self.tab_bar.setStyle(self.allocator, .height, .{ .px = tab_styles.height });
        self.tab_bar.setStyleInline(self.allocator, .{ .gap = 0, .flex_shrink = 0 });
        var row_style = tab_styles.strip();
        row_style.width = .{ .px = strip_width };
        const row = try ui.box(self.cx, row_style, .{});
        row.meta.ownership.meta.test_id = "tabs.strip";
        self.strip_root = row;
        if (overflow) _ = try self.stripControl(scope, row, ui.icons.chevron_left, "向左滚动页签", "tabs.scroll_left", 24, !self.strip_geometry.can_scroll_left, scrollLeft);
        const viewport = try ui.box(self.cx, .{ .width = .{ .px = viewport_width }, .height = .{ .px = tab_styles.height }, .overflow_hidden = true, .flex_shrink = 0 }, .{});
        viewport.meta.ownership.meta.test_id = "tabs.viewport";
        viewport.behavior.events.event_context = self;
        viewport.behavior.events.on_event = onStripEvent;
        self.strip_viewport = viewport;
        const content = try ui.box(self.cx, tab_styles.strip(), .{});
        content.style.width = .{ .px = self.strip_geometry.content };
        content.style.translate_x = -self.strip_offset;
        self.strip_content = content;
        try viewport.appendChild(self.cx.allocator, content);
        try row.appendChild(self.cx.allocator, viewport);
        const drag_gap = try ui.box(self.cx, tab_styles.dragGap(), .{});
        drag_gap.meta.ownership.meta.test_id = "tabs.drag_destination";
        drag_gap.setDisplay(.none);
        try viewport.appendChild(self.allocator, drag_gap);
        self.drag_gap = drag_gap;
        const family = if (self.font_family_resolver) |resolve| resolve("Inter Variable") else 0;
        for (0..self.model.visibleCount()) |ordinal| {
            const index = self.model.visibleAt(ordinal).?;
            const model_tab = &self.model.tabs.items[index];
            const tab = if (self.tabIndexById(model_tab.id)) |at| self.tabs.items[at] else null;
            const group_id = self.groupIdByTab(model_tab.id);
            const width = self.strip_widths.items[ordinal];
            const active = self.model.active == model_tab.id;
            const holder = try ui.box(self.cx, .{ .width = .{ .px = width }, .height = .{ .px = tab_styles.height }, .flex_shrink = 0 }, .{});
            if (group_id != null) holder.meta.ownership.meta.test_id = "groups.tab";
            const select_ctx = try self.newTabClickCtx(index);
            const full_name = try std.fmt.allocPrint(self.allocator, "{s}\n{s}\n{s}", .{ self.model.tabs.items[index].name(), self.model.tabs.items[index].details, self.tabStatus(model_tab.id) });
            defer self.allocator.free(full_name);
            const tooltip = try ui.widgets.Tooltip(.{ .text = full_name, .position = .bottom_start, .open_delay_ms = 450, .background = app_theme.current().overlay, .text_color = app_theme.current().fg_1, .font_size = 11 }).mount(scope, self.cx);
            tooltip.content.meta.ownership.meta.test_id = "tabs.tooltip";
            tooltip.content.setStyleInline(self.allocator, tab_styles.tooltip());
            try app_theme.bindMaterial(self.cx, scope, tooltip.content, "overlay");
            for (tooltip.content.children.items) |label| if (label.getText()) |old| {
                var text_style = old;
                text_style.wrap = .word;
                text_style.line_height = 1.5;
                label.setText(text_style);
                label.setStyleInline(self.allocator, .{ .width = .fill(), .min_width = 0, .max_width = 280 });
            };
            tooltip.wrapper.style.width = .fill();
            tooltip.wrapper.style.height = .fill();
            tooltip.trigger.style.width = .fill();
            tooltip.trigger.style.height = .fill();
            const tab_box = try ui.box(self.cx, tab_styles.tab(width, active), .{});
            if (group_id) |id| if (self.groupTabColor(id)) |color| {
                tab_box.setBackground(tab_styles.groupTint(color));
                const marker = try ui.box(self.cx, tab_styles.groupMarker(color), .{});
                marker.meta.ownership.meta.test_id = "tabs.group_marker";
                try tab_box.appendChild(self.allocator, marker);
            };
            select_ctx.node = tab_box;
            tab_box.meta.ownership.meta.test_id = try std.fmt.bufPrint(&select_ctx.test_id, "tabs.tab.{d}", .{@backingInt(model_tab.id)});
            tab_box.behavior.interaction.focusable = true;
            tab_box.behavior.interaction.a11y = .{ .role = .tab, .label = model_tab.name(), .selected = active };
            tab_box.behavior.events.event_context = select_ctx;
            tab_box.behavior.events.on_click = .{ .callback = onSelectTabTrampoline, .context = select_ctx };
            tab_box.behavior.events.on_event_capture = onTabBoxEvent;
            tab_box.behavior.events.on_hover = .{ .callback = tabHover, .context = select_ctx };
            tab_box.behavior.events.on_leave = .{ .callback = tabLeave, .context = select_ctx };
            tab_box.behavior.events.on_focus = .{ .callback = tabFocus, .context = select_ctx };
            tab_box.behavior.events.on_blur = .{ .callback = tabLeave, .context = select_ctx };
            const icon_slot = try ui.box(self.cx, tab_styles.iconSlot(), .{});
            const connection_color = if (group_id != null) app_theme.current().fg_2 else if (tab.?.failed) self.palette.red else if (tab.?.plugin_renderer != null) (if (tab.?.content_ready) self.palette.green else self.palette.fg_muted) else if (tab.?.terminal == null) (if (tab.?.file_ready) self.palette.green else self.palette.fg_muted) else if (tab.?.terminal.?.tombstone.state != .active) self.palette.fg_muted else if (tab.?.runtime != null or (tab.?.local and tab.?.local_state == .running)) self.palette.green else self.palette.fg_muted;
            const type_icon = try ui.iconTint(self.cx, if (group_id != null) ui.icons.get("panels-top-left").? else self.tabIcon(tab.?), connection_color, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } });
            try icon_slot.appendChild(self.cx.allocator, type_icon);
            const number = try ui.text(self.cx, "", .{ .font_size = 10, .font_weight = 500, .color = app_theme.current().fg_2, .selectable = false });
            number.meta.ownership.meta.test_id = "tabs.ordinal";
            type_icon.meta.ownership.meta.test_id = "tabs.type_icon";
            number.setDisplay(.none);
            try icon_slot.appendChild(self.cx.allocator, number);
            try tab_box.appendChild(self.cx.allocator, icon_slot);
            var label_style = tab_styles.title();
            label_style.font_family = family;
            label_style.color = if (group_id == null and tab.?.tab_color != null) ui.Color.hex(@intCast(tab.?.tab_color.?)) else if (active) app_theme.current().fg_1 else app_theme.current().fg_2;
            const title = try ui.text(self.cx, self.model.tabs.items[index].name(), label_style);
            title.meta.ownership.meta.test_id = "tabs.title";
            title.setStyleInline(self.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 30 }, .top = .{ .px = (tab_styles.height - 18) / 2 } }, .width = .{ .px = width - 62 }, .height = .{ .px = 18 }, .overflow_hidden = true });
            try tab_box.appendChild(self.cx.allocator, title);
            const close_ctx = try self.newTabClickCtx(index);
            const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 12), .icon_tint = self.palette.fg_muted, .a11y_label = if (group_id != null) "关闭组内全部会话" else "关闭页签", .base_style = tab_styles.close(width), .on_click = ui.Cx.simpleHandler(onCloseTabTrampoline, close_ctx) }).mount(scope, self.cx);
            // Button's recipe resolves chrome but does not forward positioning.
            close.setStyleInline(self.allocator, tab_styles.close(width));
            close.meta.ownership.meta.test_id = if (group_id != null) "groups.close" else try std.fmt.bufPrint(&close_ctx.test_id, "tabs.close.{d}", .{@backingInt(model_tab.id)});
            close.behavior.events.capture_context = close_ctx;
            close.behavior.events.on_event_capture = onCloseControlEvent;
            close.setOpacity(if (active) 1 else 0);
            close.setHitTestVisible(active);
            close.setFocusable(active);
            try tab_box.appendChild(self.cx.allocator, close);
            if (active) {
                const underline = try ui.box(self.cx, tab_styles.underline(width), .{});
                try tab_box.appendChild(self.cx.allocator, underline);
            }
            try tooltip.trigger.appendChild(self.cx.allocator, tab_box);
            try holder.appendChild(self.cx.allocator, tooltip.wrapper);
            try content.appendChild(self.cx.allocator, holder);
            const drag = try ui.interaction.drag.Binding.attach(scope, self.cx, holder, .{ .axis = .horizontal, .activation_distance = 5 }, onTabDrag, select_ctx);
            select_ctx.drag_binding = drag;
            try self.tab_nodes.append(self.allocator, .{ .node = tab_box, .holder = holder, .icon = number, .type_icon = type_icon, .label = title, .close = close, .tab_id = model_tab.id, .tab_index = index, .select_ctx = select_ctx, .close_ctx = close_ctx });
        }
        if (overflow) {
            _ = try self.stripControl(scope, row, ui.icons.chevron_right, "向右滚动页签", "tabs.scroll_right", 24, !self.strip_geometry.can_scroll_right, scrollRight);
            self.picker_anchor = try self.stripControl(scope, row, ui.icons.list, "全部页签", "tabs.all", 28, false, showPicker);
        }
        try self.tab_bar.appendChild(self.cx.allocator, row);
        if (self.picker_view == null) {
            const picker_view = try tab_picker.View.mount(self.cx, self.scope, .{ .virtual = .{ .ctx = self, .getRect = pickerAnchor } }, &self.model, &self.picker, .{ .context = self, .activate = pickerActivate, .dismiss = pickerDismiss, .status = pickerStatus });
            picker_view.wrapper.style.width = .{ .px = 0 };
            picker_view.wrapper.style.height = .{ .px = 0 };
            try self.tab_bar.appendChild(self.cx.allocator, picker_view.wrapper);
            self.picker_view = picker_view;
        }
        self.refreshCommandIcons();
        self.refreshNotificationAttention();
        self.cx.requestRedraw();
    }

    fn tabShowsHistory(tab: *const SessionTab) bool {
        return tab.archived or (if (tab.terminal) |terminal| terminal.history.selected != null else false);
    }

    fn tabIcon(self: *Workspace, tab: *SessionTab) ui.SvgAsset {
        if (tabShowsHistory(tab)) return session_icon.resolve(.history);
        if (tab.local) return session_icon.forOs(@import("../proto/ssh/remote_os.zig").local()) orelse session_icon.resolve(.terminal);
        if (tab.plugin_protocol_id.len != 0) return session_icon.forConnection(self.plugins, tab.plugin_protocol_id, self.tabOs(tab), false);
        if (tab.host_snapshot) |saved| return session_icon.forConnection(self.plugins, saved.value.protocolId(), self.tabOs(tab), false);
        return session_icon.forTab(tab.local, false, tab.terminal != null);
    }

    fn refreshHistoryTabIcons(self: *Workspace) void {
        for (self.tab_nodes.items) |node| {
            const index = self.tabIndexById(node.tab_id) orelse continue;
            const tab = self.tabs.items[index];
            const old = node.type_icon.getIcon() orelse continue;
            if (tabShowsHistory(tab) == (old.icon_id == session_icon.resolve(.history).icon_id.?)) continue;
            const asset = self.tabIcon(tab);
            node.type_icon.setIcon(.{ .icon_id = asset.icon_id.?, .rep = asset.pickRep(14).?, .tint = old.tint });
            node.type_icon.markRenderDirty();
        }
    }

    fn tabOs(self: *Workspace, tab: *SessionTab) session_icon.Os {
        if (tab.detected_os != .unknown) return tab.detected_os;
        if (tab.host_snapshot) |saved| return @import("session_os_cache.zig").load(self.allocator, self.io, self.hosts_path, saved.value);
        if (tab.host_index < self.registry.hosts.len) return @import("session_os_cache.zig").load(self.allocator, self.io, self.hosts_path, self.registry.hosts[tab.host_index]);
        return .unknown;
    }

    fn stripControl(self: *Workspace, scope: *ui.Scope, parent: *ui.Node, icon: ui.SvgAsset, label: []const u8, test_id: []const u8, width: f32, disabled: bool, comptime callback: fn (*Workspace) void) !*ui.Node {
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = icon, .icon_size = @as(f32, 14), .icon_tint = self.palette.fg_secondary, .a11y_label = label, .disabled = disabled, .base_style = tab_styles.control(width), .on_click = self.cx.on(Workspace, self, callback) }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = test_id;
        try parent.appendChild(self.cx.allocator, button);
        return button;
    }

    fn scrollLeft(self: *Workspace) void {
        self.scrollTabs(-180);
    }
    fn scrollRight(self: *Workspace) void {
        self.scrollTabs(180);
    }
    fn scrollTabs(self: *Workspace, delta: f32) void {
        if (self.strip_geometry.mode != .overflow) return;
        self.strip_offset = std.math.clamp(self.strip_offset + delta, 0, @max(0, self.strip_geometry.content - self.strip_geometry.viewport));
        if (self.strip_content) |content| content.setStyle(self.allocator, .translate_x, -self.strip_offset);
        self.rebuildTabBar() catch {};
    }
    fn onStripEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const self: *Workspace = @ptrCast(@alignCast(context orelse return .ignored));
        if (event == .scroll and self.strip_geometry.mode == .overflow) {
            const scroll = event.scroll;
            const delta = if (scroll.modifiers.shift) scroll.dy else scroll.dx;
            if (delta == 0) return .ignored;
            self.scrollTabs(-delta);
            return .stop;
        }
        return .ignored;
    }
    fn showPicker(self: *Workspace) void {
        self.picker_focus_return = self.model.active;
        if (self.picker_view) |view| view.show(1) catch {};
    }
    fn pickerAnchor(context: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *Workspace = @ptrCast(@alignCast(context));
        const rect = (self.picker_anchor orelse self.tab_bar).globalRect();
        const shell = @import("shell_styles.zig");
        // Keep the trigger's horizontal anchor, with the popup below the
        // title card (Figma 259:238985 y62 = title bottom54 + offset8).
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @max(rect.h, shell.outer + shell.title_height - rect.y) };
    }
    fn pickerActivate(context: *anyopaque, id: identity.TabId) void {
        const self: *Workspace = @ptrCast(@alignCast(context));
        self.activateTabId(id);
    }
    fn pickerDismiss(context: *anyopaque) void {
        const self: *Workspace = @ptrCast(@alignCast(context));
        if (self.picker_anchor) |node| self.cx.setFocus(node) else if (self.picker_focus_return) |id| {
            if (self.tabIndexById(id)) |index| self.cx.setFocus(if (self.tabs.items[index].terminal) |*terminal| terminal.root else self.tabs.items[index].root);
        }
    }
    fn pickerStatus(context: *anyopaque, id: identity.TabId) []const u8 {
        const self: *Workspace = @ptrCast(@alignCast(context));
        if (self.model.active == id) return "当前";
        return self.tabStatus(id);
    }
    fn tabStatus(self: *Workspace, id: identity.TabId) []const u8 {
        if (self.groupIdByTab(id)) |group| {
            return if (self.groupClosing(group)) "关闭中" else "终端组";
        }
        const index = self.tabIndexById(id) orelse return "已关闭";
        const tab = self.tabs.items[index];
        if (tab.archived) return "只读";
        if (tab.failed) return "离线";
        if (tab.local) return switch (tab.local_state) {
            .running => "在线",
            .starting => "连接中",
            .exited, .failed, .closing, .cleanup_unknown => "离线",
        };
        if (tab.plugin_renderer != null) return if (tab.content_ready) "在线" else "连接中";
        if (tab.terminal == null) return if (tab.file_ready) "在线" else "连接中";
        if (tab.terminal.?.tombstone.state != .active) return "离线";
        return if (tab.runtime != null) "在线" else "连接中";
    }

    pub fn setCommandHeld(self: *Workspace, held: bool) void {
        if (self.command_held == held) return;
        self.command_held = held;
        self.refreshCommandIcons();
    }
    fn refreshCommandIcons(self: *Workspace) void {
        for (self.tab_nodes.items, 0..) |*node, index| {
            const numbered = self.command_held and index < 9;
            if (numbered) {
                const digits = "123456789";
                node.icon.setTextContent(self.allocator, digits[index .. index + 1]) catch {};
            }
            node.icon.setDisplay(if (numbered) .flex else .none);
            node.type_icon.setDisplay(if (numbered) .none else .flex);
        }
        self.cx.requestRedraw();
    }
    pub fn handleTabKey(self: *Workspace, key: ui.events.KeyCode, modifiers: ui.events.Modifiers) ui.events.EventResult {
        if (self.rename_editor) |editor| if (editor.isVisible()) return editor.handleKey(key);
        if (self.rename_request != null) return .ignored;
        if (self.picker.open) {
            return if (self.picker_view) |view| view.handleKey(key) else .ignored;
        }
        if (self.model.dragging) {
            if (key == .escape) {
                if (self.drag_binding) |binding| binding.cancel(.escape);
                return .stop;
            }
            return .ignored;
        }
        const rename_chord = host_actions.descriptor(.rename_tab).default_chord.?;
        if (keybindings.fromKey(key) == rename_chord.key and modifiers.super == rename_chord.command and modifiers.ctrl == rename_chord.control and modifiers.alt == rename_chord.option and modifiers.shift == rename_chord.shift) {
            if (self.confirming_id != null or self.host_key_job != null or self.auth_job != null) return .ignored;
            if (self.model.active) |id| if (self.groupIdByTab(id)) |group| {
                if (self.groupClosing(group)) return .ignored;
                self.beginRenamePresentation(id) catch |err| self.statusFailure(@errorName(err));
                return .stop;
            };
            if (self.active_tab) |index| if (index < self.tabs.items.len and !self.tabs.items[index].closing) {
                if (self.tabs.items[index].terminal != null and self.tabs.items[index].terminal.?.preedit != null) return .ignored;
                self.beginRenameTab(self.tabs.items[index].id) catch |err| self.statusFailure(@errorName(err));
                return .stop;
            };
            return .ignored;
        }
        const chord = host_actions.descriptor(.recent_tab).default_chord.?;
        if (keybindings.fromKey(key) != chord.key or modifiers.ctrl != chord.control or modifiers.super != chord.command or modifiers.alt != chord.option) return .ignored;
        if (self.confirming_id != null or self.host_key_job != null or self.auth_job != null) return .ignored;
        if (self.active_tab) |index| if (index < self.tabs.items.len) {
            const terminal = if (self.tabs.items[index].terminal) |*value| value else null;
            if (terminal != null and (terminal.?.preedit != null or terminal.?.local_editor.active)) return .ignored;
        };
        var excluded: std.ArrayList(identity.TabId) = .empty;
        defer excluded.deinit(self.allocator);
        for (self.tabs.items) |tab| if (tab.closing) {
            excluded.append(self.allocator, tab.tab_id) catch return .stop;
        };
        for (self.group_views.items) |view| if (self.groupClosing(view.id)) {
            if (self.groupTabId(view.id)) |id| excluded.append(self.allocator, id) catch return .stop;
        };
        const id = self.model.cycleRecent(modifiers.shift, excluded.items) catch return .stop;
        if (id) |target| self.presentTabId(target);
        return .stop;
    }
    /// Called on Control release and window blur, never on each Tab preview.
    pub fn finishRecentTabSwitch(self: *Workspace) void {
        self.model.finishRecentSwitch();
    }
    fn closeVisible(self: *Workspace, cell: *ClickCtx, visible: bool) void {
        for (self.tab_nodes.items) |*node| if (node.tab_id == cell.tab_id) {
            const focused = if (self.cx.focused_node) |focus| focus == node.node or focus.isDescendantOf(node.node) else false;
            const show = visible or focused or self.model.active == node.tab_id;
            node.close.setOpacity(if (show) 1 else 0);
            node.close.setHitTestVisible(show);
            node.close.setFocusable(show);
            const group_color = if (self.groupIdByTab(node.tab_id)) |id| self.groupTabColor(id) else null;
            node.node.setBackground(if (group_color) |color| tab_styles.groupTint(color) else if (self.model.active == node.tab_id) app_theme.current().tab_on else if (cell.hovered) app_theme.current().hover else ui.Color.TRANSPARENT);
            return;
        };
    }
    fn tabHover(context: *anyopaque) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(context));
        cell.hovered = true;
        cell.workspace.closeVisible(cell, true);
    }
    fn tabLeave(context: *anyopaque) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(context));
        cell.hovered = false;
        cell.workspace.closeVisible(cell, false);
    }
    fn tabFocus(context: *anyopaque) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(context));
        cell.workspace.closeVisible(cell, true);
    }
    fn onCloseControlEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const cell: *ClickCtx = @ptrCast(@alignCast(context orelse return .ignored));
        if (event == .click and event.click.button == .left) {
            onCloseTabTrampoline(cell);
            return .stop;
        }
        if (event == .mouse_down or event == .mouse_up) return .stop;
        return .ignored;
    }
    fn onTabDrag(event: ui.interaction.drag.Event, context: *anyopaque) void {
        const cell: *ClickCtx = @ptrCast(@alignCast(context));
        const self = cell.workspace;
        const id = cell.tab_id orelse return;
        switch (event.phase) {
            .start => {
                self.model.beginDrag() catch return;
                self.drag_tab = id;
                self.drag_binding = cell.drag_binding;
            },
            .move => {},
            .end, .cancel => {
                self.model.endDrag(event.phase == .cancel) catch {};
                self.drag_tab = null;
                self.drag_binding = null;
                if (self.drag_gap) |gap| gap.setDisplay(.none);
                self.syncModelOrder() catch {};
                self.rebuildTabBar() catch {};
                return;
            },
        }
        self.drag_pointer_x = event.position_window.x;
        self.moveDraggedTab();
    }
    fn moveDraggedTab(self: *Workspace) void {
        const id = self.drag_tab orelse return;
        const viewport = self.strip_viewport orelse return;
        const rect = viewport.globalRect();
        const content_x = self.drag_pointer_x - rect.x + self.strip_offset;
        var left: f32 = 0;
        var target: usize = 0;
        for (self.strip_widths.items, 0..) |width, index| {
            target = index;
            if (content_x < left + width / 2) break;
            left += width + tab_styles.gap;
        }
        self.model.moveTab(id, self.model.visibleAt(target) orelse return) catch return;
        self.syncModelOrder() catch {};
        if (self.drag_gap) |gap| {
            var destination: f32 = 0;
            for (self.strip_widths.items[0..target]) |width| destination += width + tab_styles.gap;
            gap.setStyle(self.allocator, .translate_x, destination - self.strip_offset - 2);
            gap.setDisplay(.flex);
        }
        if (self.strip_geometry.mode == .overflow and (self.drag_pointer_x < rect.x + 24 or self.drag_pointer_x > rect.x + rect.w - 24)) self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }
    fn autoScrollDrag(self: *Workspace) bool {
        if (!self.model.dragging or self.strip_geometry.mode != .overflow) return false;
        const rect = (self.strip_viewport orelse return false).globalRect();
        const delta: f32 = if (self.drag_pointer_x < rect.x + 24) -12 else if (self.drag_pointer_x > rect.x + rect.w - 24) 12 else return false;
        const old = self.strip_offset;
        self.strip_offset = std.math.clamp(old + delta, 0, @max(0, self.strip_geometry.content - self.strip_geometry.viewport));
        if (old == self.strip_offset) return false;
        if (self.strip_content) |content| content.setStyle(self.allocator, .translate_x, -self.strip_offset);
        self.moveDraggedTab();
        return true;
    }
    fn syncModelOrder(self: *Workspace) !void {
        // Presentation order belongs only to model.tabs. Session storage and
        // group member ownership never move when a tab crosses another kind.
        var next: usize = 0;
        for (self.model.tabs.items) |tab| {
            if (next >= self.tab_nodes.items.len) break;
            for (self.tab_nodes.items[next..], next..) |node, at| if (node.tab_id == tab.id) {
                std.mem.swap(TabNode, &self.tab_nodes.items[next], &self.tab_nodes.items[at]);
                next += 1;
                break;
            };
        }
        if (self.strip_content) |content| {
            const nodes = try self.allocator.alloc(*ui.Node, self.tab_nodes.items.len);
            defer self.allocator.free(nodes);
            for (self.tab_nodes.items, nodes, 0..) |*tab, *node, index| {
                tab.tab_index = index;
                node.* = tab.holder;
                self.strip_widths.items[index] = switch (tab.holder.style.width) {
                    .px => |width| width,
                    else => self.strip_widths.items[index],
                };
            }
            try content.replaceChildOrder(self.allocator, nodes);
        }
        self.refreshCommandIcons();
    }

    pub fn beginRenameTab(self: *Workspace, id: SessionId) !void {
        const index = self.tabIndex(id) orelse return error.InvalidTab;
        try self.beginRenamePresentation(self.tabs.items[index].tab_id);
    }

    fn beginRenamePresentation(self: *Workspace, id: identity.TabId) !void {
        self.rename_request = try self.model.beginRename(id);
        self.rename_draft.clearRetainingCapacity();
        try self.rename_draft.appendSlice(self.allocator, self.model.tabs.items[self.model.indexOf(id).?].name());
        self.rename_session = if (self.tabIndexById(id)) |index| self.tabs.items[index].id else null;
        self.rename_pending = true;
        try self.startPollLoop();
        self.cx.requestRedraw();
    }

    pub fn cancelRenameTab(self: *Workspace) bool {
        if (self.rename_session == null and self.rename_request == null) return false;
        self.rename_session = null;
        self.rename_request = null;
        self.rename_pending = true;
        self.cx.requestRedraw();
        self.restoreFocusToActiveTab();
        return true;
    }
    fn flushRename(self: *Workspace) !void {
        if (!self.rename_pending) return;
        self.rename_pending = false;
        if (self.rename_scope) |old| old.dispose();
        self.rename_scope = null;
        self.rename_editor = null;
        const request = self.rename_request orelse return;
        const index = self.model.indexOf(request.tab) orelse {
            self.rename_request = null;
            self.rename_session = null;
            return;
        };
        if (!self.model.tabs.items[index].owner.eql(request.owner)) return;
        const scope = try self.scope.childScope();
        self.rename_scope = scope;
        self.rename_editor = try tab_rename.Editor.mount(self.cx, scope, @backingInt(request.tab), self.rename_draft.items, .{ .context = self, .commit = commitRename, .cancel = cancelRename, .change = changeRename, .anchor = renameAnchor });
        self.cx.setFocus(self.rename_editor.?.node);
    }
    fn renameAnchor(raw: *anyopaque, id: u64) ?ui.ComputedRect {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        for (self.tab_nodes.items) |tab| if (@backingInt(tab.tab_id) == id) return tab.node.globalRect();
        return null;
    }
    fn commitRename(raw: *anyopaque, id: u64, name: []const u8) bool {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        const request = self.rename_request orelse return false;
        if (@backingInt(request.tab) != id) return false;
        self.model.rename(request, name) catch return false;
        if (self.tabIndexById(request.tab)) |index| self.tabs.items[index].setTitle(self.model.tabs.items[self.model.indexOf(request.tab).?].name());
        self.reveal_active = true;
        self.rebuildTabBar() catch {};
        _ = self.cancelRenameTab();
        return true;
    }
    fn changeRename(raw: *anyopaque, id: u64, name: []const u8) void {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        const request = self.rename_request orelse return;
        if (@backingInt(request.tab) != id) return;
        self.rename_draft.clearRetainingCapacity();
        self.rename_draft.appendSlice(self.allocator, name) catch {};
    }
    fn cancelRename(raw: *anyopaque, id: u64) void {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        const request = self.rename_request orelse return;
        if (@backingInt(request.tab) == id) _ = self.cancelRenameTab();
    }

    fn groupView(self: *Workspace, id: u32) ?*group_view.View {
        for (self.group_views.items) |view| if (view.id == id) return view;
        return null;
    }

    fn groupIdByTab(self: *const Workspace, id: identity.TabId) ?u32 {
        const at = self.model.indexOf(id) orelse return null;
        const owner = self.model.tabs.items[at].owner;
        return if (owner == .group) @intCast(@backingInt(owner.group.id)) else null;
    }

    pub fn groupTabId(self: *const Workspace, id: u32) ?identity.TabId {
        for (self.model.tabs.items) |tab| if (tab.owner == .group and @backingInt(tab.owner.group.id) == id) return tab.id;
        return null;
    }

    pub fn groupAssistantBounds(self: *Workspace, id: u32) ?ui.ComputedRect {
        const view = self.groupView(id) orelse return null;
        const root = view.root orelse return null;
        var bounds = root.globalRect();
        const bottom = bounds.y + bounds.h;
        var top = bottom;
        for (view.panes.items) |pane| {
            if (pane.node.children.items.len == 0) continue;
            const header = pane.node.children.items[0].globalRect();
            if (header.w > 0 and header.h > 0) top = @min(top, header.y + header.h);
        }
        if (top >= bottom) return null;
        bounds.y = @max(bounds.y, top);
        bounds.h = @max(0, bottom - bounds.y);
        return bounds;
    }

    fn groupTabColor(self: *Workspace, id: u32) ?ui.Color {
        const roster = self.group_roster orelse return null;
        const group = roster.findById(id) orelse return null;
        return ui.Color.hex(@truncate(group.color));
    }

    fn groupTabStatusColor(self: *Workspace, id: u32) ui.Color {
        const roster = self.group_roster orelse return self.palette.fg_muted;
        const group = roster.findById(id) orelse return self.palette.fg_muted;
        var pending = false;
        var failed = false;
        for (group.members.items) |member| if (self.sessionTab(member.pane_id)) |tab| {
            if (tab.local) {
                if (tab.local_state == .running and !tab.closing) return self.palette.green;
                pending = pending or tab.local_state == .starting;
                failed = failed or tab.local_state == .failed;
            } else {
                if (tab.runtime != null and tab.terminal != null and tab.terminal.?.tombstone.state == .active and !tab.failed and !tab.closing) return self.palette.green;
                pending = pending or (!tab.failed and !tab.closing and tab.runtime == null);
                failed = failed or tab.failed;
            }
        };
        return if (pending) app_theme.current().warn else if (failed) self.palette.red else self.palette.fg_muted;
    }

    pub fn activateTabId(self: *Workspace, id: identity.TabId) void {
        self.model.activate(id) catch return;
        self.presentTabId(self.model.active orelse return);
    }

    fn presentTabId(self: *Workspace, id: identity.TabId) void {
        if (self.rename_request) |request| {
            if (request.tab != id) _ = self.cancelRenameTab();
        }
        if (self.groupIdByTab(id)) |group| {
            self.active_group_view = group;
            if (self.groupView(group)) |view| view.dirty = true;
            self.reveal_active = true;
            self.group_present_pending = true;
            self.rebuildTabBar() catch {};
        } else if (self.tabIndexById(id)) |index| self.presentActiveTab(index);
    }

    pub const PreparedGroupView = struct {
        workspace: *Workspace,
        group_id: u32,
        tab: workspace_model.Tab,
        view: ?*group_view.View,
        source_tab: identity.TabId,
        source_owner: identity.ContentOwner,
        source_revision: u64,
        source_container: ?identity.TabId,

        pub fn validate(self: *const PreparedGroupView) !void {
            const workspace = self.workspace;
            if (self.view == null) return error.GroupTransactionConsumed;
            if (workspace.shutting_down or workspace.model.window_close != null) return error.WorkspaceClosed;
            if (workspace.groupTabId(self.group_id) != null or workspace.groupView(self.group_id) != null) return error.GroupIdentityConflict;
            const at = workspace.model.indexOf(self.source_tab) orelse return error.SourceChanged;
            const source = workspace.model.tabs.items[at];
            if (!source.owner.eql(self.source_owner) or source.revision != self.source_revision or source.container != self.source_container) return error.SourceChanged;
            if (workspace.model.order_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        }
        /// Called at the safe controller point after the roster transaction
        /// commits. Storage reservation survives unrelated ordinary tab opens.
        pub fn commit(self: *PreparedGroupView, roster: *group_model.Roster) !void {
            try self.validate();
            const group = roster.findById(self.group_id) orelse return error.UnknownGroup;
            const source = self.workspace.sessionTab(self.workspace.tabs.items[self.workspace.tabIndexById(self.source_tab) orelse return error.SourceChanged].id) orelse return error.SourceChanged;
            if (!group.contains(source.id)) return error.SourceChanged;
            const workspace = self.workspace;
            workspace.group_roster = roster;
            workspace.group_views.appendAssumeCapacity(self.view.?);
            workspace.model.tabs.appendAssumeCapacity(self.tab);
            workspace.model.recent.appendAssumeCapacity(self.tab.id);
            workspace.model.order_revision += 1;
            workspace.model.tabs.items[workspace.model.indexOf(self.source_tab).?].container = self.tab.id;
            workspace.model.activate(self.tab.id) catch unreachable;
            workspace.active_group_view = self.group_id;
            workspace.group_present_pending = true;
            workspace.tab_rebuild_pending = true;
            workspace.reveal_active = true;
            workspace.prepared_group_views -= 1;
            self.view = null;
            workspace.cx.requestRedraw();
        }
        pub fn deinit(self: *PreparedGroupView) void {
            if (self.view) |view| {
                view.deinit(self.workspace.allocator);
                self.workspace.allocator.destroy(view);
                self.workspace.allocator.free(self.tab.details);
                self.workspace.prepared_group_views -= 1;
                self.view = null;
            }
        }
    };

    pub fn prepareGroupView(self: *Workspace, group_id: u32, name: []const u8, initial_pane: u64) !PreparedGroupView {
        if (self.shutting_down or self.model.window_close != null) return error.WorkspaceClosed;
        if (group_id == 0 or self.groupTabId(group_id) != null or self.groupView(group_id) != null) return error.GroupIdentityConflict;
        const source = self.sessionTab(initial_pane) orelse return error.SourceChanged;
        if (source.archived or source.owned_pending or source.closing or source.content_owner != .session or source.terminal == null) return error.SourceChanged;
        const source_at = self.model.indexOf(source.tab_id) orelse return error.SourceChanged;
        const source_model = self.model.tabs.items[source_at];
        if (self.model.order_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        const view = try self.allocator.create(group_view.View);
        errdefer self.allocator.destroy(view);
        view.* = .{ .id = group_id };
        errdefer view.deinit(self.allocator);
        try view.panes.ensureUnusedCapacity(self.allocator, 1);
        const detail = try self.allocator.dupe(u8, "终端组 · 分栏与广播");
        errdefer self.allocator.free(detail);
        const label = try std.fmt.allocPrint(self.allocator, "组 · {s}", .{name});
        defer self.allocator.free(label);
        var tab: workspace_model.Tab = .{ .id = try tab_ids.allocate(), .owner = .{ .group = .{ .id = @fromBackingInt(group_id) } }, .details = detail };
        var count = @min(label.len, tab.title.len);
        while (count > 0 and !std.unicode.utf8ValidateSlice(label[0..count])) count -= 1;
        @memcpy(tab.title[0..count], label[0..count]);
        tab.title_len = @intCast(count);
        const reservations = self.prepared_group_views + 1;
        try self.group_views.ensureUnusedCapacity(self.allocator, reservations);
        try self.model.tabs.ensureUnusedCapacity(self.allocator, reservations);
        try self.model.recent.ensureUnusedCapacity(self.allocator, reservations);
        try self.terminal_area.children.ensureUnusedCapacity(self.allocator, reservations);
        self.prepared_group_views = reservations;
        return .{ .workspace = self, .group_id = group_id, .tab = tab, .view = view, .source_tab = source.tab_id, .source_owner = source.content_owner, .source_revision = source_model.revision, .source_container = source_model.container };
    }

    pub fn openGroup(self: *Workspace, roster: *group_model.Roster, id: u32) !void {
        const group = roster.findById(id) orelse return error.UnknownGroup;
        self.group_roster = roster;
        if (self.groupView(id) == null) {
            const created = try self.allocator.create(group_view.View);
            errdefer self.allocator.destroy(created);
            created.* = .{ .id = id };
            try self.group_views.ensureUnusedCapacity(self.allocator, self.prepared_group_views + 1);
            try self.model.tabs.ensureUnusedCapacity(self.allocator, self.prepared_group_views + 1);
            try self.model.recent.ensureUnusedCapacity(self.allocator, self.prepared_group_views + 1);
            const tab_id = try tab_ids.allocate();
            const title = try std.fmt.allocPrint(self.allocator, "组 · {s}", .{group.name});
            defer self.allocator.free(title);
            try self.model.append(tab_id, .{ .group = .{ .id = @fromBackingInt(id), .revision = 1 } }, title);
            self.group_views.appendAssumeCapacity(created);
            try self.model.setDetails(tab_id, "终端组 · 分栏与广播");
        }
        self.activateTabId(self.groupTabId(id).?);
    }

    pub fn refreshGroup(self: *Workspace, id: u32) void {
        for (self.model.tabs.items) |tab| self.restoreStandaloneIfUngrouped(tab.id);
        if (self.groupView(id)) |view| view.dirty = true;
        self.group_present_pending = self.active_group_view == id;
        self.rebuildTabBar() catch {};
    }

    pub fn setGroupLayout(self: *Workspace, id: u32, layout: group_view.Layout) void {
        if (self.groupClosing(id)) return;
        if (self.groupView(id)) |view| {
            view.layout = layout;
            view.dirty = true;
            self.group_present_pending = true;
            self.cx.requestRedraw();
        }
    }

    pub fn splitGroup(self: *Workspace, roster: *group_model.Roster, stacked: bool) !void {
        if (self.active_group_view) |id| if (self.groupClosing(id)) return error.GroupClosing;
        const active = self.active_tab orelse return error.NoActiveTab;
        const source = self.tabs.items[active];
        if (source.terminal == null or source.archived) return error.UnsupportedService;
        var id = self.active_group_view;
        if (id == null) {
            const name = try std.fmt.allocPrint(self.allocator, "{s} 终端组 #{d}", .{ source.titleSlice(), source.id });
            defer self.allocator.free(name);
            id = (try roster.join(name, source.id, 0xff818cf8)).id;
        }
        const group = roster.findById(id.?) orelse return error.UnknownGroup;
        const revision = group.membership_revision;
        try self.openGroup(roster, id.?);
        self.setGroupLayout(id.?, if (stacked) .stacked else .side_by_side);
        const count = self.tabs.items.len;
        try self.newSessionFromTab(active);
        if (self.tabs.items.len <= count) return error.SessionNotCreated;
        const destination = self.tabs.items[self.tabs.items.len - 1].id;
        if (!group.contains(destination)) self.pending_split = .{ .group = id.?, .session = destination, .revision = revision };
        // Startup owns its independent tab until a real terminal service exists.
        try self.openGroup(roster, id.?);
    }

    pub fn selectTabOrdinal(self: *Workspace, index: usize) void {
        if (self.model.visibleAt(index)) |at| self.activateTabId(self.model.tabs.items[at].id);
    }

    pub fn selectAdjacentTab(self: *Workspace, next: bool) void {
        const count = self.model.visibleCount();
        if (count == 0) return;
        const at = if (self.model.active) |id| self.model.visibleIndexOf(id) orelse 0 else 0;
        self.selectTabOrdinal(if (next) (at + 1) % count else (at + count - 1) % count);
    }

    pub fn requestCloseActive(self: *Workspace) void {
        if (self.active_group_view) |id| self.requestCloseGroup(id) else if (self.active_tab) |index| self.requestCloseTab(index);
    }

    fn restoreGroupRoots(self: *Workspace) void {
        for (self.tabs.items) |tab| {
            if (tab.terminal) |*terminal| {
                terminal.setHistoryHost(null) catch {};
                terminal.setGrouped(if (tab.archive_document) |document| document.record.descriptor.display.grouped else false);
            }
            if (tab.root.parent != self.terminal_area) {
                if (tab.root.parent) |parent| self.cx.detachChild(parent, tab.root);
                self.terminal_area.appendChild(self.allocator, tab.root) catch {};
                tab.root.setStyleInline(self.allocator, .{ .width = .fill(), .height = .fill(), .flex_shrink = 1, .padding = .{} });
            }
        }
        for (self.group_views.items) |view| if (view.root) |root| root.setDisplay(.none);
    }

    const GroupCell = struct {
        workspace: *Workspace,
        group: u32,
        session: u64 = 0,
        action: GroupAction = .pin,
        test_id: [96]u8 = undefined,
        layout: ?group_view.Layout = null,
        close_dialog_open: ?*ui.Signal(bool) = null,
        fn open(self: *@This()) void {
            const roster = self.workspace.group_roster orelse return;
            self.workspace.openGroup(roster, self.group) catch {};
        }
        fn close(self: *@This()) void {
            self.workspace.requestCloseGroup(self.group);
        }
        fn act(self: *@This()) void {
            if (self.layout) |layout| {
                self.workspace.setGroupLayout(self.group, layout);
                return;
            }
            if (self.workspace.group_action) |action| action(self.workspace.group_action_context, self.group, self.session, self.action);
        }
        fn cancel(self: *@This()) void {
            if (self.workspace.groupView(self.group) == null) {
                if (self.close_dialog_open) |dialog_open| dialog_open.set(false);
                return;
            }
            self.workspace.cancelGroupClose(self.group);
        }
        fn approve(self: *@This()) void {
            self.workspace.approveGroupClose(self.group);
        }
        fn drag(event_value: ui.interaction.drag.Event, raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const workspace = self.workspace;
            const view = workspace.groupView(self.group) orelse return;
            if (workspace.groupClosing(self.group)) return;
            switch (event_value.phase) {
                .start => {
                    view.drag_source = self.session;
                    view.drag_target = self.session;
                },
                .move => {
                    for (view.panes.items) |pane| {
                        const rect = pane.node.globalRect();
                        const target = event_value.position_window.x >= rect.x and event_value.position_window.x < rect.x + rect.w and event_value.position_window.y >= rect.y and event_value.position_window.y < rect.y + rect.h;
                        pane.node.setBorderWidth(0);
                        pane.node.setOpacityRaw(if (target) 0.86 else 1);
                        if (target) view.drag_target = pane.session;
                    }
                },
                .end, .cancel => {
                    if (event_value.phase == .end) for (view.panes.items) |pane| {
                        const rect = pane.node.globalRect();
                        const point = event_value.position_window;
                        if (point.x >= rect.x and point.x < rect.x + rect.w and point.y >= rect.y and point.y < rect.y + rect.h) view.drag_target = pane.session;
                    };
                    for (view.panes.items) |pane| {
                        pane.node.setBorderWidth(1);
                        pane.node.setOpacityRaw(1);
                    }
                    if (event_value.phase == .end) if (view.drag_target) |target| if (view.drag_source) |source| {
                        if (workspace.group_roster) |roster| if (roster.findById(self.group)) |group| {
                            var from: ?usize = null;
                            var to: ?usize = null;
                            for (group.members.items, 0..) |member, i| {
                                if (member.pane_id == source) from = i;
                                if (member.pane_id == target) to = i;
                            }
                            if (from != null and to != null and from.? != to.?) {
                                const member = group.members.orderedRemove(from.?);
                                group.members.insert(workspace.allocator, @min(to.?, group.members.items.len), member) catch {};
                                workspace.refreshGroup(self.group);
                            }
                        };
                    };
                    view.drag_source = null;
                    view.drag_target = null;
                },
            }
        }
        fn event(event_value: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return .ignored));
            switch (event_value) {
                .mouse_down => {
                    const index = self.workspace.tabIndex(self.session) orelse return .ignored;
                    self.workspace.active_tab = index;
                    if (self.workspace.groupView(self.group)) |view| {
                        view.focused = self.session;
                        for (view.panes.items) |pane| pane.node.setBorderColor(if (pane.session == self.session) app_theme.current().action_accent.withAlpha(112) else app_theme.current().border);
                    }
                },
                .key_down => |key| if (key.key == .escape) {
                    self.cancel();
                    return .stop;
                },
                else => {},
            }
            return .ignored;
        }
    };

    pub fn setGroupMemberBroadcast(self: *Workspace, session: u64, enabled: bool) void {
        const tab = self.sessionTab(session) orelse return;
        if (tab.group_broadcast_enabled == enabled) return;
        tab.group_broadcast_enabled = enabled;
        self.group_present_pending = true;
        self.cx.requestRedraw();
    }

    fn groupCell(self: *Workspace, scope: *ui.Scope, id: u32, session: u64, action: GroupAction) !*GroupCell {
        return scope.createState(GroupCell, .{ .workspace = self, .group = id, .session = session, .action = action });
    }

    fn groupControl(self: *Workspace, scope: *ui.Scope, parent: *ui.Node, id: u32, session: u64, action: GroupAction, icon: ui.SvgAsset, label: []const u8, test_id: []const u8) !void {
        const cell = try self.groupCell(scope, id, session, action);
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = icon, .icon_size = @as(f32, 14), .a11y_label = label, .base_style = group_styles.control(), .on_click = self.cx.on(GroupCell, cell, GroupCell.act) }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = try std.fmt.bufPrint(&cell.test_id, "{s}.{d}", .{ test_id, session });
        try parent.appendChild(self.allocator, button);
    }

    fn presentGroup(self: *Workspace, view: *group_view.View) !void {
        const roster = self.group_roster orelse return;
        const group = roster.findById(view.id) orelse return;
        self.restoreGroupRoots();
        if (view.root) |root| {
            self.cx.detachChild(self.terminal_area, root);
            self.cx.destroyDetached(root);
        }
        if (view.scope) |scope| scope.dispose();
        view.root = null;
        const scope = try self.scope.childScope();
        view.scope = scope;
        view.panes.clearRetainingCapacity();
        var root_style = group_styles.root(view.layout == .stacked);
        root_style.gap = 4;
        root_style.padding = ui.Padding.all(4);
        const root = try ui.box(self.cx, root_style, .{});
        root.meta.ownership.meta.test_id = "groups.workspace";
        view.root = root;
        for (self.tabs.items) |tab| tab.root.setDisplay(.none);
        var visible: usize = 0;
        var ordered: std.ArrayList(group_model.Member) = .empty;
        defer ordered.deinit(self.allocator);
        if (group.pinned_pane) |pinned| for (group.members.items) |member| {
            if (member.pane_id == pinned) try ordered.append(self.allocator, member);
        };
        for (group.members.items) |member| if (group.pinned_pane != member.pane_id) try ordered.append(self.allocator, member);
        for (ordered.items) |member| {
            const tab = self.sessionTab(member.pane_id) orelse continue;
            if (tab.terminal == null or tab.archived) continue;
            tab.terminal.?.setGrouped(true);
            var pane_style = group_styles.pane();
            pane_style.border = .{ .width = 1, .color = app_theme.current().border, .radius = 8 };
            pane_style.padding = ui.Padding.all(1);
            const pane = try ui.box(self.cx, pane_style, .{});
            const cell = try self.groupCell(scope, view.id, tab.id, .pin);
            pane.meta.ownership.meta.test_id = try std.fmt.bufPrint(&cell.test_id, "groups.pane.{d}", .{tab.id});
            try view.panes.append(self.allocator, .{ .session = tab.id, .node = pane });
            pane.behavior.events.capture_context = cell;
            pane.behavior.events.on_event_capture = GroupCell.event;
            var header_style = group_styles.header();
            header_style.height = .{ .px = 36 };
            header_style.margin = .{};
            header_style.padding = .{ .left = 11, .right = 11, .top = 5, .bottom = 5 };
            header_style.gap = 8;
            header_style.background = app_theme.current().surface_1;
            const header = try ui.box(self.cx, header_style, .{});
            try app_theme.bindMaterial(self.cx, scope, header, "surface_1");
            header.meta.ownership.meta.test_id = "groups.pane.header";
            var grip_style = group_styles.control();
            grip_style.width = .{ .px = 13 };
            grip_style.cursor = .grab;
            grip_style.align_items = .center;
            grip_style.justify = .center;
            grip_style.hit_behavior = .@"opaque";
            const grip = try ui.box(self.cx, grip_style, .{});
            const grip_id = try self.groupCell(scope, view.id, tab.id, .pin);
            grip.meta.ownership.meta.test_id = try std.fmt.bufPrint(&grip_id.test_id, "groups.drag.{d}", .{tab.id});
            grip.behavior.interaction.a11y = .{ .role = .button, .label = "拖动排序成员" };
            const grip_icon = try ui.iconTint(self.cx, ui.icons.grip_vertical, app_theme.current().fg_2, .{ .width = .{ .px = 13 }, .height = .{ .px = 13 } });
            grip_icon.setStyleInline(self.allocator, .{ .hit_behavior = .pass_through });
            try grip.appendChild(self.allocator, grip_icon);
            _ = try ui.interaction.drag.Binding.attach(scope, self.cx, grip, .{ .axis = .both, .activation_distance = 5 }, GroupCell.drag, cell);
            try header.appendChild(self.allocator, grip);
            const identity_text = if (tab.local) try std.fmt.allocPrint(self.allocator, "Local Terminal · #{d}", .{tab.id}) else if (tab.host_snapshot) |snapshot| try std.fmt.allocPrint(self.allocator, "{s} · {s}@{s}:{d} · #{d}", .{ tab.titleSlice(), snapshot.value.user, snapshot.value.host, snapshot.value.port, tab.id }) else try std.fmt.allocPrint(self.allocator, "{s} · #{d}", .{ tab.titleSlice(), tab.id });
            defer self.allocator.free(identity_text);
            var member_label_style = group_styles.label();
            member_label_style.font_size = 11;
            const label = try ui.text(self.cx, identity_text, member_label_style);
            label.meta.ownership.meta.test_id = "groups.pane.title";
            label.setStyleInline(self.allocator, .{ .cursor = .grab });
            _ = try ui.interaction.drag.Binding.attach(scope, self.cx, label, .{ .axis = .both, .activation_distance = 5 }, GroupCell.drag, cell);
            label.setStyleInline(self.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 1, .overflow_hidden = true });
            try header.appendChild(self.allocator, label);
            const online = !tab.failed and !tab.closing and (if (tab.local) tab.local_state == .running else if (tab.runtime) |runtime| runtime.isConnected() and tab.terminal.?.tombstone.state == .active else false);
            const status_dot = try ui.box(self.cx, .{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .background = if (online) app_theme.current().ok else app_theme.current().danger, .border = .{ .radius = 3 }, .flex_shrink = 0 }, .{});
            status_dot.meta.ownership.meta.test_id = "groups.pane.status_dot";
            try header.appendChild(self.allocator, status_dot);
            var status_style = group_styles.label();
            status_style.font_size = 11;
            const status_label = try ui.text(self.cx, if (online) "在线" else if (tab.closing) "关闭中" else "离线 / 连接中", status_style);
            status_label.meta.ownership.meta.test_id = "groups.pane.status";
            status_label.setStyleInline(self.allocator, .{ .flex_shrink = 0 });
            try header.appendChild(self.allocator, status_label);
            const broadcasting = tab.group_broadcast_enabled;
            const broadcast_cell = try self.groupCell(scope, view.id, tab.id, .toggle_broadcast);
            var broadcast_style = group_styles.control();
            broadcast_style.width = .{ .px = 24 };
            broadcast_style.height = .{ .px = 24 };
            broadcast_style.background = ui.Color.TRANSPARENT;
            const broadcast_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.radio, .icon_size = @as(f32, 14), .icon_tint = if (broadcasting) app_theme.current().accent else app_theme.current().fg_2, .disabled = !online, .a11y_label = if (!online) "广播 · 连接未就绪" else if (broadcasting) "广播 · 已开启" else "广播 · 已关闭", .base_style = broadcast_style, .on_click = self.cx.on(GroupCell, broadcast_cell, GroupCell.act) }).mount(scope, self.cx);
            broadcast_button.meta.ownership.meta.test_id = try std.fmt.bufPrint(&broadcast_cell.test_id, "groups.broadcast.{d}", .{tab.id});
            if (broadcast_button.behavior.interaction.a11y) |*a11y| a11y.pressed = broadcasting;
            try header.appendChild(self.allocator, try sidebar_view.hint(self.cx, scope, broadcast_button, if (!online) "连接未就绪" else if (broadcasting) "广播已开启" else "广播已关闭", .bottom));
            try self.groupControl(scope, header, view.id, tab.id, .pin, ui.icons.pin, if (group.pinned_pane == tab.id) "取消置顶" else "置顶成员", "groups.pin");
            var menu_items: [6]ui.widgets.MenuItem = undefined;
            const menu_actions = [_]GroupAction{ .leave, .split_side, .split_stack, .close_member };
            const menu_labels = [_][]const u8{ "移出组，保留会话", "新建左右分栏", "新建上下分栏", "断开并关闭会话" };
            for (menu_actions, menu_labels, 0..) |action, action_label, action_index| {
                const action_cell = try self.groupCell(scope, view.id, tab.id, action);
                menu_items[action_index] = .{ .label = action_label, .on_click = self.cx.on(GroupCell, action_cell, GroupCell.act) };
            }
            for ([_]group_view.Layout{ .side_by_side, .stacked }, menu_actions.len..) |layout, layout_index| {
                const layout_cell = try self.groupCell(scope, view.id, tab.id, .pin);
                layout_cell.layout = layout;
                menu_items[layout_index] = .{ .label = if (layout == .stacked) "切换上下布局" else "切换左右布局", .on_click = self.cx.on(GroupCell, layout_cell, GroupCell.act) };
            }
            const menu = try ui.widgets.Menu(.{ .items = @as([]const ui.widgets.MenuItem, &menu_items), .width = @as(f32, 220), .position = .bottom_start }).mount(scope, self.cx);
            const menu_state: *ui.widgets.MenuState = @ptrCast(@alignCast(menu.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
            if (menu_state.menu_node) |menu_node| menu_node.meta.ownership.meta.test_id = "groups.member_menu";
            const menu_trigger = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.ellipsis, .icon_size = @as(f32, 14), .a11y_label = "成员菜单", .base_style = group_styles.control() }).mount(scope, self.cx);
            const menu_cell = try self.groupCell(scope, view.id, tab.id, .pin);
            menu_trigger.meta.ownership.meta.test_id = try std.fmt.bufPrint(&menu_cell.test_id, "groups.menu.{d}", .{tab.id});
            try menu.trigger.appendChild(self.allocator, menu_trigger);
            try header.appendChild(self.allocator, menu.wrapper);
            try pane.appendChild(self.allocator, header);
            if (tab.root.parent) |parent| self.cx.detachChild(parent, tab.root);
            tab.root.setStyleInline(self.allocator, .{ .width = .fill(), .height = .fill(), .flex_shrink = 1, .padding = .{} });
            tab.root.setDisplay(.flex);
            try pane.appendChild(self.allocator, tab.root);
            try root.appendChild(self.allocator, pane);
            visible += 1;
            if (view.focused == null or self.sessionTab(view.focused.?) == null) view.focused = tab.id;
        }
        for (view.panes.items) |pane| pane.node.setBorderColor(if (pane.session == view.focused) app_theme.current().action_accent.withAlpha(112) else app_theme.current().border);
        if (visible == 1 and view.panes.items.len == 1) {
            const waiting = try ui.text(self.cx, "等待其他终端加入", group_styles.label());
            waiting.setStyleInline(self.allocator, .{ .width = .fill(), .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 12 } });
            waiting.meta.ownership.meta.test_id = "groups.waiting";
            try view.panes.items[0].node.appendChild(self.allocator, waiting);
        }
        try self.terminal_area.appendChild(self.allocator, root);
        self.empty_state.setDisplay(.none);
        if (view.focused) |id| if (self.tabIndex(id)) |index| {
            self.active_tab = index;
            if (self.confirming_id == null and (view.dialog_open == null or !view.dialog_open.?.peek())) {
                if (self.tabs.items[index].terminal) |terminal| self.cx.setFocus(terminal.root);
            }
        };
        view.dirty = false;
    }

    fn restoreStandaloneIfUngrouped(self: *Workspace, tab_id: identity.TabId) void {
        const index = self.model.indexOf(tab_id) orelse return;
        const parent = self.model.tabs.items[index].container orelse return;
        const group_id = self.groupIdByTab(parent) orelse {
            self.model.setContainer(tab_id, null) catch {};
            return;
        };
        const session_index = self.tabIndexById(tab_id) orelse return;
        const roster = self.group_roster orelse return;
        const group = roster.findById(group_id);
        if (group == null or !group.?.contains(self.tabs.items[session_index].id)) self.model.setContainer(tab_id, null) catch {};
    }
    fn creationGroupFor(self: *Workspace, source: SessionId) ?u32 {
        const roster = self.group_roster orelse return null;
        if (self.active_group_view) |id| if (roster.findById(id)) |group| if (group.contains(source) and !self.groupClosing(id)) return id;
        for (roster.groups.items) |group| if (group.contains(source) and !self.groupClosing(group.id)) return group.id;
        return null;
    }

    fn pollGroupWorkspace(self: *Workspace) bool {
        for (self.model.tabs.items) |tab| self.restoreStandaloneIfUngrouped(tab.id);
        if (self.pending_split) |pending| {
            if (self.sessionTab(pending.session)) |tab| {
                const ready = tab.terminal != null and (if (tab.local) tab.local_state == .running else tab.runtime != null and !tab.failed);
                if (ready) {
                    self.pending_split = null;
                    if (self.group_roster) |roster| if (roster.findById(pending.group)) |group| {
                        if (group.membership_revision == pending.revision) {
                            _ = roster.join(group.name, tab.id, group.color) catch return false;
                            self.refreshGroup(group.id);
                        } else self.status("组成员已变化，新会话保留为独立页签");
                    };
                } else if (tab.failed or (tab.local and tab.local_state == .failed)) {
                    self.pending_split = null;
                    self.statusFailure("新分栏启动失败，原组布局已保留");
                }
            } else self.pending_split = null;
        }
        self.pollGroupClose();
        if (self.active_group_view) |group_id| if (self.groupView(group_id)) |view| if (self.group_roster) |roster| if (roster.findById(group_id)) |group| {
            var hash = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hash, group.membership_revision);
            std.hash.autoHash(&hash, group.pinned_pane);
            for (group.members.items) |member| {
                std.hash.autoHash(&hash, member.pane_id);
                if (self.sessionTab(member.pane_id)) |tab| {
                    std.hash.autoHash(&hash, tab.generation);
                    std.hash.autoHash(&hash, tab.failed);
                    std.hash.autoHash(&hash, tab.closing);
                    std.hash.autoHash(&hash, tab.local_state);
                    std.hash.autoHash(&hash, tab.group_broadcast_enabled);
                    if (tab.terminal) |terminal| std.hash.autoHash(&hash, terminal.tombstone.state);
                    std.hash.autoHash(&hash, if (tab.runtime) |runtime| runtime.isConnected() else false);
                }
            }
            const next = hash.final();
            if (view.state_hash != next) {
                view.state_hash = next;
                self.group_present_pending = true;
            }
        };
        if (!self.group_present_pending) return false;
        self.group_present_pending = false;
        if (self.active_group_view) |id| if (self.groupView(id)) |view| {
            self.presentGroup(view) catch |err| self.statusFailure(@errorName(err));
            return true;
        };
        return false;
    }
    fn groupRisk(self: *Workspace, id: SessionId) u8 {
        const risk = if (self.close_bridge.risk) |callback| callback(self.close_bridge.context, id) else CloseRisk{};
        return @as(u8, @intFromBool(risk.transfer)) | (@as(u8, @intFromBool(risk.ai_write)) << 1) | (@as(u8, @intFromBool(risk.socks)) << 2) | (@as(u8, @intFromBool(risk.local_process)) << 3) | (@as(u8, @intFromBool(risk.local_unknown)) << 4);
    }

    pub fn groupClosing(self: *Workspace, id: u32) bool {
        const view = self.groupView(id) orelse return false;
        return if (view.close) |plan| plan.phase == .closing else false;
    }

    fn groupImpact(self: *Workspace, id: SessionId) group_close.Impact {
        if (self.close_bridge.impact) |callback| return callback(self.close_bridge.context, id);
        const risk = self.groupRisk(id);
        return .{ .command = @intFromBool(risk & 8 != 0), .transfer = @intFromBool(risk & 1 != 0), .ai = @intFromBool(risk & 2 != 0), .socks = @intFromBool(risk & 4 != 0), .unknown = @intFromBool(risk & 16 != 0) };
    }

    fn captureGroupCloseMember(self: *Workspace, id: SessionId) ?group_close.Member {
        const tab = self.sessionTab(id) orelse return null;
        var member: group_close.Member = .{ .id = tab.id, .generation = tab.generation, .risk = self.groupRisk(id), .impact = self.groupImpact(id), .handle = if (tab.content_owner == .session) tab.content_owner.session else null };
        member.remote_effect_unknown = member.impact.remote_effect_unknown;
        var buffer: [512]u8 = undefined;
        const display = if (tab.local)
            std.fmt.bufPrint(&buffer, "{s} · 本机 zsh", .{tab.titleSlice()}) catch tab.titleSlice()
        else if (tab.host_snapshot) |snapshot|
            std.fmt.bufPrint(&buffer, "{s} · {s}@{s}:{d} · SSH", .{ tab.titleSlice(), snapshot.value.user, snapshot.value.host, snapshot.value.port }) catch tab.titleSlice()
        else
            std.fmt.bufPrint(&buffer, "{s} · SSH", .{tab.titleSlice()}) catch tab.titleSlice();
        member.setLabel(display);
        return member;
    }

    /// Local release and remote business consequences are separate receipts.
    /// The AI/tool owner must first retain its bounded remote-effect check.
    pub fn receiveGroupRemoteEffectUnknown(self: *Workspace, handle: identity.SessionHandle) void {
        for (self.group_views.items) |view| if (view.close) |*plan| {
            for (plan.members.items) |*member| if (member.handle != null and member.handle.?.eql(handle)) {
                member.remote_effect_unknown = true;
                self.cx.requestRedraw();
            };
        };
    }

    pub fn requestCloseGroup(self: *Workspace, id: u32) void {
        const roster = self.group_roster orelse return;
        const group = roster.findById(id) orelse return;
        const view = self.groupView(id) orelse return;
        if (self.groupClosing(id)) return;
        // Never replace the ledger of an unfinished original cleanup request.
        if (view.close) |*plan| {
            if (plan.phase == .partial) {
                self.showGroupCloseDialog(view, true) catch {};
                return;
            }
            for (plan.members.items) |member| if (member.state == .cleanup_unknown or member.state == .closing or member.state == .await_confirm) {
                self.showGroupCloseDialog(view, true) catch {};
                return;
            };
            plan.deinit(self.allocator);
        }
        view.close = .{ .revision = group.membership_revision };
        for (group.members.items) |member| if (self.captureGroupCloseMember(member.pane_id)) |captured| {
            view.close.?.append(self.allocator, captured) catch return;
        };
        self.showGroupCloseDialog(view, false) catch |err| self.statusFailure(@errorName(err));
    }

    fn cancelGroupClose(self: *Workspace, id: u32) void {
        const view = self.groupView(id) orelse return;
        if (view.dialog_open) |open| open.set(false);
        if (view.close) |*plan| {
            if (plan.phase == .closing) {
                plan.stop();
                self.showGroupCloseDialog(view, true) catch {};
            } else if (plan.phase == .confirming) {
                if (plan.retry) {
                    plan.stop();
                } else {
                    plan.deinit(self.allocator);
                    view.close = null;
                }
            }
        }
        self.abortCloseBatch();
        self.restoreFocusToActiveTab();
    }

    fn approveGroupClose(self: *Workspace, id: u32) void {
        const roster = self.group_roster orelse return;
        const group = roster.findById(id) orelse return;
        const view = self.groupView(id) orelse return;
        const plan = if (view.close) |*p| p else return;
        if (plan.phase == .partial) {
            plan.prepareRetry(group.membership_revision) catch |err| {
                self.statusFailure(@errorName(err));
                return;
            };
            // Reprepare only original failed/cancelled handles. A replacement
            // generation is not covered, and newly joined members never enter.
            for (plan.members.items) |*member| if (member.eligible) {
                const fresh = self.captureGroupCloseMember(member.id) orelse {
                    member.state = .closed;
                    member.eligible = false;
                    continue;
                };
                if (fresh.generation != member.generation or !std.meta.eql(fresh.handle, member.handle)) {
                    member.state = .failed;
                    member.eligible = false;
                } else {
                    member.impact = fresh.impact;
                    member.risk = fresh.risk;
                }
            };
            self.showGroupCloseDialog(view, false) catch {};
            return;
        }
        if (plan.phase != .confirming) return;
        var valid = plan.revision == group.membership_revision;
        for (plan.members.items) |*member| if (member.eligible and member.state == .queued) {
            const fresh = self.captureGroupCloseMember(member.id) orelse {
                valid = false;
                continue;
            };
            if (fresh.generation != member.generation or !std.meta.eql(fresh.handle, member.handle) or !fresh.impact.eql(member.impact) or fresh.risk != member.risk) valid = false;
        };
        if (!valid) {
            if (plan.retry) {
                plan.revision = group.membership_revision;
                for (plan.members.items) |*member| if (member.eligible) {
                    if (self.captureGroupCloseMember(member.id)) |fresh| {
                        if (fresh.generation == member.generation and std.meta.eql(fresh.handle, member.handle)) {
                            member.impact = fresh.impact;
                            member.risk = fresh.risk;
                        } else {
                            member.state = .failed;
                            member.eligible = false;
                        }
                    } else {
                        member.state = .closed;
                        member.eligible = false;
                    }
                };
                self.showGroupCloseDialog(view, false) catch {};
            } else self.requestCloseGroup(id);
            self.status("组成员或影响已变化，请重新确认");
            return;
        }
        plan.phase = .closing;
        if (!plan.group_hook_started) {
            plan.group_hook_started = true;
            if (self.group_action) |action| {
                action(self.group_action_context, id, 0, .stop_broadcast);
                action(self.group_action_context, id, 0, .stop_group_ai);
            }
        }
        // Individual owners continue through the existing V0.1.1 coordinator.
        self.showGroupCloseDialog(view, true) catch {};
        self.cx.requestRedraw();
    }

    fn showGroupCloseDialog(self: *Workspace, view: *group_view.View, partial: bool) !void {
        if (view.dialog_open) |open| open.set(false);
        const scope = try self.scope.childScope();
        const open = try scope.createSignal(bool, false);
        view.dialog_open = open;
        const modal = try ui.widgets.Modal(.{ .open = open, .width = 480, .max_height = @as(f32, if (partial) 248 else 294), .background = app_theme.current().overlay }).mount(scope, self.cx);
        if (!modal.portaled) try self.terminal_area.appendChild(self.allocator, modal.overlay);
        view.dialog = modal.overlay;
        view.dialog_scope = scope;
        modal.dialog.meta.ownership.meta.test_id = if (partial) "groups.close.partial" else "groups.close.confirm";
        const cell = try self.groupCell(scope, view.id, 0, .pin);
        cell.close_dialog_open = open;
        modal.dialog.behavior.events.capture_context = cell;
        modal.dialog.behavior.events.on_event_capture = GroupCell.event;
        const plan = if (view.close) |*p| p else return;
        const roster = self.group_roster orelse return;
        const group = roster.findById(view.id) orelse return;
        const cancel = try group_close_view.render(self.cx, scope, modal.dialog, modal.body, .{ .group_name = group.name, .plan = plan, .partial = partial, .cancel = self.cx.on(GroupCell, cell, GroupCell.cancel), .approve = self.cx.on(GroupCell, cell, GroupCell.approve) });
        open.set(true);
        self.cx.setFocus(cancel);
    }

    fn pollGroupClose(self: *Workspace) void {
        var retired: ?*group_view.View = null;
        for (self.group_views.items) |view| {
            const plan = if (view.close) |*p| p else continue;
            if (plan.phase != .closing and !(plan.phase == .partial and plan.awaiting != null)) continue;
            if (plan.awaiting) |id| {
                if (self.sessionTab(id)) |tab| {
                    const reported = if (self.close_bridge.close_state) |callback| callback(self.close_bridge.context, id) else null;
                    if (reported == .cleanup_unknown) {
                        const changed = plan.record(id, .cleanup_unknown);
                        plan.phase = .partial;
                        if (changed) self.showGroupCloseDialog(view, true) catch {};
                        self.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
                        continue;
                    }
                    if (tab.closing or self.confirming_id == tab.tab_id) {
                        _ = plan.record(id, if (self.confirming_id == tab.tab_id) .await_confirm else .closing);
                        self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
                        continue;
                    }
                    _ = plan.record(id, if (reported == .failed) .failed else .cancelled);
                    plan.awaiting = null;
                    plan.stop();
                    self.showGroupCloseDialog(view, true) catch {};
                    continue;
                }
                _ = plan.record(id, .closed);
                plan.awaiting = null;
                view.dirty = true;
                if (self.group_roster) |roster| _ = roster.leavePane(id);
                self.group_present_pending = self.active_group_view == view.id;
                if (plan.phase == .partial) {
                    if (plan.counts().closed != plan.members.items.len) {
                        self.showGroupCloseDialog(view, true) catch {};
                        continue;
                    }
                    // The last original cleanup may converge after Stop.
                    // All local receipts are now real; perform normal retirement.
                    plan.phase = .closing;
                }
            }
            if (plan.phase != .closing) continue;
            const member = plan.next() orelse {
                if (plan.counts().closed == plan.members.items.len) {
                    plan.phase = .complete;
                    if (plan.counts().unknown != 0) {
                        self.showGroupCloseDialog(view, true) catch {};
                    } else if (view.dialog_open) |open| open.set(false);
                    if (self.active_group_view == view.id) {
                        self.restoreGroupRoots();
                        self.active_group_view = null;
                    }
                    retired = view;
                    break;
                }
                plan.phase = .partial;
                self.showGroupCloseDialog(view, true) catch {};
                continue;
            };
            if (self.tabIndex(member.id)) |index| {
                const fresh = self.captureGroupCloseMember(member.id).?;
                if (fresh.generation != member.generation or !std.meta.eql(fresh.handle, member.handle)) {
                    _ = plan.record(member.id, .failed);
                    plan.stop();
                    self.showGroupCloseDialog(view, true) catch {};
                    continue;
                }
                plan.awaiting = member.id;
                if (!fresh.impact.eql(member.impact) or fresh.risk != member.risk) {
                    _ = plan.record(member.id, .await_confirm);
                    self.requestCloseTab(index);
                } else {
                    _ = plan.record(member.id, .closing);
                    self.forceCloseTab(index);
                    if (self.sessionTab(member.id)) |remaining| {
                        if (!remaining.closing and self.confirming_id != remaining.tab_id) {
                            _ = plan.record(member.id, .failed);
                            plan.awaiting = null;
                            plan.stop();
                            self.showGroupCloseDialog(view, true) catch {};
                        }
                    }
                }
            } else _ = plan.record(member.id, .closed);
            self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        }
        if (retired) |view| {
            if (self.groupTabId(view.id)) |id| {
                const at = self.model.indexOf(id).?;
                self.model.completeClose(id, self.model.tabs.items[at].owner) catch {};
            }
            self.restoreGroupRoots();
            if (view.root) |root| {
                self.cx.detachChild(self.terminal_area, root);
                self.cx.destroyDetached(root);
            }
            if (view.scope) |scope| scope.dispose();
            for (self.group_views.items, 0..) |candidate, index| if (candidate == view) {
                _ = self.group_views.orderedRemove(index);
                break;
            };
            view.deinit(self.allocator);
            self.allocator.destroy(view);
            if (self.model.active) |id| self.presentTabId(id);
            self.rebuildTabBar() catch {};
        }
    }

    pub fn selectTab(self: *Workspace, index: usize) void {
        if (self.tabs.items.len == 0) return;
        if (index >= self.tabs.items.len) return;
        if (self.tabs.items[index].owned_pending) return;
        const tab_id = self.tabs.items[index].tab_id;
        self.restoreStandaloneIfUngrouped(tab_id);
        self.model.activate(tab_id) catch return;
        if (self.model.active != tab_id) {
            self.presentTabId(self.model.active orelse return);
            return;
        }
        self.presentActiveTab(index);
    }
    fn presentActiveTab(self: *Workspace, index: usize) void {
        if (self.rename_request) |request| {
            if (request.tab != self.tabs.items[index].tab_id) _ = self.cancelRenameTab();
        }
        self.reveal_active = true;
        applog.debug(.ui, "selectTab index={d}", .{index});
        self.active_tab = index;
        self.restoreGroupRoots();
        self.active_group_view = null;
        for (self.tabs.items, 0..) |tab, i| {
            tab.root.setDisplay(if (i == index) .flex else .none);
            if (tab.plugin_renderer) |renderer| renderer.vtable.focus_changed(renderer.context, i == index);
        }
        self.empty_state.setDisplay(.none);
        // The status-bar grid label mirrors the ACTIVE tab only: other tabs'
        // frame hooks keep running, so they must not write the shared node.
        for (self.tabs.items) |tab| if (tab.terminal) |*terminal| {
            terminal.grid_status_node = null;
        };
        const terminal = if (self.tabs.items[index].terminal) |*value| value else null;
        if (terminal) |value| {
            value.setHistoryHost(self.history_card_host) catch {};
            value.grid_status_node = self.grid_node;
            value.grid_label_shown = false;
        } // force one rewrite from the new tab
        self.rebuildTabBar() catch return;
        // The terminal pane is the tab's primary input surface: route
        // keystrokes there immediately instead of waiting for a click.
        self.cx.setFocus(if (self.tabs.items[index].terminal) |*value| value.root else self.tabs.items[index].root);
    }

    /// Entry point for every tab-close request. A live session (runtime
    /// attached) must first pass the close-confirmation card
    /// (docs/SPEC/mockups/mockup-close-confirm.png): the ✕ button and any
    /// future close paths route here. Failed or never-connected tabs close
    /// immediately — exactly the old behavior.
    pub fn requestCloseTab(self: *Workspace, index: usize) void {
        if (index >= self.tabs.items.len) return;
        if (self.tabs.items[index].closing) return;
        const risk = if (self.close_bridge.risk) |callback| callback(self.close_bridge.context, self.tabs.items[index].id) else CloseRisk{};
        if (risk.any()) {
            self.confirmClose(index);
            return;
        }
        self.forceCloseTab(index);
    }

    fn confirmClose(self: *Workspace, index: usize) void {
        const tab = self.tabs.items[index];
        if (tab.local) if (self.close_bridge.confirm) |confirm| {
            self.confirming_tab = index;
            self.confirming_id = tab.tab_id;
            confirm(self.close_bridge.context, tab.id);
            return;
        };
        self.showCloseConfirm(index);
    }

    pub fn resolveLocalCloseConfirmation(self: *Workspace, id: SessionId, confirm: bool) void {
        const tab = self.sessionTab(id) orelse return;
        if (!tab.local or self.confirming_id != tab.tab_id) return;
        if (confirm) self.onConfirmForceClose() else self.onCancelConfirm();
    }

    pub fn requestCloseOthers(self: *Workspace, keep: usize) void {
        if (keep >= self.tabs.items.len or self.model.window_close != null) return;
        const kept = self.tabs.items[keep];
        var excluded: std.ArrayList(identity.GroupId) = .empty;
        defer excluded.deinit(self.allocator);
        if (self.group_roster) |roster| for (roster.groups.items) |group| {
            if (group.contains(kept.id)) excluded.append(self.allocator, @fromBackingInt(group.id)) catch return;
        };
        const targets = self.model.freezeCloseTargets(kept.tab_id, excluded.items) catch return;
        defer self.allocator.free(targets);
        self.close_targets.clearRetainingCapacity();
        // The mandatory group decision precedes every member's standalone
        // presentation. Released session targets then fall out by stable ID.
        for (targets) |target| if (target.owner == .group) self.close_targets.append(self.allocator, target) catch return;
        for (targets) |target| if (target.owner != .group) self.close_targets.append(self.allocator, target) catch return;
        self.close_cursor = 0;
        self.close_others_keep = self.tabs.items[keep].id;
        self.continueCloseOthers();
    }

    fn continueCloseOthers(self: *Workspace) void {
        if (self.close_others_keep == null and self.window_close_request == null) return;
        if (self.window_close_reconcile) {
            self.window_close_reconcile = false;
            self.hideCloseConfirm();
        }
        while (self.close_cursor < self.close_targets.items.len) {
            const target = self.close_targets.items[self.close_cursor];
            if (!self.model.isCurrentTarget(target)) {
                self.close_cursor += 1;
                continue;
            }
            if (target.owner == .group) {
                const group_id: u32 = @intCast(@backingInt(target.owner.group.id));
                const view = self.groupView(group_id) orelse {
                    self.close_cursor += 1;
                    continue;
                };
                if (view.close) |plan| {
                    if (plan.phase == .partial) self.abortCloseBatch();
                } else self.requestCloseGroup(group_id);
                return;
            }
            const index = self.tabIndexById(target.tab) orelse return;
            if (self.tabs.items[index].closing) return;
            const risk = if (self.close_bridge.risk) |callback| callback(self.close_bridge.context, self.tabs.items[index].id) else CloseRisk{};
            if (risk.any()) {
                self.confirmClose(index);
                return;
            }
            self.forceCloseTab(index);
            if (self.tabIndexById(target.tab) != null) return;
            self.close_cursor += 1;
        }
        self.close_others_keep = null;
    }

    /// One queue owns the frozen targets for both close-others and window
    /// close. A cursor preserves the original slice for host receipt checks.
    pub fn beginWindowCloseBatch(self: *Workspace, ticket: @import("../host/window_host.zig").Close) ![]const workspace_model.CloseTarget {
        try self.startPollLoop();
        const targets = try self.model.beginWindowClose(ticket);
        self.close_targets.deinit(self.allocator);
        self.close_targets = .empty;
        defer self.allocator.free(targets);
        for (targets) |target| if (target.owner == .group) try self.close_targets.append(self.allocator, target);
        for (targets) |target| if (target.owner != .group) try self.close_targets.append(self.allocator, target);

        self.close_cursor = 0;
        self.close_others_keep = null;
        self.window_close_request = ticket.request;
        self.window_close_reconcile = true;
        self.cx.requestRedraw();
        self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        return self.close_targets.items;
    }

    /// The application owns ticket/model cancellation and operation receipts.
    /// Clearing this queue never cancels a different or newer window request.
    pub fn endWindowCloseBatch(self: *Workspace, request: u64) bool {
        if (self.window_close_request != request) return false;
        self.window_close_request = null;
        self.window_close_reconcile = false;
        self.close_cursor = 0;
        self.close_targets.clearRetainingCapacity();
        self.close_others_keep = null;
        return true;
    }

    fn abortCloseBatch(self: *Workspace) void {
        const request = self.window_close_request;
        self.close_targets.clearRetainingCapacity();
        self.close_cursor = 0;
        self.close_others_keep = null;
        self.window_close_request = null;
        self.window_close_reconcile = false;
        if (request) |id| if (self.window_close_bridge.cancelled) |cancelled| cancelled(self.window_close_bridge.context, id);
    }

    /// Compatibility alias: keeps the historic public name working while
    /// routing through the confirm-first flow above.
    pub fn closeTab(self: *Workspace, index: usize) void {
        self.requestCloseTab(index);
    }

    /// Unconditional tab teardown — the former closeTab body. Only
    /// requestCloseTab (dead tabs) and the confirmation card (user accepted
    /// the risk rows) may call this.
    pub fn forceCloseTab(self: *Workspace, index: usize) void {
        if (index >= self.tabs.items.len) return;
        const tab = self.tabs.items[index];
        if (tab.closing) return;
        if (self.close_bridge.request_close) |request| {
            tab.closing = true;
            switch (request(self.close_bridge.context, tab.tab_id, tab.content_owner)) {
                .released => self.receiveCloseReceipt(tab.tab_id, tab.content_owner, true),
                .awaiting => {},
                .unknown => self.status("会话仍在关闭，请稍候"),
                .rejected => {
                    tab.closing = false;
                    self.abortCloseBatch();
                    self.statusFailure("关闭失败：会话状态已变化，请重试；连接资源尚未确认释放。");
                },
            }
            return;
        }
        self.removeClosedTab(index);
    }

    /// Resource owners call this from their controller thread. Actual node
    /// removal is deferred until the after-layout hook, outside event dispatch.
    pub fn receiveCloseReceipt(self: *Workspace, id: identity.TabId, owner: identity.ContentOwner, released: bool) void {
        const index = self.tabIndexById(id) orelse return;
        if (!self.tabs.items[index].content_owner.eql(owner)) return;
        if (!released) {
            self.status("会话仍在关闭，请稍候");
            return;
        }
        for (self.close_receipts.items) |pending| if (pending.tab == id and pending.owner.eql(owner)) return;
        self.close_receipts.append(self.allocator, .{ .tab = id, .owner = owner }) catch return;
        self.cx.requestRedraw();
    }

    fn removeClosedTab(self: *Workspace, requested_index: usize) void {
        if (requested_index >= self.tabs.items.len) return;
        const requested_id = self.tabs.items[requested_index].tab_id;
        if (self.close_bridge.cleanup) |callback| callback(self.close_bridge.context, self.tabs.items[requested_index].id);
        const index = self.tabIndexById(requested_id) orelse return;
        if (self.confirming_id) |pending| {
            if (pending == requested_id) self.hideCloseConfirm() else self.confirming_tab = self.tabIndexById(pending);
        }
        applog.info(.workspace, "forceCloseTab index={d}", .{index});
        const tab = self.tabs.items[index];
        if (!tab.owned_pending) self.model.completeClose(tab.tab_id, tab.content_owner) catch return;
        if (tab.owned_origin) {
            if (self.group_roster) |roster| _ = roster.leavePane(tab.id);
        }
        if (self.rename_session == tab.id) _ = self.cancelRenameTab();
        for (self.connect_jobs.items) |job| {
            if (job.ticket.matches(tab.ticket())) {
                job.cancelled.store(true, .release);
                job.host_key_bridge.cancel();
                job.auth_bridge.cancel();
                if (self.host_key_job == job) self.hideHostKeyConfirm();
            }
        }
        // Stop the per-frame hook first (same UI thread → no interleaving):
        // after this point nothing may touch the tab's worker or terminal
        // nodes. The hook used to keep running until app exit, and its next
        // frame after runtime cleanup read a destroyed TextSlot / detached
        // node tree (assertOwnedByActiveWorld SIGSEGV).
        if (tab.terminal) |*terminal| {
            terminal.removeFrameHook(self.cx);
            if (tab.runtime != null) terminal.releaseCommandDocument();
        }
        if (tab.root.parent) |parent| self.cx.detachChild(parent, tab.root);
        // Member teardown only (idempotent): the runtime struct stays alive
        // until its scope cleanup entry destroys it at app dispose —
        // destroying here would double-free on the quit path.
        if (tab.runtime) |runtime| _ = runtime.releaseStep(.{ .session_id = tab.id, .retention_days = self.app_config.log.retention_days });
        // Remove the pane from all runtime broadcast groups before freeing
        // its tab identity, so later input cannot target a closed session.
        if (self.input_bridge) |bridge| _ = bridge;
        if (tab.terminal) |*terminal| {
            terminal.clearPendingPaste();
            terminal.releaseBuffers(self.cx);
        }
        // Search and other terminal child scopes are released by releaseBuffers;
        // dispose their Local parent only after those owned pointers are cleared.
        if (tab.local_scope) |scope| scope.dispose();
        tab.local_scope = null;
        if (tab.remote_notice_scope) |scope| scope.dispose();
        tab.remote_notice_scope = null;
        tab.remote_notice = null;
        if (tab.plugin_renderer) |renderer| renderer.vtable.unmount(renderer.context);
        tab.plugin_renderer = null;
        tab.transfer_trays = .{ null, null };
        if (tab.file_scope) |scope| scope.dispose();
        tab.file_scope = null;
        self.cx.destroyDetached(tab.root);
        if (tab.plugin_protocol_id.len != 0) self.allocator.free(tab.plugin_protocol_id);
        if (tab.host_snapshot) |*snapshot| snapshot.deinit();
        if (tab.archive_document) |document| document.destroy();
        self.allocator.destroy(tab);
        _ = self.tabs.orderedRemove(index);
        if (self.tabs.items.len == 0) {
            self.active_tab = null;
            self.status("未连接");
            self.empty_state.setDisplay(.flex);
            // No live session: reset the grid-size label to a placeholder.
            if (self.grid_node) |grid| {
                grid.setTextContent(self.allocator, "—") catch {};
                grid.markRenderDirty();
            }
        } else self.active_tab = if (self.model.active) |id| self.tabIndexById(id) else null;
        if (self.picker_view) |view| if (view.open.peek()) {
            self.picker.update(self.allocator, &self.model, self.picker.query.items) catch {};
            view.dirty = true;
        };
        self.rebuildTabBar() catch return;
        // 会话关闭 → 主机可能回到离线，状态点重算。
        self.rebuildSidebar() catch {};
        if (self.active_group_view) |group| {
            if (self.groupView(group)) |view| view.dirty = true;
            self.group_present_pending = true;
        } else if (self.model.active) |id| self.presentTabId(id);
    }

    fn mountHostKeyConfirm(self: *Workspace) !void {
        if (self.host_key_root != null) return;
        const cx = self.cx;
        const p = self.palette;
        const scrim = try ui.box(cx, .{
            .position = .absolute,
            .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
            .width = .fill(),
            .height = .fill(),
            .z_index = 350,
            .align_items = .center,
            .justify = .center,
            .background = ui.Color.rgba(236, 255, 244, 128),
        }, .{});
        const card = try ui.box(cx, .{
            .width = .{ .px = 430 },
            .direction = .column,
            .gap = 10,
            .background = app_theme.current().overlay,
            .glass = app_theme.overlayGlass(),
            .padding = .{ .top = 22, .bottom = 22, .left = 26, .right = 26 },
            .border = .{ .width = 0, .color = ui.Color.rgba(19, 69, 246, 26), .radius = 12 },
            .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(15, 23, 42, 36) },
        }, .{});
        try card.appendChild(cx.allocator, try ui.text(cx, "主机密钥首连确认", .{ .font_size = 14, .font_weight = 600, .color = p.fg }));
        const detail = try ui.text(cx, "", .{ .font_size = 11, .color = p.fg_secondary, .wrap = .word });
        try card.appendChild(cx.allocator, detail);
        const buttons = try ui.box(cx, .{ .direction = .row, .justify = .center, .gap = 10 }, .{});
        try buttons.appendChild(cx.allocator, try ui.widgets.Button(.{
            .label = "拒绝",
            .variant = .secondary,
            .on_click = cx.on(Workspace, self, rejectHostKey),
        }).mount(self.scope, cx));
        const changed_button = try ui.widgets.Button(.{
            .label = "输入 yes 并继续",
            .variant = .secondary,
            .on_click = cx.on(Workspace, self, trustChangedHostKey),
        }).mount(self.scope, cx);
        changed_button.setDisplay(.none);
        try buttons.appendChild(cx.allocator, changed_button);
        try buttons.appendChild(cx.allocator, try ui.widgets.Button(.{
            .label = "仅本次",
            .variant = .secondary,
            .on_click = cx.on(Workspace, self, trustHostKeyOnce),
        }).mount(self.scope, cx));
        // Persist this fingerprint in the configured known_hosts store. This
        // remains an explicit first-use choice; subsequent connections with
        // the same host/port/key skip the modal, while a changed key still
        // requires the separate literal-yes flow.
        const remember_button = try ui.widgets.Button(.{
            .label = "记住此主机",
            .variant = .primary,
            .on_click = cx.on(Workspace, self, trustHostKeySave),
        }).mount(self.scope, cx);
        try buttons.appendChild(cx.allocator, remember_button);
        try card.appendChild(cx.allocator, buttons);
        card.behavior.interaction.focusable = true;
        card.behavior.events.on_key_down = struct {
            fn onKey(key: ui.events.KeyCode, _: ui.events.Modifiers, ctx: ?*anyopaque) ui.events.EventResult {
                if (key != .escape) return .ignored;
                const workspace: *Workspace = @ptrCast(@alignCast(ctx orelse return .ignored));
                workspace.rejectHostKey();
                return .handled;
            }
        }.onKey;
        card.behavior.events.key_context = @ptrCast(self);
        try scrim.appendChild(cx.allocator, card);
        scrim.setDisplay(.none);
        try self.terminal_area.appendChild(cx.allocator, scrim);
        self.host_key_root = scrim;
        self.host_key_card = card;
        try app_theme.bindMaterial(cx, self.scope, card, "overlay");
        self.host_key_detail = detail;
        self.host_key_changed_button = changed_button;
    }

    fn hideHostKeyConfirm(self: *Workspace) void {
        if (self.host_key_root) |root| root.setDisplay(.none);
        self.host_key_job = null;
        if (self.active_tab) |index| if (index < self.tabs.items.len) self.cx.setFocus(if (self.tabs.items[index].terminal) |*value| value.root else self.tabs.items[index].root);
    }

    fn rejectHostKey(self: *Workspace) void {
        if (self.host_key_job) |job| job.host_key_bridge.cancel();
        self.hideHostKeyConfirm();
    }

    fn trustHostKeyOnce(self: *Workspace) void {
        self.replyHostKey(.trust_once);
        self.hideHostKeyConfirm();
    }

    fn trustHostKeySave(self: *Workspace) void {
        self.replyHostKey(.trust_save);
        self.hideHostKeyConfirm();
    }

    fn trustChangedHostKey(self: *Workspace) void {
        self.replyHostKey(.{ .replace_host_key = "yes" });
        self.hideHostKeyConfirm();
    }

    pub const ConnectionProgress = struct {
        pub const Hop = struct { name: []const u8, host: []const u8, user: []const u8, port: u16 };
        pub const LogRecord = struct { key: OperationKey, entry: @import("../proto/ssh/connection_progress.zig").Journal.Entry };
        key: OperationKey,
        hops: [9]Hop = undefined,
        hop_count: usize,
        journal: @import("../proto/ssh/connection_progress.zig").Journal.Snapshot,
        resources: ResourceLedger.Snapshot,
        finished: bool,
        attached: bool,
        attachment_failed: bool,
        cancelled: bool,
        failure: ?anyerror,
        cleanup: @import("../host/operation.zig").Cleanup,
        automatic_retry_pending: bool = false,
        logs: [128]LogRecord = undefined,
        log_count: usize = 0,
        dropped: usize = 0,

        fn appendJournal(self: *ConnectionProgress, key: OperationKey, journal: @import("../proto/ssh/connection_progress.zig").Journal.Snapshot) void {
            self.dropped +|= journal.dropped;
            for (journal.entries[0..journal.count]) |entry| {
                if (self.log_count == self.logs.len) {
                    std.mem.copyForwards(LogRecord, self.logs[0 .. self.logs.len - 1], self.logs[1..]);
                    self.log_count -= 1;
                    self.dropped +|= 1;
                }
                self.logs[self.log_count] = .{ .key = key, .entry = entry };
                self.log_count += 1;
            }
        }
    };

    pub fn nextConnectionPresentationKey(self: *Workspace) ?OperationKey {
        for (self.connect_jobs.items) |job| {
            if (job.progress_dismissed) continue;
            const key = job.operation_key orelse continue;
            const tab = self.findTicket(job.ticket) orelse continue;
            if (job.ready.load(.acquire) and !tab.failed) if (tab.runtime) |runtime| {
                if (runtime.isAttached()) continue;
            };
            return key;
        }
        return null;
    }

    pub fn dismissConnectionProgress(self: *Workspace, key: OperationKey) !void {
        const progress = self.connectionProgress(key) orelse return error.StaleConnection;
        if (!progress.finished or progress.cleanup != .released) return error.CleanupNotReleased;
        for (self.connect_jobs.items) |job| {
            if (job.operation_key != null and job.operation_key.?.eql(key)) {
                job.progress_dismissed = true;
                return;
            }
        }
        return error.StaleConnection;
    }

    /// Endpoint slices borrow the frozen job only for this UI call. Consumers
    /// must copy them before retaining; no credentials enter this projection.
    pub fn connectionProgress(self: *Workspace, key: OperationKey) ?ConnectionProgress {
        for (self.connect_jobs.items) |job| {
            if (job.operation_key == null or !job.operation_key.?.eql(key)) continue;
            const tab = self.findTicket(job.ticket) orelse return null;
            const finished = job.ready.load(.acquire);
            const resources = job.resource_ledger.snapshot();
            const cancelled = job.cancelled.load(.acquire);
            var result: ConnectionProgress = .{
                .key = key,
                .hop_count = job.jump_snapshot.value.len + 1,
                .journal = job.progress.snapshot(),
                .resources = resources,
                .finished = finished,
                .attached = false,
                .attachment_failed = finished and tab.failed and job.automatic_retry_deadline_ns == null,
                .cancelled = cancelled,
                .failure = if (finished and job.automatic_retry_deadline_ns == null) job.err else null,
                .automatic_retry_pending = job.automatic_retry_deadline_ns != null,
                .cleanup = if (resources.hasUnknown() or job.cleanup_unknown) .unknown else if (finished and resources.released()) .released else if (cancelled) .releasing else .not_started,
            };
            if (result.hop_count > result.hops.len) return null;
            result.dropped = job.progress_history_dropped;
            for (job.progress_history.items) |previous| result.appendJournal(previous.key, previous.journal);
            result.appendJournal(key, result.journal);
            for (0..result.hop_count) |hop| {
                const host = authenticationHost(job, hop) orelse return null;
                result.hops[hop] = .{ .name = host.name, .host = host.host, .user = host.user, .port = host.port };
            }
            if (finished and !cancelled and !tab.failed) if (tab.runtime) |runtime| {
                result.attached = runtime.isAttached();
            };
            return result;
        }
        return null;
    }

    pub fn initialConnectionRetryDeadline(self: *Workspace, key: OperationKey) ?i128 {
        if (self.shutting_down) return null;
        for (self.connect_jobs.items) |job| {
            if (job.operation_key == null or !job.operation_key.?.eql(key) or job.cancelled.load(.acquire)) continue;
            const tab = self.findTicket(job.ticket) orelse return null;
            if (tab.closing or !job.drained or !job.resource_ledger.snapshot().released()) return null;
            return job.automatic_retry_deadline_ns;
        }
        return null;
    }

    fn replyHostKey(self: *Workspace, reply: auth_challenge.Reply) void {
        const job = self.host_key_job orelse return;
        const request = job.host_key_bridge.snapshot() orelse return;
        if (request.generation != self.host_key_generation or job.cancelled.load(.acquire)) return;
        const key = request.operation_key orelse return;
        if (job.operation_key == null or !job.operation_key.?.eql(key)) return;
        _ = job.host_key_bridge.decideScoped(.{ .key = key, .hop_index = request.hop_index, .request_id = request.generation }, reply);
    }

    /// Authentication belongs to the frozen operation, independent of the
    /// selected tab. Snapshots contain no answer secrets or worker pointers.
    pub fn pendingAuthentication(self: *Workspace) ?auth_challenge.Snapshot {
        self.auth_job = null;
        for (self.connect_jobs.items) |job| {
            if (job.cancelled.load(.acquire) or job.ready.load(.acquire) or self.findTicket(job.ticket) == null) continue;
            const key = job.operation_key orelse continue;
            if (job.host_key_bridge.snapshot()) |request| {
                if (request.operation_key == null or !request.operation_key.?.eql(key)) continue;
                const host = authenticationHost(job, request.hop_index) orelse {
                    job.cancelled.store(true, .release);
                    job.host_key_bridge.cancel();
                    job.auth_bridge.cancel();
                    continue;
                };
                if (host.user.len > 256) {
                    job.cancelled.store(true, .release);
                    job.host_key_bridge.cancel();
                    job.auth_bridge.cancel();
                    continue;
                }
                var challenge: auth_challenge.Snapshot = .{
                    .identity = .{ .key = key, .hop_index = request.hop_index, .request_id = request.generation },
                    .source_owner = request.source_owner,
                    .kind = if (request.status == .changed) .host_key_changed else .host_key_unknown,
                    .presentation = .protected_form,
                    .presentation_config_revision = job.config_snapshot.value.config_revision,
                    .expires_at_ns = null,
                    .port = request.port,
                    .host_len = request.host_len,
                    .user_len = host.user.len,
                };
                @memcpy(challenge.host[0..request.host_len], request.hostSlice());
                @memcpy(challenge.user[0..host.user.len], host.user);
                self.auth_job = job;
                return challenge;
            }
            const challenge = job.auth_bridge.snapshot() orelse continue;
            if (!challenge.identity.key.eql(key)) continue;
            switch (challenge.state) {
                .completed, .cancelled => continue,
                else => {},
            }
            self.auth_job = job;
            return challenge;
        }
        if (self.external_auth) |external| return external.pending(external.context);
        return null;
    }

    pub fn saveAuthenticationPassword(self: *Workspace, request: auth_challenge.Snapshot, password: []const u8) !void {
        if (request.kind != .password) return error.InvalidChallengeResponse;
        const frozen = self.authenticationHostFor(request.identity) orelse return error.StaleAuthentication;
        var transaction = try store.HostsTransaction.init(self.allocator, &self.registry);
        defer transaction.deinit();
        const candidate = &transaction.candidate.?;
        const index = candidate.indexOf(frozen.connection_id) orelse return error.InvalidHost;
        var host = candidate.hosts[index];
        if (host.auth_mode != .password or host.port != frozen.port or
            !std.mem.eql(u8, host.host, frozen.host) or !std.mem.eql(u8, host.user, frozen.user)) return error.RevisionConflict;
        const owner = host.owner();
        host.password = password;
        host.auth_mode = .password;
        _ = try candidate.update(owner, host);
        try transaction.commit(self.io, std.Io.Dir.cwd(), self.hosts_path, &self.registry);
    }

    pub fn submitAuthentication(self: *Workspace, request: auth_challenge.RequestIdentity, reply: auth_challenge.Reply) !void {
        for (self.connect_jobs.items) |job| {
            const key = job.operation_key orelse continue;
            if (!key.eql(request.key)) continue;
            if (job.cancelled.load(.acquire) or job.ready.load(.acquire) or self.findTicket(job.ticket) == null) return error.StaleAuthentication;
            switch (reply) {
                .answers => try job.auth_bridge.submit(request, reply),
                else => if (!job.host_key_bridge.decideScoped(request, reply)) return error.StaleAuthentication,
            }
            self.cx.requestRedraw();
            return;
        }
        if (self.external_auth) |external| {
            try external.submit(external.context, request, reply);
            self.cx.requestRedraw();
            return;
        }
        return error.StaleAuthentication;
    }

    pub fn cancelAuthentication(self: *Workspace, request: auth_challenge.RequestIdentity) bool {
        for (self.connect_jobs.items) |job| {
            const key = job.operation_key orelse continue;
            if (!key.eql(request.key) or self.findTicket(job.ticket) == null) continue;
            const host_key = job.host_key_bridge.snapshot();
            const matches_host = if (host_key) |pending| pending.operation_key != null and pending.operation_key.?.eql(request.key) and pending.hop_index == request.hop_index and pending.generation == request.request_id else false;
            if (!matches_host and !job.auth_bridge.cancelRequest(request)) return false;
            job.cancelled.store(true, .release);
            job.host_key_bridge.cancel();
            job.auth_bridge.cancel();
            self.auth_job = null;
            self.cx.requestRedraw();
            return true;
        }
        if (self.external_auth) |external| {
            const accepted = external.cancel(external.context, request);
            if (accepted) self.cx.requestRedraw();
            return accepted;
        }
        return false;
    }

    fn authenticationHost(job: *ConnectJob, hop: usize) ?hosts_mod.HostConfig {
        if (hop < job.jump_snapshot.value.len) return job.jump_snapshot.value[hop];
        if (hop == job.jump_snapshot.value.len) return job.host_snapshot.value;
        return null;
    }

    pub fn authenticationHostFor(self: *Workspace, request: auth_challenge.RequestIdentity) ?hosts_mod.HostConfig {
        for (self.connect_jobs.items) |job| {
            if (job.operation_key == null or !job.operation_key.?.eql(request.key) or self.findTicket(job.ticket) == null) continue;
            if (job.cancelled.load(.acquire) or job.ready.load(.acquire)) return null;
            if (job.host_key_bridge.snapshot()) |current| {
                const key = current.operation_key orelse return null;
                const current_identity: auth_challenge.RequestIdentity = .{ .key = key, .hop_index = current.hop_index, .request_id = current.generation };
                if (!current_identity.eql(request)) return null;
            } else {
                const current = job.auth_bridge.snapshot() orelse return null;
                if (!current.identity.eql(request) or current.state == .completed or current.state == .cancelled) return null;
            }
            var host = authenticationHost(job, request.hop_index) orelse return null;
            // This accessor is display metadata, never a credential accessor.
            host.password = null;
            host.key_passphrase = null;
            host.totp_secret = null;
            return host;
        }
        if (self.external_auth) |external| return external.host(external.context, request);
        return null;
    }

    pub fn authenticationTotp(self: *Workspace, request: auth_challenge.RequestIdentity, now: @import("../proto/ssh/totp_prefill.zig").Time) !?@import("../proto/ssh/totp_prefill.zig").Suggestion {
        for (self.connect_jobs.items) |job| {
            if (job.operation_key == null or !job.operation_key.?.eql(request.key) or self.findTicket(job.ticket) == null) continue;
            if (job.cancelled.load(.acquire) or job.ready.load(.acquire)) return null;
            const current = job.auth_bridge.snapshot() orelse return null;
            if (!current.identity.eql(request)) return null;
            const host = authenticationHost(job, request.hop_index) orelse return null;
            return @import("../proto/ssh/totp_prefill.zig").suggest(&current, request, host, job.config_snapshot.value.ssh.totp_autofill, now);
        }
        if (self.external_auth) |external| if (external.totp) |propose| return propose(external.context, request, now);
        return null;
    }

    pub fn authenticationParent(self: *Workspace, request: auth_challenge.RequestIdentity) ?*ui.Node {
        for (self.connect_jobs.items) |job| {
            if (job.operation_key == null or !job.operation_key.?.eql(request.key)) continue;
            return (self.findTicket(job.ticket) orelse return null).root;
        }
        if (self.external_auth) |external| return external.parent(external.context, request);
        return null;
    }

    pub fn authenticationHostKey(self: *Workspace, request: auth_challenge.RequestIdentity) ?host_key_confirmation.Request {
        for (self.connect_jobs.items) |job| {
            if (job.operation_key == null or !job.operation_key.?.eql(request.key)) continue;
            if (self.findTicket(job.ticket) == null or job.cancelled.load(.acquire)) return null;
            const observed = job.host_key_bridge.lastSnapshot() orelse return null;
            const key = observed.operation_key orelse return null;
            if (!key.eql(request.key) or observed.hop_index != request.hop_index) return null;
            return observed;
        }
        if (self.external_auth) |external| return external.host_key(external.context, request);
        return null;
    }

    fn pollHostKeyConfirm(self: *Workspace) void {
        if (self.authentication_ui_ready) {
            if (self.host_key_job != null) self.hideHostKeyConfirm();
            return;
        }
        if (self.host_key_job) |job| {
            if (job.host_key_bridge.pending() and !job.cancelled.load(.acquire)) return;
            self.hideHostKeyConfirm();
        }
        for (self.connect_jobs.items) |job| {
            const request = job.host_key_bridge.snapshot() orelse continue;
            if (job.cancelled.load(.acquire) or self.findTicket(job.ticket) == null) {
                job.host_key_bridge.cancel();
                continue;
            }
            self.mountHostKeyConfirm() catch {
                job.host_key_bridge.cancel();
                continue;
            };
            var buffer: [1024]u8 = undefined;
            const message = if (request.status == .changed)
                std.fmt.bufPrint(&buffer, "警告：服务器 {s}:{d} 的主机密钥已变化\n当前主机指纹\n{s} {s}\n只有输入 yes 才能继续", .{
                    request.hostSlice(), request.port, request.algorithmSlice(), request.fingerprintSlice(),
                }) catch "主机密钥已变化"
            else
                std.fmt.bufPrint(&buffer, "服务器 {s}:{d} 的身份尚未记录\n主机指纹\n{s} {s}", .{
                    request.hostSlice(), request.port, request.algorithmSlice(), request.fingerprintSlice(),
                }) catch "无法显示主机指纹";
            self.host_key_detail.?.setTextContent(self.cx.allocator, message) catch {
                job.host_key_bridge.cancel();
                continue;
            };
            const changed = request.status == .changed;
            self.host_key_detail.?.setTextColor(if (changed) ui.Color.rgb(0xDC, 0x4C, 0x3F) else ui.Color.rgb(0x47, 0x55, 0x69));
            if (self.host_key_changed_button) |button| button.setDisplay(if (changed) .flex else .none);
            self.host_key_job = job;
            self.host_key_generation = request.generation;
            self.host_key_root.?.setDisplay(.flex);
            self.cx.setFocus(self.host_key_card.?);
            self.cx.scheduleRedrawAfterNs(0);
            return;
        }
    }

    // ── Close confirmation card ──────────────────────────────────────

    /// One-shot mount of the close-confirmation overlay onto terminal_area:
    /// an absolute, centered, high-z scrim with a translucent background
    /// plus the themed overlay card. Hidden right away; showing it later only
    /// rewrites the dynamic texts and flips display.
    fn mountCloseConfirm(self: *Workspace) !void {
        if (self.confirm_root != null) return;
        const p = self.palette;
        const cx = self.cx;
        const allocator = cx.allocator;

        const scrim = try ui.box(cx, .{
            .position = .absolute,
            .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
            .width = .fill(),
            .height = .fill(),
            .z_index = 300,
            .direction = .column,
            .align_items = .center,
            .justify = .center,
            .background = ui.Color.rgba(15, 23, 42, 110),
        }, .{});

        const card = try ui.box(cx, .{
            .width = .{ .px = 420 },
            .direction = .column,
            .background = app_theme.current().overlay,
            .glass = app_theme.overlayGlass(),
            .border = .{ .width = 0, .color = p.border, .radius = 12 },
            .padding = ui.Padding.all(20),
            .shadow = .{ .blur = 28, .offset_y = 10, .color = ui.Color.rgba(15, 23, 42, 70) },
        }, .{});

        card.meta.ownership.meta.test_id = "session.close.confirm";
        const title = try ui.text(cx, "关闭会话?", .{
            .font_size = 15,
            .font_weight = 700,
            .color = danger_red,
            .wrap = .word,
        });
        try card.appendChild(allocator, title);

        const subtitle = try ui.box(cx, .{
            .width = .fill(),
            .margin = .{ .top = 4, .right = 0, .bottom = 0, .left = 0 },
        }, .{});
        try subtitle.appendChild(allocator, try ui.text(cx, "此会话仍有任务运行，关闭将影响以下内容。", .{
            .font_size = 11,
            .color = p.fg_secondary,
            .wrap = .word,
        }));
        try card.appendChild(allocator, subtitle);

        // Risk rows (category → detail, separated by spacing) — the
        // mockup-close-confirm rule list: 传输 / AI / SOCKS5 / 历史 plus the
        // live-session SSH row. setRiskDetail rewrites details by category at
        // show time; rows without live state keep the design-text default.
        const risk_specs = [_]struct { category: []const u8, detail: []const u8 }{
            .{ .category = "SSH", .detail = "" },
            .{ .category = "传输", .detail = "关闭将暂停未完成的传输" },
            .{ .category = "AI", .detail = "关闭将中止正在执行的命令" },
            .{ .category = "SOCKS5", .detail = "关闭将停止代理并断开连接" },
            .{ .category = "历史", .detail = "已保存的记录可从「查看历史」回放" },
        };
        const rows = try ui.box(cx, .{
            .width = .fill(),
            .direction = .column,
            .margin = .{ .top = 12, .right = 0, .bottom = 0, .left = 0 },
        }, .{});
        for (risk_specs) |spec| {
            const row = try ui.box(cx, .{
                .width = .fill(),
                .direction = .row,
                .align_items = .center,
                .gap = 10,
                .padding = .{ .left = 0, .right = 0, .top = 8, .bottom = 8 },
            }, .{});
            const category = try ui.box(cx, .{ .width = .{ .px = 64 }, .flex_shrink = 0 }, .{});
            try category.appendChild(allocator, try ui.text(cx, spec.category, .{
                .font_size = 12,
                .font_weight = 600,
                .color = p.fg,
            }));
            try row.appendChild(allocator, category);
            const detail = try ui.box(cx, .{ .width = .fill() }, .{});
            const detail_text = try ui.text(cx, spec.detail, .{
                .font_size = 12,
                .color = p.fg_secondary,
                .wrap = .word,
            });
            try detail.appendChild(allocator, detail_text);
            try row.appendChild(allocator, detail);
            try rows.appendChild(allocator, row);
            try self.confirm_risk_rows.append(self.allocator, .{ .category = spec.category, .detail_node = detail_text, .row_node = row });
        }
        try card.appendChild(allocator, rows);

        const buttons = try ui.box(cx, .{
            .width = .fill(),
            .direction = .row,
            .align_items = .center,
            .justify = .end,
            .gap = 10,
            .margin = .{ .top = 18, .right = 0, .bottom = 0, .left = 0 },
        }, .{});
        const cancel_button = try ui.widgets.Button(.{
            .label = "取消",
            .variant = .secondary,
            .a11y_label = "取消关闭会话",
            .base_style = .{ .border = .{ .width = 0, .color = p.border, .radius = 8 }, .text_color = p.fg_secondary },
            .on_click = cx.on(Workspace, self, onCancelConfirm),
        }).mount(self.scope, cx);
        cancel_button.meta.ownership.meta.test_id = "session.close.cancel";
        try buttons.appendChild(allocator, cancel_button);
        const force_button = try ui.widgets.Button(.{
            .label = "仍然关闭",
            .variant = .secondary,
            .a11y_label = "仍然关闭会话",
            .base_style = .{
                .background = ui.Color.WHITE,
                .border = .{ .width = 0, .color = ui.Color.rgba(0xDC, 0x4C, 0x3F, 89), .radius = 8 },
                .text_color = danger_red,
            },
            .on_click = cx.on(Workspace, self, onConfirmForceClose),
        }).mount(self.scope, cx);
        force_button.meta.ownership.meta.test_id = "session.close.accept";
        try buttons.appendChild(allocator, force_button);
        try card.appendChild(allocator, buttons);

        // Esc cancels. Focus moves onto the card when it opens, so the
        // terminal pane behind never eats the keystroke; the handler also
        // fires from focused buttons inside the card via the bubble phase.
        card.behavior.interaction.focusable = true;
        card.behavior.events.on_key_down = onCloseConfirmKeyDown;
        card.behavior.events.key_context = @ptrCast(self);

        try scrim.appendChild(allocator, card);
        scrim.setDisplay(.none);
        try self.terminal_area.appendChild(allocator, scrim);
        self.confirm_root = scrim;
        self.confirm_card = card;
        try app_theme.bindMaterial(cx, self.scope, card, "overlay");
        self.confirm_title = title;
    }

    /// Puts the confirmation card up for `index` (live session): records the
    /// pending tab, rewrites the dynamic texts (title + SSH risk row),
    /// reveals the scrim and moves keyboard focus onto the card.
    fn showCloseConfirm(self: *Workspace, index: usize) void {
        if (index >= self.tabs.items.len) return;
        const root = self.confirm_root orelse return;
        const tab = self.tabs.items[index];
        // A repeated requestCloseTab while the card is up simply overwrites
        // the pending index; the texts re-render for the new tab.
        self.confirming_tab = index;
        self.confirming_id = self.tabs.items[index].tab_id;
        applog.debug(.workspace, "close confirm shown for tab {d}", .{index});
        var title_buffer: [96]u8 = undefined;
        var title_writer = std.Io.Writer.fixed(&title_buffer);
        title_writer.print("关闭 {s}？", .{tab.titleSlice()}) catch {};
        if (self.confirm_title) |title| {
            title.setTextContent(self.allocator, title_writer.buffered()) catch {};
            title.markRenderDirty();
        }
        if (tab.host_snapshot) |snapshot| {
            const host = snapshot.value;
            var detail_buffer: [160]u8 = undefined;
            var detail_writer = std.Io.Writer.fixed(&detail_buffer);
            detail_writer.print("与 {s} 的连接将断开", .{host.host}) catch {};
            self.setRiskDetail("SSH", detail_writer.buffered());
        }
        self.setRiskVisible("SSH", !tab.local);
        // 传输/AI/SOCKS5 rows: hidden until those subsystems report live
        // state for the pending tab (wiring lands with their integration;
        // the rows mount with the design text so no fallback text is
        // invented here).
        const risk = if (self.close_bridge.risk) |callback| callback(self.close_bridge.context, tab.id) else CloseRisk{};
        self.setRiskVisible("传输", risk.transfer);
        self.setRiskVisible("AI", risk.ai_write);
        self.setRiskVisible("SOCKS5", risk.socks);
        if (risk.transfer) self.setRiskDetail("传输", "尚有未完成任务，关闭将暂停并保留续传数据");
        if (risk.ai_write) self.setRiskDetail("AI", "写命令执行中，关闭将中止并清理远端进程");
        if (risk.socks) self.setRiskDetail("SOCKS5", "正在监听，关闭将释放代理连接与端口");
        root.setDisplay(.flex);
        if (self.confirm_card) |card| self.cx.setFocus(card);
        self.cx.requestRedraw();
    }

    /// Takes the card down and clears the pending index. Does not touch
    /// focus — callers decide where keyboard input goes next.
    fn hideCloseConfirm(self: *Workspace) void {
        self.confirming_tab = null;
        self.confirming_id = null;
        if (self.confirm_root) |root| root.setDisplay(.none);
        self.cx.requestRedraw();
    }

    /// Rewrites one risk row's detail line, matched by category label.
    fn setRiskDetail(self: *Workspace, category: []const u8, detail: []const u8) void {
        for (self.confirm_risk_rows.items) |row| {
            if (!std.mem.eql(u8, row.category, category)) continue;
            row.detail_node.setTextContent(self.allocator, detail) catch return;
            row.detail_node.markRenderDirty();
            return;
        }
    }

    /// Shows/hides one risk row. 传输/AI/SOCKS5 rows stay hidden until the
    /// corresponding subsystem reports live state for the pending tab
    /// (they mount with the mockup design text so the card matches the
    /// png the moment real data lands in setRiskDetail).
    fn setRiskVisible(self: *Workspace, category: []const u8, visible: bool) void {
        for (self.confirm_risk_rows.items) |row| {
            if (!std.mem.eql(u8, row.category, category)) continue;
            row.row_node.setDisplay(if (visible) .flex else .none);
            return;
        }
    }

    /// After cancel/Esc the card gives keyboard focus back to the active
    /// terminal pane (it stole focus when it opened).
    fn restoreFocusToActiveTab(self: *Workspace) void {
        if (self.active_tab) |active| {
            if (active < self.tabs.items.len) self.cx.setFocus(if (self.tabs.items[active].terminal) |*value| value.root else self.tabs.items[active].root);
        }
    }

    /// Confirm-card "取消": keep the tab, take the card down.
    fn onCancelConfirm(self: *Workspace) void {
        self.abortCloseBatch();
        applog.debug(.workspace, "close confirm: cancelled", .{});
        self.hideCloseConfirm();
        self.restoreFocusToActiveTab();
    }

    /// Confirm-card "仍然关闭": the user accepted the risk rows — tear the
    /// pending tab down for real.
    fn onConfirmForceClose(self: *Workspace) void {
        const id = self.confirming_id orelse return;
        const index = self.tabIndexById(id) orelse {
            self.hideCloseConfirm();
            return;
        };
        applog.info(.workspace, "close confirm: force closing tab {d}", .{index});
        self.hideCloseConfirm();
        self.forceCloseTab(index);
        self.continueCloseOthers();
    }

    // ── Session lifecycle ────────────────────────────────────────────

    /// Opens (or focuses) a session tab for the host. The terminal surface and
    /// tab appear immediately with a "连接中" state; the SSH connection then
    /// proceeds on a background thread and finishes back on the UI thread.
    /// Saved connections are configurations, not running sessions. Every
    /// activation creates a new session with its own immutable snapshot.
    pub fn openSession(self: *Workspace, index: usize) !void {
        try self.newSession(index);
    }

    /// Always creates a distinct session for this asset, even if already open.
    pub fn newSession(self: *Workspace, index: usize) !void {
        if (index >= self.registry.hosts.len) return error.InvalidHost;
        try self.identities.appendHosts(self.allocator, self.registry.hosts.len);
        try self.createSession(self.registry.hosts[index], self.hostId(index).?, index, "");
        self.recent_connections.record(self.registry.hosts[index].connection_id, 0);
    }

    /// The saved revision supplies every routing and policy field. Secrets
    /// entered for this connection are copied by SessionHost, never persisted.
    pub fn newSessionWithCredentials(self: *Workspace, owner: identity.AssetOwner, password: ?[]const u8, key_passphrase: ?[]const u8) !void {
        var host = try self.registry.get(owner);
        if (password) |value| host.password = value;
        if (key_passphrase) |value| host.key_passphrase = value;
        const index = self.registry.indexOf(owner.id) orelse return error.InvalidHost;
        try self.identities.appendHosts(self.allocator, self.registry.hosts.len);
        try self.createSession(host, self.hostId(index).?, index, "");
        self.recent_connections.record(owner.id, 0);
    }

    /// The session factory owns a frozen copy. A temporary direct endpoint
    /// never enters the asset registry or consumes an asset identity.
    pub fn newTemporarySession(self: *Workspace, host: hosts_mod.HostConfig) !void {
        if (self.shutting_down or self.model.window_close != null) return error.WorkspaceClosed;
        if (@backingInt(host.connection_id) != 0 or host.protocol != .ssh or host.route.len != 0 or host.jump_chain.len != 0) return error.InvalidTemporaryTarget;
        try host.validate();
        try self.createSession(host, 0, removed_host_index, "");
    }

    pub fn isLocalSession(self: *const Workspace, id: SessionId) bool {
        const tab = self.sessionTab(id) orelse return false;
        return tab.local;
    }

    pub fn newLocalSession(self: *Workspace, cwd: ?[]const u8) !void {
        if (self.shutting_down or self.model.window_close != null) return error.WorkspaceClosed;
        const create = self.session_bridge.create_local orelse return error.LocalAdapterUnavailable;
        try create(self.session_bridge.context, cwd);
    }

    pub fn retryLocalSession(self: *Workspace, id: SessionId) !void {
        if (self.shutting_down or self.model.window_close != null) return error.WorkspaceClosed;
        const tab = self.sessionTab(id) orelse return error.InvalidTab;
        if (!tab.local or tab.closing or tab.local_state != .failed) return error.LifecycleDoesNotAllowRetry;
        const retry = self.session_bridge.retry_local orelse return error.LocalAdapterUnavailable;
        try retry(self.session_bridge.context, id);
    }

    /// Presentation only; SessionHost has already assigned this exact owner.
    /// No HostConfig or process creation is allowed in this path.
    fn applyTerminalTypography(self: *Workspace, terminal: *TerminalViewNode) !void {
        if (self.terminal_typography_resolver) |resolve| return resolve(terminal, self.app_config.ui);
        try terminal.setTypographyFamily(self.app_config.ui.font_size, self.app_config.ui.line_height, fontWeight(self.app_config.ui.font_weight), self.app_config.ui.font_family, if (self.font_family_resolver) |resolve| resolve(self.app_config.ui.font_family) else 0);
    }

    pub fn createLocalSessionDirect(self: *Workspace, handle: identity.SessionHandle) !SessionId {
        if (self.shutting_down) return error.WorkspaceClosed;
        try self.tabs.ensureUnusedCapacity(self.allocator, 1);
        try self.startPollLoop();
        const tab = try self.allocator.create(SessionTab);
        errdefer self.allocator.destroy(tab);
        var terminal = try TerminalViewNode.mount(self.cx);
        terminal.setTerminalTakeoverHandler(self.terminal_takeover_handler);
        var owned_pane: ?*ui.Node = null;
        var local_scope: ?*ui.Scope = null;
        var terminal_attached = false;
        errdefer {
            if (local_scope) |scope| scope.dispose();
            terminal.releaseBuffers(self.cx);
            if (owned_pane) |pane| self.cx.destroyDetached(pane);
            if (!terminal_attached) self.cx.destroyDetached(terminal.root);
        }
        local_scope = try self.scope.childScope();
        terminal.completion_enabled = self.app_config.completion.enabled;
        terminal.palette_observer = self.command_bridge;
        terminal.input_observer = self.input_bridge;
        terminal.setThemeColors(self.palette.fg, self.palette.border, self.palette.accent);
        try self.applyTerminalTypography(&terminal);
        terminal.setCursorStyle(cursorStyle(self.app_config.ui.cursor_style));
        terminal.setTimestampGutter(self.app_config.ui.timestamp_gutter);
        try terminal.setInputLineHighlight(self.app_config.ui.input_line_highlight);
        const pane = try ui.box(self.cx, local_styles.pane(), .{});
        owned_pane = pane;
        terminal.root.setStyleInline(self.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
        const ticket = self.identities.newTicket();
        tab.* = .{ .id = ticket.session_id, .tab_id = try tab_ids.allocate(), .content_owner = .{ .session = handle }, .generation = handle.generation, .host_id = 0, .host_index = removed_host_index, .host_snapshot = null, .root = pane, .terminal = terminal, .local = true, .local_scope = local_scope };
        tab.setTitle("Local Terminal");
        try self.mountLocalBanner(tab);
        try pane.appendChild(self.allocator, terminal.root);
        terminal_attached = true;
        try tab.terminal.?.attachSearch(local_scope.?);
        try self.installTabModel(tab);
        errdefer self.model.completeClose(tab.tab_id, tab.content_owner) catch {};
        try self.terminal_area.appendChild(self.allocator, pane);
        self.tabs.appendAssumeCapacity(tab);
        self.updateLocalState(tab.id, .starting, "正在启动 zsh…");
        self.rebuildTabBar() catch {};
        self.selectTab(self.tabs.items.len - 1);
        return tab.id;
    }

    /// Mount any native renderer in the existing content area and tab model.
    /// The provider receives only its slot, owned scope, identity and facades.
    /// UI-only detach for a transferred renderer. It never sends an owner close.
    pub fn validatePluginTransfer(self: *Workspace, owner: identity.SessionHandle, id: SessionId) !void {
        if (self.shutting_down) return error.WorkspaceClosed;
        const tab = self.sessionTab(id) orelse return error.UnknownSession;
        if (tab.content_owner != .session or !tab.content_owner.session.eql(owner) or tab.closing or tab.plugin_renderer == null or tab.terminal != null or tab.runtime != null) return error.ContentTransferUnavailable;
        if (self.model.order_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
    }
    pub fn discardTransferredPlugin(self: *Workspace, owner: identity.SessionHandle, id: SessionId) void {
        self.validatePluginTransfer(owner, id) catch unreachable;
        const tab = self.sessionTab(id).?;
        const index = self.tabIndexById(tab.tab_id).?;
        self.model.completeClose(tab.tab_id, tab.content_owner) catch unreachable;
        if (self.rename_session == tab.id) _ = self.cancelRenameTab();
        if (tab.root.parent) |parent| self.cx.detachChild(parent, tab.root);
        tab.plugin_renderer.?.vtable.unmount(tab.plugin_renderer.?.context);
        tab.plugin_renderer = null;
        tab.transfer_trays = .{ null, null };
        if (tab.file_scope) |scope| scope.dispose();
        tab.file_scope = null;
        self.cx.destroyDetached(tab.root);
        if (tab.plugin_protocol_id.len != 0) self.allocator.free(tab.plugin_protocol_id);
        self.allocator.destroy(tab);
        _ = self.tabs.orderedRemove(index);
        self.active_tab = if (self.model.active) |active| self.tabIndexById(active) else null;
        if (self.tabs.items.len == 0) {
            self.status("未连接");
            self.empty_state.setDisplay(.flex);
        }
        self.rebuildTabBar() catch {};
        self.rebuildSidebar() catch {};
        if (self.model.active) |active| self.presentTabId(active);
        self.cx.requestRedraw();
    }

    pub fn createPluginSession(self: *Workspace, owner: identity.SessionHandle, value: envelopes.Envelope, renderer: plugin_ui.RendererDefinition) !SessionId {
        if (self.shutting_down) return error.WorkspaceClosed;
        const mount_renderer = renderer.mount orelse return error.ContentRendererUnavailable;
        try self.tabs.ensureUnusedCapacity(self.allocator, 1);
        const tab = try self.allocator.create(SessionTab);
        errdefer self.allocator.destroy(tab);
        const scope = try self.scope.childScope();
        errdefer scope.dispose();
        const pane = try ui.box(self.cx, local_styles.pane(), .{});
        errdefer self.cx.destroyDetached(pane);
        pane.meta.ownership.meta.test_id = "workspace.plugin.content";
        const protocol_id = try self.allocator.dupe(u8, value.protocol_id);
        errdefer self.allocator.free(protocol_id);
        const services = if (self.content_services) |factory| try factory.create(factory.context, owner) else plugin_ui.ContentServices{};
        const instance = try mount_renderer(renderer.context, .{ .cx = self.cx, .scope = scope, .slot = pane, .owner = owner, .connection = value, .content_context = services.content_context, .frame_sink = services.frame_sink });
        errdefer instance.vtable.unmount(instance.context);
        const ticket = self.identities.newTicket();
        tab.* = .{ .id = ticket.session_id, .tab_id = try tab_ids.allocate(), .content_owner = .{ .session = owner }, .generation = owner.generation, .host_id = @backingInt(value.id), .host_index = self.registry.indexOf(value.id) orelse removed_host_index, .host_snapshot = null, .root = pane, .file_scope = scope, .plugin_renderer = instance, .plugin_protocol_id = protocol_id, .content_ready = true };
        tab.setTitle(value.name);
        try self.installTabModel(tab);
        errdefer self.model.completeClose(tab.tab_id, tab.content_owner) catch {};
        try self.terminal_area.appendChild(self.allocator, pane);
        self.tabs.appendAssumeCapacity(tab);
        self.rebuildTabBar() catch {};
        self.selectTab(self.tabs.items.len - 1);
        return tab.id;
    }

    /// Attach a real file workspace without constructing VT, PTY or a shell.
    /// Ownership of content/scope transfers only after this method succeeds.
    pub fn createFileSessionDirect(self: *Workspace, handle: identity.SessionHandle, host: hosts_mod.HostConfig, host_id: HostId, source_index: usize, content: *ui.Node, content_scope: *ui.Scope) !SessionId {
        if (self.shutting_down) return error.WorkspaceClosed;
        if (host.protocol != .sftp) return error.WrongPlugin;
        if (content.parent != null) return error.ContentAlreadyAttached;
        try self.tabs.ensureUnusedCapacity(self.allocator, 1);
        const tab = try self.allocator.create(SessionTab);
        errdefer self.allocator.destroy(tab);
        var snapshot = try HostSnapshot.init(self.allocator, host);
        errdefer snapshot.deinit();
        const ticket = self.identities.newTicket();
        tab.* = .{ .id = ticket.session_id, .tab_id = try tab_ids.allocate(), .content_owner = .{ .session = handle }, .generation = handle.generation, .host_id = host_id, .host_index = source_index, .host_snapshot = snapshot, .root = content, .file_scope = content_scope };
        tab.setTitle(host.name);
        try self.installTabModel(tab);
        errdefer self.model.completeClose(tab.tab_id, tab.content_owner) catch {};
        content.behavior.interaction.focusable = true;
        try self.terminal_area.appendChild(self.allocator, content);
        self.tabs.appendAssumeCapacity(tab);
        self.rebuildTabBar() catch {};
        self.selectTab(self.tabs.items.len - 1);
        return tab.id;
    }

    fn mountLocalBanner(self: *Workspace, tab: *SessionTab) !void {
        const banner = try ui.box(self.cx, local_styles.banner(true), .{});
        try tab.root.appendChild(self.allocator, banner);
        tab.local_banner = banner;
        banner.meta.ownership.meta.test_id = "local.notice";
        tab.local_spinner = try ui.widgets.Spinner(.{ .size = 16, .stroke_width = 2, .color = app_theme.current().fg_2 }).mount(tab.local_scope.?, self.cx);
        try banner.appendChild(self.allocator, tab.local_spinner.?);
        tab.local_ended_icon = try ui.iconTint(self.cx, ui.icons.get("terminal").?, app_theme.current().fg_2, local_styles.icon());
        try banner.appendChild(self.allocator, tab.local_ended_icon.?);
        tab.local_failure_icon = try ui.iconTint(self.cx, ui.icons.circle_alert, app_theme.current().danger, local_styles.icon());
        try banner.appendChild(self.allocator, tab.local_failure_icon.?);
        const copy = try ui.box(self.cx, local_styles.copy(), .{});
        copy.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        try banner.appendChild(self.allocator, copy);
        tab.local_message = try ui.text(self.cx, "正在启动本地终端…", local_styles.title());
        tab.local_message.?.meta.ownership.meta.test_id = "local.notice.title";
        try copy.appendChild(self.allocator, tab.local_message.?);
        tab.local_detail = try ui.text(self.cx, "", local_styles.detail());
        tab.local_detail.?.meta.ownership.meta.test_id = "local.notice.detail";
        try copy.appendChild(self.allocator, tab.local_detail.?);
        const cell = try self.allocator.create(ClickCtx);
        var adopted = false;
        errdefer if (!adopted) self.allocator.destroy(cell);
        cell.* = .{ .workspace = self, .index = 0, .session_id = tab.id };
        // Banner callbacks live with the pane, not the rebuilt tab-strip pool.
        try tab.local_scope.?.adoptResource(@ptrCast(cell), struct {
            fn release(raw: *anyopaque, allocator: std.mem.Allocator) void {
                allocator.destroy(@as(*ClickCtx, @ptrCast(@alignCast(raw))));
            }
        }.release);
        adopted = true;
        const cancel = try ui.widgets.Button(.{ .label = "取消启动", .variant = .ghost, .size = .sm, .on_click = self.cx.on(ClickCtx, cell, cancelLocalStart) }).mount(tab.local_scope.?, self.cx);
        cancel.setStyleInline(self.allocator, local_styles.cancel());
        cancel.meta.ownership.meta.test_id = "local.start.cancel";
        tab.local_cancel = cancel;
        try banner.appendChild(self.allocator, cancel);
        const close = try ui.widgets.Button(.{ .label = "关闭页签", .variant = .ghost, .size = .sm, .on_click = self.cx.on(ClickCtx, cell, cancelLocalStart) }).mount(tab.local_scope.?, self.cx);
        close.setStyleInline(self.allocator, local_styles.cancel());
        close.meta.ownership.meta.test_id = "local.ended.close";
        tab.local_close = close;
        try banner.appendChild(self.allocator, close);
        const retry = try ui.widgets.Button(.{ .label = "重试启动", .variant = .primary, .size = .sm, .base_style = .{ .font_size = 12, .font_weight = 500 }, .on_click = self.cx.on(ClickCtx, cell, retryLocalStart) }).mount(tab.local_scope.?, self.cx);
        retry.setStyleInline(self.allocator, local_styles.action());
        retry.meta.ownership.meta.test_id = "local.start.retry";
        tab.local_retry = retry;
        try banner.appendChild(self.allocator, retry);
        const new = try ui.widgets.Button(.{ .label = "新建终端", .variant = .primary, .size = .sm, .base_style = .{ .font_size = 12, .font_weight = 500 }, .on_click = self.cx.on(ClickCtx, cell, newLocalFromEnded) }).mount(tab.local_scope.?, self.cx);
        new.setStyleInline(self.allocator, local_styles.action());
        new.meta.ownership.meta.test_id = "local.ended.new";
        tab.local_new = new;
        try banner.appendChild(self.allocator, new);
    }

    fn cancelLocalStart(cell: *ClickCtx) void {
        const self = cell.workspace;
        const index = self.tabIndex(cell.session_id orelse return) orelse return;
        // This explicit startup action cancels the creating operation. A late
        // click after startup completed uses the ordinary risk-gated close.
        if (self.tabs.items[index].local_state == .starting) {
            self.forceCloseTab(index);
            return;
        }
        self.requestCloseTab(index);
    }
    fn retryLocalStart(cell: *ClickCtx) void {
        cell.workspace.retryLocalSession(cell.session_id orelse return) catch |err| cell.workspace.statusFailure(@errorName(err));
    }
    fn newLocalFromEnded(cell: *ClickCtx) void {
        cell.workspace.newLocalSession(null) catch |err| cell.workspace.statusFailure(@errorName(err));
    }

    pub fn userInputRevision(self: *Workspace, handle: identity.SessionHandle) ?u64 {
        for (self.tabs.items) |tab| {
            if (tab.archived or tab.content_owner != .session or !tab.content_owner.session.eql(handle)) continue;
            const view = if (tab.terminal) |*terminal_view| terminal_view else return null;
            if (view.terminal_surface) |surface| return if (surface.owner.eql(handle)) surface.user_input_revision else null;
            return view.user_input_revision;
        }
        return null;
    }
    pub fn setTerminalTakeoverHandler(self: *Workspace, handler: ?@import("terminal_view.zig").TakeoverHandler) void {
        self.terminal_takeover_handler = handler;
        for (self.tabs.items) |tab| if (tab.terminal) |*view| view.setTerminalTakeoverHandler(handler);
    }
    pub fn bindLocalTerminal(self: *Workspace, id: SessionId, handle: identity.SessionHandle, service: terminal_service.Service) !void {
        const tab = self.sessionTab(id) orelse return error.InvalidTab;
        if (!tab.local or !tab.content_owner.eql(.{ .session = handle })) return error.StaleSession;
        if (tab.local_bound) return;
        tab.terminal.?.setTerminalMenuHandler(.{ .context = self, .request = onTerminalServiceMenu });
        try tab.terminal.?.bindTerminalService(service);
        tab.local_bound = true;
    }

    fn onTerminalServiceMenu(raw: ?*anyopaque, handle: identity.SessionHandle, x: f32, y: f32) void {
        const self: *Workspace = @ptrCast(@alignCast(raw orelse return));
        if (self.shutting_down) return;
        for (self.tabs.items, 0..) |tab, index| {
            if (tab.closing or !tab.content_owner.eql(.{ .session = handle })) continue;
            if (!tab.local and (tab.archived or tab.failed or tab.runtime == null)) continue;
            self.menu_bridge.fireTab(.terminal_middle_click, index, self.tabs.items.len > 1, .{ .x = x, .y = y, .w = 0, .h = 0 });
            return;
        }
    }

    pub fn unbindLocalTerminal(self: *Workspace, id: SessionId, handle: identity.SessionHandle) void {
        const tab = self.sessionTab(id) orelse return;
        if (!tab.local or !tab.content_owner.eql(.{ .session = handle })) return;
        tab.terminal.?.unbindTerminalService(handle);
        tab.local_bound = false;
    }

    pub fn updateLocalState(self: *Workspace, id: SessionId, state: LocalState, text: []const u8) void {
        const tab = self.sessionTab(id) orelse return;
        if (!tab.local) return;
        const changed = tab.local_state != state;
        tab.local_state = state;
        tab.failed = state == .failed;
        if (tab.local_message) |node| {
            node.setTextContent(self.allocator, switch (state) {
                .starting => "正在启动本地终端…",
                .running => "本地终端",
                .exited => "本地终端已退出",
                .failed => "本地终端启动失败",
                .closing => "正在关闭本地终端…",
                .cleanup_unknown => "暂时无法确认终端已关闭",
            }) catch {};
        }
        if (tab.local_banner) |node| {
            node.setStyleInline(self.allocator, local_styles.banner(state == .starting));
            node.setDisplay(if (state == .running) .none else .flex);
        }
        if (tab.local_detail) |node| {
            var buffer: [512]u8 = undefined;
            const detail: []const u8 = switch (state) {
                .starting => "正在准备 zsh 环境，请稍候",
                .running => "",
                .failed => std.fmt.bufPrint(&buffer, "{s}；请检查初始目录与可执行权限", .{text}) catch text,
                .exited => blk: {
                    const exit_detail = if (std.mem.indexOf(u8, text, " · ")) |offset| text[offset + " · ".len ..] else "";
                    const prefix: []const u8 = if (std.mem.startsWith(u8, exit_detail, "exit ")) " · 退出码 " else if (std.mem.startsWith(u8, exit_detail, "signal ")) " · 终止信号 " else if (exit_detail.len > 0) " · " else "";
                    const value = if (std.mem.startsWith(u8, exit_detail, "exit ")) exit_detail[5..] else if (std.mem.startsWith(u8, exit_detail, "signal ")) exit_detail[7..] else exit_detail;
                    break :blk std.fmt.bufPrint(&buffer, "历史输出仍可查看，继续使用请新建终端{s}{s}", .{ prefix, value }) catch "历史输出仍可查看，继续使用请新建终端";
                },
                .closing => "正在释放会话资源，请稍候",
                .cleanup_unknown => "资源清理结果未知，已保留会话；请稍后查看状态",
            };
            node.setTextContent(self.allocator, detail) catch {};
        }
        if (tab.local_cancel) |node| node.setDisplay(if (state == .starting) .flex else .none);
        if (tab.local_close) |node| node.setDisplay(if (state == .exited or state == .failed) .flex else .none);
        if (tab.local_spinner) |node| node.setDisplay(if (state == .starting or state == .closing) .flex else .none);
        if (tab.local_ended_icon) |node| node.setDisplay(if (state == .exited) .flex else .none);
        if (tab.local_failure_icon) |node| node.setDisplay(if (state == .failed or state == .cleanup_unknown) .flex else .none);
        if (tab.local_retry) |node| node.setDisplay(if (state == .failed) .flex else .none);
        if (tab.local_new) |node| node.setDisplay(if (state == .exited) .flex else .none);
        if (changed) {
            const title = if (state == .failed) "Local Terminal · 启动失败" else if (state == .exited) "Local Terminal · 已退出" else "Local Terminal";
            const index = self.model.indexOf(tab.tab_id) orelse return;
            const current = self.model.tabs.items[index].name();
            if (std.mem.eql(u8, current, "Local Terminal") or std.mem.eql(u8, current, "Local Terminal · 启动失败") or std.mem.eql(u8, current, "Local Terminal · 已退出")) {
                // Startup readiness changes the status, but an unchanged
                // default title must not invalidate an in-flight rename.
                if (!std.mem.eql(u8, current, title)) {
                    self.model.rename(self.model.beginRename(tab.tab_id) catch return, title) catch {};
                    tab.setTitle(self.model.tabs.items[index].name());
                }
                self.rebuildTabBar() catch {};
            }
        }
    }

    fn createSession(self: *Workspace, host: hosts_mod.HostConfig, host_id: HostId, index: usize, initial_input: []const u8) !void {
        const create = self.session_bridge.create orelse return error.SessionHostUnavailable;
        return create(self.session_bridge.context, host, host_id, index, initial_input);
    }

    /// Capture the host's real operation before any connection thread starts.
    /// Legacy direct callers carry no operation rather than inventing one.
    pub fn createSessionDirectForOperation(self: *Workspace, host: hosts_mod.HostConfig, host_id: HostId, source_index: usize, initial_input: []const u8, operation: OperationKey) !SessionId {
        if (operation.owner != .session or operation.operation_id == 0) return error.InvalidOperation;
        try self.spawnSessionWithInput(host, host_id, source_index, initial_input, operation);
        return self.tabs.items[self.tabs.items.len - 1].id;
    }

    pub fn cancelSessionCreation(self: *Workspace, id: SessionId) void {
        for (self.connect_jobs.items) |job| if (job.ticket.session_id == id) {
            const was_cancelled = job.cancelled.swap(true, .acq_rel);
            const retry_pending = job.automatic_retry_deadline_ns != null;
            if (retry_pending) {
                job.automatic_retry_deadline_ns = null;
                job.err = null;
            }
            // Installation may have drained the creation result before the
            // host accepted attached. Cancel must still poll the real runtime
            // destructor and publish its create-cleanup receipt exactly once.
            if (!was_cancelled and job.drained and (job.runtime != null or retry_pending)) job.drained = false;
            job.host_key_bridge.cancel();
            job.auth_bridge.cancel();
            if (self.host_key_job == job) self.hideHostKeyConfirm();
            if (self.auth_job == job) {
                if (self.auth_root) |root| root.setDisplay(.none);
                self.auth_job = null;
            }
        };
    }

    /// Protocol ownership is released before the host acknowledges view removal.
    /// Pending connect jobs are cancelled, then report their own final receipt.
    pub fn protocolRelease(self: *Workspace, id: SessionId) bool {
        return self.protocolReleaseStep(id) == .released;
    }

    pub fn protocolReleaseStep(self: *Workspace, id: SessionId) RuntimeReleaseReceipt {
        self.cancelSessionCreation(id);
        var receipt: RuntimeReleaseReceipt = .released;
        if (self.sessionTab(id)) |tab| {
            if (tab.terminal) |*terminal| {
                terminal.removeFrameHook(self.cx);
                terminal.releaseCommandDocument();
                terminal.worker = null;
            }
            if (tab.terminal) |*terminal| terminal.root.behavior.interaction.text_input_client = null;
            self.cx.refreshTextInputSession();
            if (tab.runtime) |runtime| receipt = runtime.releaseStep(.{ .session_id = tab.id, .retention_days = self.app_config.log.retention_days });
        }
        for (self.connect_jobs.items) |job| {
            if (job.ticket.session_id != id) continue;
            if (job.cleanup_unknown) return .unknown;
            if (job.ready.load(.acquire)) if (job.runtime) |runtime| {
                switch (runtime.releaseStep(null)) {
                    .unknown => return .unknown,
                    .awaiting => receipt = .awaiting,
                    .released => {},
                }
            };
            if (!job.drained and receipt == .released) receipt = .awaiting;
        }
        return receipt;
    }

    /// Called only after SessionHost has accepted this operation's attachment.
    pub fn acknowledgeSessionAttached(self: *Workspace, id: SessionId, generation: u64, operation: OperationKey) bool {
        const tab = self.sessionTab(id) orelse return false;
        if (tab.generation != generation or tab.content_owner != .session or operation.owner != .session or !tab.content_owner.session.eql(operation.owner.session)) return false;
        const runtime = tab.runtime orelse return false;
        if (runtime.torn_down) return false;
        for (self.connect_jobs.items) |job| {
            if (!job.ticket.matches(tab.ticket()) or job.cancelled.load(.acquire)) continue;
            const original = job.operation_key orelse return false;
            if (!original.eql(operation)) return false;
            const attached = runtime.acknowledgeAttached(operation);
            // This attempt's creation card is terminal after the host accepts
            // its pane. Later shell exit must not reopen an attaching dialog.
            if (attached) job.progress_dismissed = true;
            return attached;
        }
        return false;
    }

    /// Opens a durable recording without a worker or transport credentials.
    pub fn focusArchive(self: *Workspace, key: []const u8) bool {
        for (self.tabs.items, 0..) |tab, index| if (tab.archive_document) |document| {
            if (std.mem.eql(u8, document.record.descriptor.archive_key, key) and !tab.closing) {
                self.selectTab(index);
                return true;
            }
        };
        return false;
    }

    /// On success this tab owns the entire decoded document and read lease.
    pub fn openArchiveDocument(self: *Workspace, document: *@import("history_archive.zig").Document) !void {
        const descriptor = document.record.descriptor;
        if (self.focusArchive(descriptor.archive_key)) return error.ArchiveAlreadyOpen;
        try self.openArchivedContent(descriptor.entry.host, descriptor.entry.user, &document.timeline, &document.reading);
        const tab = self.tabs.items[self.tabs.items.len - 1];
        tab.archive_document = document;
        if (descriptor.display.title.len > 0 and !std.mem.eql(u8, tab.titleSlice(), descriptor.display.title)) {
            tab.setTitle(descriptor.display.title);
            if (self.model.beginRename(tab.tab_id)) |ticket| self.model.rename(ticket, tab.titleSlice()) catch {} else |_| {}
            self.tab_rebuild_pending = true;
        }
        self.restoreArchiveDisplay(tab);
    }

    pub fn restoreArchiveAppearances(self: *Workspace) void {
        for (self.tabs.items) |tab| if (tab.archive_document != null) self.restoreArchiveDisplay(tab);
    }

    fn restoreArchiveDisplay(self: *Workspace, tab: *SessionTab) void {
        const document = tab.archive_document orelse return;
        const descriptor = document.record.descriptor;
        const terminal = if (tab.terminal) |*view| view else return;
        if (descriptor.manifest_revision == 0) {
            terminal.setArchiveNotice("旧版记录：未保存原布局参数，按可用记录展示");
            return;
        }
        const display = descriptor.display;
        terminal.setGrouped(display.grouped);
        terminal.setTimestampGutter(display.timestamps);
        var fallback = display.font_family == null or display.font_size_px == null or display.line_height == null;
        if (display.font_family) |family| {
            const family_id = if (self.font_family_resolver) |resolve| resolve(family) else 0;
            fallback = fallback or (family_id == 0 and !std.mem.eql(u8, family, "system"));
            const size = display.font_size_px orelse terminal.terminal_font_size;
            const line_height = display.line_height orelse terminal.terminal_line_height;
            if (terminal.terminal_font_family == null or !std.mem.eql(u8, terminal.terminal_font_family.?, family) or terminal.terminal_font_family_id != family_id or terminal.terminal_font_size != size or terminal.terminal_line_height != line_height) {
                terminal.setTypographyFamily(size, line_height, terminal.terminal_font_weight, family, family_id) catch {
                    fallback = true;
                };
                terminal.history_reading_height = 0;
                terminal.root.markLayoutDirty();
            }
        }
        const notice: []const u8 = switch (descriptor.coverage) {
            .partial, .gapped => if (fallback) "记录存在缺口；部分原布局参数不可用，已使用可用样式" else "记录存在缺口，部分输出不可用",
            .retained => if (fallback) "显示保留片段；部分原布局参数不可用，已使用可用样式" else "显示保留的记录片段",
            else => if (fallback) "部分原字体或布局参数不可用，已使用可用样式" else "",
        };
        if (notice.len > 0) terminal.setArchiveNotice(notice);
    }

    /// Opens a durable recording without a worker or transport credentials.
    /// Timeline ownership moves only after all fallible UI setup succeeds.
    pub fn openArchivedSession(self: *Workspace, host: []const u8, user: []const u8, history: *@import("history_replay.zig").Timeline) !void {
        return self.openArchivedContent(host, user, history, null);
    }

    fn openArchivedContent(self: *Workspace, host: []const u8, user: []const u8, history: *@import("history_replay.zig").Timeline, reading: ?*?@import("history_reading.zig").Model) !void {
        if (self.shutting_down) return error.WorkspaceClosed;
        if (history.frames.items.len == 0) return error.EmptyRecording;
        try self.tabs.ensureUnusedCapacity(self.allocator, 1);
        const tab = try self.allocator.create(SessionTab);
        errdefer self.allocator.destroy(tab);
        var snapshot = try HostSnapshot.init(self.allocator, .{ .name = host, .host = host, .user = user });
        errdefer snapshot.deinit();
        var terminal = try TerminalViewNode.mount(self.cx);
        terminal.setTerminalTakeoverHandler(self.terminal_takeover_handler);
        terminal.completion_enabled = self.app_config.completion.enabled;
        errdefer {
            terminal.releaseBuffers(self.cx);
            self.cx.destroyDetached(terminal.root);
        }
        terminal.root.setBackground(self.palette.terminal_bg);
        terminal.setThemeColors(self.palette.fg, self.palette.border, self.palette.accent);
        self.applyTerminalTypography(&terminal) catch {};
        terminal.setCursorStyle(cursorStyle(self.app_config.ui.cursor_style));
        terminal.setTimestampGutter(self.app_config.ui.timestamp_gutter);
        terminal.setInputLineHighlight(self.app_config.ui.input_line_highlight) catch {};
        const ticket = self.identities.newTicket();
        tab.* = .{ .id = ticket.session_id, .tab_id = try tab_ids.allocate(), .content_owner = .{ .history = try history_ids.allocate() }, .generation = ticket.generation, .host_id = 0, .host_index = removed_host_index, .host_snapshot = snapshot, .root = terminal.root, .terminal = terminal, .archived = true };
        try tab.terminal.?.attachSearch(self.scope);
        tab.setTitle(host);
        try self.installTabModel(tab);
        errdefer self.model.completeClose(tab.tab_id, tab.content_owner) catch {};
        try self.terminal_area.appendChild(self.cx.allocator, terminal.root);
        tab.terminal.?.history.deinit();
        tab.terminal.?.history = history.*;
        tab.terminal.?.history.history_id = tab.content_owner.history;
        history.* = @import("history_replay.zig").Timeline.init(history.allocator, history.limit);
        tab.terminal.?.bindArchived();
        if (reading) |prepared| {
            tab.terminal.?.history_reading = prepared.*;
            prepared.* = null;
        }
        self.tabs.appendAssumeCapacity(tab);
        self.rebuildTabBar() catch {};
        self.selectTab(self.tabs.items.len - 1);
        _ = tab.terminal.?.openHistory();
    }

    /// Rename a live or ended tab without changing its host identity.
    pub fn renameTab(self: *Workspace, index: usize, name: []const u8) !void {
        if (index >= self.tabs.items.len) return error.InvalidTab;
        const normalized = try normalizeTabName(name);
        const tab = self.tabs.items[index];
        try self.model.rename(try self.model.beginRename(tab.tab_id), normalized);
        tab.setTitle(self.model.tabs.items[self.model.indexOf(tab.tab_id).?].name());
        self.reveal_active = true;
        try self.rebuildTabBar();
    }

    /// Uses the target tab's owned config rather than its mutable asset index.
    /// This also works after deleting that host from the sidebar.
    pub fn newSessionFromTab(self: *Workspace, index: usize) !void {
        if (index >= self.tabs.items.len) return error.InvalidTab;
        const source = self.tabs.items[index];
        if (source.archived) return error.ArchivedSessionReadOnly;
        const recreate = self.session_bridge.recreate orelse return error.SessionHostUnavailable;
        const previous_group = self.creation_group;
        const previous_output = self.command_output;
        self.creation_group = self.creationGroupFor(source.id);
        self.command_output = null;
        defer {
            self.creation_group = previous_group;
            self.command_output = previous_output;
        }
        try recreate(self.session_bridge.context, source.id);
    }

    pub fn reuseSessionFromTab(self: *Workspace, index: usize) !void {
        if (index >= self.tabs.items.len) return error.InvalidTab;
        const source = self.tabs.items[index];
        if (source.archived or source.closing or source.runtime == null) return error.SessionNotConnected;
        const reuse = self.session_bridge.reuse orelse return error.SessionHostUnavailable;
        const previous_group = self.creation_group;
        const previous_output = self.command_output;
        self.creation_group = self.creationGroupFor(source.id);
        self.command_output = null;
        defer {
            self.creation_group = previous_group;
            self.command_output = previous_output;
        }
        try reuse(self.session_bridge.context, source.id);
    }

    /// Mirror the source's OSC directory into a distinct session. This takes
    /// an owned snapshot under the VT lock before starting the async job.
    /// A missing OSC directory explicitly skips cd; never invent a path or
    /// claim the remote shell has successfully changed directories.
    pub fn duplicateSessionFromTab(self: *Workspace, index: usize) !void {
        if (index >= self.tabs.items.len) return error.InvalidTab;
        const source = self.tabs.items[index];
        if (source.archived) return error.ArchivedSessionReadOnly;
        const previous_group = self.creation_group;
        const previous_color = self.creation_tab_color;
        self.creation_tab_color = source.tab_color;
        const previous_output = self.command_output;
        self.creation_group = self.creationGroupFor(source.id);
        self.command_output = null;
        defer {
            self.creation_group = previous_group;
            self.creation_tab_color = previous_color;
            self.command_output = previous_output;
        }
        if (source.local) {
            const duplicate = self.session_bridge.duplicate_local orelse return error.LocalAdapterUnavailable;
            return duplicate(self.session_bridge.context, source.id);
        }
        const runtime = source.runtime orelse return error.SessionNotConnected;
        if (runtime.torn_down or source.terminal.?.tombstone.state != .active or !runtime.isConnected()) return error.SessionNotConnected;
        const cwd = try runtime.copyCwd(self.allocator);
        defer if (cwd) |path| self.allocator.free(path);
        const input = if (cwd) |path| try lifecycle.mirrorDirectoryInput(self.allocator, path) else null;
        defer if (input) |bytes| self.allocator.free(bytes);
        try self.createSession(source.host_snapshot.?.value, source.host_id, self.hostIndex(source.host_id) orelse removed_host_index, input orelse "");
        if (cwd == null) self.status("镜像会话连接中 · 当前会话未报告 OSC 7 目录，已跳过目录切换");
    }

    /// Reconnect an ended session using the tab's owned host snapshot. The
    /// tombstone tab remains visible while the replacement job is starting,
    /// so a failed reconnect never loses the user's read-only terminal.
    pub fn reconnectTab(self: *Workspace, index: usize) !void {
        if (index >= self.tabs.items.len) return error.InvalidTab;
        const source = self.tabs.items[index];
        if (source.archived) return error.ArchivedSessionReadOnly;
        if (source.local) return error.LocalSessionDoesNotReconnect;
        const retry = self.session_bridge.retry_ssh orelse return error.SessionHostUnavailable;
        try retry(self.session_bridge.context, source.id);
    }

    /// Reuses the original tab, worker/VT and frozen Job. The host has already
    /// allocated this successor; no registry lookup selects another route.
    pub fn retrySshSession(self: *Workspace, id: SessionId, next: OperationKey) !void {
        const tab = self.sessionTab(id) orelse return error.StaleSession;
        if (tab.local or tab.archived or tab.closing or next.owner != .session) return error.LifecycleDoesNotAllowRetry;
        const index = self.model.indexOf(tab.tab_id) orelse return error.StaleSession;
        if (self.model.tabs.items[index].revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        var original: ?*ConnectJob = null;
        for (self.connect_jobs.items) |job| if (job.ticket.matches(tab.ticket())) {
            original = job;
            break;
        };
        const job = original orelse return error.StaleSession;
        const previous = job.operation_key orelse return error.MissingOperation;
        if (tab.runtime) |runtime| {
            const state = runtime.reconnectSnapshot() orelse return error.SessionClosed;
            if (state.key == null or !state.key.?.eql(previous) or (state.phase != .waiting and state.phase != .ended) or state.cleanup != .released) return error.CleanupNotReleased;
        } else if (!job.ready.load(.acquire) or !job.drained or !job.resource_ledger.snapshot().released()) return error.CleanupNotReleased;
        if (job.progress_history.items.len < 6) try job.progress_history.ensureUnusedCapacity(std.heap.c_allocator, 1);
        try job.retained_cleanup.resetReleased();
        const generation = try identity.advance(tab.generation);
        // Reserve every fallible presentation mutation before offering the
        // worker its grant. No old IO is running at this released boundary.
        try self.bindSessionOwner(id, next.owner.session);
        if (job.progress_history.items.len == 6) {
            const removed = job.progress_history.orderedRemove(0);
            job.progress_history_dropped +|= removed.journal.count;
            job.progress_history_dropped +|= removed.journal.dropped;
        }
        job.progress_history.appendAssumeCapacity(.{ .key = previous, .journal = job.progress.snapshot() });
        if (job.automatic_retry_deadline_ns != null) job.connection_attempts += 1 else job.connection_attempts = 1;
        job.automatic_retry_deadline_ns = null;
        job.host_key_bridge.reset();
        job.auth_bridge.resetForAttempt();
        job.cancelled.store(false, .release);
        job.err = null;
        job.cleanup_unknown = false;
        // Existing terminals keep retry progress inline; authentication still
        // uses its protected challenge presenter when required.
        job.progress_dismissed = tab.runtime != null;
        job.operation_key = next;
        tab.generation = generation;
        job.ticket = tab.ticket();
        job.progress.begin(next.attempt_id orelse 0);
        job.ready.store(false, .release);
        tab.failed = false;
        tab.remote_retrying = tab.runtime != null;
        tab.remote_retry_deadline = null;
        if (tab.runtime != null) if (tab.remote_notice) |notice| notice.update(.{ .state = .reconnecting });
        tab.terminal.?.clearPendingPaste();
        tab.terminal.?.paste_confirmation_pending = false;
        if (tab.runtime) |runtime| {
            // The mailbox is single-use and the old native graph is released.
            // A rejected grant is surfaced on the new operation, never turned
            // into a factory error claiming that this Runtime does not exist.
            runtime.requestReconnect(previous, next) catch |err| {
                job.err = err;
                job.ready.store(true, .release);
                tab.failed = true;
                return;
            };
        } else {
            job.resource_ledger.beginAttempt(previous, next) catch |err| {
                job.err = err;
                job.ready.store(true, .release);
                tab.failed = true;
                job.cleanup_unknown = true;
                return;
            };
            job.host_key_store.refresh() catch |err| {
                job.err = err;
                job.ready.store(true, .release);
                tab.failed = true;
                return;
            };
            job.drained = false;
            job.thread = std.Thread.spawn(.{}, @import("../plugins/ssh/connect_job.zig").connectThread, .{job}) catch |err| {
                job.err = err;
                job.ready.store(true, .release);
                return;
            };
        }
        tab.terminal.?.tombstone.state = .reconnecting;
        tab.terminal.?.refreshTombstone();
        self.tab_rebuild_pending = true;
        self.cx.requestRedraw();
    }

    fn reconnectRemoteNotice(raw: *anyopaque, id: u64) void {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        const index = self.tabIndex(id) orelse return;
        self.reconnectTab(index) catch |err| self.statusFailure(@errorName(err));
    }

    fn closeRemoteNotice(raw: *anyopaque, id: u64) void {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        self.requestCloseTab(self.tabIndex(id) orelse return);
    }

    /// Updates only controller facts for the same attempt. Native completions
    /// remain tagged by their captured key, not this Job's later current key.
    pub fn finishSshReconnect(self: *Workspace, id: SessionId, key: OperationKey, failure: ?anyerror) void {
        const tab = self.sessionTab(id) orelse return;
        for (self.connect_jobs.items) |job| {
            if (!job.ticket.matches(tab.ticket()) or job.operation_key == null or !job.operation_key.?.eql(key)) continue;
            job.err = failure;
            job.ready.store(true, .release);
            tab.failed = failure != null;
            self.tab_rebuild_pending = true;
            return;
        }
    }

    pub fn connectionDetailsStore(self: *Workspace, id: SessionId, key: OperationKey) !*@import("../proto/ssh/connection_details.zig").Store {
        const tab = self.sessionTab(id) orelse return error.StaleSession;
        for (self.connect_jobs.items) |job| {
            if (job.ticket.matches(tab.ticket()) and job.operation_key != null and job.operation_key.?.eql(key)) return &job.connection_details;
        }
        return error.StaleOperation;
    }

    fn spawnSessionWithInput(self: *Workspace, host: hosts_mod.HostConfig, host_id: HostId, host_index: usize, initial_input: []const u8, operation: ?OperationKey) !void {
        if (self.shutting_down) return error.WorkspaceClosed;
        try self.tabs.ensureUnusedCapacity(self.allocator, 1);
        try self.connect_jobs.ensureUnusedCapacity(self.allocator, 1);
        try self.startPollLoop();
        const ticket = self.identities.newTicket();
        const job = try ConnectJob.create(ticket, host, self.registry.hosts, self.app_config.*, self.io);
        errdefer job.destroy();
        if (self.pending_shared_connection) |lease| job.shared_connection = lease.retain();
        job.operation_key = operation;
        job.resource_ledger.key = operation;
        job.progress.begin(if (operation) |key| key.attempt_id orelse 0 else 0);
        job.initial_input = try std.heap.c_allocator.dupe(u8, initial_input);
        const tab = try self.allocator.create(SessionTab);
        errdefer self.allocator.destroy(tab);
        var snapshot = try HostSnapshot.init(self.allocator, host);
        errdefer snapshot.deinit();
        var terminal = try TerminalViewNode.mount(self.cx);
        terminal.setTerminalTakeoverHandler(self.terminal_takeover_handler);
        var notice_scope: ?*ui.Scope = null;
        var owned_pane: ?*ui.Node = null;
        var terminal_attached = false;
        errdefer {
            terminal.releaseBuffers(self.cx);
            if (notice_scope) |scope| scope.dispose();
            if (owned_pane) |pane| self.cx.destroyDetached(pane);
            if (!terminal_attached) self.cx.destroyDetached(terminal.root);
        }
        terminal.completion_enabled = self.app_config.completion.enabled;
        terminal.palette_observer = self.command_bridge;
        terminal.input_observer = self.input_bridge;
        terminal.root.setBackground(self.palette.terminal_bg);
        terminal.setThemeColors(self.palette.fg, self.palette.border, self.palette.accent);
        self.applyTerminalTypography(&terminal) catch {};
        terminal.setCursorStyle(cursorStyle(self.app_config.ui.cursor_style));
        terminal.setTimestampGutter(self.app_config.ui.timestamp_gutter);
        terminal.setInputLineHighlight(self.app_config.ui.input_line_highlight) catch {};
        terminal.setOutput(self.cx, "正在连接…") catch {};
        notice_scope = try self.scope.childScope();
        const pane = try ui.box(self.cx, local_styles.pane(), .{});
        owned_pane = pane;
        terminal.root.setStyleInline(self.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
        const notice = try RemoteNotice.View.mount(self.cx, notice_scope.?, pane, .{ .context = self, .session_id = ticket.session_id, .reconnect = reconnectRemoteNotice, .close = closeRemoteNotice });
        try pane.appendChild(self.allocator, terminal.root);
        terminal_attached = true;
        tab.* = .{
            .id = ticket.session_id,
            .tab_id = try tab_ids.allocate(),
            .content_owner = .{ .session = .{ .session_id = @fromBackingInt(ticket.session_id), .generation = ticket.generation } },
            .generation = ticket.generation,
            .host_id = host_id,
            .host_index = host_index,
            .host_snapshot = snapshot,
            .root = pane,
            .remote_notice_scope = notice_scope,
            .remote_notice = notice,
            .terminal = terminal,
        };
        tab.setTitle(host.name);
        try self.installTabModel(tab);
        try tab.terminal.?.attachSearch(self.scope);
        try self.terminal_area.appendChild(self.cx.allocator, pane);
        // After publishing, every failure is represented by this tab. No worker
        // owns a pointer to it, so closing it cannot invalidate a pending job.
        self.tabs.appendAssumeCapacity(tab);
        const tab_index = self.tabs.items.len - 1;
        job.thread = std.Thread.spawn(.{}, @import("../plugins/ssh/connect_job.zig").connectThread, .{job}) catch |err| {
            tab.failed = true;
            job.err = err;
            job.ready.store(true, .release);
            self.connect_jobs.appendAssumeCapacity(job);
            self.rebuildTabBar() catch {};
            self.selectTab(tab_index);
            self.statusFailure(@errorName(err));
            return;
        };
        self.connect_jobs.appendAssumeCapacity(job);
        self.rebuildTabBar() catch {};
        self.selectTab(tab_index);
        self.status("连接中…");
        self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
    }

    fn ignoreCommand(_: ?*anyopaque, _: []const u8, _: bool) void {}

    const ConnectJob = @import("../plugins/ssh/connect_job.zig").ConnectJob;

    /// Jobs stay alive for the workspace lifetime: attached runtimes retain
    /// their job's private IO context for checkpoint writes. The scope destroys
    /// those runtimes before Workspace.cleanup frees the IO contexts.
    fn drainResults(self: *Workspace) void {
        for (self.connect_jobs.items) |job| {
            // Reconnect runs on the existing Runtime thread, not a second
            // ConnectJob.thread. Cancellation must poll that Runtime even
            // while its current auth/handshake has not produced ready.
            const cancelled_runtime = job.cancelled.load(.acquire) and job.runtime_scope_owned and job.runtime != null;
            if (job.drained or job.cleanup_unknown or (!job.ready.load(.acquire) and !cancelled_runtime)) continue;
            if (job.thread) |thread| {
                thread.join();
                job.thread = null;
            }
            const tab = if (!job.cancelled.load(.acquire)) self.findTicket(job.ticket) else null;
            if (tab == null or self.shutting_down) {
                if (job.runtime) |runtime| switch (runtime.releaseStep(null)) {
                    .awaiting => continue,
                    .unknown => {
                        job.cleanup_unknown = true;
                        self.notifyConnectionCleanup(job, .unknown);
                        continue;
                    },
                    .released => if (!job.runtime_scope_owned) runtime.cleanup(),
                };
                // Scope-owned runtimes retain their struct until its single
                // registered destructor. Every owned member is already gone.
                if (!job.runtime_scope_owned) job.runtime = null;
                switch (job.failedCleanupReceipt()) {
                    .awaiting => continue,
                    .unknown => {
                        job.cleanup_unknown = true;
                        self.notifyConnectionCleanup(job, .unknown);
                        continue;
                    },
                    .released => {},
                }
                job.drained = true;
                job.ready.store(true, .release);
                // A cancelled initial connection can keep its tab after the
                // progress sheet closes. Retire its connecting placeholder
                // only once cleanup completes; reconnects retain their output.
                if (!self.shutting_down and job.cancelled.load(.acquire)) {
                    if (self.findTicket(job.ticket)) |cancelled_tab| {
                        if (cancelled_tab.runtime == null) {
                            if (cancelled_tab.terminal) |*terminal| terminal.setOutput(self.cx, "连接已取消") catch {};
                            if (self.active_tab == self.tabIndex(cancelled_tab.id)) self.status("连接已取消");
                        }
                    }
                }
                self.notifyConnectionCleanup(job, .released);
                continue;
            }
            const target = tab.?;
            if (job.err) |err| {
                if (!target.owned_origin and self.session_bridge.retry_ssh != null and job.canAutomaticallyRetry()) {
                    const receipt = job.failedCleanupReceipt();
                    if (receipt == .awaiting) continue;
                    if (receipt == .released) {
                        // Keep transient failures in diagnostics; only an exhausted
                        // attempt publishes failure feedback or replaces terminal text.
                        const delay_ms: i128 = @as(i128, job.connection_attempts) * 500;
                        job.automatic_retry_deadline_ns = @import("../platform/realtime.zig").monotonicNs() + delay_ms * std.time.ns_per_ms;
                        applog.info(.workspace, "connect retry scheduled session={d} attempt={d}/3 delay_ms={d} cause={s}", .{ target.id, job.connection_attempts + 1, delay_ms, @errorName(err) });
                        if (self.session_bridge.failed) |failed| failed(self.session_bridge.context, target.id, target.generation, @errorName(err));
                        job.drained = true;
                        self.notifyConnectionCleanup(job, .released);
                        continue;
                    }
                }
                target.failed = true;
                var failure_buffer: [512]u8 = undefined;
                const failure_title = std.fmt.bufPrint(&failure_buffer, "连接失败: {s}", .{@import("../proto/ssh/handshake_failure.zig").description(err) orelse @errorName(err)}) catch "连接失败";
                var buffer: [768]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{s} · 会话 {d} {s}", .{ target.titleSlice(), target.id, failure_title }) catch failure_title;
                target.terminal.?.setOutput(self.cx, text) catch {};
                if (self.active_tab == self.tabIndex(target.id)) self.status(text);
                self.notifyConnectionFailure(job, failure_title);
                const cleanup_receipt = job.failedCleanupReceipt();
                if (cleanup_receipt != .released) {
                    if (cleanup_receipt == .unknown) job.cleanup_unknown = true;
                    self.notifyConnectionCleanup(job, cleanup_receipt);
                    continue;
                }
                job.drained = true;
                self.notifyConnectionCleanup(job, .released);
            } else if (job.runtime) |runtime| {
                // Register the runtime owner before publishing it to the tab.
                // Workspace is registered first and will clean up the job last.
                self.scope.onCleanup(ConnectJob, job, cleanupJobRuntime) catch {
                    self.failRuntimeAttachment(job, target, "无法安装会话资源");
                    continue;
                };
                job.runtime_scope_owned = true;
                target.runtime = runtime;
                if (target.content_owner == .session) target.terminal.?.setWorkerMenuHandler(target.content_owner.session, .{ .context = self, .request = onTerminalServiceMenu });
                const active = self.active_tab == self.tabIndex(target.id);
                if (active) {
                    target.terminal.?.grid_status_node = self.grid_node;
                    target.terminal.?.grid_label_shown = false;
                }
                runtime.mountTerminal(&target.terminal.?, self.status_node orelse target.terminal.?.root) catch {
                    self.failRuntimeAttachment(job, target, "无法安装终端绘制回调");
                    continue;
                };
                if (active) {
                    self.status("已连接");
                    self.cx.setFocus(target.terminal.?.root);
                }
                job.drained = true;
                if (self.session_bridge.connected) |connected| {
                    connected(self.session_bridge.context, target.id, target.generation);
                } else {
                    // Legacy direct callers have no host controller. Their
                    // successful local installation is the attachment boundary.
                    runtime.markAttached();
                }
            }
            self.rebuildTabBar() catch {};
            self.rebuildSidebar() catch {};
        }
    }

    /// The application controller may drain completed workers at its existing
    /// UI safe point; the Workspace hook also calls the same idempotent drain.
    pub fn pollConnectionResults(self: *Workspace) void {
        self.drainResults();
        self.pollSessionOs();
        self.drainCloseReceipts();
    }

    /// Called on the UI owner, after worker publication. Never touches SSH IO.
    pub fn pollSessionOs(self: *Workspace) void {
        for (self.tabs.items) |tab| {
            if (tab.local or tab.closing) continue;
            const runtime = tab.runtime orelse continue;
            if (tab.remote_notice) |notice| if (runtime.reconnectSnapshot()) |captured| {
                var state = RemoteNotice.Snapshot.fromRuntime(captured, tab.remote_retrying);
                state.buffer_input = self.app_config.ssh.buffer_input;
                if (tab.remote_retry_deadline) |deadline| {
                    const remaining = @max(0, deadline - @import("../platform/realtime.zig").monotonicNs());
                    state.auto_retry_seconds = @intCast(@divTrunc(remaining + std.time.ns_per_s - 1, std.time.ns_per_s));
                }
                if (state.state == .connected) tab.remote_retrying = false;
                if (state.state == .reconnecting) tab.remote_retrying = true;
                notice.update(state);
                // Keep input and contextual actions in step with the same facts,
                // including a failed successor after the first transport loss.
                if (tab.terminal) |*terminal| switch (state.state) {
                    .exited, .disconnected, .retry_failed => {
                        if (terminal.tombstone.state != .ended) {
                            terminal.tombstone.end(state.title());
                            terminal.refreshTombstone();
                        }
                    },
                    .reconnecting => {
                        terminal.tombstone.state = .reconnecting;
                        terminal.refreshTombstone();
                    },
                    .connected => {},
                };
            };
            const detection = runtime.osDetection();
            if (detection.pending) self.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
            const kind = detection.kind;
            if (kind == .unknown or kind == tab.detected_os) continue;
            self.updateSessionOs(tab.content_owner.session, kind, if (tab.host_snapshot) |saved| saved.value else null);
        }
    }

    pub fn updateSessionOs(self: *Workspace, owner: identity.SessionHandle, kind: session_icon.Os, original: ?hosts_mod.HostConfig) void {
        if (kind == .unknown) return;
        for (self.tabs.items) |tab| {
            if (tab.content_owner != .session or !tab.content_owner.session.eql(owner) or tab.closing or tab.detected_os == kind) continue;
            tab.detected_os = kind;
            if (original) |host| {
                @import("session_os_cache.zig").save(self.allocator, self.io, self.hosts_path, host, kind);
                for (self.host_rows.items) |row| {
                    const current = self.registry.hosts[row.host_index];
                    if (current.connection_id == host.connection_id and std.mem.eql(u8, current.host, host.host) and current.port == host.port and std.mem.eql(u8, current.user, host.user)) session_icon.setHostNode(row.view.dot, self.plugins, current.protocolId(), kind);
                }
            }
            for (self.tab_nodes.items) |node| if (node.tab_id == tab.tab_id and !tabShowsHistory(tab)) session_icon.setNode(node.type_icon, kind);
            self.cx.requestRedraw();
        }
    }

    fn drainCloseReceipts(self: *Workspace) void {
        while (self.close_receipts.items.len > 0) {
            const receipt = self.close_receipts.orderedRemove(0);
            if (self.tabIndexById(receipt.tab)) |index| {
                const tab = self.tabs.items[index];
                if (self.model.isCurrentTarget(receipt) or (tab.owned_pending and tab.content_owner.eql(receipt.owner))) self.removeClosedTab(index);
            }
        }
    }

    fn notifyConnectionFailure(self: *Workspace, job: *ConnectJob, message: []const u8) void {
        if (self.findTicket(job.ticket)) |tab| self.reportFailure(tab.content_owner, message);
        if (self.session_bridge.failed) |failed| failed(self.session_bridge.context, job.ticket.session_id, job.ticket.generation, message);
    }

    fn notifyConnectionCleanup(self: *Workspace, job: *ConnectJob, receipt: RuntimeReleaseReceipt) void {
        if (self.session_bridge.cleanup_status) |callback| {
            callback(self.session_bridge.context, job.ticket.session_id, job.ticket.generation, receipt);
        } else if (receipt == .released) {
            if (self.session_bridge.cleanup) |callback| callback(self.session_bridge.context, job.ticket.session_id, job.ticket.generation);
        }
    }

    fn failRuntimeAttachment(self: *Workspace, job: *ConnectJob, tab: *SessionTab, message: []const u8) void {
        tab.failed = true;
        tab.terminal.?.removeFrameHook(self.cx);
        tab.terminal.?.worker = null;
        if (tab.terminal) |*terminal| terminal.root.behavior.interaction.text_input_client = null;
        self.cx.refreshTextInputSession();
        self.notifyConnectionFailure(job, message);
        self.cancelSessionCreation(tab.id);
        if (job.runtime) |runtime| _ = runtime.releaseStep(null);
    }

    fn cleanupJobRuntime(job: *ConnectJob) void {
        if (job.runtime) |runtime| if (!runtime.cleanupReleased()) return;
        job.runtime = null;
    }

    const PollHook = struct {
        workspace: *Workspace,

        fn run(ctx: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
            const hook: *PollHook = @ptrCast(@alignCast(ctx));
            const workspace = hook.workspace;
            if (workspace.shutting_down) return .done;
            workspace.pollHostKeyConfirm();
            for (workspace.host_rows.items) |row| row.view.setOnline(workspace.hostOnline(row.host_index));
            workspace.drainResults();
            workspace.pollSessionOs();
            // Hidden Local panes must keep consuming their own TextSlot so a
            // bounded producer can progress. Only the active pane gets a live
            // input clock; TerminalView additionally checks actual focus.
            for (workspace.tabs.items, 0..) |tab, index| {
                if (tab.terminal != null and tab.content_owner == .session) tab.terminal.?.configureErrorHint(tab.content_owner.session, workspace.app_config.ai.error_hint, workspace.error_hint_handler) catch {};
                if (!tab.local or !tab.local_bound or tab.content_owner != .session) continue;
                _ = tab.terminal.?.refreshTerminalService(tab.content_owner.session, workspace.active_tab == index) catch |err| switch (err) {
                    error.WorkerBusy, error.SnapshotUnavailable => false,
                    else => blk: {
                        applog.warn(.workspace, "Local view refresh: {s}", .{@errorName(err)});
                        break :blk false;
                    },
                };
            }
            workspace.refreshHistoryTabIcons();
            workspace.drainCloseReceipts();
            if (workspace.pollGroupWorkspace()) return .needs_layout;
            if ((workspace.close_others_keep != null or workspace.window_close_request != null) and (workspace.confirming_id == null or workspace.window_close_reconcile)) workspace.continueCloseOthers();
            if (workspace.header_width != @max(0, workspace.cx.viewport.width - 2 * @import("shell_styles.zig").outer)) {
                workspace.reveal_active = true;
                workspace.tab_rebuild_pending = true;
            }
            if (workspace.rename_request) |request| {
                if (workspace.model.indexOf(request.tab) == null) _ = workspace.cancelRenameTab();
            }
            workspace.flushRename() catch |err| applog.err(.ui, "rename dialog: {s}", .{@errorName(err)});
            if (workspace.autoScrollDrag()) return .needs_layout;
            if (workspace.tab_rebuild_pending and !workspace.model.dragging) {
                workspace.tab_rebuild_pending = false;
                workspace.renderTabBar() catch |err| applog.err(.ui, "tab-bar rebuild: {s}", .{@errorName(err)});
                return .needs_layout;
            }
            if (workspace.picker_view) |view| if (view.dirty) {
                view.flush() catch |err| applog.err(.ui, "tab picker: {s}", .{@errorName(err)});
                return .needs_layout;
            };
            // A canceled job still needs polling after its tab has disappeared.
            for (workspace.connect_jobs.items) |job| {
                if ((!job.drained and !job.cleanup_unknown) or job.host_key_bridge.pending()) {
                    workspace.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
                    break;
                }
            }
            return .done;
        }
    };

    fn startPollLoop(self: *Workspace) !void {
        if (self.poll_hook != null) return;
        const hook = try self.allocator.create(PollHook);
        errdefer self.allocator.destroy(hook);
        hook.* = .{ .workspace = self };
        try self.cx.addAfterLayoutHook(hook, PollHook.run);
        self.poll_hook = hook;
    }
};

pub fn cleanupRuntime(runtime: *SessionRuntime) void {
    runtime.cleanup();
}

/// Confirm-card key handler: Esc cancels the pending close. Registered as
/// the card's on_key_down, so it also fires when a focused control inside
/// the card (its buttons) is the key event target (bubble phase).
fn onCloseConfirmKeyDown(key: ui.events.KeyCode, _: ui.events.Modifiers, context: ?*anyopaque) ui.events.EventResult {
    const self: *Workspace = @ptrCast(@alignCast(context orelse return .ignored));
    if (key != .escape) return .ignored;
    self.onCancelConfirm();
    return .handled;
}

fn matchesFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (haystack[0 .. haystack.len - needle.len + 1], 0..) |_, index| {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

/// Shared handle for click trampolines; UI-thread only.
pub var current_workspace: ?*Workspace = null;

test "recent tab input leaves plain Tab and higher priority input untouched" {
    const allocator = std.testing.allocator;
    // Only the input gate is exercised; reaching presentation would touch
    // uninitialised view fields and fail rather than silently switch a tab.
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.external_auth = null;
    workspace.allocator = allocator;
    workspace.rename_editor = null;
    workspace.rename_request = null;
    workspace.picker = .{};
    workspace.model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) };
    defer workspace.model.deinit();
    workspace.confirming_id = null;
    workspace.host_key_job = null;
    workspace.auth_job = null;
    workspace.active_tab = null;
    workspace.tabs = .empty;
    const control: ui.events.Modifiers = .{ .ctrl = true };
    try std.testing.expectEqual(ui.events.EventResult.ignored, workspace.handleTabKey(.tab, .{}));
    try std.testing.expectEqual(ui.events.EventResult.ignored, workspace.handleTabKey(.tab, .{ .ctrl = true, .alt = true }));
    workspace.picker.open = true;
    workspace.picker_view = null;
    try std.testing.expectEqual(ui.events.EventResult.ignored, workspace.handleTabKey(.tab, control));
    workspace.picker.open = false;
    workspace.confirming_id = @fromBackingInt(1);
    try std.testing.expectEqual(ui.events.EventResult.ignored, workspace.handleTabKey(.tab, control));
    workspace.confirming_id = null;
    var tab: SessionTab = undefined;
    tab.terminal = @as(TerminalViewNode, undefined);
    var preedit = [_]u8{'x'};
    tab.terminal.?.preedit = &preedit;
    var tabs = [_]*SessionTab{&tab};
    workspace.tabs.items = &tabs;
    workspace.tabs.capacity = tabs.len;
    workspace.active_tab = 0;
    try std.testing.expectEqual(ui.events.EventResult.ignored, workspace.handleTabKey(.tab, control));
    tab.terminal.?.preedit = null;
    tab.terminal.?.local_editor.active = true;
    try std.testing.expectEqual(ui.events.EventResult.ignored, workspace.handleTabKey(.tab, control));
    try std.testing.expect(workspace.model.recent_cursor == null);
}

test "first tab resizes an already laid out empty title strip" {
    const allocator = std.testing.allocator;
    var cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const FractionalMeasure = struct {
        fn width(_: [*]const u8, _: usize, _: f32, _: u16, _: bool) f32 {
            return 52.676; // The saved Local title's fractional-width boundary.
        }
    };
    cx.text.measure_fn = FractionalMeasure.width;
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const controls = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 46 }, .direction = .row, .align_items = .center, .gap = 6 }, .{});
    try root.appendChild(allocator, controls);
    const strip = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 6 }, .{});
    try controls.appendChild(allocator, strip);
    const config: config_mod.Config = .{};
    var workspace: Workspace = .{
        .allocator = allocator,
        .cx = cx,
        .scope = scope,
        .io = std.testing.io,
        .app_config = &config,
        .palette = Palette.fromTheme(),
        .registry = .{ .arena = std.heap.ArenaAllocator.init(allocator), .hosts = &.{} },
        .hosts_path = "",
        .sidebar_list = root,
        .tab_bar = strip,
        .model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) },
        .terminal_area = root,
        .empty_state = root,
    };
    defer {
        scope.dispose();
        for (workspace.click_ctxs.items) |cell| allocator.destroy(cell);
        workspace.click_ctxs.deinit(allocator);
        workspace.tab_nodes.deinit(allocator);
        workspace.strip_advances.deinit(allocator);
        workspace.strip_widths.deinit(allocator);
        workspace.tabs.deinit(allocator);
        workspace.picker.deinit(allocator);
        workspace.model.deinit();
        workspace.registry.arena.deinit();
    }
    cx.setViewport(1440, 900);
    try workspace.renderTabBar();
    cx.layout();
    try std.testing.expectEqual(@as(f32, 0), strip.globalRect().w);

    const tab_id: identity.TabId = @fromBackingInt(1);
    const owner: identity.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(91) } };
    var tab: SessionTab = .{ .id = 91, .tab_id = tab_id, .content_owner = owner, .host_id = 1, .host_index = 0, .host_snapshot = undefined, .root = root, .terminal = undefined };
    tab.setTitle("Local Terminal");
    try workspace.model.append(tab_id, owner, tab.titleSlice());
    try workspace.tabs.append(allocator, &tab);
    try workspace.renderTabBar();
    cx.layout();
    const width = workspace.strip_geometry.content;
    try std.testing.expect(width >= tab_layout.minimum);
    try std.testing.expectApproxEqAbs(width, strip.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(width, workspace.strip_root.?.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(width, workspace.strip_viewport.?.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(tab_styles.height, workspace.tab_nodes.items[0].node.globalRect().h, 0.01);
    const tab_rect = workspace.tab_nodes.items[0].node.globalRect();
    const title_rect = workspace.tab_nodes.items[0].label.globalRect();
    try std.testing.expect(title_rect.w >= @as(f32, 52.676));
    try std.testing.expectEqual(tab_styles.title_font, workspace.tab_nodes.items[0].label.getText().?.font_size);
    try std.testing.expectEqual(tab_styles.title_weight, workspace.tab_nodes.items[0].label.getText().?.font_weight);
    const close_rect = workspace.tab_nodes.items[0].close.globalRect();
    try std.testing.expect(title_rect.x + title_rect.w <= close_rect.x - 6);
    try std.testing.expectApproxEqAbs(tab_rect.x + tab_rect.w - 26, close_rect.x, 0.01);
    try std.testing.expectApproxEqAbs(tab_rect.y + (tab_styles.height - 20) / 2, close_rect.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), close_rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), close_rect.h, 0.01);
    const Sink = struct {
        calls: usize = 0,
        tab: ?identity.TabId = null,
        fn close(raw: ?*anyopaque, id: identity.TabId, _: identity.ContentOwner) CloseResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.tab = id;
            return .awaiting;
        }
    };
    var sink: Sink = .{};
    workspace.close_bridge = .{ .context = &sink, .request_close = Sink.close };
    cx.handleMouseDown(close_rect.x + 10, close_rect.y + 10, .{});
    cx.handleMouseUp(close_rect.x + 10, close_rect.y + 10);
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqual(tab_id, sink.tab.?);
    try std.testing.expect(tab.closing);
    try std.testing.expect(workspace.drag_binding == null);
    try std.testing.expect(workspace.rename_request == null);
    try std.testing.expectEqual(@as(?usize, null), workspace.active_tab);
}

test "Local presentation has independent owners and keeps ended output beneath its banner" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const strip = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 46 }, .flex_shrink = 0 }, .{});
    try root.appendChild(allocator, strip);
    const area = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .column }, .{});
    try root.appendChild(allocator, area);
    const empty = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .position = .absolute }, .{});
    try area.appendChild(allocator, empty);
    const sidebar = try ui.box(cx, .{ .display = .none }, .{});
    try root.appendChild(allocator, sidebar);
    var config: config_mod.Config = .{};
    config.ui.timestamp_gutter = true;
    const workspace = try allocator.create(Workspace);
    workspace.* = .{
        .allocator = allocator,
        .cx = cx,
        .scope = scope,
        .io = std.testing.io,
        .app_config = &config,
        .palette = Palette.fromTheme(),
        .registry = .{ .arena = std.heap.ArenaAllocator.init(allocator), .hosts = &.{} },
        .hosts_path = "",
        .sidebar_list = sidebar,
        .tab_bar = strip,
        .model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) },
        .terminal_area = area,
        .empty_state = empty,
    };
    try scope.onCleanup(Workspace, workspace, Workspace.cleanup);
    cx.setViewport(1194, 800);
    const CommandSink = struct {
        calls: usize = 0,
        fn command(raw: ?*anyopaque, text: []const u8, executed: bool) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (executed and std.mem.eql(u8, text, "@grp Acceptance")) self.calls += 1;
        }
    };
    var command_sink: CommandSink = .{};
    workspace.command_bridge = .{ .context = &command_sink, .on_command = CommandSink.command };
    const first_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41) };
    const second_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(42) };
    const first = try workspace.createLocalSessionDirect(first_owner);
    const local_command_observer = workspace.sessionTab(first).?.terminal.?.palette_observer orelse return error.LocalCommandObserverMissing;
    local_command_observer.on_command(local_command_observer.context, "@grp Acceptance", true);
    try std.testing.expectEqual(@as(usize, 1), command_sink.calls);
    try std.testing.expect(workspace.sessionTab(first).?.terminal.?.local_state.timestamp_gutter);
    config.ui.timestamp_gutter = false;
    const second = try workspace.createLocalSessionDirect(second_owner);
    try std.testing.expect(!workspace.sessionTab(second).?.terminal.?.local_state.timestamp_gutter);
    try std.testing.expect(first != second);
    const MenuSink = struct {
        calls: usize = 0,
        index: ?usize = null,
        anchor: ui.ComputedRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        fn fire(raw: ?*anyopaque, trigger: MenuBridge.Trigger, _: usize, index: ?usize, _: bool, anchor: ui.ComputedRect) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (trigger != .terminal_middle_click) return;
            self.calls += 1;
            self.index = index;
            self.anchor = anchor;
        }
    };
    var menu_sink: MenuSink = .{};
    workspace.menu_bridge = .{ .context = &menu_sink, .fire = MenuSink.fire };
    // The second pane is active, but the captured first owner stays first.
    Workspace.onTerminalServiceMenu(workspace, first_owner, 213, 47);
    try std.testing.expectEqual(@as(usize, 1), menu_sink.calls);
    try std.testing.expectEqual(@as(?usize, 0), menu_sink.index);
    try std.testing.expectEqual(ui.ComputedRect{ .x = 213, .y = 47, .w = 0, .h = 0 }, menu_sink.anchor);
    Workspace.onTerminalServiceMenu(workspace, try first_owner.nextGeneration(), 99, 99);
    try std.testing.expectEqual(@as(usize, 1), menu_sink.calls);
    try std.testing.expect(workspace.tabs.items[0].tab_id != workspace.tabs.items[1].tab_id);
    const tab = workspace.sessionTab(second).?;
    try std.testing.expect(tab.local and tab.host_snapshot == null);
    try std.testing.expect(tab.content_owner.eql(.{ .session = second_owner }));
    try std.testing.expect(workspace.tabHost(1) == null);
    cx.layout();
    const pane = tab.root.globalRect();
    const starting = tab.local_banner.?.globalRect();
    try std.testing.expectApproxEqAbs(pane.x + 16, starting.x, 0.1);
    try std.testing.expectApproxEqAbs(pane.y + 16, starting.y, 0.1);
    try std.testing.expectApproxEqAbs(pane.w - 32, starting.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 64), starting.h, 0.1);
    try std.testing.expectApproxEqAbs(pane.y, tab.terminal.?.root.globalRect().y, 0.1);
    workspace.updateLocalState(second, .failed, "无法启动 /bin/zsh · EACCES");
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 64), tab.local_banner.?.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(pane.y + 64, tab.terminal.?.root.globalRect().y, 0.1);
    try std.testing.expect(tab.local_retry.?.style.display != .none);
    try std.testing.expectEqualStrings("本地终端启动失败", tab.local_message.?.getText().?.content);
    try std.testing.expect(std.mem.indexOf(u8, tab.local_detail.?.getText().?.content, "EACCES") != null);
    try std.testing.expect(tab.local_cancel.?.style.display == .none);
    try workspace.renameTab(1, "我的终端");
    workspace.updateLocalState(second, .exited, "本地 zsh 已退出 · exit 0");
    try std.testing.expectEqualStrings("我的终端", workspace.model.tabs.items[1].name());
    try std.testing.expectEqualStrings("本地终端已退出", tab.local_message.?.getText().?.content);
    try std.testing.expectEqualStrings("历史输出仍可查看，继续使用请新建终端 · 退出码 0", tab.local_detail.?.getText().?.content);
    try std.testing.expect(tab.local_new.?.style.display != .none);
    try std.testing.expect(tab.local_close.?.style.display != .none);
    try std.testing.expect(tab.local_retry.?.style.display == .none);
    const NewSink = struct {
        fn create(raw: ?*anyopaque, _: ?[]const u8) !void {
            const calls: *usize = @ptrCast(@alignCast(raw.?));
            calls.* += 1;
        }
    };
    var new_calls: usize = 0;
    workspace.session_bridge = .{ .context = &new_calls, .create_local = NewSink.create };
    // Rebuilding tabs must not free the still visible pane's callback context.
    try workspace.renderTabBar();
    try workspace.renderTabBar();
    tab.local_new.?.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), new_calls);
    workspace.removeClosedTab(1);
    try std.testing.expectEqual(@as(usize, 1), workspace.tabs.items.len);
    try std.testing.expectEqual(first, workspace.tabs.items[0].id);
}

test "rebuilt tab bar invalidates older click cells" {
    // Contract for the trampoline guard: tab click cells carry the bar
    // generation they were built for; a rebuild bumps the workspace
    // generation so in-flight clicks routed through removed nodes become
    // no-ops instead of dereferencing freed/stale state (the selectTab
    // SIGSEGV on tab close).
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.external_auth = null;
    workspace.tab_generation = 2;
    const live_cell: ClickCtx = .{ .workspace = undefined, .index = 0, .tab_generation = 2 };
    const stale_cell: ClickCtx = .{ .workspace = undefined, .index = 0, .tab_generation = 1 };
    try std.testing.expect(!workspace.isStaleTabCell(&live_cell));
    try std.testing.expect(workspace.isStaleTabCell(&stale_cell));
}

test "tab title validation trims whitespace and rejects unusable names" {
    try std.testing.expectEqualStrings("prod", try normalizeTabName("  prod\t"));
    try std.testing.expectError(error.EmptyName, normalizeTabName(" \t\n"));
    try std.testing.expectError(error.InvalidName, normalizeTabName("prod\nnode"));
    var oversized: [65]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectError(error.NameTooLong, normalizeTabName(&oversized));
}

test "reconnect lifecycle is ended-only and rolls back after spawn failure" {
    // Workspace.reconnectTab must never start a second transport for an
    // active/reconnecting tab.  Once the replacement spawn fails, the
    // read-only tombstone is restored to an ended state so the user can try
    // again and the original terminal remains available.
    var tombstone: Tombstone = .{};
    try std.testing.expect(!tombstone.beginReconnect());

    tombstone.end("connection lost");
    try std.testing.expect(tombstone.beginReconnect());
    try std.testing.expect(!tombstone.beginReconnect());

    // This is the rollback performed by reconnectTab's spawnSession error
    // path.  It must make the reconnect action reachable again, rather than
    // leaving the source tab permanently in "正在重连…".
    tombstone.end("reconnect failed");
    try std.testing.expectEqual(@TypeOf(tombstone.state).ended, tombstone.state);
    try std.testing.expect(tombstone.canReconnect());
    try std.testing.expectEqualStrings("重新连接", tombstone.reconnectLabel());
}

test "reconnect uses an owned host snapshot after source storage changes" {
    const source = hosts_mod.HostConfig{
        .name = "original",
        .host = "host.example",
        .user = "alice",
        .password = "secret",
        .jump_chain = &.{"bastion.example"},
    };
    var snapshot = try HostSnapshot.init(std.testing.allocator, source);
    defer snapshot.deinit();

    // Simulate the registry/asset being edited or removed while reconnect is
    // queued.  The queued operation must continue to target its retained
    // values, rather than reading a mutable host-index entry.
    try std.testing.expectEqualStrings("original", snapshot.value.name);
    try std.testing.expectEqualStrings("host.example", snapshot.value.host);
    try std.testing.expectEqualStrings("alice", snapshot.value.user);
    try std.testing.expectEqualStrings("secret", snapshot.value.password.?);
    try std.testing.expectEqualStrings("bastion.example", snapshot.value.jump_chain[0]);
}

test "connection job resolves only persistent route IDs including same named hops" {
    var target: hosts_mod.HostConfig = .{ .connection_id = @fromBackingInt(10), .revision = 2, .name = "target", .host = "target.test", .user = "test", .route = &.{ @fromBackingInt(21), @fromBackingInt(20) }, .jump_chain = &.{ "stale display", "stale display" } };
    const registry = [_]hosts_mod.HostConfig{
        .{ .connection_id = @fromBackingInt(20), .revision = 3, .name = "same", .host = "first.test", .user = "jump", .strict_host_key_checking = false },
        .{ .connection_id = @fromBackingInt(21), .revision = 4, .name = "same", .host = "second.test", .user = "jump" },
    };
    const hops = try Workspace.ConnectJob.resolvedHops(std.testing.allocator, target, &registry);
    defer std.testing.allocator.free(hops);
    try std.testing.expectEqual(@as(usize, 2), hops.len);
    try std.testing.expectEqualStrings("second.test", hops[0].host);
    try std.testing.expectEqualStrings("first.test", hops[1].host);
    try std.testing.expectEqual(@as(u64, 4), hops[0].revision);
    try std.testing.expect(!hops[1].strict_host_key_checking);
    target.route = &.{@fromBackingInt(22)};
    target.jump_chain = &.{"same"};
    try std.testing.expectError(error.MissingRouteReference, Workspace.ConnectJob.resolvedHops(std.testing.allocator, target, &registry));
    target.route = &.{};
    try std.testing.expectError(error.UnmigratedRoute, Workspace.ConnectJob.resolvedHops(std.testing.allocator, target, &registry));
}

test "connection job runtime target retains the actual host operation and frozen identity" {
    const key: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(99), .generation = 4 } }, .operation_id = 81, .attempt_id = 3 };
    var job: Workspace.ConnectJob = undefined;
    job.ticket = .{ .session_id = 7, .generation = 1 };
    job.operation_key = key;
    job.initial_input = null;
    job.progress = .{};
    job.progress.begin(3);
    job.host_snapshot = try HostSnapshot.init(std.testing.allocator, .{ .connection_id = @fromBackingInt(10), .revision = 8, .name = "target", .host = "target.test", .user = "target", .auth_mode = .password, .strict_host_key_checking = false, .route = &.{@fromBackingInt(20)} });
    defer job.host_snapshot.deinit();
    job.jump_snapshot = try lifecycle.Snapshot([]const hosts_mod.HostConfig).init(std.testing.allocator, &.{.{ .connection_id = @fromBackingInt(20), .revision = 6, .name = "jump", .host = "hop.test", .user = "jump", .strict_host_key_checking = true }});
    defer job.jump_snapshot.deinit();
    const target = @import("../plugins/ssh/connect_job.zig").runtimeTarget(&job);
    try std.testing.expect(target.operation_key.?.eql(key));
    try std.testing.expectEqualDeep(identity.AssetOwner{ .id = @fromBackingInt(10), .revision = 8 }, target.source_owner.?);
    try std.testing.expect(!target.strict_host_key_checking);
    try std.testing.expectEqual(hosts_mod.AuthMode.password, target.auth_mode);
    try std.testing.expectEqualSlices(identity.ConnectionId, &.{@fromBackingInt(20)}, target.route);
    try std.testing.expectEqual(@as(u64, 6), target.jump_hosts[0].revision);
    try std.testing.expect(target.jump_hosts[0].strict_host_key_checking);
    try std.testing.expect(target.keyboard_bridge.? == &job.auth_bridge);
    var options_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer options_arena.deinit();
    const options = try @import("session_runtime.zig").prepareConnectionOptions(options_arena.allocator(), .{}, target, .session);
    try std.testing.expectEqual(@as(usize, 2), options.len);
    for (options, 0..) |option, hop| {
        const observer = option.progress_observer.?;
        observer.callback(observer.context, .{ .attempt = 3, .hop = hop, .hop_count = 2, .host = option.host, .port = option.port, .phase = .transport, .status = .started });
    }
    const recorded = job.progress.snapshot();
    try std.testing.expectEqual(@as(usize, 2), recorded.count);
    try std.testing.expectEqualStrings("hop.test", recorded.entries[0].hostSlice());
    try std.testing.expectEqualStrings("target.test", recorded.entries[1].hostSlice());
    job.host_snapshot.value.connection_id = @fromBackingInt(0);
    job.operation_key = null;
    const legacy = @import("../plugins/ssh/connect_job.zig").runtimeTarget(&job);
    try std.testing.expect(legacy.source_owner == null);
    try std.testing.expect(legacy.operation_key == null);
    var unused: Workspace = undefined;
    try std.testing.expectError(error.InvalidOperation, unused.createSessionDirectForOperation(job.host_snapshot.value, 7, 0, "", .{ .owner = .app, .operation_id = 1 }));
}

test "SSH attachment gate rejects stale operation generation and cancelled jobs" {
    const handle: identity.SessionHandle = .{ .session_id = @fromBackingInt(99), .generation = 4 };
    const key: OperationKey = .{ .owner = .{ .session = handle }, .operation_id = 81, .attempt_id = 3 };
    var worker: @import("../vt/ssh_worker.zig").SshWorker = undefined;
    worker.presentation_attached = .init(false);
    var native_runtime: @import("session_runtime.zig").SessionRuntime = undefined;
    native_runtime.torn_down = false;
    native_runtime.worker = &worker;
    var worker_thread: @import("../vt/ssh_worker_thread.zig").Thread = undefined;
    worker_thread.reconnect_control = @import("../vt/reconnect.zig").Control.init(key);
    worker_thread.worker = &worker;
    native_runtime.thread = &worker_thread;
    var runtime = @import("../plugins/ssh/runtime_binding.zig").borrow(&native_runtime);
    var tab: SessionTab = undefined;
    tab.id = 7;
    tab.generation = 1;
    tab.content_owner = .{ .session = handle };
    tab.runtime = &runtime;
    var job: Workspace.ConnectJob = undefined;
    job.ticket = tab.ticket();
    job.operation_key = key;
    job.cancelled = .init(false);
    var tabs = [_]*SessionTab{&tab};
    var jobs = [_]*Workspace.ConnectJob{&job};
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.external_auth = null;
    workspace.tabs = .empty;
    workspace.tabs.items = &tabs;
    workspace.tabs.capacity = tabs.len;
    workspace.connect_jobs = .empty;
    workspace.connect_jobs.items = &jobs;
    workspace.connect_jobs.capacity = jobs.len;
    var stale = key;
    stale.operation_id += 1;
    try std.testing.expect(!workspace.acknowledgeSessionAttached(tab.id, tab.generation, stale));
    try std.testing.expect(!workspace.acknowledgeSessionAttached(tab.id, tab.generation + 1, key));
    try std.testing.expect(!worker.presentation_attached.load(.acquire));
    job.cancelled.store(true, .release);
    try std.testing.expect(!workspace.acknowledgeSessionAttached(tab.id, tab.generation, key));
    job.cancelled.store(false, .release);
    try std.testing.expect(workspace.acknowledgeSessionAttached(tab.id, tab.generation, key));
    try std.testing.expect(worker.presentation_attached.load(.acquire));
    try std.testing.expect(job.progress_dismissed);
    worker.presentation_attached.store(false, .release);
    try std.testing.expect(workspace.nextConnectionPresentationKey() == null);
}

test "SSH cancellation reopens an installed jobs cleanup drain only once" {
    var runtime: SessionRuntime = undefined;
    var job: Workspace.ConnectJob = undefined;
    job.ticket = .{ .session_id = 7, .generation = 1 };
    job.cancelled = .init(false);
    job.drained = true;
    job.runtime = &runtime;
    job.host_key_bridge = .{};
    job.auth_bridge = .{};
    var jobs = [_]*Workspace.ConnectJob{&job};
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.external_auth = null;
    workspace.connect_jobs = .empty;
    workspace.connect_jobs.items = &jobs;
    workspace.connect_jobs.capacity = jobs.len;
    workspace.host_key_job = null;
    workspace.auth_job = null;
    workspace.cancelSessionCreation(7);
    try std.testing.expect(!job.drained);
    job.drained = true; // the real destructor has subsequently been drained
    workspace.cancelSessionCreation(7);
    try std.testing.expect(job.drained);
}

test "cancelled initial connection retires placeholder after cleanup without replacing reconnect output" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const terminal = try TerminalViewNode.mount(cx);
    cx.root = terminal.root;
    var tab: SessionTab = undefined;
    tab.id = 7;
    tab.generation = 1;
    tab.runtime = null;
    tab.terminal = terminal;
    defer tab.terminal.?.releaseBuffers(cx);
    var job: Workspace.ConnectJob = undefined;
    job.ticket = tab.ticket();
    job.cancelled = .init(true);
    job.ready = .init(false);
    job.drained = false;
    job.cleanup_unknown = false;
    job.runtime_scope_owned = false;
    job.runtime = null;
    job.thread = null;
    job.resource_ledger = try ResourceLedger.init(null, 1);
    var jobs = [_]*Workspace.ConnectJob{&job};
    var tabs = [_]*SessionTab{&tab};
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.cx = cx;
    workspace.allocator = allocator;
    workspace.connect_jobs = .empty;
    workspace.connect_jobs.items = &jobs;
    workspace.tabs = .empty;
    workspace.tabs.items = &tabs;
    workspace.shutting_down = false;
    workspace.active_tab = 0;
    workspace.status_node = null;
    workspace.command_output = null;
    workspace.status_feedback = null;
    workspace.session_bridge = .{};
    try tab.terminal.?.setOutput(cx, "正在连接…");
    workspace.drainResults();
    try std.testing.expectEqualStrings("正在连接…", tab.terminal.?.row_texts[0]);
    job.ready.store(true, .release);
    workspace.drainResults();
    try std.testing.expect(job.drained);
    try std.testing.expectEqualStrings("连接已取消", tab.terminal.?.row_texts[0]);
    // A completed older generation must not change the replacement tab.
    try tab.terminal.?.setOutput(cx, "new attempt");
    tab.generation += 1;
    job.drained = false;
    workspace.drainResults();
    try std.testing.expectEqualStrings("new attempt", tab.terminal.?.row_texts[0]);
    // Cancelled reconnects keep their already installed terminal transcript.
    tab.generation = job.ticket.generation;
    var runtime: SessionRuntime = undefined;
    tab.runtime = &runtime;
    job.drained = false;
    try tab.terminal.?.setOutput(cx, "existing transcript");
    workspace.drainResults();
    try std.testing.expectEqualStrings("existing transcript", tab.terminal.?.row_texts[0]);
}

test "connection job preserves known host load errors instead of inventing unknown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "known_hosts", .data = "malformed\n" });
    try std.testing.expectError(error.InvalidKnownHosts, Workspace.ConnectJob.loadHostKeyStore(std.testing.allocator, std.testing.io, tmp.dir, "known_hosts"));
    var missing = try Workspace.ConnectJob.loadHostKeyStore(std.testing.allocator, std.testing.io, tmp.dir, "missing_known_hosts");
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.records.items.len);
    try std.testing.expectEqualStrings("missing_known_hosts", missing.persist_path.?);
}

test "connection job loads the selected OpenSSH path without migrating private TSV trust" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(std.testing.io, &home_buffer);
    const PathsType = @import("../config/paths.zig").Paths;
    var paths = try PathsType.fromHome(std.testing.allocator, home_buffer[0..home_len]);
    defer paths.deinit();
    const legacy = "host.test\t22\tssh-ed25519\tSHA256:legacy-fingerprint-only\n";
    try tmp.dir.createDirPath(std.testing.io, ".zerowork");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zerowork/known_hosts", .data = legacy });
    var missing = try Workspace.ConnectJob.loadHostKeyStore(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), paths.known_hosts);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.records.items.len);
    try std.testing.expectEqualStrings(paths.known_hosts, missing.persist_path.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, ".ssh/known_hosts", .{}));
    const preserved = try tmp.dir.readFileAlloc(std.testing.io, ".zerowork/known_hosts", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings(legacy, preserved);

    // Even an explicitly selected file cannot silently reinterpret old hashes
    // as OpenSSH key bodies or turn them into a trusted/unknown classification.
    try tmp.dir.createDirPath(std.testing.io, ".ssh");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".ssh/known_hosts", .data = legacy });
    try std.testing.expectError(error.LegacyTrustMigrationRequired, Workspace.ConnectJob.loadHostKeyStore(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), paths.known_hosts));
    const rejected = try tmp.dir.readFileAlloc(std.testing.io, ".ssh/known_hosts", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(rejected);
    try std.testing.expectEqualStrings(legacy, rejected);

    const instance_dir = try std.fs.path.join(std.testing.allocator, &.{ home_buffer[0..home_len], "isolated-instance" });
    defer std.testing.allocator.free(instance_dir);
    var isolated = try PathsType.fromDirectory(std.testing.allocator, instance_dir);
    defer isolated.deinit();
    var isolated_missing = try Workspace.ConnectJob.loadHostKeyStore(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), isolated.known_hosts);
    defer isolated_missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), isolated_missing.records.items.len);
    try std.testing.expectEqualStrings(isolated.known_hosts, isolated_missing.persist_path.?);
}

test "revealing an overflow tab refreshes arrows for the actual viewport" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.external_auth = null;
    workspace.allocator = allocator;
    workspace.cx = cx;
    workspace.model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) };
    defer workspace.model.deinit();
    workspace.strip_widths = .empty;
    defer workspace.strip_widths.deinit(allocator);
    workspace.strip_advances = .empty;
    defer workspace.strip_advances.deinit(allocator);
    workspace.font_family_resolver = null;
    workspace.strip_offset = 0;
    for (1..11) |id| try workspace.model.append(@fromBackingInt(id), .{ .session = .{ .session_id = @fromBackingInt(id) } }, "long terminal session title");
    cx.setViewport(860, 480);
    workspace.reveal_active = true;
    try workspace.measureTabs();
    try std.testing.expectEqual(tab_layout.Mode.overflow, workspace.strip_geometry.mode);
    try std.testing.expect(workspace.strip_offset > 0);
    try std.testing.expect(workspace.strip_geometry.can_scroll_left);
    try std.testing.expect(!workspace.strip_geometry.can_scroll_right);

    try workspace.model.activate(@fromBackingInt(1));
    workspace.reveal_active = true;
    try workspace.measureTabs();
    try std.testing.expectEqual(@as(f32, 0), workspace.strip_offset);
    try std.testing.expect(!workspace.strip_geometry.can_scroll_left);
    try std.testing.expect(workspace.strip_geometry.can_scroll_right);

    try workspace.model.activate(@fromBackingInt(5));
    workspace.reveal_active = true;
    try workspace.measureTabs();
    try std.testing.expect(workspace.strip_geometry.can_scroll_left);
    try std.testing.expect(workspace.strip_geometry.can_scroll_right);
    const offset = workspace.strip_offset;
    try workspace.measureTabs();
    try std.testing.expectEqual(offset, workspace.strip_offset);
}

test "authentication routes frozen requests despite tab changes and rejects late replies" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const key: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(91), .generation = 3 } }, .operation_id = 201, .attempt_id = 2 };
    var tab: SessionTab = undefined;
    tab.id = 17;
    tab.generation = 4;
    var job: Workspace.ConnectJob = undefined;
    job.ticket = tab.ticket();
    job.operation_key = key;
    job.cancelled = .init(false);
    job.ready = .init(false);
    job.auth_bridge = .{};
    job.host_key_bridge = .{};
    job.host_snapshot = try HostSnapshot.init(std.testing.allocator, .{ .name = "frozen", .host = "frozen-hop.test", .user = "operator", .password = "private-password", .key_passphrase = "private-passphrase", .totp_secret = "JBSWY3DPEHPK3PXP" });
    defer job.host_snapshot.deinit();
    job.jump_snapshot = try lifecycle.Snapshot([]const hosts_mod.HostConfig).init(std.testing.allocator, &.{.{ .name = "upstream", .host = "other.test", .user = "other" }});
    defer job.jump_snapshot.deinit();
    defer job.auth_bridge.cancel();
    const request = try job.auth_bridge.offerChallenge(.{
        .key = key,
        .hop_index = 1,
        .kind = .keyboard_interactive,
        .endpoint_identity = .{ .host = "frozen-hop.test", .user = "operator" },
        .prompts = &.{.{ .text = "Verification code:", .echo = false }},
        .presentation_config_revision = 8,
    });
    var tabs = [_]*SessionTab{&tab};
    var jobs = [_]*Workspace.ConnectJob{&job};
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.external_auth = null;
    workspace.cx = cx;
    workspace.tabs = .empty;
    workspace.tabs.items = &tabs;
    workspace.tabs.capacity = tabs.len;
    workspace.connect_jobs = .empty;
    workspace.connect_jobs.items = &jobs;
    workspace.connect_jobs.capacity = jobs.len;
    workspace.active_tab = null;
    workspace.auth_job = null;
    const snapshot = workspace.pendingAuthentication().?;
    try std.testing.expect(snapshot.identity.eql(request));
    try std.testing.expectEqualStrings("frozen-hop.test", snapshot.endpoint().host);
    const display = workspace.authenticationHostFor(request).?;
    try std.testing.expectEqualStrings("frozen", display.name);
    try std.testing.expect(display.password == null and display.key_passphrase == null and display.totp_secret == null);
    var stale = request;
    stale.request_id += 1;
    try std.testing.expect(workspace.authenticationHostFor(stale) == null);
    var wrong_hop = request;
    wrong_hop.hop_index = 0;
    try std.testing.expect(workspace.authenticationHostFor(wrong_hop) == null);
    job.ready.store(true, .release);
    try std.testing.expect(workspace.authenticationHostFor(request) == null);
    job.ready.store(false, .release);
    try std.testing.expectError(error.StaleChallenge, workspace.submitAuthentication(stale, .{ .answers = &.{"123456"} }));
    try std.testing.expect(!workspace.cancelAuthentication(stale));
    try std.testing.expect(!job.cancelled.load(.acquire));
    try workspace.submitAuthentication(request, .{ .answers = &.{"123456"} });
    try std.testing.expectError(error.StaleChallenge, workspace.submitAuthentication(request, .{ .answers = &.{"654321"} }));
    try std.testing.expect(workspace.cancelAuthentication(request));
    try std.testing.expect(job.cancelled.load(.acquire));
    try std.testing.expect(workspace.authenticationHostFor(request) == null);
    try std.testing.expect(workspace.pendingAuthentication() == null);
    try std.testing.expectError(error.StaleAuthentication, workspace.submitAuthentication(request, .{ .answers = &.{"123456"} }));
}

test "temporary session freezes its endpoint without becoming a saved asset even on failure" {
    const Capture = struct {
        snapshot: ?HostSnapshot = null,
        calls: usize = 0,
        fail: bool = false,
        fn create(raw: ?*anyopaque, host: hosts_mod.HostConfig, host_id: HostId, index: usize, input: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expectEqual(@as(HostId, 0), host_id);
            try std.testing.expectEqual(removed_host_index, index);
            try std.testing.expectEqualStrings("", input);
            self.calls += 1;
            if (self.fail) return error.FactoryUnavailable;
            self.snapshot = try HostSnapshot.init(std.testing.allocator, host);
        }
    };
    var capture: Capture = .{};
    defer if (capture.snapshot) |*snapshot| snapshot.deinit();
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.external_auth = null;
    workspace.shutting_down = false;
    workspace.model.window_close = null;
    workspace.registry = try hosts_mod.Registry.parse(std.testing.allocator, "[[hosts]] name=\"saved\"; host=\"saved.test\"; user=\"operator\"");
    defer workspace.registry.deinit();
    const revision = workspace.registry.revision;
    const next_id = workspace.registry.connection_ids.next_value;
    const source_hash = workspace.registry.source_hash;
    workspace.session_bridge = .{ .context = &capture, .create = Capture.create };
    var address = "temporary.test".*;
    var temporary: hosts_mod.HostConfig = .{ .name = "temporary", .host = &address, .user = "operator" };
    try workspace.newTemporarySession(temporary);
    @memset(&address, 'x');
    try std.testing.expectEqualStrings("temporary.test", capture.snapshot.?.value.host);
    try std.testing.expectEqual(@as(usize, 1), workspace.registry.hosts.len);
    try std.testing.expectEqual(revision, workspace.registry.revision);
    try std.testing.expectEqual(next_id, workspace.registry.connection_ids.next_value);
    try std.testing.expectEqual(source_hash, workspace.registry.source_hash);
    capture.fail = true;
    try std.testing.expectError(error.FactoryUnavailable, workspace.newTemporarySession(temporary));
    temporary.connection_id = @fromBackingInt(99);
    try std.testing.expectError(error.InvalidTemporaryTarget, workspace.newTemporarySession(temporary));
    temporary.connection_id = @fromBackingInt(0);
    temporary.route = &.{@fromBackingInt(1)};
    try std.testing.expectError(error.InvalidTemporaryTarget, workspace.newTemporarySession(temporary));
    temporary.route = &.{};
    workspace.shutting_down = true;
    try std.testing.expectError(error.WorkspaceClosed, workspace.newTemporarySession(temporary));
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(usize, 1), workspace.registry.hosts.len);
    try std.testing.expectEqual(next_id, workspace.registry.connection_ids.next_value);
}

test "saved revision opens with transient credentials without mutating registry" {
    const Capture = struct {
        calls: usize = 0,
        fn create(raw: ?*anyopaque, host: hosts_mod.HostConfig, _: HostId, _: usize, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expectEqualStrings("target.test", host.host);
            try std.testing.expect(!host.strict_host_key_checking);
            try std.testing.expectEqualStrings("one-use-password", host.password.?);
            try std.testing.expectEqualStrings("one-use-passphrase", host.key_passphrase.?);
            self.calls += 1;
        }
    };
    var capture: Capture = .{};
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.external_auth = null;
    workspace.allocator = std.testing.allocator;
    workspace.registry = try hosts_mod.Registry.parse(std.testing.allocator,
        \\[[hosts]]
        \\name="target"; host="target.test"; user="operator"
        \\options={strict_host_key=false}
    );
    defer workspace.registry.deinit();
    workspace.recent_connections = .{};
    workspace.identities = .{};
    defer workspace.identities.deinit(std.testing.allocator);
    workspace.session_bridge = .{ .context = &capture, .create = Capture.create };
    const owner = workspace.registry.hosts[0].owner();
    try workspace.newSessionWithCredentials(owner, "one-use-password", "one-use-passphrase");
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(workspace.registry.hosts[0].password == null);
    try std.testing.expect(workspace.registry.hosts[0].key_passphrase == null);
    var stale = owner;
    stale.revision += 1;
    try std.testing.expectError(error.RevisionConflict, workspace.newSessionWithCredentials(stale, "stale", null));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "connection progress keeps protocol readiness separate from host attachment" {
    const key: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(91), .generation = 3 } }, .operation_id = 201, .attempt_id = 2 };
    var tab: SessionTab = undefined;
    tab.id = 17;
    tab.generation = 4;
    tab.failed = false;
    tab.runtime = null;
    var job: Workspace.ConnectJob = undefined;
    job.ticket = tab.ticket();
    job.operation_key = key;
    job.ready = .init(true);
    job.cancelled = .init(false);
    job.cleanup_unknown = false;
    job.err = null;
    job.resource_ledger = try ResourceLedger.init(key, 1);
    job.progress = .{};
    job.progress.begin(2);
    job.progress_history = .empty;
    job.progress_history_dropped = 0;
    job.progress.record(.{ .attempt = 2, .hop = 0, .hop_count = 1, .host = "target.test", .port = 22, .phase = .ready, .status = .succeeded });
    job.host_snapshot = try HostSnapshot.init(std.testing.allocator, .{ .name = "target", .host = "target.test", .user = "operator", .password = "not-in-progress" });
    defer job.host_snapshot.deinit();
    job.jump_snapshot = try lifecycle.Snapshot([]const hosts_mod.HostConfig).init(std.testing.allocator, &.{});
    defer job.jump_snapshot.deinit();
    var tabs = [_]*SessionTab{&tab};
    var jobs = [_]*Workspace.ConnectJob{&job};
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.external_auth = null;
    workspace.tabs = .empty;
    workspace.tabs.items = &tabs;
    workspace.connect_jobs = .empty;
    workspace.connect_jobs.items = &jobs;
    const projection = workspace.connectionProgress(key).?;
    try std.testing.expect(projection.finished and projection.journal.completed);
    try std.testing.expect(!projection.attached);
    try std.testing.expectEqual(@as(usize, 1), projection.hop_count);
    try std.testing.expectEqualStrings("operator", projection.hops[0].user);
    var stale = key;
    stale.attempt_id = 1;
    try std.testing.expect(workspace.connectionProgress(stale) == null);
    var previous: @import("../proto/ssh/connection_progress.zig").Journal = .{};
    previous.begin(1);
    for (0..200) |_| previous.record(.{ .attempt = 1, .hop = 0, .hop_count = 1, .host = "target.test", .port = 22, .phase = .transport, .status = .started });
    try job.progress_history.append(std.testing.allocator, .{ .key = stale, .journal = previous.snapshot() });
    defer job.progress_history.deinit(std.testing.allocator);
    const history = workspace.connectionProgress(key).?;
    try std.testing.expectEqual(@as(usize, 128), history.log_count);
    try std.testing.expectEqual(@as(usize, 73), history.dropped);
    try std.testing.expect(history.logs[0].key.eql(stale));
    try std.testing.expectEqual(@as(u64, 73), history.logs[0].entry.sequence);
    try std.testing.expect(history.logs[127].key.eql(key));
}

test "file presentation selects and closes without constructing a terminal or connect job" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const strip = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 46 }, .flex_shrink = 0 }, .{});
    try root.appendChild(allocator, strip);
    const area = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .column }, .{});
    try root.appendChild(allocator, area);
    const empty = try ui.box(cx, .{}, .{});
    try area.appendChild(allocator, empty);
    const sidebar = try ui.box(cx, .{ .display = .none }, .{});
    try root.appendChild(allocator, sidebar);
    var config: config_mod.Config = .{};
    const workspace = try allocator.create(Workspace);
    workspace.* = .{ .allocator = allocator, .cx = cx, .scope = scope, .io = std.testing.io, .app_config = &config, .palette = Palette.fromTheme(), .registry = .{ .arena = std.heap.ArenaAllocator.init(allocator), .hosts = &.{} }, .hosts_path = "", .sidebar_list = sidebar, .tab_bar = strip, .model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) }, .terminal_area = area, .empty_state = empty };
    try scope.onCleanup(Workspace, workspace, Workspace.cleanup);
    cx.setViewport(860, 480);
    const content_scope = try scope.childScope();
    const content = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(81), .generation = 3 };
    const id = try workspace.createFileSessionDirect(owner, .{ .connection_id = @fromBackingInt(9), .protocol = .sftp, .name = "Files", .host = "files.test", .user = "operator" }, 9, removed_host_index, content, content_scope);
    const tab = workspace.sessionTab(id).?;
    try std.testing.expect(tab.terminal == null and tab.runtime == null and !tab.local);
    try std.testing.expect(tab.content_owner.eql(.{ .session = owner }));
    try std.testing.expectEqual(@as(usize, 0), workspace.connect_jobs.items.len);
    try std.testing.expectEqualStrings("operator@files.test:22 · SFTP", workspace.model.tabs.items[0].details);
    workspace.selectTab(0);
    cx.layout();
    try std.testing.expectEqual(@as(?usize, 0), workspace.active_tab);
    try std.testing.expect(content.style.display != .none);
    try std.testing.expectEqual(content, cx.focus_manager.getFocused().?);
    try std.testing.expectEqual(RuntimeReleaseReceipt.released, workspace.protocolReleaseStep(id));
    workspace.forceCloseTab(0);
    try std.testing.expectEqual(@as(usize, 0), workspace.tabs.items.len);
    try std.testing.expect(workspace.active_tab == null);
}

test "SSH middle menu bridge preserves the clicked handle across active changes and rejects stale owners" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const first: identity.SessionHandle = .{ .session_id = @fromBackingInt(901), .generation = 7 };
    const second: identity.SessionHandle = .{ .session_id = @fromBackingInt(902), .generation = 4 };
    // The callback reads only tab identity/state and runtime presence. It never
    // dereferences or starts these IO placeholders.
    var runtime: SessionRuntime = undefined;
    var clicked: SessionTab = .{ .id = 11, .tab_id = @fromBackingInt(51), .content_owner = .{ .session = first }, .generation = first.generation, .host_id = 0, .host_index = removed_host_index, .host_snapshot = null, .root = root, .runtime = &runtime };
    var other: SessionTab = .{ .id = 12, .tab_id = @fromBackingInt(52), .content_owner = .{ .session = second }, .generation = second.generation, .host_id = 0, .host_index = removed_host_index, .host_snapshot = null, .root = root, .runtime = &runtime };
    var tabs = [_]*SessionTab{ &clicked, &other };
    var workspace: Workspace = undefined;
    workspace.group_views = .empty;
    workspace.group_roster = null;
    workspace.active_group_view = null;
    workspace.shutting_down = false;
    workspace.tabs = .empty;
    workspace.tabs.items = &tabs;
    workspace.tabs.capacity = tabs.len;
    workspace.active_tab = 1;
    const Sink = struct {
        calls: usize = 0,
        index: ?usize = null,
        anchor: ui.ComputedRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        fn fire(raw: ?*anyopaque, trigger: MenuBridge.Trigger, _: usize, index: ?usize, _: bool, anchor: ui.ComputedRect) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (trigger != .terminal_middle_click) return;
            self.calls += 1;
            self.index = index;
            self.anchor = anchor;
        }
    };
    var sink: Sink = .{};
    workspace.menu_bridge = .{ .context = &sink, .fire = Sink.fire };
    Workspace.onTerminalServiceMenu(&workspace, first, 213, 47);
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqual(@as(?usize, 0), sink.index);
    try std.testing.expectEqual(ui.ComputedRect{ .x = 213, .y = 47, .w = 0, .h = 0 }, sink.anchor);
    Workspace.onTerminalServiceMenu(&workspace, try first.nextGeneration(), 90, 90);
    clicked.closing = true;
    Workspace.onTerminalServiceMenu(&workspace, first, 90, 90);
    clicked.closing = false;
    clicked.failed = true;
    Workspace.onTerminalServiceMenu(&workspace, first, 90, 90);
    clicked.failed = false;
    clicked.archived = true;
    Workspace.onTerminalServiceMenu(&workspace, first, 90, 90);
    clicked.archived = false;
    clicked.runtime = null;
    Workspace.onTerminalServiceMenu(&workspace, first, 90, 90);
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
}

test "notification output never adds tab dots and preserves icon and title colors" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const strip = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 46 }, .flex_shrink = 0 }, .{});
    try root.appendChild(allocator, strip);
    const area = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .column }, .{});
    try root.appendChild(allocator, area);
    const empty = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .position = .absolute }, .{});
    try area.appendChild(allocator, empty);
    const sidebar = try ui.box(cx, .{ .display = .none }, .{});
    try root.appendChild(allocator, sidebar);
    const config: config_mod.Config = .{};
    const workspace = try allocator.create(Workspace);
    workspace.* = .{
        .allocator = allocator,
        .cx = cx,
        .scope = scope,
        .io = std.testing.io,
        .app_config = &config,
        .palette = Palette.fromTheme(),
        .registry = .{ .arena = std.heap.ArenaAllocator.init(allocator), .hosts = &.{} },
        .hosts_path = "",
        .sidebar_list = sidebar,
        .tab_bar = strip,
        .model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) },
        .terminal_area = area,
        .empty_state = empty,
    };
    try scope.onCleanup(Workspace, workspace, Workspace.cleanup);
    cx.setViewport(1194, 800);
    const first_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41) };
    const second_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(42) };
    const first = try workspace.createLocalSessionDirect(first_owner);
    const second = try workspace.createLocalSessionDirect(second_owner);
    workspace.updateLocalState(first, .running, "");
    workspace.updateLocalState(second, .failed, "fixture failure");
    // A background Local tab has no SSH SessionRuntime; its picker status
    // must follow the Local lifecycle rather than stay "connecting" forever.
    const first_tab_id = workspace.sessionTab(first).?.tab_id;
    try std.testing.expectEqualStrings("在线", Workspace.pickerStatus(workspace, first_tab_id));
    workspace.sessionTab(first).?.local_state = .exited;
    try std.testing.expectEqualStrings("离线", Workspace.pickerStatus(workspace, first_tab_id));
    workspace.sessionTab(first).?.local_state = .running;
    workspace.sessionTab(first).?.tab_color = 0x67b88b;
    try workspace.renderTabBar();
    cx.layout();
    try std.testing.expectEqual(ui.Color.hex(0x67b88b), workspace.tab_nodes.items[0].label.getText().?.color);
    try std.testing.expectEqual(workspace.palette.green, workspace.tab_nodes.items[0].type_icon.getIcon().?.tint);
    try std.testing.expectEqual(workspace.palette.red, workspace.tab_nodes.items[1].type_icon.getIcon().?.tint);
    const first_child_count = workspace.tab_nodes.items[0].node.children.items.len;
    const second_child_count = workspace.tab_nodes.items[1].node.children.items.len;
    const notifications = @import("../host/notification_coordinator.zig");
    const preferences: config_mod.Notify = .{};
    var coordinator = try notifications.Coordinator.init(allocator, preferences, .{});
    defer coordinator.deinit();
    const Bridge = struct {
        fn hasDot(raw: ?*anyopaque, owner: identity.ContentOwner) bool {
            const value: *notifications.Coordinator = @ptrCast(@alignCast(raw.?));
            return value.hasDot(owner);
        }
    };
    _ = try coordinator.observeOutput(.{ .session = first_owner }, 7);
    _ = try coordinator.observeOutput(.{ .session = second_owner }, 3);
    workspace.setNotificationAttentionBridge(.{ .context = &coordinator, .has_dot = Bridge.hasDot });
    cx.layout();
    try std.testing.expect(coordinator.hasDot(.{ .session = first_owner }));
    try std.testing.expect(coordinator.hasDot(.{ .session = second_owner }));
    try std.testing.expectEqual(first_child_count, workspace.tab_nodes.items[0].node.children.items.len);
    try std.testing.expectEqual(second_child_count, workspace.tab_nodes.items[1].node.children.items.len);
    for (workspace.tab_nodes.items) |cell| {
        for (cell.node.children.items) |child| {
            const id = child.meta.ownership.meta.test_id orelse continue;
            try std.testing.expect(!std.mem.eql(u8, id, "tabs.unread_attention"));
            try std.testing.expect(!std.mem.eql(u8, id, "tabs.connection_status"));
        }
    }
    try std.testing.expectEqual(ui.Color.hex(0x67b88b), workspace.tab_nodes.items[0].label.getText().?.color);
    try std.testing.expectEqual(workspace.palette.green, workspace.tab_nodes.items[0].type_icon.getIcon().?.tint);
    try std.testing.expectEqual(workspace.palette.red, workspace.tab_nodes.items[1].type_icon.getIcon().?.tint);
    try std.testing.expect(coordinator.markRead(.{ .session = second_owner }, 3, true));
    workspace.refreshNotificationAttention();
    try std.testing.expect(!coordinator.hasDot(.{ .session = second_owner }));
}

test "Local rename survives same title startup but rejects real title or owner changes" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const strip = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 46 }, .flex_shrink = 0 }, .{});
    try root.appendChild(allocator, strip);
    const area = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .column }, .{});
    try root.appendChild(allocator, area);
    const empty = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .position = .absolute }, .{});
    try area.appendChild(allocator, empty);
    const sidebar = try ui.box(cx, .{ .display = .none }, .{});
    try root.appendChild(allocator, sidebar);
    var config: config_mod.Config = .{};
    config.ui.timestamp_gutter = true;
    const workspace = try allocator.create(Workspace);
    workspace.* = .{
        .allocator = allocator,
        .cx = cx,
        .scope = scope,
        .io = std.testing.io,
        .app_config = &config,
        .palette = Palette.fromTheme(),
        .registry = .{ .arena = std.heap.ArenaAllocator.init(allocator), .hosts = &.{} },
        .hosts_path = "",
        .sidebar_list = sidebar,
        .tab_bar = strip,
        .model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) },
        .terminal_area = area,
        .empty_state = empty,
    };
    try scope.onCleanup(Workspace, workspace, Workspace.cleanup);
    cx.setViewport(1194, 800);
    const Helpers = struct {
        fn frames(value: *ui.Cx) void {
            for (0..6) |_| {
                value.frame_count += 1;
                value.frame_time_ms += 16;
                _ = value.render();
            }
        }
        fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
            if (node.meta.ownership.meta.test_id) |name| if (std.mem.eql(u8, name, id)) return node;
            for (node.children.items) |child| if (find(child, id)) |found| return found;
            return null;
        }
        fn save(value: *Workspace) void {
            const button = find(value.rename_editor.?.dialog, "tabs.rename.save").?;
            const rect = button.globalRect();
            value.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
            value.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
        }
    };
    const first_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41) };
    const second_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(42) };
    const first = try workspace.createLocalSessionDirect(first_owner);
    const second = try workspace.createLocalSessionDirect(second_owner);
    try workspace.beginRenameTab(second);
    Helpers.frames(cx);
    const captured_revision = workspace.rename_request.?.revision;
    workspace.rename_editor.?.value.set("chosen title");
    // Starting -> running keeps the exact same visible default title. It must
    // not invalidate the rename already being edited for that same tab owner.
    workspace.updateLocalState(second, .running, "");
    Helpers.frames(cx);
    Helpers.save(workspace);
    try std.testing.expectEqualStrings("chosen title", workspace.sessionTab(second).?.titleSlice());
    try std.testing.expectEqualStrings("Local Terminal", workspace.sessionTab(first).?.titleSlice());
    try std.testing.expectEqual(captured_revision + 1, workspace.model.tabs.items[1].revision);
    Helpers.frames(cx);
    try std.testing.expect(workspace.rename_request == null);

    try workspace.beginRenameTab(second);
    Helpers.frames(cx);
    workspace.rename_editor.?.value.set("late title");
    try workspace.renameTab(1, "new external title");
    Helpers.frames(cx);
    Helpers.save(workspace);
    try std.testing.expectEqualStrings("new external title", workspace.sessionTab(second).?.titleSlice());
    try std.testing.expect(workspace.rename_editor.?.isVisible());
    try std.testing.expect(workspace.cancelRenameTab());
    Helpers.frames(cx);

    try workspace.beginRenameTab(second);
    Helpers.frames(cx);
    workspace.rename_editor.?.value.set("old owner title");
    try workspace.bindSessionOwner(second, try second_owner.nextGeneration());
    Helpers.frames(cx);
    Helpers.save(workspace);
    try std.testing.expectEqualStrings("new external title", workspace.sessionTab(second).?.titleSlice());
    try std.testing.expect(workspace.rename_editor.?.isVisible());
    try std.testing.expect(workspace.cancelRenameTab());
    Helpers.frames(cx);
}

test "group close cancel has no resource effects and membership change needs new approval" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const area = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = area;
    const first_root = try ui.box(cx, .{}, .{});
    const second_root = try ui.box(cx, .{}, .{});
    try area.appendChild(allocator, first_root);
    try area.appendChild(allocator, second_root);
    const config: config_mod.Config = .{};
    var roster = group_model.Roster.init(allocator);
    defer roster.deinit();
    const first_id: u64 = 0x1_0000_0011;
    const second_id: u64 = 0x1_0000_0012;
    const group_id = (try roster.join("real sessions", first_id, 0xff818cf8)).id;
    _ = try roster.join("real sessions", second_id, 0xff818cf8);
    var first: SessionTab = .{ .id = first_id, .tab_id = @fromBackingInt(1), .content_owner = .{ .session = .{ .session_id = @fromBackingInt(first_id) } }, .host_id = 0, .host_index = 0, .host_snapshot = null, .root = first_root, .local = true };
    first.setTitle("本机 · zsh");
    var second: SessionTab = .{ .id = second_id, .tab_id = @fromBackingInt(2), .content_owner = .{ .session = .{ .session_id = @fromBackingInt(second_id) } }, .host_id = 0, .host_index = 0, .host_snapshot = null, .root = second_root, .local = true };
    second.setTitle("另一个独立进程");
    var workspace: Workspace = .{ .allocator = allocator, .cx = cx, .scope = scope, .io = std.testing.io, .app_config = &config, .palette = Palette.fromTheme(), .registry = .{ .arena = std.heap.ArenaAllocator.init(allocator), .hosts = &.{} }, .hosts_path = "", .sidebar_list = area, .tab_bar = area, .terminal_area = area, .empty_state = area, .model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) }, .group_roster = &roster };
    defer if (workspace.poll_hook) |hook| {
        cx.removeAfterLayoutHook(hook);
        allocator.destroy(hook);
    };
    defer workspace.registry.deinit();
    defer workspace.model.deinit();
    defer workspace.tabs.deinit(allocator);
    defer workspace.group_views.deinit(allocator);
    try workspace.tabs.appendSlice(allocator, &.{ &first, &second });
    const view = try allocator.create(group_view.View);
    var view_retired = false;
    defer if (!view_retired) allocator.destroy(view);
    view.* = .{ .id = group_id };
    defer if (!view_retired) view.deinit(allocator);
    try workspace.group_views.append(allocator, view);
    const Sink = struct {
        calls: usize = 0,
        remote_unknown: bool = false,
        fn impact(raw: ?*anyopaque, _: SessionId) group_close.Impact {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .remote_effect_unknown = self.remote_unknown };
        }
        fn close(raw: ?*anyopaque, _: identity.TabId, _: identity.ContentOwner) CloseResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return .awaiting;
        }
    };
    var sink: Sink = .{};
    workspace.close_bridge = .{ .context = &sink, .request_close = Sink.close, .impact = Sink.impact };
    workspace.requestCloseGroup(group_id);
    try std.testing.expectEqual(@as(usize, 2), view.close.?.members.items.len);
    try std.testing.expectEqual(first_id, view.close.?.members.items[0].id);
    workspace.cancelGroupClose(group_id);
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    try std.testing.expect(view.close == null);
    try std.testing.expect(!first.closing and !second.closing);
    workspace.requestCloseGroup(group_id);
    _ = try roster.join("real sessions", 99, 0xff818cf8);
    workspace.approveGroupClose(group_id);
    try std.testing.expectEqual(group_view.ClosePhase.confirming, view.close.?.phase);
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    // The refreshed plan still only contains original valid handles; unknown
    // roster entries cannot become fabricated terminal resources.
    try std.testing.expectEqual(@as(usize, 2), view.close.?.members.items.len);
    workspace.cancelGroupClose(group_id);

    // A real AI outcome may predate the plan. Its retained owner fact must be
    // captured from impact without requiring a live receive callback or AI job.
    sink.remote_unknown = true;
    workspace.requestCloseGroup(group_id);
    try std.testing.expect(view.close.?.members.items[0].remote_effect_unknown);
    try std.testing.expectEqual(@as(usize, 2), view.close.?.counts().unknown);
    _ = view.close.?.record(first_id, .closed);
    _ = view.close.?.record(second_id, .closed);
    view.close.?.cursor = view.close.?.members.items.len;
    view.close.?.phase = .closing;
    workspace.pollGroupClose();
    view_retired = true;
    try std.testing.expectEqual(@as(usize, 0), workspace.group_views.items.len);
    const Find = struct {
        fn node(root: *ui.Node, id: []const u8) ?*ui.Node {
            if (root.meta.ownership.meta.test_id) |name| if (std.mem.eql(u8, name, id)) return root;
            for (root.children.items) |child| if (node(child, id)) |found| return found;
            return null;
        }
    };
    const result = Find.node(area, "groups.close.partial").?;
    const retry = Find.node(result, "groups.close.accept").?;
    try std.testing.expect(retry.behavior.interaction.a11y.?.disabled);
}

test "mixed tab group identity unifies drag rollback ordinals picker and MRU" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const strip = try ui.box(cx, .{ .height = .{ .px = 32 }, .direction = .row }, .{});
    try root.appendChild(allocator, strip);
    const area = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    try root.appendChild(allocator, area);
    const config: config_mod.Config = .{};
    var roster = group_model.Roster.init(allocator);
    defer roster.deinit();
    const group_id = (try roster.join("Acceptance", 71, 0xff818cf8)).id;
    var workspace: Workspace = .{ .allocator = allocator, .cx = cx, .scope = scope, .io = std.testing.io, .app_config = &config, .palette = Palette.fromTheme(), .registry = .{ .arena = std.heap.ArenaAllocator.init(allocator), .hosts = &.{} }, .hosts_path = "", .sidebar_list = root, .tab_bar = strip, .terminal_area = area, .empty_state = area, .model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) } };
    defer {
        if (workspace.poll_hook) |hook| {
            cx.removeAfterLayoutHook(hook);
            allocator.destroy(hook);
            workspace.poll_hook = null;
        }
        scope.dispose();
        for (workspace.click_ctxs.items) |cell| allocator.destroy(cell);
        workspace.click_ctxs.deinit(allocator);
        workspace.tab_nodes.deinit(allocator);
        workspace.strip_advances.deinit(allocator);
        workspace.strip_widths.deinit(allocator);
        workspace.tabs.deinit(allocator);
        workspace.picker.deinit(allocator);
        workspace.rename_draft.deinit(allocator);
        workspace.model.deinit();
        workspace.registry.deinit();
        for (workspace.group_views.items) |view| {
            view.deinit(allocator);
            allocator.destroy(view);
        }
        workspace.group_views.deinit(allocator);
    }
    cx.setViewport(860, 480);
    const first_id = try tab_ids.allocate();
    const last_id = try tab_ids.allocate();
    const first_root = try ui.box(cx, .{}, .{});
    const last_root = try ui.box(cx, .{}, .{});
    try area.appendChild(allocator, first_root);
    try area.appendChild(allocator, last_root);
    var first: SessionTab = .{ .id = 71, .tab_id = first_id, .content_owner = .{ .session = .{ .session_id = @fromBackingInt(71) } }, .host_id = 0, .host_index = 0, .host_snapshot = null, .root = first_root, .local = true };
    first.setTitle("First Local");
    var last: SessionTab = .{ .id = 72, .tab_id = last_id, .content_owner = .{ .session = .{ .session_id = @fromBackingInt(72) } }, .host_id = 0, .host_index = 0, .host_snapshot = null, .root = last_root, .local = true };
    last.setTitle("Last Local");
    try workspace.tabs.append(allocator, &first);
    try workspace.installTabModel(&first);
    try workspace.openGroup(&roster, group_id);
    const group_tab = workspace.groupTabId(group_id).?;
    try workspace.tabs.append(allocator, &last);
    try workspace.installTabModel(&last);
    try workspace.renderTabBar();
    cx.layout();
    try std.testing.expectEqual(@as(usize, 3), workspace.model.tabs.items.len);
    try std.testing.expectEqual(group_tab, workspace.tab_nodes.items[1].tab_id);
    try std.testing.expectEqual(group_id, workspace.groupIdByTab(group_tab).?);
    try std.testing.expect(workspace.tab_nodes.items[1].select_ctx.session_id == null);
    try std.testing.expectApproxEqAbs(@as(f32, 20), workspace.tab_nodes.items[1].close.globalRect().w, 0.01);
    workspace.setCommandHeld(true);
    try std.testing.expectEqualStrings("2", workspace.tab_nodes.items[1].icon.getText().?.content);
    try workspace.model.beginDrag();
    try workspace.model.moveTab(group_tab, 0);
    try workspace.syncModelOrder();
    try std.testing.expectEqual(group_tab, workspace.tab_nodes.items[0].tab_id);
    try std.testing.expectEqualStrings("1", workspace.tab_nodes.items[0].icon.getText().?.content);
    try std.testing.expectEqual(first_id, workspace.tabs.items[0].tab_id);
    try std.testing.expectEqual(last_id, workspace.tabs.items[1].tab_id);
    try workspace.model.endDrag(true);
    try workspace.syncModelOrder();
    try std.testing.expectEqual(group_tab, workspace.tab_nodes.items[1].tab_id);
    cx.layout();
    const drag_rect = workspace.tab_nodes.items[1].node.globalRect();
    const target_rect = workspace.tab_nodes.items[0].node.globalRect();
    cx.handleMouseDown(drag_rect.x + drag_rect.w / 2, drag_rect.y + 15, .{});
    cx.handleMouseMove(target_rect.x + 8, target_rect.y + 15);
    try std.testing.expect(workspace.model.dragging);
    try std.testing.expectEqual(group_tab, workspace.model.tabs.items[0].id);
    cx.cancelPointerInteractions(.window_blur);
    try std.testing.expect(!workspace.model.dragging);
    try std.testing.expectEqual(group_tab, workspace.model.tabs.items[1].id);
    try std.testing.expect(workspace.drag_binding == null);
    try std.testing.expectEqual(first.content_owner, workspace.model.tabs.items[0].owner);
    workspace.selectTabOrdinal(1);
    try std.testing.expectEqual(group_id, workspace.active_group_view.?);
    workspace.selectAdjacentTab(true);
    try std.testing.expectEqual(last_id, workspace.model.active.?);
    try workspace.picker.show(allocator, &workspace.model, 1);
    try workspace.picker.update(allocator, &workspace.model, "Acceptance");
    try std.testing.expectEqualSlices(identity.TabId, &.{group_tab}, workspace.picker.results.items);
    try workspace.picker.activate(&workspace.model, workspace.picker.revision);
    Workspace.pickerActivate(&workspace, group_tab);
    try std.testing.expectEqual(group_id, workspace.active_group_view.?);
    const previous = try workspace.model.cycleRecent(false, &.{});
    try std.testing.expectEqual(last_id, previous.?);
    workspace.presentTabId(previous.?);
    const again = try workspace.model.cycleRecent(false, &.{});
    try std.testing.expectEqual(first_id, again.?);
    try std.testing.expect(roster.findById(group_id).?.contains(71));
    try std.testing.expectEqual(@as(usize, 1), roster.findById(group_id).?.members.items.len);
    workspace.model.finishRecentSwitch();
    workspace.activateTabId(group_tab);
    try workspace.beginRenamePresentation(group_tab);
    try std.testing.expect(Workspace.commitRename(&workspace, @backingInt(group_tab), "renamed group tab"));
    try std.testing.expectEqualStrings("renamed group tab", workspace.model.tabs.items[workspace.model.indexOf(group_tab).?].name());
    try std.testing.expectEqualStrings("First Local", first.titleSlice());
    try std.testing.expectEqual(group_id, workspace.groupIdByTab(group_tab).?);
}

test "registered nonterminal renderer mounts into the existing tab without a legacy host snapshot" {
    const Driver = struct {
        mounts: usize = 0,
        fn mount(raw: ?*anyopaque, request: plugin_ui.ContentMount) !plugin_ui.RendererInstance {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.mounts += 1;
            try request.slot.appendChild(request.cx.allocator, try ui.text(request.cx, "native nonterminal content", .{}));
            return .{ .context = self, .vtable = &.{ .update = update, .focus_changed = focus, .unmount = unmount } };
        }
        fn update(_: *anyopaque, _: plugin_ui.ContentUpdate) !void {}
        fn focus(_: *anyopaque, _: bool) void {}
        fn unmount(_: *anyopaque) void {}
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
    defer a.free(path);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(1100, 720);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    var nodes: [4]*ui.Node = undefined;
    for (&nodes) |*node| {
        node.* = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        try cx.root.?.appendChild(a, node.*);
    }
    const settings: config_mod.Config = .{};
    const workspace = try Workspace.init(a, cx, scope, std.testing.io, &settings, path, nodes[0], nodes[1], nodes[2], nodes[3]);
    var driver: Driver = .{};
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(781), .generation = 3 };
    const id = try workspace.createPluginSession(owner, .{ .id = @fromBackingInt(27), .revision = 1, .protocol_id = "example.canvas", .name = "Canvas owner", .payload_version = 1, .payload = "{}" }, .{ .kind = "example.canvas", .context = &driver, .mount = Driver.mount });
    const tab = workspace.sessionTab(id).?;
    try std.testing.expectEqual(@as(usize, 1), driver.mounts);
    try std.testing.expect(tab.host_snapshot == null and tab.terminal == null and tab.runtime == null);
    try std.testing.expect(tab.plugin_renderer != null);
    try std.testing.expect(tab.content_owner.eql(.{ .session = owner }));
    try std.testing.expectEqualStrings("Canvas owner", workspace.model.tabs.items[0].details);
    try std.testing.expectEqual(@as(usize, 1), workspace.model.tabs.items.len);
    _ = cx.render();
    workspace.forceCloseTab(0);
    try std.testing.expectEqual(@as(usize, 0), workspace.model.tabs.items.len);
}

test "workspace creation without its registered session host never starts a native connection" {
    var workspace: Workspace = undefined;
    workspace.session_bridge = .{};
    try std.testing.expectError(error.SessionHostUnavailable, workspace.createSession(.{ .name = "offline", .host = "unreachable.invalid", .user = "test" }, 1, 0, ""));
}

test "group session creation new and duplicate preserve group without duplicate tab or source feedback" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const strip = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 46 }, .flex_shrink = 0 }, .{});
    try root.appendChild(allocator, strip);
    const area = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .column }, .{});
    try root.appendChild(allocator, area);
    const empty = try ui.box(cx, .{ .display = .none }, .{});
    try area.appendChild(allocator, empty);
    const sidebar = try ui.box(cx, .{ .display = .none }, .{});
    try root.appendChild(allocator, sidebar);
    const config: config_mod.Config = .{};
    const workspace = try allocator.create(Workspace);
    workspace.* = .{ .allocator = allocator, .cx = cx, .scope = scope, .io = std.testing.io, .app_config = &config, .palette = Palette.fromTheme(), .registry = .{ .arena = std.heap.ArenaAllocator.init(allocator), .hosts = &.{} }, .hosts_path = "", .sidebar_list = sidebar, .tab_bar = strip, .terminal_area = area, .empty_state = empty, .model = .{ .allocator = allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) } };
    try scope.onCleanup(Workspace, workspace, Workspace.cleanup);
    cx.setViewport(1194, 800);
    var roster = group_model.Roster.init(allocator);
    defer roster.deinit();
    const original = try workspace.createLocalSessionDirect(.{ .session_id = @fromBackingInt(50) });
    const group = (try roster.join("Acceptance", original, 0xff818cf8)).id;
    try workspace.openGroup(&roster, group);
    const Factory = struct {
        workspace: *Workspace,
        calls: usize = 0,
        feedback: usize = 0,
        fn create(raw: ?*anyopaque, _: SessionId) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            _ = try self.workspace.createLocalSessionDirect(.{ .session_id = @fromBackingInt(50 + self.calls) });
            self.workspace.status("连接中…");
        }
        fn feedbackStatus(raw: *anyopaque, _: ?identity.ContentOwner, _: []const u8, _: Workspace.StatusKind) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.feedback += 1;
        }
    };
    var factory: Factory = .{ .workspace = workspace };
    workspace.session_bridge = .{ .context = &factory, .recreate = Factory.create, .duplicate_local = Factory.create };
    workspace.status_feedback = .{ .context = &factory, .publish = Factory.feedbackStatus };
    workspace.command_output = &workspace.sessionTab(original).?.terminal.?;
    try workspace.newSessionFromTab(workspace.tabIndex(original).?);
    try std.testing.expectEqual(@as(usize, 1), factory.calls);
    try std.testing.expectEqual(@as(usize, 2), workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), workspace.model.visibleCount());
    try std.testing.expectEqual(group, workspace.active_group_view.?);
    const created = workspace.tabs.items[1];
    try std.testing.expect(roster.findById(group).?.contains(created.id));
    try std.testing.expectEqual(workspace.groupTabId(group), workspace.model.tabs.items[workspace.model.indexOf(created.tab_id).?].container);
    workspace.sessionTab(original).?.tab_color = 0x67b88b;
    try workspace.duplicateSessionFromTab(workspace.tabIndex(original).?);
    try std.testing.expectEqual(@as(?u32, 0x67b88b), workspace.tabs.items[2].tab_color);
    try std.testing.expectEqual(@as(?u32, null), workspace.creation_tab_color);
    try std.testing.expectEqual(@as(usize, 2), factory.calls);
    try std.testing.expectEqual(@as(usize, 3), workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 3), roster.findById(group).?.members.items.len);
    try std.testing.expectEqual(@as(usize, 2), workspace.model.visibleCount());
    try std.testing.expectEqual(@as(usize, 2), factory.feedback);
    try std.testing.expect(workspace.sessionTab(original).?.terminal.?.command_message == null);
    try roster.leave("Acceptance", created.id);
    workspace.refreshGroup(group);
    try std.testing.expectEqual(@as(?identity.TabId, null), workspace.model.tabs.items[workspace.model.indexOf(created.tab_id).?].container);
    try std.testing.expectEqual(@as(usize, 3), workspace.model.visibleCount());
    workspace.selectTab(workspace.tabIndex(created.id).?);
    try std.testing.expect(workspace.active_group_view == null);
    try std.testing.expectEqual(created.tab_id, workspace.model.active.?);
    workspace.command_output = null;
    workspace.status_feedback = null;
}

test "material workspace confirmation cards retain overlay alpha and blur across publication" {
    const a = std.testing.allocator;
    const previous = app_theme.materialParameters();
    const old_name = app_theme.currentName();
    defer {
        _ = app_theme.setMaterialParameters(previous.transparency, previous.blur);
        app_theme.select(old_name);
    }
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const config: config_mod.Config = .{};
    var workspace: Workspace = .{
        .allocator = a,
        .cx = cx,
        .scope = scope,
        .io = std.testing.io,
        .app_config = &config,
        .palette = Palette.fromTheme(),
        .registry = .{ .arena = std.heap.ArenaAllocator.init(a), .hosts = &.{} },
        .hosts_path = "",
        .sidebar_list = root,
        .tab_bar = root,
        .model = .{ .allocator = a, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) },
        .terminal_area = root,
        .empty_state = root,
    };
    defer workspace.registry.arena.deinit();
    defer workspace.confirm_risk_rows.deinit(a);
    try workspace.mountCloseConfirm();
    try workspace.mountHostKeyConfirm();
    const ids = .{ workspace.confirm_card.?.id, workspace.host_key_card.?.id };
    const publication = try cx.bindState(@import("shell_styles.zig").ThemePublication, .{});
    for ([_]app_theme.Name{ .dark, .light, .sauber }) |name| {
        app_theme.select(name);
        for ([_]f32{ 0, 25, 75, 100, 0 }, [_]f32{ 0, 8, 24, 96, 0 }) |t, b| {
            _ = app_theme.setMaterialParameters(t, b);
            publication.publish(cx, app_theme.widgetTheme(name));
            _ = cx.render();
            for ([_]*ui.Node{ workspace.confirm_card.?, workspace.host_key_card.? }) |card| {
                try std.testing.expectEqual(app_theme.current().overlay, card.getBackground());
                try std.testing.expectEqual(@max(12, b), card.style.backdrop_blur());
            }
            try std.testing.expectEqual(ids, .{ workspace.confirm_card.?.id, workspace.host_key_card.?.id });
        }
    }
}
