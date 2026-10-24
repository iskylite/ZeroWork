//! Host-side IO for an explicitly selected AI image attachment.
//! No picker, active-tab lookup or arbitrary-path tool is introduced here.
const std = @import("std");
const attachments = @import("../ai/image_attachments.zig");
const CancelToken = @import("../ai/provider.zig").CancelToken;
const clock = @import("../platform/realtime.zig");

/// One explicitly selected file, owned independently of the current AI pane.
/// start/poll/cancel/take/deinit belong to the starting (UI) thread. The worker
/// only owns the copied path, ticket, token and immutable result, never Draft.
/// The supplied allocator must support allocating on the worker and freeing on
/// the starting thread (for example c_allocator or a thread-safe GPA).
pub const Reader = struct {
    allocator: std.mem.Allocator,
    ticket: attachments.Ticket,
    /// UI-only assistant conversation identity; unchanged by view switching.
    conversation: u64 = 0,
    /// UI-thread-only replacement identity; the worker never reads Draft.
    replaces: ?attachments.Ticket = null,
    path: []u8,
    limits: attachments.Limits,
    source_bytes: ?[]u8 = null,
    owner_thread: std.Thread.Id,
    thread: ?std.Thread = null,
    cancel_token: CancelToken = .{},
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!attachments.ContentRef = error.ReaderNotComplete,
    taken: bool = false,

    pub const Completion = struct {
        ticket: attachments.Ticket,
        /// Ownership moves to the caller. Pass a success to Draft.complete()
        /// (which always consumes it), or release it explicitly.
        result: anyerror!attachments.ContentRef,
    };

    pub fn start(allocator: std.mem.Allocator, ticket: attachments.Ticket, selected_absolute_path: []const u8, limits: attachments.Limits) !*Reader {
        if (!std.fs.path.isAbsolute(selected_absolute_path) or std.mem.indexOfScalar(u8, selected_absolute_path, 0) != null) return error.InvalidAttachmentPath;
        const path = try allocator.dupe(u8, selected_absolute_path);
        errdefer allocator.free(path);
        const self = try allocator.create(Reader);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .ticket = ticket, .path = path, .limits = limits.effective(), .owner_thread = std.Thread.getCurrentId() };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Clipboard bytes are copied synchronously; decode runs on the worker.
    pub fn startBytes(allocator: std.mem.Allocator, ticket: attachments.Ticket, label: []const u8, bytes: []const u8, limits: attachments.Limits) !*Reader {
        if (bytes.len > limits.effective().bytes) return error.ImageTooLarge;
        try attachments.validateClipboard(bytes);
        const path = try allocator.dupe(u8, label);
        errdefer allocator.free(path);
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);
        const self = try allocator.create(Reader);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .ticket = ticket, .path = path, .limits = limits.effective(), .source_bytes = owned, .owner_thread = std.Thread.getCurrentId() };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Nonblocking readiness check. No join or filesystem work occurs here.
    pub fn poll(self: *const Reader) bool {
        self.assertOwner();
        return self.done.load(.acquire);
    }

    /// Invalidates even an already queued success which has not been taken.
    pub fn cancel(self: *Reader) void {
        self.assertOwner();
        self.cancel_token.cancel();
    }

    pub fn take(self: *Reader) ?Completion {
        self.assertOwner();
        if (self.taken or !self.poll()) return null;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.taken = true;
        var result = self.result;
        self.result = error.ReaderResultTaken;
        if (self.cancel_token.isCancelled()) {
            releaseResult(result);
            result = error.Cancelled;
        }
        return .{ .ticket = self.ticket, .result = result };
    }

    /// Close paths must call this before destroying the owning Store/Draft.
    /// Joins the bounded reader and frees an unclaimed or cancelled result.
    pub fn deinit(self: *Reader) void {
        self.assertOwner();
        self.cancel_token.cancel();
        if (self.thread) |thread| thread.join();
        releaseResult(self.result);
        const allocator = self.allocator;
        allocator.free(self.path);
        if (self.source_bytes) |bytes| allocator.free(bytes);
        allocator.destroy(self);
    }

    fn run(self: *Reader) void {
        defer self.done.store(true, .release);
        var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        self.result = if (self.source_bytes) |bytes| captureBytes(self.allocator, self.path, bytes, &self.cancel_token, self.limits) else capture(self.allocator, threaded.io(), self.path, &self.cancel_token, self.limits);
    }

    fn assertOwner(self: *const Reader) void {
        std.debug.assert(self.owner_thread == std.Thread.getCurrentId());
    }

    fn releaseResult(result: anyerror!attachments.ContentRef) void {
        if (result) |reference| {
            var owned = reference;
            owned.release();
        } else |_| {}
    }
};

pub fn capture(allocator: std.mem.Allocator, io: std.Io, selected_absolute_path: []const u8, cancel: *const CancelToken, requested: attachments.Limits) !attachments.ContentRef {
    const limits = requested.effective();
    try check(cancel);
    if (!std.fs.path.isAbsolute(selected_absolute_path) or std.mem.indexOfScalar(u8, selected_absolute_path, 0) != null) return error.InvalidAttachmentPath;
    const directory = std.Io.Dir.cwd();
    const before = try directory.statFile(io, selected_absolute_path, .{ .follow_symlinks = false });
    if (before.kind != .file) return error.NotRegularImage;
    if (before.size > limits.bytes) return error.ImageTooLarge;
    try check(cancel);
    const file = try std.Io.Dir.openFileAbsolute(io, selected_absolute_path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    if (changed(before, opened)) return error.ImageSourceChanged;
    // One extra byte proves growth/oversize without unbounded reads.
    const buffer = try allocator.alloc(u8, limits.bytes + 1);
    defer allocator.free(buffer);
    var used: usize = 0;
    while (used < buffer.len) {
        try check(cancel);
        const count = try file.readPositional(io, &.{buffer[used..][0..@min(buffer.len - used, 4096)]}, used);
        try check(cancel);
        if (count == 0) break;
        used += count;
    }
    if (used > limits.bytes) return error.ImageTooLarge;
    const after = try file.stat(io);
    const path_after = directory.statFile(io, selected_absolute_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.ImageSourceChanged,
        else => return err,
    };
    if (changed(opened, after) or changed(before, path_after) or used != after.size) return error.ImageSourceChanged;
    try check(cancel);
    var reference = try attachments.ContentRef.create(allocator, selected_absolute_path, buffer[0..used], clock.milliseconds(undefined), limits);
    errdefer reference.release();
    try check(cancel);
    return reference;
}

fn check(cancel: *const CancelToken) !void {
    if (cancel.isCancelled()) return error.Cancelled;
}
fn changed(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.kind != after.kind or before.inode != after.inode or before.size != after.size or !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime);
}

/// Source preflight precedes allocating a draft slot. Full decode errors after
/// this point stay as retryable accepted attachment errors.
pub fn preflight(io: std.Io, path: []const u8, requested: attachments.Limits) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidAttachmentPath;
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.NotRegularImage;
    if (stat.size > requested.effective().bytes) return error.ImageTooLarge;
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    var prefix: [12]u8 = undefined;
    const n = try file.readPositional(io, &.{&prefix}, 0);
    _ = try attachments.sniff(prefix[0..n]);
}
pub fn captureBytes(allocator: std.mem.Allocator, label: []const u8, bytes: []const u8, cancel: *const CancelToken, limits: attachments.Limits) !attachments.ContentRef {
    try check(cancel);
    try attachments.validateClipboard(bytes);
    const normalized = if (attachments.sniff(bytes)) |_| null else |_| try @import("ai_image_png.zig").convert(allocator, bytes, limits);
    defer if (normalized) |owned| allocator.free(owned);
    try check(cancel);
    var reference = try attachments.ContentRef.create(allocator, label, normalized orelse bytes, clock.milliseconds(undefined), limits);
    errdefer reference.release();
    try check(cancel);
    return reference;
}
