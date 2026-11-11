//! Production contributions are always present. Only this composition root
//! selects the additional acceptance fixture.
const std = @import("std");
const registry = @import("../host/plugin_registry.zig");
const presentation = @import("../host/plugin_ui_contract.zig");
const frames = @import("../host/frame_budget.zig");
const bmc = @import("bmc_ikvm/plugin.zig");
const web = @import("web/plugin.zig");
const ledger = @import("bmc_ikvm/management_journal.zig");

pub fn Bundle(comptime acceptance_plugins: bool) type {
    return struct {
        const Self = @This();
        const Resources = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            directory: std.Io.Dir,
            frame_budget: frames.Budget = frames.Budget.init(frames.application_bytes),
            journal_backend: ledger.FileBackend,
            plugin: ?*bmc.Plugin = null,
            web_plugin: ?*web.Plugin = null,
            fixture: if (acceptance_plugins) ?*@import("fixture_probe/plugin.zig").Plugin else void = if (acceptance_plugins) null else {},
        };

        // Backend contexts and reservations borrow Resources, never this
        // return-by-value Bundle. Moving the Bundle cannot invalidate them.
        resources: ?*Resources,
        manifest_entries: [if (acceptance_plugins) 3 else 2]registry.PluginManifest,
        renderer_entries: [if (acceptance_plugins) 3 else 2]presentation.RendererDefinition,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, data_directory: []const u8) !Self {
            const resources = try allocator.create(Resources);
            errdefer allocator.destroy(resources);
            const directory = try openDataDirectory(io, data_directory);
            errdefer directory.close(io);
            resources.* = .{
                .allocator = allocator,
                .io = io,
                .directory = directory,
                .journal_backend = .{ .io = io, .dir = directory, .filename = "bmc-management-v1.json" },
            };
            const plugin = try bmc.Plugin.init(allocator, .{ .frame_budget = &resources.frame_budget, .journal_backend = try resources.journal_backend.backend() });
            // init has not exposed a factory or started a worker yet.
            errdefer plugin.deinit() catch unreachable;
            resources.plugin = plugin;
            const web_plugin = try web.Plugin.init(allocator);
            errdefer web_plugin.deinit() catch unreachable;
            resources.web_plugin = web_plugin;
            if (comptime acceptance_plugins) {
                const fixture = try @import("fixture_probe/plugin.zig").Plugin.init(allocator);
                resources.fixture = fixture;
                return .{ .resources = resources, .manifest_entries = .{ plugin.manifest(), web_plugin.manifest(), fixture.manifest() }, .renderer_entries = .{ plugin.renderer(), web_plugin.renderer(), fixture.renderer() } };
            }
            return .{ .resources = resources, .manifest_entries = .{ plugin.manifest(), web_plugin.manifest() }, .renderer_entries = .{ plugin.renderer(), web_plugin.renderer() } };
        }
        pub fn manifests(self: *const Self) []const registry.PluginManifest {
            return if (self.resources != null) &self.manifest_entries else &.{};
        }
        pub fn renderers(self: *const Self) []const presentation.RendererDefinition {
            return if (self.resources != null) &self.renderer_entries else &.{};
        }
        pub fn frameBudget(self: *Self) *frames.Budget {
            return &self.resources.?.frame_budget;
        }
        /// Pending/unknown cleanup retains the actual resource owner, including
        /// the plugin and its borrowed journal/budget, for a later drain/retry.
        pub fn deinit(self: *Self) !void {
            const resources = self.resources orelse return;
            if (resources.web_plugin) |plugin| {
                try plugin.deinit();
                resources.web_plugin = null;
            }
            if (resources.plugin) |plugin| {
                try plugin.deinit();
                resources.plugin = null;
            }
            try resources.frame_budget.deinit();
            if (comptime acceptance_plugins) if (resources.fixture) |fixture| fixture.deinit();
            resources.directory.close(resources.io);
            const allocator = resources.allocator;
            allocator.destroy(resources);
            self.resources = null;
        }
    };
}

/// Startup already prepares the application-owned private data directory.
/// Open the existing path component by component so a symlink cannot redirect
/// the durable journal. Composition never creates a fallback HOME directory.
fn openDataDirectory(io: std.Io, path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path) or std.mem.trim(u8, path, "/").len == 0) return error.InvalidPluginDataDirectory;
    var current = try std.Io.Dir.openDirAbsolute(io, "/", .{ .follow_symlinks = false });
    errdefer current.close(io);
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidPluginDataDirectory;
        const next = try current.openDir(io, component, .{ .follow_symlinks = false });
        current.close(io);
        current = next;
    }
    return current;
}
