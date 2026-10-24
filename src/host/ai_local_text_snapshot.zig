//! Host-side IO for an explicitly selected AI local-text attachment.
//! No picker, active-tab lookup or arbitrary-path tool is introduced here.
const std = @import("std");
const attachments = @import("../ai/local_text_attachments.zig");
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

    pub fn start(allocator: std.mem.Allocator, ticket: attachments.Ticket, selected_absolute_path: []const u8) !*Reader {
        if (!std.fs.path.isAbsolute(selected_absolute_path) or std.mem.indexOfScalar(u8, selected_absolute_path, 0) != null) return error.InvalidAttachmentPath;
        const path = try allocator.dupe(u8, selected_absolute_path);
        errdefer allocator.free(path);
        const self = try allocator.create(Reader);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .ticket = ticket, .path = path, .owner_thread = std.Thread.getCurrentId() };
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
        allocator.destroy(self);
    }

    fn run(self: *Reader) void {
        defer self.done.store(true, .release);
        var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        self.result = capture(self.allocator, threaded.io(), self.path, &self.cancel_token);
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

pub fn capture(allocator: std.mem.Allocator, io: std.Io, selected_absolute_path: []const u8, cancel: *const CancelToken) !attachments.ContentRef {
    try check(cancel);
    if (!std.fs.path.isAbsolute(selected_absolute_path) or std.mem.indexOfScalar(u8, selected_absolute_path, 0) != null) return error.InvalidAttachmentPath;
    const directory = std.Io.Dir.cwd();
    const before = try directory.statFile(io, selected_absolute_path, .{ .follow_symlinks = false });
    if (before.kind != .file) return error.NotRegularLocalText;
    if (before.size > attachments.max_bytes) return error.LocalTextTooLarge;
    try check(cancel);
    const file = try std.Io.Dir.openFileAbsolute(io, selected_absolute_path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    if (changed(before, opened)) return error.LocalTextSourceChanged;
    // One extra byte proves growth/oversize without unbounded reads.
    const buffer = try allocator.alloc(u8, attachments.max_bytes + 1);
    defer allocator.free(buffer);
    var used: usize = 0;
    while (used < buffer.len) {
        try check(cancel);
        const count = try file.readPositional(io, &.{buffer[used..][0..@min(buffer.len - used, 4096)]}, used);
        try check(cancel);
        if (count == 0) break;
        used += count;
    }
    if (used > attachments.max_bytes) return error.LocalTextTooLarge;
    const after = try file.stat(io);
    const path_after = directory.statFile(io, selected_absolute_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.LocalTextSourceChanged,
        else => return err,
    };
    if (changed(opened, after) or changed(before, path_after) or used != after.size) return error.LocalTextSourceChanged;
    try check(cancel);
    return attachments.ContentRef.create(allocator, selected_absolute_path, buffer[0..used], clock.milliseconds(undefined));
}

fn check(cancel: *const CancelToken) !void {
    if (cancel.isCancelled()) return error.Cancelled;
}
fn changed(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.kind != after.kind or before.inode != after.inode or before.size != after.size or !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime);
}
