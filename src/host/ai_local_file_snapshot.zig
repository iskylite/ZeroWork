//! Selected host-local files: bounded type detection, text/image snapshots or a locator.
const std = @import("std");
const attachments = @import("../ai/local_text_attachments.zig");
const images = @import("../ai/image_attachments.zig");
const CancelToken = @import("../ai/provider.zig").CancelToken;
pub const Result = union(enum) {
    file: attachments.ContentRef,
    image: images.ContentRef,
    pub fn release(self: *Result) void {
        switch (self.*) {
            .file => |*reference| reference.release(),
            .image => |*reference| reference.release(),
        }
    }
};
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
    result: anyerror!Result = error.ReaderNotComplete,
    taken: bool = false,

    pub const Completion = struct {
        ticket: attachments.Ticket,
        /// Ownership moves to the caller. Pass a success to Draft.complete()
        /// (which always consumes it), or release it explicitly.
        result: anyerror!Result,
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

    fn releaseResult(result: anyerror!Result) void {
        if (result) |reference| {
            var owned = reference;
            owned.release();
        } else |_| {}
    }
};

pub const probe_limit = 4096;
pub fn capture(allocator: std.mem.Allocator, io: std.Io, path: []const u8, cancel: *const CancelToken) !Result {
    if (cancel.isCancelled()) return error.Cancelled;
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidAttachmentPath;
    const before = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (before.kind != .file) return error.NotRegularLocalFile;
    if (before.size > images.max_bytes) return .{ .file = try attachments.ContentRef.createLocalReference(allocator, path, .{ .reason = .size_limit, .size_bytes = before.size }) };
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    if (changed(before, opened)) return error.LocalTextSourceChanged;
    var buffer: [probe_limit]u8 = undefined;
    var used: usize = 0;
    while (used < buffer.len) {
        if (cancel.isCancelled()) return error.Cancelled;
        const count = try file.readPositional(io, &.{buffer[used..]}, used);
        if (count == 0) break;
        used += count;
    }
    const after = try file.stat(io);
    const path_after = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (changed(opened, after) or changed(before, path_after)) return error.LocalTextSourceChanged;
    if (cancel.isCancelled()) return error.Cancelled;
    const bytes = buffer[0..used];
    if (images.sniff(bytes)) |_| {
        const image = @import("ai_image_snapshot.zig").capture(allocator, io, path, cancel, .{}) catch |err| switch (err) {
            error.ImageTooLarge => return .{ .file = try attachments.ContentRef.createLocalReference(allocator, path, .{ .reason = .image_limit, .size_bytes = before.size }) },
            else => return err,
        };
        return .{ .image = image };
    } else |_| {}
    // Containers and executables may begin with valid ASCII/UTF-8.
    const binary = std.mem.indexOfScalar(u8, bytes, 0) != null or
        std.mem.startsWith(u8, bytes, "PK\x03\x04") or std.mem.startsWith(u8, bytes, "PK\x05\x06") or
        std.mem.startsWith(u8, bytes, "PK\x07\x08") or std.mem.startsWith(u8, bytes, "%PDF-") or
        std.mem.startsWith(u8, bytes, "\x7fELF") or std.mem.startsWith(u8, bytes, "MZ");
    if (binary) return .{ .file = try attachments.ContentRef.createLocalReference(allocator, path, .{ .size_bytes = before.size }) };
    var valid_utf8 = std.unicode.utf8ValidateSlice(bytes);
    // A bounded probe can split the final UTF-8 codepoint; EOF cannot.
    if (!valid_utf8 and before.size > used) {
        for (1..@min(used + 1, 4)) |trim| {
            if (std.unicode.utf8ValidateSlice(bytes[0 .. used - trim])) {
                valid_utf8 = true;
                break;
            }
        }
    }
    if (!valid_utf8) return .{ .file = try attachments.ContentRef.createLocalReference(allocator, path, .{ .reason = .encoding, .size_bytes = before.size }) };
    const text = @import("ai_local_text_snapshot.zig").capture(allocator, io, path, cancel) catch |err| switch (err) {
        error.LocalTextTooLarge => return .{ .file = try attachments.ContentRef.createLocalReference(allocator, path, .{ .reason = .text_limit, .size_bytes = before.size }) },
        error.BinaryLocalText => return .{ .file = try attachments.ContentRef.createLocalReference(allocator, path, .{ .size_bytes = before.size }) },
        error.InvalidLocalTextEncoding => return .{ .file = try attachments.ContentRef.createLocalReference(allocator, path, .{ .reason = .encoding, .size_bytes = before.size }) },
        else => return err,
    };
    return .{ .file = text };
}
fn changed(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.kind != after.kind or before.inode != after.inode or before.size != after.size or !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime);
}
