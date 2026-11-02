//! Native KVM content renderer. All state crosses the owner's typed service
//! boundary; this file has no Runtime, Controller, credential or token access.
const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const typed = @import("../../host/plugin_services.zig");
const console = @import("console_service.zig");
const framebuffer = @import("framebuffer.zig");
const input = @import("remote_input.zig");
const services = @import("services.zig");
const mapping = @import("input_mapping.zig");
const vm = @import("view_model.zig");
const S = @import("styles.zig");
const performance = @import("../../host/frame_performance.zig");
const LogS = @import("../../ui/connection_logs_styles.zig");
const Menu = vm.Menu;
const Popover = ui.widgets.popover.PopoverResult;
const Option = ui.widgets.SelectOption;
const WaitingBounds = struct { width: f32, height: f32, theme: u32 };
const LogBounds = struct { width: f32, height: f32, route_height: f32, compact: bool, theme: u32 };
pub const CaptureAuthority = struct {
    binding_generation: u64,
    input_epoch: u64,
    control_generation: u64,
    transport_generation: u64,
    frame_generation: u64,

    fn sameEpoch(self: CaptureAuthority, binding_generation: u64, snapshot: input.Snapshot, frame_generation: u64) bool {
        return self.binding_generation == binding_generation and self.input_epoch == snapshot.input_epoch and self.control_generation == snapshot.control_generation and self.transport_generation == snapshot.transport_generation and self.frame_generation == frame_generation;
    }
    fn matches(self: CaptureAuthority, binding_generation: u64, snapshot: input.Snapshot, frame_generation: u64) bool {
        return self.sameEpoch(binding_generation, snapshot, frame_generation) and geometryReady(snapshot, frame_generation) and snapshot.controlled and snapshot.focused and snapshot.connected and !snapshot.capture_paused and !snapshot.remote_unconfirmed;
    }
};
fn geometryReady(snapshot: input.Snapshot, frame_generation: u64) bool {
    // Zero preserves compatibility with an input-only typed provider. The
    // native pipeline starts pending and always publishes a nonzero generation.
    return !snapshot.geometry_pending and (snapshot.geometry_generation == 0 or snapshot.geometry_generation == frame_generation);
}

const menu_names = [_][]const u8{ "控制", "按键", "显示", "电源", "启动" };
const menu_ids = [_][]const u8{ "bmc.control", "bmc.keys", "bmc.display", "bmc.power", "bmc.boot" };
const menu_icons = [_]ui.SvgAsset{ ui.icons.mouse_pointer_2, ui.icons.keyboard, ui.icons.monitor, ui.icons.power, ui.icons.arrow_up_right };
const power_actions = [_]services.PowerAction{ .on, .graceful_shutdown, .graceful_restart, .force_off, .force_restart, .power_cycle };
const target_values = [_][]const u8{ "Disabled", "Pxe", "Hdd", "Cd", "Diags", "BiosSetup", "Usb", "None" };
const target_names = [_][]const u8{ "恢复默认（关闭覆盖）", "网络 PXE", "硬盘", "CD / DVD", "诊断", "BIOS 设置", "USB", "None（设备返回）" };
const mode_values = [_][]const u8{ "UEFI", "Legacy" };
const unverified_mapping_message = "管理目标或读取证据尚未核实，仅供查看";
const response_diagnostic_message = "设备响应含附加诊断；以下字段按各自读取结果显示。";
const power_option_ids = [_][]const u8{ "bmc.power.option.on", "bmc.power.option.shutdown", "bmc.power.option.restart", "bmc.power.option.force_off", "bmc.power.option.force_restart", "bmc.power.option.power_cycle" };
const target_option_ids = [_][]const u8{ "bmc.boot.option.disabled", "bmc.boot.option.pxe", "bmc.boot.option.hdd", "bmc.boot.option.cd", "bmc.boot.option.diags", "bmc.boot.option.bios", "bmc.boot.option.usb", "bmc.boot.option.none" };

pub const View = struct {
    mount_request: contract.ContentMount,
    closed: bool = false,
    root: ?*ui.Node = null,
    toolbar: ?*ui.Node = null,
    connection_title: ?*ui.Node = null,
    tool_nodes: [5]?*ui.Node = @splat(null),
    tool_styles: [5]*ui.Signal(ui.BoxStyle) = undefined,
    tool_hover: *ui.Signal(?ui.BoxStyle) = undefined,
    key_style: *ui.Signal(ui.BoxStyle) = undefined,
    last_theme_version: u32 = std.math.maxInt(u32),
    last_compact: ?bool = null,
    viewport: ?*ui.Node = null,
    scroll: ?ui.widgets.ScrollAreaResult = null,
    image_node: ?*ui.Node = null,
    waiting: ?*ui.Node = null,
    waiting_header: ?*ui.Node = null,
    waiting_title: ?*ui.Node = null,
    waiting_detail: ?*ui.Node = null,
    waiting_body: ?ui.widgets.ScrollAreaResult = null,
    waiting_actions: ?*ui.Node = null,
    progress_active: bool = false,
    progress_projection: vm.ProgressProjection = .{},
    progress_disclosure: vm.ProgressDisclosure = .{},
    progress_failure_scroll: ?usize = null,
    progress_stage_scroll: ?usize = null,
    progress_last_stage: ?console.progress.Stage = null,
    progress_attempt: ?services.OperationKey = null,
    progress_timing: ?*ui.Node = null,
    progress_stage_time: ?*ui.Node = null,
    progress_total_time: ?*ui.Node = null,
    progress_notice: ?*ui.Node = null,
    progress_steps: ?*ui.Node = null,
    progress_rows: [vm.progress_group_count]?*ui.Node = @splat(null),
    progress_buttons: [vm.progress_group_count]?*ui.Node = @splat(null),
    progress_details: [vm.progress_group_count]?*ui.Node = @splat(null),
    progress_chevrons: [vm.progress_group_count]?*ui.Node = @splat(null),
    progress_icons: [vm.progress_group_count]?*ui.Node = @splat(null),
    progress_names: [vm.progress_group_count]?*ui.Node = @splat(null),
    progress_states: [vm.progress_group_count]?*ui.Node = @splat(null),
    progress_route: ?*ui.Node = null,
    progress_route_text: ?*ui.Node = null,
    cancel_node: ?*ui.Node = null,
    cancel_disabled: *ui.Signal(bool) = undefined,
    retry_disabled: *ui.Signal(bool) = undefined,
    cancel_pending: bool = false,
    retry_node: ?*ui.Node = null,
    log_open: ?*ui.Signal(bool) = null,
    log_modal: ?ui.widgets.ModalResult = null,
    log_footer: ?*ui.Node = null,
    log_scroll: ?ui.widgets.ScrollAreaResult = null,
    log_detail: ?*ui.Node = null,
    log_empty: ?*ui.Node = null,
    log_rows: [console.progress.capacity + 1]?*ui.Node = @splat(null),
    log_timestamps: [console.progress.capacity + 1]?*ui.Node = @splat(null),
    log_messages: [console.progress.capacity + 1]?*ui.Node = @splat(null),
    log_durations: [console.progress.capacity + 1]?*ui.Node = @splat(null),
    log_route_text: ?*ui.Node = null,
    log_revision: ?u64 = null,
    log_layout_pending: bool = false,
    last_log_open: bool = false,
    log_scroll_pending: bool = false,
    log_follow_latest: bool = true,
    log_anchor: ?struct { sequence: u64, inside: f32, fallback: f32 } = null,
    log_sequences: [console.progress.capacity + 1]u64 = @splat(0),
    log_count: usize = 0,
    waiting_bounds: ?WaitingBounds = null,
    log_bounds: ?LogBounds = null,
    bounds_layout_pending: bool = false,
    snapshot: ?console.OwnedSnapshot = null,
    power_snapshot: ?services.OwnedPowerSnapshot = null,
    boot_snapshot: ?services.OwnedBootSnapshot = null,
    management_operation: ?struct { key: services.OperationKey, boot: bool } = null,
    management_result: ?services.Owned(services.Result) = null,
    draft: vm.BootDraft = .{},
    mode: mapping.Mode = .fit,
    captured: bool = false,
    capture_authority: ?CaptureAuthority = null,
    view_only: bool = true,
    watch_only_selected: bool = false,
    window_focused: bool = true,
    pending_capture: bool = false,
    pending_capture_authority: ?CaptureAuthority = null,
    keyboard: mapping.Keyboard = .{},
    wheel: mapping.WheelAccumulator = .{},
    buttons: u8 = 0,
    pointer_captured: bool = false,
    pending_pointer: ?input.Pointer = null,
    last_pointer_ms: f64 = -1000,
    input_sequence: u64 = 0,
    texture: ?u32 = null,
    frame_revision: u64 = 0,
    frame_generation: u64 = 0,
    show_fps: *ui.Signal(bool) = undefined,
    fps_hud: ?*ui.Node = null,
    fps_display: ?*ui.Node = null,
    fps_decode: ?*ui.Node = null,
    fps_detail: ?*ui.Node = null,
    decoded_meter: performance.Meter = .{},
    decoded_total: ?u64 = null,
    decoded_generation: u64 = 0,
    last_fps_ms: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    last_poll_ms: f64 = -1000,
    last_management_ms: f64 = -1000,
    after_layout_registered: bool = false,
    menus: [5]?Popover = @splat(null),
    menu_scrolls: [5]?ui.widgets.ScrollAreaResult = @splat(null),
    open: [5]*ui.Signal(bool) = undefined,
    menu_signal_count: usize = 0,
    keys_disabled: *ui.Signal(bool) = undefined,
    request_disabled: *ui.Signal(bool) = undefined,
    capture_disabled: *ui.Signal(bool) = undefined,
    power_disabled: *ui.Signal(bool) = undefined,
    boot_disabled: *ui.Signal(bool) = undefined,
    mode_disabled: *ui.Signal(bool) = undefined,
    power_execute_disabled: *ui.Signal(bool) = undefined,
    boot_execute_disabled: *ui.Signal(bool) = undefined,
    power_query: ?*ui.Node = null,
    boot_query: ?*ui.Node = null,
    power_cancel: ?*ui.Node = null,
    boot_cancel: ?*ui.Node = null,
    switch_disabled: *ui.Signal(bool) = undefined,
    power_options: *ui.Signal([]const Option) = undefined,
    boot_options: *ui.Signal([]const Option) = undefined,
    mode_options: *ui.Signal([]const Option) = undefined,
    power_value: *ui.Signal(?[]const u8) = undefined,
    target_value: *ui.Signal(?[]const u8) = undefined,
    mode_value: *ui.Signal(?[]const u8) = undefined,
    boot_continuous: *ui.Signal(bool) = undefined,
    power_choice: services.PowerAction = .on,
    power_storage: [2][6]Option = undefined,
    target_storage: [2][8]Option = undefined,
    mode_storage: [2][2]Option = undefined,
    option_slot: usize = 0,
    control_label: ?*ui.Node = null,
    control_request_row: ?*ui.Node = null,
    power_label: ?*ui.Node = null,
    power_scope_label: ?*ui.Node = null,
    power_mapping_warning: ?*ui.Node = null,
    power_hint: ?*ui.Node = null,
    boot_label: ?*ui.Node = null,
    boot_scope_label: ?*ui.Node = null,
    boot_mapping_warning: ?*ui.Node = null,
    boot_pending_label: ?*ui.Node = null,
    boot_hint: ?*ui.Node = null,
    boot_details: ?*ui.Node = null,
    boot_switch: ?*ui.Node = null,
    switch_patched: bool = false,
    switch_checked: bool = false,
    switch_theme_version: u32 = std.math.maxInt(u32),
    mode_row: ?*ui.Node = null,
    order_rows: ?*ui.Node = null,
    order_mapping_warning: ?*ui.Node = null,
    order_open: ?*ui.Signal(bool) = null,
    order_modal: ?ui.widgets.ModalResult = null,
    order_scroll: ?ui.widgets.ScrollAreaResult = null,
    fit_style: *ui.Signal(ui.BoxStyle) = undefined,
    original_style: *ui.Signal(ui.BoxStyle) = undefined,
    fullscreen_label: *ui.Signal([]const u8) = undefined,
    message: ?*ui.Node = null,
    input_hint: ?*ui.Node = null,

    const Borrowed = struct { binding: typed.Binding, table: *const console.Interface };
    fn borrowConsole(self: *View) !Borrowed {
        const access = self.mount_request.service_access orelse return error.ServiceUnavailable;
        const binding = (try access.lookup(self.mount_request.owner, console.definition)) orelse return error.ServiceUnavailable;
        return .{ .binding = binding, .table = try binding.borrow(console.Interface, console.key, self.mount_request.owner) };
    }
    fn lookup(self: *View, definition: typed.Definition) !?typed.Binding {
        const access = self.mount_request.service_access orelse return null;
        return access.lookup(self.mount_request.owner, definition);
    }
    fn anyMenu(self: *const View) bool {
        if (self.closed) return false;
        if (self.order_open) |open| if (open.peek()) return true;
        if (self.log_open) |open| if (open.peek()) return true;
        for (self.open[0..self.menu_signal_count]) |signal| if (signal.peek()) return true;
        return false;
    }
    fn closeMenus(self: *View) void {
        for (self.open[0..self.menu_signal_count]) |signal| signal.set(false);
        if (self.order_open) |open| open.set(false);
        if (self.log_open) |open| open.set(false);
    }
    fn releaseInput(self: *View, cause: input.ReleaseCause) void {
        self.captured = false;
        self.capture_authority = null;
        self.pending_capture = false;
        self.pending_capture_authority = null;
        self.buttons = 0;
        self.pending_pointer = null;
        self.keyboard.clear();
        self.wheel.clear();
        if (self.input_hint) |node| node.setDisplay(.none);
        if (self.pointer_captured) self.mount_request.cx.releasePointerCapture();
        self.pointer_captured = false;
        if (self.lookup(input.definition) catch null) |binding| {
            if (binding.borrow(input.Interface, input.key, self.mount_request.owner)) |table| {
                _ = table.release_all(binding.context, binding, cause);
            } else |_| {}
        }
        if (self.borrowConsole()) |service| {
            service.table.set_focus(service.binding.context, service.binding, false) catch {};
        } else |_| {}
    }
    fn showMessage(self: *View, text: []const u8) void {
        if (self.message) |node| node.setTextContent(self.mount_request.cx.allocator, text) catch {};
        if (self.input_hint) |node| {
            node.setTextContent(self.mount_request.cx.allocator, text) catch {};
            node.setDisplay(if (text.len > 0) .flex else .none);
        }
    }
    fn beginCapture(self: *View, requested: ?CaptureAuthority) void {
        if (self.closed or self.texture == null or self.watch_only_selected or !self.window_focused or !self.mount_request.cx.window_active or self.anyMenu() or self.mount_request.cx.overlay_stack.topmost() != null) return;
        const service = self.borrowConsole() catch return;
        var snapshot = service.table.snapshot(service.binding.context, service.binding, self.mount_request.cx.allocator) catch return;
        defer snapshot.deinit();
        if (!snapshot.value.rfb_ready or snapshot.value.read_only_requested or self.frame_generation != snapshot.value.frame_generation or !snapshot.value.input.connected or !snapshot.value.input.controlled or snapshot.value.input.remote_unconfirmed) return;
        if (!geometryReady(snapshot.value.input, self.frame_generation)) {
            self.showMessage("画面尺寸正在更新，收到完整新画面后可重新捕获键鼠。");
            return;
        }
        // Taking human focus can revoke an AI lease and advance the epoch.
        // Freeze the authority after that real handoff; later events must never
        // adopt a newer transport/control/focus grant implicitly.
        const binding = (self.lookup(input.definition) catch null) orelse {
            self.releaseInput(.released);
            return;
        };
        const table = binding.borrow(input.Interface, input.key, self.mount_request.owner) catch {
            self.releaseInput(.released);
            return;
        };
        if (requested) |authority| if (!authority.sameEpoch(binding.generation, snapshot.value.input, self.frame_generation)) return;
        service.table.set_focus(service.binding.context, service.binding, true) catch |err| {
            self.showMessage(@errorName(err));
            return;
        };
        const current = table.snapshot(binding.context, binding) catch {
            self.releaseInput(.released);
            return;
        };
        var focused_snapshot = service.table.snapshot(service.binding.context, service.binding, self.mount_request.cx.allocator) catch {
            self.releaseInput(.released);
            return;
        };
        defer focused_snapshot.deinit();
        const authority: CaptureAuthority = .{ .binding_generation = binding.generation, .input_epoch = current.input_epoch, .control_generation = current.control_generation, .transport_generation = current.transport_generation, .frame_generation = self.frame_generation };
        if (!focused_snapshot.value.rfb_ready or focused_snapshot.value.frame_generation != self.frame_generation or snapshot.value.input.control_generation != current.control_generation or snapshot.value.input.transport_generation != current.transport_generation or !authority.matches(binding.generation, focused_snapshot.value.input, self.frame_generation)) {
            self.releaseInput(.released);
            return;
        }
        self.view_only = false;
        self.capture_authority = authority;
        self.captured = true;
        if (self.viewport) |node| self.mount_request.cx.focus_manager.setFocus(node);
    }
    fn submit(self: *View, event: input.Event) bool {
        if (self.closed or !self.captured or self.view_only) return false;
        if (!self.window_focused or !self.mount_request.cx.window_active or self.anyMenu() or self.mount_request.cx.overlay_stack.topmost() != null) {
            self.releaseInput(.lost_focus);
            return false;
        }
        const binding = (self.lookup(input.definition) catch null) orelse {
            self.releaseInput(.disconnected);
            return false;
        };
        const table = binding.borrow(input.Interface, input.key, self.mount_request.owner) catch {
            self.releaseInput(.disconnected);
            return false;
        };
        const snapshot = table.snapshot(binding.context, binding) catch {
            self.releaseInput(.disconnected);
            return false;
        };
        const authority = self.capture_authority orelse {
            self.releaseInput(.control_revoked);
            return false;
        };
        if (!authority.matches(binding.generation, snapshot, self.frame_generation)) {
            self.releaseInput(.control_revoked);
            return false;
        }
        self.input_sequence = @max(self.input_sequence, snapshot.last_input_sequence);
        if (self.input_sequence == std.math.maxInt(u64)) {
            self.releaseInput(.released);
            return false;
        }
        self.input_sequence += 1;
        const result = table.submit(binding.context, binding, .{ .session_handle = self.mount_request.owner, .binding_generation = authority.binding_generation, .input_sequence = self.input_sequence, .input_epoch = authority.input_epoch, .control_generation = authority.control_generation, .geometry_generation = authority.frame_generation, .event = event });
        return switch (result) {
            .accepted => true,
            else => blk: {
                self.releaseInput(.send_failed);
                break :blk false;
            },
        };
    }
    fn geometry(self: *View) ?mapping.Geometry {
        if (self.texture == null) return null;
        const node = self.viewport orelse return null;
        const rect = node.globalRect();
        const scroll = self.scroll orelse return null;
        // ScrollArea snaps its painted translation to the backing-pixel grid.
        // Read that logical translation rather than the unsnapped accumulator,
        // otherwise fractional local scrolling can shift a click by one pixel.
        return mapping.Geometry.calculate(.{ .x = rect.x, .y = rect.y, .width = rect.w, .height = rect.h }, self.width, self.height, self.mode, .{ .x = -scroll.content.style.translate_x, .y = -scroll.content.style.translate_y });
    }
    fn pointer(self: *View, x: f32, y: f32, mask: u8, dragging: bool) bool {
        const g = self.geometry() orelse return false;
        var value = g.remote(.{ .x = x, .y = y }, dragging) orelse return false;
        value.buttons = mask;
        if (!self.submit(.{ .pointer = value })) return false;
        self.buttons = mask;
        return true;
    }
    fn flushPointer(self: *View) void {
        const pending = self.pending_pointer orelse return;
        self.pending_pointer = null;
        if (self.submit(.{ .pointer = pending })) self.last_pointer_ms = ui.frame.estimateTimeMs();
    }
    fn flushPointerWhenDue(self: *View) void {
        if (self.pending_pointer == null) return;
        const now = ui.frame.estimateTimeMs();
        const remaining_ms = 1000.0 / 60.0 - (now - self.last_pointer_ms);
        if (remaining_ms <= 0 or now < self.last_pointer_ms) {
            self.flushPointer();
        } else {
            // A final move must not wait for the ordinary 33ms console poll.
            // Cx retains the earliest scheduled redraw, including at idle.
            self.mount_request.cx.scheduleRedrawAfterNs(@intFromFloat(@ceil(remaining_ms * std.time.ns_per_ms)));
        }
    }
    fn localPointerTarget(self: *View, x: f32, y: f32) bool {
        if (self.pointer_captured) return false;
        const area = self.scroll orelse return false;
        const hit = self.mount_request.cx.hitTestQuery(.{ .kind = .pointer, .world_x = x, .world_y = y }) orelse return false;
        const target = self.mount_request.cx.node_registry.resolve(hit.handle, null) orelse return false;
        // ScrollArea exposes its content slot publicly. Its local chrome and
        // sibling status controls must retain their native pointer handlers.
        return target != area.container and target != area.content and !target.isDescendantOf(area.content);
    }
    fn handle(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (self.closed) return .ignored;
        switch (event) {
            .mouse_down => |value| {
                if (self.anyMenu()) return .ignored;
                if (self.localPointerTarget(value.x, value.y)) {
                    if (self.captured) self.releaseInput(.released);
                    return .ignored;
                }
                const g = self.geometry() orelse return .ignored;
                if (g.remote(.{ .x = value.x, .y = value.y }, false) == null) return .ignored;
                if (!self.captured) self.beginCapture(null);
                if (!self.captured) return .handled;
                self.flushPointer();
                const mask = self.buttons | buttonMask(value.button);
                if (self.pointer(value.x, value.y, mask, false)) {
                    self.mount_request.cx.setPointerCapture(self.viewport.?);
                    self.pointer_captured = true;
                    return .stop;
                }
            },
            .mouse_up => |value| {
                if (!self.captured) return .ignored;
                if (self.localPointerTarget(value.x, value.y)) return .ignored;
                self.flushPointer();
                _ = self.pointer(value.x, value.y, self.buttons & ~buttonMask(value.button), self.buttons != 0);
                if (self.buttons == 0 and self.pointer_captured) {
                    self.mount_request.cx.releasePointerCapture();
                    self.pointer_captured = false;
                }
                return .stop;
            },
            .mouse_move => |value| {
                if (!self.captured) return .ignored;
                if (self.localPointerTarget(value.x, value.y)) return .ignored;
                const g = self.geometry() orelse return .ignored;
                var pointer_value = g.remote(.{ .x = value.x, .y = value.y }, self.buttons != 0) orelse return .ignored;
                pointer_value.buttons = self.buttons;
                self.pending_pointer = pointer_value;
                self.flushPointerWhenDue();
                return .stop;
            },
            .scroll => |value| {
                if (!self.captured or self.anyMenu()) return .ignored;
                if (self.localPointerTarget(value.x, value.y)) {
                    self.releaseInput(.released);
                    return .ignored;
                }
                const g = self.geometry() orelse return .ignored;
                const p = g.remote(.{ .x = value.x, .y = value.y }, false) orelse return .ignored;
                const steps = self.wheel.add(value.dx, value.dy, value.isTrackpad());
                if (steps.x != 0 or steps.y != 0) _ = self.submit(.{ .wheel = .{ .x = p.x, .y = p.y, .steps_x = steps.x, .steps_y = steps.y } });
                return .stop;
            },
            .key_down, .key_up => |value| {
                const modifiers: mapping.Modifiers = .{ .shift = value.modifiers.shift, .ctrl = value.modifiers.ctrl, .alt = value.modifiers.alt, .super = value.modifiers.super };
                const raw_key = @backingInt(value.key);
                if (mapping.isReleaseShortcut(raw_key, modifiers)) {
                    if (event == .key_down) self.releaseCapture();
                    return .stop;
                }
                if (!self.captured or self.anyMenu()) return .ignored;
                if (self.keyboard.keyBatch(raw_key, modifiers, event == .key_down)) |batch| {
                    for (batch.slice()) |key| {
                        if (!self.submit(.{ .key = key })) break;
                    }
                } else self.showMessage("此按键尚不支持；可使用按键菜单发送常用按键。");
                return .stop;
            },
            // Physical keys already produced the remote event. Host IME text is
            // never guessed into scancodes and never sent a second time.
            .text_input, .ime_preedit, .ime_commit, .ime_delete_surrounding => return if (self.captured) .stop else .ignored,
            .blur => {
                self.releaseInput(.lost_focus);
            },
            else => {},
        }
        return .ignored;
    }
    fn reserved(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        if (event != .key_down and event != .key_up) return .ignored;
        const value = if (event == .key_down) event.key_down else event.key_up;
        if (!mapping.isReleaseShortcut(@backingInt(value.key), .{ .ctrl = value.modifiers.ctrl, .alt = value.modifiers.alt })) return .ignored;
        return handle(event, raw);
    }
    fn beforeRender(node: *ui.Node) void {
        const self: *View = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
        if (self.closed) return;
        if ((self.captured or self.pending_capture) and (!self.mount_request.cx.window_active or (self.captured and self.mount_request.cx.overlay_stack.topmost() != null))) self.releaseInput(.lost_focus);
        const now = self.mount_request.cx.frame_time_ms;
        if (now - self.last_poll_ms >= 30 or now < self.last_poll_ms) {
            self.last_poll_ms = now;
            self.refresh(now) catch |err| self.showMessage(@errorName(err));
        }
        self.updateGeometry();
        _ = self.updatePopovers();
        self.flushPointerWhenDue();
        if (self.mount_request.frame_sink) |sink| {
            // The host confirms this candidate only after a successful native
            // frame submission. Repainting the HUD never increments video FPS.
            if (self.texture != null and self.texture == sink.texture and self.frame_generation == sink.frame_generation)
                sink.presentation.stage(self.mount_request.cx.frame_count, sink.frame_generation, sink.revision);
        }
        if (self.pending_capture and !self.anyMenu() and self.mount_request.cx.overlay_stack.topmost() == null) {
            const requested = self.pending_capture_authority;
            self.pending_capture = false;
            self.pending_capture_authority = null;
            if (requested) |authority| self.beginCapture(authority);
        }
        if (self.boot_switch) |switch_node| {
            const checked = self.boot_continuous.peek();
            if (!self.switch_patched or self.switch_checked != checked or self.switch_theme_version != self.mount_request.cx.theme_version) {
                patchSwitch(self, switch_node);
                self.switch_patched = true;
                self.switch_checked = checked;
                self.switch_theme_version = self.mount_request.cx.theme_version;
            }
        }
        self.mount_request.cx.scheduleRedrawAfterNs(if (self.window_focused and self.mount_request.cx.window_active) 33 * std.time.ns_per_ms else 250 * std.time.ns_per_ms);
    }
    fn refresh(self: *View, now: f64) !void {
        const service = try self.borrowConsole();
        var next = try service.table.snapshot(service.binding.context, service.binding, self.mount_request.cx.allocator);
        var retained = false;
        errdefer if (!retained) next.deinit();
        if (!next.value.owner.eql(self.mount_request.owner)) return error.StaleBinding;
        if (self.captured) {
            const authority = self.capture_authority;
            if (authority == null or !authority.?.matches(authority.?.binding_generation, next.value.input, next.value.frame_generation) or !next.value.rfb_ready) self.releaseInput(.control_revoked);
        }
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = next;
        retained = true;
        const value = self.snapshot.?.value;
        try setText(self, self.connection_title, if (value.name.len != 0) value.name else if (value.target.len != 0) value.target else "KVM 控制台");
        var chord_available = false;
        if (try self.lookup(input.definition)) |binding| {
            const table = try binding.borrow(input.Interface, input.key, self.mount_request.owner);
            if (self.capture_authority) |authority| if (binding.generation != authority.binding_generation) self.releaseInput(.control_revoked);
            if (comptime @hasField(input.Interface, "submit_chord")) chord_available = table.submit_chord != null;
        }
        self.keys_disabled.set(!value.rfb_ready or !value.input.controlled or value.read_only_requested or !chord_available);
        self.request_disabled.set(!value.rfb_ready or value.input.controlled or value.read_only_requested or value.control == .awaiting_authorization);
        self.capture_disabled.set(!value.rfb_ready or !value.input.controlled or value.input.remote_unconfirmed or !geometryReady(value.input, self.frame_generation));
        try setText(self, self.control_label, if (!value.input.connected) "视频通道未就绪" else if (value.input.controlled) (if (self.captured) "已获控制权 · 已捕获键鼠" else if (self.watch_only_selected) "已获控制权 · 仅观看" else "已获控制权 · 键鼠已释放") else switch (value.control) {
            .awaiting_authorization => "已申请控制权 · 等待目标授权",
            .rejected => "控制权申请已被目标拒绝",
            else => if (value.read_only_requested) "当前配置为仅观看" else "仅观看 · 尚未获控制权",
        });
        if (self.control_request_row) |row| row.setDisplay(if (value.control_request != null) .flex else .none);
        // Borrow the original framebuffer definition as well as the sink: the
        // former proves this owner exposes frames, the latter owns GPU lifetime.
        if (try self.lookup(framebuffer.definition)) |binding| _ = try binding.borrow(framebuffer.Interface, framebuffer.key, self.mount_request.owner);
        try self.presentFrame(value);
        try self.updatePerformance(value);
        try self.projectProgress(value);
        if (self.mount_request.content_context) |context| self.fullscreen_label.set(if (context.fullscreen()) "退出全屏" else "进入全屏");
        if (value.cleanup == .not_started and value.route != .closed and (now - self.last_management_ms >= 1000 or now < self.last_management_ms)) {
            self.last_management_ms = now;
            try self.refreshManagement();
        }
    }
    fn updatePerformance(self: *View, value: console.Snapshot) !void {
        const now: u64 = @intCast(@max(0, @import("../../platform/realtime.zig").monotonicNs()) / std.time.ns_per_ms);
        const live = value.video == .streaming and self.texture != null;
        if (self.fps_hud) |hud| hud.setDisplay(if (self.show_fps.peek() and live) .flex else .none);
        if (self.decoded_generation != value.frame_generation or (self.decoded_total != null and value.decoded_frames < self.decoded_total.?)) {
            self.decoded_meter = .{};
            self.decoded_total = null;
            self.decoded_generation = value.frame_generation;
        }
        if (live) {
            const delta = if (self.decoded_total) |total| value.decoded_frames -| total else @as(u64, @intFromBool(value.decoded_frames != 0));
            self.decoded_meter.record(now, delta);
        }
        self.decoded_total = value.decoded_frames;
        if (now >= self.last_fps_ms and now - self.last_fps_ms < 500) return;
        self.last_fps_ms = now;
        const meter = if (self.mount_request.frame_sink) |sink| &sink.presentation.meter else null;
        var buf: [160]u8 = undefined;
        try setText(self, self.fps_display, if (live and meter != null and meter.?.fps(now) != null)
            try std.fmt.bufPrint(&buf, "显示 {d:.1} FPS", .{meter.?.fps(now).?})
        else
            "显示 — FPS");
        try setText(self, self.fps_decode, if (live and self.decoded_meter.fps(now) != null)
            try std.fmt.bufPrint(&buf, "解码 {d:.1} FPS", .{self.decoded_meter.fps(now).?})
        else
            "解码 — FPS");
        try setText(self, self.fps_detail, if (live and meter != null and meter.?.last_ms != null)
            try std.fmt.bufPrint(&buf, "最近 10 秒最大帧间隔：{d} ms\n距上一显示帧：{d} ms", .{ meter.?.maxGap(now), now -| meter.?.last_ms.? })
        else
            "等待视频帧统计");
    }
    fn fpsChanged(self: *View, enabled: bool) void {
        self.show_fps.set(enabled);
        self.last_fps_ms = 0;
        if (self.snapshot) |snapshot| self.updatePerformance(snapshot.value) catch {};
        self.mount_request.cx.requestRedraw();
    }
    fn presentFrame(self: *View, value: console.Snapshot) !void {
        if (self.mount_request.frame_sink) |sink| {
            if (!sink.owner.eql(self.mount_request.owner)) return error.StaleBinding;
            if (sink.texture == null or sink.frame_generation != value.frame_generation) {
                // A queue may cross its resize barrier after the console
                // snapshot was read. Hide the old presentation before emit;
                // the next owned snapshot will authorize the new generation.
                self.texture = null;
                if (self.image_node) |node| node.setImage(null);
                if (self.captured) self.releaseInput(.released);
            }
            if (sink.texture != null and sink.frame_generation == value.frame_generation and sink.frame_generation >= self.frame_generation and sink.revision >= self.frame_revision) {
                if (sink.texture != self.texture or sink.revision != self.frame_revision) {
                    self.texture = sink.texture;
                    self.frame_revision = sink.revision;
                    self.frame_generation = sink.frame_generation;
                    self.width = sink.width;
                    self.height = sink.height;
                    if (self.image_node) |node| {
                        node.setImage(.{ .texture_id = sink.texture.? });
                        node.markRenderDirty();
                    }
                }
            }
        }
        const current_texture = self.texture != null and self.frame_generation == value.frame_generation;
        const title = vm.statusTitle(value, current_texture);
        const interrupted = current_texture and value.route != .closed and (value.route == .failed or value.video == .failed) and value.cleanup != .awaiting and value.cleanup != .unknown;
        if (self.waiting) |node| {
            node.setDisplay(if (title.len == 0) .none else .flex);
        }
        if (self.image_node) |node| node.setDisplay(if (current_texture and (title.len == 0 or interrupted)) .flex else .none);
        if (self.viewport) |node| node.setBackground(if (title.len != 0) S.theme.current().well else ui.Color.BLACK);
        try setText(self, self.waiting_title, title);
    }
    fn projectProgress(self: *View, value: console.Snapshot) !void {
        const cx = self.mount_request.cx;
        const progress = value.progress;
        if (self.progress_attempt == null or !self.progress_attempt.?.eql(value.operation)) {
            self.progress_attempt = value.operation;
            self.progress_projection = .{};
            self.progress_disclosure = .{};
            self.progress_failure_scroll = null;
            self.progress_stage_scroll = null;
            self.progress_last_stage = null;
            self.log_revision = null;
        }
        self.progress_active = progress.revision != 0;
        // A real phase change follows the active work once. Timer/revision
        // updates within that phase leave the reader's scroll position alone.
        if (self.progress_active and self.progress_last_stage != progress.stage) {
            self.progress_last_stage = progress.stage;
            self.progress_stage_scroll = if (progress.stage != .streaming and progress.failure_code == null) if (vm.progressGroup(progress.stage)) |group| @intCast(@backingInt(group)) else null else null;
        }
        self.progress_projection.observe(progress);
        const previous_failures = self.progress_disclosure.auto_opened;
        self.progress_disclosure.observe(progress);
        const newly_failed = self.progress_disclosure.auto_opened & ~previous_failures;
        if (newly_failed != 0) {
            if (progress.failure_stage) |stage| {
                if (vm.progressGroup(stage)) |group| self.progress_failure_scroll = @intCast(@backingInt(group));
            } else {
                for (0..vm.progress_group_count) |index| {
                    if (newly_failed & (@as(u8, 1) << @intCast(index)) == 0) continue;
                    self.progress_failure_scroll = index;
                    break;
                }
            }
        }
        var writer: std.Io.Writer.Allocating = .init(cx.allocator);
        defer writer.deinit();
        if (self.progress_active) try writer.writer.print("{d}.{d}", .{ progress.stage_elapsed_ms / 1000, (progress.stage_elapsed_ms % 1000) / 100 }) else try writer.writer.writeAll("—");
        try setText(self, self.progress_stage_time, writer.written());
        writer.clearRetainingCapacity();
        if (self.progress_active) try writer.writer.print("{d}.{d}", .{ progress.elapsed_ms / 1000, (progress.elapsed_ms % 1000) / 100 }) else try writer.writer.writeAll("—");
        try setText(self, self.progress_total_time, writer.written());
        writer.clearRetainingCapacity();
        const failure_code = progress.failure_code orelse value.failure_code;
        if (failure_code) |code| {
            try writer.writer.print("错误码：{s}", .{code});
        } else if (progress.waiting_for_user) {
            try writer.writer.writeAll(if (progress.stage == .waiting_certificate or progress.stage == .waiting_video_certificate) "等待你的操作 · 请完成证书确认" else "等待你的操作 · 请完成凭据输入");
        } else if (self.cancel_pending and progress.stage != .cancelled) {
            try writer.writer.writeAll("正在取消连接，等待本次资源释放");
        } else if (progress.stage == .cancelled) try writer.writer.writeAll("本次连接已取消，目标与路由配置已保留");
        try setText(self, self.progress_notice, writer.written());
        if (self.progress_notice) |node| setTextColorIfChanged(node, if (failure_code != null) S.theme.current().danger_ink else S.progressSecondary());
        writer.clearRetainingCapacity();
        if (failure_code != null and progress.failure_stage == null) {
            try writer.writer.print("{s}\n错误码：{s}", .{ vm.failureReason(failure_code, null), failure_code.? });
        } else if (progress.waiting_for_user) {
            try writer.writer.writeAll(if (progress.stage == .waiting_certificate or progress.stage == .waiting_video_certificate) "请完成证书确认，连接正在等待你的选择。" else "请完成凭据输入，连接正在等待你的操作。");
        } else if (self.cancel_pending and progress.stage != .cancelled) {
            try writer.writer.writeAll("已请求取消，正在释放本次连接。");
        } else if (progress.stage == .cancelled) {
            try writer.writer.writeAll("本次连接已取消，目标与路由配置已保留。");
        } else if (!self.progress_active) {
            try writer.writer.writeAll(if (value.video == .awaiting_frame) "连接仍在线；等待目标发送完整视频帧。" else value.route_summary);
        }
        try setText(self, self.waiting_detail, writer.written());
        if (self.waiting_detail) |node| node.setDisplay(if (writer.written().len == 0) .none else .flex);
        writer.clearRetainingCapacity();
        for (self.progress_icons, self.progress_names, self.progress_states, 0..) |icon, name, status, index| {
            const group: vm.ProgressGroup = @fromBackingInt(@intCast(index));
            const state = self.progress_projection.state(progress, group);
            try setText(self, icon, vm.stepPrefix(state));
            try setText(self, status, vm.stepLabel(state));
            const color = switch (state) {
                .current, .waiting_for_user => S.theme.current().accent_ink,
                .done => S.theme.current().fg_1,
                .warning, .stopped => S.theme.current().warn_ink,
                .failed => S.theme.current().danger_ink,
                .waiting => S.theme.current().fg_1,
            };
            if (icon) |node| setTextColorIfChanged(node, color);
            if (name) |node| setTextColorIfChanged(node, color);
            const current = state == .current or state == .waiting_for_user;
            if (status) |node| setTextColorIfChanged(node, if (current) color else S.progressSecondary());
            if (self.progress_rows[index]) |row| {
                const fill = if (current) S.progressCurrentFill() else ui.Color.TRANSPARENT;
                if (!std.meta.eql(row.getBackground(), fill)) row.setBackground(fill);
            }
            if (self.progress_buttons[index]) |button| if (button.behavior.interaction.a11y) |*a11y| {
                a11y.expanded = self.progress_disclosure.isOpen(group);
            };
            const expanded = self.progress_disclosure.isOpen(group);
            if (self.progress_details[index]) |node| node.setDisplay(if (expanded) .flex else .none);
            try setText(self, self.progress_chevrons[index], if (expanded) "⌄" else "›");
            if (self.log_revision == null or self.log_revision.? != progress.revision) {
                writer.clearRetainingCapacity();
                try vm.writeStepDiagnosticsForTarget(&writer.writer, progress, group, value.target);
                try setText(self, self.progress_details[index], writer.written());
                writer.clearRetainingCapacity();
            }
            if (group == .route) {
                if (progress.route_hops == 0) {
                    try writer.writer.writeAll("建立直连通道");
                } else try writer.writer.print("建立独立 SSH 路由 · {d} 跳", .{progress.route_hops});
                try setText(self, name, writer.written());
                writer.clearRetainingCapacity();
            }
        }
        try setText(self, self.progress_route_text, if (value.route_summary.len != 0) value.route_summary else value.target);
        try setText(self, self.log_route_text, if (value.route_summary.len != 0) value.route_summary else value.target);
        const failed = value.route == .failed or value.video == .failed or failure_code != null;
        const terminal = failed or progress.stage == .cancelled or value.route == .closed or value.video == .closed or value.cleanup == .released;
        if (self.retry_node) |node| node.setDisplay(if (failed or progress.stage == .cancelled) .flex else .none);
        self.retry_disabled.set(value.cleanup != .released);
        const service = self.borrowConsole() catch null;
        const cancel_available = if (service) |borrowed| borrowed.table.cancel != null else false;
        if (self.cancel_node) |node| node.setDisplay(if (!terminal and cancel_available) .flex else .none);
        self.cancel_disabled.set(self.cancel_pending or value.cleanup == .awaiting or value.cleanup == .unknown);
        if (self.log_revision == null or self.log_revision.? != progress.revision) {
            self.captureLogPosition();
            const entries = vm.connectionLogEvents(progress);
            self.log_count = entries.count;
            if (self.log_empty) |node| node.setDisplay(if (entries.count == 0) .flex else .none);
            for (self.log_rows, 0..) |maybe_row, index| {
                const row = maybe_row orelse continue;
                row.setDisplay(if (index < entries.count) .flex else .none);
                if (index >= entries.count) continue;
                const event = entries.events[index];
                self.log_sequences[index] = event.sequence;
                writer.clearRetainingCapacity();
                try vm.writeLogTimestamp(&writer.writer, event);
                try setText(self, self.log_timestamps[index], writer.written());
                writer.clearRetainingCapacity();
                try vm.writeLogMessage(&writer.writer, event, value.target);
                try setText(self, self.log_messages[index], writer.written());
                if (self.log_messages[index]) |message| setTextColorIfChanged(message, if (event.kind == .failure or event.error_code != null) S.theme.current().danger_ink else S.theme.current().fg_1);
                writer.clearRetainingCapacity();
                try vm.writeLogDuration(&writer.writer, event);
                try setText(self, self.log_durations[index], writer.written());
            }
            self.log_revision = progress.revision;
            self.log_layout_pending = true;
        }
    }
    /// PluginWindowHost's earlier hook drains uploaded textures. Read the sink
    /// again in this same safe phase, before display-list emission, so a resize
    /// cannot paint an ID that the host has just retired.
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.closed) return .done;
        const snapshot = self.snapshot orelse return .done;
        const prior_width = self.width;
        const prior_height = self.height;
        self.presentFrame(snapshot.value) catch |err| self.showMessage(@errorName(err));
        self.updateGeometry();
        const popup_changed = self.updatePopovers();
        const progress_scrolled = if (!popup_changed) self.scrollToProgressStep() else false;
        const log_changed = self.updateLogLayout();
        const bounds_changed = self.bounds_layout_pending;
        self.bounds_layout_pending = false;
        return if (prior_width != self.width or prior_height != self.height or popup_changed or progress_scrolled or log_changed or bounds_changed) .needs_layout else .done;
    }
    fn scrollToProgressStep(self: *View) bool {
        const index = self.progress_failure_scroll orelse self.progress_stage_scroll orelse return false;
        const body = self.waiting_body orelse return false;
        const row = self.progress_rows[index] orelse return false;
        if (body.container.globalRect().h <= 0 or row.globalRect().h <= 0) return false;
        body.state.content_height = body.content.globalRect().h;
        body.state.viewport_height = body.container.globalRect().h;
        const top = body.state.scroll_y + row.globalRect().y - body.container.globalRect().y;
        var height = row.globalRect().h;
        if (self.progress_details[index]) |detail| if (detail.style.display != .none) {
            // Show the step header and the beginning of its expanded detail;
            // a long diagnostic remains independently scrollable in the body.
            height += 4 + @min(detail.globalRect().h, 16 + 2 * 18.7);
        };
        const before = body.state.scroll_y;
        ui.widgets.scroll_area.scrollRectIntoView(body.state, body.content, top, @min(height, body.state.viewport_height), if (self.progress_failure_scroll != null) .start else .nearest);
        self.progress_failure_scroll = null;
        self.progress_stage_scroll = null;
        return @abs(before - body.state.scroll_y) > 0.1;
    }
    fn captureLogPosition(self: *View) void {
        if (self.log_open == null or !self.log_open.?.peek()) return;
        const scroll = self.log_scroll orelse return;
        self.log_follow_latest = scroll.state.scroll_y >= scroll.state.maxScrollY() - 1;
        self.log_anchor = null;
        if (self.log_follow_latest or self.log_count == 0) return;
        const content_top = scroll.content.globalRect().y;
        var visible: usize = 0;
        for (self.log_rows[0..self.log_count], 0..) |maybe_row, index| {
            const row = maybe_row orelse continue;
            if (row.globalRect().y - content_top <= scroll.state.scroll_y) visible = index;
        }
        const row = self.log_rows[visible] orelse return;
        const top = row.globalRect().y - content_top;
        self.log_anchor = .{ .sequence = self.log_sequences[visible], .inside = scroll.state.scroll_y - top, .fallback = scroll.state.scroll_y };
    }
    /// Reflow preserved row nodes at the layout safety point. The anchor is an
    /// event sequence plus the position within its row, so wrapping or ring
    /// eviction cannot replace the event the user was reading.
    fn updateLogLayout(self: *View) bool {
        const open = if (self.log_open) |signal| signal.peek() else false;
        const newly_open = open and !self.last_log_open;
        self.last_log_open = open;
        if (!open) return false;
        const detail = self.log_detail orelse return false;
        const scroll = self.log_scroll orelse return false;
        const modal = self.log_modal orelse return false;
        if (newly_open) {
            self.log_follow_latest = true;
            self.log_anchor = null;
        }
        if (!newly_open and !self.log_layout_pending) {
            if (!self.log_scroll_pending) return false;
            scroll.state.content_height = scroll.content.globalRect().h;
            scroll.state.viewport_height = scroll.container.globalRect().h - scroll.container.style.padding.vertical();
            var target = if (self.log_follow_latest) scroll.state.maxScrollY() else scroll.state.scroll_y;
            if (!self.log_follow_latest) if (self.log_anchor) |anchor| {
                target = anchor.fallback;
                for (self.log_sequences[0..self.log_count], 0..) |sequence, index| if (sequence == anchor.sequence) {
                    const row = self.log_rows[index] orelse continue;
                    target = row.globalRect().y - scroll.content.globalRect().y + anchor.inside;
                    break;
                };
            };
            ui.widgets.scroll_area.setScrollY(scroll.state, scroll.content, target);
            self.log_scroll_pending = false;
            self.log_anchor = null;
            return false;
        }
        for (self.log_messages[0..self.log_count]) |maybe_message| if (maybe_message) |message| {
            message.clearTextLayout();
            message.markSizingDirty();
        };
        detail.markSizingDirty();
        scroll.content.markSizingDirty();
        scroll.container.markSizingDirty();
        modal.body.markSizingDirty();
        modal.dialog.markSizingDirty();
        modal.overlay.markSizingDirty();
        self.log_layout_pending = false;
        self.log_scroll_pending = true;
        return true;
    }
    fn updatePopovers(self: *View) bool {
        var changed = self.updateProgressBounds();
        for (self.menus, self.menu_scrolls, 0..) |maybe_popup, maybe_scroll, index| {
            if (!self.open[index].peek()) continue;
            const popup = maybe_popup orelse continue;
            const scroll = maybe_scroll orelse continue;
            const natural_height = popup.content.globalRect().h;
            if (natural_height <= 0) continue;
            const cap = @max(1, @min(self.mount_request.cx.viewport.height - 24, popup.chrome.style.max_height()) - S.popup_header_height);
            const wanted = @max(1, @min(natural_height, cap));
            const current = switch (scroll.container.style.height) {
                .px => |value| value,
                else => @as(f32, -1),
            };
            if (@abs(current - wanted) > 0.1) {
                scroll.container.setStyleInline(self.mount_request.cx.allocator, .{ .height = .{ .px = wanted }, .flex_shrink = 0 });
                changed = true;
            }
        }
        return changed;
    }
    fn updateProgressBounds(self: *View) bool {
        const cx = self.mount_request.cx;
        var changed = false;
        if (self.waiting) |waiting| if (self.waiting_body) |body| {
            const route_height = if (self.progress_route) |route| route.globalRect().h else 0;
            const body_height = @max(0, waiting.globalRect().h - S.progress_padding * 2 - S.progress_header_height - S.progress_action_height - S.progress_gap * 3 - route_height);
            changed = setHeight(cx, body.container, body_height) or changed;
        };
        if (self.log_modal) |modal| {
            const compact = cx.viewport.height < 600;
            const width = @min(S.log_width, @max(1, cx.viewport.width - 32));
            const route_height = if (self.log_route_text) |route| route.globalRect().h else 0;
            const bounds: LogBounds = .{ .width = width, .height = cx.viewport.height, .route_height = route_height, .compact = compact, .theme = cx.theme_version };
            if (self.log_bounds) |old| if (std.meta.eql(old, bounds)) return changed;
            self.log_bounds = bounds;
            self.bounds_layout_pending = true;
            modal.dialog.setStyleInline(cx.allocator, .{ .width = .{ .px = width }, .height = .{ .fit = .{ .max = @max(1, cx.viewport.height - 32) } }, .flex_shrink = 0, .background = S.theme.current().overlay, .glass = S.theme.overlayGlass(), .border = .{ .radius = 14 } });
            if (modal.dialog.children.items.len != 0) modal.dialog.children.items[0].setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = if (compact) .{ .left = 18, .right = 18, .top = 12, .bottom = 12 } else .{ .left = 20, .right = 20, .top = 14, .bottom = 14 }, .flex_shrink = 0 });
            modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = if (compact) .{ .left = 18, .right = 34, .bottom = 12 } else .{ .left = 24, .right = 40, .bottom = 20 }, .gap = 0, .min_height = 0, .flex_shrink = 0 });
            if (self.log_footer) |footer| footer.setStyleInline(cx.allocator, S.logFooter(compact));
            if (self.log_scroll) |scroll| {
                scroll.container.setBackground(S.theme.current().well);
                const cap = @max(1, cx.viewport.height - 32 - (if (compact) @as(f32, 130.5) else @as(f32, 150.5)) - route_height - 12 - 28);
                const height = @min(if (compact) @as(f32, 200) else @as(f32, 320), cap);
                changed = setHeight(cx, scroll.container, height) or changed;
            }
        }
        return changed;
    }
    fn refreshManagement(self: *View) !void {
        const call: services.Call = .{ .owner = self.mount_request.owner, .binding_generation = self.mount_request.owner.generation };
        if (self.management_operation) |operation| {
            if (try self.lookup(services.power_definition)) |binding| {
                const table = try binding.borrow(services.PowerService, services.power_key, self.mount_request.owner);
                const next = try table.result(binding.context, call, operation.key, self.mount_request.cx.allocator);
                if (operation.boot and next.value.phase == .succeeded and (if (self.management_result) |old| old.value.phase != .succeeded else true)) self.draft.initialized = false;
                if (self.management_result) |*old| old.deinit();
                self.management_result = next;
            }
        }
        if (try self.lookup(services.power_definition)) |binding| {
            const table = try binding.borrow(services.PowerService, services.power_key, self.mount_request.owner);
            const next = try table.snapshot(binding.context, call, self.mount_request.cx.allocator);
            if (self.power_snapshot) |*old| old.deinit();
            self.power_snapshot = next;
        }
        if (try self.lookup(services.boot_definition)) |binding| {
            const table = try binding.borrow(services.BootService, services.boot_key, self.mount_request.owner);
            var next = try table.snapshot(binding.context, call, self.mount_request.cx.allocator);
            errdefer next.deinit();
            try self.draft.refresh(next.value);
            if (self.boot_snapshot) |*old| old.deinit();
            self.boot_snapshot = next;
        }
        try self.projectManagement();
    }
    fn projectManagement(self: *View) !void {
        self.option_slot = 1 - self.option_slot;
        const slot = self.option_slot;
        const power_unmapped = if (self.power_snapshot) |snapshot| snapshot.value.system_uri.len != 0 and !snapshot.value.capability.system_mapping_verified else false;
        const boot_unmapped = if (self.boot_snapshot) |snapshot| snapshot.value.system_uri.len != 0 and !snapshot.value.capability.system_mapping_verified else false;
        const power_diagnostic = if (self.power_snapshot) |snapshot| snapshot.value.resource_evidence.validity == .partial_with_error else false;
        const boot_diagnostic = if (self.boot_snapshot) |snapshot| snapshot.value.resource_evidence.validity == .partial_with_error else false;
        if (self.power_mapping_warning) |node| node.setDisplay(if (power_unmapped or power_diagnostic) .flex else .none);
        if (self.boot_mapping_warning) |node| node.setDisplay(if (boot_unmapped or boot_diagnostic) .flex else .none);
        if (self.order_mapping_warning) |node| node.setDisplay(if (boot_unmapped or boot_diagnostic) .flex else .none);
        try setText(self, self.power_mapping_warning, if (power_unmapped) unverified_mapping_message else response_diagnostic_message);
        try setText(self, self.boot_mapping_warning, if (boot_unmapped) unverified_mapping_message else response_diagnostic_message);
        try setText(self, self.order_mapping_warning, if (boot_unmapped) unverified_mapping_message else response_diagnostic_message);
        try setText(self, self.power_scope_label, if (power_unmapped) "资源电源状态" else "当前电源");
        try setText(self, self.boot_scope_label, if (boot_unmapped) "资源启动覆盖" else "当前启动覆盖");
        var power_count: usize = 0;
        if (self.power_snapshot) |snapshot| {
            var state_buffer: [128]u8 = undefined;
            const label = vm.powerStateLabel(snapshot.value.state.value);
            try setText(self, self.power_label, if (snapshot.value.state.value != null and snapshot.value.state.evidence.validity != .valid) try std.fmt.bufPrint(&state_buffer, "{s}（部分结果）", .{label}) else label);
            for (power_actions, power_option_ids) |action, id| if (services.contains(snapshot.value.reset_types.value orelse &.{}, action.redfish())) {
                self.power_storage[slot][power_count] = .{ .value = action.redfish(), .label = vm.powerLabel(action), .test_id = id };
                power_count += 1;
            };
        }
        self.power_options.set(self.power_storage[slot][0..power_count]);
        const locked = self.managementLocked();
        const power_ready = if (self.power_snapshot) |snapshot| vm.writeAllowed(snapshot.value.capability) and snapshot.value.capability.secondary_auth == .disabled else false;
        // Selecting a local draft is harmless in a read-only session. Only the
        // execute button consumes operation authority and field readiness.
        self.power_disabled.set(locked or power_unmapped or power_count == 0);
        self.power_execute_disabled.set(locked or !power_ready or (if (self.power_snapshot) |snapshot| !vm.powerAllowed(snapshot.value, self.power_choice) else true));
        var target_count: usize = 0;
        var mode_count: usize = 0;
        if (self.boot_snapshot) |snapshot| {
            const value = snapshot.value;
            const current = value.state;
            var buffer: [768]u8 = undefined;
            const partial = (current.enabled != null and value.enabled_evidence.validity != .valid) or (current.target != null and value.target_evidence.validity != .valid) or (current.mode != null and value.mode_evidence.validity != .valid);
            const text = if (services.optionalEqual(current.enabled, "Disabled")) (if (partial) "未覆盖（部分结果）" else "未覆盖") else try std.fmt.bufPrint(&buffer, "{s} · {s} · {s}{s}", .{ current.target orelse "未知设备", current.enabled orelse "未知有效期", current.mode orelse "未知模式", if (partial) "（部分结果）" else "" });
            try setText(self, self.boot_label, text);
            if (value.pending) |pending| {
                const pending_text = try std.fmt.bufPrint(&buffer, "待生效：{s} · {s} · {s}", .{ pending.target orelse "未知设备", pending.enabled orelse "未知有效期", pending.mode orelse "未知模式" });
                try setText(self, self.boot_pending_label, pending_text);
            }
            if (self.boot_pending_label) |node| node.setDisplay(if (value.pending != null) .flex else .none);
            for (target_values, target_names, target_option_ids) |target, name, id| {
                const allowed = if (std.mem.eql(u8, target, "Disabled")) services.contains(value.allowed_enabled.value orelse &.{}, "Disabled") else services.contains(value.allowed_targets.value orelse &.{}, target);
                if (!allowed) continue;
                self.target_storage[slot][target_count] = .{ .value = target, .label = name, .test_id = id };
                target_count += 1;
            }
            for (mode_values) |mode| if (services.contains(value.allowed_modes.value orelse &.{}, mode)) {
                self.mode_storage[slot][mode_count] = .{ .value = mode, .label = mode, .test_id = if (std.mem.eql(u8, mode, "UEFI")) "bmc.boot.mode_option.uefi" else "bmc.boot.mode_option.legacy" };
                mode_count += 1;
            };
            try self.refreshOrder(value.boot_order.value);
        }
        self.boot_options.set(self.target_storage[slot][0..target_count]);
        self.mode_options.set(self.mode_storage[slot][0..mode_count]);
        const boot_ready = if (self.boot_snapshot) |snapshot| vm.writeAllowed(snapshot.value.capability) and snapshot.value.capability.secondary_auth == .disabled else false;
        self.boot_disabled.set(locked or boot_unmapped or target_count == 0);
        self.mode_disabled.set(locked or boot_unmapped or mode_count == 0);
        self.boot_execute_disabled.set(locked or !boot_ready or (if (self.boot_snapshot) |snapshot| !self.draft.canApply(snapshot.value) else true));
        const enabled_ready = if (self.boot_snapshot) |snapshot| snapshot.value.enabled_evidence.permitsWrite() and snapshot.value.allowed_enabled.evidence.permitsWrite() else false;
        self.switch_disabled.set(locked or boot_unmapped or !enabled_ready or self.draft.disabled());
        self.target_value.set(if (self.draft.disabled()) "Disabled" else canonicalTarget(self.draft.value.target.get()));
        self.mode_value.set(canonicalMode(self.draft.value.mode.get()));
        self.boot_continuous.set(self.draft.continuous());
        if (self.boot_details) |node| node.setDisplay(if (!self.draft.initialized or self.draft.disabled()) .none else .flex);
        if (self.mode_row) |node| node.setDisplay(if (mode_count > 0) .flex else .none);
        const result = if (self.management_result) |value| value.value else null;
        const operation = self.management_operation;
        const unknown = if (result) |value| value.phase == .outcome_unknown else false;
        const running = if (result) |value| !value.terminal() else false;
        if (self.power_query) |node| node.setDisplay(if (unknown and operation != null and !operation.?.boot) .flex else .none);
        if (self.boot_query) |node| node.setDisplay(if (unknown and operation != null and operation.?.boot) .flex else .none);
        if (self.power_cancel) |node| node.setDisplay(if (running and operation != null and !operation.?.boot) .flex else .none);
        if (self.boot_cancel) |node| node.setDisplay(if (running and operation != null and operation.?.boot) .flex else .none);
        const power_reason = if (self.power_snapshot) |snapshot| vm.powerUnavailableReason(snapshot.value, self.power_choice) else @as(?[]const u8, "管理通道当前不可用。");
        const power_hint = if (result != null and operation != null and !operation.?.boot) vm.resultLabel(result.?) else if (power_reason) |reason| reason else if (self.power_choice == .force_off or self.power_choice == .force_restart or self.power_choice == .power_cycle) "强制动作可能造成数据丢失；点击执行后核对并批准本次操作。" else "选择不会执行；点击执行后核对并批准本次操作。";
        try setText(self, self.power_hint, power_hint);
        const boot_reason = if (self.boot_snapshot) |snapshot| self.draft.unavailableReason(snapshot.value) else @as(?[]const u8, "管理通道当前不可用。");
        try setText(self, self.boot_hint, if (result != null and operation != null and operation.?.boot) vm.resultLabel(result.?) else if (boot_unmapped) "仅查看该管理资源的启动覆盖与顺序，不会写入或重启。" else if (boot_reason) |reason| reason else "仅设置启动覆盖，不会自动重启。USB / 光驱指目标机已有设备，不提供镜像挂载。");
    }
    fn updateGeometry(self: *View) void {
        const alloc = self.mount_request.cx.allocator;
        const viewport = self.viewport orelse return;
        const rect = viewport.globalRect();
        const area = self.scroll orelse return;
        const g = self.geometry();
        if (g) |geometry_value| {
            const dw = geometry_value.image.width;
            const dh = geometry_value.image.height;
            area.content.setStyleInline(alloc, .{ .width = .{ .px = @max(rect.w, dw) }, .height = .{ .px = @max(rect.h, dh) }, .flex_shrink = 0 });
            if (self.image_node) |node| node.setStyleInline(alloc, .{ .width = .{ .px = dw }, .height = .{ .px = dh }, .position = .absolute, .inset = .{ .left = .{ .px = @max(0, (rect.w - dw) / 2) }, .top = .{ .px = @max(0, (rect.h - dh) / 2) } } });
            if (self.mode == .fit) {
                area.state.scroll_x = 0;
                area.state.bonus_x = 0;
                area.state.bonus_velocity_x = 0;
                area.state.bounce_active_x = false;
                ui.widgets.scroll_area.setScrollY(area.state, area.content, 0);
                area.content.setStyleInline(alloc, .{ .translate_x = 0, .translate_y = 0 });
            }
        } else area.content.setStyleInline(alloc, .{ .width = .{ .px = @max(1, rect.w) }, .height = .{ .px = @max(1, rect.h) } });
        if (self.waiting) |node| {
            const width = @min(@max(rect.w - 32, 0), S.progress_width);
            const height = @min(@max(rect.h - 24, 0), S.progress_height);
            const bounds: WaitingBounds = .{ .width = rect.w, .height = rect.h, .theme = self.mount_request.cx.theme_version };
            // setTheme invokes the root's before-render hook before replaying
            // descendant recipes. That replay can restore the recipe's base
            // height after this cache was filled; repair only that mismatch.
            const size_changed = node.style.width != .px or @abs(node.style.width.px - width) > 0.1 or node.style.height != .px or @abs(node.style.height.px - height) > 0.1;
            if (self.waiting_bounds == null or !std.meta.eql(self.waiting_bounds.?, bounds) or size_changed) {
                self.waiting_bounds = bounds;
                node.setStyleInline(alloc, .{ .width = .{ .px = width }, .height = .{ .px = height }, .inset = .{ .left = .{ .px = @max(0, (rect.w - width) / 2) }, .top = .{ .px = @max(12, (rect.h - height) / 2) } } });
                self.bounds_layout_pending = true;
            }
        }
        if (self.toolbar) |bar| {
            // The measured compact prototype reduces button width, retaining all
            // five entries in one row at the product's minimum window width.
            const compact = rect.w < 1000;
            bar.setStyleInline(alloc, .{ .gap = 6, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 } });
            if (self.last_compact == null or self.last_compact.? != compact or self.last_theme_version != self.mount_request.cx.theme_version) {
                self.last_compact = compact;
                self.last_theme_version = self.mount_request.cx.theme_version;
                var style = S.tool();
                style.width = .{ .px = if (compact) 74 else 82 };
                style.font_size = if (compact) 11 else 12;
                for (self.tool_styles) |source| source.set(style);
                self.tool_hover.set(S.toolHover());
                self.key_style.set(S.keyButton());
                self.fit_style.set(S.segment(self.mode == .fit));
                self.original_style.set(S.segment(self.mode == .original));
                for (self.menus) |maybe| if (maybe) |popup| popup.chrome.setStyleInline(alloc, S.popup());
                if (self.order_modal) |modal| modal.dialog.setStyleInline(alloc, .{ .background = S.theme.current().overlay, .glass = S.theme.overlayGlass() });
            }
        }
    }
    fn update(raw: *anyopaque, value: contract.ContentUpdate) !void {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.closed or !value.owner.eql(self.mount_request.owner)) return error.StaleBinding;
        try self.refresh(self.mount_request.cx.frame_time_ms);
    }
    fn connectionStatus(raw: *anyopaque) contract.ConnectionStatus {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.closed) return .{ .state = .ended, .label = "已结束" };
        const snapshot = self.snapshot orelse return .{ .state = .connecting, .label = "正在准备连接" };
        const value = snapshot.value;
        if (value.cleanup == .unknown) return .{ .state = .degraded, .label = "清理结果待确认" };
        if (value.cleanup == .awaiting) return .{ .state = .connecting, .label = "正在释放连接" };
        if (value.progress.stage == .cancelled) return .{ .state = .ended, .label = "连接已取消" };
        if (value.progress.failure_code != null) return .{ .state = .degraded, .label = "连接失败" };
        if (value.route == .closed or value.video == .closed) return .{ .state = .ended, .label = "已结束" };
        if (value.route == .failed or value.video == .failed) return .{ .state = .degraded, .label = if (self.texture != null) "视频已中断" else "连接失败" };
        if (value.cleanup == .released) return .{ .state = .ended, .label = "已结束" };
        if (value.video == .streaming) {
            const power_unmapped = if (self.power_snapshot) |resource| resource.value.system_uri.len != 0 and !resource.value.capability.system_mapping_verified else false;
            const boot_unmapped = if (self.boot_snapshot) |resource| resource.value.system_uri.len != 0 and !resource.value.capability.system_mapping_verified else false;
            if (self.texture != null and self.frame_generation == value.frame_generation and (power_unmapped or boot_unmapped)) return .{ .state = .degraded, .label = "视频在线 · 管理条件待核实" };
            return .{ .state = .online, .label = if (value.management == .unavailable) "视频在线 · 管理不可用" else "视频在线" };
        }
        return .{ .state = .connecting, .label = if (value.progress.revision != 0) console.progress.stageLabel(value.progress.stage) else switch (value.video) {
            .authenticating => "正在验证视频会话",
            .negotiating => "正在协商视频通道",
            .awaiting_frame => "正在等待视频帧",
            else => "正在建立独立连接",
        } };
    }
    fn focus(raw: *anyopaque, focused: bool) void {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.closed) return;
        self.window_focused = focused;
        if (!focused) {
            self.closeMenus();
            self.releaseInput(.lost_focus);
        }
        self.mount_request.cx.requestRedraw();
    }
    fn unmount(raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        self.release();
    }
    fn release(self: *View) void {
        if (self.closed) return;
        self.closeMenus();
        self.releaseInput(.closed);
        if (self.root) |node| {
            node.removeBeforeRender(beforeRender);
            node.meta.per_frame.hooks.slots.anim_state = null;
        }
        if (self.after_layout_registered) self.mount_request.cx.removeAfterLayoutHook(self);
        self.after_layout_registered = false;
        self.closed = true;
        if (self.snapshot) |*value| value.deinit();
        if (self.power_snapshot) |*value| value.deinit();
        if (self.boot_snapshot) |*value| value.deinit();
        if (self.management_result) |*value| value.deinit();
        self.snapshot = null;
        self.power_snapshot = null;
        self.boot_snapshot = null;
        self.management_result = null;
        self.management_operation = null;
        self.power_query = null;
        self.boot_query = null;
        self.power_cancel = null;
        self.boot_cancel = null;
        // GPU texture, content/window facade and protocol producer remain host
        // owned. Unmount releases presentation references and never joins IO.
        self.root = null;
        self.toolbar = null;
        self.connection_title = null;
        self.viewport = null;
        self.scroll = null;
        self.image_node = null;
        self.waiting = null;
        self.waiting_header = null;
        self.waiting_title = null;
        self.waiting_detail = null;
        self.waiting_body = null;
        self.waiting_actions = null;
        self.progress_timing = null;
        self.progress_stage_time = null;
        self.progress_total_time = null;
        self.progress_notice = null;
        self.progress_steps = null;
        self.progress_rows = @splat(null);
        self.progress_buttons = @splat(null);
        self.progress_details = @splat(null);
        self.progress_chevrons = @splat(null);
        self.progress_icons = @splat(null);
        self.progress_names = @splat(null);
        self.progress_states = @splat(null);
        self.progress_route = null;
        self.progress_route_text = null;
        self.cancel_node = null;
        self.retry_node = null;
        self.log_open = null;
        self.log_modal = null;
        self.log_footer = null;
        self.log_scroll = null;
        self.log_detail = null;
        self.log_empty = null;
        self.log_rows = @splat(null);
        self.log_timestamps = @splat(null);
        self.log_messages = @splat(null);
        self.log_durations = @splat(null);
        self.log_route_text = null;
        self.control_label = null;
        self.control_request_row = null;
        self.power_label = null;
        self.power_scope_label = null;
        self.power_mapping_warning = null;
        self.power_hint = null;
        self.boot_label = null;
        self.boot_scope_label = null;
        self.boot_mapping_warning = null;
        self.boot_pending_label = null;
        self.boot_hint = null;
        self.boot_details = null;
        self.boot_switch = null;
        self.mode_row = null;
        self.order_rows = null;
        self.order_mapping_warning = null;
        self.order_open = null;
        self.order_modal = null;
        self.order_scroll = null;
        self.message = null;
        self.input_hint = null;
        self.menus = @splat(null);
        self.menu_scrolls = @splat(null);
        self.tool_nodes = @splat(null);
    }
    fn requestControl(self: *View) void {
        self.releaseInput(.released);
        const service = self.borrowConsole() catch return;
        service.table.request_control(service.binding.context, service.binding) catch |err| self.showMessage(@errorName(err));
        self.watch_only_selected = false;
    }
    fn capture(self: *View) void {
        self.closeMenus();
        self.watch_only_selected = false;
        const binding = (self.lookup(input.definition) catch null) orelse return;
        const table = binding.borrow(input.Interface, input.key, self.mount_request.owner) catch return;
        const snapshot = table.snapshot(binding.context, binding) catch return;
        // Popover exit is asynchronous. Keep the user's click tied to the
        // visible attempt instead of silently recapturing a later connection.
        self.pending_capture_authority = .{ .binding_generation = binding.generation, .input_epoch = snapshot.input_epoch, .control_generation = snapshot.control_generation, .transport_generation = snapshot.transport_generation, .frame_generation = self.frame_generation };
        self.pending_capture = true;
    }
    fn releaseCapture(self: *View) void {
        self.releaseInput(.released);
        if (self.mount_request.cx.focus_manager.getFocused() == self.viewport) self.mount_request.cx.focus_manager.clearFocus();
    }
    fn onlyView(self: *View) void {
        self.releaseInput(.released);
        self.view_only = true;
        self.watch_only_selected = true;
        self.closeMenus();
    }
    fn fit(self: *View) void {
        self.setMode(.fit);
    }
    fn original(self: *View) void {
        self.setMode(.original);
    }
    fn setMode(self: *View, mode: mapping.Mode) void {
        self.releaseInput(.released);
        self.mode = mode;
        self.fit_style.set(S.segment(mode == .fit));
        self.original_style.set(S.segment(mode == .original));
        self.mount_request.cx.requestRedraw();
    }
    fn fullscreen(self: *View) void {
        self.releaseInput(.released);
        const context = self.mount_request.content_context orelse return;
        context.requestFullscreen(!context.fullscreen()) catch |err| self.showMessage(@errorName(err));
    }
    fn refreshVideo(self: *View) void {
        self.releaseInput(.released);
        const service = self.borrowConsole() catch return;
        service.table.refresh(service.binding.context, service.binding) catch |err| self.showMessage(@errorName(err));
    }
    fn retry(self: *View) void {
        self.releaseInput(.released);
        const service = self.borrowConsole() catch return;
        service.table.retry(service.binding.context, service.binding) catch |err| self.showMessage(@errorName(err));
    }
    fn cancel(self: *View) void {
        if (self.closed or self.cancel_pending) return;
        self.releaseInput(.released);
        const service = self.borrowConsole() catch return;
        const callback = service.table.cancel orelse return;
        callback(service.binding.context, service.binding) catch |err| {
            self.showMessage(@errorName(err));
            return;
        };
        self.cancel_pending = true;
        self.cancel_disabled.set(true);
        self.mount_request.cx.requestRedraw();
    }
    fn showLog(self: *View) void {
        if (self.closed) return;
        self.releaseInput(.released);
        self.closeMenus();
        if (self.log_open) |open| open.set(true);
        if (self.log_scroll) |scroll| self.mount_request.cx.focus_manager.setFocus(scroll.container);
        self.mount_request.cx.requestRedraw();
    }
    fn closeLog(self: *View) void {
        if (self.log_open) |open| open.set(false);
    }
    fn progressKey(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (self.closed) return .ignored;
        return scrollKey(self.waiting_body orelse return .ignored, event);
    }
    fn logKey(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (self.closed) return .ignored;
        return scrollKey(self.log_scroll orelse return .ignored, event);
    }
    fn powerChanged(self: *View, selected: ?[]const u8) void {
        const value = selected orelse return;
        for (power_actions) |action| if (std.mem.eql(u8, value, action.redfish())) {
            self.power_choice = action;
            break;
        };
        self.projectManagement() catch {};
    }
    fn targetChanged(self: *View, selected: ?[]const u8) void {
        const value = selected orelse return;
        self.draft.selectTarget(value) catch return;
        self.projectManagement() catch {};
    }
    fn modeChanged(self: *View, selected: ?[]const u8) void {
        self.draft.selectMode(selected orelse return) catch {};
        self.projectManagement() catch {};
    }
    fn continuousChanged(self: *View, value: bool) void {
        self.draft.setContinuous(value) catch {};
        self.projectManagement() catch {};
    }
    fn managementLocked(self: *const View) bool {
        return if (self.management_result) |value| !value.value.terminal() or value.value.phase == .outcome_unknown else false;
    }
    fn execution(self: *View, capability: services.Capability, system_uri: []const u8) services.Execution {
        var nonce: [16]u8 = undefined;
        std.c.arc4random_buf(&nonce, nonce.len);
        if (std.mem.allEqual(u8, &nonce, 0)) nonce[0] = 1;
        var operation_id: u64 = undefined;
        std.c.arc4random_buf(@ptrCast(&operation_id), @sizeOf(u64));
        return .{ .call = .{ .owner = self.mount_request.owner, .binding_generation = capability.binding_generation }, .operation = .{ .owner = .{ .session = self.mount_request.owner }, .operation_id = operation_id | 1, .attempt_id = self.mount_request.owner.generation }, .nonce = nonce, .system_uri = system_uri, .capability_revision = capability.revision, .grant_revision = capability.grant_revision };
    }
    fn executePower(self: *View) void {
        if (self.closed or self.power_execute_disabled.peek() or self.managementLocked()) return;
        const snapshot = self.power_snapshot orelse return;
        self.submitManagement(.{ .power = .{ .execution = self.execution(snapshot.value.capability, snapshot.value.system_uri), .action = self.power_choice } });
    }
    fn executeBoot(self: *View) void {
        if (self.closed or self.boot_execute_disabled.peek() or self.managementLocked()) return;
        const snapshot = self.boot_snapshot orelse return;
        const draft = self.draft.value.state();
        self.submitManagement(.{ .boot = .{ .execution = self.execution(snapshot.value.capability, snapshot.value.system_uri), .baseline = self.draft.baseline.state(), .enabled = draft.enabled, .target = if (self.draft.disabled()) null else draft.target, .mode = if (self.draft.disabled()) null else draft.mode, .etag = snapshot.value.etag } });
    }
    fn submitManagement(self: *View, request: services.ManagementRequest) void {
        const borrowed = self.borrowConsole() catch return;
        const request_management = borrowed.table.request_management orelse {
            self.showMessage("当前会话未提供管理操作批准入口。");
            return;
        };
        self.releaseInput(.released);
        switch (request_management(borrowed.binding.context, borrowed.binding, request)) {
            .accepted => |key| {
                self.management_operation = .{ .key = key, .boot = request == .boot };
                if (self.management_result) |*old| old.deinit();
                self.management_result = services.Owned(services.Result).init(self.mount_request.cx.allocator, .{ .operation = key, .phase = .awaiting_approval }) catch null;
                self.projectManagement() catch {};
            },
            .rejected => |reason| self.showMessage(vm.reasonLabel(reason)),
        }
        self.mount_request.cx.requestRedraw();
    }
    fn queryManagement(self: *View) void {
        const operation = self.management_operation orelse return;
        const binding = (self.lookup(services.power_definition) catch return) orelse return;
        const table = binding.borrow(services.PowerService, services.power_key, self.mount_request.owner) catch return;
        const query = table.query orelse return;
        query(binding.context, .{ .owner = self.mount_request.owner, .binding_generation = self.mount_request.owner.generation }, operation.key) catch {
            self.showMessage("当前无法查询管理操作结果。");
            return;
        };
        if (self.management_result) |*value| value.value.phase = .verifying;
        self.projectManagement() catch {};
        self.mount_request.cx.requestRedraw();
    }
    fn cancelManagement(self: *View) void {
        const operation = self.management_operation orelse return;
        const binding = (self.lookup(services.power_definition) catch return) orelse return;
        const table = binding.borrow(services.PowerService, services.power_key, self.mount_request.owner) catch return;
        const result = table.cancel(binding.context, .{ .owner = self.mount_request.owner, .binding_generation = self.mount_request.owner.generation }, operation.key);
        self.showMessage(if (result == .cancelled_unsent) "已取消，本次请求未发送。" else if (result == .observation_stopped_remote_may_continue) "已停止等待；设备可能继续执行，仅可查询结果。" else "该操作已经结束或会话已变化。");
        self.refreshManagement() catch {};
        self.mount_request.cx.requestRedraw();
    }
    fn refreshOrder(self: *View, order: ?[]const []const u8) !void {
        const rows = self.order_rows orelse return;
        const cx = self.mount_request.cx;
        const references = order orelse &.{};
        const count = @max(1, @min(references.len, 256));
        var writer: std.Io.Writer.Allocating = .init(cx.allocator);
        defer writer.deinit();
        for (0..count) |index| {
            // Separate native text nodes give every option its own measured
            // row; a newline inside one shaped text run is not a row boundary.
            if (index == rows.children.items.len) {
                const row = try ui.textStyled(cx, S.orderText, "");
                row.setStyleInline(cx.allocator, S.orderRow());
                var id: [48]u8 = undefined;
                row.meta.ownership.meta.test_id = try ownedText(self.mount_request.scope, try std.fmt.bufPrint(&id, "bmc.boot.order_row.{d:0>2}", .{index + 1}));
                try rows.appendChild(cx.allocator, row);
            }
            writer.clearRetainingCapacity();
            if (references.len == 0) try writer.writer.writeAll("设备尚未返回启动顺序。") else try writer.writer.print("{d:0>2}  {s}", .{ index + 1, references[index] });
            const row = rows.children.items[index];
            try setText(self, row, writer.written());
            row.setDisplay(.flex);
        }
        for (rows.children.items[count..]) |row| row.setDisplay(.none);
    }
    fn showOrder(self: *View) void {
        self.releaseInput(.released);
        self.closeMenus();
        if (self.order_open) |open| open.set(true);
        if (self.order_scroll) |scroll| self.mount_request.cx.focus_manager.setFocus(scroll.container);
    }
    fn orderKey(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (self.closed or event != .key_down) return .ignored;
        const scroll = self.order_scroll orelse return .ignored;
        const current = scroll.state.scroll_y;
        const next: f32 = switch (event.key_down.key) {
            .home => 0,
            .end => scroll.state.maxScrollY(),
            .page_up => current - scroll.state.viewport_height,
            .page_down => current + scroll.state.viewport_height,
            .up => current - 22,
            .down => current + 22,
            else => return .ignored,
        };
        ui.widgets.scroll_area.setScrollY(scroll.state, scroll.content, next);
        return .stop;
    }
};

const MenuAction = struct {
    view: *View,
    menu: Menu,
    fn toggle(self: *MenuAction) void {
        const index = @backingInt(self.menu);
        const should_open = !self.view.open[index].peek();
        self.view.releaseInput(.released);
        self.view.closeMenus();
        self.view.open[index].set(should_open);
    }
    fn close(self: *MenuAction) void {
        self.view.open[@backingInt(self.menu)].set(false);
    }
    fn changed(self: *MenuAction, open: bool) void {
        if (open) self.view.releaseInput(.released);
    }
};
const ChordAction = struct {
    view: *View,
    chord: input.Chord,
    fn send(self: *ChordAction) void {
        self.view.releaseInput(.released);
        // Explicit menu input has its own epoch and never acquires ordinary
        // keyboard focus. Both paths share the same monotonic sequence.
        if (comptime @hasField(input.Interface, "submit_chord")) {
            const binding = (self.view.lookup(input.definition) catch null) orelse return;
            const table = binding.borrow(input.Interface, input.key, self.view.mount_request.owner) catch return;
            const submit_chord = table.submit_chord orelse return;
            const snapshot = table.snapshot(binding.context, binding) catch return;
            if (!snapshot.controlled or !snapshot.connected) return;
            self.view.input_sequence = @max(self.view.input_sequence, snapshot.last_input_sequence);
            if (self.view.input_sequence == std.math.maxInt(u64)) return;
            self.view.input_sequence += 1;
            const result = submit_chord(binding.context, binding, .{ .session_handle = self.view.mount_request.owner, .binding_generation = binding.generation, .input_sequence = self.view.input_sequence, .input_epoch = snapshot.explicit_input_epoch, .control_generation = snapshot.control_generation, .transport_generation = snapshot.transport_generation, .chord = self.chord });
            if (result != .accepted) self.view.showMessage("按键未发送；请检查当前控制权。");
        } else self.view.showMessage("当前宿主尚未提供按键菜单的安全发送入口。");
    }
};
const ReplyAction = struct {
    view: *View,
    reply: console.ControlReply,
    fn send(self: *ReplyAction) void {
        self.view.releaseInput(.released);
        const service = self.view.borrowConsole() catch return;
        var snapshot = service.table.snapshot(service.binding.context, service.binding, self.view.mount_request.cx.allocator) catch return;
        defer snapshot.deinit();
        const request = snapshot.value.control_request orelse return;
        service.table.reply_control(service.binding.context, service.binding, request, self.reply) catch |err| self.view.showMessage(@errorName(err));
    }
};

const ProgressStepAction = struct {
    view: *View,
    group: vm.ProgressGroup,
    fn toggle(self: *ProgressStepAction) void {
        self.view.progress_disclosure.toggle(self.group);
        if (self.view.snapshot) |snapshot| self.view.projectProgress(snapshot.value) catch {};
        self.view.mount_request.cx.requestRedraw();
    }
};

pub fn mount(_: ?*anyopaque, request: contract.ContentMount) !contract.RendererInstance {
    if (request.service_access == null) return error.ServiceUnavailable;
    const cx = request.cx;
    const scope = request.scope;
    const state = try cx.bindState(View, .{ .mount_request = request });
    errdefer state.release();
    for (&state.open) |*value| {
        value.* = try scope.createSignal(bool, false);
        state.menu_signal_count += 1;
    }
    state.keys_disabled = try scope.createSignal(bool, true);
    for (&state.tool_styles) |*source| source.* = try scope.createSignal(ui.BoxStyle, S.tool());
    state.tool_hover = try scope.createSignal(?ui.BoxStyle, S.toolHover());
    state.key_style = try scope.createSignal(ui.BoxStyle, S.keyButton());
    state.request_disabled = try scope.createSignal(bool, true);
    state.capture_disabled = try scope.createSignal(bool, true);
    state.power_disabled = try scope.createSignal(bool, true);
    state.boot_disabled = try scope.createSignal(bool, true);
    state.mode_disabled = try scope.createSignal(bool, true);
    state.power_execute_disabled = try scope.createSignal(bool, true);
    state.boot_execute_disabled = try scope.createSignal(bool, true);
    state.switch_disabled = try scope.createSignal(bool, true);
    state.power_options = try scope.createSignal([]const Option, &.{});
    state.boot_options = try scope.createSignal([]const Option, &.{});
    state.mode_options = try scope.createSignal([]const Option, &.{});
    state.power_value = try scope.createSignal(?[]const u8, "On");
    state.target_value = try scope.createSignal(?[]const u8, null);
    state.mode_value = try scope.createSignal(?[]const u8, null);
    state.boot_continuous = try scope.createSignal(bool, false);
    state.show_fps = try scope.createSignal(bool, true);
    state.order_open = try scope.createSignal(bool, false);
    state.log_open = try scope.createSignal(bool, false);
    state.cancel_disabled = try scope.createSignal(bool, false);
    state.retry_disabled = try scope.createSignal(bool, true);
    state.fit_style = try scope.createSignal(ui.BoxStyle, S.segment(true));
    state.original_style = try scope.createSignal(ui.BoxStyle, S.segment(false));
    state.fullscreen_label = try scope.createSignal([]const u8, "进入全屏");
    const root = try ui.vstackStyled(cx, S.workspaceRoot, .{});
    root.meta.ownership.meta.test_id = "bmc.content";
    root.behavior.events.on_event_capture = View.reserved;
    root.behavior.events.capture_context = state;
    try request.slot.appendChild(cx.allocator, root);
    state.root = root;
    const bar = try ui.hstackStyled(cx, S.toolbar, .{});
    try root.appendChild(cx.allocator, bar);
    state.toolbar = bar;
    const connection_title = try ui.textStyled(cx, S.connectionTitle, "KVM 控制台");
    connection_title.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    connection_title.meta.ownership.meta.test_id = "bmc.title";
    try bar.appendChild(cx.allocator, connection_title);
    state.connection_title = connection_title;
    for (menu_names, menu_ids, menu_icons, 0..) |name, id, icon, index| {
        const action = try cx.bindState(MenuAction, .{ .view = state, .menu = @fromBackingInt(@intCast(index)) });
        var popup = try ui.widgets.Popover(.{ .trigger = .manual, .open = state.open[index], .position = .bottom_start, .width = if (index == 4) S.boot_width else S.popup_width, .max_width = if (index == 4) S.boot_width else S.popup_width, .constrain_width_to_viewport = true, .max_height = @as(f32, 730), .viewport_padding = @as(f32, 12), .shift_main_axis = true, .offset = .{ .static = 8 }, .size_policy = .fit_content, .enter_transition = .fade, .exit_transition = .fade, .on_open_change = cx.on(MenuAction, action, MenuAction.changed) }).mount(scope, cx);
        popup.chrome.setStyleInline(cx.allocator, S.popup());
        popup.chrome.meta.ownership.meta.test_id = try scopedId(scope, id, ".popover");
        // This vendor's fit_or_scroll fixes its height to max_height. Keep the
        // Popover content-sized and own the one bounded scroll viewport here.
        const menu_scroll = try ui.widgets.ScrollArea(.{ .height = @as(f32, 1), .direction = .vertical, .rubber_band_y = false }).mount(popup.scope, cx);
        menu_scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
        try popup.content.appendChild(cx.allocator, menu_scroll.container);
        const body = try ui.vstackStyled(cx, S.popupBody, .{});
        body.meta.ownership.meta.test_id = try scopedId(scope, id, ".body");
        try menu_scroll.content.appendChild(cx.allocator, body);
        popup.content = body;
        state.menus[index] = popup;
        state.menu_scrolls[index] = menu_scroll;
        const button = try ui.widgets.Button(.{ .label = name, .variant = .ghost, .icon_asset = icon, .icon_size = @as(f32, 14), .base_style = state.tool_styles[index], .hover_style = state.tool_hover, .pressed_style = state.tool_hover, .focus_ring = ui.FocusRingConfig{ .width = 0 }, .on_click = cx.on(MenuAction, action, MenuAction.toggle) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = id;
        state.tool_nodes[index] = button;
        try popup.trigger.appendChild(cx.allocator, button);
        try bar.appendChild(cx.allocator, popup.wrapper);
        const head = try ui.hstackStyled(cx, S.popupHead, .{});
        // Header is a fixed sibling of the scroller. Close remains visible
        // while the tall key menu scrolls to its last actions.
        cx.detachChild(popup.chrome, menu_scroll.container);
        try popup.chrome.appendChild(cx.allocator, head);
        try popup.chrome.appendChild(cx.allocator, menu_scroll.container);
        try head.appendChild(cx.allocator, try ui.textStyled(cx, S.title, name));
        try head.appendChild(cx.allocator, try ui.spacer(cx));
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_asset = ui.icons.x, .icon_size = @as(f32, 14), .a11y_label = "关闭菜单", .base_style = S.close(), .on_click = cx.on(MenuAction, action, MenuAction.close) }).mount(popup.scope, cx);
        close.meta.ownership.meta.test_id = try scopedId(scope, id, ".close");
        try head.appendChild(cx.allocator, close);
        try mountMenu(state, @fromBackingInt(@intCast(index)), popup);
    }
    const workspace = try ui.boxStyled(cx, S.videoWorkspace, .{});
    workspace.meta.ownership.meta.test_id = "bmc.video_workspace";
    try root.appendChild(cx.allocator, workspace);
    const video_card = try ui.boxStyled(cx, S.videoCard, .{});
    video_card.meta.ownership.meta.test_id = "bmc.video_card";
    try workspace.appendChild(cx.allocator, video_card);
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .both, .rubber_band_x = false, .rubber_band_y = false, .background = ui.Color.BLACK }).mount(scope, cx);
    scroll.container.setStyleInline(cx.allocator, S.video());
    scroll.container.meta.ownership.meta.test_id = "bmc.viewport";
    scroll.container.behavior.interaction.focusable = true;
    scroll.container.behavior.events.on_event_capture = View.handle;
    scroll.container.behavior.events.capture_context = state;
    try video_card.appendChild(cx.allocator, scroll.container);
    state.scroll = scroll;
    state.viewport = scroll.container;
    if (scroll.container.children.items.len >= 3) {
        scroll.container.children.items[1].meta.ownership.meta.test_id = "bmc.viewport.scroll_y";
        scroll.container.children.items[2].meta.ownership.meta.test_id = "bmc.viewport.scroll_x";
    }
    const input_hint = try ui.textStyled(cx, S.inputHint, "");
    input_hint.setStyleInline(cx.allocator, S.inputHintBox());
    input_hint.setDisplay(.none);
    input_hint.meta.ownership.meta.test_id = "bmc.input_hint";
    try scroll.container.appendChild(cx.allocator, input_hint);
    state.input_hint = input_hint;
    const image_node = try ui.image(cx, 0, S.image());
    image_node.setImage(null);
    image_node.meta.ownership.meta.test_id = "bmc.frame";
    try scroll.content.appendChild(cx.allocator, image_node);
    state.image_node = image_node;
    const fps_hud = try ui.vstackStyled(cx, S.fpsHud, .{});
    fps_hud.meta.ownership.meta.test_id = "bmc.fps";
    state.fps_hud = fps_hud;
    state.fps_display = try ui.textStyled(cx, S.fpsPrimary, "显示 — FPS");
    state.fps_decode = try ui.textStyled(cx, S.fpsSecondary, "解码 — FPS");
    state.fps_display.?.meta.ownership.meta.test_id = "bmc.fps.display";
    state.fps_decode.?.meta.ownership.meta.test_id = "bmc.fps.decode";
    try fps_hud.appendChild(cx.allocator, state.fps_display.?);
    try fps_hud.appendChild(cx.allocator, state.fps_decode.?);
    try video_card.appendChild(cx.allocator, fps_hud);
    try mountProgress(state, scroll.container);
    try mountConnectionLog(state);
    try scope.onCleanup(View, state, View.release);
    root.meta.per_frame.hooks.slots.anim_state = state;
    root.addBeforeRender(View.beforeRender);
    try cx.addAfterLayoutHook(state, View.afterLayout);
    state.after_layout_registered = true;
    try state.refresh(cx.frame_time_ms);
    cx.requestRedraw();
    return .{ .context = state, .vtable = &.{ .update = View.update, .focus_changed = View.focus, .unmount = View.unmount, .connection_status = View.connectionStatus } };
}

fn mountProgress(state: *View, parent: *ui.Node) !void {
    const cx = state.mount_request.cx;
    const scope = state.mount_request.scope;
    const waiting = try ui.vstackStyled(cx, S.waiting, .{});
    waiting.meta.ownership.meta.test_id = "bmc.progress";
    // This overlay is a sibling of the image's scroll content. A failure in
    // 100% mode must stay in the viewport even when the old frame is panned.
    try parent.appendChild(cx.allocator, waiting);
    state.waiting = waiting;
    const surface = try ui.boxStyled(cx, S.progressSurface, .{});
    surface.meta.ownership.meta.test_id = "bmc.progress.surface";
    try waiting.appendChild(cx.allocator, surface);
    const route = try ui.boxStyled(cx, S.progressRouteBox, .{});
    route.meta.ownership.meta.test_id = "bmc.progress.route";
    try waiting.appendChild(cx.allocator, route);
    state.progress_route = route;
    try route.appendChild(cx.allocator, try ui.textStyled(cx, S.progressRouteLabel, "连接路径"));
    state.progress_route_text = try ui.textStyled(cx, S.progressRoute, "");
    state.progress_route_text.?.meta.ownership.meta.test_id = "bmc.progress.target";
    state.progress_route_text.?.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
    try route.appendChild(cx.allocator, state.progress_route_text.?);
    const header = try ui.vstackStyled(cx, S.progressHeader, .{});
    try waiting.appendChild(cx.allocator, header);
    state.waiting_header = header;
    state.waiting_title = try ui.textStyled(cx, S.progressTitle, "正在准备连接");
    state.waiting_title.?.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 26 }, .flex_shrink = 0 });
    state.waiting_title.?.meta.ownership.meta.test_id = "bmc.progress.stage";
    try header.appendChild(cx.allocator, state.waiting_title.?);
    const timing = try ui.hstack(cx, .{ .width = .fill(), .height = .{ .px = 18 }, .gap = 6, .align_items = .center, .flex_shrink = 0 }, .{});
    timing.meta.ownership.meta.test_id = "bmc.progress.timing";
    try header.appendChild(cx.allocator, timing);
    state.progress_timing = timing;
    try timing.appendChild(cx.allocator, try ui.textStyled(cx, S.progressTimingLabel, "当前阶段"));
    state.progress_stage_time = try ui.textStyled(cx, S.progressTiming, "—");
    state.progress_stage_time.?.setStyleInline(cx.allocator, .{ .width = .{ .px = 64 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
    state.progress_stage_time.?.meta.ownership.meta.test_id = "bmc.progress.stage_time";
    try timing.appendChild(cx.allocator, state.progress_stage_time.?);
    try timing.appendChild(cx.allocator, try ui.textStyled(cx, S.progressTimingLabel, "秒 · 总计"));
    state.progress_total_time = try ui.textStyled(cx, S.progressTiming, "—");
    state.progress_total_time.?.setStyleInline(cx.allocator, .{ .width = .{ .px = 64 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
    state.progress_total_time.?.meta.ownership.meta.test_id = "bmc.progress.total_time";
    try timing.appendChild(cx.allocator, state.progress_total_time.?);
    try timing.appendChild(cx.allocator, try ui.textStyled(cx, S.progressTimingLabel, "秒"));
    state.progress_notice = try ui.textStyled(cx, S.progressNotice, "");
    state.progress_notice.?.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .flex_shrink = 0 });
    state.progress_notice.?.meta.ownership.meta.test_id = "bmc.progress.notice";
    try header.appendChild(cx.allocator, state.progress_notice.?);
    const body = try ui.widgets.ScrollArea(.{ .height = @as(f32, 1), .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
    body.container.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0, .min_width = 0 });
    body.container.meta.ownership.meta.test_id = "bmc.progress.body";
    body.container.behavior.interaction.focusable = true;
    body.container.behavior.events.on_event_capture = View.progressKey;
    body.container.behavior.events.capture_context = state;
    body.content.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 12, .min_width = 0, .flex_shrink = 0 });
    try waiting.appendChild(cx.allocator, body.container);
    state.waiting_body = body;
    const steps = try ui.vstackStyled(cx, S.progressSteps, .{});
    steps.meta.ownership.meta.test_id = "bmc.progress.steps";
    try body.content.appendChild(cx.allocator, steps);
    state.progress_steps = steps;
    for (0..vm.progress_group_count) |index| {
        const group: vm.ProgressGroup = @fromBackingInt(@intCast(index));
        const block = try ui.vstack(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .gap = 0, .min_width = 0, .flex_shrink = 0 }, .{});
        try steps.appendChild(cx.allocator, block);
        const action = try cx.bindState(ProgressStepAction, .{ .view = state, .group = group });
        const row = try ui.hstackStyled(cx, S.progressStepBackdrop, .{});
        state.progress_rows[index] = row;
        try block.appendChild(cx.allocator, row);
        const button = try ui.widgets.Button(.{ .label = "", .a11y_label = vm.progressGroupLabel(group), .variant = .ghost, .base_style = S.progressStep(cx.tokens), .hover_style = ui.BoxStyle{ .background = ui.Color.TRANSPARENT }, .pressed_style = ui.BoxStyle{ .background = ui.Color.TRANSPARENT }, .focus_ring = .{ .width = 0, .offset = 0 }, .on_click = cx.on(ProgressStepAction, action, ProgressStepAction.toggle) }).mount(scope, cx);
        // The standard button owns focus, keyboard and pressed semantics; its
        // caller content supplies the status/name/disclosure columns.
        for (button.children.items) |child| child.setDisplay(.none);
        state.progress_buttons[index] = button;
        button.meta.ownership.meta.test_id = try scopedId(scope, "bmc.progress.step.", @tagName(group));
        try row.appendChild(cx.allocator, button);
        const icon = try ui.textStyled(cx, S.progressText, "○");
        icon.setStyleInline(cx.allocator, .{ .width = .{ .px = 16 }, .flex_shrink = 0 });
        try button.appendChild(cx.allocator, icon);
        state.progress_icons[index] = icon;
        const name = try ui.textStyled(cx, S.progressText, vm.progressGroupLabel(group));
        name.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try button.appendChild(cx.allocator, name);
        state.progress_names[index] = name;
        const status = try ui.textStyled(cx, S.progressState, "等待");
        status.setStyleInline(cx.allocator, .{ .width = .{ .px = 55 }, .flex_shrink = 0 });
        setTextLayout(status, 18.0 / 11.0, .end);
        try button.appendChild(cx.allocator, status);
        state.progress_states[index] = status;
        const chevron = try ui.textStyled(cx, S.progressState, "›");
        chevron.setStyleInline(cx.allocator, .{ .width = .{ .px = 12 }, .flex_shrink = 0 });
        try button.appendChild(cx.allocator, chevron);
        state.progress_chevrons[index] = chevron;
        const detail = try ui.textStyled(cx, S.progressDiagnostic, "该步骤尚无连接事件。");
        detail.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0, .margin = .{ .left = 24, .top = 4 }, .padding = .{ .top = 8, .bottom = 8, .left = 10, .right = 10 }, .background = S.theme.current().well, .border = .{ .width = 0, .radius = 8 } });
        detail.meta.ownership.meta.test_id = try scopedId(scope, "bmc.progress.diagnostic.", @tagName(group));
        detail.setDisplay(.none);
        try block.appendChild(cx.allocator, detail);
        state.progress_details[index] = detail;
    }
    state.waiting_detail = try ui.textStyled(cx, S.progressDetail, "");
    state.waiting_detail.?.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
    state.waiting_detail.?.meta.ownership.meta.test_id = "bmc.progress.detail";
    try body.content.appendChild(cx.allocator, state.waiting_detail.?);
    const actions = try ui.hstackStyled(cx, S.progressActions, .{});
    try waiting.appendChild(cx.allocator, actions);
    state.waiting_actions = actions;
    _ = try progressButton(state, actions, "连接日志", "bmc.connection_log", null, View.showLog);
    const session_action = try ui.box(cx, .{ .width = .{ .px = 76 }, .height = .{ .px = 32 }, .flex_shrink = 0 }, .{});
    try actions.appendChild(cx.allocator, session_action);
    state.cancel_node = try progressButton(state, session_action, "取消连接", "bmc.cancel", state.cancel_disabled, View.cancel);
    state.retry_node = try progressButton(state, session_action, "重试连接", "bmc.retry", state.retry_disabled, View.retry);
}

fn logColumns() ui.BoxStyle {
    var style = LogS.row(28);
    style.gap = 12;
    style.padding = .{ .left = 12, .right = 12 };
    return style;
}
fn logMuted(_: *const ui.ThemeTokens) ui.TextStyle {
    var style = LogS.logs();
    style.color = LogS.theme.current().fg_2;
    style.wrap = .none;
    return style;
}
fn logMessageStyle(_: *const ui.ThemeTokens) ui.TextStyle {
    return LogS.logs();
}
fn logCell(cx: *ui.Cx, text: []const u8, width: ?f32, right: bool) !*ui.Node {
    const node = try ui.textStyled(cx, logMuted, text);
    node.setStyleInline(cx.allocator, .{ .width = if (width) |value| .{ .px = value } else .fill(), .height = .{ .px = 16 }, .min_width = 0, .flex_shrink = 0 });
    if (right) setTextLayout(node, 16.0 / 10.5, .end);
    return node;
}

fn mountConnectionLog(state: *View) !void {
    const cx = state.mount_request.cx;
    const scope = state.mount_request.scope;
    const modal = try ui.widgets.Modal(.{ .title = "连接日志", .open = state.log_open.?, .width = S.log_width, .max_height = @as(f32, 600), .close_icon_asset = ui.icons.x, .enter_transition = .fade, .exit_transition = .fade }).mount(scope, cx);
    if (!modal.portaled) try state.root.?.appendChild(cx.allocator, modal.overlay);
    modal.overlay.meta.ownership.meta.test_id = "bmc.connection_log.overlay";
    modal.dialog.meta.ownership.meta.test_id = "bmc.connection_log.modal";
    if (modal.dialog.children.items.len != 0) {
        const header = modal.dialog.children.items[0];
        if (header.children.items.len != 0) {
            header.children.items[0].setStyleInline(cx.allocator, .{ .font_size = 13, .font_weight = 700 });
            setTextLayout(header.children.items[0], 20.0 / 13.0, .start);
            header.children.items[header.children.items.len - 1].meta.ownership.meta.test_id = "bmc.connection_log.close";
        }
    }
    state.log_modal = modal;
    const hint = try ui.textStyled(cx, S.hint, "仅本会话最近 32 条脱敏事件。关闭日志不会取消连接。");
    hint.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
    try modal.body.appendChild(cx.allocator, hint);
    state.log_route_text = try ui.textStyled(cx, S.progressRoute, "");
    state.log_route_text.?.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0, .padding = ui.Padding.all(10), .margin = .{ .bottom = 12 }, .background = S.theme.current().well, .border = .{ .width = 0, .radius = 8 } });
    state.log_route_text.?.meta.ownership.meta.test_id = "bmc.connection_log.route";
    try modal.body.appendChild(cx.allocator, state.log_route_text.?);
    const columns = try ui.box(cx, logColumns(), .{});
    columns.meta.ownership.meta.test_id = "bmc.connection_log.columns";
    try modal.body.appendChild(cx.allocator, columns);
    try columns.appendChild(cx.allocator, try logCell(cx, "时间戳", 86, false));
    try columns.appendChild(cx.allocator, try logCell(cx, "消息", null, false));
    try columns.appendChild(cx.allocator, try logCell(cx, "耗时", 76, true));
    const scroll = try ui.widgets.ScrollArea(.{ .height = @as(f32, 320), .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .background = LogS.theme.popupInset(), .border = .{ .width = 0, .radius = 9 }, .flex_shrink = 0 });
    scroll.content.setStyleInline(cx.allocator, LogS.logContent());
    scroll.container.meta.ownership.meta.test_id = "bmc.connection_log.list";
    scroll.container.behavior.interaction.focusable = true;
    scroll.container.behavior.events.on_event_capture = View.logKey;
    scroll.container.behavior.events.capture_context = state;
    try modal.body.appendChild(cx.allocator, scroll.container);
    state.log_scroll = scroll;
    state.log_detail = try ui.vstack(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .gap = 0, .min_width = 0, .flex_shrink = 0 }, .{});
    state.log_detail.?.meta.ownership.meta.test_id = "bmc.connection_log.events";
    try scroll.content.appendChild(cx.allocator, state.log_detail.?);
    state.log_empty = try ui.textStyled(cx, logMessageStyle, "本会话尚未产生连接事件。");
    try state.log_detail.?.appendChild(cx.allocator, state.log_empty.?);
    for (0..state.log_rows.len) |index| {
        var row_style = LogS.row(28);
        row_style.height = .{ .fit = .{} };
        row_style.min_height = 28;
        row_style.align_items = .start;
        row_style.gap = 12;
        row_style.padding = .{ .top = 6, .bottom = 6 };
        const row = try ui.box(cx, row_style, .{});
        var index_buffer: [12]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&index_buffer, "{d}", .{index});
        row.meta.ownership.meta.test_id = try scopedId(scope, "bmc.connection_log.row.", suffix);
        try state.log_detail.?.appendChild(cx.allocator, row);
        state.log_rows[index] = row;
        const timestamp = try logCell(cx, "时间未知", 86, false);
        timestamp.meta.ownership.meta.test_id = try scopedId(scope, "bmc.connection_log.timestamp.", suffix);
        try row.appendChild(cx.allocator, timestamp);
        state.log_timestamps[index] = timestamp;
        const message = try ui.textStyled(cx, logMessageStyle, "");
        message.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        message.meta.ownership.meta.test_id = try scopedId(scope, "bmc.connection_log.message.", suffix);
        try row.appendChild(cx.allocator, message);
        state.log_messages[index] = message;
        const duration = try logCell(cx, "—", 76, true);
        duration.meta.ownership.meta.test_id = try scopedId(scope, "bmc.connection_log.duration.", suffix);
        try row.appendChild(cx.allocator, duration);
        state.log_durations[index] = duration;
        row.setDisplay(.none);
    }
    const footer = try ui.box(cx, S.logFooter(cx.viewport.height < 600), .{});
    try modal.dialog.appendChild(cx.allocator, footer);
    state.log_footer = footer;
    const close = try ui.widgets.Button(.{ .label = "关闭", .variant = .secondary, .base_style = S.logClose(), .on_click = cx.on(View, state, View.closeLog) }).mount(scope, cx);
    close.meta.ownership.meta.test_id = "bmc.connection_log.dismiss";
    try footer.appendChild(cx.allocator, close);
}

fn mountMenu(state: *View, menu: Menu, popup: Popover) !void {
    const cx = state.mount_request.cx;
    const parent = popup.content;
    const scope = popup.scope;
    switch (menu) {
        .control => {
            state.control_label = try ui.textStyled(cx, S.body, "仅观看 · 尚未获控制权");
            try parent.appendChild(cx.allocator, state.control_label.?);
            _ = try actionButton(state, scope, parent, "申请控制权", "bmc.control.request", state.request_disabled, View.requestControl);
            _ = try actionButton(state, scope, parent, "捕获键盘鼠标", "bmc.control.capture", state.capture_disabled, View.capture);
            _ = try actionButton(state, scope, parent, "释放键盘鼠标 · ⌃⌥Esc", "bmc.control.release", null, View.releaseCapture);
            _ = try actionButton(state, scope, parent, "仅观看", "bmc.control.view_only", null, View.onlyView);
            state.control_request_row = try ui.vstackStyled(cx, S.root, .{});
            state.control_request_row.?.setStyleInline(cx.allocator, .{ .height = .{ .fit = .{} }, .gap = 6 });
            try parent.appendChild(cx.allocator, state.control_request_row.?);
            try state.control_request_row.?.appendChild(cx.allocator, try ui.textStyled(cx, S.hint, "另一个客户端请求控制权"));
            for ([_]console.ControlReply{ .full_control, .video_only, .reject }, [_][]const u8{ "移交完整控制", "允许仅观看", "拒绝请求" }, [_][]const u8{ "bmc.control.grant", "bmc.control.video_only", "bmc.control.reject" }) |reply, label, id| {
                const action = try cx.bindState(ReplyAction, .{ .view = state, .reply = reply });
                const button = try ui.widgets.Button(.{ .label = label, .variant = .secondary, .base_style = S.action(), .on_click = cx.on(ReplyAction, action, ReplyAction.send) }).mount(scope, cx);
                button.meta.ownership.meta.test_id = id;
                try state.control_request_row.?.appendChild(cx.allocator, button);
            }
            try parent.appendChild(cx.allocator, try ui.textStyled(cx, S.hint, "点击画面后路由键鼠。⌃⌥Esc 始终本地释放；Command 映射为远端 Super。"));
            state.message = try ui.textStyled(cx, S.hint, "");
            try parent.appendChild(cx.allocator, state.message.?);
        },
        .keys => {
            try parent.appendChild(cx.allocator, try ui.textStyled(cx, S.hint, "每次点击发送一次。需要已获控制权；不会自动抢占。"));
            try chordButton(state, scope, parent, "Ctrl + Alt + Delete", "bmc.keys.ctrl_alt_delete", &.{ 0xffe3, 0xffe9, 0xffff });
            for (0..6) |row_index| {
                const row = try ui.hstackStyled(cx, S.keyRow, .{});
                try parent.appendChild(cx.allocator, row);
                for (0..2) |column| {
                    const index = row_index * 2 + column;
                    var label_buffer: [32]u8 = undefined;
                    var id_buffer: [48]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buffer, "Ctrl + Alt + F{d}", .{index + 1});
                    const id = try std.fmt.bufPrint(&id_buffer, "bmc.keys.ctrl_alt_f{d}", .{index + 1});
                    try chordButton(state, scope, row, label, id, &.{ 0xffe3, 0xffe9, 0xffbe + @as(u32, @intCast(index)) });
                }
            }
            const row = try ui.hstackStyled(cx, S.keyRow, .{});
            try parent.appendChild(cx.allocator, row);
            try chordButton(state, scope, row, "远端 Esc", "bmc.keys.escape", &.{0xff1b});
            try chordButton(state, scope, row, "F1", "bmc.keys.f1", &.{0xffbe});
            const function_row = try ui.hstackStyled(cx, S.keyRow, .{});
            try parent.appendChild(cx.allocator, function_row);
            for ([_]u32{ 0xffbf, 0xffc7, 0xffc8, 0xffc9 }, [_][]const u8{ "F2", "F10", "F11", "F12" }, [_][]const u8{ "bmc.keys.f2", "bmc.keys.f10", "bmc.keys.f11", "bmc.keys.f12" }) |key, label, id| try chordButton(state, scope, function_row, label, id, &.{key});
        },
        .display => {
            const row = try ui.hstackStyled(cx, S.keyRow, .{});
            try parent.appendChild(cx.allocator, row);
            const fit = try ui.widgets.Button(.{ .label = "适应窗口", .variant = .ghost, .base_style = state.fit_style, .on_click = cx.on(View, state, View.fit) }).mount(scope, cx);
            fit.meta.ownership.meta.test_id = "bmc.display.fit";
            try row.appendChild(cx.allocator, fit);
            const original = try ui.widgets.Button(.{ .label = "100%", .variant = .ghost, .base_style = state.original_style, .on_click = cx.on(View, state, View.original) }).mount(scope, cx);
            original.meta.ownership.meta.test_id = "bmc.display.original";
            try row.appendChild(cx.allocator, original);
            try parent.appendChild(cx.allocator, try ui.textStyled(cx, S.hint, "100% · 逻辑原尺寸。超出区域可在释放键鼠后滚动。"));
            const fullscreen = try ui.widgets.Button(.{ .label = state.fullscreen_label, .variant = .secondary, .base_style = S.action(), .on_click = cx.on(View, state, View.fullscreen) }).mount(scope, cx);
            fullscreen.meta.ownership.meta.test_id = "bmc.display.fullscreen";
            try parent.appendChild(cx.allocator, fullscreen);
            const fps_toggle = try ui.widgets.Switch(.{ .label = "显示 FPS", .checked = state.show_fps, .on_change = cx.on(View, state, View.fpsChanged) }).mount(scope, cx);
            fps_toggle.meta.ownership.meta.test_id = "bmc.display.fps";
            try parent.appendChild(cx.allocator, fps_toggle);
            state.fps_detail = try ui.textStyled(cx, S.hint, "等待视频帧统计");
            state.fps_detail.?.meta.ownership.meta.test_id = "bmc.fps.detail";
            try parent.appendChild(cx.allocator, state.fps_detail.?);
            try parent.appendChild(cx.allocator, try ui.textStyled(cx, S.hint, "显示：新视频帧提交至窗口的频率。解码：完整视频帧发布频率。无新帧不一定表示卡顿。"));
            _ = try actionButton(state, scope, parent, "请求完整视频帧", "bmc.display.refresh", null, View.refreshVideo);
            _ = try actionButton(state, scope, parent, "连接日志", "bmc.display.connection_log", null, View.showLog);
        },
        .power => {
            state.power_mapping_warning = try mappingWarning(state, parent, "bmc.power.mapping_warning");
            const well = try wellValue(state, parent, "当前电源", "未知");
            state.power_label = well.value;
            state.power_scope_label = well.label;
            try selectField(state, scope, parent, "操作", "bmc.power.action", state.power_options, state.power_value, state.power_disabled, View.powerChanged);
            state.power_hint = try ui.textStyled(cx, S.hint, "当前仅查看管理状态。");
            try parent.appendChild(cx.allocator, state.power_hint.?);
            const actions = try ui.hstackStyled(cx, S.actions, .{});
            try parent.appendChild(cx.allocator, actions);
            state.power_cancel = try actionButton(state, scope, actions, "取消等待", "bmc.power.cancel", null, View.cancelManagement);
            state.power_cancel.?.setDisplay(.none);
            state.power_query = try actionButton(state, scope, actions, "查询结果", "bmc.power.query", null, View.queryManagement);
            state.power_query.?.setDisplay(.none);
            _ = try actionButton(state, scope, actions, "执行", "bmc.power.execute", state.power_execute_disabled, View.executePower);
        },
        .boot => {
            state.boot_mapping_warning = try mappingWarning(state, parent, "bmc.boot.mapping_warning");
            const well = try wellValue(state, parent, "当前启动覆盖", "未知");
            state.boot_label = well.value;
            state.boot_scope_label = well.label;
            state.boot_pending_label = try ui.textStyled(cx, S.hint, "");
            state.boot_pending_label.?.setDisplay(.none);
            try parent.appendChild(cx.allocator, state.boot_pending_label.?);
            try selectField(state, scope, parent, "启动设备", "bmc.boot.target", state.boot_options, state.target_value, state.boot_disabled, View.targetChanged);
            const details = try ui.vstackStyled(cx, S.root, .{});
            details.setStyleInline(cx.allocator, .{ .height = .{ .fit = .{} }, .gap = 12, .overflow_hidden = false });
            try parent.appendChild(cx.allocator, details);
            state.boot_details = details;
            const switch_node = try ui.widgets.Switch(.{ .label = "持续生效", .checked = state.boot_continuous, .disabled = state.switch_disabled, .on_change = cx.on(View, state, View.continuousChanged) }).mount(scope, cx);
            switch_node.meta.ownership.meta.test_id = "bmc.boot.continuous";
            try details.appendChild(cx.allocator, switch_node);
            state.boot_switch = switch_node;
            const mode_row = try ui.hstackStyled(cx, S.field, .{});
            try details.appendChild(cx.allocator, mode_row);
            state.mode_row = mode_row;
            try selectFieldContents(state, scope, mode_row, "下次启动模式", "bmc.boot.mode", state.mode_options, state.mode_value, state.mode_disabled, View.modeChanged);
            _ = try actionButton(state, scope, parent, "查看启动顺序（只读）", "bmc.boot.order", null, View.showOrder);
            const modal = try ui.widgets.Modal(.{ .title = "启动顺序 · 只读", .open = state.order_open.?, .width = @as(f32, 420), .max_height = @as(f32, 360), .close_icon_asset = ui.icons.x, .enter_transition = .fade, .exit_transition = .fade }).mount(scope, cx);
            if (!modal.portaled) try state.root.?.appendChild(cx.allocator, modal.overlay);
            modal.dialog.meta.ownership.meta.test_id = "bmc.boot.order_modal";
            if (modal.dialog.children.items.len != 0) {
                const header = modal.dialog.children.items[0];
                if (header.children.items.len != 0) header.children.items[header.children.items.len - 1].meta.ownership.meta.test_id = "bmc.boot.order_close";
            }
            modal.dialog.setStyleInline(cx.allocator, .{ .background = S.theme.current().overlay, .glass = S.theme.overlayGlass() });
            state.order_modal = modal;
            state.order_mapping_warning = try mappingWarning(state, modal.body, "bmc.boot.order_mapping_warning");
            state.order_mapping_warning.?.setStyleInline(cx.allocator, .{ .margin = .{ .bottom = 12 } });
            const order_scroll = try ui.widgets.ScrollArea(.{ .height = @as(f32, 240), .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
            order_scroll.container.meta.ownership.meta.test_id = "bmc.boot.order_list";
            order_scroll.container.behavior.interaction.focusable = true;
            order_scroll.container.behavior.events.on_event_capture = View.orderKey;
            order_scroll.container.behavior.events.capture_context = state;
            try modal.body.appendChild(cx.allocator, order_scroll.container);
            state.order_scroll = order_scroll;
            state.order_rows = order_scroll.content;
            try state.refreshOrder(null);
            state.boot_hint = try ui.textStyled(cx, S.hint, "仅查看启动覆盖；保存启动项不会自动重启。");
            try parent.appendChild(cx.allocator, state.boot_hint.?);
            const actions = try ui.hstackStyled(cx, S.actions, .{});
            try parent.appendChild(cx.allocator, actions);
            state.boot_cancel = try actionButton(state, scope, actions, "取消等待", "bmc.boot.cancel", null, View.cancelManagement);
            state.boot_cancel.?.setDisplay(.none);
            state.boot_query = try actionButton(state, scope, actions, "查询结果", "bmc.boot.query", null, View.queryManagement);
            state.boot_query.?.setDisplay(.none);
            _ = try actionButton(state, scope, actions, "执行", "bmc.boot.execute", state.boot_execute_disabled, View.executeBoot);
        },
    }
}

fn actionButton(state: *View, scope: *ui.Scope, parent: *ui.Node, label: []const u8, id: []const u8, disabled: ?*ui.Signal(bool), comptime action: fn (*View) void) !*ui.Node {
    const button = try ui.widgets.Button(.{ .label = label, .variant = .secondary, .disabled = if (disabled) |signal| ui.Source(bool){ .signal = signal } else ui.Source(bool){ .value = false }, .base_style = S.action(), .focus_ring = ui.FocusRingConfig{ .width = 0 }, .on_click = state.mount_request.cx.on(View, state, action) }).mount(scope, state.mount_request.cx);
    button.meta.ownership.meta.test_id = id;
    try parent.appendChild(state.mount_request.cx.allocator, button);
    return button;
}
fn progressButton(state: *View, parent: *ui.Node, label: []const u8, id: []const u8, disabled: ?*ui.Signal(bool), comptime action: fn (*View) void) !*ui.Node {
    const cx = state.mount_request.cx;
    const button = try ui.widgets.Button(.{ .label = label, .variant = .secondary, .disabled = if (disabled) |signal| ui.Source(bool){ .signal = signal } else ui.Source(bool){ .value = false }, .base_style = S.progressAction(), .on_click = cx.on(View, state, action) }).mount(state.mount_request.scope, cx);
    button.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, button);
    return button;
}
fn setHeight(cx: *ui.Cx, node: *ui.Node, height: f32) bool {
    const current = switch (node.style.height) {
        .px => |value| value,
        else => @as(f32, -1),
    };
    if (@abs(current - height) <= 0.1) return false;
    node.setStyleInline(cx.allocator, .{ .height = .{ .px = height }, .flex_shrink = 0 });
    return true;
}
fn setTextLayout(node: *ui.Node, height: f32, alignment: ui.TextAlign) void {
    var text = node.getText() orelse return;
    if (@abs(text.line_height - height) <= 0.0001 and text.text_align == alignment) return;
    text.line_height = height;
    text.text_align = alignment;
    node.setText(text);
}
fn setTextColorIfChanged(node: *ui.Node, color: ui.Color) void {
    const text = node.getText() orelse return;
    if (!std.meta.eql(text.color, color)) node.setTextColor(color);
}
fn scrollKey(scroll: ui.widgets.ScrollAreaResult, event: ui.events.Event) ui.events.EventResult {
    if (event != .key_down) return .ignored;
    const current = scroll.state.scroll_y;
    const next: f32 = switch (event.key_down.key) {
        .home => 0,
        .end => scroll.state.maxScrollY(),
        .page_up => current - scroll.state.viewport_height,
        .page_down => current + scroll.state.viewport_height,
        .up => current - 22,
        .down => current + 22,
        else => return .ignored,
    };
    ui.widgets.scroll_area.setScrollY(scroll.state, scroll.content, next);
    return .stop;
}
fn chordButton(state: *View, scope: *ui.Scope, parent: *ui.Node, label: []const u8, id: []const u8, keys: []const u32) !void {
    const cx = state.mount_request.cx;
    const action = try cx.bindState(ChordAction, .{ .view = state, .chord = try input.Chord.init(keys) });
    const owned_label = try ownedText(scope, label);
    const owned_id = try ownedText(scope, id);
    const button = try ui.widgets.Button(.{ .label = owned_label, .variant = .ghost, .disabled = state.keys_disabled, .base_style = state.key_style, .on_click = cx.on(ChordAction, action, ChordAction.send) }).mount(scope, cx);
    button.meta.ownership.meta.test_id = owned_id;
    try parent.appendChild(cx.allocator, button);
}
const WellValue = struct { label: *ui.Node, value: *ui.Node };
fn wellValue(state: *View, parent: *ui.Node, label: []const u8, value: []const u8) !WellValue {
    const cx = state.mount_request.cx;
    const row = try ui.hstackStyled(cx, S.well, .{});
    try parent.appendChild(cx.allocator, row);
    const label_node = try ui.textStyled(cx, S.hint, label);
    try row.appendChild(cx.allocator, label_node);
    const node = try ui.textStyled(cx, S.value, value);
    try row.appendChild(cx.allocator, node);
    return .{ .label = label_node, .value = node };
}
fn mappingWarning(state: *View, parent: *ui.Node, test_id: []const u8) !*ui.Node {
    const cx = state.mount_request.cx;
    const node = try ui.textStyled(cx, S.hint, unverified_mapping_message);
    node.meta.ownership.meta.test_id = test_id;
    node.setDisplay(.none);
    try parent.appendChild(cx.allocator, node);
    return node;
}
fn selectField(state: *View, scope: *ui.Scope, parent: *ui.Node, label: []const u8, id: []const u8, options: *ui.Signal([]const Option), value: *ui.Signal(?[]const u8), disabled: *ui.Signal(bool), comptime changed: fn (*View, ?[]const u8) void) !void {
    const row = try ui.hstackStyled(state.mount_request.cx, S.field, .{});
    try parent.appendChild(state.mount_request.cx.allocator, row);
    try selectFieldContents(state, scope, row, label, id, options, value, disabled, changed);
}
fn selectFieldContents(state: *View, scope: *ui.Scope, row: *ui.Node, label: []const u8, id: []const u8, options: *ui.Signal([]const Option), value: *ui.Signal(?[]const u8), disabled: *ui.Signal(bool), comptime changed: fn (*View, ?[]const u8) void) !void {
    const cx = state.mount_request.cx;
    try row.appendChild(cx.allocator, try ui.textStyled(cx, S.body, label));
    const select = try ui.widgets.Select(.{ .options = options, .value = value, .disabled = disabled, .width = S.select_width, .size = .md, .placeholder = "暂无可用选项", .on_change = cx.on(View, state, changed) }).mount(scope, cx);
    select.wrapper.meta.ownership.meta.test_id = id;
    select.trigger.meta.ownership.meta.test_id = try scopedId(scope, id, ".trigger");
    select.trigger.setStyleInline(cx.allocator, .{ .height = .{ .px = 32 }, .min_height = 32, .border = .{ .width = 0, .radius = 8 }, .font_size = 12 });
    select.chrome.meta.ownership.meta.test_id = try scopedId(scope, id, ".dropdown");
    try @import("select_surface.zig").mount(cx, select);
    try row.appendChild(cx.allocator, select.wrapper);
}
fn setText(state: *View, node: ?*ui.Node, text: []const u8) !void {
    const target = node orelse return;
    if (target.getText()) |existing| if (std.mem.eql(u8, existing.content, text)) return;
    try target.setTextContent(state.mount_request.cx.allocator, text);
}
fn scopedId(scope: *ui.Scope, prefix: []const u8, suffix: []const u8) ![]const u8 {
    const joined = try std.mem.concat(scope.allocator, u8, &.{ prefix, suffix });
    defer scope.allocator.free(joined);
    return ownedText(scope, joined);
}
fn ownedText(scope: *ui.Scope, text: []const u8) ![]const u8 {
    const Storage = struct {
        bytes: []u8,
        fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            allocator.free(self.bytes);
            allocator.destroy(self);
        }
    };
    const holder = try scope.allocator.create(Storage);
    errdefer scope.allocator.destroy(holder);
    holder.bytes = try scope.allocator.dupe(u8, text);
    errdefer scope.allocator.free(holder.bytes);
    try scope.registerResource(holder, Storage.destroy);
    return holder.bytes;
}
fn canonicalTarget(value: ?[]const u8) ?[]const u8 {
    for (target_values) |candidate| if (services.optionalEqual(value, candidate)) return candidate;
    return null;
}
fn canonicalMode(value: ?[]const u8) ?[]const u8 {
    for (mode_values) |candidate| if (services.optionalEqual(value, candidate)) return candidate;
    return null;
}
fn buttonMask(button: ui.events.MouseButton) u8 {
    return switch (button) {
        .left => 1,
        .middle => 2,
        .right => 4,
    };
}
fn patchSwitch(state: *View, root: *ui.Node) void {
    const alloc = state.mount_request.cx.allocator;
    root.setStyleInline(alloc, .{ .width = .fill(), .height = .{ .px = 24 }, .min_height = 24, .justify = .start, .gap = 8, .flex_shrink = 0 });
    if (root.children.items.len == 0) return;
    const track = root.children.items[0];
    track.setStyleInline(alloc, .{ .width = .{ .px = 30 }, .height = .{ .px = 18 }, .border = .{ .radius = 9 }, .flex_shrink = 0 });
    if (track.children.items.len == 0) return;
    track.children.items[0].setStyleInline(alloc, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .translate_x = if (state.boot_continuous.peek()) 14 else 2, .translate_y = 2, .border = .{ .radius = 7 } });
    if (root.children.items.len > 1) root.children.items[1].setStyleInline(alloc, .{ .font_size = 12 });
}
