//! Standard Redfish response and resource-identity vectors. All values are
//! synthetic; these tests never connect to a management endpoint.
const std = @import("std");
const redfish = @import("plugins/bmc_ikvm/protocol/redfish.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const power = @import("plugins/bmc_ikvm/protocol/power.zig");
const ledger = @import("plugins/bmc_ikvm/management_journal.zig");
const a = std.testing.allocator;
const management_fixture = @embedFile("plugins/bmc_ikvm/protocol/profile_fixtures/sugon_1_80_management_readonly.json");

fn expectResponse(status: u16, body: []const u8, validity: svc.Validity, accepted: bool) !void {
    var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/fixture-node", status, body, null, 100);
    defer doc.deinit();
    try std.testing.expectEqual(validity, doc.validity);
    try std.testing.expectEqual(accepted, doc.accepted());
}

// DSP0266 1.16.0 sections 7.11, 8.6 and 9.9.5 permit success messages in the
// error-shaped envelope and define ExtendedInfo as object/property annotations.
// https://redfish.dmtf.org/schemas/DSP0266_1.16.0.html
test "BMC Redfish compatibility clean resource fields are not response messages" {
    for ([_][]const u8{
        "{}",
        "{\"PowerState\":\"On\",\"Status\":{\"Health\":\"Critical\"}}",
        "{\"Severity\":\"Critical\",\"MessageSeverity\":\"Warning\"}",
        "{\"Oem\":{\"Public\":{\"LastEvent\":{\"Severity\":\"Critical\",\"MessageId\":\"Base.1.19.InternalError\"},\"error\":\"historical device field\"}}}",
        "{\"@Redfish.Settings\":{\"Messages\":[{\"MessageId\":\"Base.1.19.PropertyNotWritable\",\"Severity\":\"Warning\"}]}}",
        "{\"@Message.ExtendedInfo\":[]}",
    }) |body| try expectResponse(200, body, .valid, true);
}

test "BMC Redfish compatibility accepts explicit standard success messages" {
    for ([_][]const u8{
        "{\"error\":{\"code\":\"Base.1.8.Success\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.8.Success\",\"Severity\":\"OK\",\"MessageSeverity\":\"OK\"}]}}",
        "{\"error\":{\"code\":\"Base.1.19.Success\"}}",
        "{\"error\":{\"code\":\"Base.1.19.Created\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.Created\"}]}}",
        "{\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.Success\"}]}",
        "{\"Boot\":{\"BootSourceOverrideEnabled\":\"Once\",\"BootSourceOverrideEnabled@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.Success\",\"MessageSeverity\":\"OK\"}]}}",
    }) |body| try expectResponse(200, body, .valid, true);
    // The registry's NoOperation has Warning severity. DSP0266 specifically
    // permits it for a successful Reset that cannot change the current state.
    const no_operation = "{\"error\":{\"code\":\"Base.1.19.NoOperation\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.NoOperation\",\"Severity\":\"Warning\",\"MessageSeverity\":\"Warning\"}]}}";
    try expectResponse(200, no_operation, .valid, true);
    var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/fixture-node/Actions/ComputerSystem.Reset", 200, no_operation, null, 100);
    defer doc.deinit();
    try std.testing.expectEqual(redfish.MessageOutcome.no_operation, redfish.bodyMessages(doc.value));
}

test "BMC Redfish compatibility contradictory or uncertain messages fail closed" {
    for ([_][]const u8{
        "{\"error\":null}",
        "{\"error\":{}}",
        "{\"error\":{\"code\":\"Base.Error\"}}",
        "{\"error\":{\"code\":\"Base.1.19.Success\",\"Severity\":\"Critical\"}}",
        "{\"error\":{\"code\":\"Base.1.19.ResourceAtUriUnauthorized\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.Success\",\"Severity\":\"OK\"}]}}",
        "{\"error\":{\"code\":\"Base.1.19.Success\",\"@Message.ExtendedInfo\":[{\"Severity\":\"OK\"}]}}",
        "{\"error\":{\"code\":\"Base.1.19.Success\",\"@Message.ExtendedInfo\":[]}}",
        "{\"error\":{\"code\":\"Base.1.19.Success\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.Success\",\"Severity\":\"Critical\",\"MessageSeverity\":\"OK\"}]}}",
        "{\"error\":{\"code\":\"Base.1.19.Success\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.Success\",\"Severity\":\"OK\",\"MessageSeverity\":\"Warning\"}]}}",
        "{\"error\":{\"code\":\"Base.1.19.Success\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.Success\",\"Severity\":\"OK\"},{\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\"}]}}",
        "{\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.ResourceAtUriUnauthorized\",\"Severity\":\"OK\"}]}",
        "{\"@Message.ExtendedInfo\":[{\"MessageId\":\"Unknown.1.0.Success\",\"Severity\":\"OK\"}]}",
        "{\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.invalid.19.Success\",\"Severity\":\"OK\"}]}",
        "{\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.2.0.Success\",\"Severity\":\"OK\"}]}",
        "{\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.SuccessSuffix\",\"Severity\":\"OK\"}]}",
        "{\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.Success\",\"Severity\":null}]}",
        "{\"@Message.ExtendedInfo\":{\"MessageId\":\"Base.1.19.Success\"}}",
        "{\"Boot\":{\"BootSourceOverrideEnabled\":\"Once\",\"BootSourceOverrideEnabled@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.PropertyNotWritable\",\"Severity\":\"Warning\"}]}}",
    }) |body| try expectResponse(200, body, .partial_with_error, false);
    for ([_]u16{ 301, 400, 401, 404, 500 }) |status|
        try expectResponse(status, "{\"error\":{\"code\":\"Base.1.19.Success\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.Success\",\"Severity\":\"OK\"}]}}", .unavailable, false);
}

const MappingFixture = struct {
    root: []const u8 = "{\"Systems\":{\"@odata.id\":\"/redfish/v1/Systems\"},\"Managers\":{\"@odata.id\":\"/redfish/v1/Managers\"},\"SessionService\":{\"@odata.id\":\"/redfish/v1/SessionService\"}}",
    oem_security_profile: bool = false,
    oem_resource_association: bool = false,
    chassis: []const u8 = "{}",
    security: []const u8 = "{\"EnableAuthConfirm\":false}",
    collection: []const u8 = "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Systems/node-A\"},{\"@odata.id\":\"/redfish/v1/Systems/node-B\"}]}",
    manager_collection: []const u8 = "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}",
    manager: []const u8 = "{\"@odata.id\":\"/redfish/v1/Managers/B\",\"Id\":\"B\",\"Links\":{\"ManagerForServers\":[{\"@odata.id\":\"/redfish/v1/Systems/node-B\"}]}}",
    first: []const u8 = "{\"@odata.id\":\"/redfish/v1/Systems/node-A\",\"Id\":\"node-A\",\"UUID\":\"fixture-uuid-A\",\"PowerState\":\"On\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
    second: []const u8 = "{\"@odata.id\":\"/redfish/v1/Systems/node-B\",\"Id\":\"node-B\",\"UUID\":\"fixture-uuid-B\",\"PowerState\":\"Off\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
    canonical: []const u8 = "{\"error\":{\"code\":\"Base.1.19.ResourceMissingAtURI\"}}",
    canonical_status: u16 = 404,
    fn discover(self: MappingFixture) !redfish.Discovery {
        var result = try redfish.Discovery.init(a, .{ .host = "bmc.invalid" });
        errdefer result.deinit();
        result.oem_public_security_service = self.oem_security_profile;
        result.oem_public_resource_association = self.oem_resource_association;
        try result.ingest(result.next().?, 200, self.root, null, 1);
        while (result.next()) |request| {
            const body = switch (request.kind) {
                .systems => self.collection,
                .managers => self.manager_collection,
                .manager => self.manager,
                .chassis => self.chassis,
                .security => self.security,
                .system => if (std.mem.eql(u8, request.uri, "/redfish/v1/Systems/node-A")) self.first else if (std.mem.eql(u8, request.uri, "/redfish/v1/Systems/node-B")) self.second else self.canonical,
                else => "{}",
            };
            const status: u16 = if (request.kind == .system and !std.mem.eql(u8, request.uri, "/redfish/v1/Systems/node-A") and !std.mem.eql(u8, request.uri, "/redfish/v1/Systems/node-B")) self.canonical_status else 200;
            try result.ingest(request, status, body, null, 100);
        }
        return result;
    }
};

const management_root = "{\"Systems\":{\"@odata.id\":\"/redfish/v1/Systems\"},\"Managers\":{\"@odata.id\":\"/redfish/v1/Managers\"},\"SessionService\":{\"@odata.id\":\"/redfish/v1/SessionService\"},\"Links\":{\"ManagerProvidingService\":{\"@odata.id\":\"/redfish/v1/Managers/B\"}}}";
const management_collection = "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Systems/node-B\"}]}";
const management_manager = "{\"@odata.id\":\"/redfish/v1/Managers/B\",\"@odata.type\":\"#Manager.v1_18_0.Manager\",\"Id\":\"B\",\"SecurityService\":{\"@odata.id\":\"/redfish/v1/Managers/B/SecurityService\"}}";
const management_system = "{\"@odata.id\":\"/redfish/v1/Systems/node-B\",\"@odata.type\":\"#ComputerSystem.v1_22_0.ComputerSystem\",\"Id\":\"node-B\",\"UUID\":\"fixture-uuid-B\",\"PowerState\":\"On\",\"Actions\":{\"#ComputerSystem.Reset\":{\"target\":\"/redfish/v1/Systems/node-B/Actions/ComputerSystem.Reset\",\"ResetType@Redfish.AllowableValues\":[\"GracefulShutdown\"]}},\"Boot\":{\"BootSourceOverrideEnabled\":\"Disabled\",\"BootSourceOverrideTarget\":\"None\",\"BootSourceOverrideMode\":\"UEFI\",\"BootSourceOverrideEnabled@Redfish.AllowableValues\":[\"Disabled\",\"Once\"],\"BootSourceOverrideTarget@Redfish.AllowableValues\":[\"None\",\"Pxe\"]},\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}],\"Chassis\":[{\"@odata.id\":\"/redfish/v1/Chassis/rack-X\"}]}}";

test "BMC Redfish compatibility ManagerForServers object and array preserve collection reads when the advertised target is 404" {
    for ([_]bool{ false, true }) |array| {
        for ([_]bool{ false, true }) |missing| {
            const target = if (missing) "/redfish/v1/Systems/canonical" else "/redfish/v1/Systems/node-B";
            const relation = try std.fmt.allocPrint(a, "{s}{{\"@odata.id\":\"{s}\"}}{s}", .{ if (array) "[" else "", target, if (array) "]" else "" });
            defer a.free(relation);
            const manager = try std.fmt.allocPrint(a, "{{\"@odata.id\":\"/redfish/v1/Managers/B\",\"Id\":\"B\",\"Links\":{{\"ManagerForServers\":{s}}}}}", .{relation});
            defer a.free(manager);
            var discovery = try (MappingFixture{ .root = management_root, .collection = management_collection, .manager = manager, .second = management_system }).discover();
            defer discovery.deinit();
            try discovery.proveManagementTarget();
            try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", discovery.management_system.?);
            const selected = try discovery.system(discovery.management_system.?, .{});
            try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", selected.power.state.evidence.source_uri);
            try std.testing.expectEqual(svc.PowerState.on, selected.power.state.value.?);
            try std.testing.expectEqualStrings("Disabled", selected.boot.state.enabled.?);
            try std.testing.expectEqualStrings("None", selected.boot.state.target.?);
            try std.testing.expectEqualStrings("UEFI", selected.boot.state.mode.?);
            try std.testing.expectEqual(svc.Validity.valid, selected.power.state.evidence.validity);
            try std.testing.expectEqual(svc.Validity.valid, selected.boot.target_evidence.validity);
            try std.testing.expect(!selected.power.capability.write_granted and !selected.boot.capability.write_requestable);
            if (missing) {
                try std.testing.expectEqual(@as(u16, 404), discovery.find(target).?.status);
                try std.testing.expectError(error.MappingUnverified, discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true));
                try std.testing.expect(discovery.mapping_system == null);
                var found_source = false;
                for (discovery.queue.items) |request| if (std.mem.eql(u8, request.uri, target)) {
                    found_source = true;
                    try std.testing.expectEqual(redfish.LinkSource.manager_for_servers, request.source);
                };
                try std.testing.expect(found_source);
            } else {
                try discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true);
                try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", discovery.mapping_system.?);
            }
        }
    }
}

test "BMC Redfish compatibility ManagerForServers normalization rejects malformed foreign and ambiguous relationships" {
    for ([_][]const u8{
        "{}",                                                                 "null",                                                                 "42",                                                "{\"@odata.id\":42}",
        "{\"@odata.id\":\"https://evil.invalid/redfish/v1/Systems/node-B\"}", "[{\"@odata.id\":\"https://evil.invalid/redfish/v1/Systems/node-B\"}]", "{\"@odata.id\":\"/redfish/v1/Systems/../node-B\"}",
    }) |relation| {
        const manager = try std.fmt.allocPrint(a, "{{\"@odata.id\":\"/redfish/v1/Managers/B\",\"Id\":\"B\",\"Links\":{{\"ManagerForServers\":{s}}}}}", .{relation});
        defer a.free(manager);
        var discovery = try (MappingFixture{ .root = management_root, .collection = management_collection, .manager = manager, .second = management_system }).discover();
        defer discovery.deinit();
        if (discovery.proveManagementTarget()) |_| return error.UnexpectedManagementTarget else |_| {}
        try std.testing.expect(discovery.management_system == null and discovery.mapping_system == null);
        for (discovery.queue.items) |request| try std.testing.expect(std.mem.indexOf(u8, request.uri, "evil.invalid") == null);
    }
    const manager = "{\"Id\":\"B\",\"Links\":{\"ManagerForServers\":[{\"@odata.id\":\"/redfish/v1/Systems/node-A\"},{\"@odata.id\":\"/redfish/v1/Systems/node-B\"}]}}";
    var ambiguous = try (MappingFixture{ .root = management_root, .manager = manager, .second = management_system }).discover();
    defer ambiguous.deinit();
    try std.testing.expectError(error.ManagementTargetAmbiguous, ambiguous.proveManagementTarget());
    try std.testing.expectError(error.MappingAmbiguous, ambiguous.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true));
    try std.testing.expect(ambiguous.management_system == null and ambiguous.mapping_system == null);
}

test "BMC Redfish compatibility ManagerForServers malformed 404 bodies cannot interrupt valid collection reads" {
    for ([_][]const u8{ "<html>Not Found</html>", "[]", "{invalid" }) |body| {
        const manager = "{\"Id\":\"B\",\"Links\":{\"ManagerForServers\":{\"@odata.id\":\"/redfish/v1/Systems/canonical\"}}}";
        var discovery = try (MappingFixture{ .root = management_root, .collection = management_collection, .manager = manager, .second = management_system, .canonical = body }).discover();
        defer discovery.deinit();
        const missing = discovery.find("/redfish/v1/Systems/canonical").?;
        try std.testing.expectEqual(@as(u16, 404), missing.status);
        try std.testing.expectEqual(svc.Validity.unavailable, missing.validity);
        try discovery.proveManagementTarget();
        try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", discovery.management_system.?);
        const selected = try discovery.system(discovery.management_system.?, .{});
        try std.testing.expectEqual(svc.PowerState.on, selected.power.state.value.?);
        try std.testing.expectEqualStrings("None", selected.boot.state.target.?);
        try std.testing.expect(!selected.power.capability.write_granted);
    }
}

test "BMC Redfish compatibility standard management needs no OEM KVM mapping" {
    for ([_][]const u8{
        management_manager,
        "{\"@odata.id\":\"/redfish/v1/Managers/B\",\"Id\":\"B\",\"Links\":{\"ManagerForServers\":[{\"@odata.id\":\"/redfish/v1/Systems/canonical\"}]},\"SecurityService\":{\"@odata.id\":\"/redfish/v1/Managers/B/SecurityService\"}}",
    }) |manager| {
        var discovery = try (MappingFixture{ .root = management_root, .collection = management_collection, .manager = manager, .second = management_system }).discover();
        defer discovery.deinit();
        try discovery.proveManagementTarget();
        try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", discovery.management_system.?);
        try std.testing.expectEqualStrings("/redfish/v1/Managers/B", discovery.management_manager.?);
        try std.testing.expect(discovery.mapping_system == null and discovery.mapping_manager == null);
        const selected = try discovery.system(discovery.management_system.?, .{ .write_requestable = true });
        try std.testing.expect(selected.power.capability.system_mapping_verified and selected.boot.capability.system_mapping_verified);
        try std.testing.expect(selected.power.capability.write_requestable and !selected.power.capability.write_granted);
        try std.testing.expectEqual(svc.SecondaryAuth.disabled, selected.power.capability.secondary_auth);
        try std.testing.expect(selected.power.capability.secondary_auth_evidence.permitsWrite());
        try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", selected.boot.write_uri.?);
        try std.testing.expect(selected.power.state.evidence.permitsWrite() and selected.boot.target_evidence.permitsWrite());
        if (discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true)) |_| return error.UnexpectedKvmMapping else |_| {}
        try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", discovery.management_system.?);
    }
}

test "BMC Redfish compatibility management selection scopes capabilities and clears failed proofs" {
    const manager = "{\"@odata.id\":\"/redfish/v1/Managers/B\",\"Id\":\"B\",\"Links\":{\"ManagerForServers\":[{\"@odata.id\":\"/redfish/v1/Systems/node-B\"}]},\"SecurityService\":{\"@odata.id\":\"/redfish/v1/Managers/B/SecurityService\"}}";
    var discovery = try (MappingFixture{ .manager = manager }).discover();
    defer discovery.deinit();
    try discovery.proveManagementTarget();
    try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", discovery.management_system.?);
    const bound = try discovery.system(discovery.management_system.?, .{});
    try std.testing.expectEqual(svc.SecondaryAuth.disabled, bound.power.capability.secondary_auth);
    const other = try discovery.system("/redfish/v1/Systems/node-A", .{ .write_granted = true, .write_requestable = true, .secondary_auth = .disabled });
    try std.testing.expect(!other.power.capability.system_mapping_verified and !other.boot.capability.system_mapping_verified);
    try std.testing.expect(!other.power.capability.write_granted and !other.boot.capability.write_requestable);
    try std.testing.expectEqual(svc.SecondaryAuth.unknown, other.power.capability.secondary_auth);
    try std.testing.expect(!other.power.capability.secondary_auth_evidence.permitsWrite());
    for (discovery.resources.items) |*resource| if (resource.kind == .manager) {
        resource.doc.status = 404;
    };
    try std.testing.expectError(error.ManagementTargetUnverified, discovery.proveManagementTarget());
    try std.testing.expect(discovery.management_system == null and discovery.management_manager == null);
    const stale = try discovery.system("/redfish/v1/Systems/node-B", .{ .write_granted = true, .write_requestable = true });
    try std.testing.expect(!stale.power.capability.system_mapping_verified and !stale.power.capability.write_granted and !stale.boot.capability.write_requestable);
    try std.testing.expectEqual(svc.SecondaryAuth.unknown, stale.power.capability.secondary_auth);
}

test "BMC Redfish compatibility independently bound management still consumes exact approval" {
    const StubArbiter = struct {
        fn acquire(_: *anyopaque, _: []const u8, _: svc.Execution) !u64 {
            return 1;
        }
        fn revalidate(_: *anyopaque, _: u64, _: svc.Execution) bool {
            return true;
        }
        fn release(_: *anyopaque, _: u64) void {}
    };
    var discovery = try (MappingFixture{ .root = management_root, .collection = management_collection, .manager = management_manager, .second = management_system }).discover();
    defer discovery.deinit();
    try discovery.proveManagementTarget();
    const selected = try discovery.system(discovery.management_system.?, .{ .write_requestable = true });
    const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(912), .generation = 1 };
    const execution: svc.Execution = .{ .call = .{ .owner = owner, .binding_generation = 1 }, .operation = .{ .owner = .{ .session = owner }, .operation_id = 1, .attempt_id = 1 }, .nonce = @splat(3), .system_uri = selected.power.system_uri, .capability_revision = 1, .grant_revision = 1 };
    for ([_]bool{ false, true }) |is_boot| {
        var backend: ledger.MemoryBackend = .{ .allocator = a };
        defer backend.deinit();
        var journal = try ledger.Journal.init(a, backend.backend());
        defer journal.deinit();
        var context: u8 = 0;
        var engine = try power.Engine.init(a, owner, discovery.origin, &journal, .{ .context = &context, .acquire = StubArbiter.acquire, .revalidate = StubArbiter.revalidate, .release = StubArbiter.release });
        defer engine.deinit();
        try engine.setSnapshots(selected.power, selected.boot);
        const request: svc.ManagementRequest = if (is_boot)
            .{ .boot = .{ .execution = execution, .baseline = selected.boot.state, .enabled = "Once", .target = "Pxe" } }
        else
            .{ .power = .{ .execution = execution, .action = .graceful_shutdown } };
        const fingerprint = try svc.requestFingerprint(a, request, discovery.origin.authority, selected.power.system_identity);
        try std.testing.expectError(error.PermissionDenied, engine.approveUserRequest(fingerprint));
        engine.policy = .user_approved;
        try engine.approveUserRequest(fingerprint);
        switch (request) {
            .power => |value| {
                _ = try engine.requestPower(value, 100);
                try std.testing.expectError(error.PermissionDenied, engine.requestPower(value, 100));
            },
            .boot => |value| {
                _ = try engine.applyBoot(value, 100);
                try std.testing.expectError(error.PermissionDenied, engine.applyBoot(value, 100));
            },
        }
        const gate: power.Gate = .{ .owner = owner, .binding_generation = 1, .capability_revision = 1, .grant_revision = 1, .authenticated = true, .write_granted = true };
        const refresh = (try engine.next(100, gate)).?;
        try std.testing.expectEqual(power.Method.get, refresh.method);
        try std.testing.expectEqual(power.Purpose.refresh, refresh.purpose);
        try engine.complete(.{ .sequence = refresh.sequence, .status = 200, .body = management_system, .etag = "\"clean\"" }, 101);
        const outbound = (try engine.next(1101, gate)).?;
        try std.testing.expectEqual(if (is_boot) power.Method.patch else power.Method.post, outbound.method);
        try std.testing.expectEqualStrings("\"clean\"", outbound.if_match.?);
        try std.testing.expect(std.mem.indexOf(u8, outbound.body, "BootOrder") == null);
        // Engine output is inspected in memory; no transport dispatch occurs.
        try std.testing.expect(discovery.mapping_system == null);
    }
}

test "BMC Redfish compatibility management target rejects incomplete ambiguous and foreign identity" {
    const base: MappingFixture = .{ .root = management_root, .collection = management_collection, .manager = management_manager, .second = management_system };
    for (0..12) |invalid| {
        var fixture = base;
        switch (invalid) {
            0 => fixture.collection = "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Systems/node-A\"},{\"@odata.id\":\"/redfish/v1/Systems/node-B\"}]}",
            1 => fixture.root = "{\"Systems\":{\"@odata.id\":\"/redfish/v1/Systems\"},\"Managers\":{\"@odata.id\":\"/redfish/v1/Managers\"},\"SessionService\":{\"@odata.id\":\"/redfish/v1/SessionService\"},\"Links\":{\"ManagerProvidingService\":{\"@odata.id\":\"/redfish/v1/Managers/not-in-collection\"}}}",
            2 => fixture.manager = "{\"@odata.id\":\"https://evil.invalid/redfish/v1/Managers/B\",\"Id\":\"B\"}",
            3 => fixture.manager = "{\"@odata.id\":\"/redfish/v1/Managers/B\",\"Id\":\"\"}",
            4 => fixture.second = "{\"@odata.id\":\"/redfish/v1/Systems/node-B\",\"Id\":\"node-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/other\"}]}}",
            5 => fixture.second = "{\"@odata.id\":\"https://evil.invalid/redfish/v1/Systems/node-B\",\"Id\":\"node-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
            6 => fixture.second = "{\"@odata.id\":\"/redfish/v1/Systems/node-B\",\"@odata.type\":\"#Manager.v1_18_0.Manager\",\"Id\":\"node-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
            7 => fixture.second = "{\"@odata.id\":\"/redfish/v1/Systems/node-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
            8 => fixture.collection = "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Systems/node-B\"}],\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\",\"RelatedProperties\":[\"#/Members\"]}]}",
            9 => {
                fixture.root = (MappingFixture{}).root;
                fixture.manager_collection = "{\"Members\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"},{\"@odata.id\":\"/redfish/v1/Managers/other\"}]}";
            },
            10 => fixture.root = "{\"Systems\":{\"@odata.id\":\"/redfish/v1/Systems\"},\"Managers\":{\"@odata.id\":\"/redfish/v1/Managers\"},\"SessionService\":{\"@odata.id\":\"/redfish/v1/SessionService\"},\"Links\":{\"ManagerProvidingService\":{\"@odata.id\":\"https://evil.invalid/redfish/v1/Managers/B\"}}}",
            11 => {
                fixture.manager = "{\"@odata.id\":\"/redfish/v1/Managers/B\",\"Id\":\"B\",\"Links\":{\"ManagerForServers\":[{\"@odata.id\":\"/redfish/v1/Systems/canonical\"}]}}";
                fixture.canonical_status = 200;
                fixture.canonical = "{\"@odata.id\":\"/redfish/v1/Systems/canonical\",\"Id\":\"canonical\",\"UUID\":\"different-system\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}";
            },
            else => unreachable,
        }
        var rejected = try fixture.discover();
        defer rejected.deinit();
        if (rejected.proveManagementTarget()) |_| return error.UnexpectedManagementTarget else |_| {}
        try std.testing.expect(rejected.management_system == null and rejected.management_manager == null);
    }
}

fn discoverObserved() !redfish.Discovery {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, management_fixture, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const documents = redfish.member(parsed.value, "documents").?.object;
    var discovery = try redfish.Discovery.init(a, .{ .host = "bmc.invalid" });
    errdefer discovery.deinit();
    discovery.oem_public_security_service = true;
    discovery.oem_public_resource_association = true;
    while (discovery.next()) |request| {
        var entry: ?std.json.Value = null;
        var iterator = documents.iterator();
        while (iterator.next()) |item| if (svc.optionalEqual(redfish.text(item.value_ptr.*, "uri"), request.uri)) {
            entry = item.value_ptr.*;
            break;
        };
        const body = if (entry) |item|
            try std.json.Stringify.valueAlloc(a, redfish.member(item, "body").?, .{})
        else if (request.kind == .boot_option) blk: {
            const reference = request.uri[(std.mem.lastIndexOfScalar(u8, request.uri, '/') orelse unreachable) + 1 ..];
            break :blk try std.json.Stringify.valueAlloc(a, .{ .Id = reference, .BootOptionReference = reference, .DisplayName = "Synthetic boot option" }, .{});
        } else try a.dupe(u8, "{}");
        defer a.free(body);
        const status: u16 = if (entry) |item| @intCast(redfish.member(item, "status").?.integer) else 200;
        try discovery.ingest(request, status, body, null, 100);
    }
    return discovery;
}

test "BMC Redfish compatibility observed object diagnostic preserves independently bound valid management fields" {
    var discovery = try discoverObserved();
    defer discovery.deinit();
    var saw_advertised_missing_target = false;
    for (discovery.queue.items) |request| {
        if (!std.mem.eql(u8, request.uri, "/redfish/v1/Systems/broken-alias")) continue;
        saw_advertised_missing_target = true;
        try std.testing.expectEqual(redfish.LinkSource.manager_for_servers, request.source);
        try std.testing.expectEqualStrings("/redfish/v1/Managers/manager-B", request.source_uri.?);
        try std.testing.expectEqual(@as(u16, 404), discovery.find(request.uri).?.status);
        const manager = discovery.find(request.source_uri.?).?;
        const links = redfish.member(manager.value, "Links").?;
        const advertised = redfish.member(links, "ManagerForServers").?.array.items[0];
        try std.testing.expectEqualStrings(request.uri, redfish.text(advertised, "@odata.id").?);
    }
    try std.testing.expect(saw_advertised_missing_target);
    const association = try discovery.proveResourceAssociation();
    try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", association.system_uri);
    try std.testing.expectEqualStrings("/redfish/v1/Managers/manager-B", association.manager_uri);
    try std.testing.expectEqualStrings("/redfish/v1/Chassis/chassis-C", association.chassis_uri);
    try std.testing.expectEqual(svc.Validity.valid, association.root_evidence.validity);
    try std.testing.expectEqual(svc.Validity.valid, association.chassis_evidence.validity);
    try std.testing.expectError(error.MappingUnverified, discovery.proveKvmMapping(association.manager_uri, "/kvm/0", true));
    try std.testing.expect(discovery.mapping_system == null and discovery.mapping_manager == null);
    try discovery.proveManagementTarget();
    try std.testing.expectEqualStrings(association.system_uri, discovery.management_system.?);
    const system = try discovery.system(association.system_uri, .{ .write_requestable = true });
    try std.testing.expectEqual(svc.PowerState.on, system.power.state.value.?);
    try std.testing.expectEqual(svc.Validity.partial_with_error, system.power.resource_evidence.validity);
    try std.testing.expectEqual(svc.Validity.partial_with_error, system.boot.resource_evidence.validity);
    try std.testing.expectEqual(svc.Validity.valid, system.power.state.evidence.validity);
    try std.testing.expect(system.power.state.evidence.permitsWrite());
    try std.testing.expectEqual(svc.Validity.valid, system.power.last_reset_time.evidence.validity);
    try std.testing.expectEqual(svc.Validity.valid, system.boot.enabled_evidence.validity);
    try std.testing.expectEqual(svc.Validity.valid, system.boot.target_evidence.validity);
    try std.testing.expectEqual(svc.Validity.valid, system.boot.mode_evidence.validity);
    try std.testing.expect(svc.contains(system.boot.allowed_enabled.value.?, "Once"));
    try std.testing.expectEqual(svc.Validity.valid, system.boot.boot_order.evidence.validity);
    try std.testing.expectEqual(@as(usize, 8), system.power.reset_types.value.?.len);
    try std.testing.expectEqual(svc.Validity.valid, system.power.reset_types.evidence.validity);
    try std.testing.expectEqual(@as(usize, 20), system.boot.options.len);
    for (system.boot.options) |option| {
        try std.testing.expectEqual(svc.Validity.valid, option.evidence.validity);
        try std.testing.expect(std.mem.startsWith(u8, option.evidence.source_uri, "/redfish/v1/Systems/node-B/BootOptions/"));
    }
    try std.testing.expect(system.power.capability.system_mapping_verified and !system.power.capability.write_granted and system.power.capability.write_requestable);
    try std.testing.expectEqual(svc.SecondaryAuth.disabled, system.power.capability.secondary_auth);
    discovery.oem_public_resource_association = false;
    try std.testing.expectError(error.ResourceAssociationUnverified, discovery.proveResourceAssociation());
}

test "BMC Redfish compatibility reviewed association selects exact IDs among multiple systems" {
    const root = "{\"Systems\":{\"@odata.id\":\"/redfish/v1/Systems\"},\"Managers\":{\"@odata.id\":\"/redfish/v1/Managers\"},\"SessionService\":{\"@odata.id\":\"/redfish/v1/SessionService\"},\"Links\":{\"ManagerProvidingService\":{\"@odata.id\":\"/redfish/v1/Managers/B\"}},\"Oem\":{\"Public\":{\"SystemId\":\"node-B\",\"ManagerId\":\"B\",\"ChassisId\":\"rack-X\"}}}";
    const manager = "{\"@odata.id\":\"/redfish/v1/Managers/B\",\"@odata.type\":\"#Manager.v1_18_0.Manager\",\"Id\":\"B\",\"Links\":{\"ManagerForServers\":[{\"@odata.id\":\"/redfish/v1/Systems/canonical\"}]}}";
    const system = "{\"@odata.id\":\"/redfish/v1/Systems/node-B\",\"@odata.type\":\"#ComputerSystem.v1_22_0.ComputerSystem\",\"Id\":\"node-B\",\"UUID\":\"fixture-uuid-B\",\"PowerState\":\"On\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}],\"Chassis\":[{\"@odata.id\":\"/redfish/v1/Chassis/rack-X\"}]},\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\"}]}";
    const chassis = "{\"@odata.id\":\"/redfish/v1/Chassis/rack-X\",\"@odata.type\":\"#Chassis.v1_22_0.Chassis\",\"Id\":\"rack-X\",\"Links\":{\"ComputerSystems\":[{\"@odata.id\":\"/redfish/v1/Systems/node-B\"}],\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}";
    const base: MappingFixture = .{ .root = root, .manager = manager, .second = system, .chassis = chassis, .oem_resource_association = true };
    var discovery = try base.discover();
    defer discovery.deinit();
    const association = try discovery.proveResourceAssociation();
    try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", association.system_uri);
    try discovery.proveManagementTarget();
    try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", discovery.management_system.?);
    var clean = base;
    clean.second = management_system;
    var clean_discovery = try clean.discover();
    defer clean_discovery.deinit();
    try clean_discovery.proveManagementTarget();
    try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", clean_discovery.management_system.?);
    try std.testing.expect(clean_discovery.mapping_system == null);
    const selected = try clean_discovery.system(clean_discovery.management_system.?, .{});
    try std.testing.expect(selected.power.capability.system_mapping_verified and selected.power.state.evidence.permitsWrite());
    try std.testing.expect(!selected.power.capability.write_granted and !selected.power.capability.write_requestable);
    for (0..7) |invalid| {
        var fixture = base;
        switch (invalid) {
            0 => fixture.oem_resource_association = false,
            1 => fixture.first = "{\"@odata.id\":\"/redfish/v1/Systems/node-A\",\"Id\":\"node-B\",\"UUID\":\"different-fixture-uuid\"}",
            2 => fixture.first = "{\"@odata.id\":\"/redfish/v1/Systems/node-A\",\"Id\":\"node-A\",\"UUID\":\"fixture-uuid-B\"}",
            3 => fixture.chassis = "{\"@odata.id\":\"/redfish/v1/Chassis/rack-X\",\"Id\":\"rack-X\",\"Links\":{\"ComputerSystems\":[{\"@odata.id\":\"/redfish/v1/Systems/node-A\"}],\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
            4 => fixture.chassis = "{\"@odata.id\":\"/redfish/v1/Chassis/rack-X\",\"Id\":\"rack-X\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\"}]}",
            5 => fixture.second = "{\"@odata.id\":\"/redfish/v1/Systems/node-B\",\"@odata.type\":\"#ComputerSystem.v1_22_0.ComputerSystem\",\"Id\":\"node-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/other\"}],\"Chassis\":[{\"@odata.id\":\"/redfish/v1/Chassis/rack-X\"}]}}",
            6 => fixture.root = "{\"Systems\":{\"@odata.id\":\"/redfish/v1/Systems\"},\"Managers\":{\"@odata.id\":\"/redfish/v1/Managers\"},\"SessionService\":{\"@odata.id\":\"/redfish/v1/SessionService\"},\"Links\":{\"ManagerProvidingService\":{\"@odata.id\":\"/redfish/v1/Managers/B\"}},\"Oem\":{\"Public\":{\"SystemId\":\"missing-node\",\"ManagerId\":\"B\",\"ChassisId\":\"rack-X\"}}}",
            else => unreachable,
        }
        var rejected = try fixture.discover();
        defer rejected.deinit();
        if (rejected.proveResourceAssociation()) |_| return error.UnexpectedResourceAssociation else |_| {}
        try std.testing.expect(rejected.mapping_system == null);
    }
}

test "BMC Redfish compatibility reviewed Public SecurityService navigation is explicitly gated" {
    const manager = "{\"@odata.id\":\"/redfish/v1/Managers/B\",\"Id\":\"B\",\"Links\":{\"ManagerForServers\":[{\"@odata.id\":\"/redfish/v1/Systems/node-B\"}]},\"Oem\":{\"Public\":{\"SecurityService\":{\"@odata.id\":\"/redfish/v1/Managers/B/SecurityService\"}}}}";
    for ([_]bool{ false, true }) |reviewed| {
        var discovery = try (MappingFixture{ .manager = manager, .oem_security_profile = reviewed }).discover();
        defer discovery.deinit();
        try discovery.proveManagementTarget();
        try discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true);
        const selected = try discovery.system(discovery.mapping_system.?, .{});
        try std.testing.expectEqual(if (reviewed) svc.SecondaryAuth.disabled else .unknown, selected.power.capability.secondary_auth);
        try std.testing.expectEqual(reviewed, discovery.find("/redfish/v1/Managers/B/SecurityService") != null);
        if (reviewed) {
            try std.testing.expectEqualStrings("/redfish/v1/Managers/B/SecurityService", selected.power.capability.secondary_auth_evidence.source_uri);
            try std.testing.expect(selected.power.capability.secondary_auth_evidence.permitsWrite());
        }
    }
    var failed = try (MappingFixture{ .manager = manager, .oem_security_profile = true, .security = "{\"EnableAuthConfirm\":false,\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\",\"RelatedProperties\":[\"#/EnableAuthConfirm\"]}]}" }).discover();
    defer failed.deinit();
    try failed.proveManagementTarget();
    try failed.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true);
    const selected = try failed.system(failed.mapping_system.?, .{});
    try std.testing.expectEqual(svc.SecondaryAuth.unknown, selected.power.capability.secondary_auth);
    try std.testing.expect(!selected.power.capability.secondary_auth_evidence.permitsWrite());
}

test "BMC Redfish compatibility observed InternalError remains a diagnostic without becoming action success" {
    // Preserved field shape from the 2026-11-01 read-only device collection:
    // both profile and standard-token GETs reported the same InternalError.
    const body = "{\"@odata.id\":\"/redfish/v1/Systems/fixture-node\",\"@odata.type\":\"#ComputerSystem.v1_22_0.ComputerSystem\",\"Id\":\"fixture-node\",\"UUID\":\"synthetic-system\",\"PowerState\":\"On\",\"Boot\":{\"BootSourceOverrideEnabled\":\"Disabled\",\"BootSourceOverrideTarget\":\"None\",\"BootSourceOverrideMode\":\"UEFI\"},\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]},\"@Message.ExtendedInfo\":[{\"@odata.type\":\"#Message.v1_1_2.Message\",\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\",\"MessageArgs\":[],\"RelatedProperties\":[]}]}";
    var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/fixture-node", 200, body, null, 100);
    defer doc.deinit();
    try std.testing.expect(!doc.accepted());
    try std.testing.expectEqual(svc.Validity.partial_with_error, doc.validity);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const parsed = try redfish.parseSystem(arena.allocator(), .{ .authority = "bmc.invalid:443" }, doc);
    try std.testing.expectEqual(svc.PowerState.on, parsed.power.state.value.?);
    try std.testing.expectEqualStrings(doc.uri, parsed.power.state.evidence.source_uri);
    try std.testing.expect(doc.resourceAvailable());
    try std.testing.expectEqual(svc.Validity.partial_with_error, parsed.power.resource_evidence.validity);
    try std.testing.expectEqual(svc.Validity.valid, parsed.power.state.evidence.validity);
    try std.testing.expect(parsed.power.state.evidence.permitsWrite());
    try std.testing.expect(parsed.boot.enabled_evidence.permitsWrite());
    try std.testing.expect(parsed.boot.target_evidence.permitsWrite());
    try std.testing.expect(parsed.boot.mode_evidence.permitsWrite());
    try std.testing.expect(!parsed.power.capability.system_mapping_verified and !parsed.boot.capability.write_requestable);
}

test "BMC Redfish compatibility LastResetTime preserves independent validated evidence" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for ([_]struct { body: []const u8, validity: svc.Validity, has_value: bool }{
        .{ .body = "{\"PowerState\":\"On\",\"LastResetTime\":\"2026-11-01T01:02:03Z\"}", .validity = .valid, .has_value = true },
        .{ .body = "{\"LastResetTime\":\"2026-11-01T09:02:03.123+08:00\"}", .validity = .valid, .has_value = true },
        .{ .body = "{\"LastResetTime\":\"2026-02-30T01:02:03Z\"}", .validity = .unavailable, .has_value = true },
        .{ .body = "{\"LastResetTime\":\"invalid-timestamp\"}", .validity = .unavailable, .has_value = true },
        .{ .body = "{\"LastResetTime\":null}", .validity = .unavailable, .has_value = false },
        .{ .body = "{}", .validity = .unavailable, .has_value = false },
        .{ .body = "{\"LastResetTime\":\"2026-11-01T01:02:03Z\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\"}]}", .validity = .valid, .has_value = true },
        .{ .body = "{\"LastResetTime\":\"2026-11-01T01:02:03Z\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\",\"RelatedProperties\":[\"#/LastResetTime\"]}]}", .validity = .partial_with_error, .has_value = true },
    }) |vector| {
        var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/fixture-node", 200, vector.body, null, 100);
        defer doc.deinit();
        const parsed = try redfish.parseSystem(arena.allocator(), .{ .authority = "bmc.invalid:443" }, doc);
        try std.testing.expectEqual(vector.has_value, parsed.power.last_reset_time.value != null);
        try std.testing.expectEqual(vector.validity, parsed.power.last_reset_time.evidence.validity);
        try std.testing.expectEqual(vector.validity == .valid, parsed.power.last_reset_time.evidence.permitsWrite());
        try std.testing.expectEqualStrings(doc.uri, parsed.power.last_reset_time.evidence.source_uri);
        try std.testing.expectEqual(@as(u64, 100), parsed.power.last_reset_time.evidence.collected_ms);
    }
}

fn withAnnotation(base: []const u8, annotation: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s},{s}}}", .{ base[0 .. base.len - 1], annotation });
}

test "BMC Redfish compatibility property scopes isolate Boot Power Actions and identity" {
    for ([_]struct { path: []const u8, power_valid: bool = true, boot_valid: bool = true, reset_target: bool = true, identity_valid: bool = true }{
        .{ .path = "#/Boot", .boot_valid = false },
        .{ .path = "/Boot/BootSourceOverrideTarget", .boot_valid = false },
        .{ .path = "#/PowerState", .power_valid = false },
        .{ .path = "#/Actions/%23ComputerSystem.Reset/target", .reset_target = false },
        .{ .path = "#/Id", .identity_valid = false },
        .{ .path = "#/UUID", .identity_valid = false },
        .{ .path = "#/@odata.id", .identity_valid = false },
        .{ .path = "#/@odata.type", .identity_valid = false },
        // JSON member names are case-sensitive, including in RelatedProperties.
        .{ .path = "#/powerstate" },
        .{ .path = "#/Boot/Unrelated" },
    }) |vector| {
        const annotation = try std.fmt.allocPrint(a, "\"@Message.ExtendedInfo\":[{{\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\",\"RelatedProperties\":[\"{s}\"]}}]", .{vector.path});
        defer a.free(annotation);
        const body = try withAnnotation(management_system, annotation);
        defer a.free(body);
        var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/node-B", 200, body, null, 100);
        defer doc.deinit();
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const parsed = try redfish.parseSystem(arena.allocator(), .{ .authority = "bmc.invalid:443" }, doc);
        try std.testing.expect(!doc.accepted() and doc.resourceAvailable());
        try std.testing.expectEqual(vector.power_valid, parsed.power.state.evidence.permitsWrite());
        try std.testing.expectEqual(vector.boot_valid, parsed.boot.target_evidence.permitsWrite());
        try std.testing.expectEqual(vector.reset_target, parsed.power.reset_target != null);
        try std.testing.expectEqual(vector.identity_valid, parsed.power.system_identity.len != 0);
        var discovery = try (MappingFixture{ .root = management_root, .collection = management_collection, .manager = management_manager, .second = body }).discover();
        defer discovery.deinit();
        if (vector.identity_valid) {
            try discovery.proveManagementTarget();
            const selected = try discovery.system(discovery.management_system.?, .{ .write_requestable = true });
            try std.testing.expect(selected.power.capability.system_mapping_verified and selected.boot.capability.write_requestable);
        } else {
            if (discovery.proveManagementTarget()) |_| return error.UnexpectedManagementTarget else |_| {}
            try std.testing.expect(discovery.management_system == null);
        }
    }
}

test "BMC Redfish compatibility nested property annotations and escaped JSON pointers preserve exact scope" {
    const body =
        \\{"PowerState":"On","Boot":{"BootSourceOverrideEnabled":"Once","BootSourceOverrideTarget":"Pxe","BootSourceOverrideMode":"UEFI","BootSourceOverrideTarget@Message.ExtendedInfo":[{"MessageId":"Base.1.19.PropertyNotWritable","Severity":"Warning"}]},"A/B":{"~C":{"Value":true}},"a~1b":true,"@Message.ExtendedInfo":[{"MessageId":"Base.1.19.InternalError","Severity":"Critical","RelatedProperties":["#/A~1B/~0C"]}]}
    ;
    var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/node-B", 200, body, null, 100);
    defer doc.deinit();
    try std.testing.expectEqual(svc.Validity.partial_with_error, doc.fieldEvidence("/Boot/BootSourceOverrideTarget").validity);
    try std.testing.expectEqual(svc.Validity.partial_with_error, doc.fieldEvidence("/Boot").validity);
    try std.testing.expect(doc.fieldAccepted("/Boot/BootSourceOverrideEnabled"));
    try std.testing.expect(doc.fieldAccepted("/Boot/BootSourceOverrideMode"));
    try std.testing.expect(doc.fieldAccepted("/PowerState"));
    try std.testing.expectEqual(svc.Validity.partial_with_error, doc.fieldEvidence("/A~1B/~0C/Value").validity);
    try std.testing.expect(doc.fieldAccepted("/a~01b"));
    for ([_][]const u8{ "/A~2B", "/A~", "/powerstate", "Boot", "#/A%ZZ", "/a~1b" }) |invalid| {
        try std.testing.expectEqual(svc.Validity.unavailable, doc.fieldEvidence(invalid).validity);
    }
    const local = "{\"PowerState\":\"On\",\"Boot\":{\"BootSourceOverrideEnabled\":\"Once\",\"BootSourceOverrideTarget\":\"Pxe\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.InternalError\",\"Severity\":\"Critical\"}]}}";
    var nested = try redfish.Document.parse(a, doc.uri, 200, local, null, 100);
    defer nested.deinit();
    try std.testing.expect(nested.fieldAccepted("/PowerState"));
    try std.testing.expectEqual(svc.Validity.partial_with_error, nested.fieldEvidence("/Boot/BootSourceOverrideEnabled").validity);
    try std.testing.expectEqual(svc.Validity.partial_with_error, nested.fieldEvidence("/Boot/BootSourceOverrideTarget").validity);
}

test "BMC Redfish compatibility malformed and failed representations cannot supply management fields" {
    for ([_][]const u8{
        "{\"PowerState\":\"On\",\"@Message.ExtendedInfo\":null}",
        "{\"PowerState\":\"On\",\"@Message.ExtendedInfo\":[null]}",
        "{\"PowerState\":\"On\",\"@Message.ExtendedInfo\":[{\"MessageId\":\"Base.1.19.InternalError\",\"RelatedProperties\":\"#/PowerState\"}]}",
    }) |body| {
        var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/node-B", 200, body, null, 100);
        defer doc.deinit();
        try std.testing.expectEqual(svc.Validity.partial_with_error, doc.fieldEvidence("/PowerState").validity);
    }
    for ([_]struct { status: u16 = 200, body: []const u8 }{
        .{ .body = "{\"error\":{\"code\":\"Base.1.19.InternalError\"},\"Id\":\"node-B\",\"PowerState\":\"On\",\"Boot\":{\"BootSourceOverrideEnabled\":\"Disabled\"}}" },
        .{ .body = "{\"error\":{\"code\":\"Base.1.19.Success\"},\"PowerState\":\"On\"}" },
        .{ .status = 404, .body = management_system },
        .{ .status = 500, .body = management_system },
    }) |vector| {
        var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/node-B", vector.status, vector.body, null, 100);
        defer doc.deinit();
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const parsed = try redfish.parseSystem(arena.allocator(), .{ .authority = "bmc.invalid:443" }, doc);
        try std.testing.expect(!doc.resourceAvailable());
        try std.testing.expect(parsed.power.state.value == null and parsed.power.reset_target == null);
        try std.testing.expect(parsed.boot.state.enabled == null and parsed.boot.write_uri == null);
        try std.testing.expect(parsed.power.system_identity.len == 0);
    }
    for ([_][]const u8{
        "{\"Id\":\"node-B\",\"PowerState\":null,\"Boot\":{\"BootSourceOverrideEnabled\":null,\"BootSourceOverrideMode\":null}}",
        "{\"Id\":\"node-B\",\"PowerState\":42,\"Boot\":{\"BootSourceOverrideEnabled\":true,\"BootSourceOverrideMode\":{}}}",
        "{\"Id\":\"node-B\",\"PowerState\":\"Invalid\",\"Boot\":{\"BootSourceOverrideEnabled\":\"Invalid\",\"BootSourceOverrideMode\":\"Invalid\"}}",
    }) |body| {
        var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/node-B", 200, body, null, 100);
        defer doc.deinit();
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const parsed = try redfish.parseSystem(arena.allocator(), .{ .authority = "bmc.invalid:443" }, doc);
        try std.testing.expect(!parsed.power.state.evidence.permitsWrite());
        try std.testing.expect(!parsed.boot.enabled_evidence.permitsWrite() and !parsed.boot.mode_evidence.permitsWrite());
        try std.testing.expect(parsed.boot.allowed_enabled.value == null and parsed.boot.allowed_modes.value == null);
    }
    try std.testing.expectError(error.UnexpectedEndOfInput, redfish.Document.parse(a, "/redfish/v1/Systems/node-B", 200, "{", null, 100));
    try std.testing.expectError(error.InvalidRedfishResponse, redfish.Document.parse(a, "/redfish/v1/Systems/node-B", 200, "[]", null, 100));
}

test "BMC Redfish compatibility unrelated invalid URI and ActionInfo parameter cannot suppress valid fields" {
    var doc = try redfish.Document.parse(a, "/redfish/v1/Systems/node-B", 200,
        \\{"Id":"node-B","PowerState":"On","Actions":{"#ComputerSystem.Reset":{"target":"https://foreign.invalid/redfish/v1/Reset","ResetType@Redfish.AllowableValues":["GracefulShutdown"]}},"Boot":{"BootSourceOverrideEnabled":"Disabled","BootSourceOverrideTarget":"None","BootSourceOverrideMode":"UEFI","BootOptions":{"@odata.id":"https://foreign.invalid/redfish/v1/BootOptions"},"BootOrder":[42]},"Links":{"Chassis":42}}
    , null, 100);
    defer doc.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var parsed = try redfish.parseSystem(arena.allocator(), .{ .authority = "bmc.invalid:443" }, doc);
    try std.testing.expect(parsed.power.state.evidence.permitsWrite() and parsed.boot.target_evidence.permitsWrite());
    try std.testing.expect(parsed.power.reset_target == null and parsed.boot_options == null);
    try std.testing.expect(!parsed.boot.boot_order.evidence.permitsWrite());
    var info = try redfish.Document.parse(a, "/redfish/v1/Systems/node-B/ResetActionInfo", 200,
        \\{"Parameters":[{"Name":"Unrelated","AllowableValues":42,"@Message.ExtendedInfo":[{"MessageId":"Base.1.19.InternalError","Severity":"Critical"}]},{"Name":"ResetType","AllowableValues":["GracefulShutdown","On"]}],"@Message.ExtendedInfo":[{"MessageId":"Base.1.19.InternalError","Severity":"Critical","RelatedProperties":[]}]}
    , null, 100);
    defer info.deinit();
    try redfish.applyActionInfo(arena.allocator(), &parsed.power, info);
    try std.testing.expect(parsed.power.reset_types.evidence.permitsWrite());
    try std.testing.expectEqualStrings(info.uri, parsed.power.reset_types.evidence.source_uri);
    try std.testing.expectEqual(@as(usize, 1), parsed.power.reset_types.value.?.len);
}

test "BMC Redfish compatibility multiple systems map only through explicit reciprocal relationships" {
    var discovery = try (MappingFixture{}).discover();
    defer discovery.deinit();
    try discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true);
    try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", discovery.mapping_system.?);
}

test "BMC Redfish compatibility UUID agreement alone never proves two resource aliases" {
    var discovery = try (MappingFixture{
        .first = "{\"@odata.id\":\"/redfish/v1/Systems/node-A\",\"Id\":\"node-A\",\"UUID\":\"fixture-uuid-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
    }).discover();
    defer discovery.deinit();
    try std.testing.expectError(error.MappingAmbiguous, discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true));
    try std.testing.expect(discovery.mapping_system == null);
}

test "BMC Redfish compatibility canonical resource declarations must agree on identity" {
    var discovery = try (MappingFixture{
        .first = "{\"@odata.id\":\"/redfish/v1/Systems/node-B\",\"Id\":\"node-B\",\"UUID\":\"conflicting-fixture-uuid\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
    }).discover();
    defer discovery.deinit();
    try std.testing.expectError(error.MappingAmbiguous, discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true));
    try std.testing.expect(discovery.mapping_system == null);
}

test "BMC Redfish compatibility accepted canonical aliases retain exact mapping source" {
    var discovery = try (MappingFixture{
        .first = "{\"@odata.id\":\"https://bmc.invalid/redfish/v1/Systems/node-B\",\"Id\":\"node-B\",\"UUID\":\"fixture-uuid-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
    }).discover();
    defer discovery.deinit();
    try discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true);
    try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", discovery.mapping_system.?);
    const selected = try discovery.system(discovery.mapping_system.?, .{});
    try std.testing.expectEqualStrings("/redfish/v1/Systems/node-B", selected.power.state.evidence.source_uri);
}

test "BMC Redfish compatibility untrusted or nonresource canonical declarations cannot prove writes" {
    for ([_][]const u8{
        "{\"@odata.id\":\"https://evil.invalid/redfish/v1/Systems/node-B\",\"Id\":\"node-B\",\"UUID\":\"fixture-uuid-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
        "{\"@odata.id\":\"/redfish/v1/Systems/node-B?view=one\",\"Id\":\"node-B\",\"UUID\":\"fixture-uuid-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
        "{\"@odata.id\":42,\"Id\":\"node-B\",\"UUID\":\"fixture-uuid-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
        "{\"@odata.type\":\"#Manager.v1_20_0.Manager\",\"Id\":\"node-B\",\"UUID\":\"fixture-uuid-B\",\"Links\":{\"ManagedBy\":[{\"@odata.id\":\"/redfish/v1/Managers/B\"}]}}",
    }) |body| {
        var discovery = try (MappingFixture{ .second = body }).discover();
        defer discovery.deinit();
        try std.testing.expectError(error.MappingUnverified, discovery.proveKvmMapping("/redfish/v1/Managers/B", "/kvm/0", true));
        try std.testing.expect(discovery.mapping_system == null);
    }
}
