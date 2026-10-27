const std = @import("std");
const config = @import("config.zig");
const store = @import("store.zig");
const settings = @import("settings_values.zig");
pub const schema = @import("settings_schema.zig");
pub const paths = @import("paths.zig");

pub const Change = struct { revision: u64, fields: schema.FieldSet };

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
        if (!std.mem.eql(u8, candidate.value.ui.materials.background.path, asset.path) or asset.image.width == 0 or asset.image.height == 0 or asset.image.pixels.len == 0) return error.BackgroundNotPrepared;
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
        return .{ .allocator = allocator, .path = path, .owned = owned, .value = owned.value, .field_revisions = @splat(owned.value.config_revision) };
    }

    /// Prepare an owned candidate before writing, then replace memory only
    /// after the atomic file replacement succeeds. Allocation or IO failure
    /// leaves the previously saved in-memory snapshot valid.
    pub fn save(self: *RuntimeConfig, io: std.Io, dir: std.Io.Dir, candidate: config.Config) !void {
        var prepared = try self.prepare(candidate);
        defer prepared.deinit();
        try self.commitPrepared(io, dir, &prepared);
    }

    pub fn prepare(self: *RuntimeConfig, candidate: config.Config) !Prepared {
        if (self.value.config_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        var next = candidate;
        next.config_revision = self.value.config_revision + 1;
        try next.validate();
        return .{ .expected_revision = self.value.config_revision, .changed_fields = schema.changed(self.value, next), .owned = try Snapshot.init(self.allocator, next) };
    }

    /// Main-thread commit boundary. A stale prepared request never overwrites a
    /// newer commit; callers may merge and prepare again after the rejection.
    pub fn commitPrepared(self: *RuntimeConfig, io: std.Io, dir: std.Io.Dir, prepared: *Prepared) !void {
        if (prepared.expected_revision != self.value.config_revision) return error.StaleConfigRevision;
        const next = if (prepared.owned) |*owned| owned else return error.AlreadyCommitted;
        const same_background = std.mem.eql(u8, next.value.ui.materials.background.path, self.value.ui.materials.background.path);
        if (next.value.ui.materials.background.enabled and !prepared.background_ready and !(self.background_ready and same_background)) return error.BackgroundNotPrepared;
        if (!prepared.theme_ready and !std.mem.eql(u8, next.value.ui.theme, self.value.ui.theme))
            try @import("imported_theme.zig").validateReference(io, dir, self.allocator, next.value.ui.theme);
        next.value = try store.saveWithCredentialRefs(io, dir, self.path, next.value, next.arena.allocator());
        self.owned.deinit();
        self.owned = next.*;
        self.value = next.value;
        self.background_ready = prepared.background_ready or (same_background and self.background_ready);
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

test "runtime config defaults when file is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u16, 64), runtime.value.log.ring_mb);
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
    try std.testing.expectEqualDeep(runtime.value, restarted.value);
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
