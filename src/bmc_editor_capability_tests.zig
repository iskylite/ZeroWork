//! Public editor capability tests. Passwords use an owned memory backend;
//! config writes use a temporary directory; no BMC or Keychain IO is performed.
const std = @import("std");
const ui = @import("ui");
const credentials = @import("config/credential_store.zig");
const editor_credentials = @import("host/editor_credentials.zig");
const secrets = @import("host/secret_lease.zig");
const probes = @import("host/probe_contract.zig");
const probe_host = @import("host/probe_host.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const plugin_ui = @import("host/plugin_ui_contract.zig");
const identity = @import("host/identity.zig");
const operations = @import("host/operation.zig");
const envelopes = @import("config/connection_envelope.zig");
const config = @import("config/config.zig");
const store = @import("config/store.zig");
const refs = @import("config/plugin_credential_references.zig");
const wizard_mod = @import("ui/wizard.zig");
const a = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    mounted: ?plugin_ui.EditorMount = null,
    secret_store: *secrets.Store,
    credential_host: ?*editor_credentials.Host = null,
    sessions_host: ?*sessions.SessionHost = null,
    directory: ?std.Io.Dir = null,
    registry: ?*config.hosts.Registry = null,
    fail_save: bool = false,
    handoff: ?editor_credentials.Handoff = null,
    expected_secret: ?[]const u8 = null,
    opened_owner: ?identity.SessionHandle = null,
    opened_operation: ?operations.OperationKey = null,
    next_request: u64 = 1,
    received_secrets: usize = 0,
    defer_secret_acquire: bool = false,
    hold_probe: bool = false,
    late_release: bool = false,
    active_probe: ?probes.ProbeRequest = null,

    fn manifest(self: *Fixture) plugins.PluginManifest {
        return .{
            .id = "fixture.editor-capability",
            .display_name = "Capability fixture",
            .workspace_kind = "fixture.editor-capability",
            .content_renderer = "fixture.editor-capability",
            .session_factory = .{ .context = self, .vtable = &.{ .create = create, .cancel = cancelSession, .close = closeSession, .release_stale = stale } },
            .connection = .{
                .create_kind = .saved_or_temporary,
                .editor_factory = .{ .context = self, .mount = mount },
                .validate_payload = validate,
                .encode = codec,
                .decode = codec,
                .migrate = migrate,
                .credential_references = enumerate,
                .probe_factory = .{ .context = self, .begin = beginProbe, .poll = pollProbe, .cancel = cancelProbe },
            },
        };
    }
    fn renderer() plugins.RendererDefinition {
        return .{ .kind = "fixture.editor-capability", .shared_renderer = true };
    }
    fn mount(raw: ?*anyopaque, args: plugin_ui.EditorMount) !plugin_ui.EditorInstance {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.mounted = args;
        if (args.protocol_picker) |picker| try args.slot.appendChild(args.cx.allocator, try picker.mount(picker.context, args.cx, args.scope));
        try args.slot.appendChild(args.cx.allocator, try ui.text(args.cx, "Capability fixture", .{}));
        return .{ .context = self, .vtable = &.{ .snapshot = snapshot, .clear_secrets = clear, .unmount = clear } };
    }
    fn snapshot(_: *anyopaque, allocator: std.mem.Allocator) !envelopes.Envelope {
        return value(null).clone(allocator);
    }
    fn clear(_: *anyopaque) void {}
    const Payload = struct { credential_ref: ?[]const u8 = null };
    fn validate(payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Payload, a, payload, .{});
        defer parsed.deinit();
        if (parsed.value.credential_ref) |reference| if (!credentials.validReference(reference)) return error.InvalidCredentialReference;
    }
    fn codec(allocator: std.mem.Allocator, envelope: envelopes.Envelope) !envelopes.Envelope {
        try validate(envelope.payload);
        return envelope.clone(allocator);
    }
    fn migrate(allocator: std.mem.Allocator, envelope: envelopes.Envelope, _: u32) !envelopes.Envelope {
        return codec(allocator, envelope);
    }
    fn value(payload: ?[]const u8) envelopes.Envelope {
        return .{ .protocol_id = "fixture.editor-capability", .name = "Capability", .payload = payload orelse "{}" };
    }
    fn encodedReference(reference: ?[68]u8) ![]u8 {
        return if (reference) |ref| std.fmt.allocPrint(a, "{{\"credential_ref\":\"{s}\"}}", .{ref}) else a.dupe(u8, "{}");
    }
    fn enumerate(allocator: std.mem.Allocator, payload: []const u8) ![]const []const u8 {
        const parsed = try std.json.parseFromSlice(Payload, allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value.credential_ref) |reference| {
            const result = try allocator.alloc([]const u8, 1);
            errdefer allocator.free(result);
            result[0] = try allocator.dupe(u8, reference);
            return result;
        }
        return allocator.alloc([]const u8, 0);
    }
    fn resolve(_: *const anyopaque, protocol_id: []const u8, version: u32) ?refs.Enumerator {
        return if (version == 1 and std.mem.eql(u8, protocol_id, "fixture.editor-capability")) enumerate else null;
    }
    fn provider(self: *Fixture) refs.Provider {
        return .{ .context = self, .resolve = resolve };
    }
    fn submit(raw: *anyopaque, envelope: envelopes.Envelope, intent: plugin_ui.SubmitIntent, handoff_value: editor_credentials.Handoff) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (intent == .save or intent == .save_and_open) {
            var transaction = try store.HostsTransaction.init(a, self.registry.?);
            defer transaction.deinit();
            const record: config.hosts.HostConfig = .{ .name = envelope.name, .host = "", .user = "", .protocol_id = envelope.protocol_id, .plugin_payload = envelope.payload };
            if (@backingInt(envelope.id) == 0) {
                _ = try transaction.candidate.?.add(record);
            } else _ = try transaction.candidate.?.update(.{ .id = envelope.id, .revision = envelope.revision }, record);
            _ = try transaction.commitWithOptions(io, self.directory.?, if (self.fail_save) "blocked/hosts.toml" else "hosts.toml", self.registry.?, .{ .provider = self.provider() });
        }
        if (intent == .temporary or intent == .save_and_open) {
            self.handoff = handoff_value;
            defer self.handoff = null;
            _ = try self.sessions_host.?.open(envelope, .{ .request_key = self.next_request, .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) } });
            self.next_request += 1;
        }
    }
    fn receive(self: *Fixture, facade: secrets.Facade, operation: operations.OperationKey, cancel: ?*const std.atomic.Value(bool)) !void {
        var acquired = try facade.acquireDefault(operation, cancel);
        switch (acquired) {
            .lease => |*lease| {
                defer lease.deinit();
                try std.testing.expectEqualStrings(self.expected_secret.?, try lease.defaultBytes(facade.owner, operation));
                self.received_secrets += 1;
            },
            .missing => try std.testing.expect(self.expected_secret == null),
            else => return error.UnexpectedSecretResult,
        }
    }
    fn create(raw: *anyopaque, request: sessions.CreateRequest) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.opened_owner = request.handle;
        self.opened_operation = request.key;
        if (self.handoff) |handoff_value| try self.credential_host.?.authorizeHandoff(handoff_value, request.handle, request.key);
        if (!self.defer_secret_acquire) try self.receive(self.secret_store.facade(request.handle), request.key, null);
    }
    fn cancelSession(_: *anyopaque, _: operations.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn closeSession(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) void {}
    fn probeContext(raw: *anyopaque, token: probes.ProbeToken, cancel: *const std.atomic.Value(bool)) !probes.ProbeContext {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return .{ .owner = token.handle, .operation = token.operation, .secrets = self.secret_store.facade(token.handle), .cancel = cancel };
    }
    fn beginProbe(raw: *anyopaque, request: probes.ProbeRequest) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.active_probe = request;
        try self.receive(request.restricted_context.secrets.?, request.operation, request.restricted_context.cancel);
    }
    fn pollProbe(raw: *anyopaque, _: operations.OperationKey) !?probes.ProbeUpdate {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.hold_probe and !self.late_release) return null;
        self.late_release = false;
        self.active_probe = null;
        return .{ .result = .{ .outcome = .succeeded, .cleanup = .released, .safe_message = "finished" } };
    }
    fn cancelProbe(raw: *anyopaque, _: operations.OperationKey) probes.CloseReceipt {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.hold_probe) return .unknown;
        self.active_probe = null;
        return .released;
    }
};

const Harness = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    wizard: *wizard_mod.Wizard,
    fn init(fixture: *Fixture, source: plugins.Registry, credential_host: *editor_credentials.Host, probes_host: ?*probe_host.Host) !Harness {
        fixture.credential_host = credential_host;
        const cx = try ui.Cx.init(a, io);
        errdefer cx.deinit();
        const scope = try ui.Scope.init(a, null, cx.owner);
        errdefer scope.dispose();
        cx.setViewport(900, 700);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const wizard = try cx.bindState(wizard_mod.Wizard, .{});
        wizard.setRegistry(source);
        wizard.credential_host = credential_host;
        wizard.probe_host = probes_host;
        wizard.on_envelope_with_secret = Fixture.submit;
        wizard.envelope_context = fixture;
        try cx.root.?.appendChild(a, try wizard.mount(cx, scope));
        return .{ .cx = cx, .scope = scope, .wizard = wizard };
    }
    fn deinit(self: *Harness) void {
        self.scope.dispose();
        self.cx.deinit();
    }
};

fn expectSecret(reference: []const u8, expected: []const u8) !void {
    const secret = try credentials.get(a, reference);
    defer {
        std.crypto.secureZero(u8, secret);
        a.free(secret);
    }
    try std.testing.expectEqualStrings(expected, secret);
}

fn findNode(node: *ui.Node, test_id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |actual| if (std.mem.eql(u8, actual, test_id)) return node;
    for (node.children.items) |child| if (findNode(child, test_id)) |found| return found;
    return null;
}

test "BMC editor capability protocol picker replaces its own scope only after the pointer handler returned" {
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    var credential_host = editor_credentials.Host.init(a, io, &secret_store);
    defer credential_host.deinit();
    var fixture: Fixture = .{ .secret_store = &secret_store };
    var manifests = [_]plugins.PluginManifest{ fixture.manifest(), fixture.manifest() };
    manifests[1].id = "fixture.second-editor";
    manifests[1].display_name = "Second editor";
    var harness = try Harness.init(&fixture, .{ .published = .{ .entries = &manifests, .renderers = &.{} } }, &credential_host, null);
    defer harness.deinit();
    try harness.cx.setTestFrameStep(100);
    harness.wizard.show();
    for (0..3) |_| {
        harness.cx.advanceFrameClock();
        _ = harness.cx.render();
    }
    const before = fixture.mounted.?.credentials.?;
    const button = findNode(harness.wizard.root.?, "wizard.protocol.fixture.second-editor").?;
    const rect = button.globalRect();
    harness.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    harness.cx.handleMouseUpEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
    try std.testing.expectEqualStrings("fixture.editor-capability", harness.wizard.protocol_id);
    try std.testing.expectEqualStrings("fixture.second-editor", harness.wizard.queued_protocol.?);
    harness.cx.advanceFrameClock();
    _ = harness.cx.render();
    try std.testing.expectEqualStrings("fixture.second-editor", fixture.mounted.?.protocol_id);
    try std.testing.expect(harness.wizard.queued_protocol == null);
    try std.testing.expectError(error.StaleEditorCredentials, before.prepare("old-scope", null, false));
}

test "BMC editor capability save commits the existing config transaction and failed config rolls staged Keychain back" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    var credential_host = editor_credentials.Host.init(a, io, &secret_store);
    defer credential_host.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "file" });
    var registry = try config.hosts.Registry.parse(a, "");
    defer registry.deinit();
    var fixture: Fixture = .{ .secret_store = &secret_store, .directory = tmp.dir, .registry = &registry };
    _ = try store.saveHostsWithOptions(io, tmp.dir, "hosts.toml", registry, .{ .provider = fixture.provider() });
    const baseline = try store.loadHostsWithOptions(io, tmp.dir, a, "hosts.toml", .{ .provider = fixture.provider() });
    registry.deinit();
    registry = baseline;
    const manifests = [_]plugins.PluginManifest{fixture.manifest()};
    const renderers = [_]plugins.RendererDefinition{Fixture.renderer()};
    var sessions_host = try sessions.SessionHost.initPlugins(a, &manifests, &renderers);
    defer sessions_host.deinit();
    fixture.sessions_host = &sessions_host;
    var harness = try Harness.init(&fixture, .{ .published = .{ .entries = &manifests, .renderers = &renderers } }, &credential_host, null);
    defer harness.deinit();
    var staged = try fixture.mounted.?.credentials.?.prepare("first-password", null, true);
    const payload = try Fixture.encodedReference(staged.reference);
    defer a.free(payload);
    const events = fixture.mounted.?.events;
    try events.submit_with_secret.?(events.context, Fixture.value(payload), .save, try fixture.mounted.?.credentials.?.handoff(staged));
    try expectSecret(&staged.reference.?, "first-password");
    try std.testing.expectEqual(@as(usize, 1), registry.hosts.len);
    const encoded = try tmp.dir.readFileAlloc(io, "hosts.toml", a, .limited(8192));
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "first-password") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, &staged.reference.?) != null);
    const old_reference = staged.reference.?;
    staged = try fixture.mounted.?.credentials.?.prepare("replacement-password", &old_reference, true);
    const failed_payload = try Fixture.encodedReference(staged.reference);
    defer a.free(failed_payload);
    var editing = Fixture.value(failed_payload);
    editing.id = registry.hosts[0].connection_id;
    editing.revision = registry.hosts[0].revision;
    fixture.fail_save = true;
    if (events.submit_with_secret.?(events.context, editing, .save, try fixture.mounted.?.credentials.?.handoff(staged))) |_| return error.ExpectedConfigFailure else |_| {}
    try expectSecret(&old_reference, "first-password");
    try std.testing.expectError(error.CredentialMissing, credentials.get(a, &staged.reference.?));
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
    try std.testing.expectEqual(@as(u64, 1), registry.hosts[0].revision);
    fixture.fail_save = false;
    staged = try fixture.mounted.?.credentials.?.prepare(null, &old_reference, true);
    try std.testing.expectEqual(old_reference, staged.reference.?);
    editing.payload = payload;
    try events.submit_with_secret.?(events.context, editing, .save, try fixture.mounted.?.credentials.?.handoff(staged));
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
    staged = try fixture.mounted.?.credentials.?.prepare("unsaved-override", &old_reference, false);
    try std.testing.expect(staged.reference == null);
    editing.payload = "{}";
    editing.revision = registry.hosts[0].revision;
    fixture.expected_secret = "unsaved-override";
    try events.submit_with_secret.?(events.context, editing, .save_and_open, try fixture.mounted.?.credentials.?.handoff(staged));
    try std.testing.expectEqual(@as(usize, 1), fixture.received_secrets);
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
    try std.testing.expectEqualStrings("{}", registry.hosts[0].plugin_payload.?);
    const optout_encoded = try tmp.dir.readFileAlloc(io, "hosts.toml", a, .limited(8192));
    defer a.free(optout_encoded);
    try std.testing.expect(std.mem.indexOf(u8, optout_encoded, "unsaved-override") == null);
    try std.testing.expect(std.mem.indexOf(u8, optout_encoded, "credential_ref") == null);
}

test "BMC editor capability temporary password is never persisted and handoff uses the actual new session owner" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    var credential_host = editor_credentials.Host.init(a, io, &secret_store);
    defer credential_host.deinit();
    var fixture: Fixture = .{ .secret_store = &secret_store, .expected_secret = "one-attempt", .defer_secret_acquire = true };
    const manifests = [_]plugins.PluginManifest{fixture.manifest()};
    const renderers = [_]plugins.RendererDefinition{Fixture.renderer()};
    var sessions_host = try sessions.SessionHost.initPlugins(a, &manifests, &renderers);
    defer sessions_host.deinit();
    sessions_host.session_ids.next_value = 81;
    fixture.sessions_host = &sessions_host;
    var harness = try Harness.init(&fixture, .{ .published = .{ .entries = &manifests, .renderers = &renderers } }, &credential_host, null);
    defer harness.deinit();
    const facade = fixture.mounted.?.credentials.?;
    const staged = try facade.prepare("one-attempt", null, false);
    const handoff_value = try facade.handoff(staged);
    try std.testing.expect(staged.reference == null);
    const wrong_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(999) };
    const wrong_operation: operations.OperationKey = .{ .owner = .app, .operation_id = 7 };
    try std.testing.expectError(error.WrongOwner, credential_host.authorizeHandoff(handoff_value, wrong_owner, wrong_operation));
    const events = fixture.mounted.?.events;
    try events.submit_with_secret.?(events.context, Fixture.value(null), .temporary, handoff_value);
    try std.testing.expectEqual(@as(u64, 81), @backingInt(fixture.opened_owner.?.session_id));
    try std.testing.expectEqual(fixture.opened_owner.?, fixture.opened_operation.?.owner.session);
    // Simulate a worker starting after submit returned and the editor stage
    // was wiped. Only the real owner keeps the independently granted bytes.
    try std.testing.expectEqual(@as(usize, 0), fixture.received_secrets);
    try fixture.receive(secret_store.facade(fixture.opened_owner.?), fixture.opened_operation.?, null);
    try std.testing.expectEqual(@as(usize, 1), fixture.received_secrets);
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
    try std.testing.expectEqual(@as(usize, 0), secret_store.defaults.items.len);
    try std.testing.expectError(error.StaleCredentialStage, credential_host.authorizeHandoff(handoff_value, fixture.opened_owner.?, fixture.opened_operation.?));
    try std.testing.expect((try secret_store.facade(fixture.opened_owner.?).acquireDefault(fixture.opened_operation.?, null)) == .missing);
}

test "BMC editor capability clear destroys staged refs and recycles editors without reviving stale facades" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    var host = editor_credentials.Host.init(a, io, &secret_store);
    defer host.deinit();
    const original = try host.bindEditor(1, 1);
    var staged = try original.prepare("cancelled-password", null, true);
    const first_ref = staged.reference.?;
    original.clear();
    try std.testing.expectError(error.CredentialMissing, credentials.get(a, &first_ref));
    staged = try original.prepare("draft-password", null, true);
    const old_handoff = try original.handoff(staged);
    try original.setDraftRevision(2);
    try std.testing.expectError(error.StaleCredentialStage, original.requireHandoff(old_handoff));
    try std.testing.expectError(error.CredentialMissing, credentials.get(a, &staged.reference.?));
    original.destroy();
    for (0..editor_credentials.Host.capacity + 8) |_| {
        const current = try host.bindEditor(1, 1);
        try std.testing.expectError(error.StaleEditorCredentials, original.prepare("stale", null, false));
        _ = try current.prepare("transient", null, false);
        current.destroy();
    }
    try std.testing.expectEqual(@as(usize, 1), host.editors.items.len);
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
}

test "BMC editor capability default leases bind owner attempt cancel and reuse retired facade capacity" {
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    const first: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    const first_operation: operations.OperationKey = .{ .owner = .{ .session = first }, .operation_id = 1, .attempt_id = 1 };
    const original = secret_store.facade(first);
    try secret_store.authorizeDefault(first, first_operation, "leased");
    var result = try original.acquireDefault(first_operation, null);
    try std.testing.expect(result == .lease);
    defer result.lease.deinit();
    try std.testing.expectEqualStrings("leased", try result.lease.defaultBytes(first, first_operation));
    var wrong_attempt = first_operation;
    wrong_attempt.attempt_id = 2;
    try std.testing.expectError(error.SecretLeaseMismatch, result.lease.defaultBytes(first, wrong_attempt));
    const another: identity.SessionHandle = .{ .session_id = @fromBackingInt(2) };
    const another_operation: operations.OperationKey = .{ .owner = .{ .session = another }, .operation_id = 2, .attempt_id = 1 };
    try std.testing.expectError(error.SecretLeaseMismatch, result.lease.defaultBytes(another, another_operation));
    try std.testing.expect((try original.acquireDefault(first_operation, null)) == .missing);
    secret_store.revokeOwner(first);
    var cancelled: std.atomic.Value(bool) = .init(true);
    try secret_store.authorizeDefault(another, another_operation, "cancelled");
    const fresh = secret_store.facade(another);
    var forged = original;
    forged.owner = another;
    try std.testing.expectError(error.WrongOwner, forged.acquireDefault(another_operation, null));
    try std.testing.expect((try fresh.acquireDefault(another_operation, &cancelled)) == .cancelled);
    secret_store.revokeOperation(another_operation);
    try std.testing.expectEqual(@as(usize, 0), secret_store.defaults.items.len);
    secret_store.revokeOwner(another);
    for (3..4106) |index| {
        const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(index) };
        const operation: operations.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = index, .attempt_id = 1 };
        try secret_store.authorizeDefault(owner, operation, "short-lived");
        var acquired = try secret_store.facade(owner).acquireDefault(operation, null);
        try std.testing.expect(acquired == .lease);
        acquired.lease.deinit();
        secret_store.revokeOwner(owner);
    }
    try std.testing.expectEqual(@as(usize, 1), secret_store.facade_contexts.items.len);
    try std.testing.expectError(error.WrongOwner, original.acquireDefault(first_operation, null));
}

test "BMC editor capability probe binds real scopes cancels old drafts and rejects late parent backfill" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    var credential_host = editor_credentials.Host.init(a, io, &secret_store);
    defer credential_host.deinit();
    var fixture: Fixture = .{ .secret_store = &secret_store, .expected_secret = "probe-only", .hold_probe = true };
    const manifests = [_]plugins.PluginManifest{fixture.manifest()};
    const renderers = [_]plugins.RendererDefinition{Fixture.renderer()};
    var sessions_host = try sessions.SessionHost.initPlugins(a, &manifests, &renderers);
    defer sessions_host.deinit();
    sessions_host.session_ids.next_value = 90;
    var probes_host = probe_host.Host.init(a, &sessions_host);
    defer probes_host.deinit() catch unreachable;
    probes_host.credential_host = &credential_host;
    probes_host.context_factory = .{ .context = &fixture, .create = Fixture.probeContext };
    var harness = try Harness.init(&fixture, .{ .published = .{ .entries = &manifests, .renderers = &renderers } }, &credential_host, &probes_host);
    defer harness.deinit();
    const mount_args = fixture.mounted.?;
    const editor = mount_args.probes.?;
    const staged = try mount_args.credentials.?.prepare("probe-only", null, false);
    try mount_args.credentials.?.forProbe(staged);
    const token = try editor.begin(Fixture.value(null), harness.wizard.draft_revision);
    try std.testing.expectEqual(@as(u64, 90), @backingInt(token.handle.session_id));
    try std.testing.expectEqual(token.handle, fixture.active_probe.?.restricted_context.owner);
    try std.testing.expectEqual(editor.parent_editor_operation, token.parent_editor_operation);
    try std.testing.expect(!token.operation.eql(editor.parent_editor_operation));
    mount_args.events.changed(mount_args.events.context);
    var cancelled = try editor.snapshot(token, a);
    defer cancelled.deinit();
    try std.testing.expect(!cancelled.value.applies_to_draft and !cancelled.value.complete);
    try std.testing.expectEqual(probes.CloseReceipt.unknown, cancelled.value.cleanup);
    try std.testing.expect(fixture.active_probe.?.restricted_context.cancelled());
    try std.testing.expectError(error.StaleDraft, editor.begin(Fixture.value(null), token.draft_revision));
    harness.wizard.releaseContributedEditor();
    fixture.late_release = true;
    _ = try probes_host.poll();
    var late = try editor.snapshot(token, a);
    defer late.deinit();
    try std.testing.expect(late.value.complete and !late.value.applies_to_draft);
    try std.testing.expectEqual(probes.Outcome.cancelled, late.value.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
    try std.testing.expectEqual(@as(usize, 0), secret_store.defaults.items.len);
    try std.testing.expectError(error.ProbeEditorDestroyed, editor.begin(Fixture.value(null), 2));
    for (0..probe_host.Host.capacity + 8) |_| try harness.wizard.reset();
    try std.testing.expectEqual(@as(usize, 1), probes_host.editors.items.len);
    try std.testing.expectEqual(@as(usize, 1), credential_host.editors.items.len);
}
