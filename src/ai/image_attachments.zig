//! Immutable image snapshots. Only the host captures files/clipboard bytes.
const std = @import("std");
const asset = @import("../config/background_asset.zig");
pub const Owner = @import("tool_scope.zig").Owner;
pub const max_count = 4;
pub const max_bytes = 10_000_000;
pub const Id = u64;
pub const Limits = struct {
    count: usize = max_count,
    bytes: usize = max_bytes,
    dimension: usize = 8192,
    pixels: usize = 16 * 1024 * 1024,
    pub fn effective(self: Limits) Limits {
        return .{ .count = @min(self.count, max_count), .bytes = @min(self.bytes, max_bytes), .dimension = @min(self.dimension, 8192), .pixels = @min(self.pixels, 16 * 1024 * 1024) };
    }
};
pub const Mime = enum {
    png,
    jpeg,
    gif,
    webp,
    pub fn name(self: Mime) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
        };
    }
};
pub fn sniff(bytes: []const u8) !Mime {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return .gif;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    return error.UnsupportedImage;
}
/// Native macOS screenshot clipboard frequently contains TIFF. The host
/// normalizes that explicit clipboard snapshot to PNG before final admission.
pub fn validateClipboard(bytes: []const u8) !void {
    _ = sniff(bytes) catch |err| {
        if (std.mem.startsWith(u8, bytes, "II\x2a\x00") or std.mem.startsWith(u8, bytes, "MM\x00\x2a")) return;
        return err;
    };
}
pub const Content = struct { path: []const u8, bytes: []const u8, mime: Mime, width: u32, height: u32, pixels: []const u8, captured_at_ms: i64, sha256: [32]u8 };
const Snapshot = struct { allocator: std.mem.Allocator, references: std.atomic.Value(usize) = .init(1), value: Content };
pub const ContentRef = struct {
    snapshot: ?*Snapshot = null,
    /// Full raster decoding is mandatory; extension or IHDR alone never suffice.
    pub fn create(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, captured_at_ms: i64, requested: Limits) !ContentRef {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidAttachmentPath;
        const limits = requested.effective();
        if (bytes.len > limits.bytes) return error.ImageTooLarge;
        const mime = try sniff(bytes);
        try validateFrames(bytes);
        var image = try asset.decode(allocator, bytes, .{ .source_bytes = limits.bytes, .dimension = limits.dimension, .pixels = limits.pixels });
        errdefer image.deinit(allocator);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_bytes = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned_bytes);
        const snapshot = try allocator.create(Snapshot);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        snapshot.* = .{ .allocator = allocator, .value = .{ .path = owned_path, .bytes = owned_bytes, .mime = mime, .width = image.width, .height = image.height, .pixels = image.pixels, .captured_at_ms = captured_at_ms, .sha256 = digest } };
        return .{ .snapshot = snapshot };
    }
    pub fn content(self: ContentRef) ?Content {
        return if (self.snapshot) |snapshot| snapshot.value else null;
    }
    pub fn retain(self: ContentRef) ContentRef {
        if (self.snapshot) |snapshot| {
            const previous = snapshot.references.fetchAdd(1, .monotonic);
            std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        }
        return self;
    }
    pub fn release(self: *ContentRef) void {
        const snapshot = self.snapshot orelse return;
        self.snapshot = null;
        if (snapshot.references.fetchSub(1, .acq_rel) != 1) return;
        const allocator = snapshot.allocator;
        allocator.free(snapshot.value.path);
        allocator.free(snapshot.value.bytes);
        allocator.free(snapshot.value.pixels);
        allocator.destroy(snapshot);
    }
};
pub const Ticket = struct {
    owner: Owner,
    draft_epoch: u64,
    id: Id,
    revision: u64 = 1,
    pub fn eql(self: Ticket, other: Ticket) bool {
        return self.owner.eql(other.owner) and self.draft_epoch == other.draft_epoch and self.id == other.id and self.revision == other.revision;
    }
};
pub const State = enum { processing, ready, failed };
pub const Item = struct { ticket: Ticket, path: []u8, state: State = .processing, problem: ?anyerror = null, reference: ContentRef = .{}, limits: Limits, source_bytes: ?[]u8 = null };
pub const SentItem = struct { id: Id, reference: ContentRef };
pub const Bundle = struct {
    allocator: std.mem.Allocator,
    owner: Owner,
    draft_epoch: u64,
    items: []SentItem,
    pub fn deinit(self: *Bundle) void {
        for (self.items) |*item| item.reference.release();
        self.allocator.free(self.items);
        self.items = &.{};
    }
    pub fn retain(self: *const Bundle) !Bundle {
        const items = try self.allocator.alloc(SentItem, self.items.len);
        for (self.items, items) |item, *copy| copy.* = .{ .id = item.id, .reference = item.reference.retain() };
        return .{ .allocator = self.allocator, .owner = self.owner, .draft_epoch = self.draft_epoch, .items = items };
    }
};
pub const Draft = struct {
    allocator: std.mem.Allocator,
    owner: Owner,
    epoch: u64 = 1,
    next_id: Id = 1,
    items: std.ArrayList(Item) = .empty,
    pub fn init(allocator: std.mem.Allocator, owner: Owner) !Draft {
        if (switch (owner) {
            .session => |id| id == 0,
            .group => |id| id == 0,
        }) return error.InvalidAttachmentOwner;
        return .{ .allocator = allocator, .owner = owner };
    }
    pub fn deinit(self: *Draft) void {
        for (self.items.items) |*item| {
            item.reference.release();
            self.allocator.free(item.path);
            if (item.source_bytes) |bytes| self.allocator.free(bytes);
        }
        self.items.deinit(self.allocator);
    }
    /// Call after source preflight; picker cancellation never creates a slot.
    pub fn begin(self: *Draft, path: []const u8, requested: Limits) !Ticket {
        const limits = requested.effective();
        if (self.items.items.len >= limits.count) return error.TooManyImages;
        if (self.next_id == std.math.maxInt(Id)) return error.AttachmentIdExhausted;
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidAttachmentPath;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        const ticket: Ticket = .{ .owner = self.owner, .draft_epoch = self.epoch, .id = self.next_id };
        try self.items.append(self.allocator, .{ .ticket = ticket, .path = owned, .limits = limits });
        self.next_id += 1;
        return ticket;
    }
    /// A pasted image's retry reuses its original immutable bytes, never the
    /// later clipboard. Pending/error/ready all retain the same slot identity.
    pub fn beginBytes(self: *Draft, label: []const u8, bytes: []const u8, limits: Limits) !Ticket {
        if (bytes.len > limits.effective().bytes) return error.ImageTooLarge;
        try validateClipboard(bytes);
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        const ticket = try self.begin(label, limits);
        self.find(ticket).?.source_bytes = owned;
        return ticket;
    }
    pub fn find(self: *Draft, ticket: Ticket) ?*Item {
        for (self.items.items) |*item| if (item.ticket.eql(ticket) and self.owner.eql(ticket.owner) and self.epoch == ticket.draft_epoch) return item;
        return null;
    }
    /// Always consumes a worker reference, including cancelled/stale/OOM paths.
    pub fn complete(self: *Draft, ticket: Ticket, incoming: *ContentRef) !void {
        defer incoming.release();
        const item = self.find(ticket) orelse return error.StaleAttachment;
        if (item.state != .processing) return error.StaleAttachment;
        const value = incoming.content() orelse return error.EmptyAttachmentResult;
        if (!std.mem.eql(u8, value.path, item.path)) return error.StaleAttachment;
        const limits = item.limits.effective();
        if (value.bytes.len > limits.bytes or value.width > limits.dimension or value.height > limits.dimension or @as(usize, value.width) * value.height > limits.pixels) return error.ImageTooLarge;
        item.reference = incoming.retain();
        item.state = .ready;
        item.problem = null;
    }
    pub fn fail(self: *Draft, ticket: Ticket, problem: anyerror) bool {
        const item = self.find(ticket) orelse return false;
        if (item.state != .processing) return false;
        item.state = .failed;
        item.problem = problem;
        return true;
    }
    pub fn retry(self: *Draft, ticket: Ticket) !Ticket {
        const item = self.find(ticket) orelse return error.StaleAttachment;
        if (item.state != .failed) return error.ImageNotRetryable;
        if (item.ticket.revision == std.math.maxInt(u64)) return error.AttachmentEpochExhausted;
        item.ticket.revision += 1;
        item.state = .processing;
        item.problem = null;
        return item.ticket;
    }
    pub fn remove(self: *Draft, id: Id) bool {
        for (self.items.items, 0..) |item, index| if (item.ticket.id == id) {
            var removed = self.items.orderedRemove(index);
            removed.reference.release();
            self.allocator.free(removed.path);
            if (removed.source_bytes) |bytes| self.allocator.free(bytes);
            return true;
        };
        return false;
    }
    pub fn clear(self: *Draft) !void {
        if (self.epoch == std.math.maxInt(u64)) return error.AttachmentEpochExhausted;
        self.epoch += 1;
        while (self.items.items.len != 0) _ = self.remove(self.items.items[0].ticket.id);
    }
    pub fn restore(self: *Draft, bundle: *const Bundle) !void {
        if (!self.owner.eql(bundle.owner)) return error.StaleAttachmentBundle;
        if (self.epoch == std.math.maxInt(u64)) return error.AttachmentEpochExhausted;
        var next = try Draft.init(self.allocator, self.owner);
        errdefer next.deinit();
        next.epoch = self.epoch + 1;
        next.next_id = self.next_id;
        for (bundle.items) |item| {
            const content = item.reference.content() orelse return error.EmptyAttachmentResult;
            const ticket = try next.begin(content.path, .{});
            var ref = item.reference.retain();
            defer ref.release();
            try next.complete(ticket, &ref);
        }
        self.deinit();
        self.* = next;
    }
    pub fn freeze(self: *const Draft) !Bundle {
        for (self.items.items) |item| switch (item.state) {
            .processing => return error.AttachmentsProcessing,
            .failed => return error.ImageAttachmentFailed,
            .ready => {},
        };
        const items = try self.allocator.alloc(SentItem, self.items.items.len);
        for (self.items.items, items) |item, *copy| copy.* = .{ .id = item.ticket.id, .reference = item.reference.retain() };
        return .{ .allocator = self.allocator, .owner = self.owner, .draft_epoch = self.epoch, .items = items };
    }
    pub fn consumeSent(self: *Draft, bundle: *const Bundle) !usize {
        if (!self.owner.eql(bundle.owner) or self.epoch != bundle.draft_epoch) return error.StaleAttachmentBundle;
        var count: usize = 0;
        for (bundle.items) |item| {
            if (self.remove(item.id)) count += 1;
        }
        return count;
    }
};

const NativeRef = *const anyopaque;
extern "c" fn CFDataCreate(?NativeRef, [*]const u8, isize) ?NativeRef;
extern "c" fn CFRelease(NativeRef) void;
extern "c" fn CGImageSourceCreateWithData(NativeRef, ?NativeRef) ?NativeRef;
extern "c" fn CGImageSourceGetCount(NativeRef) usize;
fn validateFrames(bytes: []const u8) !void {
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
    defer CFRelease(data);
    const source = CGImageSourceCreateWithData(data, null) orelse return error.InvalidImage;
    defer CFRelease(source);
    if (CGImageSourceGetCount(source) > 1) return error.AnimatedImageUnsupported;
}
