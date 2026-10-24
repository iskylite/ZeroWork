const std = @import("std");
const module = @import("ui/file_authentication.zig");
const sessions = @import("host/session_host.zig");
const files = @import("host/file_binding_host.zig");
const plugins = @import("host/plugin_registry.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");

test "TOTP autofill independent file auth freezes saved switch and seed for original operation" {
    var adapter: DomainAdapter = .{};
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter(.sftp)});
    defer host.deinit();
    var library: ssh.Library = .{ .active = true };
    var saved: @import("config/config.zig").Config = .{};
    saved.ssh.totp_autofill = true;
    saved.ssh.otp_modal = true;
    saved.config_revision = 41;
    const owner = try module.FileAuthentication.init(std.testing.allocator, &host, .{ .library = &library, .known_hosts_path = "/no-io/frozen/known_hosts", .saved_config = &saved });
    defer owner.deinit() catch unreachable;
    var input = spec();
    input.saved.immutable_config.totp_secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"; // Public synthetic test seed; never used for authentication. gitleaks:allow
    const accepted = try host.create(input, target);
    const factory = owner.factory();
    const first = try factory.prepare(factory.context, try source(&host, accepted));
    defer factory.discard(factory.context, first);
    saved.ssh.totp_autofill = false;
    saved.config_revision = 42;
    const second = try factory.prepare(factory.context, try source(&host, accepted));
    defer factory.discard(factory.context, second);
    saved.ssh.totp_autofill = true;
    saved.ssh.otp_modal = false;
    saved.config_revision = 43;
    const third = try factory.prepare(factory.context, try source(&host, accepted));
    defer factory.discard(factory.context, third);
    var ids: [3]module.auth.RequestIdentity = undefined;
    for (owner.contexts.items, &ids) |context, *id| {
        id.* = try context.auth_bridge.offerChallenge(.{ .key = context.source.value.open_key, .source_owner = .{ .id = input.saved.connection_id, .revision = input.saved.config_revision }, .hop_index = 0, .kind = .keyboard_interactive, .endpoint_identity = .{ .host = "target.example", .port = 2222, .user = "target-user" }, .prompts = &.{.{ .text = "OTP", .kind = .one_time_code }}, .presentation = context.presentation, .presentation_config_revision = context.presentation_config_revision });
    }
    const now: @import("proto/ssh/totp_prefill.zig").Time = .{ .unix_seconds = 59, .monotonic_ns = 10 };
    var value = (try owner.authenticationTotp(ids[0], now)).?;
    defer value.deinit();
    try std.testing.expectEqualStrings("287082", value.code.slice());
    try std.testing.expectEqual(@as(u64, 41), owner.contexts.items[0].auth_bridge.snapshot().?.presentation_config_revision);
    try std.testing.expect(try owner.authenticationTotp(ids[1], now) == null);
    try std.testing.expect(try owner.authenticationTotp(ids[2], now) == null);
    var stale = ids[0];
    stale.key.owner.session.generation += 1;
    try std.testing.expect(try owner.authenticationTotp(stale, now) == null);
    try std.testing.expectEqual(module.auth.State.input, owner.contexts.items[0].auth_bridge.snapshot().?.state);
    try std.testing.expect(owner.cancelAuthentication(ids[0]));
    try std.testing.expect(try owner.authenticationTotp(ids[0], now) == null);
}

const DomainAdapter = struct {
    cancelled: usize = 0,
    fn adapter(self: *DomainAdapter, plugin: plugins.PluginId) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = plugin, .workspace_kind = if (plugin == .sftp) .file else .terminal, .services = plugins.requiredServices(plugin) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(raw: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        const self: *DomainAdapter = @ptrCast(@alignCast(raw));
        self.cancelled += 1;
        return .released; // This domain fixture itself acquires no resource.
    }
    fn close(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
};
const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(7), .workspace_id = @fromBackingInt(8) };
fn spec() sessions.SessionCreateSpec {
    return .{ .saved = .{ .connection_id = @fromBackingInt(88), .config_revision = 7, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "target.example", .port = 2222, .user = "target-user" }, .auth = .{ .private_key = .{ .path = "/original/key", .passphrase = "private secret" } } } } };
}
fn source(host: *sessions.SessionHost, accepted: sessions.Accepted) !files.Source {
    for (host.sessions.items) |entry| if (entry.handle.eql(accepted.handle)) return .{ .owner = accepted.handle, .create_key = accepted.operation, .open_key = try host.journal.begin(.{ .session = accepted.handle }, accepted.operation.attempt_id), .spec = entry.spec.value };
    return error.NoOriginalSession;
}
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn waitPending(bridge: *module.host_key.Bridge) !void {
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!bridge.pending()) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
}
fn request(snapshot: module.host_key.Request) module.auth.RequestIdentity {
    return .{ .key = snapshot.operation_key.?, .hop_index = snapshot.hop_index, .request_id = snapshot.generation };
}
const Observe = struct {
    bridge: *module.host_key.Bridge,
    key: sessions.OperationKey,
    host: []const u8 = "target.example",
    port: u16 = 2222,
    status: ssh.HostKeyStatus = .unknown,
    decision: ssh.HostKeyDecision = .reject_unknown,
    done: std.atomic.Value(bool) = .init(false),
    fn run(self: *Observe) void {
        self.decision = module.host_key.Bridge.observer(self.bridge, self.host, self.port, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:actual-controlled-observer", .status = self.status, .operation_key = self.key, .hop_index = 0 });
        self.done.store(true, .release);
    }
};

test "file authentication parallel opens keep independent challenges frozen metadata and one shared kind counter" {
    var adapter: DomainAdapter = .{};
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter(.sftp)});
    defer host.deinit();
    var library: ssh.Library = .{ .active = true }; // Only memory preparation.
    const owner = try module.FileAuthentication.init(std.testing.allocator, &host, .{ .library = &library, .known_hosts_path = "/no-io/frozen/known_hosts", .presentation_config_revision = 41 });
    defer owner.deinit() catch unreachable;
    const accepted = try host.create(spec(), target);
    const factory = owner.factory();
    var first_source = try source(&host, accepted);
    first_source.spec.saved.immutable_config.endpoint.host = "caller-mutated.invalid";
    const first = try factory.prepare(factory.context, first_source);
    defer factory.discard(factory.context, first);
    const second = try factory.prepare(factory.context, try source(&host, accepted));
    defer factory.discard(factory.context, second);
    const a = owner.contexts.items[0];
    const b = owner.contexts.items[1];
    owner.options.presentation_config_revision = 99;
    var one: Observe = .{ .bridge = &a.host_bridge, .key = first.key };
    var two: Observe = .{ .bridge = &b.host_bridge, .key = second.key, .status = .changed };
    var thread_one = try std.Thread.spawn(.{}, Observe.run, .{&one});
    defer thread_one.join();
    defer a.host_bridge.cancel();
    var thread_two = try std.Thread.spawn(.{}, Observe.run, .{&two});
    defer thread_two.join();
    defer b.host_bridge.cancel();
    try waitPending(&a.host_bridge);
    try waitPending(&b.host_bridge);
    const original = owner.pendingAuthentication().?;
    const other = request(b.host_bridge.snapshot().?);
    try std.testing.expectEqual(@as(u64, 1), original.identity.request_id);
    try std.testing.expectEqual(@as(u64, 1), other.request_id);
    try std.testing.expect(!original.identity.key.eql(other.key));
    try std.testing.expectEqual(@as(u64, 41), original.presentation_config_revision);
    const display = owner.authenticationHostFor(original.identity).?;
    try std.testing.expectEqualStrings("target.example", display.host);
    try std.testing.expectEqualStrings("/original/key", display.identity_file.?);
    try std.testing.expect(display.password == null and display.key_passphrase == null and display.totp_secret == null);
    var stale = original.identity;
    stale.key.owner.session.generation += 1;
    try std.testing.expectError(error.StaleAuthentication, owner.submitAuthentication(stale, .trust_once));
    try std.testing.expect(owner.authenticationHostFor(stale) == null);
    try std.testing.expect(!owner.cancelAuthentication(stale));
    try std.testing.expectError(error.StaleAuthentication, owner.submitAuthentication(other, .trust_once));
    try std.testing.expect(b.host_bridge.pending());
    try owner.submitAuthentication(original.identity, .trust_once);
    try std.testing.expectError(error.StaleAuthentication, owner.submitAuthentication(original.identity, .trust_save));
    try std.testing.expect(b.host_bridge.pending());
    try owner.submitAuthentication(other, .{ .replace_host_key = "yes" });
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!one.done.load(.acquire) or !two.done.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expectEqual(ssh.HostKeyDecision.trust_once, one.decision);
    try std.testing.expectEqual(ssh.HostKeyDecision.trust_changed_yes, two.decision);
    const auth_id = try a.auth_bridge.offerChallenge(.{ .key = first.key, .hop_index = 0, .kind = .private_key_passphrase, .endpoint_identity = .{ .host = "target.example", .port = 2222, .user = "target-user" }, .prompts = &.{.{ .text = "Passphrase" }}, .presentation_config_revision = 41 });
    try std.testing.expectEqual(@as(u64, 2), auth_id.request_id);
    const scoped = owner.authenticationHostKey(auth_id).?;
    try std.testing.expect(scoped.operation_key.?.eql(first.key));
    try owner.submitAuthentication(auth_id, .{ .answers = &.{"actual response"} });
    var reply = try a.auth_bridge.waitResponse(auth_id, 1000);
    defer reply.deinit();
    try std.testing.expectEqualStrings("actual response", reply.answerAt(0));
    try a.auth_bridge.complete(auth_id);
    try std.testing.expect(owner.pendingAuthentication() == null);
}

test "file authentication original route hop display is frozen and create cancellation cannot accept an old challenge" {
    var adapter: DomainAdapter = .{};
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{ adapter.adapter(.ssh), adapter.adapter(.sftp) });
    defer host.deinit();
    var library: ssh.Library = .{ .active = true };
    const owner = try module.FileAuthentication.init(std.testing.allocator, &host, .{ .library = &library, .known_hosts_path = "/no-io/frozen/known_hosts" });
    defer owner.deinit() catch unreachable;
    var input = spec();
    input.saved.protocol = .ssh;
    input.saved.route_snapshot = &.{.{ .owner = .{ .id = @fromBackingInt(33), .revision = 17 }, .display_name = "Original jump", .endpoint = .{ .host = "hop.example", .user = "hop-user" }, .auth = .{ .password = "hop secret" } }};
    const accepted = try host.create(input, target);
    const factory = owner.factory();
    const connector = try factory.prepare(factory.context, try source(&host, accepted));
    defer factory.discard(factory.context, connector);
    const context = owner.contexts.items[0];
    const id = try context.auth_bridge.offerChallenge(.{ .key = connector.key, .source_owner = input.saved.route_snapshot[0].owner, .hop_index = 0, .kind = .password, .endpoint_identity = .{ .host = "hop.example", .user = "hop-user" }, .prompts = &.{.{ .text = "Password" }}, .presentation_config_revision = 1 });
    const display = owner.authenticationHostFor(id).?;
    try std.testing.expectEqualStrings("Original jump", display.name);
    try std.testing.expectEqual(@as(u64, 17), display.revision);
    try std.testing.expect(display.password == null and display.key_passphrase == null and display.totp_secret == null);
    try std.testing.expect(try host.cancel(accepted.operation));
    _ = try owner.collect();
    try std.testing.expect(owner.pendingAuthentication() == null);
    try std.testing.expectError(error.StaleAuthentication, owner.submitAuthentication(id, .{ .answers = &.{"wrong owner"} }));
    try std.testing.expectError(error.Cancelled, context.auth_bridge.offerChallenge(.{ .key = connector.key, .hop_index = 0, .kind = .password, .endpoint_identity = .{ .host = "hop.example", .user = "hop-user" }, .prompts = &.{.{ .text = "Password" }}, .presentation_config_revision = 1 }));
    var foreign = try source(&host, accepted);
    foreign.owner.generation += 1;
    try std.testing.expectError(error.StaleSession, factory.prepare(factory.context, foreign));
}

const Controlled = struct {
    entered: std.atomic.Value(bool) = .init(false),
    unblock: std.atomic.Value(bool) = .init(false),
    receipt: std.atomic.Value(u8) = .init(@backingInt(module.Receipt.awaiting)),
    destroyed: std.atomic.Value(bool) = .init(false),
    caller: std.Thread.Id,
    fn connect(raw: *anyopaque, _: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *Controlled = @ptrCast(@alignCast(raw));
        std.debug.assert(std.Thread.getCurrentId() != self.caller);
        self.entered.store(true, .release);
        while (!self.unblock.load(.acquire)) pause();
        return error.ControlledConnectFailed;
    }
    fn close(raw: *anyopaque, _: ?*ssh.Session) module.Receipt {
        const self: *Controlled = @ptrCast(@alignCast(raw));
        std.debug.assert(std.Thread.getCurrentId() != self.caller);
        return @fromBackingInt(@intCast(self.receipt.load(.acquire)));
    }
    fn destroy(raw: *anyopaque) void {
        const self: *Controlled = @ptrCast(@alignCast(raw));
        self.destroyed.store(true, .release);
    }
};
const Connect = struct {
    connector: files.readonly.Connector,
    token: std.atomic.Value(bool) = .init(false),
    fn run(self: *Connect) void {
        _ = self.connector.connect_fn(self.connector.ctx, &self.token) catch {};
        while (self.connector.close_fn(self.connector.ctx, null) != .released) pause();
        self.connector.deinit_fn(self.connector.ctx);
    }
};
test "file authentication only worker actual close and destruction allow UI reclamation unknown stays busy" {
    var adapter: DomainAdapter = .{};
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter(.sftp)});
    defer host.deinit();
    var library: ssh.Library = .{ .active = true };
    const owner = try module.FileAuthentication.init(std.testing.allocator, &host, .{ .library = &library, .known_hosts_path = "/no-io/frozen/known_hosts" });
    defer owner.deinit() catch unreachable;
    const accepted = try host.create(spec(), target);
    const api = owner.factory();
    const connector = try api.prepare(api.context, try source(&host, accepted));
    const context = owner.contexts.items[0];
    // Replace only the memory-prepared native dependency with a controlled
    // blocking delegate. Production wrapper callbacks/lifetime stay unchanged.
    context.delegate.deinit_fn(context.delegate.ctx);
    var native: Controlled = .{ .caller = std.Thread.getCurrentId() };
    context.delegate = .{ .key = connector.key, .ctx = &native, .connect_fn = Controlled.connect, .close_fn = Controlled.close, .deinit_fn = Controlled.destroy };
    var connect: Connect = .{ .connector = connector };
    var thread = try std.Thread.spawn(.{}, Connect.run, .{&connect});
    defer thread.join();
    defer native.receipt.store(@backingInt(module.Receipt.released), .release);
    defer native.unblock.store(true, .release);
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!native.entered.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expectEqual(module.Receipt.awaiting, owner.shutdownStep());
    try std.testing.expectError(error.Busy, owner.deinit());
    connector.deinit_fn(connector.ctx); // A premature deinit cannot free it.
    try std.testing.expect(!native.destroyed.load(.acquire));
    native.receipt.store(@backingInt(module.Receipt.unknown), .release);
    native.unblock.store(true, .release);
    while (context.native_receipt.load(.acquire) != @backingInt(module.Receipt.unknown)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expectEqual(module.Receipt.unknown, owner.shutdownStep());
    try std.testing.expect(try owner.collect());
    try std.testing.expectError(error.Busy, owner.deinit());
    try std.testing.expect(!native.destroyed.load(.acquire));
    native.receipt.store(@backingInt(module.Receipt.released), .release);
    while (!context.closed.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
    try std.testing.expect(native.destroyed.load(.acquire));
    try std.testing.expect(!try owner.collect());
    try std.testing.expectEqual(@as(usize, 0), owner.contexts.items.len);
}

test "file authentication cancel uses original create and prepared discard needs no native IO" {
    var adapter: DomainAdapter = .{};
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter(.sftp)});
    defer host.deinit();
    var library: ssh.Library = .{ .active = true };
    const owner = try module.FileAuthentication.init(std.testing.allocator, &host, .{ .library = &library, .known_hosts_path = "/no-io/frozen/known_hosts" });
    defer owner.deinit() catch unreachable;
    const accepted = try host.create(spec(), target);
    const api = owner.factory();
    const connector = try api.prepare(api.context, try source(&host, accepted));
    const context = owner.contexts.items[0];
    const id = try context.auth_bridge.offerChallenge(.{ .key = connector.key, .hop_index = 0, .kind = .private_key_passphrase, .endpoint_identity = .{ .host = "target.example", .port = 2222, .user = "target-user" }, .prompts = &.{.{ .text = "Passphrase" }}, .presentation_config_revision = 1 });
    try std.testing.expect(owner.cancelAuthentication(id));
    try std.testing.expectEqual(@as(usize, 1), adapter.cancelled);
    try std.testing.expectEqual(sessions.Lifecycle.failed, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expect(!owner.cancelAuthentication(id));
    api.discard(api.context, connector);
    try std.testing.expect(!try owner.collect());
    try std.testing.expectEqual(module.Receipt.released, owner.shutdownStep());
}

fn closeVm(owner: *module.FileAuthentication, file_host: *files.FileBindingHost) void {
    _ = owner.shutdownStep();
    file_host.requestCloseAll();
    const deadline = clock.monotonicNs() + 15 * std.time.ns_per_s;
    while (true) {
        const files_busy = file_host.safeTick() catch unreachable;
        const auth_busy = owner.collect() catch unreachable;
        if (!files_busy and !auth_busy) break;
        if (clock.monotonicNs() >= deadline) unreachable;
        pause();
    }
    file_host.deinit() catch unreachable;
    owner.deinit() catch unreachable;
}

test "file authentication optional VM unknown fingerprint and password wait for exact explicit replies then realpath and released cleanup" {
    const password_raw = std.c.getenv("ZEROWORK_VM_PASSWORD") orelse return error.SkipZigTest;
    const password = std.mem.span(password_raw);
    const vm_host = std.mem.span(std.c.getenv("ZEROWORK_VM_HOST") orelse return error.MissingHost);
    const fingerprint = std.mem.span(std.c.getenv("ZEROWORK_SFTP_FINGERPRINT") orelse return error.MissingFingerprint);
    var library = try ssh.Library.init();
    defer library.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const trust = try std.fmt.allocPrint(std.testing.allocator, "{s}/known_hosts", .{path});
    defer std.testing.allocator.free(trust);
    var adapter: DomainAdapter = .{};
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter(.sftp)});
    defer host.deinit();
    const owner = try module.FileAuthentication.init(std.testing.allocator, &host, .{ .library = &library, .known_hosts_path = trust, .timeout_ms = 5000 });
    var file_host = try files.FileBindingHost.init(std.testing.allocator, &host, owner.factory());
    defer closeVm(owner, &file_host);
    var input = spec();
    input.saved.immutable_config.endpoint = .{ .host = vm_host, .user = "root" };
    input.saved.immutable_config.auth = .password_prompt;
    const accepted = try host.create(input, target);
    const directory = try host.reserveService(accepted.handle, accepted.operation, .directory);
    const read = try host.reserveService(accepted.handle, accepted.operation, .file_read);
    _ = try file_host.attachPreparing(accepted.handle, accepted.operation, .{ .directory = directory, .file_read = read });
    const deadline = clock.monotonicNs() + 15 * std.time.ns_per_s;
    var host_request: ?module.auth.RequestIdentity = null;
    var password_request: ?module.auth.RequestIdentity = null;
    while (file_host.state(directory).?.phase != .ready) {
        _ = try file_host.safeTick();
        _ = try owner.collect();
        if (owner.pendingAuthentication()) |challenge| {
            const display = owner.authenticationHostFor(challenge.identity).?;
            try std.testing.expectEqualStrings(vm_host, display.host);
            try std.testing.expect(display.password == null and display.key_passphrase == null and display.totp_secret == null);
            if (challenge.kind == .host_key_unknown) {
                const key = owner.authenticationHostKey(challenge.identity).?;
                try std.testing.expectEqualStrings(fingerprint, key.fingerprintSlice());
                host_request = challenge.identity;
                // Explicit fixture decision for this authorized VM only;
                // production FileAuthentication never makes this decision.
                try owner.submitAuthentication(challenge.identity, .trust_once);
            } else if (challenge.kind == .password and challenge.state == .input) {
                try std.testing.expect(host_request != null);
                password_request = challenge.identity;
                try std.testing.expect(challenge.identity.key.eql(host_request.?.key));
                try std.testing.expect(challenge.identity.request_id > host_request.?.request_id);
                try owner.submitAuthentication(challenge.identity, .{ .answers = &.{password} });
            }
        }
        const state = file_host.state(directory).?;
        if (state.phase == .failed or state.phase == .closed) return error.VmAuthenticationFailed;
        if (clock.monotonicNs() >= deadline) return error.VmAuthenticationTimeout;
        pause();
    }
    try std.testing.expect(host_request != null and password_request != null);
    try std.testing.expectEqual(sessions.Lifecycle.creating, host.queryState(accepted.handle).?.lifecycle);
    try std.testing.expect(host.queryService(accepted.handle, .directory) == .temporarily_unavailable);
    try std.testing.expectError(error.StaleAuthentication, owner.submitAuthentication(host_request.?, .trust_save));
    const key = try file_host.beginPreparing(directory, accepted.operation, .{ .path = ".", .action = .realpath, .directory_revision = 1 });
    var completed = false;
    while (!completed) {
        _ = try file_host.safeTick();
        if (file_host.take(key)) |result| {
            var owned = result;
            defer owned.deinit();
            switch (owned.result.value.body) {
                .realpath => |resolved| try std.testing.expectEqualStrings("/root", resolved),
                else => return error.UnexpectedVmDirectoryResult,
            }
            completed = owned.result.value.final;
        }
        if (clock.monotonicNs() >= deadline) return error.VmAuthenticationTimeout;
        pause();
    }
    try file_host.retire(key);
    try std.testing.expect(try host.cancel(accepted.operation));
    _ = try owner.collect();
    try std.testing.expect(owner.pendingAuthentication() == null);
    while (try file_host.safeTick()) {
        _ = try owner.collect();
        if (clock.monotonicNs() >= deadline) return error.VmCloseTimeout;
        pause();
    }
    try std.testing.expect(!try owner.collect());
    try std.testing.expectEqual(@as(usize, 0), owner.contexts.items.len);
    try std.testing.expectEqual(module.Receipt.released, owner.shutdownStep());
    std.debug.print("FILE_AUTH_VM_PASS unknown_key_explicit=true password_prompt_explicit=true shared_counter=true original_open_key=true realpath=/root native_cleanup=released shell=false remote_mutation=false\n", .{});
}

test "file authentication retained resume freezes original source after session closes and rejects retired key" {
    var adapter: DomainAdapter = .{};
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter(.sftp)});
    defer host.deinit();
    var library: ssh.Library = .{ .active = true }; // Preparation does no native IO.
    const auth_owner = try module.FileAuthentication.init(std.testing.allocator, &host, .{ .library = &library, .known_hosts_path = "/no-io/retained/known_hosts" });
    defer auth_owner.deinit() catch unreachable;
    const original = try host.create(spec(), target);
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.sftp)));
    const retained = try host.retainTransferSource(original.handle);
    _ = try host.requestClose(original.handle, .{});
    const start = try host.beginRetainedTransfer(retained, original.handle);
    var frozen: files.Source = .{ .owner = original.handle, .retained_owner = retained, .create_key = start.key, .open_key = start.key, .spec = start.spec };
    frozen.spec.saved.immutable_config.endpoint.host = "new-same-name.invalid";
    const factory = auth_owner.factory();
    const connector = try factory.prepare(factory.context, frozen);
    defer factory.discard(factory.context, connector);
    const context = auth_owner.contexts.items[0];
    try std.testing.expectEqualStrings("target.example", context.source.value.spec.saved.immutable_config.endpoint.host);
    try std.testing.expectEqualStrings("/original/key", context.source.value.spec.saved.immutable_config.auth.private_key.path);
    var observation: Observe = .{ .bridge = &context.host_bridge, .key = connector.key };
    var thread = try std.Thread.spawn(.{}, Observe.run, .{&observation});
    defer thread.join();
    defer context.host_bridge.cancel();
    try waitPending(&context.host_bridge);
    const pending = auth_owner.pendingAuthentication().?;
    try std.testing.expectEqual(start.key.owner, pending.identity.key.owner);
    try std.testing.expectEqualStrings("target.example", auth_owner.authenticationHostFor(pending.identity).?.host);
    try std.testing.expect(try host.retainedTransferReleased(start.binding, start.key, .released));
    try std.testing.expect(auth_owner.authenticationHostFor(pending.identity) == null);
    try std.testing.expectError(error.StaleAuthentication, auth_owner.submitAuthentication(pending.identity, .trust_once));
    try std.testing.expectError(error.StaleRetainedOperation, factory.prepare(factory.context, frozen));
    try std.testing.expectEqual(sessions.Lifecycle.closed, host.queryState(original.handle).?.lifecycle);
}

test "SSH auxiliary authentication owns its new key and rejects the reply after original session close" {
    var adapter: DomainAdapter = .{};
    var host = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.adapter(.ssh)});
    defer host.deinit();
    var library: ssh.Library = .{ .active = true };
    const authentication = try module.FileAuthentication.init(std.testing.allocator, &host, .{ .library = &library, .known_hosts_path = "/no-io/auxiliary/known_hosts" });
    defer authentication.deinit() catch unreachable;
    var input = spec();
    input.saved.protocol = .ssh;
    input.saved.route_snapshot = &.{.{ .display_name = "Original jump", .endpoint = .{ .host = "hop.example", .user = "hop-user" } }};
    const original = try host.create(input, target);
    try std.testing.expect(try host.ready(original.handle, original.operation, plugins.requiredServices(.ssh)));
    try std.testing.expect(try host.attached(original.handle, .{ .target = target, .tab_id = @fromBackingInt(9) }));
    const start = try host.beginAuxiliaryTransfer(original.handle);
    var frozen: files.Source = .{ .owner = original.handle, .create_key = start.key, .open_key = start.key, .spec = start.spec };
    frozen.spec.saved.immutable_config.endpoint.host = "caller-replaced.invalid";
    const factory = authentication.factory();
    const connector = try factory.prepare(factory.context, frozen);
    defer factory.discard(factory.context, connector);
    const context = authentication.contexts.items[0];
    try std.testing.expectEqualStrings("target.example", context.source.value.spec.saved.immutable_config.endpoint.host);
    try std.testing.expectEqualStrings("hop.example", context.source.value.spec.saved.route_snapshot[0].endpoint.host);
    var observation: Observe = .{ .bridge = &context.host_bridge, .key = connector.key, .host = "hop.example", .port = 22 };
    var thread = try std.Thread.spawn(.{}, Observe.run, .{&observation});
    defer thread.join();
    defer context.host_bridge.cancel();
    try waitPending(&context.host_bridge);
    const pending = authentication.pendingAuthentication().?;
    try std.testing.expect(pending.identity.key.eql(start.key));
    try std.testing.expect(!start.key.eql(original.operation));
    _ = try host.requestClose(original.handle, .{});
    try std.testing.expect(authentication.pendingAuthentication() == null);
    try std.testing.expectError(error.StaleAuthentication, authentication.submitAuthentication(pending.identity, .trust_once));
    try std.testing.expectError(error.StaleCreateOperation, factory.prepare(factory.context, frozen));
}
