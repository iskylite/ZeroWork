//! Opt-in native, read-only BMC acceptance host. Every target and credential
//! enters as one stdin JSON line; production Plugin/Runtime/OwnedTransport and
//! the registered production renderer own the complete connection lifecycle.
const std = @import("std");
const ui = @import("ui");
const zenit = @import("zenit_app");
const sessions = @import("host/session_host.zig");
const contexts = @import("host/host_context.zig");
const identity = @import("host/identity.zig");
const envelopes = @import("config/connection_envelope.zig");
const hosts = @import("config/hosts.zig");
const resolution = @import("host/connection_config_resolver.zig");
const transports = @import("host/transport_factory.zig");
const ssh = @import("proto/ssh/session.zig");
const known = @import("proto/ssh/host_key_store.zig");
const tls = @import("host/tls_trust.zig");
const secrets = @import("host/secret_lease.zig");
const challenges = @import("host/challenge_host.zig");
const content = @import("host/content_context.zig");
const frames = @import("host/frame_texture_sink.zig");
const budgets = @import("host/frame_budget.zig");
const contract = @import("host/plugin_ui_contract.zig");
const plugin_api = @import("plugins/bmc_ikvm/plugin.zig");
const runtime_api = @import("plugins/bmc_ikvm/runtime.zig");
const controller_api = @import("plugins/bmc_ikvm/controller.zig");
const native_api = @import("plugins/bmc_ikvm/native_driver.zig");
const model = @import("plugins/bmc_ikvm/model.zig");
const console = @import("plugins/bmc_ikvm/console_service.zig");
const framebuffer = @import("plugins/bmc_ikvm/framebuffer.zig");
const services = @import("plugins/bmc_ikvm/services.zig");
const journal = @import("plugins/bmc_ikvm/management_journal.zig");
const views = @import("plugins/bmc_ikvm/views.zig");
const theme = @import("ui/app_theme.zig");
const tool_api = @import("ai/plugin_tools.zig");
const tool_scope_api = @import("ai/tool_scope.zig");
const tool_operations_api = @import("host/operation_store.zig");
const typed = @import("host/plugin_services.zig");
const remote_input = @import("plugins/bmc_ikvm/remote_input.zig");
const ai_control = @import("plugins/bmc_ikvm/ai_control.zig");
const provider = @import("ai/provider.zig");
const service_access_api = @import("host/session_service_access.zig");

const a = std.heap.c_allocator;
pub const std_options: std.Options = .{ .logFn = quietLog };
fn quietLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}
const BmcInput = struct { host: []const u8, https_port: u16 = 443, username: []const u8, password: []const u8 };
const HopInput = struct { host: []const u8, port: u16 = 22, username: []const u8, password: []const u8 };
/// Only fixed, separately approved acceptance plans are permitted. The default
/// never acquires input authority or contributes a pixel observation.
const AcceptanceMode = enum { read_only, safe_interaction, ai_pointer_click, native_interactive };
const OperatorApproval = enum { safe_shift_and_pointer, observed_screen_single_click, native_view_and_observed_actions };
const ClickTarget = struct { x: u16, y: u16 };
const Input = struct {
    bmc: BmcInput,
    ssh_hops: []const HopInput,
    known_hosts_path: []const u8,
    approved_tls_leaf_sha256: []const u8,
    observe_seconds: u32 = 3,
    can_autostop: bool = true,
    acceptance_mode: AcceptanceMode = .read_only,
    operator_approval: ?OperatorApproval = null,
    click_target: ?ClickTarget = null,
    interactive_seconds: u32 = 180,
};
fn isReadOnly(value: Input) bool {
    return value.acceptance_mode == .read_only;
}
const DiscoverySummary = struct {
    manager_count: usize,
    system_count: usize,
    resource_association_verified: bool,
    resource_association_method: ?[]const u8,
    mapping_verified: bool,
    mapping_error: ?[]const u8,
    mapping_rejection: ?[]const u8,
    mapping_system_status: ?u16,
    mapping_system_validity: ?[]const u8,
    management_target_verified: bool = false,
    management_target_error: ?[]const u8 = null,
    readonly_system_projection: bool,
    readonly_rejection: ?[]const u8,
    readonly_collection_count: usize,
    readonly_member_count: usize,
    readonly_collection_status: ?u16,
    readonly_collection_validity: ?[]const u8,
    readonly_system_status: ?u16,
    readonly_system_validity: ?[]const u8,
    readonly_system_identity_present: bool,
};
const ProgressHeadline = struct {
    stage: []const u8,
    event_count: u8,
    elapsed_ms: u64,
    waiting_for_user: bool,
    failure_stage: ?[]const u8,
    static_errorcode: ?[]const u8,
    failure_event: ?console.progress.Event,
};
const ProgressEventSummary = struct {
    sequence: u64 = 0,
    at_ms: u64 = 0,
    stage: []const u8 = "idle",
    kind: []const u8 = "stage",
    code: []const u8 = "none",
    resource: []const u8 = "none",
    http_status: ?u16 = null,
    static_errorcode: ?[]const u8 = null,
    count: ?u16 = null,
    validity: ?[]const u8 = null,
    context: ?console.progress.Context = null,
};
const TypedManagementSummary = struct {
    management_policy: []const u8,
    power_write_requestable: bool,
    power_write_granted: bool,
    boot_write_requestable: bool,
    boot_write_granted: bool,
    power_resource_present: bool,
    power_resource_validity: services.Validity,
    power_mapping_verified: bool,
    power_state_present: bool,
    power_state_known: bool,
    power_state: ?services.PowerState,
    power_last_reset_time_present: bool,
    power_last_reset_time_validity: services.Validity,
    power_state_validity: services.Validity,
    power_reset_types_count: usize,
    power_reset_types_validity: services.Validity,
    boot_resource_present: bool,
    boot_resource_validity: services.Validity,
    boot_mapping_verified: bool,
    boot_state_present: bool,
    boot_enabled_present: bool,
    boot_target_present: bool,
    boot_mode_present: bool,
    boot_enabled_validity: services.Validity,
    boot_target_validity: services.Validity,
    boot_mode_validity: services.Validity,
    boot_order_count: usize,
    boot_order_validity: services.Validity,
    boot_alias_order_count: usize,
    boot_option_count: usize,
    boot_allowed_targets_count: usize,
    boot_allowed_modes_count: usize,
    boot_pending_present: bool,
};
const LogoutAttemptSummary = struct {
    stage: []const u8,
    failure: ?[]const u8,
    http_status: ?u16,
    response_validity: ?[]const u8,
    request_dispatched: bool,
    management_failed_at_entry: bool,
    transport_done_at_entry: bool,
    transport_done_at_exit: bool,
};
const LogoutSummary = struct {
    web: LogoutAttemptSummary,
    kvm: LogoutAttemptSummary,
    websocket_close: []const u8,
    websocket_failure: ?[]const u8,
};
const PresentationSummary = struct {
    sample_width: u32,
    sample_height: u32,
    sampled_pixels: usize,
    nonblack_samples: usize,
    has_nonblack_samples: bool,
    sink_has_texture: bool,
    sink_generation_matches_sample: bool,
    sink_sequence_matches_sample: bool,
    sink_dimensions_match_sample: bool,
    renderer_has_texture: bool,
    renderer_texture_matches_sink: bool,
    renderer_generation_matches_sink: bool,
    renderer_sequence_matches_sink: bool,
};
fn logoutAttemptSummary(attempt: native_api.LogoutAttempt) LogoutAttemptSummary {
    return .{
        .stage = @tagName(attempt.stage),
        .failure = if (attempt.failure) |err| @errorName(err) else null,
        .http_status = attempt.http_status,
        .response_validity = if (attempt.response_validity) |validity| @tagName(validity) else null,
        .request_dispatched = attempt.request_dispatched,
        .management_failed_at_entry = attempt.management_failed_at_entry,
        .transport_done_at_entry = attempt.transport_done_at_entry,
        .transport_done_at_exit = attempt.transport_done_at_exit,
    };
}

fn emit(value: anytype) void {
    const bytes = std.json.Stringify.valueAlloc(a, value, .{}) catch return;
    defer a.free(bytes);
    // Only bounded local enum/status/count values and fixed artifact paths.
    std.debug.print("BMC_LIVE {s}\n", .{bytes});
}
fn wipe(bytes: []const u8) void {
    std.crypto.secureZero(u8, @constCast(bytes));
}
fn wipeInput(value: Input) void {
    wipe(value.bmc.password);
    for (value.ssh_hops) |hop| wipe(hop.password);
}
fn readInputLine() ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer {
        wipe(bytes.items);
        bytes.deinit(a);
    }
    while (true) {
        var byte: [1]u8 = undefined;
        const count = std.c.read(0, &byte, 1);
        if (count == 0) break;
        if (count < 0) return error.StdinReadFailed;
        if (byte[0] == '\n') break;
        if (bytes.items.len == 64 * 1024) return error.InputTooLarge;
        try bytes.append(a, byte[0]);
    }
    if (bytes.items.len == 0) return error.MissingStdinJson;
    return bytes.toOwnedSlice(a);
}
fn validateInput(value: Input) ![32]u8 {
    switch (value.acceptance_mode) {
        .read_only => if (value.operator_approval != null or value.click_target != null) return error.UnexpectedControlApproval,
        .safe_interaction => if (value.operator_approval != .safe_shift_and_pointer or value.click_target != null) return error.ExplicitSafeInteractionApprovalRequired,
        .native_interactive => if (value.operator_approval != .native_view_and_observed_actions or value.click_target != null or value.interactive_seconds < 30 or value.interactive_seconds > 900) return error.ExplicitNativeInteractionApprovalRequired,
        .ai_pointer_click => {
            if (value.operator_approval != .observed_screen_single_click or value.click_target == null) return error.ObservedScreenClickApprovalRequired;
            // Check against the actual observation dimensions again at dispatch.
            if (value.click_target.?.x >= 8192 or value.click_target.?.y >= 8192) return error.InvalidClickTarget;
        },
    }
    try model.validate(.{ .endpoint = .{ .host = value.bmc.host, .https_port = value.bmc.https_port }, .username = value.bmc.username, .display = .{ .read_only_requested = isReadOnly(value) } });
    if (value.bmc.password.len == 0 or value.bmc.password.len > 8192 or std.mem.indexOfScalar(u8, value.bmc.password, 0) != null) return error.InvalidCredential;
    if (value.ssh_hops.len == 0 or value.ssh_hops.len > 8) return error.InvalidSshRoute;
    for (value.ssh_hops, 0..) |hop, i| {
        const config: hosts.HostConfig = .{ .name = "read-only route", .host = hop.host, .port = hop.port, .user = hop.username, .auth_mode = .password, .strict_host_key_checking = true };
        try config.validate();
        if (hop.password.len == 0 or hop.password.len > 8192 or std.mem.indexOfScalar(u8, hop.password, 0) != null) return error.InvalidCredential;
        for (value.ssh_hops[0..i]) |previous| if (resolution.sameEndpoint(config, .{ .name = "read-only route", .host = previous.host, .port = previous.port, .user = previous.username })) return error.DuplicateEndpoint;
    }
    if (!std.fs.path.isAbsolute(value.known_hosts_path) or std.mem.indexOfAny(u8, value.known_hosts_path, "\x00\r\n") != null) return error.InvalidKnownHostsPath;
    if (value.observe_seconds == 0 or value.observe_seconds > 45) return error.InvalidObserveSeconds;
    if (value.approved_tls_leaf_sha256.len != 64) return error.InvalidApprovedFingerprint;
    var fingerprint: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&fingerprint, value.approved_tls_leaf_sha256) catch return error.InvalidApprovedFingerprint;
    if (std.mem.allEqual(u8, &fingerprint, 0)) return error.InvalidApprovedFingerprint;
    return fingerprint;
}

/// Same reservation/adoption contract as connection_transport_runner's
/// acceptance fixture. Any native retry/join runs on this detached cleanup
/// worker; the main thread only observes its acquire/release counters.
const Retainer = struct {
    slots: [16]?*transports.OwnedTransport = @splat(null),
    mutex: std.atomic.Mutex = .unlocked,
    reserved: std.atomic.Value(usize) = .init(0),
    retained: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    fn start(self: *Retainer) !void {
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.detach();
    }
    fn interface(self: *Retainer) transports.FailedOpenOwner {
        return .{ .context = self, .reserve = reserve, .release = release, .adopt = adopt };
    }
    fn reserve(raw: *anyopaque) !void {
        const self: *Retainer = @ptrCast(@alignCast(raw));
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.stopping.load(.acquire)) return error.CleanupOwnerStopping;
        if (self.reserved.load(.acquire) + self.retained.load(.acquire) >= self.slots.len) return error.CleanupCapacity;
        _ = self.reserved.fetchAdd(1, .acq_rel);
    }
    fn release(raw: *anyopaque) void {
        const self: *Retainer = @ptrCast(@alignCast(raw));
        std.debug.assert(self.reserved.fetchSub(1, .acq_rel) > 0);
    }
    fn adopt(raw: *anyopaque, owned: *transports.OwnedTransport) void {
        const self: *Retainer = @ptrCast(@alignCast(raw));
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        for (&self.slots) |*slot| if (slot.* == null) {
            slot.* = owned;
            _ = self.retained.fetchAdd(1, .acq_rel);
            release(raw);
            return;
        };
        unreachable;
    }
    fn run(self: *Retainer) void {
        while (true) {
            for (0..self.slots.len) |i| {
                while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
                const owned = self.slots[i];
                self.mutex.unlock();
                if (owned) |transport| {
                    if (transport.close() == .released) {
                        transport.deinit() catch unreachable;
                        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
                        self.slots[i] = null;
                        self.mutex.unlock();
                        _ = self.retained.fetchSub(1, .acq_rel);
                    }
                }
            }
            if (self.stopping.load(.acquire) and self.reserved.load(.acquire) == 0 and self.retained.load(.acquire) == 0) break;
            var fds: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&fds, 0, 5);
        }
        self.done.store(true, .release);
    }
};

const ReadOnlyJournal = struct {
    denied_writes: usize = 0,
    fn backend(self: *ReadOnlyJournal) journal.Backend {
        return .{ .context = self, .read = read, .replace_durable = replace };
    }
    fn read(_: *anyopaque, _: std.mem.Allocator) !?[]u8 {
        return null;
    }
    fn replace(raw: *anyopaque, _: []const u8) !void {
        const self: *ReadOnlyJournal = @ptrCast(@alignCast(raw));
        self.denied_writes += 1;
        return error.ReadOnlyJournal;
    }
};

const ControlStage = enum {
    initial_observation,
    request_control,
    human_shift,
    human_shift_wait,
    human_observe,
    human_pointer_wait,
    human_final_observe,
    ai_observation,
    ai_shift,
    ai_shift_wait,
    ai_pointer,
    ai_pointer_wait,
    final_observe,
    interactive_ready,
    interactive_observe,
    interactive_action_wait,
    complete,
};
const ControlSummary = struct {
    acceptance_mode: AcceptanceMode,
    completed: bool,
    stage: ControlStage,
    readonly_tool_calls: usize,
    exact_approved_tool_calls: usize,
    human_sent_sequence: u64,
    ai_keyboard_sent: bool,
    ai_pointer_sent: bool,
    ai_keyboard_receipt: ?WireReceiptSummary,
    ai_pointer_receipt: ?WireReceiptSummary,
    last_wire_receipt: ?WireReceiptSummary,
    active_human_leases: usize,
    active_automation_leases: usize,
    frame_leases_remaining: ?usize,
    input_queued: usize,
    automation_pending: usize,
    remote_input_unconfirmed: bool,
    released_keys_and_buttons_zero: bool,
    own_web_delete_http_200: bool,
    own_kvm_delete_http_200: bool,
    local_images_only: bool = true,
    model_visual_understanding_tested: bool = false,
    native_view: NativeViewEvidence,
    interactive_actions_sent: usize,
    interactive_actions_cancelled_unsent: usize,
    interactive_stop_requests: usize,
    actions_with_post_send_observation: usize,
    last_action_timing: ?ActionTiming,
    reconnects: usize,
    same_tab_preserved: bool,
    old_proof_invalid_after_retry: bool,
    old_proof_rejected_by_new_owner: bool,
    old_proof_invalid_after_stop: bool,
    old_proof_rejected_after_stop: bool,
    retry_own_logout_confirmed: bool,
};
const WireReceiptSummary = struct {
    operation_id: u64,
    state: []const u8,
    sent_events: u16,
    total_events: u16,
    possibly_written: bool,
};
/// Only the latest immutable CPU framebuffer is sampled here. Publication
/// sequence gaps remain visible; main-thread polling is never a video FPS.
const VideoEvidence = struct {
    connection_started_ms: u64 = 0,
    first_sampled_ms: u64 = 0,
    last_sampled_ms: u64 = 0,
    last_received_ns: u64 = 0,
    first_sequence: u64 = 0,
    last_sequence: u64 = 0,
    sampled_latest_frames: u64 = 0,
    unsampled_published_sequences: u64 = 0,
    consecutive_interval_samples: u64 = 0,
    consecutive_interval_total_ns: u64 = 0,
    consecutive_interval_min_ns: u64 = std.math.maxInt(u64),
    consecutive_interval_max_ns: u64 = 0,
    sampled_latest_age_max_ms: u64 = 0,
};
const VideoSummary = struct {
    owner_generation: ?u64,
    observation_ms: u64,
    first_frame_observed_after_connection_ms: ?u64,
    published_complete_cpu_frames: u64,
    sampled_latest_frames: u64,
    published_updates_over_observation: u64,
    published_sequences_not_individually_sampled: u64,
    published_updates_per_second_over_observation: ?f64,
    consecutive_received_interval_samples: u64,
    consecutive_received_interval_min_ms: ?f64,
    consecutive_received_interval_mean_ms: ?f64,
    consecutive_received_interval_max_ms: ?f64,
    sampled_latest_frame_age_ms: ?u64,
    sampled_latest_frame_age_max_ms: u64,
    includes_requested_full_refreshes: bool = true,
    received_or_decoded_frame_drops_measured: bool = false,
    rendered_fps_measured: bool = false,
    motion_or_static_screen_classification: []const u8 = "operator_observation_required",
    no_update_interval_alone_proves_stall: bool = false,
};
/// The production receipt owns the wire timestamp. Dispatch/receipt-observed
/// times are host bounds, not an invented exact enqueue or remote response time.
const ActionTiming = struct {
    owner: identity.SessionHandle,
    operation_id: u64,
    source_observation_id: u64,
    source_frame_generation: u64,
    source_frame_sequence: u64,
    dispatch_started_monotonic_ms: u64,
    queued_receipt_observed_monotonic_ms: ?u64 = null,
    sent_monotonic_ns: ?u64 = null,
    sent_receipt_observed_monotonic_ms: ?u64 = null,
    dispatch_to_wire_sent_ms_upper_bound: ?u64 = null,
    exact_queue_to_wire_ms: ?u64 = null,
    post_observation_id: ?u64 = null,
    post_frame_sequence: ?u64 = null,
    post_frame_received_monotonic_ns: ?u64 = null,
    post_screenshot_captured_monotonic_ms: ?u64 = null,
    sent_to_post_frame_ms: ?f64 = null,
    sent_to_post_screenshot_ms: ?u64 = null,
    post_send_new_frame_verified: bool = false,
    remote_application_effect_verified: bool = false,
};
/// Test control contains no connection, credential or arbitrary text fields.
/// An action names the observation and owner Root has actually inspected.
const InteractiveCommand = struct {
    command: enum { observe, pointer, shift, text_probe, clear_line, old_proof_probe, stop_ai, reconnect, cancel_connection, finish },
    owner_generation: ?u64 = null,
    observation_id: ?u64 = null,
    pointer_action: ?enum { move, click, double_click, right_click, drag, wheel } = null,
    x: ?u16 = null,
    y: ?u16 = null,
    end_x: ?u16 = null,
    end_y: ?u16 = null,
    steps_x: ?i8 = null,
    steps_y: ?i8 = null,
    observed_idle_prompt: bool = false,
};
const NativeViewEvidence = struct {
    captured_observed: bool = false,
    shift_down_queued: bool = false,
    shift_up_queued: bool = false,
    shift_down_wire_sent: bool = false,
    shift_up_wire_sent: bool = false,
    pointer_move_queued: bool = false,
    pointer_move_wire_sent: bool = false,
    left_button_down_queued: bool = false,
    left_button_up_queued: bool = false,
    left_button_down_wire_sent: bool = false,
    left_button_up_wire_sent: bool = false,
    left_click_queued_complete: bool = false,
    left_click_wire_complete: bool = false,
    accepted_events: usize = 0,
    wire_sent_events: usize = 0,
    invalidated_before_send_confirmation: usize = 0,
    last_queued_sequence: u64 = 0,
    last_wire_sent_sequence: u64 = 0,
    focus_loss_observed: bool = false,
    focus_loss_released: bool = false,
    human_takeover_observed: bool = false,
    human_takeover_revoked_ai_proof: bool = false,
    /// Physical input is established by the operator/Cua transcript, not RPC.
    physical_event_source_verified_by_runner: bool = false,
};
const NativeQueued = struct {
    sequence: u64,
    transport: u64,
    epoch: u64,
    queued_observed_monotonic_ms: u64,
    kind: enum { shift_down, shift_up, pointer_move, left_button_down, left_button_up, other },
    event_kind: enum { key, pointer, wheel, chord },
    keysym: ?u32 = null,
    down: ?bool = null,
    keysym_redacted: bool = false,
    buttons: ?u8 = null,
    button: ?enum { left } = null,
    click_down_sequence: ?u64 = null,
};
const NativeButtonStart = struct {
    sequence: u64,
    transport: u64,
    epoch: u64,
    owner_generation: u64,
};
const NativeFocusDiagnostic = struct {
    window_active: bool,
    renderer_window_focused: bool,
    focused_node_id: ?u32,
    focused_test_id: ?[]const u8,
    focused_is_viewport: bool,
    last_focus_reason: []const u8,
    overlay_present: bool,
    dispatch_depth: usize,
    content_window_focused: bool,
    content_content_focused: bool,
};
const Presentation = struct { input: content.Context, sink: frames.Sink };
var active: ?*Runner = null;
const Runner = struct {
    input: Input,
    approved_leaf: [32]u8,
    io: std.Io,
    app: *zenit.App,
    owner_thread: std.Thread.Id,
    registry: hosts.Registry,
    hop_assets: [8]identity.AssetOwner = undefined,
    library: ssh.Library,
    host_keys: known.HostKeyStore,
    retainer: Retainer = .{},
    budget: budgets.Budget = budgets.Budget.init(budgets.application_bytes),
    journal_backend: ReadOnlyJournal = .{},
    secret_store: secrets.Store,
    tls_store: tls.Store,
    challenge_host: challenges.Host,
    plugin: ?*plugin_api.Plugin = null,
    host: ?sessions.SessionHost = null,
    accepted: ?sessions.Accepted = null,
    authorized_owner: ?identity.SessionHandle = null,
    authorized_operation: ?services.OperationKey = null,
    sink: ?*frames.Sink = null,
    content_context: ?*content.Context = null,
    presentations: [4]?*Presentation = @splat(null),
    presentation_count: usize = 0,
    tab_id: ?identity.TabId = null,
    renderer: ?contract.RendererInstance = null,
    scope: ?*ui.Scope = null,
    root: ?*ui.Node = null,
    slot: ?*ui.Node = null,
    envelope: ?envelopes.Envelope = null,
    workspace_ids: identity.Allocator(identity.WorkspaceId) = .{},
    tab_ids: identity.Allocator(identity.TabId) = .{},
    target: ?sessions.AttachmentTarget = null,
    begin_ms: u64 = 0,
    first_frame_ms: ?u64 = null,
    close_requested: bool = false,
    finished: bool = false,
    released: bool = false,
    failed: bool = false,
    failure_code: ?[]const u8 = null,
    native_route_verified: bool = false,
    safe_views_verified: bool = false,
    console_ready: bool = false,
    last_route: ?controller_api.RouteState = null,
    last_video: ?controller_api.VideoState = null,
    last_management: ?controller_api.ManagementState = null,
    last_frames: u64 = 0,
    video_evidence: VideoEvidence = .{},
    last_width: u32 = 0,
    last_height: u32 = 0,
    last_input_sequence: u64 = 0,
    last_input_queued: usize = 0,
    last_automation_pending: usize = 0,
    last_input_remote_unknown: bool = false,
    pressed_keys: usize = 0,
    pressed_buttons: u8 = 0,
    web_logout: native_api.RemoteRelease = .not_created,
    kvm_logout: native_api.RemoteRelease = .not_created,
    discovery_summary: ?DiscoverySummary = null,
    typed_management_summary: ?TypedManagementSummary = null,
    logout_summary: ?LogoutSummary = null,
    presentation_summary: ?PresentationSummary = null,
    progress_headline: ?ProgressHeadline = null,
    progress_events: [console.progress.capacity]ProgressEventSummary = @splat(.{}),
    progress_event_count: usize = 0,
    last_progress_stage: ?console.progress.Stage = null,
    progress_shot: bool = false,
    progress_shot_requested_frame: ?u64 = null,
    log_shot: bool = false,
    log_opened_ms: ?u64 = null,
    log_opened_frame: ?u64 = null,
    shots: [3]bool = @splat(false),
    after_layout_registered: bool = false,
    retainer_started: bool = false,
    control_stage: ControlStage = .initial_observation,
    control_stage_ms: u64 = 0,
    control_complete: bool = false,
    control_shots: [3]bool = @splat(false),
    control_requested: bool = false,
    control_focus_wait_reported: bool = false,
    human_lease: ?content.Lease = null,
    human_last_sequence: u64 = 0,
    human_sent_sequence: u64 = 0,
    human_transport_generation: u64 = 0,
    tool_members: [1]tool_api.Member = undefined,
    tool_scope: ?tool_scope_api.Scope = null,
    tool_table: ?tool_api.RequestTable = null,
    tool_operations: tool_operations_api.Store = tool_operations_api.Store.init(a),
    next_tool_operation: u64 = 1,
    expected_approval_operation: ?u64 = null,
    expected_approval_hash: [32]u8 = @splat(0),
    approved_tool_calls: usize = 0,
    readonly_tool_calls: usize = 0,
    observation_id: ?u64 = null,
    observation_width: u32 = 0,
    observation_height: u32 = 0,
    observation_valid_until_ms: u64 = 0,
    observation_frame_generation: u64 = 0,
    observation_frame_sequence: u64 = 0,
    action_timing: ?ActionTiming = null,
    last_completed_action_timing: ?ActionTiming = null,
    actions_with_post_send_observation: usize = 0,
    ai_operation: ?u64 = null,
    ai_keyboard_sent: bool = false,
    ai_pointer_sent: bool = false,
    ai_keyboard_receipt: ?WireReceiptSummary = null,
    ai_pointer_receipt: ?WireReceiptSummary = null,
    ai_grant: ?content.AutomationGrant = null,
    control_stopped: std.atomic.Value(bool) = .init(false),
    last_status_poll_ms: u64 = 0,
    last_wire_receipt: ?WireReceiptSummary = null,
    last_tool_error: ?anyerror = null,
    screenshot_wait_started_ms: ?u64 = null,
    next_screenshot_retry_ms: u64 = 0,
    native_view: NativeViewEvidence = .{},
    native_pending: [256]NativeQueued = undefined,
    native_pending_count: usize = 0,
    native_last_window_active: ?bool = null,
    native_capture_was_active: bool = false,
    native_last_pointer: ?remote_input.Pointer = null,
    native_pointer_epoch: u64 = 0,
    native_pointer_transport: u64 = 0,
    native_left_down_queued: ?NativeButtonStart = null,
    native_left_down_sent: ?NativeButtonStart = null,
    native_refresh_needed: bool = false,
    native_refresh_sequence: ?u64 = null,
    native_command: ?InteractiveCommand = null,
    active_command: ?InteractiveCommand = null,
    interactive_actions_sent: usize = 0,
    interactive_actions_cancelled_unsent: usize = 0,
    interactive_stop_requests: usize = 0,
    action_stopped: std.atomic.Value(bool) = .init(false),
    reconnects: usize = 0,
    reconnect_requested: bool = false,
    retry_previous_proof: ?content.AutomationProof = null,
    stopped_previous_proof: ?content.AutomationProof = null,
    old_proof_invalid_after_stop: bool = false,
    old_proof_rejected_after_stop: bool = false,
    old_proof_invalid_after_retry: bool = false,
    old_proof_rejected_by_new_owner: bool = false,
    retry_own_logout_confirmed: bool = true,
    same_tab_preserved: bool = true,
    cancelled_connection: bool = false,
    native_focus_subscription: ?u64 = null,
    last_native_focus: ?NativeFocusDiagnostic = null,

    fn create(io: std.Io, app: *zenit.App, value: Input, approved: [32]u8) !*Runner {
        const self = try a.create(Runner);
        errdefer a.destroy(self);
        // Read bytes directly and parse without a persistence facade: missing
        // files fail, and this store has no capability to rewrite known_hosts.
        const known_bytes = try std.Io.Dir.cwd().readFileAlloc(io, value.known_hosts_path, a, .limited(known.max_file_bytes));
        defer a.free(known_bytes);
        var host_keys = try known.HostKeyStore.parse(a, known_bytes);
        errdefer host_keys.deinit();
        var library = try ssh.Library.init();
        errdefer library.deinit();
        self.* = .{ .input = value, .approved_leaf = approved, .io = io, .app = app, .owner_thread = std.Thread.getCurrentId(), .registry = .{ .arena = .init(a), .hosts = &.{} }, .library = library, .host_keys = host_keys, .secret_store = secrets.Store.init(a), .tls_store = undefined, .challenge_host = challenges.Host.init(a) };
        self.tls_store = tls.Store.init(a, .{ .context = self, .verify = verifyNative }, null);
        errdefer {
            self.registry.deinit();
            self.secret_store.deinit();
            self.tls_store.deinit();
            self.challenge_host.deinit();
        }
        for (value.ssh_hops, 0..) |hop, i| self.hop_assets[i] = try self.registry.add(.{ .name = "Read-only SSH route", .host = hop.host, .port = hop.port, .user = hop.username, .auth_mode = .password, .strict_host_key_checking = true, .auto_shell_integration = false });
        self.plugin = try plugin_api.Plugin.init(a, .{ .frame_budget = &self.budget, .journal_backend = self.journal_backend.backend(), .management_policy = .read_only, .probe_challenges = &self.challenge_host, .retry_context = self, .retry_accepted = retryAccepted });
        errdefer self.plugin.?.deinit() catch unreachable;
        self.host = try sessions.SessionHost.initPlugins(a, &.{self.plugin.?.manifest()}, &.{self.plugin.?.renderer()});
        errdefer self.host.?.deinit();
        self.host.?.setContextFactory(.{ .context = self, .create = makeContext });
        try self.retainer.start();
        self.retainer_started = true;
        return self;
    }
    fn verifyNative(raw: ?*anyopaque, authority: tls.Authority, chain: []const []const u8) !tls.VerificationResult {
        const self: *Runner = @ptrCast(@alignCast(raw.?));
        const expected = try tls.canonicalize(.{ .host = self.input.bmc.host, .port = self.input.bmc.https_port });
        const actual = try tls.canonicalize(authority);
        if (!actual.eql(&expected) or chain.len == 0) return error.WrongTlsAuthority;
        var received: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(chain[0], &received, .{});
        if (!std.mem.eql(u8, &received, &self.approved_leaf)) return error.ApprovedTlsLeafMismatch;
        const verifier = tls.Verifier.native();
        return verifier.verify(verifier.context, authority, chain);
    }
    fn credentials(raw: *anyopaque, owner: identity.ResourceOwner, asset: identity.AssetOwner, alloc: std.mem.Allocator) !ssh.Auth {
        const self: *Runner = @ptrCast(@alignCast(raw));
        if (std.Thread.getCurrentId() != self.owner_thread or owner != .session) return error.WrongCredentialOwner;
        const original = self.authorized_owner orelse return error.WrongCredentialOwner;
        const key = self.authorized_operation orelse return error.WrongCredentialOperation;
        if (!owner.session.eql(original)) return error.WrongCredentialOwner;
        try tls.requireOperation(original, key);
        const state = self.host.?.queryState(original) orelse return error.StaleCredentialOwner;
        if (!state.create_operation.eql(key) or state.lifecycle != .creating) return error.StaleCredentialOperation;
        for (self.hop_assets[0..self.input.ssh_hops.len], 0..) |expected, i| if (expected.id == asset.id and expected.revision == asset.revision) {
            const config = self.registry.hosts[self.registry.indexOf(asset.id) orelse return error.StaleCredentialAsset];
            if (config.revision != asset.revision or !config.strict_host_key_checking or !std.mem.eql(u8, config.protocolId(), "ssh")) return error.StaleCredentialAsset;
            // Factory immediately clones this owned one-attempt Auth into its
            // zeroing arena, never retaining a config/store password literal.
            return .{ .password = try alloc.dupeSentinel(u8, self.input.ssh_hops[i].password, 0) };
        };
        return error.CredentialAssetDenied;
    }
    fn makeContext(raw: *anyopaque, owner: identity.SessionHandle, key: services.OperationKey, target: contexts.Target) !contexts.HostContext {
        const self: *Runner = @ptrCast(@alignCast(raw));
        if (std.Thread.getCurrentId() != self.owner_thread) return error.InvalidContextRequest;
        if (self.authorized_owner != null) try self.prepareRetryContext(owner);
        try tls.requireOperation(owner, key);
        const actual = self.host.?.queryState(owner) orelse return error.InvalidContextOwner;
        if (!actual.create_operation.eql(key) or actual.target.window_id != target.window_id or actual.target.workspace_id != target.workspace_id) return error.InvalidContextOperation;
        self.authorized_owner = owner;
        self.authorized_operation = key;
        try self.secret_store.authorizeDefault(owner, key, self.input.bmc.password);
        if (self.presentation_count >= self.presentations.len) return error.AcceptanceRetryLimit;
        const presentation = try a.create(Presentation);
        presentation.* = .{
            .sink = frames.Sink.initWithBudget(owner, frames.backendFor(self.app.sharedImageStore() orelse return error.ImageStoreUnavailable), &self.budget, .kvm),
            .input = .{ .owner = owner, .window_id = target.window_id, .window = .{ .context = self, .request_fullscreen = fullscreen, .fullscreen_state = fullscreenState, .transfer = transfer }, .consumer = .{ .context = self, .consume = denyInput }, .authorized = false },
        };
        self.presentations[self.presentation_count] = presentation;
        self.presentation_count += 1;
        self.sink = &presentation.sink;
        self.content_context = &presentation.input;
        const auth_provider: transports.Credentials = .{ .context = self, .resolve = credentials };
        return .{ .owner = owner, .operation = key, .target = target, .connection_configs = resolution.Resolver.init(&self.registry), .transports = .{ .allocator = a, .library = &self.library, .credentials = auth_provider, .host_key_store = &self.host_keys, .host_key_decision = .reject_unknown, .timeout_ms = 15_000, .operation_key = key, .failed_open_owner = self.retainer.interface() }, .credentials = auth_provider, .secrets = self.secret_store.facade(owner), .trust = .{ .ssh_host_keys = &self.host_keys, .tls = self.tls_store.facade(owner) }, .challenges = &self.challenge_host, .presentation = .{ .input = self.content_context.?, .frame_sink = self.sink.? } };
    }
    fn fullscreen(_: *anyopaque, _: bool) !void {
        return error.ReadOnlyAcceptanceWindow;
    }
    fn fullscreenState(_: *anyopaque) bool {
        return false;
    }
    fn transfer(_: *anyopaque, _: identity.SessionHandle, _: identity.WindowId) !void {
        return error.ReadOnlyAcceptanceWindow;
    }
    fn denyInput(_: *anyopaque, _: content.Input) !void {
        return error.ReadOnlyAcceptanceInput;
    }
    fn begin(self: *Runner) !void {
        var hops: [8]model.Hop = undefined;
        for (self.hop_assets[0..self.input.ssh_hops.len], 0..) |asset, i| hops[i] = .{ .asset_id = @backingInt(asset.id) };
        const payload: model.Payload = .{ .endpoint = .{ .host = self.input.bmc.host, .https_port = self.input.bmc.https_port }, .username = self.input.bmc.username, .access = .{ .ssh_route = .{ .hops = hops[0..self.input.ssh_hops.len] } }, .display = .{ .read_only_requested = isReadOnly(self.input) } };
        self.envelope = .{ .protocol_id = model.protocol_id, .name = if (isReadOnly(self.input)) "BMC · live read-only" else "BMC · live safe control", .payload = try std.json.Stringify.valueAlloc(a, payload, .{}) };
        self.target = .{ .window_id = @fromBackingInt(self.app.windowId()), .workspace_id = try self.workspace_ids.allocate() };
        self.begin_ms = runtime_api.monotonicMs();
        self.video_evidence.connection_started_ms = self.begin_ms;
        self.accepted = try self.host.?.open(self.envelope.?, .{ .request_key = 1, .target = self.target.? });
        emit(.{ .phase = "accepted", .production_plugin = true, .automatic_profile = true, .native_owned_ssh = true, .ssh_nodes = self.input.ssh_hops.len, .shell = false, .pty = false, .read_only_requested = isReadOnly(self.input), .acceptance_mode = @tagName(self.input.acceptance_mode) });
    }
    fn runtime(self: *Runner) ?*runtime_api.Runtime {
        const accepted = self.accepted orelse return null;
        return (self.plugin orelse return null).runtimeFor(accepted.handle);
    }
    fn captureDiscoverySummary(self: *Runner) ?DiscoverySummary {
        const runtime_value = self.runtime() orelse return self.discovery_summary;
        const backend = runtime_value.backend orelse return self.discovery_summary;
        // The backend publishes this immutable subset through its own release /
        // acquire barrier. Never inspect its worker-owned discovery resources.
        const diagnostic = backend.discoveryDiagnostics() orelse return self.discovery_summary;
        self.discovery_summary = .{ .manager_count = diagnostic.manager_count, .system_count = diagnostic.system_count, .resource_association_verified = diagnostic.resource_association_verified, .resource_association_method = if (diagnostic.resource_association_method) |method| @tagName(method) else null, .mapping_verified = diagnostic.mapping_verified, .mapping_error = if (diagnostic.mapping_error) |err| @errorName(err) else null, .mapping_rejection = if (diagnostic.mapping_rejection) |reason| @tagName(reason) else null, .mapping_system_status = diagnostic.mapping_system_status, .mapping_system_validity = if (diagnostic.mapping_system_validity) |validity| @tagName(validity) else null, .readonly_system_projection = diagnostic.readonly_system_projection, .readonly_rejection = if (diagnostic.readonly_rejection) |reason| @tagName(reason) else null, .readonly_collection_count = diagnostic.readonly_collection_count, .readonly_member_count = diagnostic.readonly_member_count, .readonly_collection_status = diagnostic.readonly_collection_status, .readonly_collection_validity = if (diagnostic.readonly_collection_validity) |validity| @tagName(validity) else null, .readonly_system_status = diagnostic.readonly_system_status, .readonly_system_validity = if (diagnostic.readonly_system_validity) |validity| @tagName(validity) else null, .readonly_system_identity_present = diagnostic.readonly_system_identity_present };
        self.discovery_summary.?.management_target_verified = diagnostic.management_target_verified;
        self.discovery_summary.?.management_target_error = if (diagnostic.management_target_error) |err| @errorName(err) else null;
        return self.discovery_summary;
    }
    fn captureProgressSummary(self: *Runner, value: console.progress.Snapshot) void {
        // Controller.poll() copies this bounded, lock-protected snapshot. Its
        // strings are exclusively @errorName values by the production Tracker
        // contract; no route/authority/device text can enter this projection.
        self.progress_headline = .{ .stage = @tagName(value.stage), .event_count = value.event_count, .elapsed_ms = value.elapsed_ms, .waiting_for_user = value.waiting_for_user, .failure_stage = if (value.failure_stage) |stage| @tagName(stage) else null, .static_errorcode = value.failure_code, .failure_event = value.failure_event };
        self.progress_event_count = @min(value.event_count, self.progress_events.len);
        for (value.events[0..self.progress_event_count], 0..) |event, i| self.progress_events[i] = .{ .sequence = event.sequence, .at_ms = event.at_ms, .stage = @tagName(event.stage), .kind = @tagName(event.kind), .code = @tagName(event.code), .resource = @tagName(event.resource), .http_status = event.http_status, .static_errorcode = event.error_code, .count = event.count, .validity = if (event.validity) |validity| @tagName(validity) else null, .context = event.context };
        if (value.revision != 0 and self.last_progress_stage != value.stage) {
            self.last_progress_stage = value.stage;
            emit(.{ .phase = "progress_state", .progress = self.progress_headline });
        }
    }
    fn observeProgressShot(self: *Runner, value: console.progress.Snapshot, frame_received: bool) void {
        if (self.progress_shot or frame_received or self.close_requested or self.renderer == null or value.event_count == 0 or value.elapsed_ms < 100) return;
        const view: *views.View = @ptrCast(@alignCast(self.renderer.?.context));
        if (!view.progress_active) return;
        const waiting = view.waiting orelse return;
        const rect = waiting.globalRect();
        if (rect.w <= 0 or rect.h <= 0) return;
        if (self.progress_shot_requested_frame == null) {
            self.progress_shot_requested_frame = self.app.renderer.frame_count;
            self.app.cx.requestRedraw();
            return;
        }
        if (self.app.renderer.frame_count <= self.progress_shot_requested_frame.? or !self.app.renderer.last_frame_presented) return;
        self.progress_shot = self.app.capturePresentedToPng("/tmp/zerowork-bmc-live-progress.png");
        if (self.progress_shot) emit(.{ .phase = "progress_screenshot", .progress = self.progress_headline });
    }
    fn captureTypedManagementSummary(self: *Runner) !TypedManagementSummary {
        const access = try self.host.?.serviceAccess(self.accepted.?.handle);
        const call: services.Call = .{ .owner = self.accepted.?.handle, .binding_generation = self.accepted.?.handle.generation };
        const p = (try access.lookup(call.owner, services.power_definition)) orelse return error.MissingPowerService;
        const p_table = try p.borrow(services.PowerService, services.power_key, call.owner);
        var power = try p_table.snapshot(p.context, call, a);
        defer power.deinit();
        const b = (try access.lookup(call.owner, services.boot_definition)) orelse return error.MissingBootService;
        const b_table = try b.borrow(services.BootService, services.boot_key, call.owner);
        var boot = try b_table.snapshot(b.context, call, a);
        defer boot.deinit();
        const runtime_value = self.runtime() orelse return error.MissingRuntime;
        if (runtime_value.management_policy != .read_only or runtime_value.controller.manager.policy != .read_only or runtime_value.controller.manager.engine.policy != .read_only) return error.UnsafeManagementPolicy;
        if (power.value.capability.write_granted or boot.value.capability.write_granted or power.value.capability.write_requestable or boot.value.capability.write_requestable) return error.UnsafeManagementActions;
        const pv = power.value;
        const bv = boot.value;
        const value: TypedManagementSummary = .{
            .management_policy = @tagName(runtime_value.management_policy),
            .power_write_requestable = pv.capability.write_requestable,
            .power_write_granted = pv.capability.write_granted,
            .boot_write_requestable = bv.capability.write_requestable,
            .boot_write_granted = bv.capability.write_granted,
            .power_resource_present = pv.system_uri.len != 0,
            .power_resource_validity = pv.resource_evidence.validity,
            .power_mapping_verified = pv.capability.system_mapping_verified,
            .power_state_present = pv.state.value != null,
            .power_state_known = if (pv.state.value) |state| state != .unknown else false,
            .power_state = pv.state.value,
            .power_last_reset_time_present = pv.last_reset_time.value != null,
            .power_last_reset_time_validity = pv.last_reset_time.evidence.validity,
            .power_state_validity = pv.state.evidence.validity,
            .power_reset_types_count = if (pv.reset_types.value) |items| items.len else 0,
            .power_reset_types_validity = pv.reset_types.evidence.validity,
            .boot_resource_present = bv.system_uri.len != 0,
            .boot_resource_validity = bv.resource_evidence.validity,
            .boot_mapping_verified = bv.capability.system_mapping_verified,
            .boot_state_present = bv.state.enabled != null or bv.state.target != null or bv.state.mode != null,
            .boot_enabled_present = bv.state.enabled != null,
            .boot_target_present = bv.state.target != null,
            .boot_mode_present = bv.state.mode != null,
            .boot_enabled_validity = bv.enabled_evidence.validity,
            .boot_target_validity = bv.target_evidence.validity,
            .boot_mode_validity = bv.mode_evidence.validity,
            .boot_order_count = if (bv.boot_order.value) |items| items.len else 0,
            .boot_order_validity = bv.boot_order.evidence.validity,
            .boot_alias_order_count = if (bv.alias_boot_order.value) |items| items.len else 0,
            .boot_option_count = bv.options.len,
            .boot_allowed_targets_count = if (bv.allowed_targets.value) |items| items.len else 0,
            .boot_allowed_modes_count = if (bv.allowed_modes.value) |items| items.len else 0,
            .boot_pending_present = bv.pending != null,
        };
        self.typed_management_summary = value;
        return value;
    }
    fn capturePresentationSummary(self: *Runner) !?PresentationSummary {
        const access = try self.host.?.serviceAccess(self.accepted.?.handle);
        const binding = (try access.lookup(self.accepted.?.handle, framebuffer.definition)) orelse return error.MissingFramebufferService;
        const table = try binding.borrow(framebuffer.Interface, framebuffer.key, self.accepted.?.handle);
        var lease = switch (table.acquire_latest(binding.context, binding, 0)) {
            .frame => |value| value,
            .unavailable, .unchanged => return self.presentation_summary,
            .stale_binding => return error.StaleFrameBinding,
        };
        defer lease.release();
        const frame = lease.snapshot;
        if (frame.width == 0 or frame.height == 0 or frame.pixels.len < frame.stride * @as(usize, frame.height)) return error.InvalidSampleFrame;
        const columns: usize = @min(frame.width, 64);
        const rows: usize = @min(frame.height, 64);
        var nonblack: usize = 0;
        // A bounded RGB-only grid, with no pixel values or digests retained or
        // logged. Alpha=255 in a black remote frame is not non-black content.
        for (0..rows) |row| {
            const y = if (rows == 1) 0 else row * (@as(usize, frame.height) - 1) / (rows - 1);
            for (0..columns) |column| {
                const x = if (columns == 1) 0 else column * (@as(usize, frame.width) - 1) / (columns - 1);
                const offset = y * frame.stride + x * 4;
                if (offset + 2 >= frame.pixels.len) return error.InvalidSampleFrame;
                if (frame.pixels[offset] != 0 or frame.pixels[offset + 1] != 0 or frame.pixels[offset + 2] != 0) nonblack += 1;
            }
        }
        const sink = self.sink orelse return error.MissingFrameSink;
        const view: ?*views.View = if (self.renderer) |renderer| @ptrCast(@alignCast(renderer.context)) else null;
        const summary: PresentationSummary = .{
            .sample_width = frame.width,
            .sample_height = frame.height,
            .sampled_pixels = columns * rows,
            .nonblack_samples = nonblack,
            .has_nonblack_samples = nonblack != 0,
            .sink_has_texture = sink.texture != null,
            .sink_generation_matches_sample = sink.texture != null and sink.frame_generation == frame.frame_generation,
            .sink_sequence_matches_sample = sink.texture != null and sink.revision == frame.sequence,
            .sink_dimensions_match_sample = sink.texture != null and sink.width == frame.width and sink.height == frame.height,
            .renderer_has_texture = if (view) |v| v.texture != null else false,
            .renderer_texture_matches_sink = if (view) |v| v.texture != null and v.texture == sink.texture else false,
            .renderer_generation_matches_sink = if (view) |v| v.texture != null and v.frame_generation == sink.frame_generation else false,
            .renderer_sequence_matches_sink = if (view) |v| v.texture != null and v.frame_revision == sink.revision else false,
        };
        self.presentation_summary = summary;
        return summary;
    }
    fn handleChallenges(self: *Runner, runtime_value: *runtime_api.Runtime) !void {
        const incoming = self.challenge_host.snapshot(0, runtime_value.owner) orelse return;
        if (incoming.state != .pending) return;
        const expected = try tls.canonicalize(.{ .host = self.input.bmc.host, .port = self.input.bmc.https_port });
        var approved = false;
        while (!runtime_value.bridge.mutex.tryLock()) std.atomic.spinLoopHint();
        if (runtime_value.bridge.request) |request| switch (request) {
            .trust => |challenge| {
                approved = incoming.kind == .choice and incoming.owner.eql(runtime_value.owner) and incoming.request_id == runtime_value.bridge.request_id and incoming.generation == runtime_value.owner.generation and challenge.owner.eql(runtime_value.owner) and challenge.operation.eql(runtime_value.operation) and challenge.authority.eql(&expected) and challenge.verification.failures.canExcept() and std.mem.eql(u8, &challenge.verification.leaf_fingerprint, &self.approved_leaf);
            },
            .password => {}, // The operation-bound default grant is the only password source.
        };
        runtime_value.bridge.mutex.unlock();
        try self.challenge_host.submitAnswer(incoming.owner, incoming.request_id, incoming.generation, if (incoming.kind == .choice) .{ .choice = if (approved) "once" else "reject" } else .{ .secret_input = "" }, runtime_api.monotonicMs());
        emit(.{ .phase = "tls_challenge", .once = approved, .persistent = false });
        if (!approved) self.fail("TrustChallengeRejected");
    }
    fn mountRenderer(self: *Runner) !void {
        const accepted = self.accepted orelse return;
        const state = self.host.?.queryState(accepted.handle) orelse return error.MissingSession;
        if (state.lifecycle != .ready or self.renderer != null) return;
        const manifest = self.host.?.manifestFor(accepted.handle) orelse return error.MissingManifest;
        const definition = self.host.?.registry.renderer(manifest.content_renderer) orelse return error.MissingRenderer;
        const service_access = try self.host.?.serviceAccess(accepted.handle);
        const binding = (try service_access.lookup(accepted.handle, console.definition)) orelse return error.MissingConsoleService;
        _ = try binding.borrow(console.Interface, console.key, accepted.handle);
        const renderer_access: service_access_api.SessionServiceAccess = if (self.input.acceptance_mode == .native_interactive) .{ .context = self, .owner = accepted.handle, .lookup_fn = rendererLookup } else service_access;
        self.renderer = try (definition.mount orelse return error.MissingRendererMount)(definition.context, .{ .cx = self.app.cx, .scope = self.scope.?, .slot = self.slot.?, .owner = accepted.handle, .connection = self.envelope.?, .content_context = self.content_context.?, .frame_sink = self.sink.?, .service_access = renderer_access });
        if (self.tab_id == null) self.tab_id = try self.tab_ids.allocate();
        if (!try self.host.?.attached(accepted.handle, .{ .target = self.target.?, .tab_id = self.tab_id.? })) return error.AttachRejected;
        const attached = self.host.?.queryState(accepted.handle) orelse return error.MissingAttachment;
        self.same_tab_preserved = self.same_tab_preserved and attached.attachment != null and attached.attachment.?.tab_id == self.tab_id.?;
        if (!self.same_tab_preserved) return error.TabIdentityChanged;
        if (self.input.acceptance_mode == .safe_interaction) try self.content_context.?.setConsumer(.{ .context = self, .consume = humanConsume });
        if (self.input.acceptance_mode == .native_interactive and self.native_focus_subscription == null) self.native_focus_subscription = try self.app.cx.focus_manager.subscribeVisibility(self, nativeFocusChanged);
        self.console_ready = true;
        emit(.{ .phase = "renderer_ready", .manifest_factory = true, .typed_lookup = true, .production_views = true });
    }
    /// Retry reuses the original logical Tab, but never a facade backing store,
    /// View, image observation or AutomationProof from the retired generation.
    fn prepareRetryContext(self: *Runner, owner: identity.SessionHandle) !void {
        const previous = self.accepted orelse return error.InvalidRetryOwner;
        if (self.input.acceptance_mode != .native_interactive or !self.reconnect_requested or owner.session_id != previous.handle.session_id or owner.generation != previous.handle.generation + 1 or self.presentation_count >= self.presentations.len) return error.InvalidRetryOwner;
        const old = self.runtime() orelse return error.MissingRetiredRuntime;
        if (old.receipt() != .released) return error.RetryCleanupNotReleased;
        emit(.{ .phase = "video_observation", .boundary = "retired_owner", .video = self.videoSummary() });
        const diagnostic = old.remote_logout_diagnostics orelse return error.MissingRetryLogoutReceipt;
        self.retry_own_logout_confirmed = self.retry_own_logout_confirmed and old.remote_web_logout == .confirmed and old.remote_kvm_logout == .confirmed and diagnostic.web.http_status == 200 and diagnostic.kvm.http_status == 200;
        self.stopInteractiveAuthority();
        self.unmountRenderer();
        if (self.content_context) |context| context.close();
        if (self.sink) |sink| try sink.close();
        self.sink = null;
        self.content_context = null;
        self.authorized_owner = null;
        self.authorized_operation = null;
        self.secret_store.revokeOwner(previous.handle);
        self.tls_store.cancelOwner(previous.handle);
        self.challenge_host.retireOwner(previous.handle);
        if (self.tool_table) |*table| table.deinit();
        self.tool_table = null;
        self.tool_scope = null;
        self.observation_id = null;
        self.observation_frame_generation = 0;
        self.observation_frame_sequence = 0;
        self.action_timing = null;
        self.ai_operation = null;
        self.native_refresh_sequence = null;
        self.native_refresh_needed = false;
        self.native_pending_count = 0;
        self.native_last_pointer = null;
        self.native_left_down_queued = null;
        self.native_left_down_sent = null;
        self.console_ready = false;
        self.safe_views_verified = false;
        self.native_route_verified = false;
        self.first_frame_ms = null;
        self.video_evidence = .{ .connection_started_ms = runtime_api.monotonicMs() };
        self.last_route = null;
        self.last_video = null;
        self.last_management = null;
        self.control_requested = false;
        self.cancelled_connection = false;
        self.control_stage = .initial_observation;
        emit(.{ .phase = "retry_old_owner_released", .old_owner = previous.handle, .new_owner = owner, .same_tab_id = @backingInt(self.tab_id.?), .own_logout_http_200 = self.retry_own_logout_confirmed, .old_proof_valid = if (self.retry_previous_proof) |proof| proof.valid() else false, .old_input_replayed = false });
    }
    fn retryAccepted(raw: ?*anyopaque, accepted: sessions.Accepted) !void {
        const self: *Runner = @ptrCast(@alignCast(raw orelse return error.MissingRetryContext));
        self.accepted = accepted;
        self.reconnects += 1;
        self.reconnect_requested = false;
        self.old_proof_invalid_after_retry = if (self.retry_previous_proof) |proof| !proof.valid() else false;
        self.old_proof_rejected_by_new_owner = false;
        emit(.{ .phase = "retry_new_owner_accepted", .owner = accepted.handle, .same_tab_id = @backingInt(self.tab_id.?), .old_proof_present = self.retry_previous_proof != null, .old_proof_invalid = self.old_proof_invalid_after_retry, .fresh_observation_required = true });
    }
    fn unmountRenderer(self: *Runner) void {
        if (self.renderer) |renderer| {
            // Retain the bounded old tree until window-scope disposal. Its
            // callbacks and hooks are detached by the real renderer's unmount.
            // This avoids disposing a page while an event still owns a Node.
            const view: *views.View = @ptrCast(@alignCast(renderer.context));
            if (view.root) |root| root.setDisplay(.none);
            self.app.cx.clearFocus();
            renderer.vtable.unmount(renderer.context);
        }
        self.renderer = null;
    }
    /// An observation-only proxy around the original production typed input.
    /// Only commands actually emitted by views.View pass here; it never creates
    /// an event or treats queued acceptance as a wire acknowledgement.
    fn rendererLookup(raw: *anyopaque, owner: identity.SessionHandle, definition: typed.Definition) !?typed.Binding {
        const self: *Runner = @ptrCast(@alignCast(raw));
        if (!self.accepted.?.handle.eql(owner)) return error.StaleSession;
        const access = try self.host.?.serviceAccess(owner);
        const actual = (try access.lookup(owner, definition)) orelse return null;
        if (!definition.matches(remote_input.definition)) return actual;
        return typed.Binding.init(remote_input.Interface, remote_input.key, self, &native_input_table, owner, actual.revision);
    }
    fn nativeInputBinding(self: *Runner, binding: typed.Binding) !InputService {
        if (self.input.acceptance_mode != .native_interactive or binding.context != @as(*anyopaque, self) or !binding.owner.eql(self.accepted.?.handle) or binding.generation != self.accepted.?.handle.generation or !binding.definition.matches(remote_input.definition) or !binding.authorized) return error.StaleBinding;
        return self.inputService();
    }
    fn nativeInputSnapshot(raw: *anyopaque, binding: typed.Binding) !remote_input.Snapshot {
        const self: *Runner = @ptrCast(@alignCast(raw));
        const service = try self.nativeInputBinding(binding);
        return service.table.snapshot(service.binding.context, service.binding);
    }
    fn nativeInputSubmit(raw: *anyopaque, binding: typed.Binding, command: remote_input.Command) remote_input.SubmitResult {
        const self: *Runner = @ptrCast(@alignCast(raw));
        const service = self.nativeInputBinding(binding) catch return .stale_binding;
        const snapshot = service.table.snapshot(service.binding.context, service.binding) catch return .stale_binding;
        const result = service.table.submit(service.binding.context, service.binding, command);
        if (result == .accepted) {
            self.native_view.accepted_events += 1;
            self.native_view.last_queued_sequence = command.input_sequence;
            var queued: NativeQueued = .{ .sequence = command.input_sequence, .transport = snapshot.transport_generation, .epoch = snapshot.input_epoch, .queued_observed_monotonic_ms = runtime_api.monotonicMs(), .kind = .other, .event_kind = switch (command.event) {
                .key => .key,
                .pointer => .pointer,
                .wheel => .wheel,
                .chord => .chord,
            } };
            switch (command.event) {
                .key => |value| {
                    // Modifier/navigation diagnostics cannot reconstruct typed
                    // text or credentials. Printable/unknown keysyms stay out
                    // of both queued and sent receipts.
                    queued.keysym = switch (value.keysym) {
                        0xffe1...0xffee, 0xff50...0xff58, 0xff1b, 0xff09 => value.keysym,
                        else => null,
                    };
                    queued.keysym_redacted = queued.keysym == null;
                    queued.down = value.down;
                    if (value.keysym == 0xffe1 or value.keysym == 0xffe2) queued.kind = if (value.down) .shift_down else .shift_up;
                },
                .pointer => |value| {
                    const previous = if (self.native_pointer_epoch == snapshot.input_epoch and self.native_pointer_transport == snapshot.transport_generation) self.native_last_pointer else null;
                    const previous_buttons: u8 = if (previous) |last| last.buttons else 0;
                    const moved = if (previous) |last| value.x != last.x or value.y != last.y else false;
                    self.native_last_pointer = value;
                    self.native_pointer_epoch = snapshot.input_epoch;
                    self.native_pointer_transport = snapshot.transport_generation;
                    queued.buttons = value.buttons;
                    if (previous_buttons & 1 == 0 and value.buttons & 1 != 0) {
                        queued.kind = .left_button_down;
                        queued.button = .left;
                        queued.down = true;
                        self.native_left_down_queued = .{ .sequence = command.input_sequence, .transport = snapshot.transport_generation, .epoch = snapshot.input_epoch, .owner_generation = binding.owner.generation };
                    } else if (previous_buttons & 1 != 0 and value.buttons & 1 == 0) {
                        queued.kind = .left_button_up;
                        queued.button = .left;
                        queued.down = false;
                        if (self.native_left_down_queued) |start| if (start.transport == snapshot.transport_generation and start.epoch == snapshot.input_epoch and start.owner_generation == binding.owner.generation) {
                            queued.click_down_sequence = start.sequence;
                            self.native_view.left_click_queued_complete = true;
                        };
                        self.native_left_down_queued = null;
                    } else if (previous_buttons == 0 and value.buttons == 0 and moved) {
                        // A button transition, including release at a changed
                        // coordinate, never counts as a mouse-move verdict.
                        queued.kind = .pointer_move;
                    }
                },
                else => {},
            }
            switch (queued.kind) {
                .shift_down => self.native_view.shift_down_queued = true,
                .shift_up => self.native_view.shift_up_queued = true,
                .pointer_move => self.native_view.pointer_move_queued = true,
                .left_button_down => self.native_view.left_button_down_queued = true,
                .left_button_up => self.native_view.left_button_up_queued = true,
                .other => {},
            }
            if (self.native_pending_count < self.native_pending.len) {
                self.native_pending[self.native_pending_count] = queued;
                self.native_pending_count += 1;
            }
            emit(.{ .phase = "native_view_input", .owner = binding.owner, .state = "queued", .kind = @tagName(queued.kind), .event_kind = queued.event_kind, .keysym = queued.keysym, .down = queued.down, .keysym_redacted = queued.keysym_redacted, .button = queued.button, .buttons = queued.buttons, .click_down_sequence = queued.click_down_sequence, .input_sequence = command.input_sequence, .input_epoch = snapshot.input_epoch, .transport_generation = snapshot.transport_generation, .queued_observed_monotonic_ms = queued.queued_observed_monotonic_ms, .wire_sent = false, .remote_application_effect_verified = false });
        }
        return result;
    }
    fn nativeInputRelease(raw: *anyopaque, binding: typed.Binding, cause: remote_input.ReleaseCause) remote_input.ReleaseResult {
        const self: *Runner = @ptrCast(@alignCast(raw));
        const service = self.nativeInputBinding(binding) catch return .stale_binding;
        const result = service.table.release_all(service.binding.context, service.binding, cause);
        self.native_last_pointer = null;
        self.native_left_down_queued = null;
        self.native_left_down_sent = null;
        emit(.{ .phase = "native_view_release", .owner = binding.owner, .cause = @tagName(cause), .result = @tagName(result), .focus = self.nativeFocusDiagnostic() });
        return result;
    }
    fn nativeFocusDiagnostic(self: *Runner) NativeFocusDiagnostic {
        const cx = self.app.cx;
        const focused = cx.focus_manager.getFocused();
        const view: ?*views.View = if (self.renderer) |renderer| @ptrCast(@alignCast(renderer.context)) else null;
        return .{
            .window_active = cx.window_active,
            .renderer_window_focused = if (view) |value| value.window_focused else false,
            .focused_node_id = if (focused) |node| node.id else null,
            .focused_test_id = if (focused) |node| node.meta.ownership.meta.test_id else null,
            .focused_is_viewport = if (view) |value| focused != null and focused == value.viewport else false,
            .last_focus_reason = @tagName(cx.focus_manager.last_focus_reason),
            .overlay_present = cx.overlay_stack.topmost() != null,
            .dispatch_depth = cx.dispatcher.dispatch_depth,
            .content_window_focused = if (self.content_context) |context| context.focused else false,
            .content_content_focused = if (self.content_context) |context| context.content_focused else false,
        };
    }
    fn nativeFocusChanged(raw: *anyopaque) void {
        const self: *Runner = @ptrCast(@alignCast(raw));
        self.observeNativeFocus();
    }
    fn observeNativeFocus(self: *Runner) void {
        const next = self.nativeFocusDiagnostic();
        if (self.last_native_focus) |last| if (std.meta.eql(last, next)) return;
        self.last_native_focus = next;
        emit(.{ .phase = "native_focus_state", .focus = next });
    }
    fn nativeInputChord(raw: *anyopaque, binding: typed.Binding, command: remote_input.ExplicitChordCommand) remote_input.SubmitResult {
        const self: *Runner = @ptrCast(@alignCast(raw));
        const service = self.nativeInputBinding(binding) catch return .stale_binding;
        const submit = service.table.submit_chord orelse return .read_only;
        return submit(service.binding.context, service.binding, command);
    }
    const native_input_table: remote_input.Interface = .{ .snapshot = nativeInputSnapshot, .submit = nativeInputSubmit, .release_all = nativeInputRelease, .submit_chord = nativeInputChord };
    fn fail(self: *Runner, code: []const u8) void {
        if (!self.failed) emit(.{ .phase = "failed", .code = code });
        self.failed = true;
        self.failure_code = code;
        self.close_requested = true;
    }
    fn closeRequest(raw: *anyopaque, _: u64, _: zenit.App.CloseReason) void {
        const self: *Runner = @ptrCast(@alignCast(raw));
        self.close_requested = true;
    }
    fn observeVideo(self: *Runner, runtime_value: *runtime_api.Runtime) !void {
        const now = runtime_api.monotonicMs();
        const evidence = &self.video_evidence;
        evidence.last_sampled_ms = now;
        defer if (evidence.last_received_ns != 0) {
            evidence.sampled_latest_age_max_ms = @max(evidence.sampled_latest_age_max_ms, now -| (evidence.last_received_ns / std.time.ns_per_ms));
        };
        var lease = switch (runtime_value.controller.framebuffer.acquireLatest(runtime_value.controller.framebuffer.binding(), evidence.last_sequence)) {
            .frame => |value| value,
            .stale_binding => return error.StaleVideoEvidenceOwner,
            else => return,
        };
        defer lease.release();
        const frame = lease.snapshot;
        if (!frame.session_handle.eql(self.accepted.?.handle)) return error.StaleVideoEvidenceOwner;
        if (evidence.first_sequence == 0) {
            evidence.first_sampled_ms = now;
            evidence.first_sequence = frame.sequence;
        } else if (frame.sequence == evidence.last_sequence + 1 and frame.received_monotonic_ns >= evidence.last_received_ns) {
            const interval = frame.received_monotonic_ns - evidence.last_received_ns;
            evidence.consecutive_interval_samples += 1;
            evidence.consecutive_interval_total_ns += interval;
            evidence.consecutive_interval_min_ns = @min(evidence.consecutive_interval_min_ns, interval);
            evidence.consecutive_interval_max_ns = @max(evidence.consecutive_interval_max_ns, interval);
        }
        evidence.unsampled_published_sequences += frame.sequence - evidence.last_sequence - 1;
        evidence.sampled_latest_frames += 1;
        evidence.last_sequence = frame.sequence;
        evidence.last_received_ns = frame.received_monotonic_ns;
    }
    fn videoSummary(self: *Runner) VideoSummary {
        const evidence = &self.video_evidence;
        const elapsed = if (evidence.first_sequence != 0) evidence.last_sampled_ms -| evidence.first_sampled_ms else 0;
        const age: ?u64 = if (evidence.last_received_ns != 0) evidence.last_sampled_ms -| (evidence.last_received_ns / std.time.ns_per_ms) else null;
        const intervals = evidence.consecutive_interval_samples;
        return .{
            .owner_generation = if (self.accepted) |accepted| accepted.handle.generation else null,
            .observation_ms = elapsed,
            .first_frame_observed_after_connection_ms = if (evidence.first_sequence != 0) evidence.first_sampled_ms -| evidence.connection_started_ms else null,
            .published_complete_cpu_frames = self.last_frames,
            .sampled_latest_frames = evidence.sampled_latest_frames,
            .published_updates_over_observation = evidence.last_sequence -| evidence.first_sequence,
            .published_sequences_not_individually_sampled = evidence.unsampled_published_sequences,
            .published_updates_per_second_over_observation = if (elapsed != 0) @as(f64, @floatFromInt(evidence.last_sequence - evidence.first_sequence)) * 1000 / @as(f64, @floatFromInt(elapsed)) else null,
            .consecutive_received_interval_samples = intervals,
            .consecutive_received_interval_min_ms = if (intervals != 0) @as(f64, @floatFromInt(evidence.consecutive_interval_min_ns)) / std.time.ns_per_ms else null,
            .consecutive_received_interval_mean_ms = if (intervals != 0) @as(f64, @floatFromInt(evidence.consecutive_interval_total_ns)) / @as(f64, @floatFromInt(intervals)) / std.time.ns_per_ms else null,
            .consecutive_received_interval_max_ms = if (intervals != 0) @as(f64, @floatFromInt(evidence.consecutive_interval_max_ns)) / std.time.ns_per_ms else null,
            .sampled_latest_frame_age_ms = age,
            .sampled_latest_frame_age_max_ms = evidence.sampled_latest_age_max_ms,
        };
    }
    fn poll(self: *Runner) !void {
        if (self.finished) return;
        if (self.plugin != null) {
            if (self.host) |*host| _ = try host.pollControllers();
        }
        if (self.runtime()) |runtime_value| {
            try self.handleChallenges(runtime_value);
            try self.mountRenderer();
            const state = runtime_value.controller.poll();
            self.captureProgressSummary(state.progress);
            self.observeProgressShot(state.progress, runtime_value.last_sequence != 0);
            self.last_frames = state.published_frames;
            if (!self.close_requested and !self.reconnect_requested and !self.cancelled_connection) try self.observeVideo(runtime_value);
            self.last_width = runtime_value.last_width;
            self.last_height = runtime_value.last_height;
            self.last_input_sequence = state.input.last_input_sequence;
            self.last_input_queued = state.input.queued;
            self.last_automation_pending = state.input.automation_queued;
            self.last_input_remote_unknown = state.input.remote_unconfirmed;
            if (state.route != self.last_route or state.video != self.last_video or state.management != self.last_management) {
                emit(.{ .phase = "state", .route = @tagName(state.route), .video = @tagName(state.video), .management = @tagName(state.management), .width = self.last_width, .height = self.last_height, .frames = self.last_frames, .budget_bytes = self.budget.usedBytes() });
                self.last_route = state.route;
                self.last_video = state.video;
                self.last_management = state.management;
            }
            if (state.route == .connected and !self.native_route_verified) {
                const backend = runtime_value.backend orelse return error.MissingNativeBackend;
                if (backend.pair.transport.nativeSessionIdentity() == 0 or backend.pair.transport.options.len != self.input.ssh_hops.len) return error.InvalidOwnedSshRoute;
                self.native_route_verified = true;
                emit(.{ .phase = "route_verified", .native_owned_ssh = true, .shell = false, .pty = false });
            }
            if (self.journal_backend.denied_writes != 0) self.fail("ManagementWriteInvariantFailed");
            if (isReadOnly(self.input) and (state.input.controlled or state.input.last_input_sequence != 0 or state.input.queued != 0)) self.fail("ReadOnlyInvariantFailed");
            if (state.failure) |failure| if (!self.close_requested) self.fail(@errorName(failure));
            if (runtime_value.last_sequence > 0 and self.first_frame_ms == null) {
                self.first_frame_ms = runtime_api.monotonicMs();
                emit(.{ .phase = "first_frame", .width = self.last_width, .height = self.last_height, .frames = self.last_frames, .video = self.videoSummary(), .budget_bytes = self.budget.usedBytes(), .discovery = self.captureDiscoverySummary(), .typed_management = try self.captureTypedManagementSummary(), .presentation = try self.capturePresentationSummary(), .progress = self.progress_headline });
            }
            if (state.worker_exited) {
                self.pressed_keys = runtime_value.controller.remote_input.pressed_count;
                self.pressed_buttons = runtime_value.controller.remote_input.pressed_buttons;
            }
            if (self.first_frame_ms) |first| {
                const elapsed = runtime_api.monotonicMs() - first;
                if (isReadOnly(self.input)) try self.observeMenus(elapsed) else if (self.input.acceptance_mode == .native_interactive) try self.observeInteractive() else try self.observeControl(elapsed);
                const period = @as(u64, self.input.observe_seconds) * 1000;
                if (isReadOnly(self.input) and self.input.can_autostop and elapsed >= period and (self.log_shot or elapsed >= period + 1000)) self.close_requested = true;
            }
        }
        const now = runtime_api.monotonicMs();
        // Leave ten seconds of the total deadline for best-effort logout and
        // native resource release; never destroy live facade backing stores.
        const interaction_deadline_ms: u64 = if (self.input.acceptance_mode == .native_interactive) @as(u64, self.input.interactive_seconds) * 1000 else 50_000;
        if (self.begin_ms != 0 and now - self.begin_ms >= interaction_deadline_ms and !self.close_requested) self.fail("ObservationTimeout");
        if (self.close_requested) try self.advanceClose();
        if (!self.finished and self.begin_ms != 0 and now - self.begin_ms >= interaction_deadline_ms + 10_000) {
            self.failed = true;
            self.failure_code = "CleanupDeadlineUnknown";
            self.web_logout = .unknown;
            self.kvm_logout = .unknown;
            self.releasePresentation() catch {};
            emit(.{ .phase = "complete", .success = false, .cleanup = "unknown", .web_logout = @tagName(self.web_logout), .kvm_logout = @tagName(self.kvm_logout), .width = self.last_width, .height = self.last_height, .frames = self.last_frames, .budget_bytes = self.budget.usedBytes(), .pressed_keys = self.pressed_keys, .pressed_buttons = self.pressed_buttons, .logout_diagnostics = self.logout_summary, .control = self.controlSummary(), .video = self.videoSummary(), .failure_code = self.failure_code, .progress_screenshot = self.progress_shot, .log_screenshot = self.log_shot, .progress = self.progress_headline, .progress_events = self.progress_events[0..self.progress_event_count] });
            self.finished = true;
            _ = self.app.commitClose();
        }
        self.app.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }
    fn observeNativeInput(self: *Runner, view: *views.View, snapshot: remote_input.Snapshot) void {
        if (self.native_last_window_active) |was_active| {
            if (was_active and !self.app.cx.window_active) self.native_view.focus_loss_observed = true;
        }
        self.native_last_window_active = self.app.cx.window_active;
        if (!self.app.cx.window_active and !view.captured and !snapshot.focused and snapshot.queued == 0) self.native_view.focus_loss_released = self.native_view.focus_loss_observed;
        if (view.captured and !self.native_capture_was_active) {
            self.native_view.captured_observed = true;
            if (self.ai_grant) |grant| {
                self.native_view.human_takeover_observed = true;
                self.native_view.human_takeover_revoked_ai_proof = !grant.proof.valid();
            }
            emit(.{ .phase = "native_view_captured", .owner = self.accepted.?.handle, .view_input_sequence = view.input_sequence, .typed_focused = snapshot.focused, .ai_proof_valid = if (self.ai_grant) |grant| grant.proof.valid() else false });
        }
        self.native_capture_was_active = view.captured;
        var remaining: usize = 0;
        for (self.native_pending[0..self.native_pending_count]) |pending| {
            const same_epoch = snapshot.input_epoch == pending.epoch and snapshot.transport_generation == pending.transport;
            if (same_epoch and snapshot.last_sent_transport_generation == pending.transport and snapshot.last_sent_input_sequence >= pending.sequence) {
                self.native_view.wire_sent_events += 1;
                self.native_view.last_wire_sent_sequence = pending.sequence;
                switch (pending.kind) {
                    .shift_down => self.native_view.shift_down_wire_sent = true,
                    .shift_up => self.native_view.shift_up_wire_sent = true,
                    .pointer_move => self.native_view.pointer_move_wire_sent = true,
                    .left_button_down => {
                        self.native_view.left_button_down_wire_sent = true;
                        self.native_left_down_sent = .{ .sequence = pending.sequence, .transport = pending.transport, .epoch = pending.epoch, .owner_generation = self.accepted.?.handle.generation };
                    },
                    .left_button_up => {
                        self.native_view.left_button_up_wire_sent = true;
                        if (self.native_left_down_sent) |start| if (pending.click_down_sequence == start.sequence and start.transport == pending.transport and start.epoch == pending.epoch and start.owner_generation == self.accepted.?.handle.generation and pending.buttons == 0) {
                            self.native_view.left_click_wire_complete = true;
                        };
                        self.native_left_down_sent = null;
                    },
                    .other => {},
                }
                self.native_refresh_needed = true;
                emit(.{ .phase = "native_view_input", .owner = self.accepted.?.handle, .state = "sent", .kind = @tagName(pending.kind), .event_kind = pending.event_kind, .keysym = pending.keysym, .down = pending.down, .keysym_redacted = pending.keysym_redacted, .button = pending.button, .buttons = pending.buttons, .click_down_sequence = pending.click_down_sequence, .input_sequence = pending.sequence, .last_sent_input_sequence = snapshot.last_sent_input_sequence, .transport_generation = pending.transport, .queued_observed_monotonic_ms = pending.queued_observed_monotonic_ms, .queued_to_sent_confirmation_ms = runtime_api.monotonicMs() -| pending.queued_observed_monotonic_ms, .exact_wire_send_time_available = false, .wire_sent = true, .remote_application_effect_verified = false });
            } else if (!same_epoch) {
                self.native_view.invalidated_before_send_confirmation += 1;
                emit(.{ .phase = "native_view_input", .owner = self.accepted.?.handle, .state = "confirmation_unavailable_after_barrier", .kind = @tagName(pending.kind), .event_kind = pending.event_kind, .keysym = pending.keysym, .down = pending.down, .keysym_redacted = pending.keysym_redacted, .button = pending.button, .buttons = pending.buttons, .input_sequence = pending.sequence, .wire_sent = false, .remote_effect_unknown = true, .input_replayed = false });
            } else {
                self.native_pending[remaining] = pending;
                remaining += 1;
            }
        }
        self.native_pending_count = remaining;
    }
    fn stopInteractiveAuthority(self: *Runner) void {
        self.action_stopped.store(true, .release);
        if (self.ai_grant) |grant| {
            grant.release();
            self.ai_grant = null;
        }
        if (self.content_context) |context| context.takeHumanControl();
    }
    fn validateInteractiveCommand(self: *Runner, command: InteractiveCommand) !void {
        if (self.input.acceptance_mode != .native_interactive or self.close_requested or self.finished) return error.InteractiveModeRequired;
        const is_pointer = command.command == .pointer;
        const is_input = is_pointer or command.command == .shift or command.command == .text_probe or command.command == .clear_line or command.command == .old_proof_probe;
        if (is_input) {
            if (command.owner_generation != self.accepted.?.handle.generation or command.observation_id == null or command.observation_id != self.observation_id) return error.FreshObservedOwnerRequired;
            if (runtime_api.monotonicMs() >= self.observation_valid_until_ms) return error.ObservationExpired;
            if (self.control_stage != .interactive_ready or self.renderer == null) return error.InteractiveActionInProgress;
            const view: *views.View = @ptrCast(@alignCast(self.renderer.?.context));
            if (view.captured or !self.app.cx.window_active) return error.ReleaseNativeCaptureBeforeAi;
            const service = try self.inputService();
            const snapshot = try service.table.snapshot(service.binding.context, service.binding);
            if (snapshot.geometry_pending or !try self.frameGeometryReady()) return error.FrameGeometryPending;
            if (!snapshot.connected or !snapshot.controlled or snapshot.focused or snapshot.remote_unconfirmed) return error.AutomationAuthorityUnavailable;
        } else if (command.observation_id != null or command.owner_generation != null) return error.UnexpectedObservationParameter;
        if (is_pointer) {
            const action = command.pointer_action orelse return error.PointerActionRequired;
            const x = command.x orelse return error.PointerPointRequired;
            const y = command.y orelse return error.PointerPointRequired;
            if (x >= self.observation_width or y >= self.observation_height) return error.PointerOutsideObservation;
            if (action == .drag) {
                if (command.end_x == null or command.end_y == null or command.end_x.? >= self.observation_width or command.end_y.? >= self.observation_height) return error.PointerOutsideObservation;
            } else if (command.end_x != null or command.end_y != null) return error.UnexpectedPointerParameter;
            if (action == .wheel) {
                const dx = command.steps_x orelse 0;
                const dy = command.steps_y orelse 0;
                if (dx < -3 or dx > 3 or dy < -3 or dy > 3 or (dx == 0 and dy == 0)) return error.InvalidSafeWheel;
            } else if (command.steps_x != null or command.steps_y != null) return error.UnexpectedPointerParameter;
        } else if (command.pointer_action != null or command.x != null or command.y != null or command.end_x != null or command.end_y != null or command.steps_x != null or command.steps_y != null) return error.UnexpectedPointerParameter;
        if ((command.command == .text_probe or command.command == .clear_line) != command.observed_idle_prompt) return error.ExplicitIdlePromptObservationRequired;
        if (command.command == .reconnect and self.presentation_count >= self.presentations.len) return error.AcceptanceRetryLimit;
        if ((command.command == .observe or command.command == .finish) and self.control_stage != .interactive_ready) return error.InteractiveActionInProgress;
        if (command.command == .observe and !try self.frameGeometryReady()) return error.FrameGeometryPending;
        if ((command.command == .reconnect or command.command == .cancel_connection) and (!self.console_ready or self.tab_id == null)) return error.NativeViewNotReady;
    }
    fn interactiveArguments(self: *Runner, command: InteractiveCommand) ![]u8 {
        const sid = @backingInt(self.accepted.?.handle.session_id);
        const observed = command.observation_id orelse return error.MissingObservation;
        return switch (command.command) {
            .shift => std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"key\",\"keysym\":65505}}", .{ sid, observed }),
            .text_probe => std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"text\",\"text\":\"codex-kvm-check\",\"layout\":\"us_ascii\"}}", .{ sid, observed }),
            .clear_line => std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"chord\",\"keys\":[65507,117]}}", .{ sid, observed }),
            .pointer => switch (command.pointer_action.?) {
                .move => std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"move\",\"x\":{d},\"y\":{d}}}", .{ sid, observed, command.x.?, command.y.? }),
                .click, .double_click, .right_click => std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"click\",\"x\":{d},\"y\":{d},\"button\":\"{s}\",\"count\":{d}}}", .{ sid, observed, command.x.?, command.y.?, if (command.pointer_action.? == .right_click) @as([]const u8, "right") else "left", @as(u8, if (command.pointer_action.? == .double_click) 2 else 1) }),
                .drag => std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"drag\",\"points\":[{{\"x\":{d},\"y\":{d}}},{{\"x\":{d},\"y\":{d}}}],\"button\":\"left\"}}", .{ sid, observed, command.x.?, command.y.?, command.end_x.?, command.end_y.? }),
                .wheel => std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"wheel\",\"x\":{d},\"y\":{d},\"steps_x\":{d},\"steps_y\":{d}}}", .{ sid, observed, command.x.?, command.y.?, command.steps_x orelse 0, command.steps_y orelse 0 }),
            },
            else => error.InteractiveCommandHasNoInput,
        };
    }
    fn observeInteractive(self: *Runner) !void {
        if (self.close_requested or self.renderer == null) return;
        const runtime_value = self.runtime() orelse return error.MissingRuntime;
        const view: *views.View = @ptrCast(@alignCast(self.renderer.?.context));
        const state = runtime_value.controller.poll();
        const context = self.content_context orelse return error.MissingContentContext;
        context.setFocus(self.app.cx.window_active, view.captured);
        context.expireAutomation();
        self.observeNativeFocus();
        self.observeNativeInput(view, state.input);
        while (context.drainRevocation()) |revoked| emit(.{ .phase = "content_lease_revoked", .owner = revoked.lease.owner, .lease_kind = @tagName(revoked.lease.kind), .reason = @tagName(revoked.reason) });
        if (!self.safe_views_verified) {
            if (!view.power_execute_disabled.peek() or !view.boot_execute_disabled.peek()) return error.UnsafeManagementActions;
            self.safe_views_verified = true;
            try self.prepareToolGateway();
            if (self.readonly_tool_calls == 0) try self.runReadonlyTools();
            self.setControlStage(.interactive_observe);
            emit(.{ .phase = "native_interactive_ready", .owner = self.accepted.?.handle, .same_tab_id = @backingInt(self.tab_id.?), .deadline_seconds = self.input.interactive_seconds, .cleanup_reserve_seconds = 10, .production_view_consumer_preserved = true, .manual_input = "operator_native_view_only", .provider_upload = false, .management_write_granted = false, .automatic_input = false });
        }
        if (self.native_command) |command| {
            self.native_command = null;
            // Validate again at execution, including actual focus and owner.
            self.validateInteractiveCommand(command) catch |err| {
                emit(.{ .phase = "interactive_command_rejected", .command = @tagName(command.command), .code = @errorName(err), .input_dispatched = false });
                return;
            };
            switch (command.command) {
                .finish => {
                    self.stopInteractiveAuthority();
                    const manual_pointer_verified = self.native_view.pointer_move_wire_sent or self.native_view.left_click_wire_complete;
                    self.control_complete = self.native_view.captured_observed and self.native_view.shift_down_wire_sent and self.native_view.shift_up_wire_sent and manual_pointer_verified and view.buttons == 0;
                    emit(.{ .phase = "native_manual_verdict", .shift_down_wire_sent = self.native_view.shift_down_wire_sent, .shift_up_wire_sent = self.native_view.shift_up_wire_sent, .actual_move_wire_sent = self.native_view.pointer_move_wire_sent, .actual_left_down_up_wire_complete = self.native_view.left_click_wire_complete, .local_buttons_released = view.buttons == 0, .completed = self.control_complete, .input_injected_by_runner = false });
                    self.setControlStage(.complete);
                    self.close_requested = true;
                    return;
                },
                .stop_ai => {
                    self.interactive_stop_requests += 1;
                    if (self.ai_grant) |grant| self.stopped_previous_proof = grant.proof;
                    self.stopInteractiveAuthority();
                    self.old_proof_invalid_after_stop = if (self.stopped_previous_proof) |proof| !proof.valid() else false;
                    self.old_proof_rejected_after_stop = false;
                    self.observation_id = null;
                    if (self.control_stage != .interactive_action_wait) self.setControlStage(.interactive_observe);
                    emit(.{ .phase = "interactive_ai_stopped", .input_replayed = false, .active_operation_id = self.ai_operation, .old_proof_present = self.stopped_previous_proof != null, .old_proof_invalid = self.old_proof_invalid_after_stop });
                },
                .reconnect => {
                    self.retry_previous_proof = if (self.ai_grant) |grant| grant.proof else self.retry_previous_proof;
                    self.stopInteractiveAuthority();
                    self.reconnect_requested = true;
                    const service = try self.consoleService();
                    try service.table.retry(service.binding.context, service.binding);
                    emit(.{ .phase = "interactive_reconnect_requested", .owner = self.accepted.?.handle, .same_tab_id = @backingInt(self.tab_id.?), .force = false });
                    return;
                },
                .cancel_connection => {
                    self.stopInteractiveAuthority();
                    const service = try self.consoleService();
                    const cancel = service.table.cancel orelse return error.CancelUnavailable;
                    try cancel(service.binding.context, service.binding);
                    self.cancelled_connection = true;
                    emit(.{ .phase = "interactive_connection_cancel_requested", .owner = self.accepted.?.handle, .input_replayed = false });
                    return;
                },
                .observe => {
                    if (self.control_stage != .interactive_ready) return error.InteractiveActionInProgress;
                    self.setControlStage(.interactive_observe);
                    if (self.native_refresh_needed) {
                        self.native_refresh_sequence = runtime_value.last_sequence;
                        try runtime_value.controller.requestFullRefresh();
                    }
                },
                .old_proof_probe => {
                    const after_retry = self.reconnects != 0;
                    const proof = (if (after_retry) self.retry_previous_proof else self.stopped_previous_proof) orelse return error.NoRetiredProofToVerify;
                    if (proof.valid() or (after_retry and proof.lease.owner.eql(self.accepted.?.handle))) return error.RetiredProofRequired;
                    const remote = &runtime_value.controller.remote_input;
                    const before = try remote.snapshot(remote.binding());
                    if (before.geometry_pending or before.geometry_generation == 0 or before.geometry_generation != runtime_value.last_generation) return error.FrameGeometryPending;
                    if (before.automation_queued != 0 or before.queued != 0) return error.OperationPending;
                    const operation_id = self.next_tool_operation;
                    self.next_tool_operation += 1;
                    const authority: remote_input.automation.Authority = .{ .owner = self.accepted.?.handle, .binding_generation = self.accepted.?.handle.generation, .transport_generation = before.transport_generation, .control_generation = before.control_generation, .input_epoch = before.input_epoch, .geometry_generation = before.geometry_generation, .expires_at_ms = runtime_api.monotonicMs() + 1000, .proof = proof };
                    _ = remote.submitAutomation(remote.binding(), authority, .{ .operation_id = operation_id, .action = .{ .pointer_move = .{ .x = 0, .y = 0 } } }) catch |err| {
                        const after = try remote.snapshot(remote.binding());
                        const rejected = err == error.StaleAutomationAuthority and before.automation_queued == after.automation_queued and before.queued == after.queued and before.last_input_sequence == after.last_input_sequence and before.last_sent_input_sequence == after.last_sent_input_sequence and before.last_sent_transport_generation == after.last_sent_transport_generation;
                        if (after_retry) self.old_proof_rejected_by_new_owner = rejected else self.old_proof_rejected_after_stop = rejected;
                        emit(.{ .phase = "retired_proof_probe", .boundary = if (after_retry) @as([]const u8, "reconnect") else "stop", .owner = self.accepted.?.handle, .rejected = rejected, .code = @errorName(err), .current_binding_generation = authority.binding_generation, .current_transport_generation = authority.transport_generation, .current_control_generation = authority.control_generation, .current_input_epoch = authority.input_epoch, .current_geometry_generation = authority.geometry_generation, .only_retired_proof_substituted = true, .input_queue_and_sent_watermarks_unchanged = rejected, .input_dispatched = false, .wire_sent = false });
                        if (!rejected) return error.RetiredProofRejectionUnverified;
                        return;
                    };
                    self.stopInteractiveAuthority();
                    return error.RetiredProofUnexpectedlyAccepted;
                },
                .pointer, .shift, .text_probe, .clear_line => {
                    if (self.ai_grant) |grant| if (!grant.proof.valid()) {
                        grant.release();
                        self.ai_grant = null;
                    };
                    self.action_stopped.store(false, .release);
                    try context.setAuthorization(true, context.authorization_revision);
                    self.active_command = command;
                    const args = try self.interactiveArguments(command);
                    defer a.free(args);
                    self.ai_operation = self.callTool(if (command.command == .pointer) "bmc_ikvm.pointer" else "bmc_ikvm.keyboard", args, null) catch |err| switch (err) {
                        error.ObservationExpired, error.ObservationInvalidated, error.FreshObservationRequired, error.StaleAutomationAuthority, error.HumanInputActive, error.RemoteInputUnavailable, error.FrameUnavailable, error.FrameGeometryPending => {
                            self.active_command = null;
                            self.observation_id = null;
                            self.stopInteractiveAuthority();
                            emit(.{ .phase = "interactive_action_rejected", .code = @errorName(err), .input_dispatched = false, .input_replayed = false });
                            self.setControlStage(.interactive_observe);
                            return;
                        },
                        else => return err,
                    };
                    self.observation_id = null;
                    self.setControlStage(.interactive_action_wait);
                },
            }
        }
        if (self.reconnect_requested or self.cancelled_connection) return;
        switch (self.control_stage) {
            .interactive_action_wait => {
                const operation_id = self.ai_operation orelse return error.MissingAiInputOperation;
                const binding = runtime_value.aiBinding();
                const table = try binding.borrow(ai_control.Interface, ai_control.key, self.accepted.?.handle);
                const receipt = try table.operation_status(binding.context, binding, operation_id);
                if (receipt.status == .accepted) {
                    if (runtime_api.monotonicMs() - self.control_stage_ms > 4_000) return error.InteractiveInputSendTimeout;
                    return;
                }
                if (receipt.status == .outcome_unknown) return error.InteractiveInputOutcomeUnknown;
                if (receipt.status == .sent) {
                    if (!try self.aiInputSent()) return;
                    self.interactive_actions_sent += 1;
                    if (self.active_command.?.command == .pointer) {
                        self.ai_pointer_sent = true;
                        self.ai_pointer_receipt = self.last_wire_receipt;
                    } else {
                        self.ai_keyboard_sent = true;
                        self.ai_keyboard_receipt = self.last_wire_receipt;
                    }
                } else {
                    self.interactive_actions_cancelled_unsent += 1;
                    emit(.{ .phase = "interactive_input_cancelled_unsent", .operation_id = operation_id, .sent_events = receipt.sent_events, .total_events = receipt.total_events, .input_replayed = false });
                }
                self.active_command = null;
                self.setControlStage(.interactive_observe);
            },
            .interactive_observe => {
                if (self.native_refresh_sequence) |sequence| {
                    if (runtime_value.last_sequence <= sequence) {
                        if (runtime_api.monotonicMs() - self.control_stage_ms > 4_000) return error.NativePostActionFrameTimeout;
                        return;
                    }
                    self.native_refresh_sequence = null;
                    self.native_refresh_needed = false;
                }
                if (!try self.runScreenshot("/tmp/zerowork-bmc-interactive-observation.png")) return;
                _ = self.app.capturePresentedToPng("/tmp/zerowork-bmc-interactive-window.png");
                emit(.{ .phase = "interactive_observation_ready", .owner = self.accepted.?.handle, .observation_id = self.observation_id, .image_path = "/tmp/zerowork-bmc-interactive-observation.png", .native_window_path = "/tmp/zerowork-bmc-interactive-window.png", .remote_application_effect_verified = false });
                self.setControlStage(.interactive_ready);
            },
            else => {},
        }
    }
    fn observeControl(self: *Runner, _: u64) !void {
        if (self.close_requested or self.renderer == null or self.sink == null or self.sink.?.texture == null) return;
        const now = runtime_api.monotonicMs();
        const runtime_value = self.runtime() orelse return error.MissingRuntime;
        const state = runtime_value.controller.poll();
        const context = if (self.content_context) |value| value else return error.MissingContentContext;
        // Native focus is a real host fact. Losing it revokes pending authority;
        // no acceptance mode may pretend a background window has content focus.
        context.setFocus(self.app.cx.window_active, self.human_lease != null);
        context.expireAutomation();
        while (context.drainRevocation()) |revoked| {
            emit(.{ .phase = "content_lease_revoked", .owner = revoked.lease.owner, .lease_kind = @tagName(revoked.lease.kind), .reason = @tagName(revoked.reason) });
        }
        if (!self.safe_views_verified) {
            const view: *views.View = @ptrCast(@alignCast(self.renderer.?.context));
            if (!view.power_execute_disabled.peek() or !view.boot_execute_disabled.peek()) return error.UnsafeManagementActions;
            self.safe_views_verified = true;
            try self.prepareToolGateway();
            self.control_stage_ms = now;
            emit(.{ .phase = "control_plan", .acceptance_mode = @tagName(self.input.acceptance_mode), .owner = self.accepted.?.handle, .management_write_granted = false, .provider_upload = false, .force_takeover = false, .generic_gateway = true, .manual_authority = "synthetic_runner_content_route", .native_view_input_verified = false });
        }
        if (state.control_request != null) return error.ExternalControlRequestPending;
        if (state.input.remote_unconfirmed) return error.RemoteInputUnconfirmed;
        if (!self.app.cx.window_active and self.control_stage != .initial_observation) {
            if (!self.control_focus_wait_reported) emit(.{ .phase = "waiting_for_native_window_focus", .owner = self.accepted.?.handle, .input_sent = false });
            self.control_focus_wait_reported = true;
            return;
        }
        self.control_focus_wait_reported = false;
        switch (self.control_stage) {
            .initial_observation => {
                if (self.readonly_tool_calls == 0) try self.runReadonlyTools();
                if (!try self.runScreenshot("/tmp/zerowork-bmc-control-observation-before.png")) return;
                self.control_shots[0] = self.app.capturePresentedToPng("/tmp/zerowork-bmc-control-before.png");
                self.setControlStage(.request_control);
            },
            .request_control => {
                if (!state.rfb_ready or !state.input.connected) return;
                if (!state.input.controlled) {
                    if (state.control == .rejected) return error.NormalControlRequestRejected;
                    if (!self.control_requested) {
                        const service = try self.consoleService();
                        try service.table.request_control(service.binding.context, service.binding);
                        self.control_requested = true;
                        emit(.{ .phase = "normal_control_requested", .owner = self.accepted.?.handle, .force = false });
                    }
                    if (now - self.control_stage_ms > 8_000) return error.NormalControlNotGranted;
                    return;
                }
                try context.setAuthorization(true, context.authorization_revision);
                if (self.input.acceptance_mode == .ai_pointer_click) {
                    context.setFocus(self.app.cx.window_active, false);
                    self.setControlStage(.ai_observation);
                } else {
                    context.setFocus(self.app.cx.window_active, true);
                    self.human_lease = try context.acquire(.human_focus, context.authorization_revision);
                    const service = try self.consoleService();
                    try service.table.set_focus(service.binding.context, service.binding, true);
                    emit(.{ .phase = "human_lease_acquired", .owner = self.accepted.?.handle, .lease_kind = "human_focus", .automation_lease_present = context.automation != null });
                    self.setControlStage(.human_shift);
                }
            },
            .human_shift => {
                const lease = self.human_lease orelse return error.MissingHumanLease;
                const sequence = context.last_human_event;
                if (!try context.route(lease, sequence + 1, .{ .key = .{ .code = 0xffe1, .down = true } }, false)) return error.HumanShiftNotRouted;
                if (!try context.route(lease, sequence + 2, .{ .key = .{ .code = 0xffe1, .down = false } }, false)) return error.HumanShiftNotRouted;
                self.setControlStage(.human_shift_wait);
            },
            .human_shift_wait => {
                if (!try self.humanInputSent()) {
                    if (now - self.control_stage_ms > 4_000) return error.HumanShiftSendUnknown;
                    return;
                }
                // The first action is only one Shift down/up. Observe before
                // any pointer movement, click, or second keyboard operation.
                self.setControlStage(.human_observe);
            },
            .human_observe => {
                if (now - self.control_stage_ms < 1_000) return;
                if (!try self.runScreenshot("/tmp/zerowork-bmc-control-observation-wake.png")) return;
                const lease = self.human_lease orelse return error.MissingHumanLease;
                if (!try context.route(lease, context.last_human_event + 1, .{ .pointer = .{ .x = @floatFromInt(@min(self.last_width - 1, 32)), .y = @floatFromInt(@min(self.last_height - 1, 32)), .buttons = 0 } }, false)) return error.HumanPointerNotRouted;
                self.setControlStage(.human_pointer_wait);
            },
            .human_pointer_wait => {
                if (!try self.humanInputSent()) {
                    if (now - self.control_stage_ms > 4_000) return error.HumanPointerSendUnknown;
                    return;
                }
                self.setControlStage(.human_final_observe);
            },
            .human_final_observe => {
                if (now - self.control_stage_ms < 750) return;
                self.control_shots[1] = self.app.capturePresentedToPng("/tmp/zerowork-bmc-control-human.png");
                try self.captureAndEmitPresentation("human_observed");
                if (self.human_lease) |lease| context.release(lease);
                self.human_lease = null;
                context.setFocus(self.app.cx.window_active, false);
                const service = try self.consoleService();
                try service.table.set_focus(service.binding.context, service.binding, false);
                self.setControlStage(.ai_observation);
            },
            .ai_observation => {
                // Input release advances input_epoch. Capture a new immutable
                // remote observation after that boundary, never reuse the old.
                if (!try self.runScreenshot("/tmp/zerowork-bmc-control-observation-ai.png")) return;
                if (self.input.acceptance_mode == .ai_pointer_click) self.setControlStage(.ai_pointer) else self.setControlStage(.ai_shift);
            },
            .ai_shift => {
                const args = try std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"key\",\"keysym\":65505}}", .{ @backingInt(self.accepted.?.handle.session_id), self.observation_id orelse return error.MissingObservation });
                defer a.free(args);
                self.ai_operation = try self.callTool("bmc_ikvm.keyboard", args, null);
                self.setControlStage(.ai_shift_wait);
            },
            .ai_shift_wait => {
                if (!try self.aiInputSent()) {
                    if (now - self.control_stage_ms > 4_000) return error.AiShiftSendUnknown;
                    return;
                }
                self.ai_keyboard_sent = true;
                self.ai_keyboard_receipt = self.last_wire_receipt;
                self.setControlStage(.ai_pointer);
            },
            .ai_pointer => {
                // Refresh the observation if a full frame changed while the
                // keyboard operation completed. This is another real gateway
                // observation with its own exact approval ticket.
                if (!try self.runScreenshot("/tmp/zerowork-bmc-control-observation-pointer.png")) return;
                const click = self.input.acceptance_mode == .ai_pointer_click;
                const x = if (click) self.input.click_target.?.x else @min(self.observation_width - 1, 48);
                const y = if (click) self.input.click_target.?.y else @min(self.observation_height - 1, 48);
                if (x >= self.observation_width or y >= self.observation_height) return error.ClickOutsideObservation;
                const args = if (click)
                    try std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"click\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"count\":1}}", .{ @backingInt(self.accepted.?.handle.session_id), self.observation_id.?, x, y })
                else
                    try std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"observation_id\":{d},\"action\":\"move\",\"x\":{d},\"y\":{d}}}", .{ @backingInt(self.accepted.?.handle.session_id), self.observation_id.?, x, y });
                defer a.free(args);
                self.ai_operation = try self.callTool("bmc_ikvm.pointer", args, null);
                self.setControlStage(.ai_pointer_wait);
            },
            .ai_pointer_wait => {
                if (!try self.aiInputSent()) {
                    if (now - self.control_stage_ms > 4_000) return error.AiPointerSendUnknown;
                    return;
                }
                self.ai_pointer_sent = true;
                self.ai_pointer_receipt = self.last_wire_receipt;
                self.setControlStage(.final_observe);
            },
            .final_observe => {
                if (now - self.control_stage_ms < @as(u64, self.input.observe_seconds) * 1000) return;
                self.control_shots[2] = self.app.capturePresentedToPng("/tmp/zerowork-bmc-control-ai.png");
                if (!try self.runScreenshot("/tmp/zerowork-bmc-control-observation-after.png")) return;
                try self.captureAndEmitPresentation("ai_observed");
                self.releaseControlAuthority();
                self.control_complete = self.readonly_tool_calls == 3 and self.ai_pointer_sent and (self.input.acceptance_mode == .ai_pointer_click or (self.ai_keyboard_sent and self.human_sent_sequence >= 3)) and self.control_shots[0] and self.control_shots[2] and (self.input.acceptance_mode == .ai_pointer_click or self.control_shots[1]);
                self.setControlStage(.complete);
                self.close_requested = true;
            },
            .interactive_ready, .interactive_observe, .interactive_action_wait => return error.UnexpectedInteractiveStage,
            .complete => {},
        }
    }
    fn controlSummary(self: *Runner) ?ControlSummary {
        if (isReadOnly(self.input)) return null;
        const context = if (self.content_context) |value| value else null;
        const diagnostic = self.logout_summary;
        return .{
            .acceptance_mode = self.input.acceptance_mode,
            .completed = self.control_complete,
            .stage = self.control_stage,
            .readonly_tool_calls = self.readonly_tool_calls,
            .exact_approved_tool_calls = self.approved_tool_calls,
            .human_sent_sequence = self.human_sent_sequence,
            .ai_keyboard_sent = self.ai_keyboard_sent,
            .ai_pointer_sent = self.ai_pointer_sent,
            .ai_keyboard_receipt = self.ai_keyboard_receipt,
            .ai_pointer_receipt = self.ai_pointer_receipt,
            .last_wire_receipt = self.last_wire_receipt,
            .active_human_leases = if (context) |value| @intFromBool(value.human != null) else 0,
            .active_automation_leases = if (context) |value| @intFromBool(value.automation != null) else 0,
            // Controller cleanup cannot report released until every CPU frame
            // borrower releases; the budget barrier proves their storage died.
            .frame_leases_remaining = if (self.released) 0 else null,
            .input_queued = self.last_input_queued,
            .automation_pending = self.last_automation_pending,
            .remote_input_unconfirmed = self.last_input_remote_unknown,
            .released_keys_and_buttons_zero = self.released and self.pressed_keys == 0 and self.pressed_buttons == 0,
            .own_web_delete_http_200 = if (diagnostic) |value| self.web_logout == .confirmed and value.web.http_status == 200 else false,
            .own_kvm_delete_http_200 = if (diagnostic) |value| self.kvm_logout == .confirmed and value.kvm.http_status == 200 else false,
            .native_view = self.native_view,
            .interactive_actions_sent = self.interactive_actions_sent,
            .interactive_actions_cancelled_unsent = self.interactive_actions_cancelled_unsent,
            .interactive_stop_requests = self.interactive_stop_requests,
            .actions_with_post_send_observation = self.actions_with_post_send_observation,
            .last_action_timing = self.last_completed_action_timing,
            .reconnects = self.reconnects,
            .same_tab_preserved = self.same_tab_preserved,
            .old_proof_invalid_after_retry = self.old_proof_invalid_after_retry,
            .old_proof_rejected_by_new_owner = self.old_proof_rejected_by_new_owner,
            .old_proof_invalid_after_stop = self.old_proof_invalid_after_stop,
            .old_proof_rejected_after_stop = self.old_proof_rejected_after_stop,
            .retry_own_logout_confirmed = self.retry_own_logout_confirmed,
        };
    }
    fn setControlStage(self: *Runner, next: ControlStage) void {
        self.control_stage = next;
        self.control_stage_ms = runtime_api.monotonicMs();
        self.screenshot_wait_started_ms = null;
        self.next_screenshot_retry_ms = 0;
        emit(.{ .phase = "control_stage", .stage = @tagName(next), .owner = self.accepted.?.handle });
    }
    fn captureAndEmitPresentation(self: *Runner, phase: []const u8) !void {
        emit(.{ .phase = phase, .owner = self.accepted.?.handle, .presentation = try self.capturePresentationSummary(), .input_sequence = self.last_input_sequence, .human_sent_sequence = self.human_sent_sequence });
    }
    const ConsoleService = struct { binding: typed.Binding, table: *const console.Interface };
    fn consoleService(self: *Runner) !ConsoleService {
        const owner = self.accepted.?.handle;
        const access = try self.host.?.serviceAccess(owner);
        const binding = (try access.lookup(owner, console.definition)) orelse return error.MissingConsoleService;
        return .{ .binding = binding, .table = try binding.borrow(console.Interface, console.key, owner) };
    }
    const InputService = struct { binding: typed.Binding, table: *const remote_input.Interface };
    fn inputService(self: *Runner) !InputService {
        const owner = self.accepted.?.handle;
        const access = try self.host.?.serviceAccess(owner);
        const binding = (try access.lookup(owner, remote_input.definition)) orelse return error.MissingInputService;
        return .{ .binding = binding, .table = try binding.borrow(remote_input.Interface, remote_input.key, owner) };
    }
    fn humanConsume(raw: *anyopaque, value: content.Input) !void {
        const self: *Runner = @ptrCast(@alignCast(raw));
        if (isReadOnly(self.input)) return error.ReadOnlyAcceptanceInput;
        const service = try self.inputService();
        if (value == .release_all) {
            const result = service.table.release_all(service.binding.context, service.binding, .released);
            emit(.{ .phase = "input_release_requested", .owner = self.accepted.?.handle, .result = @tagName(result) });
            return;
        }
        if (self.human_lease == null or self.input.acceptance_mode != .safe_interaction) return error.HumanAcceptanceAuthorityRequired;
        const snapshot = try service.table.snapshot(service.binding.context, service.binding);
        const event: remote_input.Event = switch (value) {
            .key => |key_value| blk: {
                if (key_value.code != 0xffe1 or key_value.modifiers != 0 or self.control_stage != .human_shift) return error.UnsafeAcceptanceKey;
                break :blk .{ .key = .{ .keysym = key_value.code, .down = key_value.down } };
            },
            .pointer => |point| blk: {
                if (point.buttons != 0 or point.wheel_x != 0 or point.wheel_y != 0 or self.control_stage != .human_observe or !std.math.isFinite(point.x) or !std.math.isFinite(point.y) or point.x < 0 or point.y < 0 or point.x >= @as(f32, @floatFromInt(self.last_width)) or point.y >= @as(f32, @floatFromInt(self.last_height))) return error.UnsafeAcceptancePointer;
                break :blk .{ .pointer = .{ .x = @intFromFloat(point.x), .y = @intFromFloat(point.y), .buttons = 0 } };
            },
            .text, .release_all => return error.UnsafeAcceptanceInput,
        };
        if (snapshot.geometry_pending) return error.FrameGeometryPending;
        if (!snapshot.connected or !snapshot.controlled or !snapshot.focused or snapshot.remote_unconfirmed) return error.HumanInputUnavailable;
        const sequence = snapshot.last_input_sequence + 1;
        const submitted = service.table.submit(service.binding.context, service.binding, .{ .session_handle = self.accepted.?.handle, .binding_generation = service.binding.generation, .input_sequence = sequence, .input_epoch = snapshot.input_epoch, .control_generation = snapshot.control_generation, .geometry_generation = snapshot.geometry_generation, .event = event });
        if (submitted != .accepted) return error.HumanInputNotAccepted;
        self.human_last_sequence = sequence;
        self.human_transport_generation = snapshot.transport_generation;
        emit(.{ .phase = "human_input_receipt", .owner = self.accepted.?.handle, .effect = "remote_input", .state = "queued", .input_sequence = sequence, .wire_sent = false, .remote_effect_unknown = false });
    }
    fn humanInputSent(self: *Runner) !bool {
        const service = try self.inputService();
        const snapshot = try service.table.snapshot(service.binding.context, service.binding);
        if (snapshot.remote_unconfirmed or snapshot.transport_generation != self.human_transport_generation) return error.HumanRemoteEffectUnknown;
        if (snapshot.last_sent_input_sequence < self.human_last_sequence or snapshot.last_sent_transport_generation != self.human_transport_generation) return false;
        self.human_sent_sequence = snapshot.last_sent_input_sequence;
        emit(.{ .phase = "human_input_receipt", .owner = self.accepted.?.handle, .effect = "remote_input", .state = "sent", .input_sequence = self.human_last_sequence, .wire_sent = true, .remote_effect_unknown = false, .remote_application_effect_verified = false });
        return true;
    }
    fn releaseControlAuthority(self: *Runner) void {
        if (self.control_stopped.swap(true, .acq_rel)) return;
        if (self.content_context) |context| {
            if (self.human_lease) |lease| context.release(lease);
            self.human_lease = null;
            if (self.ai_grant) |grant| grant.release();
            self.ai_grant = null;
            context.setAuthorization(false, context.authorization_revision + 1) catch {};
        }
    }
    fn prepareToolGateway(self: *Runner) !void {
        if (self.tool_table != null) return;
        const owner = self.accepted.?.handle;
        const manifest = self.host.?.manifestFor(owner) orelse return error.MissingManifest;
        const bindings = self.host.?.typedBindingsFor(owner) orelse return error.MissingTypedBindings;
        var captured: tool_scope_api.Scope = .{ .owner = .{ .session = @backingInt(owner.session_id) }, .members = .{} };
        captured.members.ids[0] = @backingInt(owner.session_id);
        captured.members.len = 1;
        self.tool_scope = captured;
        self.tool_members[0] = .{ .owner = owner, .plugin_id = manifest.id, .context = manifest.session_factory.?.context, .bindings = manifest.tools, .services = bindings, .capability_revision = self.host.?.capabilityRevisionFor(owner) orelse return error.MissingCapabilityRevision, .policy_revision = 1 };
        self.tool_table = try tool_api.RequestTable.init(a, captured, manifest.tool_definitions, &self.tool_members);
    }
    fn liveToolScope(raw: *anyopaque) !tool_scope_api.Scope {
        const self: *Runner = @ptrCast(@alignCast(raw));
        if (self.close_requested or isReadOnly(self.input)) return error.ToolAcceptanceStopped;
        return self.tool_scope orelse return error.MissingToolScope;
    }
    fn liveToolMembers(raw: *anyopaque) ![]const tool_api.Member {
        const self: *Runner = @ptrCast(@alignCast(raw));
        const owner = self.accepted.?.handle;
        self.tool_members[0].services = self.host.?.typedBindingsFor(owner) orelse return error.MissingTypedBindings;
        self.tool_members[0].capability_revision = self.host.?.capabilityRevisionFor(owner) orelse return error.MissingCapabilityRevision;
        return &self.tool_members;
    }
    fn toolPolicy(raw: *anyopaque) tool_api.Policy {
        const self: *Runner = @ptrCast(@alignCast(raw));
        return .{ .full_control = false, .allow_read = true, .allow_input = !isReadOnly(self.input) and !self.control_stopped.load(.acquire), .allow_write = false };
    }
    fn toolNow(_: *anyopaque) i64 {
        return @intCast(runtime_api.monotonicMs());
    }
    fn approveTool(raw: *anyopaque, invocation: tool_api.DynamicInvocation, ticket: *tool_api.ApprovalTicket, _: ?*provider.CancelToken) !bool {
        const self: *Runner = @ptrCast(@alignCast(raw));
        if (isReadOnly(self.input) or self.input.operator_approval == null or self.control_stopped.load(.acquire) or self.close_requested) return false;
        if (self.expected_approval_operation != invocation.operation_id or !std.mem.eql(u8, &self.expected_approval_hash, &ticket.arguments_hash) or !std.mem.eql(u8, &invocation.parsed.arguments_hash, &ticket.arguments_hash) or !ticket.owner.eql(self.tool_scope.?.owner) or ticket.len != 1 or !ticket.targets[0].owner.eql(self.accepted.?.handle)) return error.UnexpectedApprovalSubject;
        const definition = invocation.parsed.entry.definition;
        const allowed = definition.effect == .observe_image and std.mem.eql(u8, definition.id, "bmc_ikvm.screenshot") or definition.effect == .remote_input and (std.mem.eql(u8, definition.id, "bmc_ikvm.keyboard") or std.mem.eql(u8, definition.id, "bmc_ikvm.pointer"));
        if (!allowed) return error.UnsafeAcceptanceApproval;
        if (definition.effect == .remote_input) {
            const arguments = invocation.parsed.json.value.object;
            const observed = arguments.get("observation_id") orelse return error.MissingObservation;
            if (observed != .integer or observed.integer <= 0 or self.observation_id != @as(u64, @intCast(observed.integer))) return error.UnexpectedApprovalSubject;
            const action = arguments.get("action") orelse return error.UnsafeAcceptanceApproval;
            if (action != .string) return error.UnsafeAcceptanceApproval;
            if (self.input.acceptance_mode == .native_interactive) {
                const command = self.active_command orelse return error.MissingInteractiveApproval;
                try self.validateInteractiveCommand(command);
                const expected = try self.interactiveArguments(command);
                defer a.free(expected);
                if (!std.mem.eql(u8, expected, invocation.arguments) or !std.mem.eql(u8, definition.id, if (command.command == .pointer) "bmc_ikvm.pointer" else "bmc_ikvm.keyboard")) return error.UnexpectedApprovalSubject;
            } else if (std.mem.eql(u8, definition.id, "bmc_ikvm.keyboard")) {
                const keysym = arguments.get("keysym") orelse return error.UnsafeAcceptanceKey;
                if (self.input.acceptance_mode != .safe_interaction or self.control_stage != .ai_shift or !std.mem.eql(u8, action.string, "key") or keysym != .integer or keysym.integer != 0xffe1) return error.UnsafeAcceptanceKey;
            } else {
                if (self.control_stage != .ai_pointer) return error.UnsafeAcceptancePointer;
                const is_click = self.input.acceptance_mode == .ai_pointer_click;
                if (!std.mem.eql(u8, action.string, if (is_click) "click" else "move")) return error.UnsafeAcceptancePointer;
                const expected_x = if (is_click) self.input.click_target.?.x else @min(self.observation_width - 1, 48);
                const expected_y = if (is_click) self.input.click_target.?.y else @min(self.observation_height - 1, 48);
                if (try jsonUnsigned(arguments, "x") != expected_x or try jsonUnsigned(arguments, "y") != expected_y) return error.UnsafeAcceptancePointer;
            }
        }
        self.approved_tool_calls += 1;
        emit(.{ .phase = "generic_approval", .owner = self.accepted.?.handle, .operation_id = invocation.operation_id, .effect = @tagName(definition.effect), .tool_id = definition.id, .exact_arguments = true, .one_shot = true, .explicit_operator_plan = @tagName(self.input.operator_approval.?), .observed_command = if (definition.effect == .remote_input and self.input.acceptance_mode == .native_interactive) self.active_command else null, .source_observation_id = if (definition.effect == .remote_input) self.observation_id else null, .source_frame_generation = self.observation_frame_generation, .source_frame_sequence = self.observation_frame_sequence, .approved_monotonic_ms = runtime_api.monotonicMs(), .provider_upload = false });
        return true;
    }
    fn invokeTool(raw: *anyopaque, target: tool_api.TargetBinding, request: tool_api.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !tool_api.ToolResult {
        const self: *Runner = @ptrCast(@alignCast(raw));
        var actual = request;
        if (request.effect == .resource_write) return error.ManagementWritesForbidden;
        if (request.effect == .remote_input) {
            const context = if (self.content_context) |value| value else return error.MissingContentContext;
            const view: *views.View = @ptrCast(@alignCast((self.renderer orelse return error.MissingRenderer).context));
            if (!self.app.cx.window_active or self.human_lease != null or view.captured or !context.authorized) return error.AutomationAuthorityUnavailable;
            if (self.ai_grant == null) {
                context.setFocus(self.app.cx.window_active, false);
                self.ai_grant = try context.acquireAutomation(context.authorization_revision, null, if (self.input.acceptance_mode == .native_interactive) &self.action_stopped else &self.control_stopped, runtime_api.monotonicMs() + 15_000);
            }
            if (self.input.acceptance_mode == .native_interactive and self.reconnects == 0) self.retry_previous_proof = self.ai_grant.?.proof;
            actual.automation_proof = self.ai_grant.?.proof;
        }
        // This is the generic gateway dispatch boundary, not an RFB wire ack.
        // Only the typed input receipt may claim that its events were sent.
        if (request.effect == .remote_input) try tool_api.markSent(&self.tool_operations, request.owner, request.operation_id, request.call_id, request.tool_id, request.arguments_hash);
        if (request.effect == .remote_input) self.action_timing = .{
            .owner = request.owner,
            .operation_id = request.operation_id,
            .source_observation_id = self.observation_id orelse return error.MissingObservation,
            .source_frame_generation = self.observation_frame_generation,
            .source_frame_sequence = self.observation_frame_sequence,
            .dispatch_started_monotonic_ms = runtime_api.monotonicMs(),
        };
        const result = target.binding.handler(target.context, actual, allocator) catch |err| {
            self.last_tool_error = err;
            return err;
        };
        if (request.effect != .remote_input) try tool_api.markSent(&self.tool_operations, request.owner, request.operation_id, request.call_id, request.tool_id, request.arguments_hash);
        return result;
    }
    fn callTool(self: *Runner, id: []const u8, arguments: []const u8, image_path: ?[]const u8) !u64 {
        const table = if (self.tool_table) |*value| value else return error.MissingToolTable;
        var encoded: [64]u8 = undefined;
        var parsed = try table.parse(a, try tool_api.encodeName(&encoded, id), arguments);
        defer parsed.deinit();
        const operation_id = self.next_tool_operation;
        self.next_tool_operation += 1;
        self.expected_approval_operation = operation_id;
        self.expected_approval_hash = parsed.arguments_hash;
        defer self.expected_approval_operation = null;
        const gateway: tool_api.Runtime = .{ .context = self, .live_scope = liveToolScope, .live_members = liveToolMembers, .current_policy = toolPolicy, .now_ms = toolNow, .approval = approveTool, .operations = &self.tool_operations, .invoke = invokeTool };
        self.last_tool_error = null;
        const output = try gateway.execute(.{ .table = table, .parsed = parsed, .turn_id = 1, .call_id = "native-live-acceptance", .arguments = arguments, .operation_id = operation_id }, a, null);
        defer {
            for (output) |*result| result.deinit(a);
            a.free(output);
        }
        if (output.len != 1) return error.UnexpectedToolTargetCount;
        const result = output[0];
        emit(.{ .phase = "generic_tool_result", .owner = result.receipt.owner, .operation_id = result.receipt.operation_id, .tool_id = id, .effect = @tagName(parsed.entry.definition.effect), .status = @tagName(result.status), .local_released = result.receipt.local_released, .remote_effect_unknown = result.receipt.remote_effect_unknown, .blocks = result.blocks.len, .wire_sent_verified_by_this_result = false });
        var images: usize = 0;
        for (result.blocks) |block| switch (block) {
            .structured => |bytes| try self.observeToolStructure(id, operation_id, bytes),
            .image_ref => |reference| {
                const image_value = reference.content() orelse return error.EmptyToolImage;
                if (image_path == null or image_value.mime != .png or image_value.width == 0 or image_value.height == 0) return error.UnexpectedToolImage;
                images += 1;
                try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = image_path.?, .data = image_value.bytes });
                emit(.{ .phase = "local_image_ref_verified", .owner = result.receipt.owner, .operation_id = operation_id, .width = image_value.width, .height = image_value.height, .png_bytes = image_value.bytes.len, .provider_uploaded = false });
            },
            .text => {},
        };
        if (result.status != .succeeded or result.receipt.remote_effect_unknown) {
            if (self.last_tool_error) |err| return err;
            return error.LiveToolRejected;
        }
        if (image_path != null and images != 1) return error.MissingToolImage;
        return operation_id;
    }
    fn jsonUnsigned(object: std.json.ObjectMap, key: []const u8) !u64 {
        const value = object.get(key) orelse return error.MissingToolResultField;
        if (value != .integer or value.integer < 0) return error.InvalidToolResultField;
        return @intCast(value.integer);
    }
    fn observeToolStructure(self: *Runner, id: []const u8, operation_id: u64, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidToolResultField;
        const object = parsed.value.object;
        if (object.get("error_code")) |code| {
            if (code != .string) return error.InvalidToolResultField;
            self.last_tool_error = if (std.mem.eql(u8, code.string, "PostActionFramePending")) error.PostActionFramePending else if (std.mem.eql(u8, code.string, "OperationPending")) error.OperationPending else if (std.mem.eql(u8, code.string, "ObservationExpired")) error.ObservationExpired else if (std.mem.eql(u8, code.string, "ObservationInvalidated")) error.ObservationInvalidated else if (std.mem.eql(u8, code.string, "FreshObservationRequired")) error.FreshObservationRequired else if (std.mem.eql(u8, code.string, "StaleAutomationAuthority")) error.StaleAutomationAuthority else if (std.mem.eql(u8, code.string, "HumanInputActive")) error.HumanInputActive else if (std.mem.eql(u8, code.string, "RemoteInputUnavailable")) error.RemoteInputUnavailable else if (std.mem.eql(u8, code.string, "FrameUnavailable")) error.FrameUnavailable else if (std.mem.eql(u8, code.string, "FrameGeometryPending")) error.FrameGeometryPending else error.LiveToolRejected;
            return;
        }
        if (std.mem.eql(u8, id, "bmc_ikvm.screenshot")) {
            self.observation_id = try jsonUnsigned(object, "observation_id");
            self.observation_valid_until_ms = try jsonUnsigned(object, "valid_until_monotonic_ms");
            self.observation_width = @intCast(try jsonUnsigned(object, "output_width"));
            self.observation_height = @intCast(try jsonUnsigned(object, "output_height"));
            if (self.observation_width == 0 or self.observation_height == 0) return error.InvalidObservationDimensions;
            self.observation_frame_generation = try jsonUnsigned(object, "frame_generation");
            self.observation_frame_sequence = try jsonUnsigned(object, "sequence");
            const received_ns = try jsonUnsigned(object, "frame_received_monotonic_ns");
            const captured_ms = try jsonUnsigned(object, "captured_monotonic_ms");
            emit(.{ .phase = "ai_observation", .owner = self.accepted.?.handle, .operation_id = operation_id, .observation_id = self.observation_id, .width = self.observation_width, .height = self.observation_height, .frame_generation = self.observation_frame_generation, .frame_sequence = self.observation_frame_sequence, .frame_received_monotonic_ns = received_ns, .captured_monotonic_ms = captured_ms, .transport_generation = try jsonUnsigned(object, "transport_generation"), .control_generation = try jsonUnsigned(object, "control_generation"), .input_epoch = try jsonUnsigned(object, "input_epoch"), .provider_uploaded = false });
            if (self.action_timing) |*timing| if (timing.sent_monotonic_ns) |sent_ns| {
                const runtime_value = self.runtime() orelse return error.MissingRuntime;
                if (runtime_value.ai_control.refresh_fence_operation_id != timing.operation_id or self.observation_frame_sequence <= runtime_value.ai_control.refresh_fence_sequence or received_ns < sent_ns) return error.PostActionEvidenceMismatch;
                timing.post_observation_id = self.observation_id;
                timing.post_frame_sequence = self.observation_frame_sequence;
                timing.post_frame_received_monotonic_ns = received_ns;
                timing.post_screenshot_captured_monotonic_ms = captured_ms;
                timing.sent_to_post_frame_ms = @as(f64, @floatFromInt(received_ns - sent_ns)) / std.time.ns_per_ms;
                timing.sent_to_post_screenshot_ms = captured_ms -| (sent_ns / std.time.ns_per_ms);
                timing.post_send_new_frame_verified = true;
                self.last_completed_action_timing = timing.*;
                self.actions_with_post_send_observation += 1;
                emit(.{ .phase = "input_observed_after_send", .owner = self.accepted.?.handle, .timing = timing.* });
                self.action_timing = null;
            };
        } else if (std.mem.eql(u8, id, "bmc_ikvm.keyboard") or std.mem.eql(u8, id, "bmc_ikvm.pointer") or std.mem.eql(u8, id, "bmc_ikvm.operation_status")) {
            const state = object.get("state") orelse return error.MissingToolResultField;
            const possibly_written = object.get("possibly_written") orelse return error.MissingToolResultField;
            if (state != .string or possibly_written != .bool) return error.InvalidToolResultField;
            const safe_state: []const u8 = if (std.mem.eql(u8, state.string, "queued")) "queued" else if (std.mem.eql(u8, state.string, "sent")) "sent" else if (std.mem.eql(u8, state.string, "partial_unknown")) "partial_unknown" else if (std.mem.eql(u8, state.string, "cancelled_unsent")) "cancelled_unsent" else return error.InvalidToolResultField;
            const input_operation = try jsonUnsigned(object, "operation_id");
            if (std.mem.eql(u8, id, "bmc_ikvm.operation_status")) {
                if (input_operation != self.ai_operation) return error.UnexpectedInputReceipt;
            } else if (input_operation != operation_id) return error.UnexpectedInputReceipt;
            const sent_events = try jsonUnsigned(object, "sent_events");
            const total_events = try jsonUnsigned(object, "total_events");
            if (sent_events > total_events or total_events == 0 or total_events > 256) return error.InvalidToolResultField;
            self.last_wire_receipt = .{ .operation_id = input_operation, .state = safe_state, .sent_events = @intCast(sent_events), .total_events = @intCast(total_events), .possibly_written = possibly_written.bool };
            if (self.action_timing) |*timing| if (timing.operation_id == input_operation and timing.queued_receipt_observed_monotonic_ms == null) {
                timing.queued_receipt_observed_monotonic_ms = runtime_api.monotonicMs();
            };
            emit(.{ .phase = "generic_input_receipt", .owner = self.accepted.?.handle, .tool_operation_id = operation_id, .input_operation_id = input_operation, .tool_id = id, .state = safe_state, .sent_events = sent_events, .total_events = total_events, .possibly_written = possibly_written.bool, .wire_sent = std.mem.eql(u8, safe_state, "sent"), .remote_application_effect_verified = false });
        }
    }
    fn runReadonlyTools(self: *Runner) !void {
        const args = try std.fmt.allocPrint(a, "{{\"session_ids\":[{d}]}}", .{@backingInt(self.accepted.?.handle.session_id)});
        defer a.free(args);
        for ([_][]const u8{ "bmc_ikvm.read_power_state", "bmc_ikvm.read_boot", "bmc_ikvm.describe_frame" }) |id| {
            _ = try self.callTool(id, args, null);
            self.readonly_tool_calls += 1;
        }
        emit(.{ .phase = "readonly_tools_verified", .owner = self.accepted.?.handle, .tools = self.readonly_tool_calls, .typed_management = try self.captureTypedManagementSummary(), .unavailable_management_is_valid_result = true });
    }
    fn runScreenshot(self: *Runner, image_path: []const u8) !bool {
        const now = runtime_api.monotonicMs();
        if (now < self.next_screenshot_retry_ms) return false;
        if (!try self.frameGeometryReady()) return self.waitForScreenshot(now, error.FrameGeometryPending);
        // Runtime.poll/operation_status arm the production post-action fence.
        // Wait on that state first, so an image-sharing approval is used once
        // when an image can actually be returned, not as a polling mechanism.
        if (!try self.postActionFrameReady()) {
            return self.waitForScreenshot(now, error.PostActionFramePending);
        }
        const args = try std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"max_width\":1920,\"max_height\":1200}}", .{@backingInt(self.accepted.?.handle.session_id)});
        defer a.free(args);
        self.observation_id = null;
        _ = self.callTool("bmc_ikvm.screenshot", args, image_path) catch |err| switch (err) {
            error.PostActionFramePending, error.OperationPending, error.FrameGeometryPending => {
                // An admitted input must be queried before another image read.
                // This branch never resubmits the original keyboard/pointer.
                if (err == error.OperationPending) _ = try self.aiInputSent();
                return self.waitForScreenshot(now, err);
            },
            else => return err,
        };
        self.screenshot_wait_started_ms = null;
        self.next_screenshot_retry_ms = 0;
        if (self.observation_id == null) return error.MissingObservation;
        return true;
    }
    fn waitForScreenshot(self: *Runner, now: u64, err: anyerror) !bool {
        if (self.screenshot_wait_started_ms == null) {
            self.screenshot_wait_started_ms = now;
            emit(.{ .phase = "observation_refresh_waiting", .owner = self.accepted.?.handle, .stage = @tagName(self.control_stage), .code = @errorName(err), .new_input_dispatched = false, .new_image_approval_requested = false });
        }
        if (now - self.screenshot_wait_started_ms.? >= 4_000) return error.PostActionFrameRefreshTimeout;
        self.next_screenshot_retry_ms = now + 100;
        return false;
    }
    fn postActionFrameReady(self: *Runner) !bool {
        const runtime_value = self.runtime() orelse return error.MissingRuntime;
        if (runtime_value.ai_control.last_operation_id == 0) return true;
        const binding = runtime_value.aiBinding();
        const table = try binding.borrow(ai_control.Interface, ai_control.key, self.accepted.?.handle);
        const receipt = try table.operation_status(binding.context, binding, runtime_value.ai_control.last_operation_id);
        if (receipt.status == .accepted) return false;
        if (receipt.status == .cancelled_unsent) return true;
        if (runtime_value.ai_control.refresh_fence_operation_id != receipt.operation_id) return false;
        var lease = switch (runtime_value.controller.framebuffer.acquireLatest(runtime_value.controller.framebuffer.binding(), 0)) {
            .frame => |value| value,
            else => return false,
        };
        defer lease.release();
        return lease.snapshot.sequence > runtime_value.ai_control.refresh_fence_sequence and (receipt.sent_monotonic_ns == 0 or lease.snapshot.received_monotonic_ns >= receipt.sent_monotonic_ns);
    }
    fn frameGeometryReady(self: *Runner) !bool {
        const runtime_value = self.runtime() orelse return false;
        const snapshot = try runtime_value.controller.remote_input.snapshot(runtime_value.controller.remote_input.binding());
        // The live Pipeline publishes a nonzero generation only after a
        // complete frame. Reading this fact never mutates its pending gate.
        return !snapshot.geometry_pending and snapshot.geometry_generation != 0 and snapshot.geometry_generation == runtime_value.last_generation;
    }
    fn aiInputSent(self: *Runner) !bool {
        const now = runtime_api.monotonicMs();
        if (self.last_status_poll_ms != 0 and now - self.last_status_poll_ms < 250) return false;
        self.last_status_poll_ms = now;
        const operation_id = self.ai_operation orelse return error.MissingAiInputOperation;
        const args = try std.fmt.allocPrint(a, "{{\"session_ids\":[{d}],\"operation_id\":{d}}}", .{ @backingInt(self.accepted.?.handle.session_id), operation_id });
        defer a.free(args);
        _ = try self.callTool("bmc_ikvm.operation_status", args, null);
        // Query the same production typed service too, so the verdict cannot be
        // inferred from a generic 'tool submitted' success or an empty queue.
        const owner = self.accepted.?.handle;
        const access = try self.host.?.serviceAccess(owner);
        const binding = (try access.lookup(owner, ai_control.definition)) orelse return error.MissingAiControlService;
        const iface = try binding.borrow(ai_control.Interface, ai_control.key, owner);
        const receipt = try iface.operation_status(binding.context, binding, operation_id);
        if (self.action_timing) |*timing| if (timing.operation_id == receipt.operation_id and receipt.status == .sent) {
            if (receipt.sent_monotonic_ns == 0) return error.MissingWireSendTimestamp;
            timing.sent_monotonic_ns = receipt.sent_monotonic_ns;
            timing.sent_receipt_observed_monotonic_ms = runtime_api.monotonicMs();
            // Both endpoints are truncated to milliseconds; reserve one ms so
            // this remains an upper bound on time spent after local admission.
            timing.dispatch_to_wire_sent_ms_upper_bound = (receipt.sent_monotonic_ms -| timing.dispatch_started_monotonic_ms) +| 1;
        };
        self.last_wire_receipt = .{ .operation_id = receipt.operation_id, .state = switch (receipt.status) {
            .accepted => "queued",
            .sent => "sent",
            .cancelled_unsent => "cancelled_unsent",
            .outcome_unknown => "partial_unknown",
        }, .sent_events = receipt.sent_events, .total_events = receipt.total_events, .possibly_written = receipt.possibly_written };
        emit(.{ .phase = "ai_input_receipt", .owner = receipt.owner, .operation_id = receipt.operation_id, .effect = "remote_input", .state = @tagName(receipt.status), .sent_events = receipt.sent_events, .total_events = receipt.total_events, .possibly_written = receipt.possibly_written, .sent_monotonic_ns = receipt.sent_monotonic_ns, .timing = self.action_timing, .wire_sent = receipt.status == .sent, .remote_effect_unknown = receipt.status == .outcome_unknown, .remote_application_effect_verified = false });
        return switch (receipt.status) {
            .accepted => false,
            .sent => receipt.sent_events == receipt.total_events and receipt.total_events != 0,
            .cancelled_unsent => error.AiInputCancelledUnsent,
            .outcome_unknown => error.AiInputOutcomeUnknown,
        };
    }
    fn observeMenus(self: *Runner, elapsed: u64) !void {
        if (self.close_requested or self.renderer == null or self.sink == null or self.sink.?.texture == null) return;
        const view: *views.View = @ptrCast(@alignCast(self.renderer.?.context));
        if (!self.safe_views_verified) {
            if (!view.request_disabled.peek() or !view.keys_disabled.peek() or !view.power_execute_disabled.peek() or !view.boot_execute_disabled.peek()) return error.UnsafeRendererActions;
            const typed_summary = try self.captureTypedManagementSummary();
            self.safe_views_verified = true;
            emit(.{ .phase = "readonly_verified", .control_disabled = true, .input_disabled = true, .power_disabled = true, .boot_disabled = true, .management_snapshots = true, .discovery = self.captureDiscoverySummary(), .typed_management = typed_summary, .presentation = try self.capturePresentationSummary(), .progress = self.progress_headline });
        }
        const period = @as(u64, self.input.observe_seconds) * 1000;
        if (!self.shots[0] and elapsed >= 100) {
            _ = try self.capturePresentationSummary();
            self.shots[0] = self.app.capturePresentedToPng("/tmp/zerowork-bmc-live-frame.png");
            if (self.shots[0]) {
                for (view.open) |signal| signal.set(false);
                view.open[3].set(true);
                self.app.cx.requestRedraw();
            }
        }
        if (self.shots[0] and !self.shots[1] and elapsed >= @max(300, period / 3)) {
            _ = try self.capturePresentationSummary();
            self.shots[1] = self.app.capturePresentedToPng("/tmp/zerowork-bmc-live-power.png");
            if (self.shots[1]) {
                for (view.open) |signal| signal.set(false);
                view.open[4].set(true);
                self.app.cx.requestRedraw();
            }
        }
        if (self.shots[1] and !self.shots[2] and elapsed >= @max(600, 2 * period / 3)) {
            _ = try self.capturePresentationSummary();
            self.shots[2] = self.app.capturePresentedToPng("/tmp/zerowork-bmc-live-boot.png");
            if (self.shots[2]) {
                for (view.open) |signal| signal.set(false);
                self.app.cx.requestRedraw();
            }
        }
        if (std.mem.allEqual(bool, &self.shots, true) and !self.log_shot) {
            if (self.log_opened_ms == null) {
                for (view.open) |signal| signal.set(false);
                const open = view.log_open orelse return error.MissingConnectionLog;
                open.set(true);
                self.log_opened_ms = runtime_api.monotonicMs();
                self.log_opened_frame = self.app.renderer.frame_count;
                self.app.cx.requestRedraw();
                return;
            }
            const modal = view.log_modal orelse return error.MissingConnectionLog;
            const rect = modal.dialog.globalRect();
            if (runtime_api.monotonicMs() - self.log_opened_ms.? < 250 or self.app.renderer.frame_count <= self.log_opened_frame.? or !self.app.renderer.last_frame_presented or rect.w <= 0 or rect.h <= 0) return;
            self.log_shot = self.app.capturePresentedToPng("/tmp/zerowork-bmc-live-log.png");
            if (self.log_shot) {
                emit(.{ .phase = "log_screenshot", .progress = self.progress_headline });
                if (view.log_open) |open| open.set(false);
                self.app.cx.requestRedraw();
            }
        }
    }
    fn releasePresentation(self: *Runner) !void {
        if (!isReadOnly(self.input)) self.releaseControlAuthority();
        self.unmountRenderer();
        if (self.native_focus_subscription) |subscription| self.app.cx.focus_manager.unsubscribeVisibility(subscription);
        self.native_focus_subscription = null;
        if (self.content_context) |context| context.close();
        if (self.sink) |sink| try sink.close();
        if (self.after_layout_registered) {
            self.app.cx.removeAfterLayoutHook(self);
            self.after_layout_registered = false;
        }
    }
    fn advanceClose(self: *Runner) !void {
        if (!isReadOnly(self.input)) self.releaseControlAuthority();
        if (self.accepted != null and self.plugin != null) {
            const accepted = self.accepted.?;
            if (self.host) |*host| _ = try host.requestClose(accepted.handle, .{});
            if (self.runtime()) |runtime_value| {
                const receipt = runtime_value.receipt();
                if (receipt != .released) return;
                self.web_logout = runtime_value.remote_web_logout;
                self.kvm_logout = runtime_value.remote_kvm_logout;
                self.captureProgressSummary(runtime_value.controller.poll().progress);
                // Runtime caches this after the worker-exit barrier and before
                // backend destruction. No cleanup-time backend borrow escapes.
                if (runtime_value.remote_logout_diagnostics) |diagnostic| self.logout_summary = .{
                    .web = logoutAttemptSummary(diagnostic.web),
                    .kvm = logoutAttemptSummary(diagnostic.kvm),
                    .websocket_close = @tagName(diagnostic.websocket_close),
                    .websocket_failure = if (diagnostic.websocket_failure) |err| @errorName(err) else null,
                };
                self.pressed_keys = runtime_value.controller.remote_input.pressed_count;
                self.pressed_buttons = runtime_value.controller.remote_input.pressed_buttons;
                const input_snapshot = runtime_value.controller.poll().input;
                self.last_input_queued = input_snapshot.queued;
                self.last_automation_pending = input_snapshot.automation_queued;
                self.last_input_remote_unknown = input_snapshot.remote_unconfirmed;
            }
        }
        try self.releasePresentation();
        if (self.plugin) |plugin| {
            plugin.deinit() catch |err| {
                if (err == error.BmcCleanupPending) return;
                return err;
            };
            self.plugin = null;
        }
        self.retainer.stopping.store(true, .release);
        if (!self.retainer.done.load(.acquire)) return;
        try self.budget.deinit();
        if (self.accepted) |accepted| {
            self.secret_store.revokeOwner(accepted.handle);
            self.tls_store.cancelOwner(accepted.handle);
            self.challenge_host.retireOwner(accepted.handle);
        }
        self.released = true;
        self.finished = true;
        if (self.first_frame_ms == null or !self.safe_views_verified or !self.native_route_verified or self.pressed_keys != 0 or self.pressed_buttons != 0) self.failed = true;
        if (isReadOnly(self.input)) {
            if (!std.mem.allEqual(bool, &self.shots, true) or !self.progress_shot or !self.log_shot) self.failed = true;
        } else {
            const result = self.controlSummary().?;
            if (!self.control_complete or !result.own_web_delete_http_200 or !result.own_kvm_delete_http_200 or result.active_human_leases != 0 or result.active_automation_leases != 0 or result.input_queued != 0 or result.automation_pending != 0 or result.remote_input_unconfirmed) self.failed = true;
        }
        emit(.{ .phase = "complete", .success = !self.failed, .cleanup = "released", .web_logout = @tagName(self.web_logout), .kvm_logout = @tagName(self.kvm_logout), .width = self.last_width, .height = self.last_height, .frames = self.last_frames, .budget_bytes = self.budget.usedBytes(), .budget_peak_bytes = self.budget.peakBytes(), .pressed_keys = self.pressed_keys, .pressed_buttons = self.pressed_buttons, .input_sequence = self.last_input_sequence, .journal_writes = self.journal_backend.denied_writes, .screenshots = self.shots, .progress_screenshot = self.progress_shot, .log_screenshot = self.log_shot, .discovery = self.discovery_summary, .typed_management = self.typed_management_summary, .logout_diagnostics = self.logout_summary, .control = self.controlSummary(), .video = self.videoSummary(), .failure_code = self.failure_code, .presentation = self.presentation_summary, .progress = self.progress_headline, .progress_events = self.progress_events[0..self.progress_event_count] });
        _ = self.app.commitClose();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Runner = @ptrCast(@alignCast(raw));
        if (!self.finished) {
            if (self.sink) |sink| _ = sink.drain() catch false;
        }
        return .done;
    }
    fn destroy(self: *Runner) void {
        std.debug.assert(self.released and self.retainer.done.load(.acquire));
        if (self.tool_table) |*table| table.deinit();
        self.tool_operations.deinit();
        for (self.presentations[0..self.presentation_count]) |slot| if (slot) |presentation| a.destroy(presentation);
        if (self.host) |*host| host.deinit();
        self.host = null;
        self.secret_store.deinit();
        self.tls_store.deinit();
        self.challenge_host.deinit();
        self.registry.deinit();
        self.host_keys.deinit();
        self.library.deinit();
        if (self.envelope) |envelope| a.free(envelope.payload);
        a.destroy(self);
    }
};

fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const self = active orelse return error.RunnerUnavailable;
    theme.select(.dark);
    cx.setTheme(theme.widgetTheme(.dark));
    self.scope = scope;
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 6, .padding = ui.Padding.all(8), .background = theme.baseColors().app, .min_width = 0, .min_height = 0 }, .{});
    root.meta.ownership.meta.test_id = "live.window";
    self.root = root;
    const heading = try ui.hstack(cx, .{ .width = .fill(), .height = .{ .px = 36 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 12, .right = 12 }, .background = theme.current().surface_1, .border = .{ .radius = 9 } }, .{});
    try root.appendChild(cx.allocator, heading);
    try heading.appendChild(cx.allocator, try ui.text(cx, if (isReadOnly(self.input)) "ZeroWork · BMC · LIVE READ-ONLY ACCEPTANCE" else "ZeroWork · BMC · LIVE SAFE CONTROL ACCEPTANCE", .{ .font_size = 12, .color = theme.current().fg_2 }));
    const slot = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .border = .{ .radius = 11 }, .overflow_hidden = true }, .{});
    slot.meta.ownership.meta.test_id = "live.content_slot";
    try root.appendChild(cx.allocator, slot);
    self.slot = slot;
    // Host upload hook precedes the real renderer's texture presentation hook.
    try cx.addAfterLayoutHook(self, Runner.afterLayout);
    self.after_layout_registered = true;
    return root;
}

fn route(path: []const u8, body: []const u8, out: []u8) ?[]const u8 {
    const self = active orelse return null;
    if (std.mem.eql(u8, path, "/app/bmc-live/close")) {
        self.close_requested = true;
        return "{\"ok\":true}";
    }
    if (std.mem.eql(u8, path, "/app/bmc-live/command")) {
        if (self.native_command != null) return "{\"error\":\"InteractiveCommandAlreadyQueued\"}";
        const parsed = std.json.parseFromSlice(InteractiveCommand, a, body, .{}) catch return "{\"error\":\"InvalidSafeTestCommand\"}";
        defer parsed.deinit();
        self.validateInteractiveCommand(parsed.value) catch |err| return jsonReply(.{ .error_code = @errorName(err), .input_dispatched = false }, out);
        self.native_command = parsed.value;
        return "{\"ok\":true,\"state\":\"test_command_queued\",\"wire_sent\":false,\"remote_application_effect_verified\":false}";
    }
    if (std.mem.eql(u8, path, "/app/bmc-live/native-evidence")) return jsonReply(self.native_view, out);
    if (std.mem.eql(u8, path, "/app/bmc-live/video-stats")) return jsonReply(self.videoSummary(), out);
    if (std.mem.eql(u8, path, "/app/bmc-live/performance")) {
        const runtime_value = self.runtime() orelse return "{\"error\":\"RuntimeUnavailable\"}";
        const state = runtime_value.controller.poll();
        return jsonReply(.{ .observed_monotonic_ms = runtime_api.monotonicMs(), .performance = state.performance, .published_frames = state.published_frames, .queued_sequence = state.input.last_input_sequence, .sent_sequence = state.input.last_sent_input_sequence }, out);
    }
    if (std.mem.eql(u8, path, "/app/bmc-live/control-state")) return jsonReply(.{
        .owner = if (self.accepted) |accepted| accepted.handle else null,
        .control_stage = self.control_stage,
        .command_queued = self.native_command != null,
        .observation_id = self.observation_id,
        .observation_frame_sequence = self.observation_frame_sequence,
        .observation_remaining_ms = self.observation_valid_until_ms -| runtime_api.monotonicMs(),
        .geometry_ready = self.frameGeometryReady() catch false,
        .window_active = self.app.cx.window_active,
        .closing = self.close_requested,
    }, out);
    if (std.mem.eql(u8, path, "/app/bmc-live/focus-stats")) return jsonReply(self.nativeFocusDiagnostic(), out);
    if (std.mem.eql(u8, path, "/app/bmc-live/lifecycle-stats")) return jsonReply(.{
        .interactive_actions_sent = self.interactive_actions_sent,
        .interactive_actions_cancelled_unsent = self.interactive_actions_cancelled_unsent,
        .interactive_stop_requests = self.interactive_stop_requests,
        .actions_with_post_send_observation = self.actions_with_post_send_observation,
        .last_completed_action_timing = self.last_completed_action_timing,
        .reconnects = self.reconnects,
        .same_tab_preserved = self.same_tab_preserved,
        .old_proof_invalid_after_retry = self.old_proof_invalid_after_retry,
        .old_proof_rejected_by_new_owner = self.old_proof_rejected_by_new_owner,
        .old_proof_invalid_after_stop = self.old_proof_invalid_after_stop,
        .old_proof_rejected_after_stop = self.old_proof_rejected_after_stop,
        .retry_own_logout_confirmed = self.retry_own_logout_confirmed,
        .active_human_leases = if (self.content_context) |context| @intFromBool(context.human != null) else 0,
        .active_automation_leases = if (self.content_context) |context| @intFromBool(context.automation != null) else 0,
        .cancelled_connection = self.cancelled_connection,
    }, out);
    if (!std.mem.eql(u8, path, "/app/bmc-live/stats") and !std.mem.eql(u8, path, "/app/bmc-live/input-stats")) return null;
    const view: ?*views.View = if (self.renderer) |renderer| @ptrCast(@alignCast(renderer.context)) else null;
    const input_snapshot: ?remote_input.Snapshot = if (self.runtime()) |runtime_value| runtime_value.controller.poll().input else null;
    var local_pressed_keys: usize = 0;
    if (view) |value| for (value.keyboard.pressed) |symbol| {
        if (symbol != 0) local_pressed_keys += 1;
    };
    if (std.mem.eql(u8, path, "/app/bmc-live/input-stats")) return jsonReply(.{
        .captured = if (view) |v| v.captured else false,
        .pending_capture = if (view) |v| v.pending_capture else false,
        .view_input_sequence = if (view) |v| v.input_sequence else 0,
        .view_buttons = if (view) |v| v.buttons else 0,
        .view_pressed_keys = local_pressed_keys,
        .capture_authority = if (view) |v| v.capture_authority else null,
        .input = input_snapshot,
        .ai_proof_valid = if (self.ai_grant) |grant| grant.proof.valid() else false,
        .ai_operation = self.ai_operation,
        .last_wire_receipt = self.last_wire_receipt,
        .pending_action_timing = self.action_timing,
        .last_completed_action_timing = self.last_completed_action_timing,
    }, out);
    const now = runtime_api.monotonicMs();
    const deadline_ms = self.begin_ms + (if (self.input.acceptance_mode == .native_interactive) @as(u64, self.input.interactive_seconds) * 1000 else 50_000);
    const value = .{
        .renderer_ready = self.console_ready,
        .native_route_verified = self.native_route_verified,
        .readonly_verified = self.safe_views_verified,
        .width = self.last_width,
        .height = self.last_height,
        .frames = self.last_frames,
        .closing = self.close_requested,
        .finished = self.finished,
        .cleanup = if (self.released) "released" else "pending",
        .budget_bytes = self.budget.usedBytes(),
        .input_sequence = self.last_input_sequence,
        .journal_writes = self.journal_backend.denied_writes,
        .owner = if (self.accepted) |accepted| accepted.handle else null,
        .tab_id = if (self.tab_id) |id| @backingInt(id) else null,
        .acceptance_mode = self.input.acceptance_mode,
        .control_stage = self.control_stage,
        .command_queued = self.native_command != null,
        .deadline_remaining_ms = deadline_ms -| now,
        .window_active = self.app.cx.window_active,
        .geometry_ready = self.frameGeometryReady() catch false,
        .observation_id = self.observation_id,
        .observation_width = self.observation_width,
        .observation_height = self.observation_height,
        .observation_frame_generation = self.observation_frame_generation,
        .observation_frame_sequence = self.observation_frame_sequence,
        .observation_remaining_ms = self.observation_valid_until_ms -| now,
        .local_image_path = if (self.input.acceptance_mode == .native_interactive) @as(?[]const u8, "/tmp/zerowork-bmc-interactive-observation.png") else null,
    };
    return jsonReply(value, out);
}
fn jsonReply(value: anytype, out: []u8) []const u8 {
    const bytes = std.json.Stringify.valueAlloc(a, value, .{}) catch return "{\"error\":\"serialization\"}";
    defer a.free(bytes);
    if (bytes.len > out.len) return "{\"error\":\"buffer\"}";
    @memcpy(out[0..bytes.len], bytes);
    return out[0..bytes.len];
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    var validate_only = false;
    if (args.next()) |arg| {
        if (!std.mem.eql(u8, arg, "--validate-stdin") or args.next() != null) return error.InvalidRunnerArgument;
        validate_only = true;
    }
    emit(.{ .phase = "awaiting_stdin", .validate_only = validate_only });
    const bytes = try readInputLine();
    defer {
        wipe(bytes);
        a.free(bytes);
    }
    const parsed = try std.json.parseFromSlice(Input, a, bytes, .{ .allocate = .alloc_always });
    // An unknown native cleanup receipt keeps the TLS verifier's borrowed
    // authority strings alive until process exit. Password bytes still wipe.
    var pending_native_storage = false;
    defer if (!pending_native_storage) parsed.deinit();
    defer wipeInput(parsed.value);
    const approved = try validateInput(parsed.value);
    if (validate_only) {
        emit(.{ .phase = "input_validated", .network_started = false, .window_created = false, .ssh_nodes = parsed.value.ssh_hops.len, .read_only_requested = isReadOnly(parsed.value), .acceptance_mode = @tagName(parsed.value.acceptance_mode), .explicit_operator_approval = parsed.value.operator_approval != null });
        return;
    }
    if (parsed.value.acceptance_mode == .native_interactive) {
        const activation = init.environ_map.get("ZENIT_E2E_REAL_ACTIVATION") orelse return error.NativeRealActivationRequired;
        if (!std.mem.eql(u8, activation, "1")) return error.NativeRealActivationRequired;
        for ([_][]const u8{ "ZENIT_E2E_BACKGROUND", "ZENIT_E2E_ISOLATE_POINTER", "ZENIT_E2E_ISOLATE_KEYBOARD" }) |flag| {
            if (init.environ_map.get(flag) != null) return error.NativeInputIsolationMustBeUnset;
        }
        emit(.{ .phase = "native_input_environment", .real_activation = true, .background = false, .pointer_isolation = false, .keyboard_isolation = false, .window_created = false, .network_started = false });
    }
    try @import("platform/ui_fonts.zig").register();
    var application = zenit.MultiWindowApp.init(a, .{ .shared_gpu = true });
    defer application.deinit();
    const app = try application.createWindow(.{ .io = init.io, .font = .{ .fallback_families = @import("platform/ui_fonts.zig").families }, .window = .{ .width = 1440, .height = 900, .min_width = 860, .min_height = 480, .title = if (isReadOnly(parsed.value)) "ZeroWork · BMC live read-only acceptance" else "ZeroWork · BMC live safe control acceptance", .titlebar = .custom_inset, .titlebar_height = 0, .hide_native_controls = true } });
    const self = try Runner.create(init.io, app, parsed.value, approved);
    active = self;
    defer active = null;
    defer if (self.released) self.destroy();
    app.setCloseRequestHandler(.{ .context = self, .request = Runner.closeRequest });
    zenit.setTestRouteHandler(route);
    app.mount(mount) catch |err| {
        self.fail(@errorName(err));
    };
    self.begin() catch |err| self.fail(@errorName(err));
    while (application.shouldContinue()) {
        self.poll() catch |err| self.fail(@errorName(err));
        _ = try application.tick();
    }
    if (!self.released) {
        pending_native_storage = true;
        return error.LiveCleanupUnknown;
    }
    if (self.failed) return error.LiveAcceptanceFailed;
}
