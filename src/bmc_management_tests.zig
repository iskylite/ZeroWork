//! Management fixtures only. No real endpoint or user-data store is opened.
const std = @import("std");
const model = @import("plugins/bmc_ikvm/model.zig");
const codec = @import("plugins/bmc_ikvm/codec.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const redfish = @import("plugins/bmc_ikvm/protocol/redfish.zig");
const auth = @import("plugins/bmc_ikvm/protocol/auth.zig");
const power = @import("plugins/bmc_ikvm/protocol/power.zig");
const boot = @import("plugins/bmc_ikvm/protocol/boot.zig");
const journal = @import("plugins/bmc_ikvm/management_journal.zig");
const a = std.testing.allocator;
const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(77), .generation = 3 };
fn execution(id: u64) svc.Execution {
    return .{ .call = .{ .owner = owner, .binding_generation = 1 }, .operation = .{ .owner = .{ .session = owner }, .operation_id = id }, .nonce = @splat(@intCast(id)), .system_uri = "/redfish/v1/Systems/node-A", .capability_revision = 4, .grant_revision = 5 };
}
const capability: svc.Capability = .{ .revision = 4, .grant_revision = 5, .binding_generation = 1, .system_mapping_verified = true, .write_granted = true, .secondary_auth = .disabled, .secondary_auth_evidence = .{ .source_uri = "/redfish/v1/Managers/B/SecurityService", .collected_ms = 100, .validity = .valid } };
const evidence: svc.Evidence = .{ .source_uri = "/redfish/v1/Systems/node-A", .collected_ms = 100, .validity = .valid };
const boot_state: svc.BootState = .{ .enabled = "Disabled", .target = "None", .mode = "UEFI" };
fn snapshots() struct { p: svc.PowerSnapshot, b: svc.BootSnapshot } {
    return .{
        .p = .{ .system_uri = execution(1).system_uri, .system_identity = "fixture-system-uuid", .capability = capability, .state = .{ .value = .on, .evidence = evidence }, .reset_types = .{ .value = &.{ "On", "GracefulShutdown", "GracefulRestart", "ForceOff", "ForceRestart", "PowerCycle", "Nmi", "ForceOn" }, .evidence = evidence }, .reset_target = "/redfish/v1/Systems/node-A/Actions/ComputerSystem.Reset", .etag = "\"rev1\"" },
        .b = .{ .system_uri = execution(1).system_uri, .system_identity = "fixture-system-uuid", .write_uri = execution(1).system_uri, .capability = capability, .state = boot_state, .enabled_evidence = evidence, .target_evidence = evidence, .mode_evidence = evidence, .allowed_enabled = .{ .value = &.{ "Disabled", "Once", "Continuous" }, .evidence = evidence }, .allowed_targets = .{ .value = &.{ "None", "Pxe", "Hdd", "Cd", "Diags", "BiosSetup", "Usb", "UefiBootNext" }, .evidence = evidence }, .allowed_modes = .{ .value = &.{ "UEFI", "Legacy" }, .evidence = evidence }, .etag = "\"rev1\"" },
    };
}
const system_on =
    \\{"Id":"node-A","UUID":"fixture-system-uuid","PowerState":"On","Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/node-A/Actions/ComputerSystem.Reset","ResetType@Redfish.AllowableValues":["On","ForceOff","ForceRestart","GracefulRestart","GracefulShutdown","PowerCycle"]}},"Boot":{"BootSourceOverrideEnabled":"Disabled","BootSourceOverrideTarget":"None","BootSourceOverrideMode":"UEFI","BootSourceOverrideEnabled@Redfish.AllowableValues":["Disabled","Once","Continuous"],"BootSourceOverrideTarget@Redfish.AllowableValues":["None","Pxe","Hdd"],"BootSourceOverrideMode@Redfish.AllowableValues":["UEFI","Legacy"],"BootOrder":["Boot0001","Boot0002"],"AliasBootOrder":["Hdd","Pxe"],"BootOptions":{"@odata.id":"/redfish/v1/Systems/node-A/BootOptions"}},"Links":{"ManagedBy":[{"@odata.id":"/redfish/v1/Managers/B"}]}}
;
const system_off =
    \\{"Id":"node-A","UUID":"fixture-system-uuid","PowerState":"Off","Boot":{"BootSourceOverrideEnabled":"Disabled","BootSourceOverrideTarget":"None","BootSourceOverrideMode":"UEFI"}}
;
const gate: power.Gate = .{ .owner = owner, .binding_generation = 1, .capability_revision = 4, .grant_revision = 5, .authenticated = true, .write_granted = true };
const TestArbiter = struct {
    held: bool = false,
    valid: bool = true,
    releases: usize = 0,
    fn api(self: *TestArbiter) power.Arbiter {
        return .{ .context = self, .acquire = acquire, .revalidate = revalidate, .release = release };
    }
    fn acquire(raw: *anyopaque, key: []const u8, _: svc.Execution) !u64 {
        const self: *TestArbiter = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, key, "bmc.invalid:443|fixture-system-uuid")) return error.InvalidResource;
        if (self.held) return error.ResourceBusy;
        self.held = true;
        return 1;
    }
    fn revalidate(raw: *anyopaque, _: u64, _: svc.Execution) bool {
        const self: *TestArbiter = @ptrCast(@alignCast(raw));
        return self.held and self.valid;
    }
    fn release(raw: *anyopaque, _: u64) void {
        const self: *TestArbiter = @ptrCast(@alignCast(raw));
        self.held = false;
        self.releases += 1;
    }
};
fn initEngine(log: *journal.Journal, arbiter: *TestArbiter) !power.Engine {
    var value = try power.Engine.init(a, owner, .{ .authority = "bmc.invalid:443" }, log, arbiter.api());
    errdefer value.deinit();
    const values = snapshots();
    try value.setSnapshots(values.p, values.b);
    return value;
}

test "BMC payload defaults strict secrets route uniqueness and codec GC ownership" {
    var parsed = try model.parse(a, "{\"endpoint\":{\"host\":\"bmc.invalid\"},\"username\":\"operator\"}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 443), parsed.value().endpoint.https_port);
    try std.testing.expect(parsed.value().access == .direct);
    try std.testing.expectError(error.UnknownField, model.validatePayload("{\"endpoint\":{\"host\":\"bmc.invalid\"},\"username\":\"operator\",\"password\":\"fixture\"}"));
    try std.testing.expectError(error.DuplicateRoute, model.validate(.{ .endpoint = .{ .host = "bmc.invalid" }, .username = "u", .access = .{ .ssh_route = .{ .hops = &.{ .{ .asset_id = 1 }, .{ .asset_id = 1 } } } } }));
    try std.testing.expectError(error.InvalidEndpoint, model.validate(.{ .endpoint = .{ .host = "https://bmc.invalid" }, .username = "u" }));
    const reference = "zw1_" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const payload = try std.json.Stringify.valueAlloc(a, model.Payload{ .endpoint = .{ .host = "bmc.invalid" }, .username = "u", .credential_ref = reference, .access = .{ .ssh_route = .{ .hops = &.{.{ .asset_id = 9 }} } } }, .{});
    defer a.free(payload);
    const refs = try codec.credentialReferences(a, payload);
    defer {
        for (refs) |ref| a.free(ref);
        a.free(refs);
    }
    try std.testing.expectEqualStrings(reference, refs[0]);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const encoded = try codec.encode(arena.allocator(), .{ .protocol_id = model.protocol_id, .name = "BMC", .payload = payload });
    const decoded = try codec.decode(arena.allocator(), encoded);
    try std.testing.expectEqualStrings(encoded.payload, decoded.payload);
    try std.testing.expectError(error.UnsupportedPayloadVersion, codec.migrate(arena.allocator(), encoded, 2));
}

test "BMC same origin paths pagination and field-level body errors fail closed" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const origin = try redfish.Origin.init(alloc, .{ .host = "BMC.invalid" });
    try std.testing.expectEqualStrings("bmc.invalid:443", origin.authority);
    try std.testing.expectEqualStrings("/redfish/v1/Systems/X", try redfish.resourceUri(alloc, origin, "https://bmc.invalid/redfish/v1/Systems/X"));
    for ([_][]const u8{ "https://evil.invalid/redfish/v1/", "/redfish/v1/../Managers", "/redfish/v1/%2e%2e/Managers", "//evil.invalid/redfish/v1/", "/redfish/v1x/Systems", "/redfish/v1/Systems/X#secret" }) |bad| try std.testing.expectError(if (std.mem.startsWith(u8, bad, "https:")) error.CrossOriginResource else error.InvalidResourceUri, redfish.resourceUri(alloc, origin, bad));
    var doc = try redfish.Document.parse(a, execution(1).system_uri, 200, system_on, "\"a\"", 100);
    defer doc.deinit();
    const system = try redfish.parseSystem(alloc, origin, doc);
    try std.testing.expect(system.power.state.evidence.permitsWrite());
    try std.testing.expectEqual(@as(usize, 2), system.boot.boot_order.value.?.len);
    var partial = try redfish.Document.parse(a, "/redfish/v1/Systems/X", 200, "{\"PowerState\":\"On\",\"error\":{\"code\":\"Base.Error\"}}", null, 200);
    defer partial.deinit();
    const partial_system = try redfish.parseSystem(alloc, origin, partial);
    try std.testing.expectEqual(svc.PowerState.on, partial_system.power.state.value.?);
    try std.testing.expect(!partial_system.power.state.evidence.permitsWrite());
    try std.testing.expect(!partial.accepted());
    var extended = try redfish.Document.parse(a, "/redfish/v1/Tasks/X", 200, "{\"@Message.ExtendedInfo\":[{\"MessageSeverity\":\"Critical\"}]}", null, 0);
    defer extended.deinit();
    try std.testing.expect(!extended.accepted());
}

test "BMC discovery requires independent KVM manager evidence and reciprocal unique mapping" {
    var discovery = try redfish.Discovery.init(a, .{ .host = "bmc.invalid" });
    defer discovery.deinit();
    const root = discovery.next().?;
    try discovery.ingest(root, 200, "{\"Systems\":{\"@odata.id\":\"/redfish/v1/Systems\"},\"Managers\":{\"@odata.id\":\"/redfish/v1/Managers\"},\"SessionService\":{\"@odata.id\":\"/redfish/v1/SessionService\"}}", null, 1);
    while (discovery.next()) |request| {
        const body = switch (request.kind) {
            .systems => "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Systems/node-A\"}]}",
            .managers => "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}",
            .system => system_on,
            .manager => "{\"Links\":{\"ManagerForServers\":[{\"@odata.id\":\"/redfish/v1/Systems/node-A\"}]},\"SecurityService\":{\"@odata.id\":\"/redfish/v1/Managers/B/SecurityService\"}}",
            .security => "{\"EnableAuthConfirm\":false}",
            .boot_options => "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Systems/node-A/BootOptions/A\"},{\"@odata.id\":\"/redfish/v1/Systems/node-A/BootOptions/B\"}]}",
            .boot_option => "{\"Id\":\"A\",\"BootOptionReference\":\"Boot0001\",\"DisplayName\":\"Unknown vendor device\"}",
            else => "{}",
        };
        try discovery.ingest(request, 200, body, null, 100);
    }
    var selected = try discovery.system(execution(1).system_uri, capability);
    try std.testing.expect(!selected.power.capability.system_mapping_verified);
    try std.testing.expectEqual(@as(usize, 1), selected.boot.options.len);
    try std.testing.expectError(error.MappingUnverified, discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", false));
    try discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true);
    selected = try discovery.system(execution(1).system_uri, capability);
    try std.testing.expect(selected.power.capability.system_mapping_verified);
    try std.testing.expectEqual(svc.SecondaryAuth.disabled, selected.power.capability.secondary_auth);
}

test "BMC authentication refuses missing evidence and wipes each owned secret" {
    const Fake = struct {
        fn encrypt(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
            return alloc.dupe(u8, &(@as([256]u8, @splat(7))));
        }
    };
    var context: u8 = 0;
    const encryptor: auth.Encryptor = .{ .context = &context, .encrypt_rsa2048_pkcs1v15 = Fake.encrypt };
    try std.testing.expectError(error.AuthenticationEvidenceUnavailable, auth.webLogin(a, .{}, encryptor, "fixture", "synthetic-input"));
    var storage: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var secret = try auth.Secret.init(fixed.allocator(), "synthetic-fixture-token");
    const len = secret.bytes.len;
    secret.clear();
    try std.testing.expect(std.mem.allEqual(u8, storage[0..len], 0));
    secret.deinit();
    var doc = try redfish.Document.parse(a, "/redfish/v1/SessionService/Sessions", 201, "{\"Id\":\"fixture-session\"}", null, 1);
    defer doc.deinit();
    var session = try auth.acceptWebSession(a, .{ .authority = "bmc.invalid:443" }, owner, doc, "fixture-web-token", "/redfish/v1/SessionService/Sessions/fixture-session");
    defer session.deinit();
    try std.testing.expectError(error.AuthenticationEvidenceUnavailable, auth.kvmLogin(a, .{}, session, owner));
    try std.testing.expectError(error.CrossOriginResource, auth.acceptWebSession(a, .{ .authority = "bmc.invalid:443" }, owner, doc, "fixture-web-token", "https://evil.invalid/redfish/v1/SessionService/Sessions/fixture-session"));
}

fn syntheticKvmAuthEvidence() auth.Evidence {
    const pem = "synthetic-public-key-for-session-schema-fixtures";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pem, &digest, .{});
    return .{ .profile_id = "synthetic-session-schema", .firmware = "fixture", .public_key_pem = pem, .public_key_sha256 = digest, .source_uri = "fixture", .verified = true, .web_headers_verified = true, .kvm_schema_verified = true };
}

test "BMC OEM KVM session owns its response header token and separate body Id" {
    const session_evidence = syntheticKvmAuthEvidence();
    var web_doc = try redfish.Document.parse(a, "/redfish/v1/SessionService/Sessions", 201, "{\"Id\":\"fixture-web-session\"}", null, 1);
    defer web_doc.deinit();
    var web_session = try auth.acceptWebSession(a, .{ .authority = "bmc.invalid:443" }, owner, web_doc, "fixture-web-token", "/redfish/v1/SessionService/Sessions/fixture-web-session");
    defer web_session.deinit();
    // Sanitized observed field shape: token is a response header, while Id and
    // OEM privilege metadata are in JSON. This fixture contains no real token.
    var kvm_doc = try redfish.Document.parse(a, "/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions", 201, "{\"Id\":\"fixture-kvm-session\",\"OemPrivileges\":{}}", null, 2);
    var header_token = "fixture-kvm-header-token".*;
    var kvm_session = auth.acceptKvmSessionHeader(a, session_evidence, owner, kvm_doc, &header_token, null) catch |err| {
        kvm_doc.deinit();
        return err;
    };
    defer kvm_session.deinit();
    kvm_doc.deinit();
    header_token[0] = 'x';
    try std.testing.expectEqualStrings("fixture-kvm-header-token", kvm_session.token.bytes);
    try std.testing.expectEqualStrings("fixture-kvm-session", kvm_session.id.?.bytes);
    try std.testing.expect(!std.mem.eql(u8, kvm_session.token.bytes, web_session.token.bytes));
    try std.testing.expect(!std.mem.eql(u8, kvm_session.id.?.bytes, web_session.id.bytes));
    try std.testing.expect(kvm_session.owner.eql(owner));
}

test "BMC OEM KVM header is required validated and never replaced with a body token" {
    const session_evidence = syntheticKvmAuthEvidence();
    var doc = try redfish.Document.parse(a, "/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions", 201, "{\"Id\":\"fixture-kvm-session\",\"OemPrivileges\":{},\"Token\":\"fixture-web-token\"}", null, 1);
    defer doc.deinit();
    try std.testing.expectError(error.MissingKvmToken, auth.acceptKvmSessionHeader(a, session_evidence, owner, doc, null, "Id"));
    for ([_][]const u8{ "", "fixture token", "fixture,token", "fixture/token", "fixture\r\nX-Other:value", "fixture\x00token" }) |invalid| {
        try std.testing.expectError(error.InvalidKvmToken, auth.acceptKvmSessionHeader(a, session_evidence, owner, doc, invalid, "Id"));
    }
    const oversized: [4097]u8 = @splat('a');
    try std.testing.expectError(error.InvalidKvmToken, auth.acceptKvmSessionHeader(a, session_evidence, owner, doc, &oversized, "Id"));
    var session = try auth.acceptKvmSessionHeader(a, session_evidence, owner, doc, "fixture-oem-response-token", "Id");
    defer session.deinit();
    try std.testing.expectEqualStrings("fixture-oem-response-token", session.token.bytes);
    try std.testing.expectError(error.AuthenticationEvidenceUnavailable, auth.acceptKvmSessionHeader(a, .{}, owner, doc, "fixture-oem-response-token", "Id"));
    var missing_id = try redfish.Document.parse(a, "/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions", 201, "{\"OemPrivileges\":{}}", null, 1);
    defer missing_id.deinit();
    try std.testing.expectError(error.MissingKvmSessionId, auth.acceptKvmSessionHeader(a, session_evidence, owner, missing_id, "fixture-oem-response-token", null));
    var invalid_id = try redfish.Document.parse(a, "/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions", 201, "{\"Id\":\"../other\"}", null, 1);
    defer invalid_id.deinit();
    try std.testing.expectError(error.InvalidKvmSessionId, auth.acceptKvmSessionHeader(a, session_evidence, owner, invalid_id, "fixture-oem-response-token", "Id"));
    var error_doc = try redfish.Document.parse(a, "/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions", 201, "{\"Id\":\"fixture-kvm-session\",\"error\":{\"code\":\"Base.1.19.Success\",\"@Message.ExtendedInfo\":[{\"Severity\":\"OK\"}]}}", null, 1);
    defer error_doc.deinit();
    try std.testing.expectError(error.KvmAuthenticationFailed, auth.acceptKvmSessionHeader(a, session_evidence, owner, error_doc, "fixture-oem-response-token", "Id"));
}

test "BMC explicit synthetic KVM body token schema remains supported" {
    var doc = try redfish.Document.parse(a, "/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions", 201, "{\"SyntheticId\":\"fixture-body-session\",\"SyntheticToken\":\"fixture-body-token\"}", null, 1);
    defer doc.deinit();
    var session = try auth.acceptKvmSession(a, syntheticKvmAuthEvidence(), owner, doc, "SyntheticToken", "SyntheticId");
    defer session.deinit();
    try std.testing.expectEqualStrings("fixture-body-token", session.token.bytes);
    try std.testing.expectEqualStrings("fixture-body-session", session.id.?.bytes);
    try std.testing.expectError(error.MissingKvmToken, auth.acceptKvmSessionHeader(a, syntheticKvmAuthEvidence(), owner, doc, null, "SyntheticId"));
}

test "BMC journal durable dedupe conflict and crash recovery prohibit redispatch" {
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var log = try journal.Journal.init(a, memory.backend());
    const ex = execution(1);
    const first = try log.reserve(ex, "https://bmc.invalid:443/redfish/v1/Systems/node-A", "fixture-system-uuid", .{ .power = .force_off }, .{ .power = .on });
    const duplicate = try log.reserve(ex, "https://bmc.invalid:443/redfish/v1/Systems/node-A", "fixture-system-uuid", .{ .power = .force_off }, .{ .power = .off });
    try std.testing.expect(duplicate.existing);
    try std.testing.expectEqual(first.index, duplicate.index);
    try std.testing.expectError(error.OperationConflict, log.reserve(ex, "https://bmc.invalid:443/redfish/v1/Systems/node-A", "fixture-system-uuid", .{ .power = .force_restart }, .{}));
    try log.beginDispatch(first.index);
    try std.testing.expect(std.mem.indexOf(u8, memory.bytes.?, "\"dispatch_started\":true") != null);
    log.deinit();
    var recovered = try journal.Journal.init(a, memory.backend());
    defer recovered.deinit();
    try std.testing.expectEqual(svc.Phase.outcome_unknown, recovered.entries[0].phase);
    try std.testing.expectError(error.OperationAlreadyDispatched, recovered.beginDispatch(0));
}

test "BMC file journal uses isolated temporary directory and reopens durable schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file: journal.FileBackend = .{ .io = std.testing.io, .dir = tmp.dir, .filename = "management-fixture.json" };
    var log = try journal.Journal.init(a, try file.backend());
    _ = try log.reserve(execution(1), "https://bmc.invalid:443/redfish/v1/Systems/node-A", "fixture-system-uuid", .{ .power = .force_off }, .{ .power = .on });
    try log.beginDispatch(0);
    log.deinit();
    var reopened = try journal.Journal.init(a, try file.backend());
    defer reopened.deinit();
    try std.testing.expectEqual(svc.Phase.outcome_unknown, reopened.entries[0].phase);
    const stat = try tmp.dir.statFile(std.testing.io, "management-fixture.json", .{});
    try std.testing.expectEqual(@as(u16, 0o600), @as(u16, @intCast(@backingInt(stat.permissions) & 0o777)));
}

test "BMC power durable dispatch verifies state and never repeats a completed write" {
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var log = try journal.Journal.init(a, memory.backend());
    defer log.deinit();
    var arbiter: TestArbiter = .{};
    var engine_value = try initEngine(&log, &arbiter);
    defer engine_value.deinit();
    const key = try engine_value.requestPower(.{ .execution = execution(1), .action = .force_off }, 200);
    const write = (try engine_value.next(200, gate)).?;
    try std.testing.expectEqual(power.Method.post, write.method);
    try std.testing.expectEqualStrings("{\"ResetType\":\"ForceOff\"}", write.body);
    try std.testing.expect(log.entries[0].dispatch_started);
    try engine_value.complete(.{ .sequence = write.sequence, .status = 204 }, 201);
    const verify = (try engine_value.next(1201, gate)).?;
    try std.testing.expectEqual(power.Method.get, verify.method);
    try engine_value.complete(.{ .sequence = verify.sequence, .status = 200, .body = system_off }, 1202);
    try std.testing.expectEqual(svc.Phase.succeeded, (try engine_value.result(key)).phase);
    try std.testing.expectEqual(@as(usize, 1), arbiter.releases);
    try std.testing.expect((try engine_value.next(9999, gate)) == null);
    _ = try engine_value.requestPower(.{ .execution = execution(1), .action = .force_off }, 9999);
    try std.testing.expect((try engine_value.next(9999, gate)) == null);
    const binding = engine_value.powerBinding(1);
    const iface = try binding.borrow(svc.PowerService, svc.power_key, owner);
    var snapshot = try iface.snapshot(binding.context, execution(1).call, a);
    defer snapshot.deinit();
    var outcome = try iface.result(binding.context, execution(1).call, key, a);
    defer outcome.deinit();
    try std.testing.expectEqual(svc.Phase.succeeded, outcome.value.phase);
}

test "BMC journal failure stale grant and resource revocation send zero writes" {
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var log = try journal.Journal.init(a, memory.backend());
    defer log.deinit();
    var arbiter: TestArbiter = .{};
    var engine_value = try initEngine(&log, &arbiter);
    defer engine_value.deinit();
    _ = try engine_value.requestPower(.{ .execution = execution(1), .action = .force_off }, 200);
    memory.fail_writes = true;
    try std.testing.expectError(error.InjectedJournalFailure, engine_value.next(200, gate));
    try std.testing.expect(!log.entries[0].dispatch_started);
    memory.fail_writes = false;
    var changed_gate = gate;
    changed_gate.grant_revision += 1;
    try std.testing.expect((try engine_value.next(201, changed_gate)) == null);
    try std.testing.expectEqual(svc.Phase.failed, (try engine_value.result(execution(1).operation)).phase);
    _ = try engine_value.requestPower(.{ .execution = execution(2), .action = .force_off }, 200);
    arbiter.valid = false;
    try std.testing.expect((try engine_value.next(200, gate)) == null);
    try std.testing.expect(!log.entries[1].dispatch_started);
}

test "BMC body errors cancellation transport uncertainty and restart On are never success" {
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var log = try journal.Journal.init(a, memory.backend());
    defer log.deinit();
    var arbiter: TestArbiter = .{};
    var engine_value = try initEngine(&log, &arbiter);
    defer engine_value.deinit();
    const key1 = try engine_value.requestPower(.{ .execution = execution(1), .action = .force_off }, 200);
    try std.testing.expectEqual(svc.CancelResult.cancelled_unsent, engine_value.cancel(key1));
    _ = try engine_value.requestPower(.{ .execution = execution(2), .action = .force_off }, 200);
    var write = (try engine_value.next(200, gate)).?;
    try engine_value.complete(.{ .sequence = write.sequence, .status = 200, .body = "{\"error\":{\"code\":\"Base.Error\"}}" }, 201);
    try std.testing.expectEqual(svc.Phase.failed, (try engine_value.result(execution(2).operation)).phase);
    _ = try engine_value.requestPower(.{ .execution = execution(3), .action = .force_restart }, 200);
    write = (try engine_value.next(200, gate)).?;
    try engine_value.complete(.{ .sequence = write.sequence, .status = 204 }, 201);
    const verify = (try engine_value.next(1201, gate)).?;
    try engine_value.complete(.{ .sequence = verify.sequence, .status = 200, .body = system_on }, 1202);
    try std.testing.expectEqual(svc.Phase.outcome_unknown, (try engine_value.result(execution(3).operation)).phase);
    try std.testing.expectEqual(svc.Reason.accepted_unverified, (try engine_value.result(execution(3).operation)).reason.?);
    try engine_value.query(execution(3).operation, 2000);
    const query = (try engine_value.next(2000, gate)).?;
    try std.testing.expectEqual(power.Method.get, query.method);
    try std.testing.expectEqual(svc.CancelResult.observation_stopped_remote_may_continue, engine_value.cancel(query.operation));
}

test "BMC 202 tracks same origin task then verifies restart and respects Retry-After" {
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var log = try journal.Journal.init(a, memory.backend());
    defer log.deinit();
    var arbiter: TestArbiter = .{};
    var engine_value = try initEngine(&log, &arbiter);
    defer engine_value.deinit();
    const key = try engine_value.requestPower(.{ .execution = execution(1), .action = .force_restart }, 200);
    const write = (try engine_value.next(200, gate)).?;
    try engine_value.complete(.{ .sequence = write.sequence, .status = 202, .body = "{}", .location = "/redfish/v1/TaskService/TaskMonitors/fixture", .retry_after_ms = 3000 }, 201);
    try std.testing.expect((try engine_value.next(3200, gate)) == null);
    const task = (try engine_value.next(3201, gate)).?;
    try engine_value.complete(.{ .sequence = task.sequence, .status = 200, .body = "{\"TaskState\":\"Completed\"}" }, 3202);
    const verify = (try engine_value.next(4202, gate)).?;
    try engine_value.complete(.{ .sequence = verify.sequence, .status = 200, .body = system_on }, 4203);
    try std.testing.expectEqual(svc.Phase.succeeded, (try engine_value.result(key)).phase);
}

test "BMC Boot Disabled emits one field no reboot and no ETag requires fresh compare" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var values = snapshots();
    values.b.state = .{ .enabled = "Once", .target = "Pxe", .mode = "UEFI" };
    const prepared = try boot.prepare(arena.allocator(), values.b, .{ .execution = execution(1), .baseline = values.b.state, .enabled = "Disabled", .target = "Hdd", .mode = "Legacy", .etag = values.b.etag });
    try std.testing.expectEqualStrings("{\"Boot\":{\"BootSourceOverrideEnabled\":\"Disabled\"}}", prepared.body);
    try std.testing.expectError(error.UnchangedBoot, boot.prepare(arena.allocator(), values.b, .{ .execution = execution(1), .baseline = values.b.state, .enabled = "Once", .etag = values.b.etag }));
    try std.testing.expectError(error.UnsupportedBootValue, boot.prepare(arena.allocator(), values.b, .{ .execution = execution(1), .baseline = values.b.state, .target = "UefiBootNext", .etag = values.b.etag }));
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var log = try journal.Journal.init(a, memory.backend());
    defer log.deinit();
    var arbiter: TestArbiter = .{};
    var engine_value = try initEngine(&log, &arbiter);
    defer engine_value.deinit();
    values = snapshots();
    values.b.etag = null;
    try engine_value.setSnapshots(values.p, values.b);
    const key = try engine_value.applyBoot(.{ .execution = execution(1), .baseline = boot_state, .enabled = "Once", .target = "Pxe" }, 200);
    const refresh = (try engine_value.next(200, gate)).?;
    try std.testing.expectEqual(power.Purpose.refresh, refresh.purpose);
    try std.testing.expect(!log.entries[0].dispatch_started);
    try engine_value.complete(.{ .sequence = refresh.sequence, .status = 200, .body = system_on }, 201);
    const write = (try engine_value.next(1201, gate)).?;
    try std.testing.expectEqual(power.Method.patch, write.method);
    try std.testing.expect(std.mem.indexOf(u8, write.body, "BootOrder") == null);
    try engine_value.complete(.{ .sequence = write.sequence, .status = 412 }, 1202);
    try std.testing.expectEqual(svc.Reason.conflict, (try engine_value.result(key)).reason.?);
    const current = (try engine_value.next(1203, gate)).?;
    try std.testing.expectEqual(power.Purpose.conflict_refresh, current.purpose);
    try std.testing.expectEqual(power.Method.get, current.method);
    try engine_value.complete(.{ .sequence = current.sequence, .status = 200, .body = system_on, .etag = "\"rev2\"" }, 1204);
    try std.testing.expectEqual(svc.Phase.failed, (try engine_value.result(key)).phase);
    try std.testing.expect((try engine_value.next(9999, gate)) == null);
}

test "BMC secondary auth is operation-bound and never persisted or bypassed" {
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var log = try journal.Journal.init(a, memory.backend());
    defer log.deinit();
    var arbiter: TestArbiter = .{};
    var engine_value = try initEngine(&log, &arbiter);
    defer engine_value.deinit();
    var values = snapshots();
    values.p.capability.secondary_auth = .unknown;
    try engine_value.setSnapshots(values.p, values.b);
    try std.testing.expectError(error.SecondaryAuthUnknown, engine_value.requestPower(.{ .execution = execution(1), .action = .force_off }, 200));
    try std.testing.expectEqual(@as(usize, 0), memory.writes);
    values.p.capability.secondary_auth = .required;
    values.b.capability.secondary_auth = .required;
    try engine_value.setSnapshots(values.p, values.b);
    const key = try engine_value.requestPower(.{ .execution = execution(1), .action = .force_off }, 200);
    try std.testing.expectEqual(svc.Phase.awaiting_auth, (try engine_value.result(key)).phase);
    try std.testing.expect((try engine_value.next(200, gate)) == null);
    const Fake = struct {
        fn encrypt(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
            return alloc.dupe(u8, &(@as([256]u8, @splat(7))));
        }
    };
    var context: u8 = 0;
    const pem = "synthetic-public-key-fixture";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pem, &digest, .{});
    const proof_evidence: auth.Evidence = .{ .profile_id = "synthetic", .firmware = "fixture", .public_key_pem = pem, .public_key_sha256 = digest, .source_uri = "fixture", .verified = true, .web_headers_verified = true, .secondary_auth_verified = true };
    var proof = try auth.secondaryProof(a, proof_evidence, .{ .context = &context, .encrypt_rsa2048_pkcs1v15 = Fake.encrypt }, execution(1), "synthetic-confirmation");
    proof.nonce[0] ^= 1;
    try std.testing.expectError(error.StaleOperation, engine_value.supplySecondary(&proof));
    proof.nonce[0] ^= 1;
    try engine_value.supplySecondary(&proof);
    const write = (try engine_value.next(201, gate)).?;
    try std.testing.expectEqual(@as(usize, 344), write.authkey.?.len);
    try std.testing.expect(std.mem.indexOf(u8, memory.bytes.?, "synthetic-confirmation") == null);
    try std.testing.expect(std.mem.indexOf(u8, memory.bytes.?, "AUTHKEY") == null);
    try engine_value.complete(.{ .sequence = write.sequence, .status = 401 }, 202);
    try std.testing.expectEqual(svc.Phase.failed, (try engine_value.result(key)).phase);
    try std.testing.expect(!engine_value.power.value.capability.write_granted);
    try std.testing.expect(engine_value.active.?.authkey == null);
}

test "BMC actual dispatch rechecks five second freshness and in-flight timeout" {
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var log = try journal.Journal.init(a, memory.backend());
    defer log.deinit();
    var arbiter: TestArbiter = .{};
    var engine_value = try initEngine(&log, &arbiter);
    defer engine_value.deinit();
    const key = try engine_value.requestPower(.{ .execution = execution(1), .action = .force_off }, 200);
    const refresh = (try engine_value.next(6000, gate)).?;
    try std.testing.expectEqual(power.Purpose.refresh, refresh.purpose);
    try std.testing.expect(!log.entries[0].dispatch_started);
    try engine_value.complete(.{ .sequence = refresh.sequence, .status = 200, .body = system_on, .etag = "\"rev1\"" }, 6001);
    const write = (try engine_value.next(7001, gate)).?;
    try std.testing.expectEqual(power.Method.post, write.method);
    try std.testing.expect((try engine_value.next(60_201, gate)) == null);
    try std.testing.expectEqual(svc.Phase.outcome_unknown, (try engine_value.result(key)).phase);
    try std.testing.expectError(error.StaleCompletion, engine_value.complete(.{ .sequence = write.sequence, .status = 204 }, 60_202));
    _ = try engine_value.requestPower(.{ .execution = execution(1), .action = .force_off }, 60_203);
    try std.testing.expect((try engine_value.next(60_203, gate)) == null);
    try std.testing.expectError(error.OperationConflict, engine_value.requestPower(.{ .execution = execution(1), .action = .force_restart }, 60_203));
}

test "BMC Boot applied and pending values remain distinct without reboot" {
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var log = try journal.Journal.init(a, memory.backend());
    defer log.deinit();
    var arbiter: TestArbiter = .{};
    var engine_value = try initEngine(&log, &arbiter);
    defer engine_value.deinit();
    const key = try engine_value.applyBoot(.{ .execution = execution(1), .baseline = boot_state, .enabled = "Once", .target = "Pxe", .etag = "\"rev1\"" }, 200);
    const write = (try engine_value.next(200, gate)).?;
    try std.testing.expectEqual(power.Method.patch, write.method);
    try engine_value.complete(.{ .sequence = write.sequence, .status = 204 }, 201);
    const read = (try engine_value.next(1201, gate)).?;
    const settings_current = "{\"Id\":\"node-A\",\"UUID\":\"fixture-system-uuid\",\"PowerState\":\"On\",\"Boot\":{\"BootSourceOverrideEnabled\":\"Disabled\",\"BootSourceOverrideTarget\":\"None\",\"BootSourceOverrideMode\":\"UEFI\"},\"@Redfish.Settings\":{\"SettingsObject\":{\"@odata.id\":\"/redfish/v1/Systems/node-A/Settings\"}}}";
    try engine_value.complete(.{ .sequence = read.sequence, .status = 200, .body = settings_current }, 1202);
    const pending = (try engine_value.next(2202, gate)).?;
    try std.testing.expectEqual(power.Method.get, pending.method);
    try std.testing.expectEqual(power.Purpose.pending_verify, pending.purpose);
    try engine_value.complete(.{ .sequence = pending.sequence, .status = 200, .body = "{\"Boot\":{\"BootSourceOverrideEnabled\":\"Once\",\"BootSourceOverrideTarget\":\"Pxe\",\"BootSourceOverrideMode\":\"UEFI\"}}" }, 2203);
    const outcome = try engine_value.result(key);
    try std.testing.expectEqual(svc.Phase.outcome_unknown, outcome.phase);
    try std.testing.expectEqual(svc.Reason.pending, outcome.reason.?);
    try std.testing.expectEqualStrings("Disabled", outcome.current_boot.?.enabled.?);
    try std.testing.expectEqualStrings("Once", outcome.pending_boot.?.enabled.?);
    try std.testing.expectEqualStrings("Once", log.entries[0].result().pending_boot.?.enabled.?);
    try std.testing.expect((try engine_value.next(5000, gate)) == null);
}

test "BMC paginated collections reject cycles and cross-origin next links" {
    var discovery = try redfish.Discovery.init(a, .{ .host = "bmc.invalid" });
    defer discovery.deinit();
    const root = discovery.next().?;
    try discovery.ingest(root, 200, "{\"Systems\":{\"@odata.id\":\"/redfish/v1/Systems\"},\"Managers\":{\"@odata.id\":\"/redfish/v1/Managers\"},\"SessionService\":{\"@odata.id\":\"/redfish/v1/SessionService\"}}", null, 0);
    const systems = discovery.next().?;
    try discovery.ingest(systems, 200, "{\"Members\":[],\"Members@odata.nextLink\":\"/redfish/v1/Systems?$skip=1\"}", null, 0);
    var next_page: ?redfish.ReadRequest = null;
    while (discovery.next()) |request| {
        if (request.kind == .systems) {
            next_page = request;
            break;
        }
        try discovery.ingest(request, 200, if (request.kind == .managers) "{\"Members\":[]}" else "{}", null, 0);
    }
    try std.testing.expect(next_page != null);
    try std.testing.expectError(error.PaginationCycle, discovery.ingest(next_page.?, 200, "{\"Members\":[],\"Members@odata.nextLink\":\"/redfish/v1/Systems\"}", null, 0));
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var doc = try redfish.Document.parse(a, "/redfish/v1/Systems", 200, "{\"Members\":[],\"Members@odata.nextLink\":\"https://evil.invalid/redfish/v1/Systems?$skip=1\"}", null, 0);
    defer doc.deinit();
    try std.testing.expectError(error.CrossOriginResource, redfish.parseCollection(arena.allocator(), discovery.origin, doc));
}

test "BMC recovered query owns all current and pending Boot fields across journal replacements" {
    var memory: journal.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var poisoned: PoisonFreedAllocator = .{ .base = a };
    defer poisoned.deinit();
    var log = try journal.Journal.init(poisoned.allocator(), memory.backend());
    defer log.deinit();
    const ex = execution(61);
    const current: svc.BootState = .{ .enabled = "Once", .target = "Pxe", .mode = "UEFI" };
    const pending: svc.BootState = .{ .enabled = "Continuous", .target = "Hdd", .mode = "Legacy" };
    const task_uri = "/redfish/v1/TaskService/TaskMonitors/fixture";
    const reservation = try log.reserve(ex, "https://bmc.invalid:443/redfish/v1/Systems/node-A", "fixture-system-uuid", .{ .boot = pending }, .{ .boot = boot_state, .etag = "\"rev1\"" });
    try log.beginDispatch(reservation.index);
    try log.setResult(reservation.index, .{ .operation = ex.operation, .phase = .outcome_unknown, .reason = .timeout, .dispatched = true, .task_uri = task_uri, .current_boot = current, .pending_boot = pending });
    var engine_value = try power.Engine.init(a, owner, .{ .authority = "bmc.invalid:443" }, &log, null);
    defer engine_value.deinit();
    try engine_value.query(ex.operation, 100);
    const read_gate: power.Gate = .{ .owner = owner, .binding_generation = 1, .capability_revision = 1, .grant_revision = 1, .authenticated = true, .write_granted = false };
    const writes_before = memory.writes;
    for (0..2) |iteration| {
        const now_ms = 100 + @as(u64, @intCast(iteration)) * 1001;
        const request = (try engine_value.next(now_ms, read_gate)).?;
        try std.testing.expectEqual(power.Method.get, request.method);
        try std.testing.expectEqualStrings(task_uri, request.uri);
        try engine_value.complete(.{ .sequence = request.sequence, .status = 200, .body = "{\"TaskState\":\"Running\"}" }, now_ms + 1);
        try std.testing.expectEqual(writes_before + iteration + 1, memory.writes);
        const observed = try engine_value.result(ex.operation);
        try std.testing.expectEqualStrings("Once", observed.current_boot.?.enabled.?);
        try std.testing.expectEqualStrings("Pxe", observed.current_boot.?.target.?);
        try std.testing.expectEqualStrings("UEFI", observed.current_boot.?.mode.?);
        try std.testing.expectEqualStrings("Continuous", observed.pending_boot.?.enabled.?);
        try std.testing.expectEqualStrings("Hdd", observed.pending_boot.?.target.?);
        try std.testing.expectEqualStrings("Legacy", observed.pending_boot.?.mode.?);
        try std.testing.expectEqualStrings(task_uri, observed.task_uri.?);
        const persisted = log.entries[reservation.index].result();
        try std.testing.expect(svc.sameBoot(current, persisted.current_boot.?));
        try std.testing.expect(svc.sameBoot(pending, persisted.pending_boot.?));
    }
}

/// Deterministically exposes a borrowed pointer after arena teardown without
/// dereferencing unmapped memory. Freed blocks are poisoned and remain owned
/// until the test ends; the backing testing allocator still checks all frees.
const PoisonFreedAllocator = struct {
    const Allocation = struct { memory: []u8, alignment: std.mem.Alignment };
    base: std.mem.Allocator,
    allocations: [4096]Allocation = undefined,
    count: usize = 0,
    fn allocator(self: *PoisonFreedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PoisonFreedAllocator = @ptrCast(@alignCast(raw));
        if (self.count == self.allocations.len) return null;
        const bytes = self.base.rawAlloc(len, alignment, ra) orelse return null;
        self.allocations[self.count] = .{ .memory = bytes[0..len], .alignment = alignment };
        self.count += 1;
        return bytes;
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(_: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
        @memset(bytes, 0xdd);
    }
    fn deinit(self: *PoisonFreedAllocator) void {
        for (self.allocations[0..self.count]) |item| self.base.rawFree(item.memory, item.alignment, @returnAddress());
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};
