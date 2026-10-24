//! Static composition is the only place that selects acceptance plugins.
//! Public window/session code receives ordinary registry contributions.
const std = @import("std");
const registry = @import("../host/plugin_registry.zig");
const presentation = @import("../host/plugin_ui_contract.zig");

pub fn Bundle(comptime acceptance_plugins: bool) type {
    return struct {
        const Self = @This();
        plugin: if (acceptance_plugins) *@import("fixture_probe/plugin.zig").Plugin else void,
        manifest_entries: [if (acceptance_plugins) 1 else 0]registry.PluginManifest,
        renderer_entries: [if (acceptance_plugins) 1 else 0]presentation.RendererDefinition,

        pub fn init(allocator: std.mem.Allocator) !Self {
            if (comptime acceptance_plugins) {
                const plugin = try @import("fixture_probe/plugin.zig").Plugin.init(allocator);
                return .{ .plugin = plugin, .manifest_entries = .{plugin.manifest()}, .renderer_entries = .{plugin.renderer()} };
            }
            return .{ .plugin = {}, .manifest_entries = .{}, .renderer_entries = .{} };
        }
        pub fn manifests(self: *const Self) []const registry.PluginManifest {
            return &self.manifest_entries;
        }
        pub fn renderers(self: *const Self) []const presentation.RendererDefinition {
            return &self.renderer_entries;
        }
        pub fn deinit(self: *Self) void {
            if (comptime acceptance_plugins) self.plugin.deinit();
        }
    };
}
