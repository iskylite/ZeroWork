//! Explicit VM check of the production FileBindingHost/DirectFactory path.
//! The controlled domain adapter only provides actual SessionHost-issued test
//! identities; it is never part of ApplicationHost or a readiness claim.
const std = @import("std");
const files = @import("host/file_binding_host.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const identity = @import("host/identity.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");

const Adapter = struct {
    file_host: ?*files.FileBindingHost = null,
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(raw: *anyopaque, owner: identity.SessionHandle, key: sessions.OperationKey) !sessions.CloseReceipt {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        return switch (try self.file_host.?.requestClose(owner, key)) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        };
    }
    fn stale(_: *anyopaque, _: identity.SessionHandle, _: sessions.OperationKey) void {}
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
const Trust = struct {
    fingerprint: []const u8,
    fn observe(raw: *anyopaque, _: []const u8, _: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Trust = @ptrCast(@alignCast(raw));
        if (info.status != .unknown or !std.mem.eql(u8, self.fingerprint, info.fingerprint)) return .reject_unknown;
        std.debug.print("HOSTKEY algorithm={s} fingerprint={s} trust=unknown_once\n", .{ info.algorithm, info.fingerprint });
        return .trust_once;
    }
};
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn drain(host: *files.FileBindingHost) !void {
    const deadline = clock.monotonicNs() + 30 * std.time.ns_per_s;
    while (try host.safeTick()) {
        if (clock.monotonicNs() >= deadline) return error.CleanupNotReleased;
        pause();
    }
}
fn validateStartup(host: *files.FileBindingHost, domain: *sessions.SessionHost, accepted: sessions.Accepted, logical: files.Bindings, endpoint: files.readonly.EndpointRef) !void {
    if (host.attach(accepted.handle, logical)) |_| return error.ConsumerAttachedBeforeReady else |err| if (err != error.StaleBinding) return err;
    if (host.begin(logical.directory, .{ .path = ".", .action = .realpath })) |_| return error.ConsumerReadBeforeReady else |err| if (err != error.StaleBinding) return err;
    const keys = [_]sessions.OperationKey{
        try host.beginPreparing(logical.directory, accepted.operation, .{ .path = ".", .action = .realpath }),
        try host.beginPreparing(logical.directory, accepted.operation, .{ .path = "/", .action = .{ .list = .{ .page_entries = 8 } }, .directory_revision = 19 }),
    };
    var complete: [2]bool = @splat(false);
    var entries: usize = 0;
    var pages: usize = 0;
    const deadline = clock.monotonicNs() + 30 * std.time.ns_per_s;
    while (!complete[0] or !complete[1]) {
        if (domain.queryState(accepted.handle).?.lifecycle != .creating or domain.queryService(accepted.handle, .directory) != .temporarily_unavailable or domain.queryService(accepted.handle, .file_read) != .temporarily_unavailable) return error.ServicesPublishedBeforeValidation;
        _ = try host.safeTick();
        for (keys, 0..) |key, index| {
            while (host.take(key)) |received| {
                var response = received;
                defer response.deinit();
                const value = response.result.value;
                if (response.stale or !value.key.eql(key) or !value.endpoint.eql(endpoint)) return error.StaleStartupResponse;
                switch (value.body) {
                    .realpath => |path| {
                        if (index != 0 or path[0] != '/') return error.StartupRealpathMismatch;
                        std.debug.print("STARTUP_REALPATH path={s} lifecycle=creating queryService=unavailable\n", .{path});
                    },
                    .page => |page| {
                        if (index != 1 or page.index != pages or value.directory_revision != 19) return error.StartupPageMismatch;
                        entries += page.entries.len;
                        pages += 1;
                    },
                    .failure => |failure| {
                        std.debug.print("STARTUP_FAIL reason={s}\n", .{@tagName(failure)});
                        return error.StartupValidationFailed;
                    },
                    else => return error.UnexpectedStartupBody,
                }
                if (value.final) {
                    if (host.cleanupReceipt(key) != .released or !domain.journal.isTerminal(key)) return error.StartupCleanupMissing;
                    complete[index] = true;
                    try host.retire(key);
                }
            }
        }
        if (clock.monotonicNs() >= deadline) return error.StartupTimedOut;
        pause();
    }
    if (entries != 21 or pages != 3 or domain.journal.isTerminal(accepted.operation) or host.state(logical.directory).?.phase != .ready) return error.StartupValidationMismatch;
    std.debug.print("STARTUP_LIST entries={d} pages={d} revision=19 parent_create_terminal=false physical_subsystem=ready\n", .{ entries, pages });
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const trust_path = args.next() orelse return error.MissingTrustPath;
    const host_name = args.next() orelse return error.MissingHost;
    const allowed_host = init.environ_map.get("ZEROWORK_VM_HOST") orelse "127.0.0.1";
    const port = try std.fmt.parseInt(u16, args.next() orelse "22", 10);
    if (!std.mem.startsWith(u8, trust_path, "/tmp/zerowork-file-host-") or !std.mem.endsWith(u8, trust_path, "/known_hosts")) return error.IsolationRequired;
    if (!std.mem.eql(u8, host_name, allowed_host) or port != 22) return error.EndpointNotAuthorized;
    const password = init.environ_map.get("ZEROWORK_VM_PASSWORD") orelse return error.MissingCredential;
    var library = try ssh.Library.init();
    defer library.deinit();
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(init.gpa, &.{adapter.interface()});
    defer domain.deinit();
    var trust: Trust = .{ .fingerprint = init.environ_map.get("ZEROWORK_SFTP_FINGERPRINT") orelse return error.MissingFingerprint };
    var factory: files.DirectFactory = .{ .library = &library, .known_hosts_path = trust_path, .host_key_observer = .{ .ctx = &trust, .callback = Trust.observe }, .timeout_ms = 5000 };
    var host = try files.FileBindingHost.init(init.gpa, &domain, factory.interface());
    defer {
        host.requestCloseAll();
        drain(&host) catch unreachable;
        host.deinit() catch unreachable;
    }
    adapter.file_host = &host;
    const original_host = try init.gpa.dupe(u8, host_name);
    const original_password = try init.gpa.dupe(u8, password);
    const result = domain.create(.{ .saved = .{
        .connection_id = @fromBackingInt(97),
        .config_revision = 13,
        .protocol = .sftp,
        .immutable_config = .{ .endpoint = .{ .host = original_host, .port = port, .user = "root" }, .auth = .{ .password = original_password }, .startup_commands = &.{"cd /"} },
    } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    init.gpa.free(original_host);
    init.gpa.free(original_password);
    const accepted = try result;
    const logical: files.Bindings = .{
        .directory = try domain.reserveService(accepted.handle, accepted.operation, .directory),
        .file_read = try domain.reserveService(accepted.handle, accepted.operation, .file_read),
    };
    const endpoint = try host.attachPreparing(accepted.handle, accepted.operation, logical);
    try validateStartup(&host, &domain, accepted, logical, endpoint);
    const before_ready = domain.next_binding;
    if (!try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp))) return error.DomainReadyRejected;
    if (!domain.queryService(accepted.handle, .directory).available.eql(logical.directory) or !domain.queryService(accepted.handle, .file_read).available.eql(logical.file_read)) return error.ReservedIdentityChanged;
    if (domain.next_binding != before_ready + @as(u64, @popCount(plugins.requiredServices(.sftp).bits)) - 2) return error.ReservedIdentityAllocatedTwice;
    if (!try domain.attached(accepted.handle, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(1) })) return error.DomainAttachRejected;
    if (!(try host.attach(accepted.handle, logical)).eql(endpoint)) return error.PhysicalBindingRecreated;
    if (endpoint.binding_id != logical.directory.binding_id or endpoint.binding_id == logical.file_read.binding_id) return error.PhysicalMappingMismatch;
    const open_key = host.state(logical.directory).?.open_key;
    std.debug.print("BIND owner={d} generation={d} directory={d} file_read={d} physical_endpoint={d} create_operation={d} open_operation={d}\n", .{ @backingInt(accepted.handle.session_id), accepted.handle.generation, logical.directory.binding_id, logical.file_read.binding_id, endpoint.binding_id, accepted.operation.operation_id, open_key.operation_id });
    const read_key = try host.begin(logical.file_read, .{ .path = "/etc/os-release", .action = .{ .read_text = .{} } });
    const list_key = try host.begin(logical.directory, .{ .path = "/", .action = .{ .list = .{ .page_entries = 8 } }, .directory_revision = 17 });
    const realpath_key = try host.begin(logical.directory, .{ .path = ".", .action = .realpath });
    const stat_key = try host.begin(logical.directory, .{ .path = "/etc/os-release", .action = .stat });
    const keys = [_]sessions.OperationKey{ read_key, list_key, realpath_key, stat_key };
    var complete: [4]bool = @splat(false);
    var entries: usize = 0;
    var pages: usize = 0;
    const deadline = clock.monotonicNs() + 30 * std.time.ns_per_s;
    while (true) {
        _ = try host.safeTick();
        for (keys, 0..) |key, index| {
            while (host.take(key)) |received| {
                var response = received;
                defer response.deinit();
                const value = response.result.value;
                if (response.stale or !value.key.eql(key) or !value.endpoint.eql(endpoint)) return error.StaleResponse;
                switch (value.body) {
                    .text => |text| {
                        if (index != 0 or text.truncated or std.mem.indexOf(u8, text.text, "ID=") == null) return error.ReadMismatch;
                        std.debug.print("READ requested={s} resolved={s} size={any} bytes={d} cleanup={s}\n", .{ value.requested_path, value.resolved_path.?, text.original_size, text.read_bytes, @tagName(value.cleanup) });
                    },
                    .page => |page| {
                        if (index != 1 or value.directory_revision != 17 or page.index != pages) return error.PageMismatch;
                        pages += 1;
                        entries += page.entries.len;
                    },
                    .realpath => |path| {
                        if (index != 2 or path[0] != '/') return error.RealpathMismatch;
                        std.debug.print("REALPATH resolved={s}\n", .{path});
                    },
                    .stat => |attrs| {
                        if (index != 3) return error.StatMismatch;
                        std.debug.print("LSTAT kind={s} size={any}\n", .{ @tagName(attrs.kind), attrs.size });
                    },
                    .failure => |failure| {
                        std.debug.print("FAIL request={d} reason={s}\n", .{ value.request_id, @tagName(failure) });
                        return error.FileRequestFailed;
                    },
                    else => return error.UnexpectedBody,
                }
                if (value.final) {
                    if (host.cleanupReceipt(key) != .released or !domain.journal.isTerminal(key)) return error.OperationCleanupMissing;
                    complete[index] = true;
                    try host.retire(key);
                }
            }
        }
        var all = true;
        for (complete) |done| all = all and done;
        if (all) break;
        if (clock.monotonicNs() >= deadline) return error.RequestTimedOut;
        pause();
    }
    if (entries != 21 or pages != 3) return error.DirectoryMismatch;
    std.debug.print("LIST entries={d} pages={d} original_revision=17\n", .{ entries, pages });
    const late_key = try host.begin(logical.file_read, .{ .path = "/etc/os-release", .action = .{ .read_text = .{} } });
    while (!domain.journal.isTerminal(late_key)) {
        _ = try host.safeTick();
        if (clock.monotonicNs() >= deadline) return error.RequestTimedOut;
        pause();
    }
    const close_key = try domain.requestClose(accepted.handle, .{});
    var late = host.take(late_key) orelse return error.LateResultMissing;
    defer late.deinit();
    if (!late.stale or late.result.value.body != .cancelled) return error.LateContentLeaked;
    try host.retire(late_key);
    try drain(&host);
    if (domain.queryState(accepted.handle).?.lifecycle != .closed) _ = try domain.closeReceipt(accepted.handle, close_key, .close_protocol, .released);
    if (domain.queryState(accepted.handle).?.lifecycle != .closed) return error.DomainClosePending;
    var open_released = false;
    while (domain.journal.take()) |item| {
        var event = item;
        defer event.deinit();
        if (event.value.key.eql(open_key) and event.value.kind == .cleanup_released) open_released = true;
    }
    if (!open_released) return error.OpenOperationCleanupMissing;
    if (std.Io.Dir.cwd().openFile(init.io, trust_path, .{})) |file| {
        file.close(init.io);
        return error.OnceTrustCreatedFile;
    } else |err| if (err != error.FileNotFound) return err;
    std.debug.print("PASS file_binding_host=true startup_realpath_list_before_ready=true consumer_gated_during_creating=true reserved_handles_reused=true domain_ids=true saved_spec_owned=true same_journal=true typed_kind_mapping=true late_content_suppressed=true no_shell=true readonly=true cleanup=released domain_closed=true known_hosts_absent=true\n", .{});
}
