//! Local owns its process factory; the window only contributes a presentation
//! attachment and records the operation owner returned by SessionHost.
const std = @import("std");
const session = @import("../../host/session_host.zig");
const identity = @import("../../host/identity.zig");
const OperationKey = session.OperationKey;
const CloseReceipt = session.CloseReceipt;
pub fn Binding(comptime Host: type) type {
    return struct {
        pub const vtable: session.Adapter.VTable = .{ .create = localCreate, .cancel = localCancel, .close = close, .release_stale = localReleaseStale };
        fn close(raw: *anyopaque, handle: identity.SessionHandle, key: OperationKey) !CloseReceipt {
            const self: *Host = @ptrCast(@alignCast(raw));
            const mapping = self.findHandle(handle) orelse return .unknown;
            return self.runCloseStep(mapping, key, .close_protocol, false);
        }
        fn localCreate(context: *anyopaque, request: session.CreateRequest) !void {
            const self: *Host = @ptrCast(@alignCast(context));
            self.local_adapter.configureScrollback(self.workspace.app_config.ui.scrollback_limit);
            try self.local_adapter.configureRecording(.{ .io = self.workspace.io, .log = self.workspace.app_config.log });
            var mapping: ?*@typeInfo(@TypeOf(self.mappings.items)).pointer.child = null;
            // SessionHost.retry changes generation before invoking this callback.
            // Only the old, failed/released attempt can reach this reuse path.
            for (self.mappings.items) |*candidate| if (candidate.process != null and candidate.handle.session_id == request.handle.session_id) {
                const previous = candidate.handle;
                self.workspace.unbindLocalTerminal(candidate.legacy_id, previous);
                if (candidate.local_started) self.local_adapter.retire(previous) catch |err| switch (err) {
                    error.StaleSession => {},
                    else => return err,
                };
                try self.workspace.bindSessionOwner(candidate.legacy_id, request.handle);
                const tab = self.workspace.sessionTab(candidate.legacy_id) orelse return error.StaleSession;
                tab.generation = request.handle.generation;
                candidate.* = .{ .process = self.local_adapter, .handle = request.handle, .create_operation = request.key, .legacy_id = tab.id, .legacy_generation = tab.generation, .tab_id = tab.tab_id, .owner = tab.content_owner, .source = null };
                mapping = candidate;
                self.workspace.updateLocalState(tab.id, .starting, "正在启动 zsh…");
                break;
            };
            if (mapping == null) {
                try self.mappings.ensureUnusedCapacity(self.allocator, 1);
                const id = try self.workspace.createLocalSessionDirect(request.handle);
                const tab = self.workspace.sessionTab(id).?;
                self.mappings.appendAssumeCapacity(.{ .process = self.local_adapter, .handle = request.handle, .create_operation = request.key, .legacy_id = id, .legacy_generation = tab.generation, .tab_id = tab.tab_id, .owner = tab.content_owner, .source = null });
                mapping = &self.mappings.items[self.mappings.items.len - 1];
            }
            const adapter = self.local_adapter.adapter();
            // All fallible presentation work precedes process allocation. If the
            // adapter itself throws, it has acquired no process and SessionHost
            // publishes a failed/released attempt in this same pane.
            try adapter.vtable.create(adapter.context, request);
            mapping.?.local_started = true;
        }

        fn localCancel(context: *anyopaque, key: OperationKey) CloseReceipt {
            const self: *Host = @ptrCast(@alignCast(context));
            if (key.owner == .session) if (self.findHandle(key.owner.session)) |mapping|
                self.workspace.unbindLocalTerminal(mapping.legacy_id, mapping.handle);
            const adapter = self.local_adapter.adapter();
            return adapter.vtable.cancel(adapter.context, key);
        }
        fn localReleaseStale(context: *anyopaque, handle: identity.SessionHandle, key: OperationKey) void {
            const self: *Host = @ptrCast(@alignCast(context));
            const adapter = self.local_adapter.adapter();
            adapter.vtable.release_stale(adapter.context, handle, key);
        }
    };
}
