//! A one-attempt permission for the complete text a human previewed. Neither
//! bytes nor a provider-facing file token live in this draft reference.
const std = @import("std");
const preview = @import("workspace_preview.zig");
const workspace = @import("local_workspace.zig");
const input = @import("../ai/session_input.zig");
const provider = @import("../ai/provider.zig");

pub const Pin = struct { file: workspace.Identity, digest: [32]u8 };
pub const Selection = struct { stamp: preview.Stamp, relative: []const u8, pin: Pin };

fn includes(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    return false;
}

/// The first slice is explicitly selected, small, ordinary documentation.
/// Never attach hidden paths or known credential material. This is not a
/// generic secret detector; only the approved, complete preview is eligible.
pub fn pinText(relative: []const u8, value: preview.Text) !Pin {
    const file = value.file orelse return error.WorkspaceFileNotPlainText;
    if (value.limited or value.line_limited or value.bytes.len == 0 or value.bytes.len > preview.max_bytes) return error.WorkspaceFileNotPlainText;
    if (relative.len == 0 or relative.len >= std.Io.Dir.max_path_bytes or std.mem.indexOfAny(u8, relative, "\x00\r\n") != null) return error.WorkspaceFileNotPlainText;
    var components = std.mem.splitScalar(u8, relative, '/');
    while (components.next()) |part| {
        if (part.len == 0 or part[0] == '.') return error.WorkspaceFileProtected;
        for ([_][]const u8{ "password", "secret", "credential", "token", "private", "authorized_keys", "id_ed25519", "id_rsa" }) |name| {
            if (includes(part, name)) return error.WorkspaceFileProtected;
        }
    }
    const extension = std.fs.path.extension(relative);
    if (!std.ascii.eqlIgnoreCase(extension, ".txt") and !std.ascii.eqlIgnoreCase(extension, ".md") and !std.ascii.eqlIgnoreCase(extension, ".rst")) return error.WorkspaceFileNotPlainText;
    for ([_][]const u8{ "private key-----", "-----begin pgp", "aws_access_key_id", "aws_secret_access_key", "authorization: bearer", "api_key=", "api_key:", "password=", "password:", "token=", "token:", "://" }) |marker| {
        // URLs can embed credentials. Do not guess whether an arbitrary URL
        // in the first preview slice is safe to transfer.
        if (includes(value.bytes, marker)) return error.WorkspaceFileProtected;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value.bytes, &digest, .{});
    return .{ .file = file, .digest = digest };
}

pub const Lease = struct {
    arena: std.heap.ArenaAllocator,
    source: preview.Source,
    relative: []const u8,
    pin: Pin,
    refs: std.atomic.Value(usize) = .init(1),
    revoked: std.atomic.Value(bool) = .init(false),
    run_claimed: std.atomic.Value(bool) = .init(false),
    attempted: std.atomic.Value(bool) = .init(false),
    body_started: std.atomic.Value(bool) = .init(false),

    pub fn create(source: preview.Source, selection: Selection) !*Lease {
        if (!std.meta.eql(source.stamp, selection.stamp)) return error.WorkspaceFileReselectRequired;
        const allocator = std.heap.c_allocator;
        const lease = try allocator.create(Lease);
        errdefer allocator.destroy(lease);
        lease.* = .{ .arena = .init(allocator), .source = source, .relative = "", .pin = selection.pin };
        errdefer lease.arena.deinit();
        const a = lease.arena.allocator();
        lease.source.workspace = try source.workspace.clone(a);
        lease.source.data_root = try a.dupe(u8, source.data_root);
        lease.relative = try a.dupe(u8, selection.relative);
        return lease;
    }
    pub fn retain(self: *Lease) *Lease {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *Lease) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }
    pub fn revoke(self: *Lease) void {
        self.revoked.store(true, .release);
    }
    pub fn claimRun(self: *Lease) !void {
        if (self.run_claimed.swap(true, .acq_rel) or self.revoked.load(.acquire)) return error.WorkspaceFileReselectRequired;
    }

    /// Checked on the controller and again at the provider boundary. The
    /// Inbox is the thread-safe owner of the binding/environment and workspace
    /// revision; the worker must not inspect UI or mutable workspace objects.
    pub fn requireCurrent(self: *const Lease, inbox: *input.Inbox, fence: input.Fence) !void {
        if (self.revoked.load(.acquire) or !fence.eql(self.source.stamp.fence)) return error.WorkspaceFileReselectRequired;
        inbox.lock();
        defer inbox.unlock();
        if (self.revoked.load(.acquire) or !inbox.admission or inbox.closing or inbox.workspace_changing or !inbox.fence.eql(fence) or inbox.workspace_revision != self.source.stamp.revision)
            return error.WorkspaceFileReselectRequired;
    }

    /// The native transport calls this after opening its connection but before
    /// writing any request-body bytes. A started attempt is never reusable.
    pub fn beginBody(self: *Lease, io: std.Io, inbox: *input.Inbox, fence: input.Fence, cancel: ?*const provider.CancelToken) !void {
        if (!self.attempted.load(.acquire) or self.body_started.swap(true, .acq_rel)) return error.WorkspaceFileReselectRequired;
        const a = std.heap.c_allocator;
        const bytes = try self.verifiedText(a, io, inbox, fence, cancel);
        a.free(bytes);
    }

    /// Claims the approval before touching disk. Failure, a native transport
    /// error or an implicit retry cannot read this reference a second time.
    /// Returned bytes are for one temporary request only, not the wire history.
    pub fn takeForSend(self: *Lease, a: std.mem.Allocator, io: std.Io, inbox: *input.Inbox, fence: input.Fence, cancel: ?*const provider.CancelToken) ![]u8 {
        if (self.attempted.swap(true, .acq_rel)) return error.WorkspaceFileReselectRequired;
        return self.verifiedText(a, io, inbox, fence, cancel);
    }

    fn verifiedText(self: *const Lease, a: std.mem.Allocator, io: std.Io, inbox: *input.Inbox, fence: input.Fence, cancel: ?*const provider.CancelToken) ![]u8 {
        try self.requireCurrent(inbox, fence);
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        const job = preview.Job.start(self.source, .read_text_reference, self.relative) catch return error.WorkspaceFileReselectRequired;
        defer {
            job.cancel();
            job.release();
        }
        const limit = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
        while (!job.done.load(.acquire)) {
            try self.requireCurrent(inbox, fence);
            if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
            if (std.Io.Clock.awake.now(io).nanoseconds >= limit) return error.WorkspaceFileReselectRequired;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        const result = job.result catch return error.WorkspaceFileReselectRequired;
        if (result != .text) return error.WorkspaceFileReselectRequired;
        const current = pinText(self.relative, result.text) catch return error.WorkspaceFileReselectRequired;
        if (!std.meta.eql(current, self.pin)) return error.WorkspaceFileReselectRequired;
        try self.requireCurrent(inbox, fence);
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        return a.dupe(u8, result.text.bytes);
    }
};

test "workspace reference accepts exact approved descriptor bytes once, rejects workspace changes and reselects changed files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    try fixture.dir.writeFile(io, .{ .sub_path = "guide.txt", .data = "the exact approved bytes\n" });
    const directory = try fixture.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    var snapshot = try workspace.inspect(a, io, directory);
    defer snapshot.deinit(a);
    const fence: input.Fence = .{ .agent = .generate(), .conversation = .generate(), .binding = 2, .environment = 4 };
    const stamp: preview.Stamp = .{ .owner = .{ .session_id = @fromBackingInt(7), .generation = 3 }, .fence = fence, .scope_revision = 3, .revision = snapshot.revision, .root = snapshot.directory_identity.? };
    const source: preview.Source = .{ .stamp = stamp, .workspace = snapshot, .data_root = "" };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const text = (try preview.capture(arena.allocator(), io, source, .read, "guide.txt")).text;
    const sel: Selection = .{ .stamp = stamp, .relative = "guide.txt", .pin = try pinText("guide.txt", text) };
    var inbox = input.Inbox.init(a, fence);
    defer inbox.deinit();

    const lease = try Lease.create(source, sel);
    defer lease.release();
    const sent = try lease.takeForSend(a, io, &inbox, fence, null);
    defer a.free(sent);
    try std.testing.expectEqualStrings(text.bytes, sent);
    try lease.beginBody(io, &inbox, fence, null);
    try std.testing.expectError(error.WorkspaceFileReselectRequired, lease.beginBody(io, &inbox, fence, null));
    try std.testing.expectError(error.WorkspaceFileReselectRequired, lease.takeForSend(a, io, &inbox, fence, null));

    const changed = try Lease.create(source, sel);
    defer changed.release();
    try fixture.dir.writeFile(io, .{ .sub_path = "guide.txt", .data = "an unapproved replacement\n" });
    try std.testing.expectError(error.WorkspaceFileReselectRequired, changed.takeForSend(a, io, &inbox, fence, null));
    try fixture.dir.writeFile(io, .{ .sub_path = "guide.txt", .data = text.bytes });
    try std.testing.expectError(error.WorkspaceFileReselectRequired, changed.takeForSend(a, io, &inbox, fence, null));

    const before_body = try Lease.create(source, sel);
    defer before_body.release();
    const prepared = try before_body.takeForSend(a, io, &inbox, fence, null);
    defer a.free(prepared);
    try fixture.dir.writeFile(io, .{ .sub_path = "guide.txt", .data = "changed after request preparation\n" });
    try std.testing.expectError(error.WorkspaceFileReselectRequired, before_body.beginBody(io, &inbox, fence, null));
    try fixture.dir.writeFile(io, .{ .sub_path = "guide.txt", .data = text.bytes });
    try std.testing.expectError(error.WorkspaceFileReselectRequired, before_body.beginBody(io, &inbox, fence, null));

    const switched = try Lease.create(source, sel);
    defer switched.release();
    inbox.setWorkspaceRevision(stamp.revision + 1);
    try std.testing.expectError(error.WorkspaceFileReselectRequired, switched.takeForSend(a, io, &inbox, fence, null));
}

test "workspace reference refuses known credential paths contents and partial text" {
    const ordinary: preview.Text = .{ .bytes = "a documentation example", .limited = false, .line_limited = false, .file = .{ .device = 1, .inode = 7 } };
    _ = try pinText("docs/readme.txt", ordinary);
    try std.testing.expectError(error.WorkspaceFileProtected, pinText(".ssh/config.txt", ordinary));
    try std.testing.expectError(error.WorkspaceFileProtected, pinText("credentials.txt", ordinary));
    var secret = ordinary;
    secret.bytes = "-----BEGIN PRIVATE KEY-----";
    try std.testing.expectError(error.WorkspaceFileProtected, pinText("docs/readme.txt", secret));
    var partial = ordinary;
    partial.limited = true;
    try std.testing.expectError(error.WorkspaceFileNotPlainText, pinText("docs/readme.txt", partial));
}
