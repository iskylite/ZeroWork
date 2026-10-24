test {
    _ = @import("config/store.zig");
    _ = @import("config/runtime_config.zig");
    _ = @import("config/settings_controller.zig");
}
const std = @import("std");
const config = @import("config/config.zig");
const store = @import("config/store.zig");
const credentials = @import("config/credential_store.zig");

test "credential migration redacts all supported secrets and preserves identities unknowns" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ai = "[meta]\nconfig_revision=41\n[ai]\n[[ai.providers]]\nid=\"fixture\"\napi_key=\"owned-ai-secret\"\n";
    const hosts = "[registry]\nschema_version=2\nrevision=8\nnext_connection_id=3\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=5\nname=\"owned\"\nhost=\"localhost\"\nuser=\"fixture\"\nauth={password=\"owned-password\",future_auth=\"preserve\"}\ntotp_secret=\"JBSWY3DPEHPK3PXP\"\nfuture=\"preserve\"\n[[hosts]]\nconnection_id=2\nname=\"key\"\nhost=\"localhost\"\nuser=\"fixture\"\nauth={key=\"/fixture/no-read\",passphrase=\"owned-passphrase\"}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml", .data = ai });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = hosts });
    try store.prepareCredentials(std.testing.io, tmp.dir, std.testing.allocator, "config.toml", "hosts.toml");
    try std.testing.expectEqual(@as(usize, 4), memory.values.count());
    var loaded = try store.load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("owned-ai-secret", loaded.value.ai.providers[0].api_key);
    try std.testing.expectEqual(@as(u64, 41), loaded.value.config_revision);
    var registry = try store.loadHosts(std.testing.io, tmp.dir, std.testing.allocator, "hosts.toml");
    defer registry.deinit();
    try std.testing.expectEqualStrings("owned-password", registry.hosts[0].password.?);
    try std.testing.expectEqualStrings("owned-passphrase", registry.hosts[1].key_passphrase.?);
    try std.testing.expectEqual(@as(u64, 8), registry.revision);
    try std.testing.expectEqual(@as(u64, 5), registry.hosts[0].revision);
    const disk = try tmp.dir.readFileAlloc(std.testing.io, "hosts.toml", std.testing.allocator, .limited(store.max_config_bytes));
    defer std.testing.allocator.free(disk);
    for ([_][]const u8{ "owned-password", "owned-passphrase", "JBSWY3DPEHPK3PXP" }) |secret| try std.testing.expect(std.mem.indexOf(u8, disk, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, disk, "future_auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, disk, "future =") != null);
    try std.testing.expect(credentials.validReference(registry.hosts[0].password_ref.?));
    try store.saveHosts(std.testing.io, tmp.dir, "hosts.toml", registry);
    try store.save(std.testing.io, tmp.dir, "config.toml", loaded.value);
    try std.testing.expectEqual(@as(usize, 4), memory.values.count());
}

test "credential denied migration keeps original bytes and no defaults" {
    var memory: credentials.MemoryBackend = .{ .denied = true };
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "[ai]\n[[ai.providers]]\nid=\"fixture\"\napi_key=\"owned-secret\"\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml", .data = source });
    try std.testing.expectError(error.CredentialDenied, store.load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml"));
    const disk = try tmp.dir.readFileAlloc(std.testing.io, "config.toml", std.testing.allocator, .limited(store.max_config_bytes));
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqualStrings(source, disk);
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
}

test "credential staged file failure rolls back new refs and retains old secret" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var providers = [_]config.AiProvider{.{ .name = "fixture", .api_key = "owned-old" }};
    var value: config.Config = .{};
    value.ai.providers = &providers;
    value.ai.provider_count = 1;
    try store.save(std.testing.io, tmp.dir, "config.toml", value);
    var old = try store.load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer old.deinit(std.testing.allocator);
    const old_reference = old.value.ai.providers[0].api_key_ref.?;
    try tmp.dir.createDir(std.testing.io, "blocked", .default_dir);
    providers[0].api_key = "owned-new";
    try std.testing.expectError(error.IsDir, store.save(std.testing.io, tmp.dir, "blocked", value));
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
    const secret = try credentials.get(std.testing.allocator, old_reference);
    defer std.testing.allocator.free(secret);
    try std.testing.expectEqualStrings("owned-old", secret);
    const long = try std.testing.allocator.alloc(u8, store.max_config_bytes + 10);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    value.ui.font_family = long;
    try std.testing.expectError(error.WriteFailed, store.save(std.testing.io, tmp.dir, "config.toml", value));
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
    var unchanged = try store.load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("owned-old", unchanged.value.ai.providers[0].api_key);
}

test "credential changes replace immutable refs without accumulating orphans missing refs fail" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var providers = [_]config.AiProvider{.{ .name = "fixture", .api_key = "owned-first" }};
    var value: config.Config = .{};
    value.ai.providers = &providers;
    value.ai.provider_count = 1;
    try store.save(std.testing.io, tmp.dir, "config.toml", value);
    var loaded = try store.load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer loaded.deinit(std.testing.allocator);
    const old_reference = loaded.value.ai.providers[0].api_key_ref.?;
    providers[0].api_key_ref = old_reference;
    for (0..4) |_| {
        providers[0].api_key = "owned-second";
        try store.save(std.testing.io, tmp.dir, "config.toml", value);
    }
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
    try std.testing.expectError(error.CredentialMissing, credentials.get(std.testing.allocator, old_reference));
    try credentials.eraseScope();
    try std.testing.expectError(error.CredentialMissing, store.load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml"));
    try std.testing.expectError(error.CredentialMissing, store.save(std.testing.io, tmp.dir, "config.toml", value));
}

test "credential partial staging failure rolls back completed writes" {
    var memory: credentials.MemoryBackend = .{ .fail_add_after = 1 };
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try config.hosts.Registry.parse(std.testing.allocator, "[[hosts]]\nname=\"fixture\"\nhost=\"localhost\"\nuser=\"fixture\"\nauth={password=\"owned-password\"}\ntotp_secret=\"JBSWY3DPEHPK3PXP\"\n");
    defer registry.deinit();
    try std.testing.expectError(error.CredentialStorageFailure, store.saveHosts(std.testing.io, tmp.dir, "hosts.toml", registry));
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "hosts.toml", .{}));
}

test "credential host conflict after staging preserves old secret and rolls back new" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try config.hosts.Registry.parse(std.testing.allocator, "[[hosts]]\nname=\"fixture\"\nhost=\"localhost\"\nuser=\"fixture\"\nauth={password=\"owned-old\"}\n");
    defer registry.deinit();
    try store.saveHosts(std.testing.io, tmp.dir, "hosts.toml", registry);
    var live = try store.loadHosts(std.testing.io, tmp.dir, std.testing.allocator, "hosts.toml");
    defer live.deinit();
    const old_reference = live.hosts[0].password_ref.?;
    var tx = try store.HostsTransaction.init(std.testing.allocator, &live);
    defer tx.deinit();
    tx.candidate.?.hosts[0].password = "owned-new";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "# external edit\n" });
    try std.testing.expectError(error.FileConflict, tx.commit(std.testing.io, tmp.dir, "hosts.toml", &live));
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
    try std.testing.expectEqualStrings("owned-old", live.hosts[0].password.?);
    const secret = try credentials.get(std.testing.allocator, old_reference);
    defer std.testing.allocator.free(secret);
    try std.testing.expectEqualStrings("owned-old", secret);
}

test "credential import source stays read-only until persistence" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "[[hosts]]\nname=\"fixture\"\nhost=\"localhost\"\nuser=\"fixture\"\nauth={password=\"owned-import\"}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "import.toml", .data = source });
    var registry = try store.loadHostsForImport(std.testing.io, tmp.dir, std.testing.allocator, "import.toml");
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), memory.values.count());
    const disk = try tmp.dir.readFileAlloc(std.testing.io, "import.toml", std.testing.allocator, .limited(store.max_config_bytes));
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqualStrings(source, disk);
    try store.saveHosts(std.testing.io, tmp.dir, "hosts.toml", registry);
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
}

test "credential reconciliation only erases current service owned refs" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    const b = memory.backend();
    const reference = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try b.add(b.context, "com.zerowork.unrelated", reference, "owned-other-scope");
    var tx = try credentials.Transaction.init();
    defer tx.deinit();
    const own = (try tx.stage(std.testing.io, std.testing.allocator, "owned-current", null)).?;
    defer std.testing.allocator.free(own);
    tx.commit();
    try credentials.reconcileScope(&.{own});
    try std.testing.expectEqual(@as(usize, 2), memory.values.count());
    try credentials.eraseScope();
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
    const other = try b.get(b.context, std.testing.allocator, "com.zerowork.unrelated", reference);
    defer std.testing.allocator.free(other);
    try std.testing.expectEqualStrings("owned-other-scope", other);
}

test "credential runtime publishes committed refs across key update and provider rename" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var providers = [_]config.AiProvider{.{ .name = "fixture", .api_key = "owned-first" }};
    var initial: config.Config = .{};
    initial.ai.providers = &providers;
    initial.ai.provider_count = 1;
    try store.save(std.testing.io, tmp.dir, "config.toml", initial);
    var runtime = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    const first_reference = try std.testing.allocator.dupe(u8, runtime.value.ai.providers[0].api_key_ref.?);
    defer std.testing.allocator.free(first_reference);

    providers[0] = runtime.value.ai.providers[0];
    providers[0].api_key = "owned-second";
    var changed = runtime.value;
    changed.ai.providers = &providers;
    try runtime.save(std.testing.io, tmp.dir, changed);
    const second_reference = try std.testing.allocator.dupe(u8, runtime.value.ai.providers[0].api_key_ref.?);
    defer std.testing.allocator.free(second_reference);
    try std.testing.expect(!std.mem.eql(u8, first_reference, second_reference));
    try std.testing.expectError(error.CredentialMissing, credentials.get(std.testing.allocator, first_reference));
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());

    providers[0] = runtime.value.ai.providers[0];
    providers[0].name = "renamed-fixture";
    changed = runtime.value;
    changed.ai.providers = &providers;
    try runtime.save(std.testing.io, tmp.dir, changed);
    try std.testing.expectEqualStrings(second_reference, runtime.value.ai.providers[0].api_key_ref.?);
    try std.testing.expectEqualStrings("owned-second", runtime.value.ai.providers[0].api_key);
    var reloaded = try store.load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer reloaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("renamed-fixture", reloaded.value.ai.providers[0].name);
    try std.testing.expectEqualStrings(second_reference, reloaded.value.ai.providers[0].api_key_ref.?);
    try std.testing.expectEqualStrings("owned-second", reloaded.value.ai.providers[0].api_key);
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());

    // Failure before replacement must retain the published ref and old secret.
    const oversized = try std.testing.allocator.alloc(u8, store.max_config_bytes + 10);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    providers[0] = runtime.value.ai.providers[0];
    providers[0].api_key = "owned-third";
    changed = runtime.value;
    changed.ai.providers = &providers;
    changed.ui.font_family = oversized;
    try std.testing.expectError(error.WriteFailed, runtime.save(std.testing.io, tmp.dir, changed));
    try std.testing.expectEqualStrings(second_reference, runtime.value.ai.providers[0].api_key_ref.?);
    try std.testing.expectEqualStrings("owned-second", runtime.value.ai.providers[0].api_key);
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
}

test "credential settings window saves a new key then provider rename without stale refs" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var providers = [_]config.AiProvider{.{ .name = "fixture", .api_key = "owned-first" }};
    var initial: config.Config = .{};
    initial.ai.providers = &providers;
    initial.ai.provider_count = 1;
    try store.save(std.testing.io, tmp.dir, "config.toml", initial);
    var runtime = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    var controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, runtime.value);
    defer controller.deinit();
    const first_reference = try std.testing.allocator.dupe(u8, controller.model.value.ai.providers[0].api_key_ref.?);
    defer std.testing.allocator.free(first_reference);

    var provider = controller.model.value.ai.providers[0];
    provider.api_key = "owned-second";
    try controller.editProvider(0, provider);
    try controller.save(std.testing.io, tmp.dir, &runtime);
    const second_reference = try std.testing.allocator.dupe(u8, runtime.value.ai.providers[0].api_key_ref.?);
    defer std.testing.allocator.free(second_reference);
    try std.testing.expect(!std.mem.eql(u8, first_reference, second_reference));
    try std.testing.expectEqualStrings(second_reference, controller.original.value.ai.providers[0].api_key_ref.?);
    try std.testing.expectEqualStrings(second_reference, controller.model.value.ai.providers[0].api_key_ref.?);
    try std.testing.expect(!controller.model.dirty);
    try std.testing.expectError(error.CredentialMissing, credentials.get(std.testing.allocator, first_reference));

    provider = controller.model.value.ai.providers[0];
    provider.name = "renamed-fixture";
    try controller.editProvider(0, provider);
    try controller.save(std.testing.io, tmp.dir, &runtime);
    try std.testing.expectEqualStrings(second_reference, runtime.value.ai.providers[0].api_key_ref.?);
    try std.testing.expectEqualStrings(second_reference, controller.original.value.ai.providers[0].api_key_ref.?);
    try std.testing.expectEqualStrings("renamed-fixture", controller.model.value.ai.providers[0].name);
    try std.testing.expect(!controller.model.dirty);
    var reloaded = try store.load(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer reloaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("renamed-fixture", reloaded.value.ai.providers[0].name);
    try std.testing.expectEqualStrings(second_reference, reloaded.value.ai.providers[0].api_key_ref.?);
    try std.testing.expectEqualStrings("owned-second", reloaded.value.ai.providers[0].api_key);
    try std.testing.expectEqual(@as(usize, 1), memory.values.count());
}
