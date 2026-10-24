//! SFTP owns its file lifecycle factory and frozen launch source.
const std = @import("std");
const session = @import("../../host/session_host.zig");
const identity = @import("../../host/identity.zig");
const OperationKey = session.OperationKey;
const CloseReceipt = session.CloseReceipt;
const SourceSnapshot = @import("../ssh/connection_source.zig").SourceSnapshot;
pub fn Binding(comptime Host: type) type {
    return struct {
        pub const vtable: session.Adapter.VTable = .{ .create = fileCreate, .cancel = fileCancel, .close = fileClose, .release_stale = fileReleaseStale };
        fn fileCreate(context: *anyopaque, request: session.CreateRequest) !void {
            const self: *Host = @ptrCast(@alignCast(context));
            if (request.spec == .plugin) return @import("../ssh/envelope_binding.zig").Binding(Host).createRemoteEnvelope(self, request, fileCreate);
            const plugin = self.file_plugin orelse return error.FilePluginUnavailable;
            if (request.spec.pluginId() != .sftp) return error.WrongPlugin;
            const original = if (self.pending_source) |source| source.value else blk: {
                for (self.file_sources.items) |source| if (source.handle.session_id == request.handle.session_id) break :blk source.source.value;
                return error.MissingCreateSource;
            };
            try self.file_sources.ensureUnusedCapacity(self.allocator, 1);
            var frozen = try SourceSnapshot.init(self.allocator, original);
            errdefer frozen.deinit();
            // Adapter.create queues only. It cannot install presentation or call
            // SessionHost while the domain is still inside create/retry.
            try plugin.adapter.vtable.create(plugin.adapter.context, request);
            self.file_sources.appendAssumeCapacity(.{ .handle = request.handle, .key = request.key, .source = frozen });
        }

        fn fileCancel(context: *anyopaque, key: OperationKey) CloseReceipt {
            const self: *Host = @ptrCast(@alignCast(context));
            const adapter = (self.file_plugin orelse return .unknown).adapter;
            return adapter.vtable.cancel(adapter.context, key);
        }

        fn fileClose(context: *anyopaque, owner: identity.SessionHandle, key: OperationKey) !CloseReceipt {
            const self: *Host = @ptrCast(@alignCast(context));
            const adapter = (self.file_plugin orelse return error.FilePluginUnavailable).adapter;
            return adapter.vtable.close(adapter.context, owner, key);
        }

        fn fileReleaseStale(context: *anyopaque, owner: identity.SessionHandle, key: OperationKey) void {
            const self: *Host = @ptrCast(@alignCast(context));
            const adapter = (self.file_plugin orelse return).adapter;
            adapter.vtable.release_stale(adapter.context, owner, key);
        }
    };
}
