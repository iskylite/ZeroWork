/// PieceTree: SumTree-based high-performance text storage engine.
///
/// SumTree(TreePiece, PieceSummary) implementation:
/// - insert/delete: O(log P) (P = piece count)
/// - line index maintenance: embedded Summary, O(1) line count, O(log P) line<->offset
/// - no rebuildLineIndex() needed
///
/// Common API matches PieceTable.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const sum_tree = @import("sum_tree.zig");
const SumTree = sum_tree.SumTree;
const piece_stats = @import("piece_stats.zig");

/// piece source.
pub const Source = enum { original, add };

/// PieceSummary: per-subtree aggregate digest.
///
/// align Zed TextSummary: embed first/last/longest_row_chars, O(log N) maintain
/// longest doc line, no full-file scan.
pub const PieceSummary = struct {
    bytes: usize = 0,
    lines: usize = 0, // newline count.
    /// first line chars (adjacent-piece concat calc cross-piece row width).
    first_line_chars: u32 = 0,
    /// last line chars (same; last_line + next.first_line may form longest).
    last_line_chars: u32 = 0,
    /// longest row chars in subtree.
    longest_row_chars: u32 = 0,

    pub const ZERO: PieceSummary = .{};

    /// merge two summaries (align Zed TextSummary::AddAssign). key: concat
    /// self.last_line + other.first_line may form new longest.
    pub fn add(self: PieceSummary, other: PieceSummary) PieceSummary {
        // concat-point line width = self last + other first.
        const joined_chars: u32 = self.last_line_chars +| other.first_line_chars;
        var longest = self.longest_row_chars;
        if (joined_chars > longest) longest = joined_chars;
        if (other.longest_row_chars > longest) longest = other.longest_row_chars;

        return .{
            .bytes = self.bytes + other.bytes,
            .lines = self.lines + other.lines,
            // first_line_chars: self no newline, first extends to other.first_line.
            .first_line_chars = if (self.lines == 0)
                self.first_line_chars +| other.first_line_chars
            else
                self.first_line_chars,
            // last_line_chars: other no newline, last extends from self.last_line.
            .last_line_chars = if (other.lines == 0)
                self.last_line_chars +| other.last_line_chars
            else
                other.last_line_chars,
            .longest_row_chars = longest,
        };
    }
};

/// TreePiece: SumTree leaf item.
pub const TreePiece = struct {
    source: Source,
    start: usize,
    length: usize,
    newline_count: usize,
    first_line_chars: u32 = 0,
    last_line_chars: u32 = 0,
    longest_row_chars: u32 = 0,

    pub fn summary(self: TreePiece) PieceSummary {
        return .{
            .bytes = self.length,
            .lines = self.newline_count,
            .first_line_chars = self.first_line_chars,
            .last_line_chars = self.last_line_chars,
            .longest_row_chars = self.longest_row_chars,
        };
    }

    /// construct TreePiece from text content (one pass compute all stats).
    pub fn fromText(source: Source, start: usize, text: []const u8) TreePiece {
        const stats = PieceTree.scanTextStats(text);
        return .{
            .source = source,
            .start = start,
            .length = text.len,
            .newline_count = stats.newline_count,
            .first_line_chars = stats.first_line_chars,
            .last_line_chars = stats.last_line_chars,
            .longest_row_chars = stats.longest_row_chars,
        };
    }
};

/// dimension: seek by byte offset.
pub const ByteDim = struct {
    pub fn fromSummary(s: PieceSummary) usize {
        return s.bytes;
    }
};

/// dimension: seek by line number.
pub const LineDim = struct {
    pub fn fromSummary(s: PieceSummary) usize {
        return s.lines;
    }
};

const Tree = SumTree(TreePiece, PieceSummary);
const ADD_BUFFER_PAGE_SIZE: usize = 64 * 1024;

const AddBufferPage = struct {
    allocator: Allocator,
    start: usize,
    data: []const u8,
    ref_count: Atomic(usize),

    fn create(allocator: Allocator, start: usize, data: []const u8) !*AddBufferPage {
        const copy = try allocator.dupe(u8, data);
        errdefer allocator.free(copy);
        const self = try allocator.create(AddBufferPage);
        self.* = .{
            .allocator = allocator,
            .start = start,
            .data = copy,
            .ref_count = Atomic(usize).init(1),
        };
        return self;
    }

    fn retain(self: *AddBufferPage) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn release(self: *AddBufferPage) void {
        const prev = self.ref_count.fetchSub(1, .release);
        if (prev == 1) {
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    }
};

fn hasValidPieceBounds(piece: TreePiece, source_buf: []const u8) bool {
    if (piece.start > source_buf.len) return false;
    return piece.length <= source_buf.len - piece.start;
}

/// Zero-copy chunk iterator; each piece returns a direct `[]const u8` slice.
///
/// usage:
///   var it = piece_tree.chunksInRange(start, len);
///   while (it.next()) |chunk| { ... }  // chunk is a zero-copy ref.
pub fn ChunkIterator(comptime Container: type) type {
    return struct {
        const Self = @This();
        container: *const Container,
        index: usize, // current piece SumTree item index.
        offset_in_piece: usize, // offset within current piece.
        remaining: usize, // bytes left to iterate.

        /// return current chunk zero-copy slice, advance to next piece.
        pub fn next(self: *Self) ?[]const u8 {
            if (self.remaining == 0) return null;
            const piece = self.container.tree.get(self.index) orelse return null;
            const piece_buf = self.container.getPieceBuffer(piece) orelse return null;
            const available = piece_buf.len - self.offset_in_piece;
            if (available == 0) return null;
            const chunk_len = @min(available, self.remaining);
            const slice_start = self.offset_in_piece;
            const result = piece_buf[slice_start .. slice_start + chunk_len];
            self.remaining -= chunk_len;
            self.offset_in_piece = 0;
            self.index += 1;
            return result;
        }

        /// relocate to new byte offset (tree-sitter non-sequential callback).
        pub fn seekTo(self: *Self, byte_offset: usize, total_len: usize) void {
            const clamped = @min(byte_offset, total_len);
            const seek_result = self.container.tree.seek(ByteDim, clamped);
            self.index = seek_result.index;
            self.offset_in_piece = seek_result.offset_in_item;
            self.remaining = total_len - clamped;
        }
    };
}

/// PieceTreeSnapshot: bg-thread-safe read-only doc view.
///
/// share SumTree nodes (refcount) and append pages via COW snapshot. bg
/// tree-sitter parse etc.
pub const PieceTreeSnapshot = struct {
    tree: Tree,
    original_buffer: []const u8, // read-only shared (immutable).
    original_page: ?*AddBufferPage = null,
    add_pages: []const *AddBufferPage,
    allocator: Allocator,

    /// zero-copy: return direct slice in piece containing offset (no copy). from offset
    /// to piece end continuous memory.
    pub const ChunkResult = struct {
        ptr: [*]const u8,
        len: usize,
    };

    pub fn deinit(self: *PieceTreeSnapshot) void {
        if (self.original_page) |page| page.release();
        for (self.add_pages) |page| page.release();
        if (self.add_pages.len > 0) self.allocator.free(@constCast(self.add_pages));
        self.tree.deinit();
    }

    pub fn totalLength(self: *const PieceTreeSnapshot) usize {
        return self.tree.summary().bytes;
    }

    pub fn lineCount(self: *const PieceTreeSnapshot) usize {
        return self.tree.summary().lines + 1;
    }

    pub fn getText(self: *const PieceTreeSnapshot, start: usize, length: usize, buffer: []u8) ![]const u8 {
        const total = self.totalLength();
        if (start > total or length > total - start) return error.InvalidRange;
        if (buffer.len < length) return error.BufferTooSmall;
        if (length == 0) return buffer[0..0];

        var pieces = self.tree.iterator();
        var offset_in_piece = pieces.seekTo(ByteDim, start) orelse return error.CorruptPieceTree;
        var copied: usize = 0;
        var remaining = length;

        while (remaining > 0) {
            const piece = pieces.next() orelse return error.CorruptPieceTree;
            const piece_buf = self.getPieceBuffer(piece) orelse return error.CorruptPieceTree;
            if (offset_in_piece > piece_buf.len) return error.CorruptPieceTree;
            const available = piece_buf.len - offset_in_piece;
            // Public mutators never retain empty pieces; zero progress is corruption.
            if (available == 0) return error.CorruptPieceTree;
            const to_copy = @min(available, remaining);
            @memcpy(
                buffer[copied .. copied + to_copy],
                piece_buf[offset_in_piece .. offset_in_piece + to_copy],
            );
            copied += to_copy;
            remaining -= to_copy;
            offset_in_piece = 0;
        }
        if (remaining != 0) return error.CorruptPieceTree;
        return buffer[0..copied];
    }

    pub fn getChunkAt(self: *const PieceTreeSnapshot, offset: usize) ?ChunkResult {
        const total = self.totalLength();
        if (offset >= total) return null;

        const seek_result = self.tree.seek(ByteDim, offset);
        const piece = seek_result.item orelse return null;
        const piece_buf = self.getPieceBuffer(piece) orelse return null;
        const offset_in_piece = seek_result.offset_in_item;
        if (offset_in_piece >= piece_buf.len) return null;
        return .{
            .ptr = piece_buf[offset_in_piece..].ptr,
            .len = piece_buf.len - offset_in_piece,
        };
    }

    pub fn offsetToLine(self: *const PieceTreeSnapshot, offset: usize) usize {
        const root = self.tree.root orelse return 0;
        const total = self.totalLength();
        const clamped = @min(offset, total);
        return self.offsetToLineInNode(root, clamped);
    }

    fn offsetToLineInNode(self: *const PieceTreeSnapshot, node: *const Tree.Node, remaining_bytes: usize) usize {
        switch (node.data) {
            .internal => |*internal| {
                var remaining = remaining_bytes;
                var lines: usize = 0;
                for (0..internal.len) |i| {
                    const child_bytes = internal.summaries[i].bytes;
                    if (child_bytes > remaining) {
                        return lines + self.offsetToLineInNode(internal.children[i], remaining);
                    }
                    lines += internal.summaries[i].lines;
                    remaining -= child_bytes;
                }
                return lines;
            },
            .leaf => |*leaf| {
                var remaining = remaining_bytes;
                var lines: usize = 0;
                for (leaf.items[0..leaf.len]) |piece| {
                    if (piece.length > remaining) {
                        const buf = self.getPieceBuffer(piece) orelse return lines;
                        for (buf[0..remaining]) |byte| {
                            if (byte == '\n') lines += 1;
                        }
                        return lines;
                    }
                    lines += piece.newline_count;
                    remaining -= piece.length;
                }
                return lines;
            },
        }
    }

    pub fn lineToOffset(self: *const PieceTreeSnapshot, target_line: usize) usize {
        if (target_line == 0) return 0;
        const root = self.tree.root orelse return 0;
        return self.lineToOffsetInNode(root, target_line);
    }

    fn lineToOffsetInNode(self: *const PieceTreeSnapshot, node: *const Tree.Node, remaining_lines: usize) usize {
        switch (node.data) {
            .internal => |*internal| {
                var remaining = remaining_lines;
                var byte_offset: usize = 0;
                for (0..internal.len) |i| {
                    const child_lines = internal.summaries[i].lines;
                    if (child_lines >= remaining) {
                        return byte_offset + self.lineToOffsetInNode(internal.children[i], remaining);
                    }
                    remaining -= child_lines;
                    byte_offset += internal.summaries[i].bytes;
                }
                return byte_offset;
            },
            .leaf => |*leaf| {
                var remaining = remaining_lines;
                var byte_offset: usize = 0;
                for (leaf.items[0..leaf.len]) |piece| {
                    if (piece.newline_count >= remaining) {
                        const buf = self.getPieceBuffer(piece) orelse return byte_offset;
                        var count: usize = 0;
                        for (buf, 0..) |byte, j| {
                            if (byte == '\n') {
                                count += 1;
                                if (count == remaining) return byte_offset + j + 1;
                            }
                        }
                        return byte_offset + piece.length;
                    }
                    remaining -= piece.newline_count;
                    byte_offset += piece.length;
                }
                return byte_offset;
            },
        }
    }

    /// zero-copy chunk iterator: per-piece direct ref, no memcpy.
    pub fn chunksInRange(self: *const PieceTreeSnapshot, start: usize, len: usize) ChunkIterator(PieceTreeSnapshot) {
        const total = self.totalLength();
        const clamped_start = @min(start, total);
        const clamped_len = @min(len, total - clamped_start);
        if (clamped_len == 0) return .{ .container = self, .index = 0, .offset_in_piece = 0, .remaining = 0 };
        const seek_result = self.tree.seek(ByteDim, clamped_start);
        return .{
            .container = self,
            .index = seek_result.index,
            .offset_in_piece = seek_result.offset_in_item,
            .remaining = clamped_len,
        };
    }

    fn getPieceBuffer(self: *const PieceTreeSnapshot, piece: TreePiece) ?[]const u8 {
        return switch (piece.source) {
            .original => blk: {
                if (!hasValidPieceBounds(piece, self.original_buffer)) return null;
                break :blk self.original_buffer[piece.start .. piece.start + piece.length];
            },
            .add => self.getAddPageSlice(piece.start, piece.length),
        };
    }

    fn getAddPageSlice(self: *const PieceTreeSnapshot, start: usize, len: usize) ?[]const u8 {
        for (self.add_pages) |page| {
            if (start < page.start or start >= page.start + page.data.len) continue;
            const local_start = start - page.start;
            if (len > page.data.len - local_start) return null;
            return page.data[local_start .. local_start + len];
        }
        return null;
    }
};

/// PieceTree: B-tree text storage.
pub const PieceTree = struct {
    /// Bound the local scan performed by lineToOffset/offsetToLine inside a
    /// single piece. Large initial files used to be represented by one piece,
    /// making every line lookup near EOF scan the whole file despite the
    /// SumTree carrying line summaries.
    const initial_piece_bytes: usize = 2 * 1024;

    tree: Tree,
    original_buffer: []const u8,
    original_page: ?*AddBufferPage,
    add_buffer: std.ArrayList(u8),
    add_pages: std.ArrayList(*AddBufferPage),
    add_pages_total_len: usize,
    allocator: Allocator,
    /// protect main-thread mutation vs bg `snapshot()` mutual exclude. lock only
    /// 'struct field mutate' + 'snapshot read'; scan/traverse snapshot itself lock-free.
    /// granule: snapshot O(log P) tree refcount + O(P_pages) add_page refcount, tens
    /// microsec lock hold, no main-thread edit delay.
    io: std.Io,
    snapshot_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: std.Io) PieceTree {
        return .{
            .io = io,
            .tree = Tree.init(allocator),
            .original_buffer = &[_]u8{},
            .original_page = null,
            .add_buffer = @as(std.ArrayList(u8), .empty),
            .add_pages = @as(std.ArrayList(*AddBufferPage), .empty),
            .add_pages_total_len = 0,
            .allocator = allocator,
        };
    }

    pub fn initFromBuffer(allocator: Allocator, io: std.Io, content: []const u8) !PieceTree {
        var self = init(allocator, io);
        errdefer self.deinit();
        if (content.len > 0) {
            // original buffer held by shared pages, snapshot cross-thread lifespan extend.
            const page = try AddBufferPage.create(allocator, 0, content);
            self.original_page = page;
            self.original_buffer = page.data;
            var tree_tx = self.tree.beginTransaction();
            defer tree_tx.deinit();
            var start: usize = 0;
            while (start < self.original_buffer.len) {
                const end = @min(start + initial_piece_bytes, self.original_buffer.len);
                try self.tree.push(TreePiece.fromText(.original, start, self.original_buffer[start..end]));
                start = end;
            }
            tree_tx.commit();
        }
        return self;
    }

    pub fn deinit(self: *PieceTree) void {
        self.tree.deinit();
        if (self.original_page) |page| page.release();
        self.add_buffer.deinit(self.allocator);
        for (self.add_pages.items) |page| page.release();
        self.add_pages.deinit(self.allocator);
    }

    /// create read-only snapshot (bg-thread-safe).
    /// SumTree COW O(1) + add page metadata copy.
    ///
    /// bg-thread callable (word_index.zig bgLoop). via `snapshot_mutex` main-thread
    /// mutation exclude, avoid reading half-mutated add_pages pointer/tree root (bg
    /// thread SIGSEGV).
    pub fn snapshot(self: *PieceTree, alloc: Allocator) !PieceTreeSnapshot {
        self.snapshot_mutex.lockUncancelable(self.io);
        defer self.snapshot_mutex.unlock(self.io);

        const pages = try alloc.alloc(*AddBufferPage, self.add_pages.items.len);
        for (self.add_pages.items, 0..) |page, i| {
            page.retain();
            pages[i] = page;
        }
        if (self.original_page) |page| page.retain();
        return .{
            .tree = self.tree.snapshot(),
            .original_buffer = self.original_buffer,
            .original_page = self.original_page,
            .add_pages = pages,
            .allocator = alloc,
        };
    }

    /// A mutation batch holds the snapshot lock until commit or rollback. Reads
    /// on this thread remain valid; do not call snapshot/insert/delete on the
    /// tree while the transaction is active. Use the transaction edit methods.
    /// The COW root and append-only buffer lengths make rollback allocation-free.
    pub const Transaction = struct {
        owner: *PieceTree,
        tree_transaction: Tree.Transaction,
        add_len: usize,
        page_count: usize,
        active: bool = true,

        pub fn insert(self: *Transaction, pos: usize, text: []const u8) !void {
            std.debug.assert(self.active);
            try self.owner.insertUnlocked(pos, text);
        }

        pub fn delete(self: *Transaction, start: usize, length: usize) !void {
            std.debug.assert(self.active);
            try self.owner.deleteUnlocked(start, length);
        }

        pub fn commit(self: *Transaction) void {
            std.debug.assert(self.active);
            self.tree_transaction.commit();
            self.active = false;
            self.owner.snapshot_mutex.unlock(self.owner.io);
        }

        /// Always defer deinit; an uncommitted batch is rolled back in full.
        pub fn deinit(self: *Transaction) void {
            if (!self.active) return;
            self.tree_transaction.deinit();
            self.owner.add_buffer.shrinkRetainingCapacity(self.add_len);
            while (self.owner.add_pages.items.len > self.page_count) {
                self.owner.add_pages.pop().?.release();
            }
            self.owner.add_pages_total_len = self.add_len;
            self.active = false;
            self.owner.snapshot_mutex.unlock(self.owner.io);
        }
    };

    pub fn beginTransaction(self: *PieceTree) Transaction {
        self.snapshot_mutex.lockUncancelable(self.io);
        return .{
            .owner = self,
            .tree_transaction = self.tree.beginTransaction(),
            .add_len = self.add_buffer.items.len,
            .page_count = self.add_pages.items.len,
        };
    }

    // ===== edit ops =====

    /// insert text at pos, O(log P).
    pub fn insert(self: *PieceTree, pos: usize, text: []const u8) !void {
        var tx = self.beginTransaction();
        defer tx.deinit();
        try tx.insert(pos, text);
        tx.commit();
    }

    fn insertUnlocked(self: *PieceTree, pos: usize, text: []const u8) !void {
        const total = self.totalLength();
        if (pos > total) return error.InvalidPosition;
        if (text.len == 0) return;

        // getChunkAt may lend a slice of add_buffer to the caller. Growing that
        // buffer invalidates the source, including inside ArrayList.appendSlice.
        const source_ptr = @intFromPtr(text.ptr);
        const add_ptr = @intFromPtr(self.add_buffer.items.ptr);
        if (self.add_buffer.items.len > 0 and source_ptr >= add_ptr and
            source_ptr - add_ptr < self.add_buffer.items.len)
        {
            const copy = try self.allocator.dupe(u8, text);
            defer self.allocator.free(copy);
            return self.insertUnlocked(pos, copy);
        }

        // append to add_buffer.
        const add_start = self.add_buffer.items.len;
        try self.add_buffer.appendSlice(self.allocator, text);
        self.appendAddPages(add_start, text) catch |err| {
            self.add_buffer.shrinkRetainingCapacity(add_start);
            return err;
        };

        if (self.tree.count() == 0) {
            try self.pushInsertedPieces(add_start, text);
            return;
        }

        // seek target piece via ByteDim.
        const seek_result = self.tree.seek(ByteDim, pos);

        if (seek_result.item == null or seek_result.preceding == pos) {
            // piece boundary, direct insert.
            try self.insertPiecesAt(seek_result.index, add_start, text);
            return;
        }

        // piece middle, need split.
        const piece_idx = seek_result.index;
        const piece = seek_result.item.?;
        const offset_in_piece = seek_result.offset_in_item;

        // prefix piece.
        const prefix_buf = self.getBuffer(piece.source);
        const prefix = TreePiece.fromText(piece.source, piece.start, prefix_buf[piece.start .. piece.start + offset_in_piece]);

        // suffix piece.
        const suffix_start = piece.start + offset_in_piece;
        const suffix_len = piece.length - offset_in_piece;
        const suffix = TreePiece.fromText(piece.source, suffix_start, self.getBuffer(piece.source)[suffix_start .. suffix_start + suffix_len]);

        // replace original piece with prefix.
        try self.tree.replace(piece_idx, prefix);
        try self.insertPiecesAt(piece_idx + 1, add_start, text);
        try self.tree.insert(piece_idx + 1 + insertedPieceCount(text.len), suffix);
    }

    /// delete [start, start+length) range, O(log P).
    pub fn delete(self: *PieceTree, start: usize, length: usize) !void {
        var tx = self.beginTransaction();
        defer tx.deinit();
        try tx.delete(start, length);
        tx.commit();
    }

    fn deleteUnlocked(self: *PieceTree, start: usize, length: usize) !void {
        const total = self.totalLength();
        if (start > total or length > total - start) return error.InvalidRange;
        if (length == 0) return;

        const end_pos = start + length;

        // find start piece.
        const start_seek = self.tree.seek(ByteDim, start);
        if (start_seek.item == null) return;

        // find end piece. note: end_pos may be exact piece boundary.
        var end_seek: Tree.SeekResult(ByteDim) = undefined;
        if (end_pos >= total) {
            end_seek = .{
                .index = self.tree.count(),
                .item = null,
                .offset_in_item = 0,
                .preceding = total,
            };
        } else {
            end_seek = self.tree.seek(ByteDim, end_pos);
        }

        // case 1: delete range entirely within one piece.
        if (start_seek.index == end_seek.index and end_seek.item != null) {
            const piece = start_seek.item.?;
            const start_in_piece = start_seek.offset_in_item;
            const end_in_piece = end_seek.offset_in_item;

            if (start_in_piece == 0 and end_in_piece == piece.length) {
                // entire piece deleted.
                try self.tree.remove(start_seek.index);
            } else if (start_in_piece == 0) {
                // delete piece prefix.
                const buf = self.getBuffer(piece.source);
                const new_start = piece.start + end_in_piece;
                const new_len = piece.length - end_in_piece;
                try self.tree.replace(start_seek.index, TreePiece.fromText(piece.source, new_start, buf[new_start .. new_start + new_len]));
            } else if (end_in_piece == piece.length) {
                // delete piece suffix.
                const buf = self.getBuffer(piece.source);
                try self.tree.replace(start_seek.index, TreePiece.fromText(piece.source, piece.start, buf[piece.start .. piece.start + start_in_piece]));
            } else {
                // delete middle, split to two.
                const buf = self.getBuffer(piece.source);
                const prefix = TreePiece.fromText(piece.source, piece.start, buf[piece.start .. piece.start + start_in_piece]);
                const suffix_start = piece.start + end_in_piece;
                const suffix_len = piece.length - end_in_piece;
                const suffix = TreePiece.fromText(piece.source, suffix_start, buf[suffix_start .. suffix_start + suffix_len]);
                try self.tree.replace(start_seek.index, prefix);
                try self.tree.insert(start_seek.index + 1, suffix);
            }
            return;
        }

        // case 2: delete span multiple pieces. steps: collect indices then rear-to-front
        // modify.

        // handle end piece (partial delete if).
        var end_idx = end_seek.index;
        if (end_seek.item != null and end_seek.offset_in_item > 0) {
            // end piece front half deleted.
            const end_piece = end_seek.item.?;
            const off = end_seek.offset_in_item;
            const buf = self.getBuffer(end_piece.source);
            const new_start = end_piece.start + off;
            const new_len = end_piece.length - off;
            try self.tree.replace(end_seek.index, TreePiece.fromText(end_piece.source, new_start, buf[new_start .. new_start + new_len]));
            end_idx = end_seek.index;
        }

        // delete middle full pieces (rear-to-front to keep indices stable).
        {
            const first_full_remove = if (start_seek.offset_in_item > 0)
                start_seek.index + 1
            else
                start_seek.index;

            if (end_idx > first_full_remove) {
                var i = end_idx;
                while (i > first_full_remove) {
                    i -= 1;
                    try self.tree.remove(i);
                }
            }
        }

        // handle start piece (partial delete if).
        if (start_seek.offset_in_item > 0) {
            const piece = start_seek.item.?;
            const buf = self.getBuffer(piece.source);
            try self.tree.replace(start_seek.index, TreePiece.fromText(piece.source, piece.start, buf[piece.start .. piece.start + start_seek.offset_in_item]));
        }
    }

    // ===== query API =====

    /// total bytes O(1).
    pub fn totalLength(self: *const PieceTree) usize {
        return self.tree.summary().bytes;
    }

    /// total lines O(1): newlines + 1.
    pub fn lineCount(self: *const PieceTree) usize {
        return self.tree.summary().lines + 1;
    }

    /// longest row chars O(1): SumTree root summary direct read. align
    /// Zed DisplaySnapshot::longest_row(), no full-file scan.
    pub fn longestRowChars(self: *const PieceTree) u32 {
        return self.tree.summary().longest_row_chars;
    }

    /// get [start, start+length) text. locate start piece by byte dim, then
    /// sequential traverse; no re-seek each fragment.
    pub fn getText(self: *const PieceTree, start: usize, length: usize, buffer: []u8) ![]const u8 {
        const total = self.totalLength();
        if (start > total or length > total - start) return error.InvalidRange;
        if (buffer.len < length) return error.BufferTooSmall;
        if (length == 0) return buffer[0..0];

        // O(log P) locate start piece.
        var pieces = self.tree.iterator();
        var offset_in_piece = pieces.seekTo(ByteDim, start) orelse return error.CorruptPieceTree;
        var copied: usize = 0;
        var remaining = length;

        // copy sequentially from located piece.
        while (remaining > 0) {
            const piece = pieces.next() orelse return error.CorruptPieceTree;
            const source_buf = self.getBuffer(piece.source);
            if (!hasValidPieceBounds(piece, source_buf)) return error.CorruptPieceTree;
            if (offset_in_piece > piece.length) return error.CorruptPieceTree;
            const available = piece.length - offset_in_piece;
            // Public mutators never retain empty pieces; zero progress is corruption.
            if (available == 0) return error.CorruptPieceTree;
            const to_copy = @min(available, remaining);

            @memcpy(
                buffer[copied .. copied + to_copy],
                source_buf[piece.start + offset_in_piece .. piece.start + offset_in_piece + to_copy],
            );

            copied += to_copy;
            remaining -= to_copy;
            offset_in_piece = 0; // next pieces from head.
        }

        if (remaining != 0) return error.CorruptPieceTree;
        return buffer[0..copied];
    }

    /// zero-copy: return direct slice in piece at offset (no copy). from offset to piece
    /// end continuous memory. tree-sitter read callback avoids 4KB memcpy per call.
    pub const ChunkResult = struct {
        ptr: [*]const u8,
        len: usize,
    };

    pub fn getChunkAt(self: *const PieceTree, offset: usize) ?ChunkResult {
        const total = self.totalLength();
        if (offset >= total) return null;

        const seek_result = self.tree.seek(ByteDim, offset);
        const piece = seek_result.item orelse return null;
        const source_buf = self.getBuffer(piece.source);
        if (!hasValidPieceBounds(piece, source_buf)) return null;
        const offset_in_piece = seek_result.offset_in_item;
        if (offset_in_piece >= piece.length) return null;
        const available = piece.length - offset_in_piece;
        const start = piece.start + offset_in_piece;
        return .{
            .ptr = source_buf[start..].ptr,
            .len = available,
        };
    }

    /// get specified line content.
    pub fn getLine(self: *const PieceTree, line: usize, buffer: []u8) ![]const u8 {
        const lc = self.lineCount();
        if (line >= lc) return error.InvalidLine;

        const start = self.lineToOffset(line);
        const end = if (line + 1 < lc)
            self.lineToOffset(line + 1)
        else
            self.totalLength();

        return self.getText(start, end - start, buffer);
    }

    /// byte offset -> line number, true O(log P): B-tree descend tracking line_count.
    pub fn offsetToLine(self: *const PieceTree, offset: usize) usize {
        const root = self.tree.root orelse return 0;
        const total = self.totalLength();
        const clamped = @min(offset, total);
        return self.offsetToLineInNode(root, clamped);
    }

    fn offsetToLineInNode(self: *const PieceTree, node: *const Tree.Node, remaining_bytes: usize) usize {
        switch (node.data) {
            .internal => |*internal| {
                var remaining = remaining_bytes;
                var lines: usize = 0;
                for (0..internal.len) |i| {
                    const child_bytes = internal.summaries[i].bytes;
                    if (child_bytes > remaining) {
                        return lines + self.offsetToLineInNode(internal.children[i], remaining);
                    }
                    lines += internal.summaries[i].lines;
                    remaining -= child_bytes;
                }
                return lines;
            },
            .leaf => |*leaf| {
                var remaining = remaining_bytes;
                var lines: usize = 0;
                for (leaf.items[0..leaf.len]) |piece| {
                    if (piece.length > remaining) {
                        // within-piece partial scan.
                        const buf = self.getBuffer(piece.source);
                        for (buf[piece.start .. piece.start + remaining]) |byte| {
                            if (byte == '\n') lines += 1;
                        }
                        return lines;
                    }
                    lines += piece.newline_count;
                    remaining -= piece.length;
                }
                return lines;
            },
        }
    }

    /// line number -> line start byte offset, true O(log P): B-tree descend tracking
    /// byte_offset and line_count.
    pub fn lineToOffset(self: *const PieceTree, target_line: usize) usize {
        if (target_line == 0) return 0;
        const root = self.tree.root orelse return 0;
        return self.lineToOffsetInNode(root, target_line);
    }

    fn lineToOffsetInNode(self: *const PieceTree, node: *const Tree.Node, remaining_lines: usize) usize {
        switch (node.data) {
            .internal => |*internal| {
                var remaining = remaining_lines;
                var byte_offset: usize = 0;
                for (0..internal.len) |i| {
                    const child_lines = internal.summaries[i].lines;
                    if (child_lines >= remaining) {
                        return byte_offset + self.lineToOffsetInNode(internal.children[i], remaining);
                    }
                    remaining -= child_lines;
                    byte_offset += internal.summaries[i].bytes;
                }
                return byte_offset;
            },
            .leaf => |*leaf| {
                var remaining = remaining_lines;
                var byte_offset: usize = 0;
                for (leaf.items[0..leaf.len]) |piece| {
                    if (piece.newline_count >= remaining) {
                        // find remaining-th \n within piece.
                        const buf = self.getBuffer(piece.source);
                        var count: usize = 0;
                        for (buf[piece.start .. piece.start + piece.length], 0..) |byte, j| {
                            if (byte == '\n') {
                                count += 1;
                                if (count == remaining) return byte_offset + j + 1;
                            }
                        }
                        return byte_offset + piece.length;
                    }
                    remaining -= piece.newline_count;
                    byte_offset += piece.length;
                }
                return byte_offset;
            },
        }
    }

    // ===== anchor API (stable position markers) =====

    /// create anchor at doc offset. after edit anchor auto-follow content (ref Zed
    /// `text::Anchor`).
    ///
    /// impl: (source, buffer_offset) pair on PieceTree. original_buffer and add_buffer
    /// append-only, so buffer_offset permanent byte coordinate.
    ///
    /// special: offset==0 -> `Anchor.START` (any edit point doc start); offset==totalLength()
    /// -> `Anchor.END` (any edit point doc end). need 'anchor current char' not forever
    /// endpoints, use `anchorAtStrict`.
    ///
    /// complexity: O(log P).
    pub fn anchorAt(self: *const PieceTree, offset: usize, bias: AnchorBias) Anchor {
        const total = self.totalLength();
        if (offset == 0) return Anchor.START;
        if (offset >= total) return Anchor.END;
        return self.anchorAtStrict(offset, bias);
    }

    /// Like `anchorAt`, but bypasses the START/END constants even at offset 0 or totalLength and
    /// returns a normal anchor (based on the current piece buffer_offset).
    ///
    /// Use case: Find/Selection need the anchor to follow the character position after edits, not
    /// be
    /// locked to doc start/end.
    pub fn anchorAtStrict(self: *const PieceTree, offset: usize, bias: AnchorBias) Anchor {
        const total = self.totalLength();
        const clamped = @min(offset, total);

        const seek = self.tree.seek(ByteDim, clamped);
        if (seek.item) |piece| {
            return .{
                .source = pieceSourceToAnchorSource(piece.source),
                .buffer_offset = piece.start + seek.offset_in_item,
                .bias = bias,
                .kind = .normal,
            };
        }

        // End of document (offset == total and total > 0) -> retreat to last piece end
        if (clamped > 0 and self.tree.count() > 0) {
            const last = self.tree.get(self.tree.count() - 1) orelse return Anchor.END;
            return .{
                .source = pieceSourceToAnchorSource(last.source),
                .buffer_offset = last.start + last.length,
                .bias = bias,
                .kind = .normal,
            };
        }

        // Empty document -> fallback to START
        return Anchor.START;
    }

    /// Resolve an anchor to the current document offset.
    ///
    /// Algorithm (Zed bias semantics):
    ///
    /// 1. Scan all pieces to find the piece containing (source, buffer_offset)
    /// 2. On hit (target_offset within piece [start, start+length]):
    ///    - Strictly inside (start < target < end): return doc_offset + (target - piece.start)
    ///    - On a piece boundary (target == piece.start or piece.end):
    ///      bias picks the boundary: .left prefers the preceding piece end; .right the following
    ///      piece start
    /// 3. On miss (anchor's buffer range deleted):
    ///    - .left -> preceding boundary (left doc offset of the deleted range)
    ///    - .right -> succeeding boundary (right doc offset of the deleted range)
    ///
    /// Complexity: O(P) linear scan; could cache source+offset -> piece_index
    pub fn resolveAnchor(self: *const PieceTree, anchor: Anchor) usize {
        switch (anchor.kind) {
            .start_of_document => return 0,
            .end_of_document => return self.totalLength(),
            .normal => {},
        }

        const target_source = anchorSourceToPieceSource(anchor.source);
        const target_offset = anchor.buffer_offset;

        var doc_offset: usize = 0;
        var best_before: usize = 0;
        var best_after: ?usize = null;
        // Record all matching pieces; bias chooses which one to use.
        // Typical scenario: after insert, original buffer split, both pieces touch
        // original target_offset (piece.end == target for former, piece.start == target for
        // latter).
        var inner_hit: ?usize = null; // interior hit (non-boundary)
        var trailing_edge_hit: ?usize = null; // target == piece_end (.left preferred)
        var leading_edge_hit: ?usize = null; // target == piece_start (.right preferred)

        const count = self.tree.count();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const piece = self.tree.get(i) orelse break;
            const piece_end = piece.start + piece.length;

            if (piece.source == target_source) {
                // Case 1: strictly interior hit
                if (target_offset > piece.start and target_offset < piece_end) {
                    inner_hit = doc_offset + (target_offset - piece.start);
                }
                // Case 2: target at piece end (trailing edge)
                else if (target_offset == piece_end and target_offset > piece.start) {
                    trailing_edge_hit = doc_offset + piece.length;
                }
                // Case 3: target at piece start (leading edge)
                else if (target_offset == piece.start and target_offset < piece_end) {
                    if (leading_edge_hit == null) leading_edge_hit = doc_offset;
                }
                // Case 4: empty piece and target on boundary (rare, ignore)

                // Record fallback candidates on miss
                if (target_offset > piece_end) {
                    best_before = doc_offset + piece.length;
                } else if (target_offset < piece.start and best_after == null) {
                    best_after = doc_offset;
                }
            }

            doc_offset += piece.length;
        }

        // Priority: inner hit most certain
        if (inner_hit) |h| return h;

        // Boundary hit: bias decides the direction
        switch (anchor.bias) {
            .left => {
                if (trailing_edge_hit) |h| return h;
                if (leading_edge_hit) |h| return h;
            },
            .right => {
                if (leading_edge_hit) |h| return h;
                if (trailing_edge_hit) |h| return h;
            },
        }

        // Complete miss: fallback
        return switch (anchor.bias) {
            .left => best_before,
            .right => best_after orelse doc_offset,
        };
    }

    // Anchor-related types (re-exported from core/anchor.zig for caller convenience)
    pub const Anchor = @import("anchor.zig").Anchor;
    pub const AnchorBias = @import("anchor.zig").Bias;
    pub const AnchorRange = @import("anchor.zig").AnchorRange;

    inline fn pieceSourceToAnchorSource(s: Source) @import("anchor.zig").Source {
        return switch (s) {
            .original => .original,
            .add => .add,
        };
    }

    inline fn anchorSourceToPieceSource(s: @import("anchor.zig").Source) Source {
        return switch (s) {
            .original => .original,
            .add => .add,
        };
    }

    // ===== internal helpers =====

    /// Zero-copy chunk iterator: return direct references per piece, no memcpy
    pub fn chunksInRange(self: *const PieceTree, start: usize, len: usize) ChunkIterator(PieceTree) {
        const total = self.totalLength();
        const clamped_start = @min(start, total);
        const clamped_len = @min(len, total - clamped_start);
        if (clamped_len == 0) return .{ .container = self, .index = 0, .offset_in_piece = 0, .remaining = 0 };
        const seek_result = self.tree.seek(ByteDim, clamped_start);
        return .{
            .container = self,
            .index = seek_result.index,
            .offset_in_piece = seek_result.offset_in_item,
            .remaining = clamped_len,
        };
    }

    fn getBuffer(self: *const PieceTree, source: Source) []const u8 {
        return switch (source) {
            .original => self.original_buffer,
            .add => self.add_buffer.items,
        };
    }

    fn getPieceBuffer(self: *const PieceTree, piece: TreePiece) ?[]const u8 {
        const source_buf = self.getBuffer(piece.source);
        if (!hasValidPieceBounds(piece, source_buf)) return null;
        return source_buf[piece.start .. piece.start + piece.length];
    }

    fn appendAddPages(self: *PieceTree, add_start: usize, text: []const u8) !void {
        if (self.add_pages_total_len != add_start) return error.InvalidAddBufferState;
        const old_page_count = self.add_pages.items.len;
        const old_total_len = self.add_pages_total_len;
        errdefer {
            while (self.add_pages.items.len > old_page_count) {
                const page = self.add_pages.pop().?;
                page.release();
            }
            self.add_pages_total_len = old_total_len;
        }
        var offset: usize = 0;
        while (offset < text.len) {
            const chunk_len = @min(ADD_BUFFER_PAGE_SIZE, text.len - offset);
            const page = try AddBufferPage.create(self.allocator, self.add_pages_total_len, text[offset .. offset + chunk_len]);
            self.add_pages.append(self.allocator, page) catch |err| {
                page.release();
                return err;
            };
            self.add_pages_total_len += chunk_len;
            offset += chunk_len;
        }
    }

    fn pushInsertedPieces(self: *PieceTree, add_start: usize, text: []const u8) !void {
        var offset: usize = 0;
        while (offset < text.len) {
            const chunk_len = @min(ADD_BUFFER_PAGE_SIZE, text.len - offset);
            try self.tree.push(TreePiece.fromText(.add, add_start + offset, text[offset .. offset + chunk_len]));
            offset += chunk_len;
        }
    }

    fn insertPiecesAt(self: *PieceTree, index: usize, add_start: usize, text: []const u8) !void {
        var offset: usize = 0;
        var insert_idx = index;
        while (offset < text.len) {
            const chunk_len = @min(ADD_BUFFER_PAGE_SIZE, text.len - offset);
            try self.tree.insert(insert_idx, TreePiece.fromText(.add, add_start + offset, text[offset .. offset + chunk_len]));
            insert_idx += 1;
            offset += chunk_len;
        }
    }

    fn insertedPieceCount(text_len: usize) usize {
        if (text_len == 0) return 0;
        return (text_len + ADD_BUFFER_PAGE_SIZE - 1) / ADD_BUFFER_PAGE_SIZE;
    }

    /// Scan text stats (aligns Zed TextSummary::from(str)).
    /// Single pass computes newline_count + first/last/longest_row_chars.
    ///
    /// Implemented in piece_stats.zig (see its module header: illegal UTF-8, truncated sequences,
    /// row width saturation). Delegation kept here for PieceTree.scanTextStats call sites.
    const TextStats = piece_stats.TextStats;

    fn scanTextStats(text: []const u8) TextStats {
        return piece_stats.scan(text);
    }
};

// ===== unit tests =====

test "PieceTree: init and deinit" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
}

test "PieceTree: init from buffer" {
    const content = "Hello\nWorld\n";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, content);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 12), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());
}

test "PieceTree: insert at beginning" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "Hello");
    try std.testing.expectEqual(@as(usize, 5), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("Hello", text);
}

test "PieceTree: insert at end" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "Hello");
    try pt.insert(5, " World");
    try std.testing.expectEqual(@as(usize, 11), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 11, &buffer);
    try std.testing.expectEqualStrings("Hello World", text);
}

test "PieceTree: snapshot shares add pages without copying contiguous add buffer" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    const large = try std.testing.allocator.alloc(u8, ADD_BUFFER_PAGE_SIZE + 32);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');

    try pt.insert(0, large);
    const first_page = pt.add_pages.items[0];
    const second_page = pt.add_pages.items[1];

    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 2), snap.add_pages.len);
    try std.testing.expectEqual(@intFromPtr(first_page), @intFromPtr(snap.add_pages[0]));
    try std.testing.expectEqual(@intFromPtr(second_page), @intFromPtr(snap.add_pages[1]));
}

test "PieceTree: insert in middle" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try pt.insert(5, ",");
    try std.testing.expectEqual(@as(usize, 12), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 12, &buffer);
    try std.testing.expectEqualStrings("Hello, World", text);
}

test "PieceTree: get line" {
    const content = "Line 1\nLine 2\nLine 3\n";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, content);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());

    var buffer: [100]u8 = undefined;

    const line1 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1\n", line1);

    const line2 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 2\n", line2);
}

test "PieceTree: delete from middle" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try pt.delete(5, 1); // delete space
    try std.testing.expectEqual(@as(usize, 10), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 10, &buffer);
    try std.testing.expectEqualStrings("HelloWorld", text);
}

test "PieceTree: delete from beginning" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try pt.delete(0, 6);
    try std.testing.expectEqual(@as(usize, 5), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("World", text);
}

test "PieceTree: delete from end" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try pt.delete(5, 6);
    try std.testing.expectEqual(@as(usize, 5), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("Hello", text);
}

test "PieceTree: delete across pieces" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "Hello");
    try pt.insert(5, " World");
    try pt.insert(11, "!");

    try pt.delete(3, 5); // Delete "lo Wo"
    try std.testing.expectEqual(@as(usize, 7), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 7, &buffer);
    try std.testing.expectEqualStrings("Helrld!", text);
}

test "PieceTree: line index after insert newline" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());

    try pt.insert(5, "\n");
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Hello\n", line0);
    const line1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings(" World", line1);
}

test "PieceTree: line index after insert multiple newlines" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "ABCD");
    try pt.insert(2, "\n\n");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("AB\n", line0);
    const line1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", line1);
    const line2 = try pt.getLine(2, &buffer);
    try std.testing.expectEqualStrings("CD", line2);
}

test "PieceTree: line index after delete newline" {
    const content = "Line 1\nLine 2\nLine 3";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, content);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    try pt.delete(6, 1);
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1Line 2\n", line0);
    const line1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 3", line1);
}

test "PieceTree: line index after delete across lines" {
    const content = "AAA\nBBB\nCCC\nDDD";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, content);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());

    try pt.delete(4, 8); // "BBB\nCCC\n"
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("AAA\n", line0);
    const line1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("DDD", line1);
}

test "PieceTree: line consistency through multiple edits" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "Line 1\n");
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    try pt.insert(7, "Line 2\n");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    try pt.insert(14, "Line 3");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const l0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1\n", l0);
    const l1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 2\n", l1);
    const l2 = try pt.getLine(2, &buffer);
    try std.testing.expectEqualStrings("Line 3", l2);

    const full_before = try pt.getText(0, pt.totalLength(), &buffer);
    try std.testing.expectEqualStrings("Line 1\nLine 2\nLine 3", full_before);

    try pt.delete(7, 7);
    try std.testing.expectEqual(@as(usize, 13), pt.totalLength());

    const full_after = try pt.getText(0, pt.totalLength(), &buffer);
    try std.testing.expectEqualStrings("Line 1\nLine 3", full_after);

    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());
    const new_l1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 3", new_l1);
}

test "PieceTree: consecutive newline inserts" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "Press hello\n");
    defer pt.deinit();

    var buffer: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    try pt.insert(11, "\n");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());
    const l0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Press hello\n", l0);
    const l1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", l1);

    try pt.insert(12, "\n");
    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());

    try pt.insert(13, "\n");
    try std.testing.expectEqual(@as(usize, 5), pt.lineCount());

    const full = try pt.getText(0, pt.totalLength(), &buffer);
    try std.testing.expectEqualStrings("Press hello\n\n\n\n", full);
}

test "PieceTree: insert newline at line start" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "ABC");
    defer pt.deinit();

    var buffer: [256]u8 = undefined;

    try pt.insert(0, "\n");
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());
    const l0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("\n", l0);
    const l1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("ABC", l1);

    try pt.insert(1, "\n");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    const full = try pt.getText(0, pt.totalLength(), &buffer);
    try std.testing.expectEqualStrings("\n\nABC", full);
}

test "PieceTree: offsetToLine and lineToOffset" {
    const content = "Hello\nWorld\nFoo\n";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, content);
    defer pt.deinit();

    // line 0 = "Hello\n" (0..6)
    // line 1 = "World\n" (6..12)
    // line 2 = "Foo\n"   (12..16)
    // line 3 = ""         (16..16)
    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());

    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(0));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(5));
    try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(6));
    try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(11));
    try std.testing.expectEqual(@as(usize, 2), pt.offsetToLine(12));
    try std.testing.expectEqual(@as(usize, 3), pt.offsetToLine(16));

    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));
    try std.testing.expectEqual(@as(usize, 6), pt.lineToOffset(1));
    try std.testing.expectEqual(@as(usize, 12), pt.lineToOffset(2));
    try std.testing.expectEqual(@as(usize, 16), pt.lineToOffset(3));
}

test "PieceTree: equivalence with PieceTable for mixed operations" {
    // Equivalence test: verify PieceTree and PieceTable results match for same operations
    const piece_table_mod = @import("piece_table.zig");
    const PieceTable = piece_table_mod.PieceTable;

    var pt_tree = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt_tree.deinit();

    var pt_table = try PieceTable.init(std.testing.allocator);
    defer pt_table.deinit();

    const ops = [_]struct { kind: enum { ins, del }, pos: usize, text: []const u8, del_len: usize }{
        .{ .kind = .ins, .pos = 0, .text = "Hello World\n", .del_len = 0 },
        .{ .kind = .ins, .pos = 5, .text = ",\n", .del_len = 0 },
        .{ .kind = .ins, .pos = 14, .text = "Foo\nBar\n", .del_len = 0 },
        .{ .kind = .del, .pos = 3, .text = "", .del_len = 5 },
        .{ .kind = .ins, .pos = 3, .text = "XYZ", .del_len = 0 },
        .{ .kind = .del, .pos = 0, .text = "", .del_len = 3 },
    };

    for (ops) |op| {
        switch (op.kind) {
            .ins => {
                try pt_tree.insert(op.pos, op.text);
                try pt_table.insert(op.pos, op.text);
            },
            .del => {
                try pt_tree.delete(op.pos, op.del_len);
                try pt_table.delete(op.pos, op.del_len);
            },
        }

        // Verify total length match
        try std.testing.expectEqual(pt_table.total_length, pt_tree.totalLength());

        // Verify line count match
        try std.testing.expectEqual(pt_table.lineCount(), pt_tree.lineCount());

        // Verify full text match
        var buf1: [1024]u8 = undefined;
        var buf2: [1024]u8 = undefined;
        const text1 = try pt_tree.getText(0, pt_tree.totalLength(), &buf1);
        const text2 = try pt_table.getText(0, pt_table.total_length, &buf2);
        try std.testing.expectEqualStrings(text2, text1);
    }
}

test "PieceTree: lineToOffset/offsetToLine brute force verification" {
    const alloc = std.testing.allocator;

    // Various document contents
    const cases = [_][]const u8{
        "Hello\nWorld\nFoo\n",
        "abc",
        "\n\n\n",
        "a\nb\nc",
        "Line 1\nLine 2\nLine 3\n",
        "",
        "\n",
        "no newline at end",
        "aaa\nbbb\nccc\nddd\neee\nfff\n",
    };

    for (cases) |content| {
        var pt = if (content.len > 0)
            try PieceTree.initFromBuffer(alloc, std.testing.io, content)
        else
            PieceTree.init(alloc, std.testing.io);
        defer pt.deinit();

        const lc = pt.lineCount();

        // Brute force compute line offset table
        var line_starts_buf: [128]usize = undefined;
        var brute_lc: usize = 1;
        line_starts_buf[0] = 0;
        for (content, 0..) |byte, i| {
            if (byte == '\n') {
                line_starts_buf[brute_lc] = i + 1;
                brute_lc += 1;
            }
        }

        // Verify lineCount
        try std.testing.expectEqual(brute_lc, lc);

        // Verify lineToOffset
        for (0..lc) |line| {
            const expected = line_starts_buf[line];
            const got = pt.lineToOffset(line);
            try std.testing.expectEqual(expected, got);
        }

        // Verify offsetToLine
        for (0..content.len + 1) |offset| {
            var expected_line: usize = 0;
            for (content[0..@min(offset, content.len)]) |b| {
                if (b == '\n') expected_line += 1;
            }
            const got = pt.offsetToLine(@min(offset, pt.totalLength()));
            try std.testing.expectEqual(expected_line, got);
        }
    }

    // Post-edit verify: simulate multiple inserts producing multiple pieces
    {
        var pt = PieceTree.init(alloc, std.testing.io);
        defer pt.deinit();

        try pt.insert(0, "AAA\n");
        try pt.insert(4, "BBB\n");
        try pt.insert(8, "CCC");

        // Full text = "AAA\nBBB\nCCC" (3 pieces)
        try std.testing.expectEqual(@as(usize, 3), pt.lineCount());
        try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));
        try std.testing.expectEqual(@as(usize, 4), pt.lineToOffset(1));
        try std.testing.expectEqual(@as(usize, 8), pt.lineToOffset(2));

        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(0));
        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(3));
        try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(4));
        try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(7));
        try std.testing.expectEqual(@as(usize, 2), pt.offsetToLine(8));
        try std.testing.expectEqual(@as(usize, 2), pt.offsetToLine(11));
    }
}

test "PieceTree: getText rejects corrupt piece bounds" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    try pt.insert(0, "abc");
    try pt.tree.replace(0, .{
        .source = .add,
        .start = 99,
        .length = 1,
        .newline_count = 0,
    });

    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.CorruptPieceTree, pt.getText(0, 1, &buffer));

    var snapshot = try pt.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectError(error.CorruptPieceTree, snapshot.getText(0, 1, &buffer));
}

test "PieceTreeSnapshot remains readable during concurrent source edits" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();

    const seed = "0123456789abcdef\n";
    for (0..48) |_| {
        try pt.insert(pt.totalLength(), seed);
    }

    var snapshot = try pt.snapshot(std.testing.allocator);
    defer snapshot.deinit();

    const total = snapshot.totalLength();
    const expected = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(expected);
    _ = try snapshot.getText(0, total, expected);

    const AtomicBool = std.atomic.Value(bool);
    const ReaderContext = struct {
        snapshot: *const PieceTreeSnapshot,
        expected: []const u8,
        done: *AtomicBool,
        failed: *AtomicBool,

        fn run(ctx: *@This()) void {
            var buf: [97]u8 = undefined;
            var offset: usize = 0;

            while (!ctx.done.load(.acquire)) {
                const remaining = ctx.expected.len - offset;
                const read_len = @min(buf.len, remaining);
                const text = ctx.snapshot.getText(offset, read_len, &buf) catch {
                    ctx.failed.store(true, .release);
                    return;
                };
                if (!std.mem.eql(u8, ctx.expected[offset .. offset + read_len], text)) {
                    ctx.failed.store(true, .release);
                    return;
                }

                offset += 31;
                if (offset >= ctx.expected.len) offset = 0;
            }
        }
    };

    var done = AtomicBool.init(false);
    var failed = AtomicBool.init(false);
    var reader_ctx = ReaderContext{
        .snapshot = &snapshot,
        .expected = expected,
        .done = &done,
        .failed = &failed,
    };
    const thread = try std.Thread.spawn(.{}, ReaderContext.run, .{&reader_ctx});
    defer thread.join();

    for (0..2_000) |i| {
        const mid = pt.totalLength() / 2;
        try pt.insert(mid, "X");
        try pt.delete(mid, 1);

        if ((i & 31) == 0) {
            std.Thread.yield() catch {};
        }
    }

    done.store(true, .release);
    try std.testing.expect(!failed.load(.acquire));
}

test "ChunkIterator: basic single piece" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "hello world");
    defer pt.deinit();

    // Full range iteration
    var it = pt.chunksInRange(0, pt.totalLength());
    var result: [64]u8 = undefined;
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    try std.testing.expectEqualSlices(u8, "hello world", result[0..pos]);
}

test "ChunkIterator: multiple pieces after edit" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abcdef");
    defer pt.deinit();
    try pt.insert(3, "XYZ"); // "abcXYZdef"

    var it = pt.chunksInRange(0, pt.totalLength());
    var result: [64]u8 = undefined;
    var pos: usize = 0;
    var chunk_count: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
        chunk_count += 1;
    }
    try std.testing.expectEqualSlices(u8, "abcXYZdef", result[0..pos]);
    try std.testing.expect(chunk_count >= 2); // at least 2 pieces
}

test "ChunkIterator: sub-range" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "0123456789");
    defer pt.deinit();
    try pt.insert(5, "AB"); // "01234AB56789"

    // Iterate only offset 3..9 -> "34AB56"
    var it = pt.chunksInRange(3, 6);
    var result: [64]u8 = undefined;
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    try std.testing.expectEqualSlices(u8, "34AB56", result[0..pos]);
}

test "ChunkIterator: empty range" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abc");
    defer pt.deinit();

    var it = pt.chunksInRange(1, 0);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "ChunkIterator: snapshot" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "hello");
    defer pt.deinit();
    try pt.insert(5, " world");

    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();

    var it = snap.chunksInRange(0, snap.totalLength());
    var result: [64]u8 = undefined;
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    try std.testing.expectEqualSlices(u8, "hello world", result[0..pos]);
}

test "PieceTreeSnapshot: getChunkAt returns direct slice inside piece" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "hello");
    defer pt.deinit();
    try pt.insert(5, " world");

    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();

    const chunk0 = snap.getChunkAt(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", chunk0.ptr[0..chunk0.len]);

    const chunk6 = snap.getChunkAt(6) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("world", chunk6.ptr[0..chunk6.len]);

    try std.testing.expectEqual(@as(?PieceTreeSnapshot.ChunkResult, null), snap.getChunkAt(snap.totalLength()));
}

test "PieceTreeSnapshot retains original buffer after source deinit" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "hello world");
    var snap = try pt.snapshot(std.testing.allocator);
    pt.deinit();
    defer snap.deinit();

    var buf: [11]u8 = undefined;
    const text = try snap.getText(0, 11, &buf);
    try std.testing.expectEqualStrings("hello world", text);

    const chunk = snap.getChunkAt(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello world", chunk.ptr[0..chunk.len]);
}

test "ChunkIterator: matches getText" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "The quick brown fox jumps over the lazy dog");
    defer pt.deinit();
    // Create multiple pieces
    try pt.insert(10, "!!!"); // after "quick"
    try pt.insert(0, ">>> ");
    try pt.delete(20, 5);

    const total = pt.totalLength();
    var text_buf: [256]u8 = undefined;
    const expected = try pt.getText(0, total, &text_buf);

    var it = pt.chunksInRange(0, total);
    var result: [256]u8 = undefined;
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    try std.testing.expectEqualSlices(u8, expected, result[0..pos]);
}

test "PieceTree: longestRowChars basic" {
    // Simple multi-line text
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "short\na longer line here\nhi\n");
    defer pt.deinit();
    // "a longer line here" = 18 chars
    try std.testing.expectEqual(@as(u32, 18), pt.longestRowChars());
}

test "PieceTree: longestRowChars single line" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "hello world");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 11), pt.longestRowChars());
}

test "PieceTree: longestRowChars empty" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 0), pt.longestRowChars());
}

test "PieceTree: longestRowChars after insert extends line" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abc\ndef\n");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 3), pt.longestRowChars());
    // Insert " extended" after "abc" -> "abc extended\ndef\n"
    try pt.insert(3, " extended");
    try std.testing.expectEqual(@as(u32, 12), pt.longestRowChars());
}

test "PieceTree: longestRowChars after delete shrinks" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "short\nvery long line content here\nhi\n");
    defer pt.deinit();
    // "very long line content here" = 27 chars
    try std.testing.expectEqual(@as(u32, 27), pt.longestRowChars());
    // Delete "very long line content here\n" (offset 6, length 28)
    try pt.delete(6, 28);
    // Remaining: "short\nhi\n" -> longest = 5
    try std.testing.expectEqual(@as(u32, 5), pt.longestRowChars());
}

test "PieceTree: longestRowChars cross-piece join" {
    // Two pieces that join: "abc" + "defghij\nxy" -> first line "abcdefghij" = 10 chars
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abc");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 3), pt.longestRowChars());
    try pt.insert(3, "defghij\nxy");
    // "abcdefghij\nxy" -> longest = 10
    try std.testing.expectEqual(@as(u32, 10), pt.longestRowChars());
}

test "PieceTree: scanTextStats correctness" {
    const stats = PieceTree.scanTextStats("hello\nworld foo bar\nhi\n");
    try std.testing.expectEqual(@as(usize, 3), stats.newline_count);
    try std.testing.expectEqual(@as(u32, 5), stats.first_line_chars); // "hello"
    try std.testing.expectEqual(@as(u32, 0), stats.last_line_chars); // "" after final \n
    try std.testing.expectEqual(@as(u32, 13), stats.longest_row_chars); // "world foo bar"
}

test "PieceTree: scanTextStats no newline" {
    const stats = PieceTree.scanTextStats("abcdef");
    try std.testing.expectEqual(@as(usize, 0), stats.newline_count);
    try std.testing.expectEqual(@as(u32, 6), stats.first_line_chars);
    try std.testing.expectEqual(@as(u32, 6), stats.last_line_chars);
    try std.testing.expectEqual(@as(u32, 6), stats.longest_row_chars);
}

// Regression guard after factoring: delegation must field-by-field match
test "PieceTree: scanTextStats delegates to piece_stats.scan unchanged" {
    const cases = [_][]const u8{
        "",
        "\n",
        "abc",
        "hello\nworld foo bar\nhi\n",
        "héllo\nwörld\n",
        "abc\u{4F60}"[0..5], // truncated 3-byte sequence
        "\xff\xfe\xc0\x80\x8f",
        "ab\r\ncd\r\n",
    };
    for (cases) |text| {
        const via_pt = PieceTree.scanTextStats(text);
        const via_mod = piece_stats.scan(text);
        try std.testing.expectEqualDeep(via_mod, via_pt);
        // Explicit field-by-field comparison (expectEqualDeep has poor error messages)
        try std.testing.expectEqual(via_mod.newline_count, via_pt.newline_count);
        try std.testing.expectEqual(via_mod.first_line_chars, via_pt.first_line_chars);
        try std.testing.expectEqual(via_mod.last_line_chars, via_pt.last_line_chars);
        try std.testing.expectEqual(via_mod.longest_row_chars, via_pt.longest_row_chars);
    }
}

test "PieceTree: longestRowChars multi-piece insert builds correct cross-piece join" {
    // Large file scenario: append to same line multiple times, concatenate across pieces
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "line1\nline2\nline3\n");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 5), pt.longestRowChars());

    // Append at end of line2 (offset 11, before "\n" after "line2")
    try pt.insert(11, " appended text here!!!!");
    // "line2 appended text here!!!!" = 5 + 23 = 28 chars
    try std.testing.expectEqual(@as(u32, 28), pt.longestRowChars());

    // Append more
    try pt.insert(11 + 23, " and even more stuff");
    // "line2 appended text here!!!! and even more stuff" = 48 chars
    try std.testing.expectEqual(@as(u32, 48), pt.longestRowChars());
}

test "PieceTree: longestRowChars matches brute-force scan on constructed content" {
    // Construct multi-line content with known longest line
    const allocator = std.testing.allocator;
    var buf = @as(std.ArrayList(u8), .empty);
    defer buf.deinit(allocator);

    // Generate 1000 lines with line 500 longest (200 chars)
    var expected_longest: u32 = 0;
    for (0..1000) |i| {
        const line_len: usize = if (i == 500) 200 else @min(i % 80 + 10, 79);
        for (0..line_len) |_| {
            try buf.append(allocator, 'x');
        }
        try buf.append(allocator, '\n');
        if (line_len > expected_longest) expected_longest = @intCast(line_len);
    }

    var pt = try PieceTree.initFromBuffer(allocator, std.testing.io, buf.items);
    defer pt.deinit();
    try std.testing.expectEqual(expected_longest, pt.longestRowChars());

    // Now insert longer line at line 700
    // Find offset of line 700
    var offset: usize = 0;
    var line: usize = 0;
    for (buf.items, 0..) |byte, idx| {
        if (byte == '\n') {
            line += 1;
            if (line == 700) {
                offset = idx + 1;
                break;
            }
        }
    }
    // Insert 300 'Y's + '\n' at this position
    var insert_buf: [301]u8 = undefined;
    @memset(insert_buf[0..300], 'Y');
    insert_buf[300] = '\n';
    try pt.insert(offset, &insert_buf);
    try std.testing.expectEqual(@as(u32, 300), pt.longestRowChars());
}

test "PieceSummary: add merges longest_row_chars across join" {
    // Piece A: "abc" (no newline) -> first=3, last=3, longest=3
    const a = PieceSummary{ .bytes = 3, .lines = 0, .first_line_chars = 3, .last_line_chars = 3, .longest_row_chars = 3 };
    // Piece B: "defgh\nij" -> first=5, last=2, longest=5
    const b = PieceSummary{ .bytes = 8, .lines = 1, .first_line_chars = 5, .last_line_chars = 2, .longest_row_chars = 5 };
    const merged = a.add(b);
    // joined = 3 + 5 = 8 > both -> longest = 8
    try std.testing.expectEqual(@as(u32, 8), merged.longest_row_chars);
    // first_line_chars: a has no newlines -> extends: 3 + 5 = 8
    try std.testing.expectEqual(@as(u32, 8), merged.first_line_chars);
    // last_line_chars: b has newlines -> b.last = 2
    try std.testing.expectEqual(@as(u32, 2), merged.last_line_chars);
}

test "PieceSummary: line widths saturate instead of overflowing" {
    const a = PieceSummary{
        .first_line_chars = std.math.maxInt(u32),
        .last_line_chars = std.math.maxInt(u32),
        .longest_row_chars = std.math.maxInt(u32),
    };
    const b = PieceSummary{ .first_line_chars = 10, .last_line_chars = 10, .longest_row_chars = 10 };
    const merged = a.add(b);
    try std.testing.expectEqual(std.math.maxInt(u32), merged.first_line_chars);
    try std.testing.expectEqual(std.math.maxInt(u32), merged.last_line_chars);
    try std.testing.expectEqual(std.math.maxInt(u32), merged.longest_row_chars);
}

// ============================================================================
// Anchor tests
// ============================================================================

test "Anchor: START and END resolve to 0 and totalLength" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "Hello, World");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(PieceTree.Anchor.START));
    try std.testing.expectEqual(@as(usize, 12), pt.resolveAnchor(PieceTree.Anchor.END));
}

test "Anchor: anchorAt(0) returns START" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abc");
    defer pt.deinit();

    const a = pt.anchorAt(0, .right);
    const AnchorKind = @import("anchor.zig").Kind;
    try std.testing.expectEqual(AnchorKind.start_of_document, a.kind);
}

test "Anchor: anchorAt(total) returns END" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abc");
    defer pt.deinit();

    const a = pt.anchorAt(3, .left);
    const AnchorKind = @import("anchor.zig").Kind;
    try std.testing.expectEqual(AnchorKind.end_of_document, a.kind);
}

test "Anchor: normal anchor resolves to correct offset" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "Hello, World");
    defer pt.deinit();

    const a = pt.anchorAt(5, .left); // after "Hello"
    const AnchorKind = @import("anchor.zig").Kind;
    try std.testing.expectEqual(AnchorKind.normal, a.kind);
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(a));
}

test "Anchor: stability across insertions BEFORE anchor" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "Hello, World");
    defer pt.deinit();

    // Anchor points to 'W' in "World"
    const anchor_world = pt.anchorAt(7, .right);
    try std.testing.expectEqual(@as(usize, 7), pt.resolveAnchor(anchor_world));

    // Insert "<<" (2 bytes) at start
    try pt.insert(0, "<<");
    // anchor should auto-follow to new "World" start (offset 9)
    try std.testing.expectEqual(@as(usize, 9), pt.resolveAnchor(anchor_world));
}

test "Anchor: stability across insertions AFTER anchor" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "Hello, World");
    defer pt.deinit();

    const anchor_mid = pt.anchorAt(5, .left); // Point to end of "Hello"
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(anchor_mid));

    // Append at end
    try pt.insert(12, "!!!");
    // anchor position unchanged
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(anchor_mid));
}

test "Anchor: stability across deletions BEFORE anchor" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "Hello, World");
    defer pt.deinit();

    const anchor_world = pt.anchorAt(7, .right);
    try std.testing.expectEqual(@as(usize, 7), pt.resolveAnchor(anchor_world));

    // Delete "Hello, " (7 bytes)
    try pt.delete(0, 7);
    // anchor follows to new "World" start (offset 0)
    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(anchor_world));
}

test "Anchor: stability across deletions AFTER anchor" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "Hello, World");
    defer pt.deinit();

    const anchor_mid = pt.anchorAt(5, .left);

    // Delete "World" (5 bytes, position 7..12)
    try pt.delete(7, 5);
    // anchor position unchanged
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(anchor_mid));
}

test "Anchor: bias left vs right on insert AT anchor position" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abcdef");
    defer pt.deinit();

    // Anchor at offset 3 ("abc|def")
    const a_left = pt.anchorAt(3, .left);
    const a_right = pt.anchorAt(3, .right);
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_left));
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_right));

    // Insert "XYZ" at offset 3 -> doc becomes "abcXYZdef"
    try pt.insert(3, "XYZ");

    // Bias semantics (aligns Zed):
    //   .left  -> anchor sticks after the char before the insert -> position unchanged (3)
    //   .right -> anchor sticks before the char after the insert -> moves right (6)
    //
    // Detail: insert splits the original piece into "abc"(0..3) and "def"(3..6) and puts the add
    // piece between. target_offset=3 matches both:
    //   - "abc" piece trailing edge (piece_end=3) -> doc_offset=3
    //   - "def" piece leading edge (piece_start=3) -> doc_offset=6
    // .left chooses trailing; .right chooses leading.
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_left));
    try std.testing.expectEqual(@as(usize, 6), pt.resolveAnchor(a_right));
}

test "Anchor: falls back to left boundary when inside deleted range (.left bias)" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abcdefghij");
    defer pt.deinit();

    // Anchor points to offset 5 (character 'f')
    const a_left = pt.anchorAt(5, .left);
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(a_left));

    // Delete [3, 8) -> remove "defgh"
    try pt.delete(3, 5);
    // anchor's buffer bytes no longer in any piece
    // .left bias -> fallback to delete range left boundary (doc offset 3)
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_left));
}

test "Anchor: falls back to right boundary when inside deleted range (.right bias)" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abcdefghij");
    defer pt.deinit();

    const a_right = pt.anchorAt(5, .right);
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(a_right));

    try pt.delete(3, 5);
    // .right bias -> fallback to delete range right boundary (offset same: 3, deletion joins
    // directly)
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_right));
}

test "Anchor: survives complex edit sequence" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "The quick brown fox");
    defer pt.deinit();

    // Multiple anchors at different characters
    const a_quick = pt.anchorAt(4, .right); // 'q'
    const a_brown = pt.anchorAt(10, .right); // 'b'
    const a_fox = pt.anchorAt(16, .right); // 'f'

    // Multiple edits: replace "quick" with "very swift"
    try pt.delete(4, 5); // "The  brown fox"
    try pt.insert(4, "very swift"); // "The very swift brown fox"

    // anchor positions should correctly reflect new doc chars,
    // original 'q' buffer byte deleted -> fallback to delete boundary (offset 4)
    try std.testing.expectEqual(@as(usize, 4), pt.resolveAnchor(a_quick));
    // 'b' and 'f' buffer bytes unchanged, follow new offset (length +5)
    try std.testing.expectEqual(@as(usize, 15), pt.resolveAnchor(a_brown));
    try std.testing.expectEqual(@as(usize, 21), pt.resolveAnchor(a_fox));
}

test "Anchor: resolveAnchorRange returns pair" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "hello world");
    defer pt.deinit();

    const r: PieceTree.AnchorRange = .{
        .start = pt.anchorAt(0, .right),
        .end = pt.anchorAt(5, .left),
    };
    // Use resolve inside piece_tree, not document.resolveAnchorRange (that's document layer)
    const s = pt.resolveAnchor(r.start);
    const e = pt.resolveAnchor(r.end);
    try std.testing.expectEqual(@as(usize, 0), s);
    try std.testing.expectEqual(@as(usize, 5), e);
}

test "Anchor: normal anchor pointsTo predicate" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abcdef");
    defer pt.deinit();

    const a = pt.anchorAt(3, .left);
    // anchor points to offset 3 in original buffer
    try std.testing.expect(a.pointsTo(.original, 3));
    try std.testing.expect(!a.pointsTo(.original, 4));
    try std.testing.expect(!a.pointsTo(.add, 3));
}

test "Anchor: insert + anchor survives in add buffer" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "AB");
    defer pt.deinit();

    // Insert first, make subsequent anchor fall in add buffer
    try pt.insert(1, "XYZ"); // "AXYZB"

    const a_y = pt.anchorAt(2, .right); // 'Y' in add buffer
    try std.testing.expectEqual(@as(usize, 2), pt.resolveAnchor(a_y));

    // Insert more
    try pt.insert(0, "<<"); // "<<AXYZB"
    try std.testing.expectEqual(@as(usize, 4), pt.resolveAnchor(a_y));
}

fn checkTransactionalAllocationFailures(comptime deleting: bool) !void {
    const baseline = (@as([("first line\nsecond line\n").len * (5000)]u8, @bitCast(@as([5000][("first line\nsecond line\n").len]u8, @splat(("first line\nsecond line\n").*)))) ++ "");
    const inserted = (@as([("inserted\n").len * (16000)]u8, @bitCast(@as([16000][("inserted\n").len]u8, @splat(("inserted\n").*)))) ++ "");
    var fail_at: usize = 0;
    while (fail_at < 2000) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var pt = try PieceTree.initFromBuffer(failing.allocator(), std.testing.io, baseline);
        defer pt.deinit();
        var snap = try pt.snapshot(std.testing.allocator);
        defer snap.deinit();
        failing.fail_index = failing.alloc_index + fail_at;
        failing.resize_fail_index = failing.resize_index;
        const result = if (deleting) pt.delete(5, baseline.len - 10) else pt.insert(5, inserted);
        if (result) |_| {
            try std.testing.expectEqual(if (deleting) @as(usize, 10) else baseline.len + inserted.len, pt.totalLength());
            return;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            const buf = try std.testing.allocator.alloc(u8, baseline.len);
            defer std.testing.allocator.free(buf);
            try std.testing.expectEqual(@as(usize, baseline.len), pt.totalLength());
            try std.testing.expectEqualStrings(baseline, try pt.getText(0, baseline.len, buf));
            try std.testing.expectEqualStrings(baseline, try snap.getText(0, baseline.len, buf));
            try std.testing.expectEqual(@as(usize, 0), pt.add_buffer.items.len);
            try std.testing.expectEqual(@as(usize, 0), pt.add_pages.items.len);
            try std.testing.expectEqual(@as(usize, 0), pt.add_pages_total_len);
        }
    }
    return error.TestUnexpectedResult;
}

test "PieceTree transactions preserve text and release split nodes on every allocation failure" {
    try checkTransactionalAllocationFailures(false);
    try checkTransactionalAllocationFailures(true);
}

test "PieceTree transaction rollback keeps prior snapshots and anchors valid" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "hello world\n");
    defer pt.deinit();
    const anchor = pt.anchorAtStrict(6, .right);
    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();
    {
        var tx = pt.beginTransaction();
        defer tx.deinit();
        try tx.insert(0, "prefix");
        try tx.delete(8, 3);
        try std.testing.expectError(error.InvalidRange, tx.delete(1, std.math.maxInt(usize)));
    }
    var buf: [100]u8 = undefined;
    try std.testing.expectEqualStrings("hello world\n", try pt.getText(0, pt.totalLength(), &buf));
    try std.testing.expectEqualStrings("hello world\n", try snap.getText(0, snap.totalLength(), &buf));
    try std.testing.expectEqual(@as(usize, 6), pt.resolveAnchor(anchor));
    // A subsequent transaction can acquire the lock and publish a complete edit.
    try pt.insert(0, "ok ");
    try std.testing.expectEqual(@as(usize, 9), pt.resolveAnchor(anchor));
}

test "PieceTree insertion accepts a borrowed add-buffer chunk across reallocation" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();
    const content = (@as([("abcdef\n").len * (500)]u8, @bitCast(@as([500][("abcdef\n").len]u8, @splat(("abcdef\n").*)))) ++ "");
    try pt.insert(0, content);
    const chunk = pt.getChunkAt(0).?;
    try pt.insert(0, chunk.ptr[0..chunk.len]);
    const buf = try std.testing.allocator.alloc(u8, pt.totalLength());
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqualStrings(content ++ content, try pt.getText(0, pt.totalLength(), buf));
}

// ========================================================================
// Boundary & tree shape supplemental tests
//
// Covers branches not otherwise tested: empty doc, single char, long lines,
// no-newline large file, invalid UTF-8, and SumTree split/merge shape invariants.
// ========================================================================

/// Deterministic LCG (same multiplier as sum_tree.zig fuzzy test).
const Lcg = struct {
    state: u64,

    fn init(seed: u64) Lcg {
        return .{ .state = seed };
    }

    /// Return usize in [0, mod). mod must be nonzero.
    fn below(self: *Lcg, mod: usize) usize {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        const m: u64 = @intCast(mod);
        return @as(usize, @intCast((self.state >> 33) % m));
    }
};

/// Tree shape invariants check. Asserts only properties this implementation must satisfy:
///   1. All leaves same depth (height changes only at root split/collapse, splitInternalInsert
///      new node inherits sibling height, merge doesn't change it, so depth stays uniform);
///   2. Each node items <= BRANCHING_FACTOR (split always 4/5, insert has capacity guard);
///   3. Sum(piece.length) == tree.summary().bytes == totalLength();
///   4. piece count == tree.count().
/// Intentionally no "leaf fill >= MIN_CHILDREN" assert: removeInNode only rebalances direct
/// children and doesn't propagate, so underfull is an allowed intermediate state (see
/// sum_tree.zig:631).
const PieceTreeShape = struct {
    /// B-tree params copied from sum_tree.zig (BRANCHING_FACTOR=8).
    const branching_factor: usize = 8;
    /// Degenerate-to-chain depth ceiling. 8-way 512 pieces only need depth 2; 6 is loose guard
    /// to catch structural disasters like linear degradation.
    const max_depth: usize = 6;

    fn check(pt: *const PieceTree, alloc: std.mem.Allocator) !void {
        var depths = @as(std.ArrayList(usize), .empty);
        defer depths.deinit(alloc);
        var piece_count: usize = 0;
        var byte_sum: usize = 0;

        const root = pt.tree.root orelse {
            try std.testing.expectEqual(@as(usize, 0), pt.tree.count());
            try std.testing.expectEqual(@as(usize, 0), pt.tree.summary().bytes);
            return;
        };
        try collect(root, 0, &depths, &piece_count, &byte_sum, alloc);

        try std.testing.expectEqual(pt.tree.count(), piece_count);
        try std.testing.expectEqual(pt.totalLength(), byte_sum);
        try std.testing.expect(depths.items.len > 0);
        for (depths.items) |d| {
            try std.testing.expectEqual(depths.items[0], d);
            try std.testing.expect(d <= max_depth);
        }
    }

    fn collect(
        node: *const Tree.Node,
        depth: usize,
        depths: *std.ArrayList(usize),
        piece_count: *usize,
        byte_sum: *usize,
        alloc: std.mem.Allocator,
    ) !void {
        switch (node.data) {
            .leaf => |*leaf| {
                try depths.append(alloc, depth);
                try std.testing.expect(leaf.len <= branching_factor);
                piece_count.* += leaf.len;
                for (leaf.items[0..leaf.len]) |piece| byte_sum.* += piece.length;
            },
            .internal => |*internal| {
                try std.testing.expect(internal.len <= branching_factor);
                try std.testing.expect(internal.len > 0);
                for (0..internal.len) |i| {
                    try collect(internal.children[i], depth + 1, depths, piece_count, byte_sum, alloc);
                }
            },
        }
    }
};

test "PieceTree: empty document degenerate paths stay consistent" {
    const alloc = std.testing.allocator;
    var pt = PieceTree.init(alloc, std.testing.io);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 0), pt.longestRowChars());
    try std.testing.expectEqual(@as(usize, 0), pt.tree.count());
    // Query on empty doc must be safe
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(0));
    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));
    try std.testing.expectEqual(@as(?PieceTree.ChunkResult, null), pt.getChunkAt(0));
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", try pt.getText(0, 0, &buf));
    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(PieceTree.Anchor.END));
    // initFromBuffer("") equals init() (0 pieces); empty tree shape check also safe
    var pt2 = try PieceTree.initFromBuffer(alloc, std.testing.io, "");
    defer pt2.deinit();
    try std.testing.expectEqual(@as(usize, 0), pt2.tree.count());
    try std.testing.expectEqual(@as(usize, 0), pt2.totalLength());
    try PieceTreeShape.check(&pt2, alloc);
    // Delete 0 length on empty doc is legal no-op
    try pt.delete(0, 0);
    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
}

test "PieceTree: single character round-trips through every read path" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "x");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 1), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 1), pt.longestRowChars());
    try std.testing.expectEqual(@as(usize, 1), pt.tree.count());

    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("x", try pt.getText(0, 1, &buf));
    try std.testing.expectEqualStrings("x", try pt.getLine(0, &buf));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(0));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(1));
    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));

    const chunk = pt.getChunkAt(0).?;
    try std.testing.expectEqual(@as(usize, 1), chunk.len);
    try std.testing.expectEqual(@as(u8, 'x'), chunk.ptr[0]);
    try std.testing.expectEqual(@as(?PieceTree.ChunkResult, null), pt.getChunkAt(1));

    var it = pt.chunksInRange(0, 1);
    try std.testing.expectEqualStrings("x", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());

    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();
    try std.testing.expectEqualStrings("x", try snap.getText(0, 1, &buf));

    // Byte-by-byte fill then clear: minimal stress path for repeated split/replace/remove
    try pt.delete(0, 1);
    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 0), pt.tree.count());
    try pt.insert(0, "y");
    try std.testing.expectEqualStrings("y", try pt.getText(0, 1, &buf));
}

test "PieceTree: single character inserted into empty tree" {
    var pt = PieceTree.init(std.testing.allocator, std.testing.io);
    defer pt.deinit();
    try pt.insert(0, "Q");
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("Q", try pt.getText(0, pt.totalLength(), &buf));
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
}

test "PieceTree: deleting everything then editing again stays consistent" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "aa\nbb\ncc\n");
    defer pt.deinit();
    try pt.delete(0, pt.totalLength());
    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try PieceTreeShape.check(&pt, std.testing.allocator);

    // After clear (tree.count()==0), insert exercises empty-tree push branch
    try pt.insert(0, "fresh\ncontent\n");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("fresh\ncontent\n", try pt.getText(0, pt.totalLength(), &buf));
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());
    try PieceTreeShape.check(&pt, std.testing.allocator);
}

test "PieceTree: single very long line survives piece boundaries and cross-piece joins" {
    const alloc = std.testing.allocator;
    // Line length spans initial_piece_bytes(2048) and ADD_BUFFER_PAGE_SIZE(64KiB) thresholds
    const line_len: usize = 150_000;
    const content = try alloc.alloc(u8, line_len);
    defer alloc.free(content);
    @memset(content, 'L');

    var pt = try PieceTree.initFromBuffer(alloc, std.testing.io, content);
    defer pt.deinit();
    try std.testing.expectEqual(@as(usize, line_len), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try std.testing.expectEqual(@as(u32, @intCast(line_len)), pt.longestRowChars());
    try PieceTreeShape.check(&pt, alloc);

    // Insert equal-length content mid-long-line: split -> prefix/add/suffix
    const mid = line_len / 2;
    try pt.insert(mid, content);
    try std.testing.expectEqual(@as(usize, line_len * 2), pt.totalLength());
    try std.testing.expectEqual(@as(u32, @intCast(line_len * 2)), pt.longestRowChars());
    try PieceTreeShape.check(&pt, alloc);

    // Full read-back and segment compare
    const full = try alloc.alloc(u8, pt.totalLength());
    defer alloc.free(full);
    try std.testing.expectEqual(@as(usize, line_len * 2), (try pt.getText(0, pt.totalLength(), full)).len);
    try std.testing.expectEqualSlices(u8, content, full[0..line_len]);
    try std.testing.expectEqualSlices(u8, content, full[line_len..]);

    // Line coords on ultra-long single line must always be 0
    var off: usize = 0;
    while (off <= pt.totalLength()) : (off += 997) {
        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(@min(off, pt.totalLength())));
    }
    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));

    // ChunkIterator stitches full text across multiple pieces
    var it = pt.chunksInRange(0, pt.totalLength());
    var assembled: usize = 0;
    while (it.next()) |chunk| assembled += chunk.len;
    try std.testing.expectEqual(pt.totalLength(), assembled);
}

test "PieceTree: long line that exceeds one add-buffer page" {
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, ADD_BUFFER_PAGE_SIZE + 1024);
    defer alloc.free(big);
    @memset(big, 'z');

    var pt = PieceTree.init(alloc, std.testing.io); // Empty tree: insert exercises pushInsertedPieces multi-page path
    defer pt.deinit();
    try pt.insert(0, big);
    try std.testing.expectEqual(big.len, pt.totalLength());
    try std.testing.expectEqual(@as(u32, @intCast(big.len)), pt.longestRowChars());
    try std.testing.expectEqual(@as(usize, 2), pt.add_pages.items.len);

    const full = try alloc.alloc(u8, pt.totalLength());
    defer alloc.free(full);
    try std.testing.expectEqualSlices(u8, big, try pt.getText(0, pt.totalLength(), full));

    // After delete spanning add page boundary, remaining bytes still correct
    try pt.delete(ADD_BUFFER_PAGE_SIZE - 4, 8);
    const rest = try alloc.alloc(u8, pt.totalLength());
    defer alloc.free(rest);
    const got = try pt.getText(0, pt.totalLength(), rest);
    try std.testing.expectEqualSlices(u8, big[0 .. ADD_BUFFER_PAGE_SIZE - 4], got[0 .. ADD_BUFFER_PAGE_SIZE - 4]);
    try std.testing.expectEqualSlices(u8, big[ADD_BUFFER_PAGE_SIZE + 4 ..], got[ADD_BUFFER_PAGE_SIZE - 4 ..]);
}

test "PieceTree: large file with no newlines keeps offset<->line trivial" {
    const alloc = std.testing.allocator;
    const size: usize = 1024 * 1024;
    const content = try alloc.alloc(u8, size);
    defer alloc.free(content);
    // Semi-random verifiable content (no '\n')
    var rng = Lcg.init(7);
    for (content) |*b| b.* = @intCast('a' + @as(u32, @intCast(rng.below(26))));

    var pt = try PieceTree.initFromBuffer(alloc, std.testing.io, content);
    defer pt.deinit();
    try std.testing.expectEqual(size, pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try std.testing.expectEqual(@as(usize, size / PieceTree.initial_piece_bytes), pt.tree.count());
    try PieceTreeShape.check(&pt, alloc);

    // Sample read-back and verify (getText segments span pieces)
    var buf: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < size) : (off += 61_234) {
        const n = @min(buf.len, size - off);
        if (n == 0) break;
        try std.testing.expectEqualSlices(u8, content[off .. off + n], try pt.getText(off, n, &buf));
    }

    // Any offset always on line 0
    var probe: usize = 0;
    while (probe < size) : (probe += 123_457) {
        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(probe));
    }

    // 1MiB no-newline file, insert newline mid-file: lineCount 1->2, coordinates all correct.
    // Semantics match test "offsetToLine and lineToOffset": lineToOffset(k) returns the byte after
    // the k-th '\n' (lineToOffsetInNode `byte_offset + j + 1`), so '\n' at mid means line 1 starts
    // at
    // mid+1; offsetToLine counts only '\n' strictly before offset.
    const mid = size / 2;
    try pt.insert(mid, "\n");
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());
    try std.testing.expectEqual(@as(usize, mid + 1), pt.lineToOffset(1));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(mid));
    try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(mid + 1));
    try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(mid + 5));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(mid - 1));
    // getLine(k)'s range is [lineToOffset(k), lineToOffset(k+1)), **including line-end '\n'**
    // (see getLine impl: end = lineToOffset(line+1)). So line 0 is content[0..mid] plus the
    // inserted newline, length mid+1, not mid.
    const line_buf = try alloc.alloc(u8, mid + 1);
    defer alloc.free(line_buf);
    const line0 = try pt.getLine(0, line_buf);
    try std.testing.expectEqual(@as(usize, mid + 1), line0.len);
    try std.testing.expectEqualStrings(content[0..mid], line0[0..mid]);
    try std.testing.expectEqual(@as(u8, '\n'), line0[mid]);
    try PieceTreeShape.check(&pt, alloc);
}

test "PieceTree: invalid UTF-8 bytes are stored and returned verbatim" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "\xff", // isolated illegal byte
        "\xc3\x28", // 2-byte lead followed by ASCII (illegal continuation)
        "\xe2\x82", // 3-byte sequence truncated
        "\xf0\x9f\x98", // 4-byte sequence truncated
        "ok\xff\xfe\xc0\x80ok", // Valid + invalid mixed
        "a\xc0\x80b", // NUL overlong encoding
    };

    for (cases) |content| {
        var pt = try PieceTree.initFromBuffer(alloc, std.testing.io, content);
        defer pt.deinit();
        const buf = try alloc.alloc(u8, content.len);
        defer alloc.free(buf);
        try std.testing.expectEqualStrings(content, try pt.getText(0, content.len, buf));

        // After middle insert + delete, bytes unchanged
        try pt.insert(content.len / 2, "\xff");
        try pt.delete(content.len / 2, 1);
        try std.testing.expectEqualStrings(content, try pt.getText(0, content.len, buf));
    }
}

test "PieceTree: invalid UTF-8 does not corrupt byte-exact reads or summary aggregation" {
    const alloc = std.testing.allocator;
    // 3-byte Chinese sequence truncated at buffer end (E4 BD then '\n'):
    // exercises the scanTextStats advance-correction path and a known quirk (see piece_stats.zig
    // module header). The test doesn't hard-code quirk arithmetic; it locks two unambiguous
    // invariants:
    //   1. byte-level read/write is unaffected by multibyte decoding (storage is pure bytes);
    //   2. Summary aggregation matches a single-pass scan of the same buffer (stats self-consistent).
    const tail = "\u{4F60}"[0..2]; // E4 BD (3rd byte missing)
    var content = @as(std.ArrayList(u8), .empty);
    defer content.deinit(alloc);
    try content.appendSlice(alloc, "aaa\n");
    try content.appendSlice(alloc, "\u{4F60}");
    try content.appendSlice(alloc, tail);
    try content.appendSlice(alloc, "\nbbb\n");

    var pt = try PieceTree.initFromBuffer(alloc, std.testing.io, content.items);
    defer pt.deinit();

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(content.items, try pt.getText(0, pt.totalLength(), &buf));
    // line0 pure ASCII, boundary determined by true byte scan (lineToOffsetInNode)
    try std.testing.expectEqualStrings("aaa\n", try pt.getLine(0, &buf));
    // Summary line count == single-pass scan newline_count + 1 (self-consistency in single piece)
    try std.testing.expectEqual(
        PieceTree.scanTextStats(content.items).newline_count + 1,
        pt.lineCount(),
    );

    // snapshot path read-back same bytes
    var snap = try pt.snapshot(alloc);
    defer snap.deinit();
    try std.testing.expectEqualStrings(content.items, try snap.getText(0, snap.totalLength(), &buf));
}

test "PieceTree: offset beyond total clamps instead of panicking" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abc\ndef\n");
    defer pt.deinit();
    try std.testing.expectEqual(@as(usize, 2), pt.offsetToLine(999));
    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));
    // Out-of-range line number degrades to document end (current behavior: returns the last
    // piece's cumulative offset).
    try std.testing.expectEqual(pt.totalLength(), pt.lineToOffset(999));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidRange, pt.getText(9, 1, &tiny));
    try std.testing.expectError(error.InvalidPosition, pt.insert(99, "x"));
    try std.testing.expectError(error.InvalidRange, pt.delete(99, 1));
    // start == total is legal (append at end)
    try pt.insert(pt.totalLength(), "!");
    try std.testing.expectError(error.InvalidLine, pt.getLine(99, &tiny));
}

test "PieceTree: many small edits keep the tree a balanced B-tree" {
    const alloc = std.testing.allocator;
    var pt = try PieceTree.initFromBuffer(alloc, std.testing.io, "");
    defer pt.deinit();

    // Use an exactly replayable string model as oracle: after every edit both full texts match and
    // the tree shape is valid. The LCG makes runs reproducible.
    var model = @as(std.ArrayList(u8), .empty);
    defer model.deinit(alloc);

    var rng = Lcg.init(20260730);
    const alphabet = "abcdefghij\n\n";
    const read_buf = try alloc.alloc(u8, 4096);
    defer alloc.free(read_buf);

    var step: usize = 0;
    while (step < 400) : (step += 1) {
        const op = rng.below(10);
        if (op < 6) {
            // Insert 1..12 chars
            const n = 1 + rng.below(12);
            var tmp: [12]u8 = undefined;
            for (0..n) |i| tmp[i] = alphabet[rng.below(alphabet.len)];
            const pos = if (model.items.len == 0) 0 else rng.below(model.items.len + 1);
            try pt.insert(pos, tmp[0..n]);
            try model.insertSlice(alloc, pos, tmp[0..n]);
        } else if (op < 9 and model.items.len > 0) {
            // Delete 1..40 bytes
            const pos = rng.below(model.items.len);
            const max_del = @min(40, model.items.len - pos);
            const n = 1 + rng.below(max_del);
            try pt.delete(pos, n);
            try model.replaceRange(alloc, pos, n, "");
        } else {
            // Replace: equivalent to delete + insert (covers deleteUnlocked cross-piece branch)
            if (model.items.len == 0) continue;
            const pos = rng.below(model.items.len);
            const max_del = @min(20, model.items.len - pos);
            const n = 1 + rng.below(max_del);
            const insert_n = 1 + rng.below(12);
            var tmp: [12]u8 = undefined;
            for (0..insert_n) |i| tmp[i] = alphabet[rng.below(alphabet.len)];
            try pt.delete(pos, n);
            try model.replaceRange(alloc, pos, n, "");
            try pt.insert(pos, tmp[0..insert_n]);
            try model.insertSlice(alloc, pos, tmp[0..insert_n]);
        }

        // Each step verify: length, full text, line count, longest line, tree shape
        try std.testing.expectEqual(model.items.len, pt.totalLength());
        if (model.items.len > 0) {
            var pos: usize = 0;
            while (pos < model.items.len) {
                const n = @min(read_buf.len, model.items.len - pos);
                try std.testing.expectEqualSlices(u8, model.items[pos .. pos + n], try pt.getText(pos, n, read_buf));
                pos += n;
            }
        }
        var nl: usize = 1;
        for (model.items) |b| {
            if (b == '\n') nl += 1;
        }
        try std.testing.expectEqual(nl, pt.lineCount());

        var longest: u32 = 0;
        var cur: u32 = 0;
        for (model.items) |b| {
            if (b == '\n') {
                if (cur > longest) longest = cur;
                cur = 0;
            } else cur += 1;
        }
        if (cur > longest) longest = cur;
        // Note: PieceTree counts code points, but alphabet all ASCII, same result
        try std.testing.expectEqual(longest, pt.longestRowChars());

        if (step % 40 == 0) try PieceTreeShape.check(&pt, alloc);
    }
    try PieceTreeShape.check(&pt, alloc);
    // Intentionally don't assert piece count magnitude: it depends on merge/split policy (adjacent
    // same-source pieces merge), an implementation detail, not a contract. The loop's value is
    // "text matches the model bytewise each step + PieceTreeShape.check passes", the B-tree
    // invariant. Random sequences can merge below any fixed count (e.g. `count() > 20`).
}

test "PieceTree: document entirely of newlines" {
    const alloc = std.testing.allocator;
    const n: usize = 5000;
    const content = try alloc.alloc(u8, n);
    defer alloc.free(content);
    @memset(content, '\n');

    var pt = try PieceTree.initFromBuffer(alloc, std.testing.io, content);
    defer pt.deinit();
    try std.testing.expectEqual(n, pt.totalLength());
    try std.testing.expectEqual(n + 1, pt.lineCount());
    try std.testing.expectEqual(@as(u32, 0), pt.longestRowChars());
    try PieceTreeShape.check(&pt, alloc);

    // line k start must be k (every line empty)
    var k: usize = 0;
    while (k <= n) : (k += 317) {
        try std.testing.expectEqual(k, pt.lineToOffset(k));
        try std.testing.expectEqual(k, pt.offsetToLine(k));
    }
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("\n", try pt.getLine(0, &buf));
    try std.testing.expectEqualStrings("", try pt.getLine(n, &buf));
}

test "PieceTree: snapshot line coordinates match the live tree" {
    const alloc = std.testing.allocator;
    var pt = try PieceTree.initFromBuffer(alloc, std.testing.io, "l0\nl1\nl2\nl3\n");
    defer pt.deinit();
    try pt.insert(3, "INSERTED\n"); // Multiple pieces
    var snap = try pt.snapshot(alloc);
    defer snap.deinit();

    try std.testing.expectEqual(pt.totalLength(), snap.totalLength());
    try std.testing.expectEqual(pt.lineCount(), snap.lineCount());
    var off: usize = 0;
    while (off <= pt.totalLength()) : (off += 1) {
        try std.testing.expectEqual(pt.offsetToLine(off), snap.offsetToLine(off));
    }
    var line: usize = 0;
    while (line < pt.lineCount()) : (line += 1) {
        try std.testing.expectEqual(pt.lineToOffset(line), snap.lineToOffset(line));
    }
}

test "PieceTree: ChunkIterator seekTo repositions for non-sequential readers" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "0123456789abcdefghij");
    defer pt.deinit();
    try pt.insert(10, "---"); // Create 3 pieces

    const total = pt.totalLength();
    const buf = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(buf);
    // oracle: full forward scan
    const oracle = try pt.getText(0, total, buf);

    // tree-sitter-style nonsequential read: read segment -> seek mid -> read to end -> seek back to
    // head
    var got = @as(std.ArrayList(u8), .empty);
    defer got.deinit(std.testing.allocator);

    var it = pt.chunksInRange(0, total);
    while (it.next()) |c| try got.appendSlice(std.testing.allocator, c);
    try std.testing.expectEqualStrings(oracle, got.items);

    got.clearRetainingCapacity();
    it.seekTo(6, total);
    while (it.next()) |c| try got.appendSlice(std.testing.allocator, c);
    try std.testing.expectEqualStrings(oracle[6..], got.items);

    got.clearRetainingCapacity();
    it.seekTo(0, total);
    while (it.next()) |c| try got.appendSlice(std.testing.allocator, c);
    try std.testing.expectEqualStrings(oracle, got.items);

    // Seek past total: clamp to end, read empty
    it.seekTo(total * 2, total);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "PieceTree: anchors survive a delete that empties the document" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "abcdef");
    defer pt.deinit();
    const a = pt.anchorAtStrict(3, .right);
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a));
    try pt.delete(0, 6);
    // Empty doc: anchor revert to 0 (.right with no best_after lands at doc_offset)
    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(a));
    // anchorAtStrict doesn't panic after empty
    const b = pt.anchorAtStrict(0, .left);
    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(b));
}

test "PieceTree: many-piece insert then full read matches (no newline, 300 pieces)" {
    const alloc = std.testing.allocator;
    var pt = PieceTree.init(alloc, std.testing.io);
    defer pt.deinit();
    var expect = @as(std.ArrayList(u8), .empty);
    defer expect.deinit(alloc);

    // 300 random-position small inserts, create 300+ piece tree (height 2-3)
    var rng = Lcg.init(99);
    var step: usize = 0;
    while (step < 300) : (step += 1) {
        const pos = if (expect.items.len == 0) 0 else rng.below(expect.items.len + 1);
        const c: u8 = @intCast('A' + @as(u32, @intCast(rng.below(26))));
        try pt.insert(pos, &[_]u8{c});
        try expect.insert(alloc, pos, c);
    }
    try std.testing.expectEqual(expect.items.len, pt.totalLength());
    const buf = try alloc.alloc(u8, expect.items.len);
    defer alloc.free(buf);
    try std.testing.expectEqualSlices(u8, expect.items, try pt.getText(0, pt.totalLength(), buf));
    try PieceTreeShape.check(&pt, alloc);
    // Verify offsetToLine per offset (no newlines -> always 0)
    var off: usize = 0;
    while (off <= pt.totalLength()) : (off += 7) {
        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(off));
    }
}

test "PieceTree fragmented range reads match immutable snapshot after COW edit" {
    const allocator = std.testing.allocator;
    const original = (@as([("abcd").len * (256)]u8, @bitCast(@as([256][("abcd").len]u8, @splat(("abcd").*)))) ++ "");
    var tree = try PieceTree.initFromBuffer(allocator, std.testing.io, original);
    defer tree.deinit();
    for (0..256) |i| try tree.insert(i * 6 + 2, "XY");
    const expected = (@as([("abXYcd").len * (256)]u8, @bitCast(@as([256][("abXYcd").len]u8, @splat(("abXYcd").*)))) ++ "");
    var snapshot = try tree.snapshot(allocator);
    defer snapshot.deinit();
    try tree.insert(0, "prefix");
    const live_expected = "prefix" ++ expected;
    var buffer: [live_expected.len]u8 = undefined;
    var start: usize = 0;
    while (start <= expected.len) : (start += 1) {
        for ([_]usize{ 0, @min(@as(usize, 1), expected.len - start), @min(@as(usize, 31), expected.len - start), expected.len - start }) |length| {
            const snap_text = try snapshot.getText(start, length, &buffer);
            try std.testing.expectEqualSlices(u8, expected[start .. start + length], snap_text);
            const live_text = try tree.getText(start + 6, length, &buffer);
            try std.testing.expectEqualSlices(u8, expected[start .. start + length], live_text);
        }
    }
    try std.testing.expectEqualSlices(u8, live_expected, try tree.getText(0, live_expected.len, &buffer));
    try std.testing.expectError(error.InvalidRange, snapshot.getText(expected.len, 1, &buffer));
    try std.testing.expectError(error.BufferTooSmall, tree.getText(0, 2, buffer[0..1]));
}

test "PieceTree public edits never retain zero-byte pieces" {
    var tree = try PieceTree.initFromBuffer(std.testing.allocator, std.testing.io, "");
    defer tree.deinit();
    const Op = struct { start: usize, remove: usize = 0, insert: []const u8 = "" };
    for ([_]Op{
        .{ .start = 0 },
        .{ .start = 0, .insert = "abcdef" },
        .{ .start = 0 },
        .{ .start = 6 },
        .{ .start = 3, .insert = "XYZ" },
        .{ .start = 4, .remove = 1 },
        .{ .start = 2, .remove = 4 },
        .{ .start = 0, .remove = 1 },
        .{ .start = 2, .remove = 1 },
        .{ .start = 0, .remove = 2 },
        .{ .start = 0, .insert = "again" },
        .{ .start = 0, .remove = 5 },
    }) |op| {
        try tree.delete(op.start, op.remove);
        try tree.insert(op.start, op.insert);
        var pieces = tree.tree.iterator();
        var bytes: usize = 0;
        while (pieces.next()) |piece| {
            try std.testing.expect(piece.length > 0);
            bytes += piece.length;
        }
        try std.testing.expectEqual(bytes, tree.totalLength());
        var snapshot = try tree.snapshot(std.testing.allocator);
        defer snapshot.deinit();
        var buffer: [32]u8 = undefined;
        _ = try snapshot.getText(0, bytes, &buffer);
        _ = try tree.getText(0, bytes, &buffer);
    }
}
