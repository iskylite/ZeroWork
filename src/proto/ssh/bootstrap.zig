//! BootstrapV1 resources and an exact, explicitly approved temporary deployment.
//! The UI approval owner supplies Permit; model arguments cannot create one.
//! No curl, package install, dotfile editing, recursive cleanup or PTY injection.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const ssh = @import("session.zig");
const realtime = @import("../../platform/realtime.zig");
pub const capability = "ssh_cloexec_boundary_interval_v1";
pub const names = [_][]const u8{ "bootstrap", "zw_execution.so", "execution.zsh" };
pub const Probe = struct { os: []const u8, arch: []const u8, shell_path: []const u8, shell_version: []const u8 };
const Manifest = struct {
    schema: u32,
    payload_format: []const u8,
    protocol: []const u8,
    bootstrap: []const u8,
    resource_version: u32,
    platform: []const u8,
    shell: []const u8,
    shell_version: []const u8,
    capability: []const u8,
    output_scope: []const u8,
    files: []const struct { name: []const u8, bytes: usize, sha256: []const u8, mode: u32 },
};
pub const Package = struct {
    arena: std.heap.ArenaAllocator,
    platform: []const u8,
    manifest_hash: [32]u8,
    files: [3][]const u8,
    hashes: [3][32]u8,
    pub fn deinit(self: *Package) void {
        self.arena.deinit();
    }
    /// Production callers select only the App/CLI bundle next to the current
    /// executable. Resource locations are never model supplied remote paths.
    pub fn loadBundled(a: std.mem.Allocator, io: std.Io, platform: []const u8) !Package {
        if (!eq(platform, "darwin-aarch64") and !eq(platform, "linux-x86_64") and !eq(platform, "linux-aarch64")) return error.UnsupportedBootstrapPlatform;
        const executable = try std.process.executablePathAlloc(io, a);
        defer a.free(executable);
        const parent = std.fs.path.dirname(executable) orelse return error.BootstrapResourceUnavailable;
        const path = if (std.mem.endsWith(u8, parent, "/Contents/MacOS")) try std.fs.path.join(a, &.{ parent, "../Resources/ssh-bootstrap/v1", platform }) else try std.fs.path.join(a, &.{ parent, "../share/zerowork/ssh-bootstrap/v1", platform });
        defer a.free(path);
        const dir = std.Io.Dir.cwd().openDir(io, path, .{ .follow_symlinks = false }) catch return error.BootstrapResourceUnavailable;
        defer dir.close(io);
        return load(a, io, dir);
    }
    /// `directory` is the signed App resource platform directory. Refuse link
    /// files and verify every bounded payload before asking for deployment.
    pub fn load(a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !Package {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const bytes = try readResource(allocator, io, directory, "manifest.json", 16 * 1024);
        const parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .ignore_unknown_fields = true });
        const m = parsed.value;
        if (m.schema != 1 or !eq(m.payload_format, "ZWBOOTSTRAP1") or m.resource_version != 1 or !eq(m.protocol, "TerminalExecutionProtocolV1") or !eq(m.bootstrap, "BootstrapV1") or !eq(m.shell, "zsh") or !eq(m.shell_version, "5.9") or !eq(m.capability, capability) or !eq(m.output_scope, "session_interval") or m.files.len != names.len) return error.UnsupportedBootstrapResource;
        if (!eq(m.platform, "darwin-aarch64") and !eq(m.platform, "linux-x86_64") and !eq(m.platform, "linux-aarch64")) return error.UnsupportedBootstrapPlatform;
        var result: Package = .{ .arena = arena, .platform = m.platform, .manifest_hash = digest(bytes), .files = undefined, .hashes = undefined };
        for (names, m.files, 0..) |name, file, i| {
            if (!eq(file.name, name) or file.bytes == 0 or file.bytes > 8 * 1024 * 1024 or file.mode != @as(u32, if (i == 0) 0o700 else 0o600)) return error.InvalidBootstrapManifest;
            const encoded_name = try std.fmt.allocPrint(allocator, "{s}.payload", .{name});
            const encoded = try readResource(allocator, io, directory, encoded_name, 8 * 1024 * 1024 + 13);
            const magic = "ZWBOOTSTRAP1\n";
            if (!std.mem.startsWith(u8, encoded, magic)) return error.InvalidBootstrapResource;
            const data = encoded[magic.len..];
            if (data.len != file.bytes) return error.BootstrapResourceHashMismatch;
            const expected = std.fmt.hexToBytes(&result.hashes[i], file.sha256) catch return error.InvalidBootstrapManifest;
            if (expected.len != 32 or !std.mem.eql(u8, &digest(data), &result.hashes[i])) return error.BootstrapResourceHashMismatch;
            result.files[i] = data;
        }
        return result;
    }
};
fn readResource(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, limit: usize) ![]const u8 {
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0 or stat.size > limit) return error.InvalidBootstrapResource;
    const bytes = try a.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.BootstrapResourceTruncated;
    return bytes;
}
pub const Permit = struct {
    owner: identity.SessionHandle,
    task_id: identity.TaskId,
    plan_hash: [32]u8,
    expires_at: i64,
};
pub const Plan = struct {
    owner: identity.SessionHandle,
    task_id: identity.TaskId,
    directory: [53]u8,
    nonce: [64]u8,
    shell_path: enum { bin, usr_bin },
    package: *const Package,
    permit: ?Permit = null,
    pub fn prepare(owner: identity.SessionHandle, task_id: identity.TaskId, package: *const Package, probe: Probe, new_owned: bool) !Plan {
        if (!new_owned) return error.BootstrapRequiresNewOwnedSession;
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0 or !task_id.valid()) return error.InvalidBootstrapOwner;
        if (!eq(probe.shell_version, "5.9") or (!eq(probe.shell_path, "/bin/zsh") and !eq(probe.shell_path, "/usr/bin/zsh"))) return error.UnsupportedBootstrapShell;
        const platform = if (eq(probe.os, "Darwin") and eq(probe.arch, "arm64")) "darwin-aarch64" else if (eq(probe.os, "Linux") and eq(probe.arch, "x86_64")) "linux-x86_64" else if (eq(probe.os, "Linux") and (eq(probe.arch, "aarch64") or eq(probe.arch, "arm64"))) "linux-aarch64" else return error.UnsupportedBootstrapPlatform;
        if (!eq(platform, package.platform)) return error.BootstrapPlatformMismatch;
        var random: [32]u8 = undefined;
        std.c.arc4random_buf(&random, random.len);
        const suffix = std.fmt.bytesToHex(random[0..16].*, .lower);
        var result: Plan = .{ .owner = owner, .task_id = task_id, .package = package, .shell_path = if (eq(probe.shell_path, "/bin/zsh")) .bin else .usr_bin, .nonce = undefined, .directory = undefined };
        @memcpy(result.directory[0..21], "/tmp/zw-bootstrap-v1-");
        @memcpy(result.directory[21..], &suffix);
        std.c.arc4random_buf(&random, random.len);
        result.nonce = std.fmt.bytesToHex(random, .lower);
        return result;
    }
    pub fn hash(self: *const Plan) [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("ZeroWork BootstrapV1 temporary deployment\x00");
        h.update(std.mem.asBytes(&@as(u64, @backingInt(self.owner.session_id))));
        h.update(std.mem.asBytes(&self.owner.generation));
        h.update(&self.task_id.bytes);
        h.update(&self.directory);
        h.update(&self.nonce);
        h.update(self.package.platform);
        h.update(&self.package.manifest_hash);
        h.update(@tagName(self.shell_path));
        var value: [32]u8 = undefined;
        h.final(&value);
        return value;
    }
    pub fn validate(self: *const Plan, owner: identity.SessionHandle, now: i64) !void {
        if (!owner.eql(self.owner) or !validDirectory(&self.directory)) return error.StaleBootstrapOwner;
        const permit = self.permit orelse return error.BootstrapDeploymentAuthorizationRequired;
        if (!permit.owner.eql(owner) or !permit.task_id.eql(self.task_id) or !std.mem.eql(u8, &permit.plan_hash, &self.hash()) or now >= permit.expires_at) return error.StaleBootstrapAuthorization;
        for (self.package.files, self.package.hashes) |bytes, expected| if (!std.mem.eql(u8, &digest(bytes), &expected)) return error.BootstrapResourceHashMismatch;
    }
    pub fn command(self: *const Plan, a: std.mem.Allocator, control: bool) ![:0]u8 {
        if (!validDirectory(&self.directory)) return error.InvalidBootstrapDirectory;
        if (control) return std.fmt.allocPrintSentinel(a, "'{s}/bootstrap' control '{s}'", .{ self.directory, self.directory }, 0);
        return std.fmt.allocPrintSentinel(a, "'{s}/bootstrap' shell '{s}' {d} {d} '{s}' '{s}'", .{ self.directory, self.directory, @backingInt(self.owner.session_id), self.owner.generation, self.nonce, if (self.shell_path == .bin) "/bin/zsh" else "/usr/bin/zsh" }, 0);
    }
};
pub fn validDirectory(path: []const u8) bool {
    return path.len == 53 and std.mem.startsWith(u8, path, "/tmp/zw-bootstrap-v1-") and for (path[21..]) |c| {
        if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) break false;
    } else true;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn digest(bytes: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}

/// Initial deployment runs on the fresh connection's sole IO owner before its
/// PTY exists. The exact file handle is read back; EXCL and 0700 precede bytes.
pub const NativeGuard = struct {
    context: *anyopaque,
    lock: *const fn (*anyopaque) void,
    unlock: *const fn (*anyopaque) void,
};
pub const Deployment = struct {
    directory: [53]u8,
    files_created: u8 = 0,
    directory_created: bool = false,
    verified: bool = false,
    cleanup: ssh.ReleaseReceipt = .awaiting,
    pub fn install(self: *Deployment, plan: *const Plan, session: *ssh.Session, options: ssh.Options, guard: ?NativeGuard) !void {
        const owner = if (options.operation_key) |key| if (key.owner == .session) key.owner.session else return error.StaleBootstrapOwner else return error.StaleBootstrapOwner;
        try plan.validate(owner, nowMs());
        if (session.channel != null) return error.BootstrapRequiresNewOwnedSession;
        if (guard) |g| g.lock(g.context);
        defer if (guard) |g| g.unlock(g.context);
        self.* = .{ .directory = plan.directory };
        const end = nowMs() + 30_000;
        while (true) {
            session.sftpReadonlyInit() catch |err| {
                try retry(err, options, end, guard);
                continue;
            };
            break;
        }
        const path = try std.heap.c_allocator.dupeSentinel(u8, &plan.directory, 0);
        defer std.heap.c_allocator.free(path);
        while (true) {
            session.sftpMkdirPrivate(path) catch |err| {
                try retry(err, options, end, guard);
                continue;
            };
            break;
        }
        self.directory_created = true;
        session.recordResource(.bootstrap, .owned);
        var attrs: ssh.SftpAttributes = undefined;
        while (true) {
            attrs = session.sftpStat(path, false) catch |err| {
                try retry(err, options, end, guard);
                continue;
            };
            break;
        }
        if (attrs.kind != .directory or attrs.permissions == null or attrs.permissions.? & 0o777 != 0o700) return error.BootstrapPrivateDirectoryRequired;
        for (names, plan.package.files, plan.package.hashes, 0..) |name, bytes, expected, index| {
            const file_path = try std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}/{s}", .{ plan.directory, name }, 0);
            defer std.heap.c_allocator.free(file_path);
            var file: ssh.SftpReadonlyHandle = undefined;
            while (true) {
                file = session.sftpOpenPrivate(file_path, if (index == 0) 0o700 else 0o600) catch |err| {
                    try retry(err, options, end, guard);
                    continue;
                };
                break;
            }
            self.files_created += 1;
            defer {
                while (file.closeReceipt().receipt == .awaiting) {
                    retry(error.WouldBlock, options, end, guard) catch break;
                }
            }
            var offset: usize = 0;
            while (offset < bytes.len) {
                const count = file.writePrivate(bytes[offset..@min(offset + 32768, bytes.len)]) catch |err| {
                    try retry(err, options, end, guard);
                    continue;
                };
                if (count == 0) {
                    try retry(error.WouldBlock, options, end, guard);
                    continue;
                }
                offset += count;
            }
            while (true) {
                attrs = file.stat() catch |err| {
                    try retry(err, options, end, guard);
                    continue;
                };
                break;
            }
            if (attrs.kind != .file or attrs.size != bytes.len or attrs.permissions == null or attrs.permissions.? & 0o777 != @as(u32, if (index == 0) 0o700 else 0o600)) return error.BootstrapRemoteResourceMismatch;
            // Read back using a separate read handle; SFTP's exact original
            // EXCL handle remains open and checked until verification finishes.
            var reader: ssh.SftpReadonlyHandle = undefined;
            while (true) {
                reader = session.sftpOpenReadonly(file_path, false) catch |err| {
                    try retry(err, options, end, guard);
                    continue;
                };
                break;
            }
            defer {
                while (reader.closeReceipt().receipt == .awaiting) {
                    retry(error.WouldBlock, options, end, guard) catch break;
                }
            }
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            var buffer: [32768]u8 = undefined;
            offset = 0;
            while (offset < bytes.len) {
                const count = reader.read(buffer[0..@min(buffer.len, bytes.len - offset)]) catch |err| {
                    try retry(err, options, end, guard);
                    continue;
                };
                if (count == 0) return error.BootstrapRemoteResourceMismatch;
                hash.update(buffer[0..count]);
                offset += count;
            }
            var actual: [32]u8 = undefined;
            hash.final(&actual);
            if (!std.mem.eql(u8, &expected, &actual)) return error.BootstrapRemoteResourceMismatch;
        }
        self.verified = true;
    }
    /// Exact owned names only; no directory recursion or wildcard. Failure is
    /// an explicit owned resource receipt for the caller, never fake released.
    pub fn release(self: *Deployment, session: *ssh.Session, options: ssh.Options) ssh.ReleaseReceipt {
        if (!self.directory_created) {
            self.cleanup = .released;
            return .released;
        }
        const end = nowMs() + 2000;
        for (names[0..self.files_created]) |name| {
            var path: [128:0]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&path, "{s}/{s}", .{ self.directory, name }, 0) catch return .unknown;
            while (true) {
                session.sftpUnlinkOwned(text) catch |err| {
                    if (err == error.FileNotFound) break;
                    retry(err, options, end, null) catch {
                        self.cleanup = .unknown;
                        return .unknown;
                    };
                    continue;
                };
                break;
            }
        }
        // These names are created only by the approved launcher in this exact
        // EXCL-owned directory. No wildcard or user-dotfile path is accepted.
        for ([_][]const u8{ ".zshrc", "shell.sock", "control.sock" }) |name| {
            var runtime_path: [128:0]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&runtime_path, "{s}/{s}", .{ self.directory, name }, 0) catch return .unknown;
            while (true) {
                session.sftpUnlinkOwned(text) catch |err| {
                    if (err == error.FileNotFound) break;
                    retry(err, options, end, null) catch {
                        self.cleanup = .unknown;
                        return .unknown;
                    };
                    continue;
                };
                break;
            }
        }
        var path: [54:0]u8 = undefined;
        @memcpy(path[0..53], &self.directory);
        path[53] = 0;
        while (true) {
            session.sftpRmdirOwned(path[0..53 :0]) catch |err| {
                if (err == error.FileNotFound) break;
                retry(err, options, end, null) catch {
                    self.cleanup = .unknown;
                    return .unknown;
                };
                continue;
            };
            break;
        }
        self.directory_created = false;
        self.cleanup = .released;
        return .released;
    }
};
/// Releases only this owned BootstrapV1 graph. Native EAGAIN pins the exact
/// channel/Session; it never aborts an authenticated shared transport.
pub fn closeResources(session: *ssh.Session, control: *?@import("channel.zig").Channel, deployment: *?Deployment, options: ssh.Options) ssh.ReleaseReceipt {
    if (control.*) |*channel| {
        session.recordResource(.execution_control, .releasing);
        const receipt = session.closeChannelReceipt(channel);
        if (receipt != .released) return receipt;
        control.* = null;
        session.recordResource(.execution_control, .released);
    }
    if (session.channel) |*channel| {
        const receipt = session.closeChannelReceipt(channel);
        if (receipt != .released) return receipt;
    }
    if (deployment.*) |*value| {
        session.recordResource(.bootstrap, .releasing);
        var cleanup_options = options;
        cleanup_options.cancel_token = null;
        const receipt = value.release(session, cleanup_options);
        session.recordResource(.bootstrap, if (receipt == .released) .released else .unknown);
        if (receipt != .released) return receipt;
        deployment.* = null;
    }
    return .released;
}
fn retry(err: anyerror, options: ssh.Options, end: i64, guard: ?NativeGuard) !void {
    if (err != error.WouldBlock and err != error.ChannelOpenBusy) return err;
    if (options.cancel_token) |token| if (token.load(.acquire)) return error.Cancelled;
    if (nowMs() >= end) return error.BootstrapTimedOut;
    if (guard) |g| g.unlock(g.context);
    pause();
    if (guard) |g| g.lock(g.context);
}
fn pause() void {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

fn nowMs() i64 {
    return @intCast(@divTrunc(realtime.monotonicNs(), std.time.ns_per_ms));
}

test "SSH BootstrapV1 plan binds explicit approval to exact owned directory platform resources and generation" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedBootstrapPlatform, Package.loadBundled(a, std.testing.io, "unknown"));
    var package: Package = .{ .arena = std.heap.ArenaAllocator.init(a), .platform = "linux-x86_64", .manifest_hash = digest("manifest"), .files = .{ "a", "b", "c" }, .hashes = .{ digest("a"), digest("b"), digest("c") } };
    defer package.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(17), .generation = 2 };
    const task = identity.TaskId.generate();
    const probe: Probe = .{ .os = "Linux", .arch = "x86_64", .shell_path = "/bin/zsh", .shell_version = "5.9" };
    try std.testing.expectError(error.BootstrapRequiresNewOwnedSession, Plan.prepare(owner, task, &package, probe, false));
    var plan = try Plan.prepare(owner, task, &package, probe, true);
    try std.testing.expect(validDirectory(&plan.directory));
    try std.testing.expectError(error.BootstrapDeploymentAuthorizationRequired, plan.validate(owner, 1));
    plan.permit = .{ .owner = owner, .task_id = task, .plan_hash = plan.hash(), .expires_at = 100 };
    try plan.validate(owner, 99);
    try std.testing.expectError(error.StaleBootstrapAuthorization, plan.validate(owner, 100));
    try std.testing.expectError(error.StaleBootstrapOwner, plan.validate(.{ .session_id = owner.session_id, .generation = 3 }, 99));
    plan.nonce[0] = if (plan.nonce[0] == '0') '1' else '0';
    try std.testing.expectError(error.StaleBootstrapAuthorization, plan.validate(owner, 99));
    var wrong_probe = probe;
    wrong_probe.shell_version = "5.8";
    try std.testing.expectError(error.UnsupportedBootstrapShell, Plan.prepare(owner, task, &package, wrong_probe, true));
    wrong_probe = probe;
    wrong_probe.arch = "aarch64";
    try std.testing.expectError(error.BootstrapPlatformMismatch, Plan.prepare(owner, task, &package, wrong_probe, true));
    const command = try plan.command(a, false);
    defer a.free(command);
    try std.testing.expect(std.mem.indexOf(u8, command, " shell '") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "'/bin/zsh'") != null);
    try std.testing.expect(!validDirectory("/tmp/zw-bootstrap-v1-../../escape"));
}
