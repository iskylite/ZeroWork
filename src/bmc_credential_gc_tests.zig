//! Opaque contribution enumeration and scoped credential cleanup. Every secret
//! lives in MemoryBackend; every persisted fixture lives in a temporary folder.
const std = @import("std");
const config = @import("config/config.zig");
const store = @import("config/store.zig");
const credentials = @import("config/credential_store.zig");
const references = @import("config/plugin_credential_references.zig");
const a = std.testing.allocator;
const io = std.testing.io;

const ref_ai = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const ref_ssh = "zw1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const ref_plugin = "zw1_cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const ref_orphan = "zw1_dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";

const FixtureRegistry = struct {
    enabled: bool = true,

    fn provider(self: *const FixtureRegistry) references.Provider {
        return .{ .context = self, .resolve = resolve };
    }

    fn resolve(context: *const anyopaque, protocol_id: []const u8, version: u32) ?references.Enumerator {
        const self: *const FixtureRegistry = @ptrCast(@alignCast(context));
        if (self.enabled and std.mem.eql(u8, protocol_id, "fixture.custom") and version == 1) return enumerate;
        return null;
    }

    fn enumerate(allocator: std.mem.Allocator, payload: []const u8) ![]const []const u8 {
        const Payload = struct { credential_refs: []const []const u8 = &.{}, comment: []const u8 = "" };
        const parsed = try std.json.parseFromSlice(Payload, allocator, payload, .{});
        defer parsed.deinit();
        const result = try allocator.alloc([]const u8, parsed.value.credential_refs.len);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |reference| allocator.free(reference);
            allocator.free(result);
        }
        for (parsed.value.credential_refs, result) |reference, *destination| {
            if (!credentials.validReference(reference)) return error.InvalidCredentialReference;
            destination.* = try allocator.dupe(u8, reference);
            initialized += 1;
        }
        return result;
    }
};

fn seed(memory: *credentials.MemoryBackend, reference: []const u8, secret: []const u8) !void {
    const backend = memory.backend();
    try backend.add(backend.context, try credentials.scopeService(), reference, secret);
}

fn expectSecret(reference: []const u8, expected: []const u8) !void {
    const secret = try credentials.get(a, reference);
    defer a.free(secret);
    try std.testing.expectEqualStrings(expected, secret);
}

fn pluginHost(payload: ?[]const u8) config.hosts.HostConfig {
    return .{ .name = "plugin", .host = "", .user = "", .protocol_id = "fixture.custom", .plugin_payload = payload };
}

fn registryWith(host: config.hosts.HostConfig) !config.hosts.Registry {
    var registry = try config.hosts.Registry.parse(a, "");
    errdefer registry.deinit();
    _ = try registry.add(host);
    return registry;
}

fn writeRegistry(dir: std.Io.Dir, path: []const u8, registry: *const config.hosts.Registry) !void {
    const encoded = try registry.encode(a);
    defer a.free(encoded);
    try dir.writeFile(io, .{ .sub_path = path, .data = encoded });
}

fn pluginPayload(allocator: std.mem.Allocator, reference: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"credential_refs\":[\"{s}\"]}}", .{reference});
}

test "BMC credential GC known custom plugin refs form a union with AI and structured SSH without scanning strings" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_ai, "ai-secret");
    try seed(&memory, ref_ssh, "ssh-secret");
    try seed(&memory, ref_plugin, "plugin-secret");
    try seed(&memory, ref_orphan, "crash-leftover");
    const payload = try std.fmt.allocPrint(a, "{{\"credential_refs\":[\"{s}\",\"{s}\"],\"comment\":\"{s}\"}}", .{ ref_plugin, ref_plugin, ref_orphan });
    defer a.free(payload);
    var registry = try registryWith(pluginHost(payload));
    defer registry.deinit();
    _ = try registry.add(.{ .name = "ssh", .host = "localhost", .user = "ops", .auth_mode = .password, .password_ref = ref_ssh });
    var providers = [_]config.AiProvider{.{ .name = "fixture", .api_key_ref = ref_ai }};
    var value: config.Config = .{};
    value.ai.providers = &providers;
    value.ai.provider_count = 1;
    const plugins: FixtureRegistry = .{};
    try std.testing.expectEqual(store.CleanupStatus.complete, try store.reconcileCredentialsWithProvider(value, &registry, plugins.provider()));
    try std.testing.expectEqual(@as(usize, 3), memory.values.count());
    try expectSecret(ref_ai, "ai-secret");
    try expectSecret(ref_ssh, "ssh-secret");
    try expectSecret(ref_plugin, "plugin-secret");
    try std.testing.expectError(error.CredentialMissing, credentials.get(a, ref_orphan));
}

test "BMC credential GC unknown absent malformed and unsupported payload contributions defer all cleanup" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_plugin, "preserved-secret");
    const plugins: FixtureRegistry = .{};
    const payload = try pluginPayload(a, ref_plugin);
    defer a.free(payload);
    const cases = [_]struct { host: config.hosts.HostConfig, provider: ?references.Provider }{
        .{ .host = pluginHost(payload), .provider = null },
        .{ .host = .{ .name = "unknown", .host = "", .user = "", .protocol_id = "vendor.unloaded", .plugin_payload = payload }, .provider = plugins.provider() },
        .{ .host = pluginHost("{invalid-json"), .provider = plugins.provider() },
        .{ .host = pluginHost("{\"credential_refs\":[\"zw1_invalid\"]}"), .provider = plugins.provider() },
        .{ .host = pluginHost(null), .provider = plugins.provider() },
        .{ .host = .{ .name = "future", .host = "", .user = "", .protocol_id = "fixture.custom", .payload_version = 2, .plugin_payload = payload }, .provider = plugins.provider() },
        .{ .host = .{ .name = "future-ssh", .host = "", .user = "", .payload_version = 2, .plugin_payload = payload }, .provider = plugins.provider() },
    };
    for (cases) |case| {
        var registry = try registryWith(case.host);
        defer registry.deinit();
        try std.testing.expectEqual(store.CleanupStatus.deferred, try store.reconcileCredentialsWithProvider(.{}, &registry, case.provider));
        try expectSecret(ref_plugin, "preserved-secret");
    }
}

test "BMC credential GC bootstrap before plugin registry leaves opaque credentials and still opens both files" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_plugin, "plugin-secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try pluginPayload(a, ref_plugin);
    defer a.free(payload);
    var registry = try registryWith(pluginHost(payload));
    defer registry.deinit();
    try writeRegistry(tmp.dir, "hosts.toml", &registry);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = "[ui]\nfont_size=16\n" });
    try std.testing.expectEqual(store.CleanupStatus.deferred, try store.prepareCredentialsWithOptions(io, tmp.dir, a, "config.toml", "hosts.toml", .{}));
    var loaded = try store.load(io, tmp.dir, a, "config.toml");
    defer loaded.deinit(a);
    try std.testing.expectEqual(@as(u8, 16), loaded.value.ui.font_size);
    var hosts = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer hosts.deinit();
    try std.testing.expectEqualStrings(payload, hosts.hosts[0].plugin_payload.?);
    try expectSecret(ref_plugin, "plugin-secret");
    const plugins: FixtureRegistry = .{};
    try std.testing.expectEqual(store.CleanupStatus.complete, try store.prepareCredentialsWithOptions(io, tmp.dir, a, "config.toml", "hosts.toml", .{ .provider = plugins.provider() }));
    try expectSecret(ref_plugin, "plugin-secret");
}

test "BMC credential GC bootstrap missing files preserve all existing secrets" {
    for ([_]struct { config_exists: bool, hosts_exist: bool }{
        .{ .config_exists = false, .hosts_exist = false },
        .{ .config_exists = true, .hosts_exist = false },
        .{ .config_exists = false, .hosts_exist = true },
        .{ .config_exists = true, .hosts_exist = true },
    }) |case| {
        var memory: credentials.MemoryBackend = .{};
        defer memory.deinit();
        const previous = credentials.useBackendForTesting(memory.backend());
        defer credentials.restoreBackendForTesting(previous);
        try seed(&memory, ref_ai, "recoverable-ai-secret");
        try seed(&memory, ref_ssh, "recoverable-host-password");
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (case.config_exists) try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = "[ui]\nfont_size=16\n" });
        if (case.hosts_exist) try tmp.dir.writeFile(io, .{ .sub_path = "hosts.toml", .data = "" });
        const status = try store.prepareCredentialsWithOptions(io, tmp.dir, a, "config.toml", "hosts.toml", .{});
        if (case.config_exists and case.hosts_exist) {
            // Both explicit empty files are authoritative; ordinary orphan
            // cleanup continues to work when neither source is missing.
            try std.testing.expectEqual(store.CleanupStatus.complete, status);
            try std.testing.expectEqual(@as(usize, 0), memory.values.count());
        } else {
            try std.testing.expectEqual(store.CleanupStatus.deferred, status);
            try expectSecret(ref_ai, "recoverable-ai-secret");
            try expectSecret(ref_ssh, "recoverable-host-password");
        }
    }
}

test "BMC credential GC known plugin reference retires only after its final host is removed" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_plugin, "shared-plugin-secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try pluginPayload(a, ref_plugin);
    defer a.free(payload);
    var registry = try registryWith(pluginHost(payload));
    defer registry.deinit();
    var second = pluginHost(payload);
    second.name = "second-plugin";
    _ = try registry.add(second);
    try writeRegistry(tmp.dir, "hosts.toml", &registry);
    const plugins: FixtureRegistry = .{};
    try registry.remove(registry.hosts[0].owner());
    try std.testing.expectEqual(store.CleanupStatus.complete, try store.saveHostsWithOptions(io, tmp.dir, "hosts.toml", registry, .{ .provider = plugins.provider() }));
    try expectSecret(ref_plugin, "shared-plugin-secret");
    var live = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer live.deinit();
    var transaction = try store.HostsTransaction.init(a, &live);
    defer transaction.deinit();
    try transaction.candidate.?.remove(transaction.candidate.?.hosts[0].owner());
    try std.testing.expectEqual(store.CleanupStatus.complete, try transaction.commitWithOptions(io, tmp.dir, "hosts.toml", &live, .{ .provider = plugins.provider() }));
    try std.testing.expectEqual(@as(usize, 0), live.hosts.len);
    try std.testing.expect(transaction.candidate == null);
    try std.testing.expectError(error.CredentialMissing, credentials.get(a, ref_plugin));
}

test "BMC credential GC removing unknown baseline defers retirement instead of trusting the empty replacement" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_plugin, "unknown-secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try pluginPayload(a, ref_plugin);
    defer a.free(payload);
    var registry = try registryWith(pluginHost(payload));
    defer registry.deinit();
    try writeRegistry(tmp.dir, "hosts.toml", &registry);
    try registry.remove(registry.hosts[0].owner());
    try std.testing.expectEqual(store.CleanupStatus.deferred, try store.saveHostsWithOptions(io, tmp.dir, "hosts.toml", registry, .{}));
    try expectSecret(ref_plugin, "unknown-secret");
}

test "BMC credential GC unknown payload prevents stage from retiring a replaced SSH secret" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_ssh, "old-ssh-secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try registryWith(pluginHost("opaque"));
    defer registry.deinit();
    _ = try registry.add(.{ .name = "ssh", .host = "localhost", .user = "ops", .auth_mode = .password, .password_ref = ref_ssh });
    try writeRegistry(tmp.dir, "hosts.toml", &registry);
    var live = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer live.deinit();
    live.hosts[1].password = "new-ssh-secret";
    try std.testing.expectEqual(store.CleanupStatus.deferred, try store.saveHostsWithOptions(io, tmp.dir, "hosts.toml", live, .{}));
    try expectSecret(ref_ssh, "old-ssh-secret");
    try std.testing.expectEqual(@as(usize, 2), memory.values.count());
}

test "BMC credential GC known payload protects a replaced SSH secret still referenced by plugin" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_ssh, "shared-secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try pluginPayload(a, ref_ssh);
    defer a.free(payload);
    var registry = try registryWith(pluginHost(payload));
    defer registry.deinit();
    _ = try registry.add(.{ .name = "ssh", .host = "localhost", .user = "ops", .auth_mode = .password, .password_ref = ref_ssh });
    try writeRegistry(tmp.dir, "hosts.toml", &registry);
    var live = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer live.deinit();
    live.hosts[1].password = "replacement";
    const plugins: FixtureRegistry = .{};
    try std.testing.expectEqual(store.CleanupStatus.complete, try store.saveHostsWithOptions(io, tmp.dir, "hosts.toml", live, .{ .provider = plugins.provider() }));
    try expectSecret(ref_ssh, "shared-secret");
    try std.testing.expectEqual(@as(usize, 2), memory.values.count());
}

test "BMC credential GC failed host save rolls back newly staged secret and preserves known plugin ref" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_plugin, "plugin-secret");
    try seed(&memory, ref_ssh, "old-ssh-secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try pluginPayload(a, ref_plugin);
    defer a.free(payload);
    var registry = try registryWith(pluginHost(payload));
    defer registry.deinit();
    _ = try registry.add(.{ .name = "ssh", .host = "localhost", .user = "ops", .auth_mode = .password, .password_ref = ref_ssh });
    try writeRegistry(tmp.dir, "hosts.toml", &registry);
    var live = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer live.deinit();
    var transaction = try store.HostsTransaction.init(a, &live);
    defer transaction.deinit();
    transaction.candidate.?.hosts[1].password = "rolled-back-secret";
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts.toml", .data = "# external change\n" });
    const plugins: FixtureRegistry = .{};
    try std.testing.expectError(error.FileConflict, transaction.commitWithOptions(io, tmp.dir, "hosts.toml", &live, .{ .provider = plugins.provider() }));
    try std.testing.expectEqual(@as(usize, 2), memory.values.count());
    try expectSecret(ref_plugin, "plugin-secret");
    try expectSecret(ref_ssh, "old-ssh-secret");
    try std.testing.expectEqualStrings("old-ssh-secret", live.hosts[1].password.?);
    try std.testing.expectEqualStrings("rolled-back-secret", transaction.candidate.?.hosts[1].password.?);
}

test "BMC credential GC AI and plugin files sharing one reference retain it until both drop it" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_plugin, "shared-secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try pluginPayload(a, ref_plugin);
    defer a.free(payload);
    var registry = try registryWith(pluginHost(payload));
    defer registry.deinit();
    try writeRegistry(tmp.dir, "hosts.toml", &registry);
    const ai_source = "[ai]\n[[ai.providers]]\nid=\"fixture\"\napi_key_ref=\"" ++ ref_plugin ++ "\"\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = ai_source });
    const plugins: FixtureRegistry = .{};
    try std.testing.expectEqual(store.CleanupStatus.complete, try store.saveWithOptions(io, tmp.dir, "config.toml", .{}, .{ .provider = plugins.provider() }));
    try expectSecret(ref_plugin, "shared-secret");
    try registry.remove(registry.hosts[0].owner());
    try std.testing.expectEqual(store.CleanupStatus.complete, try store.saveHostsWithOptions(io, tmp.dir, "hosts.toml", registry, .{ .provider = plugins.provider() }));
    try std.testing.expectError(error.CredentialMissing, credentials.get(a, ref_plugin));
}

test "BMC credential GC plugin removal honors AI sibling references at explicitly configured paths" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_plugin, "shared-secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try pluginPayload(a, ref_plugin);
    defer a.free(payload);
    var registry = try registryWith(pluginHost(payload));
    defer registry.deinit();
    try writeRegistry(tmp.dir, "assets.toml", &registry);
    const ai_source = "[ai]\n[[ai.providers]]\nid=\"fixture\"\napi_key_ref=\"" ++ ref_plugin ++ "\"\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.toml", .data = ai_source });
    const plugins: FixtureRegistry = .{};
    const options: store.CredentialOptions = .{ .provider = plugins.provider(), .config_path = "settings.toml", .hosts_path = "assets.toml" };
    try registry.remove(registry.hosts[0].owner());
    try std.testing.expectEqual(store.CleanupStatus.complete, try store.saveHostsWithOptions(io, tmp.dir, "assets.toml", registry, options));
    try expectSecret(ref_plugin, "shared-secret");
    try std.testing.expectEqual(store.CleanupStatus.complete, try store.saveWithOptions(io, tmp.dir, "settings.toml", .{}, options));
    try std.testing.expectError(error.CredentialMissing, credentials.get(a, ref_plugin));
}

test "BMC credential GC unreadable sibling references defer retirement during normal save" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_plugin, "preserved-secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try pluginPayload(a, ref_plugin);
    defer a.free(payload);
    var registry = try registryWith(pluginHost(payload));
    defer registry.deinit();
    try writeRegistry(tmp.dir, "hosts.toml", &registry);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = "broken config" });
    try registry.remove(registry.hosts[0].owner());
    const plugins: FixtureRegistry = .{};
    try std.testing.expectEqual(store.CleanupStatus.deferred, try store.saveHostsWithOptions(io, tmp.dir, "hosts.toml", registry, .{ .provider = plugins.provider() }));
    try expectSecret(ref_plugin, "preserved-secret");
}

test "BMC credential GC providers are operation scoped and unloading one cannot authorize another" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    try seed(&memory, ref_plugin, "preserved-secret");
    var registry = try registryWith(pluginHost("{\"credential_refs\":[]}"));
    defer registry.deinit();
    const unloaded: FixtureRegistry = .{ .enabled = false };
    try std.testing.expectEqual(store.CleanupStatus.deferred, try store.reconcileCredentialsWithProvider(.{}, &registry, unloaded.provider()));
    const loaded: FixtureRegistry = .{};
    try std.testing.expectEqual(store.CleanupStatus.complete, try store.reconcileCredentialsWithProvider(.{}, &registry, loaded.provider()));
    try std.testing.expectError(error.CredentialMissing, credentials.get(a, ref_plugin));
    try seed(&memory, ref_plugin, "another-domain-secret");
    try std.testing.expectEqual(store.CleanupStatus.deferred, try store.reconcileCredentialsWithProvider(.{}, &registry, null));
    try expectSecret(ref_plugin, "another-domain-secret");
}

test "BMC credential GC default structured SSH migration save and retirement remain compatible" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "[[hosts]]\nname=\"legacy\"\nhost=\"localhost\"\nuser=\"ops\"\nauth={password=\"legacy-secret\"}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts.toml", .data = source });
    try store.prepareCredentials(io, tmp.dir, a, "config.toml", "hosts.toml");
    var registry = try store.loadHosts(io, tmp.dir, a, "hosts.toml");
    defer registry.deinit();
    const reference = try a.dupe(u8, registry.hosts[0].password_ref.?);
    defer a.free(reference);
    try std.testing.expect(credentials.validReference(reference));
    try std.testing.expectEqualStrings("legacy-secret", registry.hosts[0].password.?);
    try registry.remove(registry.hosts[0].owner());
    try store.saveHosts(io, tmp.dir, "hosts.toml", registry);
    try std.testing.expectError(error.CredentialMissing, credentials.get(a, reference));
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
}
