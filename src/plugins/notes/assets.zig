//! Images are immutable, content-addressed files scoped to one knowledge base.
const std = @import("std");
const images = @import("../../ai/image_attachments.zig");
const png = @import("../../host/ai_image_png.zig");
const model = @import("model.zig");
const Store = @import("store.zig").Store;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const CancelToken = @import("../../ai/provider.zig").CancelToken;
pub const Limits = images.Limits;

const directory_name = "assets";
const prefix = directory_name ++ "/";
const hex_length = 2 * Sha256.digest_length;
const filename_length = hex_length + ".png".len;
const path_length = prefix.len + filename_length;

pub const Imported = struct {
    path: [path_length]u8,
    width: u32,
    height: u32,

    pub fn relativePath(self: *const Imported) []const u8 {
        return &self.path;
    }
};

pub const ImageLine = struct {
    alt: []const u8,
    relative_path: []const u8,
};

/// A top-level image block. Borrowed slices point into the source line.
/// The document parser must still exclude code and other opaque blocks.
pub fn parseImageLine(raw: []const u8) ?ImageLine {
    const line = std.mem.trimStart(u8, raw, " ");
    if (raw.len - line.len > 3 or !std.mem.startsWith(u8, line, "![")) return null;
    var depth: usize = 1;
    var index: usize = 2;
    while (index < line.len) : (index += 1) {
        switch (line[index]) {
            '\\' => {
                if (index + 1 < line.len and std.ascii.isPunctuation(line[index + 1])) index += 1;
            },
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
    }
    if (depth != 0 or !std.mem.startsWith(u8, line[index + 1 ..], "(")) return null;
    const destination = std.mem.trimEnd(u8, line[index + 2 ..], " \t\r");
    if (!std.mem.endsWith(u8, destination, ")")) return null;
    const path = destination[0 .. destination.len - 1];
    _ = parsePath(path) orelse return null;
    return .{ .alt = line[2..index], .relative_path = path };
}

/// Only standalone image blocks belong to the note asset grammar. Skip code
/// fences and HTML comments. The renderer uses the same line parser.
pub const ReferenceIterator = struct {
    lines: std.mem.SplitIterator(u8, .any),
    fence: ?Fence = null,
    in_comment: bool = false,

    pub fn init(markdown: []const u8) ReferenceIterator {
        return .{ .lines = std.mem.splitAny(u8, markdown, "\r\n") };
    }

    pub fn next(self: *ReferenceIterator) ?ImageLine {
        while (self.lines.next()) |raw| {
            if (self.fence) |open| {
                if (open.closes(raw)) self.fence = null;
                continue;
            }
            if (self.in_comment) {
                if (std.mem.indexOf(u8, raw, "-->") != null) self.in_comment = false;
                continue;
            }
            if (Fence.opening(raw)) |open| {
                self.fence = open;
                continue;
            }
            if (commentStart(raw)) |continues| {
                self.in_comment = continues;
                continue;
            }
            if (parseImageLine(raw)) |image| return image;
        }
        return null;
    }
};

/// Returns whether an HTML comment starting on this line continues onto later
/// lines, or null if the line does not start a top-level comment.
pub fn commentStart(raw: []const u8) ?bool {
    const line = std.mem.trimStart(u8, raw, " ");
    if (raw.len - line.len > 3 or !std.mem.startsWith(u8, line, "<!--")) return null;
    return std.mem.indexOf(u8, line[4..], "-->") == null;
}

pub const Fence = struct {
    marker: u8,
    count: usize,

    fn run(line: []const u8, marker: u8) usize {
        var index: usize = 0;
        while (index < line.len and line[index] == marker) : (index += 1) {}
        return index;
    }

    pub fn opening(raw: []const u8) ?Fence {
        const line = std.mem.trimStart(u8, raw, " ");
        if (raw.len - line.len > 3 or line.len < 3 or (line[0] != '`' and line[0] != '~')) return null;
        const count = run(line, line[0]);
        if (count < 3 or (line[0] == '`' and std.mem.indexOfScalar(u8, line[count..], '`') != null)) return null;
        return .{ .marker = line[0], .count = count };
    }

    pub fn closes(self: Fence, raw: []const u8) bool {
        const line = std.mem.trimStart(u8, raw, " ");
        if (raw.len - line.len > 3) return false;
        const count = run(line, self.marker);
        return count >= self.count and std.mem.trim(u8, line[count..], " \t\r").len == 0;
    }
};

/// The caller frees the returned list. Every path borrows the supplied text.
pub fn references(a: Allocator, markdown: []const u8) ![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(a);
    var iterator = ReferenceIterator.init(markdown);
    while (iterator.next()) |item| {
        const entry = try seen.getOrPut(a, item.relative_path);
        if (!entry.found_existing) try paths.append(a, item.relative_path);
    }
    return paths.toOwnedSlice(a);
}

pub fn isReferenced(markdown: []const u8, relative_path: []const u8) bool {
    var iterator = ReferenceIterator.init(markdown);
    while (iterator.next()) |item| {
        if (std.mem.eql(u8, item.relative_path, relative_path)) return true;
    }
    return false;
}

/// Insertion starts a fresh paragraph, so only a fence or HTML comment
/// carried over from the preceding Markdown can hide the image line.
pub fn allowsImageParagraphAfter(markdown: []const u8) bool {
    var iterator = ReferenceIterator.init(markdown);
    while (iterator.next() != null) {}
    return iterator.fence == null and !iterator.in_comment;
}

const AssetPath = struct {
    filename: []const u8,
    digest: [Sha256.digest_length]u8,
    mime: images.Mime,
};

fn parsePath(relative_path: []const u8) ?AssetPath {
    if (relative_path.len != path_length or !std.mem.startsWith(u8, relative_path, prefix)) return null;
    const filename = relative_path[prefix.len..];
    const mime: images.Mime = if (std.mem.eql(u8, filename[hex_length..], ".png"))
        .png
    else if (std.mem.eql(u8, filename[hex_length..], ".jpg"))
        .jpeg
    else
        return null;
    const encoded = filename[0..hex_length];
    for (encoded) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return null;
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, encoded) catch unreachable;
    return .{ .filename = filename, .digest = digest, .mime = mime };
}

/// Use only for files explicitly selected by the local user. The Markdown
/// renderer and AI tools use readReferenced, which never open caller paths.
pub fn importFile(a: Allocator, store: *Store, library_id: model.LibraryId, absolute_path: []const u8, cancel: *const CancelToken, requested: Limits) !Imported {
    if (!std.fs.path.isAbsolute(absolute_path) or std.mem.indexOfScalar(u8, absolute_path, 0) != null) return error.InvalidAttachmentPath;
    const bytes = try readBytes(a, store.io, .cwd(), absolute_path, requested.effective().bytes, cancel, false);
    defer a.free(bytes);
    return importBytes(a, store, library_id, bytes, cancel, requested);
}

/// Call on a worker with owned bytes. A successful return only materializes the
/// asset. The caller must still apply the import receipt to its original draft.
pub fn importBytes(a: Allocator, store: *Store, library_id: model.LibraryId, bytes: []const u8, cancel: *const CancelToken, requested: Limits) !Imported {
    try checkCancelled(cancel);
    const limits = requested.effective();
    if (bytes.len > limits.bytes) return error.ImageTooLarge;
    var image = try captureStatic(a, bytes, limits);
    defer image.release();
    const data = image.content().?;
    const extension = switch (data.mime) {
        .png => ".png",
        .jpeg => ".jpg",
        else => unreachable,
    };
    const result: Imported = .{
        .path = prefix.* ++ std.fmt.bytesToHex(data.sha256, .lower) ++ extension.*,
        .width = data.width,
        .height = data.height,
    };

    try checkCancelled(cancel);
    var record = try store.loadLibrary(a, library_id, .active);
    record.deinit();
    const library = try store.openLibrary(library_id);
    defer library.close(store.io);
    library.createDir(store.io, directory_name, @fromBackingInt(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const assets = try library.openDir(store.io, directory_name, .{ .follow_symlinks = false });
    defer assets.close(store.io);
    const path = parsePath(result.relativePath()).?;
    try writeAsset(a, store.io, assets, path, data.bytes, cancel, limits);
    try syncDirectory(assets);
    try syncDirectory(library);
    try checkCancelled(cancel);
    return result;
}

/// The caller supplies the authorized note revision (or an active local
/// draft). AI callers must revalidate their query fence before publishing.
pub fn readReferenced(a: Allocator, store: *Store, library_id: model.LibraryId, markdown: []const u8, relative_path: []const u8, cancel: *const CancelToken, requested: Limits) !images.ContentRef {
    try checkCancelled(cancel);
    const path = parsePath(relative_path) orelse return error.InvalidAssetReference;
    if (!isReferenced(markdown, relative_path)) return error.UnreferencedAsset;
    var record = try store.loadLibrary(a, library_id, .active);
    record.deinit();
    const library = try store.openLibrary(library_id);
    defer library.close(store.io);
    const assets = try library.openDir(store.io, directory_name, .{ .follow_symlinks = false });
    defer assets.close(store.io);

    const limits = requested.effective();
    const bytes = try readAsset(a, store.io, assets, path, cancel, limits);
    defer a.free(bytes);
    const captured_at = std.Io.Clock.real.now(store.io).toMilliseconds();
    var image = try images.ContentRef.create(a, relative_path, bytes, captured_at, limits);
    errdefer image.release();
    try checkCancelled(cancel);
    return image;
}

fn captureStatic(a: Allocator, bytes: []const u8, limits: Limits) !images.ContentRef {
    images.validateClipboard(bytes) catch |err| {
        if (!isNativeRasterContainer(bytes)) return err;
    };
    if (images.sniff(bytes)) |mime| {
        if (mime == .png or mime == .jpeg) {
            if (images.ContentRef.create(a, "note-image", bytes, 0, limits)) |image| {
                return image;
            } else |err| {
                if (err != error.AnimatedImageUnsupported) return err;
            }
        }
    } else |_| {}
    const normalized = try png.convert(a, bytes, limits);
    defer a.free(normalized);
    return images.ContentRef.create(a, "note-image", normalized, 0, limits);
}

fn isNativeRasterContainer(bytes: []const u8) bool {
    if (bytes.len >= 14 and std.mem.startsWith(u8, bytes, "BM")) return true;
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[4..8], "ftyp")) return false;
    const size = std.mem.readInt(u32, bytes[0..4], .big);
    if (size < 16 or size > bytes.len or size % 4 != 0) return false;
    if (isHeifBrand(bytes[8..12])) return true;
    var offset: usize = 16;
    while (offset < size) : (offset += 4) {
        if (isHeifBrand(bytes[offset..][0..4])) return true;
    }
    return false;
}

fn isHeifBrand(brand: *const [4]u8) bool {
    const value = std.mem.readInt(u32, brand, .big);
    return switch (value) {
        std.mem.readInt(u32, "heic", .big),
        std.mem.readInt(u32, "heix", .big),
        std.mem.readInt(u32, "hevc", .big),
        std.mem.readInt(u32, "hevx", .big),
        std.mem.readInt(u32, "heim", .big),
        std.mem.readInt(u32, "heis", .big),
        std.mem.readInt(u32, "hevm", .big),
        std.mem.readInt(u32, "hevs", .big),
        std.mem.readInt(u32, "mif1", .big),
        std.mem.readInt(u32, "msf1", .big),
        => true,
        else => false,
    };
}

fn writeAsset(a: Allocator, io: std.Io, dir: Dir, path: AssetPath, bytes: []const u8, cancel: *const CancelToken, limits: Limits) !void {
    // A competing import can only publish identical bytes at this name.
    // Open and verify an existing file instead of overwriting it.
    if (dir.statFile(io, path.filename, .{ .follow_symlinks = false })) |_| {
        const existing = try readAsset(a, io, dir, path, cancel, limits);
        a.free(existing);
        return;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
    var atomic = try dir.createFileAtomic(io, path.filename, .{ .permissions = @fromBackingInt(0o600) });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, bytes, 0);
    try atomic.file.sync(io);
    try checkCancelled(cancel);
    atomic.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try readAsset(a, io, dir, path, cancel, limits);
            a.free(existing);
        },
        else => return err,
    };
}

fn readAsset(a: Allocator, io: std.Io, dir: Dir, path: AssetPath, cancel: *const CancelToken, limits: Limits) ![]u8 {
    const bytes = try readBytes(a, io, dir, path.filename, limits.bytes, cancel, true);
    errdefer a.free(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &path.digest) or (images.sniff(bytes) catch return error.InvalidAsset) != path.mime) return error.InvalidAsset;
    return bytes;
}

fn readBytes(a: Allocator, io: std.Io, dir: Dir, path: []const u8, limit: usize, cancel: *const CancelToken, private: bool) ![]u8 {
    try checkCancelled(cancel);
    const before = try dir.statFile(io, path, .{ .follow_symlinks = false });
    if (before.kind != .file or (private and before.nlink != 1)) return error.NotRegularImage;
    if (before.size > limit) return error.ImageTooLarge;
    const file = try dir.openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    if (fileChanged(before, opened)) return error.ImageSourceChanged;
    const bytes = try a.alloc(u8, @intCast(opened.size));
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        try checkCancelled(cancel);
        const length = @min(bytes.len - offset, 64 * 1024);
        const count = try file.readPositional(io, &.{bytes[offset..][0..length]}, offset);
        if (count == 0) return error.ImageSourceChanged;
        offset += count;
    }
    const after = try file.stat(io);
    const at_path = try dir.statFile(io, path, .{ .follow_symlinks = false });
    if (fileChanged(opened, after) or fileChanged(after, at_path)) return error.ImageSourceChanged;
    try checkCancelled(cancel);
    return bytes;
}

fn fileChanged(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.kind != after.kind or before.inode != after.inode or before.nlink != after.nlink or before.size != after.size or
        !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime);
}

fn checkCancelled(cancel: *const CancelToken) !void {
    if (cancel.isCancelled()) return error.Cancelled;
}

fn syncDirectory(dir: Dir) !void {
    while (true) switch (std.posix.errno(std.c.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.AssetDirectorySyncFailed,
    };
}
