const std = @import("std");
const config = @import("config.zig");
const store = @import("store.zig");
const settings = @import("settings_values.zig");
pub const schema = @import("settings_schema.zig");
pub const paths = @import("paths.zig");

pub const Change = struct { revision: u64, fields: schema.FieldSet };
const default_provider_index = schema.find("ai", "default_provider").?;
const ConfigStamp = struct {
    inode: std.Io.File.INode,
    size: u64,
    modified: std.Io.Timestamp,
    changed: std.Io.Timestamp,
};

/// All allocations are complete before the atomic disk replacement starts.
pub const Prepared = struct {
    expected_revision: u64,
    changed_fields: schema.FieldSet,
    owned: ?Snapshot,
    background_ready: bool = false,
    theme_ready: bool = false,

    /// A prepared registry/installation receipt already resolved this theme.
    pub fn confirmTheme(self: *Prepared, id: []const u8) !void {
        const candidate = self.owned orelse return error.AlreadyCommitted;
        if (!std.mem.eql(u8, candidate.value.ui.theme, id)) return error.ThemeNotPrepared;
        self.theme_ready = true;
    }

    /// Called after worker decoding and the consumer's resource preparation.
    /// No file access or decoding occurs on the configuration commit path.
    pub fn confirmBackground(self: *Prepared, asset: *const config.material.Prepared) !void {
        const candidate = self.owned orelse return error.AlreadyCommitted;
        if (!asset.matches(candidate.value.ui.materials.background) or asset.image.width == 0 or asset.image.height == 0 or asset.image.pixels.len == 0) return error.BackgroundNotPrepared;
        self.background_ready = true;
    }

    pub fn deinit(self: *Prepared) void {
        if (self.owned) |*owned| owned.deinit();
        self.* = undefined;
    }
};

/// A complete configuration copy whose string fields never borrow UI buffers.
/// Runtime and settings-controller snapshots have independent lifetimes.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    value: config.Config,

    pub fn init(allocator: std.mem.Allocator, value: config.Config) !Snapshot {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var copy = value;
        copy.ui.theme = try owned.dupe(u8, value.ui.theme);
        copy.ui.font_family = try owned.dupe(u8, value.ui.font_family);
        copy.ui.font_weight = try owned.dupe(u8, value.ui.font_weight);
        copy.ui.cursor_style = try owned.dupe(u8, value.ui.cursor_style);
        copy.ui.materials.background.path = try owned.dupe(u8, value.ui.materials.background.path);
        copy.transfer.download_dir = try owned.dupe(u8, value.transfer.download_dir);
        copy.ai.extensions = try value.ai.extensions.clone(owned);
        copy.ai.default_provider = try owned.dupe(u8, value.ai.default_provider);
        copy.ai.providers = try owned.dupe(config.AiProvider, value.ai.providers);
        for (copy.ai.providers, value.ai.providers) |*dst, src| {
            dst.* = src;
            dst.name = try owned.dupe(u8, src.name);
            dst.endpoint = try owned.dupe(u8, src.endpoint);
            dst.model = try owned.dupe(u8, src.model);
            dst.api_key = try owned.dupe(u8, src.api_key);
            dst.api_key_ref = if (src.api_key_ref) |reference| try owned.dupe(u8, reference) else null;
            dst.models = try owned.dupe(config.AiModel, src.models);
            for (dst.models, src.models) |*dm, sm| {
                dm.* = sm;
                dm.id = try owned.dupe(u8, sm.id);
            }
        }
        const preferences = try owned.alloc(config.PluginPreference, value.plugin_preferences.len);
        for (preferences, value.plugin_preferences) |*destination, source| destination.* = .{ .plugin_id = try owned.dupe(u8, source.plugin_id), .key = try owned.dupe(u8, source.key), .value = try owned.dupe(u8, source.value) };
        copy.plugin_preferences = preferences;
        copy.ssh.term = try owned.dupe(u8, value.ssh.term);
        copy.ssh.socks_bind = try owned.dupe(u8, value.ssh.socks_bind);
        copy.transfer.conflict_policy = try owned.dupe(u8, value.transfer.conflict_policy);
        copy.notify.quiet_hours = try owned.dupe(u8, value.notify.quiet_hours);
        copy.log.export_format = try owned.dupe(u8, value.log.export_format);
        return .{ .arena = arena, .value = copy };
    }

    pub fn deinit(self: *Snapshot) void {
        for (self.value.ai.extensions.servers) |server| inline for (.{ "environment", "headers" }) |key| for (@field(server, key)) |entry| if (entry.secret) {
            std.crypto.secureZero(u8, @constCast(entry.value));
        };
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Owns both the loaded path and the current configuration snapshot.
/// The directory passed to save/update must be the same base used to load a
/// relative path; the application's user-data paths are absolute.
pub const RuntimeConfig = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    owned: Snapshot,
    value: config.Config,
    field_revisions: [schema.field_count]u64 = @splat(1),
    background_ready: bool = false,
    disk_baseline: store.ConfigBaseline = .{},
    observed_disk: store.ConfigBaseline = .{},
    observed_stamp: ?ConfigStamp = null,
    external_provider_revision: u64 = 0,

    pub fn loadOrDefault(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, sub_path: []const u8) !RuntimeConfig {
        if (sub_path.len == 0) return error.InvalidConfigPath;
        const path = try allocator.dupe(u8, sub_path);
        errdefer allocator.free(path);
        var loaded = store.load(io, dir, allocator, path) catch |err| switch (err) {
            error.FileNotFound => {
                const owned = try Snapshot.init(allocator, .{});
                return .{ .allocator = allocator, .path = path, .owned = owned, .value = owned.value };
            },
            else => return err,
        };
        defer loaded.deinit(allocator);
        const owned = try Snapshot.init(allocator, loaded.value);
        const baseline = store.ConfigBaseline.fromSource(loaded.source);
        return .{ .allocator = allocator, .path = path, .owned = owned, .value = owned.value, .field_revisions = @splat(owned.value.config_revision), .disk_baseline = baseline, .observed_disk = baseline };
    }

    /// Only Provider settings are hot reloaded. Other file changes still
    /// invalidate the write baseline so an app save cannot discard them.
    pub fn reloadProviders(self: *RuntimeConfig, io: std.Io, dir: std.Io.Dir) !bool {
        const stat = dir.statFile(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.observed_stamp = null;
                self.observed_disk = .{};
                return false;
            },
            else => return err,
        };
        const stamp: ConfigStamp = .{ .inode = stat.inode, .size = stat.size, .modified = stat.mtime, .changed = stat.ctime };
        if (std.meta.eql(self.observed_stamp, @as(?ConfigStamp, stamp))) return false;
        if (stat.kind != .file) return error.InvalidConfigPath;
        const source = (try store.readConfigSource(io, dir, self.allocator, self.path)) orelse return false;
        var owns_source = true;
        defer if (owns_source) self.allocator.free(source);
        const baseline = store.ConfigBaseline.fromSource(source);
        if (std.meta.eql(baseline, self.observed_disk)) {
            self.observed_stamp = stamp;
            return false;
        }
        var loaded = try store.decodeConfig(self.allocator, source);
        owns_source = false;
        defer loaded.deinit(self.allocator);

        var fields = schema.changed(self.value, loaded.value);
        var provider_fields: schema.FieldSet = .empty;
        if (fields.isSet(schema.providers_index)) provider_fields.set(schema.providers_index);
        if (fields.isSet(default_provider_index)) provider_fields.set(default_provider_index);
        fields.toggleSet(provider_fields);
        if (provider_fields.count() != 0) {
            var prepared = try self.prepare(schema.merge(self.value, loaded.value, provider_fields));
            defer prepared.deinit();
            self.publish(&prepared, self.background_ready);
            self.external_provider_revision = self.value.config_revision;
        }
        // The sidebar width is persisted by its resize action outside the
        // settings editor's field list.
        if (fields.count() == 0 and self.value.ui.sidebar_width == loaded.value.ui.sidebar_width) self.disk_baseline = baseline;
        self.observed_disk = baseline;
        self.observed_stamp = stamp;
        return provider_fields.count() != 0;
    }

    /// Prepare an owned candidate before writing, then replace memory only
    /// after the atomic file replacement succeeds. Allocation or IO failure
    /// leaves the previously saved in-memory snapshot valid.
    pub fn save(self: *RuntimeConfig, io: std.Io, dir: std.Io.Dir, candidate: config.Config) !void {
        var prepared = try self.prepare(candidate);
        defer prepared.deinit();
        try self.commitPrepared(io, dir, &prepared);
    }

    /// Startup restores the saved image without a configuration commit. Call
    /// only after decoding and renderer preparation have both succeeded.
    pub fn confirmLoadedBackground(self: *RuntimeConfig, asset: *const config.material.Prepared) !void {
        if (!asset.matches(self.value.ui.materials.background) or asset.image.width == 0 or asset.image.height == 0 or asset.image.pixels.len == 0) return error.BackgroundNotPrepared;
        self.background_ready = true;
    }

    pub fn prepare(self: *RuntimeConfig, candidate: config.Config) !Prepared {
        if (self.value.config_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        var next = candidate;
        next.config_revision = self.value.config_revision + 1;
        const changed = schema.changed(self.value, next);
        var policy_changes = changed;
        // A running turn owns its Provider snapshot. Catalog edits only
        // change future turns, so do not revoke the current tool authority.
        policy_changes.unset(schema.providers_index);
        policy_changes.unset(default_provider_index);
        policy_changes.unset(schema.extensions_index);
        policy_changes.unset(schema.find("ai", "child_context_mode").?);
        policy_changes.unset(schema.find("ai", "child_reuse_policy").?);
        policy_changes.unset(schema.find("ai", "permission_mode").?);
        policy_changes.unset(schema.find("ai", "execution_mode").?);
        policy_changes.unset(schema.default_effort_index);
        next.agent_policy_revision = if (policy_changes.count() == 0) self.value.agentPolicyRevision() else next.config_revision;
        try next.validate();
        return .{ .expected_revision = self.value.config_revision, .changed_fields = changed, .owned = try Snapshot.init(self.allocator, next) };
    }

    /// Main-thread commit boundary. A stale prepared request never overwrites a
    /// newer commit; callers may merge and prepare again after the rejection.
    pub fn commitPrepared(self: *RuntimeConfig, io: std.Io, dir: std.Io.Dir, prepared: *Prepared) !void {
        if (prepared.expected_revision != self.value.config_revision) return error.StaleConfigRevision;
        const next = if (prepared.owned) |*owned| owned else return error.AlreadyCommitted;
        const same_background = next.value.ui.materials.background.source == self.value.ui.materials.background.source and std.mem.eql(u8, next.value.ui.materials.background.path, self.value.ui.materials.background.path);
        if (next.value.ui.materials.background.enabled and !prepared.background_ready and !(self.background_ready and same_background)) return error.BackgroundNotPrepared;
        if (!prepared.theme_ready and !std.mem.eql(u8, next.value.ui.theme, self.value.ui.theme))
            try @import("imported_theme.zig").validateReference(io, dir, self.allocator, next.value.ui.theme);
        const saved = try store.saveWithCredentialRefs(io, dir, self.path, next.value, next.arena.allocator(), self.disk_baseline);
        next.value = saved.value;
        self.disk_baseline = saved.baseline;
        self.observed_disk = saved.baseline;
        self.observed_stamp = null;
        self.publish(prepared, prepared.background_ready or (same_background and self.background_ready));
    }

    fn publish(self: *RuntimeConfig, prepared: *Prepared, background_ready: bool) void {
        const next = &prepared.owned.?;
        self.owned.deinit();
        self.owned = next.*;
        self.value = next.value;
        self.background_ready = background_ready;
        for (&self.field_revisions, 0..) |*revision, index| if (prepared.changed_fields.isSet(index)) {
            revision.* = next.value.config_revision;
        };
        prepared.owned = null;
    }

    /// Consumers keep their last revision and subscribe only to relevant fields.
    /// Per-field revisions preserve changes even when several commits occurred
    /// between two consumer reads.
    pub fn changesSince(self: *const RuntimeConfig, revision: u64, interests: schema.FieldSet) ?Change {
        var changed: schema.FieldSet = .empty;
        for (self.field_revisions, 0..) |field_revision, index| {
            if (field_revision > revision and interests.isSet(index)) changed.set(index);
        }
        if (changed.count() == 0) return null;
        return .{ .revision = self.value.config_revision, .fields = changed };
    }

    /// Model discovery only depends on providers and the default provider.
    pub fn modelDiscoveryRevision(self: *const RuntimeConfig) u64 {
        return @max(self.field_revisions[schema.providers_index], self.field_revisions[default_provider_index]);
    }

    /// Changing the selected effort does not invalidate an open picker.
    pub fn composerRevision(self: *const RuntimeConfig) u64 {
        var revision: u64 = 1;
        for (self.field_revisions, 0..) |field_revision, index| {
            if (index != schema.default_effort_index) revision = @max(revision, field_revision);
        }
        return revision;
    }

    /// Validation and persistence share the path selected at load time.
    pub fn updateSetting(self: *RuntimeConfig, io: std.Io, dir: std.Io.Dir, section: []const u8, key: []const u8, next: settings.Value) !void {
        var candidate = self.value;
        try settings.writeConfig(&candidate, section, key, next);
        try self.save(io, dir, candidate);
    }

    pub fn deinit(self: *RuntimeConfig) void {
        self.owned.deinit();
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

test "runtime setting update persists to its owned non-default path and reloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path = [_]u8{ 'n', 'e', 's', 't', 'e', 'd', '/', 's', 'e', 't', 't', 'i', 'n', 'g', 's', '.', 't', 'o', 'm', 'l' };
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, &path);
    defer runtime.deinit();
    @memset(&path, 'x');
    try runtime.updateSetting(std.testing.io, tmp.dir, "ui", "font_size", .{ .unsigned = 18 });
    try std.testing.expectEqual(@as(u8, 18), runtime.value.ui.font_size);
    try std.testing.expectEqualStrings("nested/settings.toml", runtime.path);
    var restarted = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "nested/settings.toml");
    defer restarted.deinit();
    try std.testing.expectEqual(@as(u8, 18), restarted.value.ui.font_size);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "config.toml", .{}));
    try std.testing.expectError(error.OutOfRange, runtime.updateSetting(std.testing.io, tmp.dir, "ui", "font_size", .{ .unsigned = 2 }));
    try std.testing.expectEqual(@as(u8, 18), runtime.value.ui.font_size);
}

test "provider reload retries a transient credential error for the same file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = "config.toml";
    var runtime = try RuntimeConfig.loadOrDefault(io, tmp.dir, std.testing.allocator, file);
    defer runtime.deinit();
    var credentials: store.credentials.MemoryBackend = .{ .denied = true };
    defer credentials.deinit();
    const previous = store.credentials.useBackendForTesting(credentials.backend());
    defer store.credentials.restoreBackendForTesting(previous);
    const source = "[ai]\ndefault_provider=\"new\"\n[[ai.providers]]\nid=\"new\"\n" ++
        "api_key_ref=\"zw1_0000000000000000000000000000000000000000000000000000000000000000\"\n";
    try tmp.dir.writeFile(io, .{ .sub_path = file, .data = source });

    try std.testing.expectError(error.CredentialDenied, runtime.reloadProviders(io, tmp.dir));
    try std.testing.expectEqual(@as(usize, 0), runtime.value.ai.provider_count);
    credentials.denied = false;
    try std.testing.expect(try runtime.reloadProviders(io, tmp.dir));
    try std.testing.expectEqualStrings("new", runtime.value.ai.providers[0].name);
    try std.testing.expect(!try runtime.reloadProviders(io, tmp.dir));
}

test "runtime config defaults when file is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u16, 64), runtime.value.log.ring_mb);
}

test "AI defaults persist across restart while existing agents keep their choices and policy fence" {
    const Controls = @import("../ai/assistant_store.zig").Controls;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    var existing: Controls = .{};
    existing.ensureDefaults(runtime.value.ai);
    const fence = runtime.value.agentPolicyRevision();
    try runtime.updateSetting(std.testing.io, tmp.dir, "ai", "permission_mode", .{ .text = "auto" });
    try runtime.updateSetting(std.testing.io, tmp.dir, "ai", "execution_mode", .{ .text = "new_pty" });
    existing.ensureDefaults(runtime.value.ai);
    try std.testing.expectEqual(config.PermissionMode.confirm, existing.permission.?);
    try std.testing.expectEqual(config.ExecutionMode.auto, existing.execution_mode.?);
    try std.testing.expectEqual(fence, runtime.value.agentPolicyRevision());
    try std.testing.expect(runtime.value.config_revision > fence);
    var restarted = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer restarted.deinit();
    var next: Controls = .{};
    next.ensureDefaults(restarted.value.ai);
    try std.testing.expectEqual(config.PermissionMode.auto, next.permission.?);
    try std.testing.expectEqual(config.ExecutionMode.new_pty, next.execution_mode.?);
    try runtime.updateSetting(std.testing.io, tmp.dir, "ai", "session_retention", .{ .text = "keep" });
    try std.testing.expectEqual(runtime.value.config_revision, runtime.value.agentPolicyRevision());
}

test "reasoning effort default persists atomically without invalidating discovery or policy" {
    const Effort = @import("../ai/provider.zig").Effort;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    try std.testing.expect(runtime.value.ai.default_effort == null);
    const policy = runtime.value.agentPolicyRevision();
    const discovery = runtime.modelDiscoveryRevision();
    const composer = runtime.composerRevision();
    try runtime.updateSetting(std.testing.io, tmp.dir, "ai", "default_effort", .{ .text = "high" });
    try std.testing.expectEqual(Effort.high, runtime.value.ai.default_effort.?);
    try std.testing.expectEqual(policy, runtime.value.agentPolicyRevision());
    try std.testing.expectEqual(discovery, runtime.modelDiscoveryRevision());
    try std.testing.expectEqual(composer, runtime.composerRevision());
    try std.testing.expectError(error.InvalidValue, runtime.updateSetting(std.testing.io, tmp.dir, "ai", "default_effort", .{ .text = "invalid" }));
    var restarted = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer restarted.deinit();
    try std.testing.expectEqual(Effort.high, restarted.value.ai.default_effort.?);
    try restarted.updateSetting(std.testing.io, tmp.dir, "ai", "default_effort", .{ .text = "none" });
    var again = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer again.deinit();
    try std.testing.expectEqual(Effort.none, again.value.ai.default_effort.?);

    var blocked = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "blocked/config.toml");
    defer blocked.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "not a directory" });
    try std.testing.expectError(error.NotDir, blocked.updateSetting(std.testing.io, tmp.dir, "ai", "default_effort", .{ .text = "high" }));
    try std.testing.expect(blocked.value.ai.default_effort == null);
}

test "loaded background permits AI defaults while unprepared replacements remain blocked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var initial: config.Config = .{};
    initial.ui.materials.background = .{ .enabled = true, .source = .directory, .path = "/fixture/backgrounds" };
    try store.save(std.testing.io, tmp.dir, "config.toml", initial);
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    const revision = runtime.value.config_revision;
    try std.testing.expectError(error.BackgroundNotPrepared, runtime.updateSetting(std.testing.io, tmp.dir, "ai", "permission_mode", .{ .text = "auto" }));
    var pixels = [_]u8{ 255, 255, 255, 255 };
    var path = "/fixture/backgrounds".*;
    var asset: config.material.Prepared = .{ .draft_id = 1, .asset_revision = 1, .path = &path, .source = .file, .image = .{ .pixels = &pixels, .width = 1, .height = 1 } };
    try std.testing.expectError(error.BackgroundNotPrepared, runtime.confirmLoadedBackground(&asset));
    asset.source = .directory;
    asset.image.width = 0;
    try std.testing.expectError(error.BackgroundNotPrepared, runtime.confirmLoadedBackground(&asset));
    try std.testing.expect(!runtime.background_ready);
    asset.image.width = 1;
    try runtime.confirmLoadedBackground(&asset);
    try std.testing.expectEqual(revision, runtime.value.config_revision);
    try runtime.updateSetting(std.testing.io, tmp.dir, "ai", "permission_mode", .{ .text = "auto" });
    try runtime.updateSetting(std.testing.io, tmp.dir, "ai", "execution_mode", .{ .text = "new_pty" });
    try std.testing.expectEqual(config.PermissionMode.auto, runtime.value.ai.permission_mode);
    try std.testing.expectEqual(config.ExecutionMode.new_pty, runtime.value.ai.execution_mode);
    var candidate = runtime.value;
    candidate.ui.materials.background.path = "/fixture/other-backgrounds";
    try std.testing.expectError(error.BackgroundNotPrepared, runtime.save(std.testing.io, tmp.dir, candidate));
    candidate = runtime.value;
    candidate.ui.materials.background.source = .file;
    try std.testing.expectError(error.BackgroundNotPrepared, runtime.save(std.testing.io, tmp.dir, candidate));
    var restarted = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer restarted.deinit();
    try std.testing.expectEqual(config.PermissionMode.auto, restarted.value.ai.permission_mode);
    try std.testing.expectEqual(config.ExecutionMode.new_pty, restarted.value.ai.execution_mode);
    try std.testing.expect(!restarted.background_ready);
}

test "failed AI default persistence preserves defaults and agent policy fence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "blocked/config.toml");
    defer runtime.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "not a directory" });
    try std.testing.expectError(error.NotDir, runtime.updateSetting(std.testing.io, tmp.dir, "ai", "permission_mode", .{ .text = "auto" }));
    try std.testing.expectEqual(config.PermissionMode.confirm, runtime.value.ai.permission_mode);
    try std.testing.expectEqual(@as(u64, 1), runtime.value.config_revision);
    try std.testing.expectEqual(@as(u64, 1), runtime.value.agentPolicyRevision());
}

test "runtime snapshot owns edited strings after the caller buffer changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    var font = [_]u8{ 'I', 'n', 'p', 'u', 't', ' ', 'M', 'o', 'n', 'o' };
    try runtime.updateSetting(std.testing.io, tmp.dir, "ui", "font_family", .{ .text = &font });
    @memset(&font, 'x');
    try std.testing.expectEqualStrings("Input Mono", runtime.value.ui.font_family);
    var restarted = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer restarted.deinit();
    try std.testing.expectEqualStrings("Input Mono", restarted.value.ui.font_family);
}

test "failed persistence does not replace the runtime snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "blocked/config.toml");
    defer runtime.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "not a directory" });
    try std.testing.expectError(error.NotDir, runtime.updateSetting(std.testing.io, tmp.dir, "ui", "font_family", .{ .text = "Edited Mono" }));
    try std.testing.expectEqualStrings("Monaco", runtime.value.ui.font_family);
    try std.testing.expectEqualStrings("blocked/config.toml", runtime.path);
}

test "runtime config owns loaded source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var expected: config.Config = .{};
    expected.ui.font_family = "Loaded Mono";
    expected.log.ring_mb = 7;
    expected.log.checkpoint_sec = 9;
    try store.save(std.testing.io, tmp.dir, "config.toml", expected);
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    try std.testing.expectEqualStrings("Loaded Mono", runtime.value.ui.font_family);
    try std.testing.expectEqual(@as(u16, 7), runtime.value.log.ring_mb);
    try std.testing.expectEqual(@as(u16, 9), runtime.value.log.checkpoint_sec);
}

test {
    _ = paths;
}

test "extended snapshot strings remain owned after input buffers mutate" {
    var term = [_]u8{ 'v', 't', '1', '0', '0' };
    var bind = [_]u8{ '0', '.', '0', '.', '0', '.', '0' };
    var quiet = [_]u8{ '2', '3', ':', '3', '0', '-', '0', '7', ':', '1', '5' };
    var format = [_]u8{ 'c', 'a', 's', 't' };
    var candidate: config.Config = .{};
    candidate.ssh.term = &term;
    candidate.ssh.socks_bind = &bind;
    candidate.notify.quiet_hours = &quiet;
    candidate.log.export_format = &format;
    var owned = try Snapshot.init(std.testing.allocator, candidate);
    defer owned.deinit();
    @memset(&term, 'x');
    @memset(&bind, 'x');
    @memset(&quiet, 'x');
    @memset(&format, 'x');
    try std.testing.expectEqualStrings("vt100", owned.value.ssh.term);
    try std.testing.expectEqualStrings("0.0.0.0", owned.value.ssh.socks_bind);
    try std.testing.expectEqualStrings("23:30-07:15", owned.value.notify.quiet_hours);
    try std.testing.expectEqualStrings("cast", owned.value.log.export_format);
}

test "extended settings persist together and reload from the same path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "settings.toml");
    defer runtime.deinit();
    var candidate = runtime.value;
    try settings.writeConfig(&candidate, "ssh", "connect_timeout_sec", .{ .unsigned = 45 });
    try settings.writeConfig(&candidate, "ssh", "term", .{ .text = "vt100" });
    try settings.writeConfig(&candidate, "transfer", "resume", .{ .boolean = false });
    try settings.writeConfig(&candidate, "transfer", "max_tasks", .{ .unsigned = 5 });
    try settings.writeConfig(&candidate, "notify", "quiet_hours", .{ .text = "23:30-07:15" });
    try settings.writeConfig(&candidate, "log", "retention_days", .{ .unsigned = 30 });
    try settings.writeConfig(&candidate, "completion", "enabled", .{ .boolean = false });
    try runtime.save(std.testing.io, tmp.dir, candidate);
    var restarted = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "settings.toml");
    defer restarted.deinit();
    // The agent policy fence is runtime-only; persisted fields still round-trip.
    var persisted = runtime.value;
    persisted.agent_policy_revision = null;
    try std.testing.expectEqualDeep(persisted, restarted.value);
    try std.testing.expectEqual(runtime.value.agentPolicyRevision(), restarted.value.agentPolicyRevision());
    try std.testing.expectEqual(@as(u16, 45), restarted.value.ssh.connect_timeout_sec);
    try std.testing.expect(!restarted.value.transfer.@"resume");
    try std.testing.expect(!restarted.value.completion.enabled);
}

test "invalid theme references do not replace saved configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    var candidate = runtime.value;
    candidate.ui.theme = "dracula";
    try runtime.save(std.testing.io, tmp.dir, candidate);
    candidate = runtime.value;
    candidate.ui.theme = "unknown-preset";
    try std.testing.expectError(error.UnknownTheme, runtime.save(std.testing.io, tmp.dir, candidate));
    candidate.ui.theme = "missing.itermcolors";
    try std.testing.expectError(error.FileNotFound, runtime.save(std.testing.io, tmp.dir, candidate));
    try std.testing.expectEqualStrings("dracula", runtime.value.ui.theme);
    var restarted = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer restarted.deinit();
    try std.testing.expectEqualStrings("dracula", restarted.value.ui.theme);
}

test "revision persists and subscribers see their fields across intervening commits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    const baseline_revision = runtime.value.config_revision;
    var interest: schema.FieldSet = .empty;
    const font = schema.find("ui", "font_size").?;
    interest.set(font);
    try runtime.updateSetting(std.testing.io, tmp.dir, "ui", "font_size", .{ .unsigned = 18 });
    const font_revision = runtime.value.config_revision;
    try runtime.updateSetting(std.testing.io, tmp.dir, "ssh", "term", .{ .text = "vt100" });
    const change = runtime.changesSince(baseline_revision, interest).?;
    try std.testing.expectEqual(@as(usize, 1), change.fields.count());
    try std.testing.expect(change.fields.isSet(font));
    try std.testing.expectEqual(runtime.value.config_revision, change.revision);
    try std.testing.expect(runtime.changesSince(font_revision, interest) == null);
    var reloaded = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer reloaded.deinit();
    try std.testing.expectEqual(runtime.value.config_revision, reloaded.value.config_revision);
}

test "exhausted revision refuses persistence and retains runtime" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var initial: config.Config = .{};
    initial.config_revision = std.math.maxInt(u64);
    try store.save(std.testing.io, tmp.dir, "config.toml", initial);
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    try std.testing.expectError(error.RevisionExhausted, runtime.updateSetting(std.testing.io, tmp.dir, "ui", "font_size", .{ .unsigned = 18 }));
    try std.testing.expectEqual(std.math.maxInt(u64), runtime.value.config_revision);
    try std.testing.expectEqual(@as(u8, 14), runtime.value.ui.font_size);
}

test "full line-height precision survives persistence without rounded writeback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    const exact: f32 = 11.0 / 7.0;
    try runtime.updateSetting(std.testing.io, tmp.dir, "ui", "line_height", .{ .decimal = exact });
    var loaded = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer loaded.deinit();
    try std.testing.expectEqual(exact, loaded.value.ui.line_height);
    try std.testing.expectApproxEqAbs(@as(f32, 22), loaded.value.ui.line_height * 14, 0.00001);
    try std.testing.expectError(error.OutOfRange, runtime.updateSetting(std.testing.io, tmp.dir, "ui", "line_height", .{ .decimal = std.math.inf(f32) }));
}
