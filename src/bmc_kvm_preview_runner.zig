//! Isolated acceptance host for the production BMC renderer. Services use the
//! original typed definitions; all input bytes terminate in a local counter.
//! No transport, Runtime, controller, credentials or real target is created.
const std = @import("std");
const ui = @import("ui");
const zenit = @import("zenit_app");
const App = zenit.App;
const views = @import("plugins/bmc_ikvm/views.zig");
const console = @import("plugins/bmc_ikvm/console_service.zig");
const framebuffer = @import("plugins/bmc_ikvm/framebuffer.zig");
const input = @import("plugins/bmc_ikvm/remote_input.zig");
const services = @import("plugins/bmc_ikvm/services.zig");
const typed = @import("host/plugin_services.zig");
const contract = @import("host/plugin_ui_contract.zig");
const frames = @import("host/frame_texture_sink.zig");
const access_api = @import("host/session_service_access.zig");
const identity = @import("host/identity.zig");
const theme = @import("ui/app_theme.zig");

const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(320), .generation = 7 };
const operation: services.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 1, .attempt_id = 1 };
const State = enum { controlled, read_only, no_signal, disconnected, partial, unknown, progress_log };
const ProgressFixture = struct { revision: u64 = 1, stage: console.progress.Stage = .public_script, elapsed_ms: u64 = 9900, stage_elapsed_ms: u64 = 9900, long_route: bool = false, failure: bool = false, log_generation: u64 = 1 };
var selected_state: State = .controlled;
var selected_theme: theme.Name = .dark;
var app_instance: ?*App = null;
var active_fixture: ?*Fixture = null;
const evidence: services.Evidence = .{ .source_uri = "/local-fixture/system", .collected_ms = 1, .validity = .valid, .corroborated = true };
const order = [_][]const u8{
    "Boot0001 · UEFI PXE IPv4 Port 1",
    "Boot0002 · UEFI PXE IPv6 Port 1",
    "Boot0003 · UEFI PXE IPv4 Port 2",
    "Boot0004 · UEFI PXE IPv6 Port 2",
    "Boot0005 · Local synthetic disk 1",
    "Boot0006 · Local synthetic disk 2",
    "Boot0007 · Local synthetic disk 3",
    "Boot0008 · Local synthetic disk 4",
    "Boot0009 · Existing optical drive",
    "Boot000A · Existing USB device",
    "Boot000B · Local diagnostics",
    "Boot000C · Firmware setup",
    "Boot000D · Vendor option (raw retained)",
    "Boot000E · Disabled vendor option",
    "Boot000F · Local synthetic disk 5",
    "Boot0010 · Local synthetic disk 6",
    "Boot0011 · Local synthetic disk 7",
    "Boot0012 · Local synthetic disk 8",
    "Boot0013 · Unknown option original text",
    "Boot0014 · LAST LOCAL FIXTURE ENTRY",
};

const Fixture = struct {
    cx: *ui.Cx,
    main_thread: std.Thread.Id,
    root: *ui.Node,
    slot: *ui.Node,
    budget: frames.Budget = frames.Budget.init(128 * 1024 * 1024),
    sink: frames.Sink = undefined,
    fb: framebuffer.Service = undefined,
    remote: input.Service = input.Service.init(owner),
    renderer: ?contract.RendererInstance = null,
    state: State = .controlled,
    progress_log_generation: u64 = 0,
    progress_fixture: ?ProgressFixture = null,
    closed: bool = false,
    console_reads: usize = 0,
    power_reads: usize = 0,
    boot_reads: usize = 0,
    control_requests: usize = 0,
    control_replies: usize = 0,
    refresh_requests: usize = 0,
    retries: usize = 0,
    power_writes: usize = 0,
    boot_writes: usize = 0,
    release_count: usize = 0,
    last_release: input.ReleaseCause = .released,
    key_count: usize = 0,
    chord_count: usize = 0,
    pointer_count: usize = 0,
    wheel_count: usize = 0,
    last_key: input.Key = .{ .keysym = 0, .down = false },
    last_pointer: input.Pointer = .{ .x = 0, .y = 0, .buttons = 0 },
    last_wheel: input.Wheel = .{ .x = 0, .y = 0 },
    last_chord: input.Chord = .{ .count = 0 },
    transition_count: usize = 0,
    wire_bytes: usize = 0,
    wire_messages: usize = 0,
    wire_aborts: usize = 0,
    owner_guards: bool = false,
    type_guards: bool = false,
    lease_guards: bool = false,

    fn from(raw: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(raw));
    }
    fn validate(self: *Fixture, binding: typed.Binding, definition: typed.Definition) !void {
        if (std.Thread.getCurrentId() != self.main_thread) return error.ServiceLookupOffMainThread;
        if (self.closed or !binding.owner.eql(owner) or binding.generation != owner.generation or binding.context != @as(*anyopaque, self)) return error.StaleBinding;
        if (!binding.definition.matches(definition)) return error.ServiceTypeMismatch;
        if (!binding.authorized) return error.ServiceDenied;
    }
    fn validateCall(self: *Fixture, call: services.Call) !void {
        if (self.closed or !call.owner.eql(owner) or call.binding_generation != owner.generation) return error.StaleBinding;
    }
    fn lookup(raw: *anyopaque, requested_owner: identity.SessionHandle, definition: typed.Definition) !?typed.Binding {
        const self = from(raw);
        if (std.Thread.getCurrentId() != self.main_thread) return error.ServiceLookupOffMainThread;
        if (self.closed or !owner.eql(requested_owner)) return error.StaleSession;
        const bindings = [_]typed.Binding{
            typed.Binding.init(console.Interface, console.key, self, &console_table, owner, 1),
            self.fb.binding(),
            typed.Binding.init(input.Interface, input.key, self, &input_table, owner, 1),
            typed.Binding.init(services.PowerService, services.power_key, self, &power_table, owner, 1),
            typed.Binding.init(services.BootService, services.boot_key, self, &boot_table, owner, 1),
        };
        for (bindings) |binding| {
            if (!binding.definition.key.eql(definition.key)) continue;
            if (!binding.definition.matches(definition)) return error.ServiceTypeMismatch;
            return binding;
        }
        return null;
    }
    fn access(self: *Fixture) access_api.SessionServiceAccess {
        return .{ .context = self, .owner = owner, .lookup_fn = lookup };
    }
    fn consoleSnapshot(raw: *anyopaque, binding: typed.Binding, allocator: std.mem.Allocator) !console.OwnedSnapshot {
        const self = from(raw);
        try self.validate(binding, console.definition);
        self.console_reads += 1;
        const disconnected = self.state == .disconnected;
        const no_signal = self.state == .no_signal;
        const progress_log = self.state == .progress_log;
        const failed_progress = if (self.progress_fixture) |fixture| progress_log and fixture.failure else false;
        const snap = try self.remote.snapshot(self.remote.binding());
        return console.OwnedSnapshot.init(allocator, .{
            .owner = owner,
            .operation = operation,
            .name = "LOCAL BMC fixture",
            .target = "local.synthetic.invalid",
            .route_summary = if (progress_log and self.progress_fixture != null and self.progress_fixture.?.long_route) "LOCAL SYNTHETIC ROUTE · local → first.synthetic.invalid:22 → a-long-hostname-for-layout-measurement.synthetic.invalid:22 → another-long-hostname-for-layout-measurement.synthetic.invalid:22 → local.synthetic.invalid:443" else "Local synthetic fixture · no network transport",
            .route = if (disconnected or failed_progress) .failed else .connected,
            .video = if (disconnected or failed_progress) .failed else if (no_signal or progress_log) .awaiting_frame else .streaming,
            .cleanup = if (failed_progress) .released else .not_started,
            .management = .available,
            .input = snap,
            .control = if (snap.controlled) .major else .read_only,
            .width = self.fb.width,
            .height = self.fb.height,
            .stride = @as(usize, self.fb.width) * 4,
            .frame_sequence = self.fb.sequence,
            .frame_generation = self.fb.frame_generation,
            .rfb_ready = !disconnected and !progress_log,
            .progress = if (progress_log) self.syntheticProgressLog() else .{},
            .read_only_requested = self.state == .read_only,
            .failure_stage = if (disconnected) .video else null,
            .failure_code = if (disconnected) "LOCAL_FIXTURE_DISCONNECTED" else null,
        });
    }
    /// Explicit acceptance data only. No Runtime, transport or response parser
    /// feeds this fixture; the final two rows prove real native wrapping/scroll.
    fn syntheticProgressLog(self: *Fixture) console.progress.Snapshot {
        var result: console.progress.Snapshot = .{ .revision = 31 + self.progress_log_generation, .stage = .redfish_discovery, .elapsed_ms = 12300, .stage_elapsed_ms = 11700, .event_count = 32 };
        const first_sequence = result.revision - 31;
        const phases = [_]console.progress.Stage{ .route, .tls_handshake, .public_identity, .public_script, .web_login, .firmware_confirmation, .redfish_discovery };
        for (&result.events, 0..) |*event, index| {
            const sequence = first_sequence + index;
            event.* = .{ .sequence = sequence, .at_ms = (sequence - 1) * 100, .stage = .redfish_discovery, .kind = .http_response, .resource = .system, .http_status = 200, .count = @intCast(sequence), .validity = .valid };
            if (sequence <= phases.len) event.* = .{ .sequence = sequence, .at_ms = (sequence - 1) * 100, .stage = phases[sequence - 1] };
            if (sequence == 31) event.* = .{ .sequence = sequence, .at_ms = 3000, .stage = .redfish_discovery, .kind = .diagnostic, .resource = .manager, .http_status = 404, .code = .mapping_manager_document_rejected, .validity = .partial_with_error };
            if (sequence >= 32) event.* = .{ .sequence = sequence, .at_ms = (sequence - 1) * 100, .stage = .redfish_discovery, .kind = .diagnostic, .resource = if (sequence > 32) .system else .systems_collection, .http_status = 404, .code = if (sequence > 32) .readonly_member_rejected else .readonly_collection_rejected, .validity = .partial_with_error, .error_code = if (sequence > 32) "LOCAL_GROWN_READONLY_REJECTED" else "LOCAL_FIXTURE_READONLY_REJECTED" };
        }
        if (self.progress_fixture) |fixture| {
            result.revision = fixture.revision;
            if (fixture.revision == 0) result.event_count = 0;
            result.stage = if (fixture.failure) .failed else fixture.stage;
            result.elapsed_ms = fixture.elapsed_ms;
            result.stage_elapsed_ms = fixture.stage_elapsed_ms;
            result.waiting_for_user = fixture.stage == .waiting_certificate or fixture.stage == .waiting_credentials;
            if (fixture.failure) {
                result.failure_stage = .public_script;
                result.failure_code = "UnsupportedProfilePublicEvidenceUnavailable";
            }
        }
        return result;
    }
    fn requestControl(raw: *anyopaque, binding: typed.Binding) !void {
        const self = from(raw);
        try self.validate(binding, console.definition);
        self.control_requests += 1;
        if (self.state == .read_only or self.state == .disconnected) return error.ReadOnlyFixture;
        try self.remote.setControl(true, self.remote.control_generation + 1);
    }
    fn replyControl(raw: *anyopaque, binding: typed.Binding, _: [4]u8, _: console.ControlReply) !void {
        const self = from(raw);
        try self.validate(binding, console.definition);
        self.control_replies += 1;
    }
    fn refresh(raw: *anyopaque, binding: typed.Binding) !void {
        const self = from(raw);
        try self.validate(binding, console.definition);
        self.refresh_requests += 1;
        self.cx.requestRedraw();
    }
    fn focus(raw: *anyopaque, binding: typed.Binding, focused: bool) !void {
        const self = from(raw);
        try self.validate(binding, console.definition);
        self.remote.setFocus(focused);
    }
    fn retry(raw: *anyopaque, binding: typed.Binding) !void {
        const self = from(raw);
        try self.validate(binding, console.definition);
        self.retries += 1;
    }
    const console_table: console.Interface = .{ .snapshot = consoleSnapshot, .request_control = requestControl, .reply_control = replyControl, .refresh = refresh, .set_focus = focus, .retry = retry };
    fn inputSnapshot(raw: *anyopaque, binding: typed.Binding) !input.Snapshot {
        const self = from(raw);
        try self.validate(binding, input.definition);
        return self.remote.snapshot(self.remote.binding());
    }
    fn submit(raw: *anyopaque, binding: typed.Binding, command: input.Command) input.SubmitResult {
        const self = from(raw);
        self.validate(binding, input.definition) catch return .stale_binding;
        const result = self.remote.submit(self.remote.binding(), command);
        if (result == .accepted) switch (command.event) {
            .key => |v| {
                self.key_count += 1;
                self.last_key = v;
            },
            .pointer => |v| {
                self.pointer_count += 1;
                self.last_pointer = v;
            },
            .wheel => |value| {
                self.wheel_count += 1;
                self.last_wheel = value;
            },
            .chord => |v| {
                self.chord_count += 1;
                self.last_chord = v;
            },
        };
        return result;
    }
    fn submitChord(raw: *anyopaque, binding: typed.Binding, command: input.ExplicitChordCommand) input.SubmitResult {
        const self = from(raw);
        self.validate(binding, input.definition) catch return .stale_binding;
        const result = self.remote.submitChord(self.remote.binding(), command);
        if (result == .accepted) {
            self.chord_count += 1;
            self.last_chord = command.chord;
        }
        return result;
    }
    fn releaseAll(raw: *anyopaque, binding: typed.Binding, cause: input.ReleaseCause) input.ReleaseResult {
        const self = from(raw);
        self.validate(binding, input.definition) catch return .stale_binding;
        self.release_count += 1;
        self.last_release = cause;
        return self.remote.releaseAll(self.remote.binding(), cause);
    }
    const input_table: input.Interface = .{ .snapshot = inputSnapshot, .submit = submit, .release_all = releaseAll, .submit_chord = submitChord };
    fn capability(self: *Fixture) services.Capability {
        return .{ .revision = 1, .grant_revision = 1, .binding_generation = owner.generation, .system_mapping_verified = true, .write_granted = false, .secondary_auth = .disabled, .secondary_auth_evidence = self.localEvidence() };
    }
    fn localEvidence(self: *Fixture) services.Evidence {
        var result = evidence;
        if (self.state == .partial) {
            result.validity = .partial_with_error;
            result.corroborated = false;
        }
        return result;
    }
    fn powerSnapshot(raw: *anyopaque, call: services.Call, allocator: std.mem.Allocator) !services.OwnedPowerSnapshot {
        const self = from(raw);
        try self.validateCall(call);
        self.power_reads += 1;
        return services.OwnedPowerSnapshot.init(allocator, .{ .system_uri = "/local-fixture/system", .system_identity = "LOCAL SYNTHETIC SYSTEM", .capability = self.capability(), .state = .{ .value = if (self.state == .unknown) .unknown else .on, .evidence = self.localEvidence() }, .reset_types = .{ .value = &.{ "On", "GracefulShutdown", "GracefulRestart", "ForceOff", "ForceRestart", "PowerCycle" }, .evidence = self.localEvidence() }, .reset_target = "/local-fixture/reset" });
    }
    fn bootSnapshot(raw: *anyopaque, call: services.Call, allocator: std.mem.Allocator) !services.OwnedBootSnapshot {
        const self = from(raw);
        try self.validateCall(call);
        self.boot_reads += 1;
        const ev = self.localEvidence();
        return services.OwnedBootSnapshot.init(allocator, .{ .system_uri = "/local-fixture/system", .system_identity = "LOCAL SYNTHETIC SYSTEM", .write_uri = "/local-fixture/boot", .capability = self.capability(), .state = if (self.state == .unknown) .{ .enabled = "OemUnrecognized", .target = "VendorOriginalText", .mode = "CustomMode" } else .{ .enabled = "Once", .target = "Pxe", .mode = "UEFI" }, .enabled_evidence = ev, .target_evidence = ev, .mode_evidence = ev, .allowed_enabled = .{ .value = &.{ "Disabled", "Once", "Continuous" }, .evidence = ev }, .allowed_targets = .{ .value = &.{ "Pxe", "Hdd", "Cd", "Diags", "BiosSetup", "Usb", "None" }, .evidence = ev }, .allowed_modes = .{ .value = &.{ "UEFI", "Legacy" }, .evidence = ev }, .boot_order = .{ .value = &order, .evidence = ev }, .etag = "LOCAL-FIXTURE-1" });
    }
    fn powerRequest(raw: *anyopaque, _: services.PowerExecutionRequest) services.RequestResult {
        from(raw).power_writes += 1;
        return .{ .rejected = .permission_denied };
    }
    fn bootApply(raw: *anyopaque, _: services.BootExecutionPatch) services.RequestResult {
        from(raw).boot_writes += 1;
        return .{ .rejected = .permission_denied };
    }
    fn cancel(_: *anyopaque, _: services.Call, _: services.OperationKey) services.CancelResult {
        return .already_terminal;
    }
    fn operationResult(raw: *anyopaque, call: services.Call, op: services.OperationKey, allocator: std.mem.Allocator) !services.Owned(services.Result) {
        try from(raw).validateCall(call);
        return services.Owned(services.Result).init(allocator, .{ .operation = op, .phase = .failed, .reason = .permission_denied });
    }
    const power_table: services.PowerService = .{ .snapshot = powerSnapshot, .request = powerRequest, .cancel = cancel, .result = operationResult };
    const boot_table: services.BootService = .{ .snapshot = bootSnapshot, .apply = bootApply, .cancel = cancel, .result = operationResult };
    fn localWrite(raw: *anyopaque, bytes: []const u8) !usize {
        const self = from(raw);
        self.wire_bytes += bytes.len;
        self.wire_messages += 1;
        return bytes.len;
    }
    fn localAbort(raw: *anyopaque) void {
        from(raw).wire_aborts += 1;
    }
    fn pump(self: *Fixture) void {
        _ = self.remote.pump(.{ .context = self, .generation = self.remote.transport_generation, .write = localWrite, .abort = localAbort }) catch {};
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self = from(raw);
        if (!self.closed) {
            _ = self.sink.drain() catch false;
            self.pump();
        }
        return .done;
    }
    fn applyState(self: *Fixture, value: State) !void {
        if (self.renderer) |renderer| renderer.vtable.focus_changed(renderer.context, false);
        self.state = value;
        if (value == .progress_log) self.progress_log_generation += 1;
        if ((value != .disconnected) != self.remote.connected) try self.remote.setConnected(value != .disconnected, self.remote.transport_generation + 1);
        try self.remote.setControl(value != .read_only and value != .disconnected, self.remote.control_generation + 1);
        self.remote.setFocus(false);
        if (self.renderer) |renderer| {
            renderer.vtable.focus_changed(renderer.context, true);
            try renderer.vtable.update(renderer.context, .{ .owner = owner, .revision = 1, .title = "Local fixture", .status = "" });
        }
        self.cx.requestRedraw();
    }
    fn checkGuards(self: *Fixture) !void {
        const stale = try owner.nextGeneration();
        self.owner_guards = if (self.access().lookup(stale, console.definition)) |_| false else |err| err == error.OwnerMismatch;
        self.type_guards = if (self.access().lookup(owner, typed.Definition.of(input.Interface, console.key))) |_| false else |err| err == error.ServiceTypeMismatch;
        var lease = switch (self.fb.acquireLatest(self.fb.binding(), 0)) {
            .frame => |v| v,
            else => return error.ExpectedSyntheticFrame,
        };
        self.lease_guards = if (self.fb.advanceGeneration()) |_| false else |err| err == error.FrameBorrowed;
        lease.release();
        lease.release();
        if (!self.owner_guards or !self.type_guards or !self.lease_guards) return error.FixtureGuardFailed;
    }
    fn cleanup(self: *Fixture) void {
        if (self.closed) return;
        if (self.renderer) |renderer| renderer.vtable.unmount(renderer.context);
        self.renderer = null;
        self.remote.close();
        self.pump();
        self.sink.stop();
        self.sink.close() catch @panic("fixture sink still busy");
        self.fb.deinit() catch @panic("fixture framebuffer still borrowed");
        self.budget.deinit() catch @panic("fixture leaked frame reservation");
        self.cx.removeAfterLayoutHook(self);
        self.closed = true;
        active_fixture = null;
        std.debug.print("BMC_FIXTURE_CLEANUP budget_used={d} keys={d} buttons={d} power_writes={d} boot_writes={d}\n", .{ self.budget.usedBytes(), self.remote.pressed_count, self.remote.pressed_buttons, self.power_writes, self.boot_writes });
    }
};

fn syntheticFrame(self: *Fixture) !void {
    const width = 1920;
    const height = 1200;
    const rgba = try self.cx.allocator.alloc(u8, width * height * 4);
    defer self.cx.allocator.free(rgba);
    for (0..height) |y| for (0..width) |x| {
        const i = (y * width + x) * 4;
        const grid = x % 240 < 2 or y % 150 < 2;
        const cross = x >= 958 and x <= 961 or y >= 598 and y <= 601;
        rgba[i] = if (cross) 90 else if (grid) 26 else @intCast(3 + x / 120);
        rgba[i + 1] = if (cross) 180 else if (grid) 50 else @intCast(5 + y / 60);
        rgba[i + 2] = if (cross) 240 else if (grid) 75 else 24;
        rgba[i + 3] = 255;
    };
    _ = try self.fb.publishComplete(width, height, rgba, 1);
    _ = try self.fb.publishToSink(&self.sink);
    _ = try self.sink.drain();
}
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(selected_theme);
    cx.setTheme(theme.widgetTheme(selected_theme));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 6, .padding = ui.Padding.all(8), .background = theme.baseColors().app, .min_width = 0, .min_height = 0 }, .{});
    root.meta.ownership.meta.test_id = "fixture.window";
    const top = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 36 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 12, .right = 12 }, .background = theme.current().surface_1, .border = .{ .radius = 9 } }, .{});
    top.meta.ownership.meta.test_id = "fixture.shell.header";
    try root.appendChild(cx.allocator, top);
    try top.appendChild(cx.allocator, try ui.text(cx, "ZeroWork · BMC renderer · LOCAL SYNTHETIC FIXTURE", .{ .font_size = 12, .color = theme.current().fg_2 }));
    const slot = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .border = .{ .radius = 11 }, .overflow_hidden = true }, .{});
    slot.meta.ownership.meta.test_id = "fixture.content_slot";
    try root.appendChild(cx.allocator, slot);
    const status = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 26 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 12, .right = 12 }, .background = theme.current().surface_1, .border = .{ .radius = 8 } }, .{});
    try root.appendChild(cx.allocator, status);
    try status.appendChild(cx.allocator, try ui.text(cx, "LOCAL ONLY  ·  1920 × 1200 synthetic RGBA  ·  management read only", .{ .font_size = 11, .color = theme.current().fg_2 }));
    const self = try scope.createState(Fixture, .{ .cx = cx, .main_thread = std.Thread.getCurrentId(), .root = root, .slot = slot });
    self.fb = framebuffer.Service.init(cx.allocator, owner, &self.budget);
    self.sink = frames.Sink.initWithBudget(owner, frames.backendFor((app_instance orelse return error.AppUnavailable).sharedImageStore() orelse return error.ImageStoreUnavailable), &self.budget, .kvm);
    try scope.onCleanup(Fixture, self, Fixture.cleanup);
    active_fixture = self;
    try syntheticFrame(self);
    try self.checkGuards();
    try self.applyState(selected_state);
    // Register the real host upload phase before the renderer's presentation
    // phase, just as PluginWindowHost does for the application.
    try cx.addAfterLayoutHook(self, Fixture.afterLayout);
    self.renderer = try views.mount(null, .{ .cx = cx, .scope = scope, .slot = slot, .owner = owner, .connection = .{ .protocol_id = "bmc_ikvm", .name = "LOCAL BMC fixture", .payload = "{}" }, .frame_sink = &self.sink, .service_access = self.access() });
    return root;
}

fn route(path: []const u8, body: []const u8, out: []u8) ?[]const u8 {
    const self = active_fixture orelse return null;
    if (std.mem.eql(u8, path, "/app/bmc-fixture/progress")) {
        const parsed = std.json.parseFromSlice(ProgressFixture, self.cx.allocator, body, .{}) catch return "{\"error\":\"invalid progress fixture\"}";
        defer parsed.deinit();
        self.state = .progress_log;
        self.progress_fixture = parsed.value;
        self.progress_log_generation = @max(1, parsed.value.log_generation);
        if (self.renderer) |renderer| renderer.vtable.update(renderer.context, .{ .owner = owner, .revision = parsed.value.revision, .title = "LOCAL synthetic progress fixture", .status = "" }) catch return "{\"error\":\"progress fixture update failed\"}";
        self.cx.requestRedraw();
        return "{\"ok\":true}";
    }
    if (std.mem.eql(u8, path, "/app/bmc-fixture/state")) {
        const parsed = std.json.parseFromSlice(struct { state: State }, self.cx.allocator, body, .{}) catch return "{\"error\":\"invalid fixture state\"}";
        defer parsed.deinit();
        self.applyState(parsed.value.state) catch return "{\"error\":\"fixture transition failed\"}";
        return "{\"ok\":true}";
    }
    if (std.mem.eql(u8, path, "/app/bmc-fixture/focus")) {
        const parsed = std.json.parseFromSlice(struct { focused: bool }, self.cx.allocator, body, .{}) catch return "{\"error\":\"invalid focus\"}";
        defer parsed.deinit();
        if (self.renderer) |renderer| renderer.vtable.focus_changed(renderer.context, parsed.value.focused);
        return "{\"ok\":true}";
    }
    if (std.mem.eql(u8, path, "/app/bmc-fixture/transition")) {
        const parsed = std.json.parseFromSlice(struct { action: enum { input_epoch, revoke_control, grant_control, reconnect } }, self.cx.allocator, body, .{}) catch return "{\"error\":\"invalid synthetic input transition\"}";
        defer parsed.deinit();
        switch (parsed.value.action) {
            .input_epoch => {
                _ = self.remote.releaseAll(self.remote.binding(), .released);
                self.pump();
                self.remote.resumeCapture() catch return "{\"error\":\"fixture input release pending\"}";
            },
            .revoke_control => self.remote.setControl(false, self.remote.control_generation + 1) catch return "{\"error\":\"fixture revoke failed\"}",
            .grant_control => self.remote.setControl(true, self.remote.control_generation + 1) catch return "{\"error\":\"fixture grant failed\"}",
            .reconnect => {
                self.remote.setConnected(false, self.remote.transport_generation + 1) catch return "{\"error\":\"fixture disconnect failed\"}";
                self.pump();
                self.remote.setConnected(true, self.remote.transport_generation + 1) catch return "{\"error\":\"fixture reconnect failed\"}";
                self.remote.setControl(true, self.remote.control_generation + 1) catch return "{\"error\":\"fixture control failed\"}";
            },
        }
        self.transition_count += 1;
        self.cx.requestRedraw();
        return "{\"ok\":true,\"synthetic_service_transition\":true,\"native_os_focus_evidence\":false}";
    }
    if (std.mem.eql(u8, path, "/app/bmc-fixture/menus")) {
        const renderer = self.renderer orelse return "{\"error\":\"renderer unavailable\"}";
        const view: *views.View = @ptrCast(@alignCast(renderer.context));
        var opened: [5]bool = @splat(false);
        var heights: [5]f32 = @splat(0);
        var bodies: [5]ui.ComputedRect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        var chromes: [5]ui.ComputedRect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        for (0..5) |i| {
            opened[i] = view.open[i].peek();
            if (view.menu_scrolls[i]) |scroll| heights[i] = scroll.container.globalRect().h;
            if (view.menus[i]) |popup| {
                bodies[i] = popup.content.globalRect();
                chromes[i] = popup.chrome.globalRect();
            }
        }
        return jsonReply(self.cx.allocator, .{ .open = opened, .closed = view.closed, .overlay = self.cx.overlay_stack.topmost() != null, .heights = heights, .bodies = bodies, .chromes = chromes }, out);
    }
    if (!std.mem.eql(u8, path, "/app/bmc-fixture/stats") and !std.mem.eql(u8, path, "/app/bmc-fixture/input-stats") and !std.mem.eql(u8, path, "/app/bmc-fixture/material-stats")) return null;
    self.pump();
    const view: ?*views.View = if (self.renderer) |renderer| @ptrCast(@alignCast(renderer.context)) else null;
    const remote_snapshot = self.remote.snapshot(self.remote.binding()) catch return "{\"error\":\"fixture input snapshot failed\"}";
    const surface = if (view) |value| if (value.waiting) |waiting| findById(waiting, "bmc.progress.surface") else null else null;
    var local_keys: usize = 0;
    if (view) |value| for (value.keyboard.pressed) |symbol| {
        if (symbol != 0) local_keys += 1;
    };
    if (std.mem.eql(u8, path, "/app/bmc-fixture/material-stats")) return jsonReply(self.cx.allocator, .{
        .progress_material = if (surface) |node| .{ .alpha = node.getBackground().a, .blur = if (node.style.glass_params()) |glass| glass.backdrop_blur else 0, .bounds = node.globalRect(), .shared_layer_alpha = theme.layerAlpha(1), .parameters = theme.materialParameters() } else null,
    }, out);
    if (std.mem.eql(u8, path, "/app/bmc-fixture/input-stats")) return jsonReply(self.cx.allocator, .{
        .captured = if (view) |v| v.captured else false,
        .pending_capture = if (view) |v| v.pending_capture else false,
        .capture_authority = if (view) |v| v.capture_authority else null,
        .view_input_sequence = if (view) |v| v.input_sequence else 0,
        .view_pressed_keys = local_keys,
        .view_buttons = if (view) |v| v.buttons else 0,
        .input = remote_snapshot,
        .wire_bytes = self.wire_bytes,
        .wire_messages = self.wire_messages,
        .wire_aborts = self.wire_aborts,
        .transition_count = self.transition_count,
        .pointers = self.pointer_count,
        .wheels = self.wheel_count,
        .last_wheel = self.last_wheel,
    }, out);
    const stats = .{
        .state = @tagName(self.state),
        .owner_guards = self.owner_guards,
        .type_guards = self.type_guards,
        .lease_guards = self.lease_guards,
        .texture = self.sink.texture,
        .frame_generation = self.sink.frame_generation,
        .frame_revision = self.sink.revision,
        .budget_used = self.budget.usedBytes(),
        .captured = if (view) |v| v.captured else false,
        .draft = if (view) |v| v.draft.value.state() else services.BootState{},
        .draft_dirty = if (view) |v| v.draft.dirty() else false,
        .scale = if (view) |v| @tagName(v.mode) else "none",
        .scroll_x = if (view) |v| if (v.scroll) |s| s.state.scroll_x else 0 else 0,
        .scroll_y = if (view) |v| if (v.scroll) |s| s.state.scroll_y else 0 else 0,
        .order_scroll_y = if (view) |v| if (v.order_scroll) |s| s.state.scroll_y else 0 else 0,
        .order_max_y = if (view) |v| if (v.order_scroll) |s| s.state.maxScrollY() else 0 else 0,
        .log_revision = if (view) |v| v.log_revision else null,
        .log_scroll_y = if (view) |v| if (v.log_scroll) |s| s.state.scroll_y else 0 else 0,
        .log_max_y = if (view) |v| if (v.log_scroll) |s| s.state.maxScrollY() else 0 else 0,
        .log_line_count = if (view) |v| if (v.log_detail) |n| if (n.layoutTextLayout()) |layout| layout.line_count else @as(u16, 0) else @as(u16, 0) else @as(u16, 0),
        .power_writes = self.power_writes,
        .boot_writes = self.boot_writes,
        .release_count = self.release_count,
        .last_release = @tagName(self.last_release),
        .keys = self.key_count,
        .chords = self.chord_count,
        .last_key = self.last_key,
        .last_pointer = self.last_pointer,
        .last_chord = self.last_chord,
        .pressed_keys = self.remote.pressed_count,
        .pressed_buttons = self.remote.pressed_buttons,
    };
    return jsonReply(self.cx.allocator, stats, out);
}
fn findById(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |actual| if (std.mem.eql(u8, actual, id)) return node;
    for (node.children.items) |child| if (findById(child, id)) |found| return found;
    return null;
}
fn jsonReply(allocator: std.mem.Allocator, value: anytype, out: []u8) []const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    std.json.Stringify.value(value, .{}, &writer.writer) catch return "{\"error\":\"stats serialization failed\"}";
    const json = writer.written();
    if (json.len > out.len) return "{\"error\":\"stats buffer too small\"}";
    @memcpy(out[0..json.len], json);
    return out[0..json.len];
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--theme=")) selected_theme = std.meta.stringToEnum(theme.Name, arg[8..]) orelse return error.InvalidTheme else if (std.mem.startsWith(u8, arg, "--state=")) selected_state = std.meta.stringToEnum(State, arg[8..]) orelse return error.InvalidFixtureState else return error.InvalidFixtureArgument;
    }
    try @import("platform/ui_fonts.zig").register();
    var application = zenit.MultiWindowApp.init(std.heap.c_allocator, .{ .shared_gpu = true });
    defer application.deinit();
    const app = try application.createWindow(.{ .io = init.io, .font = .{ .fallback_families = @import("platform/ui_fonts.zig").families }, .window = .{ .width = 1440, .height = 900, .min_width = 860, .min_height = 480, .title = "ZeroWork · BMC isolated renderer fixture", .titlebar = .custom_inset, .titlebar_height = 0, .hide_native_controls = true } });
    app_instance = app;
    defer app_instance = null;
    zenit.setTestRouteHandler(route);
    try app.mount(mount);
    try application.run();
}
