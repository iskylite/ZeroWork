//! SSH owns remote creation/retry and its transport lifecycle factory.
const std = @import("std");
const session = @import("../../host/session_host.zig");
const identity = @import("../../host/identity.zig");
const OperationKey = session.OperationKey;
const CloseReceipt = session.CloseReceipt;
const SourceSnapshot = @import("connection_source.zig").SourceSnapshot;
pub fn Binding(comptime Host: type) type {
    return struct {
        pub const vtable: session.Adapter.VTable = .{ .create = adapterCreate, .cancel = adapterCancel, .close = close, .release_stale = adapterReleaseStale };
        fn adapterCreate(context: *anyopaque, request: session.CreateRequest) !void {
            const self: *Host = @ptrCast(@alignCast(context));
            if (request.spec == .plugin) return @import("envelope_binding.zig").Binding(Host).createRemoteEnvelope(self, request, adapterCreate);
            if (request.purpose == .socks_background) return (self.domain.backgrounds orelse return error.BackgroundHostUnavailable).queue(request);
            if (self.pending_source == null) for (self.mappings.items) |*mapping| {
                // SessionHost has already advanced the generation before
                // invoking this factory. The mapping still owns the previous
                // generation until retrySshSession succeeds.
                if (mapping.handle.session_id != request.handle.session_id or !self.supportsIntegration(request.handle, "transport_loss")) continue;
                // The successor owns the same tab and Runtime, not another pane.
                try self.workspace.retrySshSession(mapping.legacy_id, request.key);
                const tab = self.workspace.sessionTab(mapping.legacy_id) orelse return error.StaleSession;
                mapping.handle = request.handle;
                mapping.create_operation = request.key;
                mapping.legacy_generation = tab.generation;
                mapping.owner = tab.content_owner;
                mapping.connected_received = false;
                mapping.ready_published = false;
                mapping.attached_published = false;
                mapping.failed_received = false;
                mapping.failed_published = false;
                mapping.cleanup_received = false;
                mapping.cleanup_unknown_received = false;
                mapping.runtime_loss_received = false;
                mapping.failure_len = 0;
                return;
            };
            const source = if (self.pending_source) |source| source.value else blk: {
                // A retry uses the original immutable source, never today's asset.
                for (self.mappings.items) |mapping| if (mapping.handle.session_id == request.handle.session_id) {
                    if (mapping.source) |source| break :blk source.value;
                };
                return error.MissingCreateSource;
            };
            try self.mappings.ensureUnusedCapacity(self.allocator, 1);
            var frozen = try SourceSnapshot.init(self.allocator, source);
            errdefer frozen.deinit();
            // The operation-aware entry copies these exact values into its
            // ConnectJob. Restore the live sources before returning to event dispatch.
            const original_config = self.workspace.app_config;
            const original_hosts = self.workspace.registry.hosts;
            self.workspace.app_config = &frozen.value.global_config;
            self.workspace.registry.hosts = @constCast(frozen.value.route_hosts);
            defer self.workspace.app_config = original_config;
            defer self.workspace.registry.hosts = original_hosts;
            const original_shared = self.workspace.pending_shared_connection;
            self.workspace.pending_shared_connection = self.pending_shared_connection;
            defer self.workspace.pending_shared_connection = original_shared;
            const id = try self.workspace.createSessionDirectForOperation(frozen.value.host, frozen.value.host_id, frozen.value.source_index, frozen.value.initial_input, request.key);
            const tab = self.workspace.sessionTab(id) orelse unreachable;
            self.mappings.appendAssumeCapacity(.{ .handle = request.handle, .create_operation = request.key, .legacy_id = id, .legacy_generation = tab.generation, .tab_id = tab.tab_id, .owner = tab.content_owner, .source = frozen });
            const mapping = &self.mappings.items[self.mappings.items.len - 1];
            // Once the tab/job exists, failures use receipts rather than throwing a
            // factory error that would incorrectly claim no resource was acquired.
            self.workspace.bindSessionOwner(id, request.handle) catch |err| {
                mapping.recordFailure(@errorName(err));
                self.workspace.cancelSessionCreation(id);
                return;
            };
            mapping.owner = .{ .session = request.handle };
        }

        fn adapterCancel(context: *anyopaque, key: OperationKey) CloseReceipt {
            const self: *Host = @ptrCast(@alignCast(context));
            if (key.owner == .session) if (self.domain.backgrounds) |host| if (host.owns(key.owner.session)) return host.cancel(key);
            for (self.mappings.items) |*mapping| if (mapping.create_operation.eql(key)) {
                self.workspace.cancelSessionCreation(mapping.legacy_id);
                const receipt = self.workspace.protocolReleaseStep(mapping.legacy_id);
                if (receipt == .released) mapping.cleanup_received = true;
                return switch (receipt) {
                    .released => .released,
                    .awaiting => .awaiting,
                    .unknown => .unknown,
                };
            };
            return .unknown;
        }

        pub fn close(context: *anyopaque, handle: identity.SessionHandle, key: OperationKey) !CloseReceipt {
            const self: *Host = @ptrCast(@alignCast(context));
            if (self.domain.backgrounds) |host| if (host.owns(handle)) return host.closeStep(handle, key, .close_protocol);
            const mapping = self.findHandle(handle) orelse return .unknown;
            return self.runCloseStep(mapping, key, .close_protocol, false);
        }

        fn adapterReleaseStale(context: *anyopaque, handle: identity.SessionHandle, key: OperationKey) void {
            const self: *Host = @ptrCast(@alignCast(context));
            if (self.domain.backgrounds) |host| if (host.owns(handle)) return host.releaseStale(handle, key);
            const mapping = self.findHandle(handle) orelse return;
            if (!mapping.create_operation.eql(key)) return;
            self.workspace.cancelSessionCreation(mapping.legacy_id);
            _ = self.workspace.protocolRelease(mapping.legacy_id);
        }
    };
}
