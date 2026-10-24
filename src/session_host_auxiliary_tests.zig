//! Domain auxiliary-transfer identity and receipt gates. No native IO.
const std = @import("std");
const domain = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const a = std.testing.allocator;
const target: domain.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };

const Adapter = struct {
    fn interface(context: *anyopaque) domain.Adapter {
        return .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.requiredServices(.ssh) }, .context = context, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn create(_: *anyopaque, _: domain.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: domain.OperationKey) domain.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: domain.SessionHandle, _: domain.OperationKey) !domain.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: domain.SessionHandle, _: domain.OperationKey) void {}
};
fn source() domain.SessionCreateSpec {
    return .{ .saved = .{ .connection_id = @fromBackingInt(77), .config_revision = 4, .protocol = .ssh, .immutable_config = .{ .endpoint = .{ .host = "target.example", .user = "operator" }, .startup_commands = &.{"original SSH command"} }, .route_snapshot = &.{.{ .endpoint = .{ .host = "bastion.example", .user = "jump" } }} } };
}
fn attach(host: *domain.SessionHost) !domain.Accepted {
    const original = try host.create(source(), target);
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh)));
    try std.testing.expect(try host.attached(original.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }));
    return original;
}
fn clearEvents(host: *domain.SessionHost) void {
    while (host.journal.take()) |event| {
        var value = event;
        value.deinit();
    }
    host.journal.events.deinit(a);
    host.journal.events = .empty;
}

test "auxiliary transfer reserves original attached SSH identity and publishes only actual ready" {
    var context: u8 = 0;
    var host = try domain.SessionHost.init(a, &.{Adapter.interface(&context)});
    defer host.deinit();
    const original = try host.create(source(), target);
    try std.testing.expectError(error.LifecycleDoesNotAllowTransfer, host.beginAuxiliaryTransfer(original.handle));
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh)));
    // SSH advertises optional shared/independent transfer support, but the
    // terminal's ready receipt cannot publish an uninstalled byte service.
    try std.testing.expect(host.registry.descriptor(.ssh).services.has(.transfer));
    try std.testing.expect(!plugins.requiredServices(.ssh).has(.transfer));
    try std.testing.expect(host.queryService(original.handle, .transfer) == .temporarily_unavailable);
    try std.testing.expectError(error.LifecycleDoesNotAllowTransfer, host.beginAuxiliaryTransfer(original.handle));
    try std.testing.expect(try host.attached(original.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }));
    try std.testing.expect(host.queryService(original.handle, .transfer) == .temporarily_unavailable);
    const terminal = host.queryService(original.handle, .terminal).available;
    const first = try host.beginAuxiliaryTransfer(original.handle);
    try std.testing.expect(first.binding.binding_id > terminal.binding_id);
    try std.testing.expect(first.binding.resource_owner == .session and first.binding.resource_owner.session.eql(original.handle));
    try std.testing.expect(first.binding.origin_session.?.eql(original.handle));
    try std.testing.expect(first.key.owner == .session and first.key.owner.session.eql(original.handle));
    try std.testing.expectEqual(original.operation.attempt_id, first.key.attempt_id);
    try std.testing.expect(!original.operation.eql(first.key));
    try std.testing.expectEqualStrings("bastion.example", first.spec.saved.route_snapshot[0].endpoint.host);
    try std.testing.expectEqualStrings("original SSH command", first.spec.saved.immutable_config.startup_commands[0]);
    const repeated = try host.beginAuxiliaryTransfer(original.handle);
    try std.testing.expectEqualDeep(first.binding, repeated.binding);
    try std.testing.expect(first.key.eql(repeated.key));
    try std.testing.expect(host.bindingIsPreparing(first.binding, first.key));
    try std.testing.expect(!host.bindingIsLive(first.binding));
    try std.testing.expect(host.queryService(original.handle, .transfer) == .temporarily_unavailable);
    try std.testing.expect(host.bindingIsLive(terminal));
    var wrong_key = first.key;
    wrong_key.operation_id += 1;
    var wrong_binding = first.binding;
    wrong_binding.binding_generation += 1;
    try std.testing.expect(!try host.auxiliaryTransferReady(first.binding, wrong_key));
    try std.testing.expect(!try host.auxiliaryTransferReady(wrong_binding, first.key));
    try std.testing.expect(!try host.auxiliaryTransferReleased(wrong_binding, first.key, .released));
    try std.testing.expect(try host.auxiliaryTransferReady(first.binding, first.key));
    try std.testing.expect(host.bindingIsLive(first.binding));
    try std.testing.expectEqualDeep(first.binding, host.queryService(original.handle, .transfer).available);
    try std.testing.expect(host.queryService(original.handle, .directory) == .temporarily_unavailable);
    try std.testing.expect(host.queryState(original.handle).?.create_operation.eql(original.operation));
    try std.testing.expect(!try host.auxiliaryTransferReady(first.binding, first.key));
    try std.testing.expect(try host.auxiliaryTransferReleased(first.binding, first.key, .unknown));
    try std.testing.expect(!host.bindingIsLive(first.binding));
    try std.testing.expect(!host.bindingIsPreparing(first.binding, first.key));
    try std.testing.expect(!host.auxiliaryTransferOperationIsCurrent(original.handle, first.key));
    try std.testing.expect(host.auxiliaryTransferOwns(first.binding, first.key));
    try std.testing.expectError(error.CleanupNotReleased, host.beginAuxiliaryTransfer(original.handle));
    try std.testing.expect(try host.auxiliaryTransferReleased(first.binding, first.key, .awaiting));
    try std.testing.expectError(error.CleanupNotReleased, host.beginAuxiliaryTransfer(original.handle));
    try std.testing.expect(try host.auxiliaryTransferReleased(first.binding, first.key, .released));
    try std.testing.expect(host.journal.isTerminal(first.key));
    try std.testing.expect(host.auxiliaryTransferOwns(first.binding, first.key));
    const next = try host.beginAuxiliaryTransfer(original.handle);
    try std.testing.expect(next.binding.binding_id > first.binding.binding_id);
    try std.testing.expectEqual(first.binding.binding_generation + 1, next.binding.binding_generation);
    try std.testing.expect(next.binding.binding_generation != original.handle.generation);
    try std.testing.expect(!host.auxiliaryTransferOwns(first.binding, first.key));
    try std.testing.expect(!try host.auxiliaryTransferReady(first.binding, first.key));
    try std.testing.expect(!try host.auxiliaryTransferReleased(first.binding, first.key, .released));
    try std.testing.expect(host.bindingIsPreparing(next.binding, next.key));
    try std.testing.expect(try host.auxiliaryTransferReleased(next.binding, next.key, .released));
}

test "auxiliary transfer revokes on original SSH close but preserves exact cleanup and retain source" {
    const Gate = struct {
        owner: ?domain.SessionHandle = null,
        key: ?domain.OperationKey = null,
        fn pause(raw: *anyopaque, owner: domain.SessionHandle, key: domain.OperationKey) !domain.CloseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.owner = owner;
            self.key = key;
            return .awaiting;
        }
    };
    var context: u8 = 0;
    var host = try domain.SessionHost.init(a, &.{Adapter.interface(&context)});
    defer host.deinit();
    const original = try attach(&host);
    const auxiliary = try host.beginAuxiliaryTransfer(original.handle);
    try std.testing.expect(try host.auxiliaryTransferReady(auxiliary.binding, auxiliary.key));
    var gate: Gate = .{};
    const close_key = try host.requestClose(original.handle, .{ .pause_transfers = .{ .context = &gate, .run = Gate.pause } });
    try std.testing.expect(gate.owner.?.eql(original.handle) and gate.key.?.eql(close_key));
    try std.testing.expect(!close_key.eql(auxiliary.key));
    try std.testing.expect(!host.auxiliaryTransferOperationIsCurrent(original.handle, auxiliary.key));
    try std.testing.expect(!host.bindingIsLive(auxiliary.binding));
    try std.testing.expect(!host.bindingIsPreparing(auxiliary.binding, auxiliary.key));
    try std.testing.expect(!try host.auxiliaryTransferReady(auxiliary.binding, auxiliary.key));
    try std.testing.expectError(error.LifecycleDoesNotAllowTransfer, host.beginAuxiliaryTransfer(original.handle));
    const retained_id = try host.retainTransferSource(original.handle);
    try std.testing.expectEqualStrings("bastion.example", host.retainedTransferSource(retained_id, original.handle).?.saved.route_snapshot[0].endpoint.host);
    try std.testing.expectError(error.OriginalSessionNotClosed, host.beginRetainedTransfer(retained_id, original.handle));
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .released));
    try std.testing.expect(try host.closeReceipt(original.handle, close_key, .pause_transfers, .released));
    try std.testing.expect(host.queryState(original.handle).?.lifecycle == .closed);
    try std.testing.expect(host.auxiliaryTransferOwns(auxiliary.binding, auxiliary.key));
    try std.testing.expect(!host.auxiliaryTransferOperationIsCurrent(original.handle, auxiliary.key));
    const retained = try host.beginRetainedTransfer(retained_id, original.handle);
    try std.testing.expect(retained.binding.resource_owner == .retained_transfer);
    try std.testing.expect(retained.binding.binding_id > auxiliary.binding.binding_id);
    try std.testing.expect(try host.retainedTransferReady(retained.binding, retained.key));
    try std.testing.expect(try host.retainedTransferReleased(retained.binding, retained.key, .released));
    try host.releaseRetainedTransfer(retained_id, original.handle);
}

test "auxiliary transfer ready and cleanup OOM preserve exact receipt gates" {
    var context: u8 = 0;
    var host = try domain.SessionHost.init(a, &.{Adapter.interface(&context)});
    defer host.deinit();
    const original = try attach(&host);
    const terminal = host.queryService(original.handle, .terminal).available;
    const auxiliary = try host.beginAuxiliaryTransfer(original.handle);
    clearEvents(&host);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    host.journal.allocator = failing.allocator();
    defer host.journal.allocator = a;
    try std.testing.expectError(error.OutOfMemory, host.auxiliaryTransferReady(auxiliary.binding, auxiliary.key));
    try std.testing.expect(host.bindingIsPreparing(auxiliary.binding, auxiliary.key));
    try std.testing.expect(!host.bindingIsLive(auxiliary.binding));
    try std.testing.expect(host.bindingIsLive(terminal));
    host.journal.allocator = a;
    try std.testing.expect(try host.auxiliaryTransferReady(auxiliary.binding, auxiliary.key));
    clearEvents(&host);
    failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    host.journal.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .released));
    try std.testing.expect(!host.bindingIsLive(auxiliary.binding));
    try std.testing.expect(!host.bindingIsPreparing(auxiliary.binding, auxiliary.key));
    try std.testing.expect(host.bindingIsLive(terminal));
    try std.testing.expect(!host.journal.isTerminal(auxiliary.key));
    try std.testing.expectError(error.CleanupNotReleased, host.beginAuxiliaryTransfer(original.handle));
    host.journal.allocator = a;
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .released));
    try std.testing.expect(host.journal.isTerminal(auxiliary.key));
    const next = try host.beginAuxiliaryTransfer(original.handle);
    try std.testing.expectEqual(auxiliary.binding.binding_generation + 1, next.binding.binding_generation);
    try std.testing.expect(try host.auxiliaryTransferReleased(next.binding, next.key, .released));
}

test "fault retained source waits exact release while original SSH stays attached" {
    var context: u8 = 0;
    var host = try domain.SessionHost.init(a, &.{Adapter.interface(&context)});
    defer host.deinit();
    const original = try attach(&host);
    const auxiliary = try host.beginAuxiliaryTransfer(original.handle);
    try std.testing.expect(try host.auxiliaryTransferReady(auxiliary.binding, auxiliary.key));
    try std.testing.expectError(error.StaleBinding, host.retainFaultTransferSource(auxiliary.binding, auxiliary.key));
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .awaiting));
    const id = try host.retainFaultTransferSource(auxiliary.binding, auxiliary.key);
    try std.testing.expectEqual(id, try host.retainFaultTransferSource(auxiliary.binding, auxiliary.key));
    try std.testing.expect(host.faultTransferSourceIsCurrent(id, original.handle, auxiliary.binding, auxiliary.key));
    var wrong = auxiliary.key;
    wrong.operation_id += 1;
    try std.testing.expect(!host.faultTransferSourceIsCurrent(id, original.handle, auxiliary.binding, wrong));
    try std.testing.expectError(error.StaleBinding, host.retainFaultTransferSource(auxiliary.binding, wrong));
    var wrong_binding = auxiliary.binding;
    wrong_binding.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, host.retainFaultTransferSource(wrong_binding, auxiliary.key));
    try std.testing.expect(!host.faultTransferSourceIsCurrent(id, original.handle, wrong_binding, auxiliary.key));
    var wrong_owner = original.handle;
    wrong_owner.generation += 1;
    const wrong_id: @import("host/identity.zig").RetainedTransferOwnerId = @fromBackingInt(@backingInt(id) + 1);
    try std.testing.expect(!host.faultTransferSourceIsCurrent(id, wrong_owner, auxiliary.binding, auxiliary.key));
    try std.testing.expect(!host.faultTransferSourceIsCurrent(wrong_id, original.handle, auxiliary.binding, auxiliary.key));
    const next_binding = host.next_binding;
    try std.testing.expectError(error.UnknownRetainedTransfer, host.beginRetainedTransfer(wrong_id, original.handle));
    try std.testing.expectError(error.RetainedOwnerMismatch, host.beginRetainedTransfer(id, wrong_owner));
    try std.testing.expect(!try host.auxiliaryTransferReleased(auxiliary.binding, wrong, .released));
    try std.testing.expect(!try host.auxiliaryTransferReleased(wrong_binding, auxiliary.key, .released));
    try std.testing.expectError(error.CleanupNotReleased, host.beginRetainedTransfer(id, original.handle));
    try std.testing.expectEqual(next_binding, host.next_binding);
    try std.testing.expectError(error.CleanupNotReleased, host.releaseRetainedTransfer(id, original.handle));
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .unknown));
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .awaiting));
    try std.testing.expectError(error.CleanupNotReleased, host.beginRetainedTransfer(id, original.handle));
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .released));
    const resumed = try host.beginRetainedTransfer(id, original.handle);
    try std.testing.expect(resumed.binding.resource_owner == .retained_transfer);
    try std.testing.expectEqual(domain.Lifecycle.attached, host.queryState(original.handle).?.lifecycle);
    try std.testing.expect(try host.retainedTransferReady(resumed.binding, resumed.key));
    // A second fault keeps the original retained ID and exact open operation.
    try std.testing.expectError(error.StaleBinding, host.retainFaultTransferSource(resumed.binding, resumed.key));
    try std.testing.expect(try host.retainedTransferReleased(resumed.binding, resumed.key, .awaiting));
    try std.testing.expectEqual(id, try host.retainFaultTransferSource(resumed.binding, resumed.key));
    try std.testing.expectEqual(id, try host.retainFaultTransferSource(resumed.binding, resumed.key));
    try std.testing.expect(host.faultTransferSourceIsCurrent(id, original.handle, auxiliary.binding, auxiliary.key));
    try std.testing.expect(host.faultTransferSourceIsCurrent(id, original.handle, resumed.binding, resumed.key));
    try std.testing.expect(!host.faultTransferSourceIsCurrent(id, original.handle, resumed.binding, auxiliary.key));
    try std.testing.expect(!try host.retainedTransferReleased(resumed.binding, auxiliary.key, .released));
    try std.testing.expectError(error.StaleBinding, host.retainFaultTransferSource(resumed.binding, auxiliary.key));
    try std.testing.expectError(error.CleanupNotReleased, host.beginRetainedTransfer(id, original.handle));
    try std.testing.expect(try host.retainedTransferReleased(resumed.binding, resumed.key, .unknown));
    try std.testing.expect(try host.retainedTransferReleased(resumed.binding, resumed.key, .awaiting));
    try std.testing.expectError(error.CleanupNotReleased, host.beginRetainedTransfer(id, original.handle));
    try std.testing.expectError(error.CleanupNotReleased, host.releaseRetainedTransfer(id, original.handle));
    try std.testing.expect(try host.retainedTransferReleased(resumed.binding, resumed.key, .released));
    const again = try host.beginRetainedTransfer(id, original.handle);
    try std.testing.expectEqual(id, again.binding.resource_owner.retained_transfer);
    try std.testing.expectEqual(resumed.binding.binding_generation + 1, again.binding.binding_generation);
    try std.testing.expect(again.binding.binding_id != resumed.binding.binding_id and !again.key.eql(resumed.key));
    try std.testing.expect(try host.retainedTransferReady(again.binding, again.key));
    try std.testing.expect(!try host.retainedTransferReleased(resumed.binding, resumed.key, .released));
    try std.testing.expect(host.bindingIsLive(again.binding));
    try std.testing.expect(host.bindingIsLive(host.queryService(original.handle, .terminal).available));
    try std.testing.expectEqual(domain.Lifecycle.attached, host.queryState(original.handle).?.lifecycle);
    try std.testing.expect(try host.retainedTransferReleased(again.binding, again.key, .released));
    try host.releaseRetainedTransfer(id, original.handle);
    try std.testing.expect(!host.faultTransferSourceIsCurrent(id, original.handle, resumed.binding, resumed.key));
}

test "fault retained source closed SSH does not replace an auxiliary transport release receipt" {
    var context: u8 = 0;
    var host = try domain.SessionHost.init(a, &.{Adapter.interface(&context)});
    defer host.deinit();
    const original = try attach(&host);
    const auxiliary = try host.beginAuxiliaryTransfer(original.handle);
    try std.testing.expect(try host.auxiliaryTransferReady(auxiliary.binding, auxiliary.key));
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .awaiting));
    const id = try host.retainFaultTransferSource(auxiliary.binding, auxiliary.key);
    // The controlled terminal adapter acknowledges only its own close. The
    // separately recorded file transport deliberately still has no release.
    _ = try host.requestClose(original.handle, .{});
    try std.testing.expectEqual(domain.Lifecycle.closed, host.queryState(original.handle).?.lifecycle);
    try std.testing.expectError(error.CleanupNotReleased, host.beginRetainedTransfer(id, original.handle));
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .unknown));
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .awaiting));
    try std.testing.expectError(error.CleanupNotReleased, host.beginRetainedTransfer(id, original.handle));
    try std.testing.expect(try host.auxiliaryTransferReleased(auxiliary.binding, auxiliary.key, .released));
    const resumed = try host.beginRetainedTransfer(id, original.handle);
    try std.testing.expectEqual(id, resumed.binding.resource_owner.retained_transfer);
    try std.testing.expect(try host.retainedTransferReleased(resumed.binding, resumed.key, .released));
    try host.releaseRetainedTransfer(id, original.handle);
}
