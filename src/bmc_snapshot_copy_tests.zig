//! Copy boundaries only: synthetic data, no network or persisted user state.
const std = @import("std");
const svc = @import("plugins/bmc_ikvm/services.zig");
const journal = @import("plugins/bmc_ikvm/management_journal.zig");
const model = @import("plugins/bmc_ikvm/model.zig");
const profile = @import("plugins/bmc_ikvm/protocol/profile.zig");
const a = std.testing.allocator;
const text = "owned snapshot text";
const Source = struct {
    storage: []u8,
    power: svc.PowerSnapshot,
    boot: svc.BootSnapshot,
    entry: journal.Entry,
    payload: model.Payload,
    selected: profile.Profile,

    fn init(allocator: std.mem.Allocator) !Source {
        const value = try allocator.dupe(u8, text);
        const strings = try allocator.alloc([]const u8, 3);
        @memset(strings, value);
        const options = try allocator.alloc(svc.BootOption, 3);
        for (options) |*option| option.* = .{ .reference = value, .id = value, .name = value, .evidence = .{ .source_uri = value } };
        const hops = try allocator.alloc(model.Hop, 3);
        for (hops, 1..) |*hop, id| hop.* = .{ .asset_id = id };
        const state: svc.BootState = .{ .enabled = value, .target = value, .mode = value };
        return .{
            .storage = value,
            .power = .{ .system_uri = value, .system_identity = value, .resource_evidence = .{ .source_uri = value }, .capability = .{ .secondary_auth_evidence = .{ .source_uri = value } }, .reset_types = .{ .value = strings, .evidence = .{ .source_uri = value } }, .reset_target = value, .etag = value, .last_reset_time = .{ .value = value, .evidence = .{ .source_uri = value } } },
            .boot = .{ .system_uri = value, .state = state, .pending = state, .allowed_targets = .{ .value = strings, .evidence = .{ .source_uri = value } }, .boot_order = .{ .value = strings }, .alias_boot_order = .{ .value = strings }, .options = options, .etag = value },
            .entry = .{ .session_id = 9, .generation = 2, .operation_id = 3, .nonce = @splat(7), .canonical_target = value, .system_identity = value, .parameters_sha256 = @splat(8), .parameters = .{ .boot = state }, .baseline = .{ .boot = state, .etag = value, .last_reset_time = value }, .current_boot = state, .pending_boot = state, .task_uri = value },
            .payload = .{ .endpoint = .{ .host = value }, .username = value, .credential_ref = value, .access = .{ .ssh_route = .{ .hops = hops } } },
            .selected = .{ .id = .sugon_1_80_oem_rfb, .synthetic = true, .evidence = .{ .firmware = value, .identity_fixture_sha256 = @splat(1), .public_key_pem = value, .public_key_sha256 = @splat(2), .public_key_source = value, .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .{ .own_id_template = .{ .prefix = value, .suffix = value } } } },
        };
    }
};
const Copies = struct {
    power: svc.OwnedPowerSnapshot,
    boot: svc.OwnedBootSnapshot,
    entry: journal.OwnedEntry,
    result: svc.Owned(svc.Result),
    payload: svc.Owned(model.Payload),
    selected: svc.Owned(profile.Profile),

    fn init(allocator: std.mem.Allocator, source: *const Source) !Copies {
        var power = try svc.OwnedPowerSnapshot.init(allocator, source.power);
        errdefer power.deinit();
        var boot = try svc.OwnedBootSnapshot.init(allocator, source.boot);
        errdefer boot.deinit();
        var entry = try journal.OwnedEntry.init(allocator, source.entry);
        errdefer entry.deinit();
        var result = try svc.Owned(svc.Result).init(allocator, source.entry.result());
        errdefer result.deinit();
        var payload = try svc.Owned(model.Payload).init(allocator, source.payload);
        errdefer payload.deinit();
        return .{ .power = power, .boot = boot, .entry = entry, .result = result, .payload = payload, .selected = try svc.Owned(profile.Profile).init(allocator, source.selected) };
    }
    fn deinit(self: *Copies) void {
        self.power.deinit();
        self.boot.deinit();
        self.entry.deinit();
        self.result.deinit();
        self.payload.deinit();
        self.selected.deinit();
    }
    fn check(self: *const Copies) !void {
        for ([_][]const u8{
            self.power.value.resource_evidence.source_uri,
            self.power.value.capability.secondary_auth_evidence.source_uri,
            self.power.value.reset_types.value.?[2],
            self.power.value.last_reset_time.value.?,
            self.boot.value.pending.?.mode.?,
            self.boot.value.allowed_targets.value.?[2],
            self.boot.value.options[2].name.?,
            self.boot.value.options[2].evidence.source_uri,
            self.boot.value.alias_boot_order.value.?[2],
            self.entry.value.parameters.boot.mode.?,
            self.entry.value.baseline.last_reset_time.?,
            self.entry.value.current_boot.?.enabled.?,
            self.entry.value.pending_boot.?.target.?,
            self.entry.value.task_uri.?,
            self.result.value.current_boot.?.enabled.?,
            self.result.value.pending_boot.?.target.?,
            self.result.value.task_uri.?,
            self.payload.value.endpoint.host,
            self.payload.value.username,
            self.payload.value.credential_ref.?,
            self.selected.value.evidence.public_key_pem,
            self.selected.value.evidence.kvm_logout.?.own_id_template.prefix,
            self.selected.value.evidence.kvm_logout.?.own_id_template.suffix,
        }) |value| try std.testing.expectEqualStrings(text, value);
        try std.testing.expectEqual(@as(u64, 3), self.payload.value.access.ssh_route.hops[2].asset_id);
        try std.testing.expectEqual(@as(u64, 9), self.entry.value.session_id);
        try std.testing.expectEqual(@as(u8, 7), self.entry.value.nonce[0]);
        try std.testing.expectEqual(profile.Logout.own_session_location, self.selected.value.evidence.web_logout.?);
    }
    fn allocationCase(allocator: std.mem.Allocator, source: *const Source) !void {
        var copies = try init(allocator, source);
        defer copies.deinit();
        try copies.check();
    }
};

test "BMC snapshot copies own nested management journal profile and configuration data on a small stack" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const source = try arena.allocator().create(Source);
    source.* = try Source.init(arena.allocator());
    const Worker = struct {
        source: *const Source,
        copies: ?Copies = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.copies = Copies.init(a, self.source) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var worker: Worker = .{ .source = source };
    const thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    var copies = worker.copies orelse return error.MissingSnapshot;
    defer copies.deinit();
    @memset(source.storage, 'x');
    for (@constCast(source.payload.access.ssh_route.hops)) |*hop| hop.asset_id = 0;
    arena.deinit();
    arena = .init(a);
    try copies.check();
}

test "BMC snapshot copies release all allocations on failure" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const source = try Source.init(arena.allocator());
    // Arena growth can use a different allocation count at different addresses.
    // Advance the failure point until a complete copy needs no failed allocation.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const completed = success: {
            Copies.allocationCase(failing.allocator(), &source) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                break :success false;
            };
            break :success true;
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (completed) {
            try std.testing.expect(!failing.has_induced_failure);
            break;
        }
        try std.testing.expect(failing.has_induced_failure);
    }
    try std.testing.expectEqualStrings(text, source.storage);
}
