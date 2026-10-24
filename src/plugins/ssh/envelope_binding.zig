//! Remote provider envelope-to-engine boundary, shared by SSH and SFTP.
const std = @import("std");
const session = @import("../../host/session_host.zig");
const connection_envelope = @import("../../config/connection_envelope.zig");
const source_codec = @import("connection_source.zig");
const SourceSnapshot = source_codec.SourceSnapshot;
const freezeSource = source_codec.freezeSource;
const sourceSpec = source_codec.sourceSpec;
const workspace_mod = @import("../../ui/workspace.zig");
pub fn Binding(comptime Host: type) type {
    return struct {
        pub fn createRemoteEnvelope(self: *Host, request: session.CreateRequest, create_engine: *const fn (*anyopaque, session.CreateRequest) anyerror!void) !void {
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            var owned_source: ?SourceSnapshot = null;
            defer if (owned_source) |*source| source.deinit();
            const source = if (self.pending_source) |source| source else blk: {
                for (self.mappings.items) |*mapping| if (mapping.handle.session_id == request.handle.session_id) {
                    if (mapping.source) |*frozen| break :blk frozen;
                };
                for (self.file_sources.items) |*previous| if (previous.handle.session_id == request.handle.session_id) break :blk &previous.source;
                const host = try connection_envelope.decodeLegacy(arena.allocator(), request.spec.plugin);
                owned_source = try freezeSource(self.allocator, host, self.workspace.app_config.*, self.workspace.registry.hosts, @backingInt(host.connection_id), self.workspace.registry.indexOf(host.connection_id) orelse workspace_mod.removed_host_index, "");
                break :blk &owned_source.?;
            };
            const payload = try std.json.Stringify.valueAlloc(arena.allocator(), source.value, .{});
            var route: [8]session.RouteHop = undefined;
            var adapted = request;
            adapted.spec = sourceSpec(source.value, &route, payload);
            if (adapted.spec == .saved) adapted.spec.saved.purpose = request.purpose;
            try self.sessions.bindEngineSpec(request.handle, request.key, adapted.spec);
            const previous = self.pending_source;
            const reusing_tab = blk: {
                if (previous != null) break :blk false;
                for (self.mappings.items) |mapping| if (mapping.handle.session_id == request.handle.session_id) break :blk true;
                break :blk false;
            };
            if (!reusing_tab) self.pending_source = source;
            defer self.pending_source = previous;
            try create_engine(self, adapted);
        }
    };
}
