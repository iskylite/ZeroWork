//! Actual SessionHost and Journal failure paths; no network or native window.
const std = @import("std");
const domain = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const a = std.testing.allocator;

const Adapter = struct {
    fn interface(context: *anyopaque) domain.Adapter {
        return .{
            .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.requiredServices(.ssh) },
            .context = context,
            .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = releaseStale },
        };
    }
    fn create(_: *anyopaque, _: domain.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: domain.OperationKey) domain.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: domain.SessionHandle, _: domain.OperationKey) !domain.CloseReceipt {
        return .released;
    }
    fn releaseStale(_: *anyopaque, _: domain.SessionHandle, _: domain.OperationKey) void {}
};

test "retained transfer release publication OOM revokes capabilities before retrying exact receipt" {
    for ([_]bool{ false, true }) |ready| {
        for ([_]domain.CloseReceipt{ .awaiting, .unknown, .released }) |receipt| {
            // First payload allocation and the later event-queue allocation
            // exercise both fallible publication boundaries of a release.
            const failure_points: []const usize = if (receipt == .released) &.{ 0, 1 } else &.{0};
            for (failure_points) |failure_point| {
                var context: u8 = 0;
                var host = try domain.SessionHost.init(a, &.{Adapter.interface(&context)});
                defer host.deinit();
                const target: domain.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
                const original = try host.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "test.invalid", .user = "test" } } }, target);
                try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh)));
                const owner = try host.retainTransferSource(original.handle);
                _ = try host.requestClose(original.handle, .{});
                const first = try host.beginRetainedTransfer(owner, original.handle);
                if (ready) try std.testing.expect(try host.retainedTransferReady(first.binding, first.key));
                try std.testing.expectEqual(ready, host.bindingIsLive(first.binding));
                try std.testing.expectEqual(!ready, host.bindingIsPreparing(first.binding, first.key));
                try std.testing.expect(host.retainedTransferOperationIsCurrent(owner, original.handle, first.key));

                while (host.journal.take()) |event| {
                    var owned = event;
                    owned.deinit();
                }
                host.journal.events.deinit(a);
                host.journal.events = .empty;
                var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = failure_point });
                host.journal.allocator = failing.allocator();
                defer host.journal.allocator = a;
                try std.testing.expectError(error.OutOfMemory, host.retainedTransferReleased(first.binding, first.key, receipt));
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expect(host.journal.take() == null);
                try std.testing.expect(!host.journal.isTerminal(first.key));
                try std.testing.expect(!host.bindingIsLive(first.binding));
                try std.testing.expect(!host.bindingIsPreparing(first.binding, first.key));
                try std.testing.expect(!host.retainedTransferOperationIsCurrent(owner, original.handle, first.key));
                try std.testing.expect(!try host.retainedTransferReady(first.binding, first.key));
                try std.testing.expectError(error.CleanupNotReleased, host.beginRetainedTransfer(owner, original.handle));
                try std.testing.expectError(error.CleanupNotReleased, host.releaseRetainedTransfer(owner, original.handle));

                host.journal.allocator = a;
                try std.testing.expect(try host.retainedTransferReleased(first.binding, first.key, receipt));
                var publication = host.journal.take().?;
                defer publication.deinit();
                try std.testing.expect(publication.value.key.eql(first.key));
                try std.testing.expectEqual(@as(u64, if (ready) 2 else 1), publication.value.sequence);
                switch (receipt) {
                    .released => {
                        try std.testing.expect(publication.value.kind == .completed);
                        var cleanup = host.journal.take().?;
                        defer cleanup.deinit();
                        try std.testing.expect(cleanup.value.key.eql(first.key));
                        try std.testing.expect(cleanup.value.kind == .cleanup_released);
                    },
                    .awaiting, .unknown => {
                        const expected: @TypeOf(publication.value.kind) = if (receipt == .unknown) .cleanup_unknown else .cleanup_progress;
                        try std.testing.expect(publication.value.kind == expected);
                        try std.testing.expectError(error.CleanupNotReleased, host.beginRetainedTransfer(owner, original.handle));
                        try std.testing.expect(try host.retainedTransferReleased(first.binding, first.key, .released));
                    },
                }
                try std.testing.expect(host.journal.isTerminal(first.key));
                const next = try host.beginRetainedTransfer(owner, original.handle);
                try std.testing.expectEqual(first.binding.binding_generation + 1, next.binding.binding_generation);
                try std.testing.expect(!try host.retainedTransferReleased(first.binding, first.key, .released));
                try std.testing.expect(host.bindingIsPreparing(next.binding, next.key));
                try std.testing.expect(try host.retainedTransferReady(next.binding, next.key));
                try std.testing.expect(host.bindingIsLive(next.binding));
                try std.testing.expect(try host.retainedTransferReleased(next.binding, next.key, .released));
                try host.releaseRetainedTransfer(owner, original.handle);
            }
        }
    }
}
