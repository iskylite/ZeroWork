const std = @import("std");
const Allocator = std.mem.Allocator;

/// Where a piece's text comes from.
pub const Source = enum {
    original, // original file content
    add, // newly added content
};

/// A piece is one fragment of the text.
pub const Piece = struct {
    source: Source,
    start: usize, // start offset in the corresponding buffer
    length: usize, // fragment length

    pub fn end(self: Piece) usize {
        return self.start + self.length;
    }
};

/// Piece linked-list node.
const PieceNode = struct {
    data: Piece,
    next: ?*PieceNode = null,
    prev: ?*PieceNode = null,
};

/// Piece Table text storage engine; efficient insert/delete and O(1) Undo/Redo.
pub const PieceTable = struct {
    allocator: Allocator,

    /// read-only original file content
    original_buffer: []const u8,

    /// buffer holding all added content
    add_buffer: std.ArrayList(u8),

    /// head node of piece list
    head: ?*PieceNode,

    /// tail node of piece list
    tail: ?*PieceNode,

    /// total character count
    total_length: usize,

    /// line index cache (start byte offset of each line)
    line_index: std.ArrayList(usize),

    /// initialize an empty Piece Table
    pub fn init(allocator: Allocator) !PieceTable {
        var line_index = @as(std.ArrayList(usize), .empty);
        try line_index.append(allocator, 0); // the first line starts at offset 0

        return PieceTable{
            .allocator = allocator,
            .original_buffer = &[_]u8{},
            .add_buffer = @as(std.ArrayList(u8), .empty),
            .head = null,
            .tail = null,
            .total_length = 0,
            .line_index = line_index,
        };
    }

    /// Initialize from file content.
    ///
    /// Content is copied once, owned by PieceTable, freed on deinit;
    /// caller can freely release content after this function returns.
    pub fn initFromBuffer(allocator: Allocator, content: []const u8) !PieceTable {
        var self = try init(allocator);
        errdefer self.deinit();

        if (content.len > 0) {
            self.original_buffer = try allocator.dupe(u8, content);

            // create initial piece
            const node = try allocator.create(PieceNode);
            node.* = PieceNode{
                .data = Piece{
                    .source = .original,
                    .start = 0,
                    .length = content.len,
                },
                .next = null,
                .prev = null,
            };

            self.head = node;
            self.tail = node;
            self.total_length = content.len;

            // build line index
            try self.rebuildLineIndex();
        }

        return self;
    }

    pub fn deinit(self: *PieceTable) void {
        // free list nodes
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }

        // original_buffer is owned by this table (copied by initFromBuffer);
        // empty table is len=0 literal, Allocator.free is no-op for len=0.
        self.allocator.free(self.original_buffer);
        self.add_buffer.deinit(self.allocator);
        self.line_index.deinit(self.allocator);
    }

    /// Insert text at the given position.
    pub fn insert(self: *PieceTable, pos: usize, text: []const u8) !void {
        if (text.len == 0) return;
        if (pos > self.total_length) return error.InvalidPosition;

        // append text to add_buffer
        const add_start = self.add_buffer.items.len;
        try self.add_buffer.appendSlice(self.allocator, text);

        const new_piece = Piece{
            .source = .add,
            .start = add_start,
            .length = text.len,
        };

        if (pos == 0) {
            // insert at head
            try self.insertAtHead(new_piece);
        } else if (pos == self.total_length) {
            // insert at tail
            try self.insertAtTail(new_piece);
        } else {
            // insert in the middle (must split a piece)
            try self.insertInMiddle(pos, new_piece);
        }

        self.total_length += text.len;

        // update line index
        try self.updateLineIndexAfterInsert(pos, text);
    }

    /// Delete text in the given range.
    pub fn delete(self: *PieceTable, start: usize, length: usize) !void {
        if (length == 0) return;
        if (start + length > self.total_length) return error.InvalidRange;

        const end_pos = start + length;
        var current_pos: usize = 0;
        var current = self.head;

        // find the piece containing start
        while (current) |node| {
            const piece_end = current_pos + node.data.length;

            if (piece_end > start) {
                // deletion starts here
                break;
            }

            current_pos = piece_end;
            current = node.next;
        }

        // delete the range piece by piece
        while (current) |node| {
            const piece_end = current_pos + node.data.length;

            if (current_pos >= end_pos) {
                // deletion finished
                break;
            }

            if (current_pos < start and piece_end > end_pos) {
                // range inside one piece: split into two
                const offset_start = start - current_pos;
                const offset_end = end_pos - current_pos;

                // create the right half
                const right_piece = Piece{
                    .source = node.data.source,
                    .start = node.data.start + offset_end,
                    .length = node.data.length - offset_end,
                };

                // shrink the current piece to the left half
                node.data.length = offset_start;

                // insert the right half
                const right_node = try self.allocator.create(PieceNode);
                right_node.* = PieceNode{
                    .data = right_piece,
                    .next = node.next,
                    .prev = node,
                };

                if (node.next) |next| {
                    next.prev = right_node;
                } else {
                    self.tail = right_node;
                }

                node.next = right_node;
                break;
            } else if (current_pos >= start and piece_end <= end_pos) {
                // whole piece inside the range: remove it
                const next = node.next;

                if (node.prev) |prev| {
                    prev.next = node.next;
                } else {
                    self.head = node.next;
                }

                if (node.next) |n| {
                    n.prev = node.prev;
                } else {
                    self.tail = node.prev;
                }

                self.allocator.destroy(node);
                current_pos = piece_end;
                current = next;
                continue;
            } else if (current_pos < start) {
                // start is in the middle of the piece
                const offset = start - current_pos;
                node.data.length = offset;
            } else if (piece_end > end_pos) {
                // end is in the middle of the piece
                const offset = end_pos - current_pos;
                node.data.start += offset;
                node.data.length -= offset;
                break;
            }

            current_pos = piece_end;
            current = node.next;
        }

        self.total_length -= length;

        // update line index
        try self.updateLineIndexAfterDelete(start, length);
    }

    /// Get text in the given range.
    pub fn getText(self: *const PieceTable, start: usize, length: usize, buffer: []u8) ![]const u8 {
        if (start + length > self.total_length) return error.InvalidRange;
        if (buffer.len < length) return error.BufferTooSmall;

        var current_pos: usize = 0;
        var copied: usize = 0;
        var current = self.head;

        while (current) |node| : (current = node.next) {
            const piece = node.data;
            const piece_end = current_pos + piece.length;

            // skip irrelevant pieces
            if (piece_end <= start) {
                current_pos = piece_end;
                continue;
            }

            // compute the part to copy
            const copy_start = if (current_pos < start) start - current_pos else 0;
            const copy_end = @min(piece.length, copy_start + (length - copied));
            const copy_len = copy_end - copy_start;

            // copy from the corresponding buffer
            const source_buffer = if (piece.source == .original)
                self.original_buffer
            else
                self.add_buffer.items;

            @memcpy(
                buffer[copied .. copied + copy_len],
                source_buffer[piece.start + copy_start .. piece.start + copy_end],
            );

            copied += copy_len;
            current_pos = piece_end;

            if (copied >= length) break;
        }

        return buffer[0..copied];
    }

    /// Get the total line count.
    pub fn lineCount(self: *const PieceTable) usize {
        return self.line_index.items.len;
    }

    /// Get the content of the given line.
    pub fn getLine(self: *const PieceTable, line: usize, buffer: []u8) ![]const u8 {
        if (line >= self.line_index.items.len) return error.InvalidLine;

        const start = self.line_index.items[line];
        const end = if (line + 1 < self.line_index.items.len)
            self.line_index.items[line + 1]
        else
            self.total_length;

        return self.getText(start, end - start, buffer);
    }

    // ===== private helpers =====

    fn insertAtHead(self: *PieceTable, piece: Piece) !void {
        const node = try self.allocator.create(PieceNode);
        node.* = PieceNode{
            .data = piece,
            .next = self.head,
            .prev = null,
        };

        if (self.head) |head| {
            head.prev = node;
        } else {
            self.tail = node;
        }

        self.head = node;
    }

    fn insertAtTail(self: *PieceTable, piece: Piece) !void {
        const node = try self.allocator.create(PieceNode);
        node.* = PieceNode{
            .data = piece,
            .next = null,
            .prev = self.tail,
        };

        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }

        self.tail = node;
    }

    fn insertInMiddle(self: *PieceTable, pos: usize, new_piece: Piece) !void {
        var current_pos: usize = 0;
        var current = self.head;

        while (current) |node| : (current = node.next) {
            const piece = node.data;
            const piece_end = current_pos + piece.length;

            if (pos == piece_end) {
                // right between the current and next piece: insert the new node here
                const new_node = try self.allocator.create(PieceNode);
                new_node.* = PieceNode{
                    .data = new_piece,
                    .next = node.next,
                    .prev = node,
                };
                if (node.next) |next| {
                    next.prev = new_node;
                } else {
                    self.tail = new_node;
                }
                node.next = new_node;
                return;
            }

            if (pos > current_pos and pos < piece_end) {
                // must split the current piece
                const offset = pos - current_pos;

                // right half
                const right_piece = Piece{
                    .source = piece.source,
                    .start = piece.start + offset,
                    .length = piece.length - offset,
                };

                // shrink the current piece to the left half
                node.data.length = offset;

                // create the new node and the right-half node
                const new_node = try self.allocator.create(PieceNode);
                const right_node = try self.allocator.create(PieceNode);

                new_node.* = PieceNode{
                    .data = new_piece,
                    .next = right_node,
                    .prev = node,
                };

                right_node.* = PieceNode{
                    .data = right_piece,
                    .next = node.next,
                    .prev = new_node,
                };

                if (node.next) |next| {
                    next.prev = right_node;
                } else {
                    self.tail = right_node;
                }

                node.next = new_node;
                return;
            }

            current_pos = piece_end;
        }
    }

    fn rebuildLineIndex(self: *PieceTable) !void {
        self.line_index.clearRetainingCapacity();
        try self.line_index.append(self.allocator, 0);

        var current_pos: usize = 0;
        var current = self.head;

        while (current) |node| : (current = node.next) {
            const piece = node.data;
            const source_buffer = if (piece.source == .original)
                self.original_buffer
            else
                self.add_buffer.items;

            const piece_data = source_buffer[piece.start..piece.end()];

            for (piece_data, 0..) |byte, i| {
                if (byte == '\n') {
                    try self.line_index.append(self.allocator, current_pos + i + 1);
                }
            }

            current_pos += piece.length;
        }
    }

    /// Incremental line index update after insert: just rebuild, simple and reliable, and it avoids
    /// incremental-offset edge bugs.
    fn updateLineIndexAfterInsert(self: *PieceTable, pos: usize, text: []const u8) !void {
        _ = pos;
        _ = text;
        try self.rebuildLineIndex();
    }

    /// Incremental line index update after delete: just rebuild, simple and reliable, and it avoids
    /// incremental-offset edge bugs.
    fn updateLineIndexAfterDelete(self: *PieceTable, start: usize, length: usize) !void {
        _ = start;
        _ = length;
        try self.rebuildLineIndex();
    }
};

// ===== unit tests =====

test "PieceTable: init and deinit" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.total_length);
    try std.testing.expectEqual(@as(usize, 1), table.lineCount());
}

test "PieceTable: init from buffer" {
    const content = "Hello\nWorld\n";
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 12), table.total_length);
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());
}

test "PieceTable: initFromBuffer 拷贝内容,调用方释放原 buffer 后仍可读" {
    const content = try std.testing.allocator.dupe(u8, "Hello\nWorld\n");
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    // Caller frees their buffer immediately; if initFromBuffer borrowed that pointer,
    // all reads after are use-after-free (testing.allocator paints freed memory 0xAA).
    std.testing.allocator.free(content);

    try std.testing.expectEqual(@as(usize, 12), table.total_length);
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 12, &buffer);
    try std.testing.expectEqualStrings("Hello\nWorld\n", text);

    // editing still works on the copied content
    try table.insert(5, "!");
    const after = try table.getText(0, 13, &buffer);
    try std.testing.expectEqualStrings("Hello!\nWorld\n", after);
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());
}

test "PieceTable: insert at beginning" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello");
    try std.testing.expectEqual(@as(usize, 5), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("Hello", text);
}

test "PieceTable: insert at end" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello");
    try table.insert(5, " World");
    try std.testing.expectEqual(@as(usize, 11), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 11, &buffer);
    try std.testing.expectEqualStrings("Hello World", text);
}

test "PieceTable: insert in middle" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try table.insert(5, ",");
    try std.testing.expectEqual(@as(usize, 12), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 12, &buffer);
    try std.testing.expectEqualStrings("Hello, World", text);
}

test "PieceTable: get line" {
    const content = "Line 1\nLine 2\nLine 3\n";
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 4), table.lineCount());

    var buffer: [100]u8 = undefined;

    const line1 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1\n", line1);

    const line2 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 2\n", line2);
}

test "PieceTable: delete from middle" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try table.delete(5, 1); // delete the space
    try std.testing.expectEqual(@as(usize, 10), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 10, &buffer);
    try std.testing.expectEqualStrings("HelloWorld", text);
}

test "PieceTable: delete from beginning" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try table.delete(0, 6); // delete "Hello "
    try std.testing.expectEqual(@as(usize, 5), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("World", text);
}

test "PieceTable: delete from end" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try table.delete(5, 6); // delete " World"
    try std.testing.expectEqual(@as(usize, 5), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("Hello", text);
}

test "PieceTable: delete across pieces" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello");
    try table.insert(5, " World");
    try table.insert(11, "!");

    // 3 pieces now
    try table.delete(3, 5); // delete "lo Wo" spanning two pieces
    try std.testing.expectEqual(@as(usize, 7), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 7, &buffer);
    try std.testing.expectEqualStrings("Helrld!", text);
}

test "PieceTable: incremental line index after insert newline" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try std.testing.expectEqual(@as(usize, 1), table.lineCount());

    // insert a newline in the middle
    try table.insert(5, "\n");
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Hello\n", line0);
    const line1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings(" World", line1);
}

test "PieceTable: incremental line index after insert multiple newlines" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "ABCD");
    try table.insert(2, "\n\n"); // insert two newlines
    // now: "AB\n\nCD"
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("AB\n", line0);
    const line1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", line1);
    const line2 = try table.getLine(2, &buffer);
    try std.testing.expectEqualStrings("CD", line2);
}

test "PieceTable: incremental line index after delete newline" {
    const content = "Line 1\nLine 2\nLine 3";
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    // delete the newline
    try table.delete(6, 1);
    // the two lines merged
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1Line 2\n", line0);
    const line1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 3", line1);
}

test "PieceTable: incremental line index after delete across lines" {
    const content = "AAA\nBBB\nCCC\nDDD";
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 4), table.lineCount());

    // delete across lines
    try table.delete(4, 8);
    // the lines merged
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("AAA\n", line0);
    const line1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("DDD", line1);
}

test "PieceTable: line index consistency through multiple edits" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    // build up several lines step by step
    try table.insert(0, "Line 1\n");
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    try table.insert(7, "Line 2\n");
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    try table.insert(14, "Line 3");
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    // check each line
    var buffer: [100]u8 = undefined;
    const l0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1\n", l0);
    const l1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 2\n", l1);
    const l2 = try table.getLine(2, &buffer);
    try std.testing.expectEqualStrings("Line 3", l2);

    // check the full text
    const full_before = try table.getText(0, table.total_length, &buffer);
    try std.testing.expectEqualStrings("Line 1\nLine 2\nLine 3", full_before);

    // delete the middle line
    try table.delete(7, 7); // delete "Line 2\n"
    try std.testing.expectEqual(@as(usize, 13), table.total_length);

    // check the text after deletion
    const full_after = try table.getText(0, table.total_length, &buffer);
    try std.testing.expectEqualStrings("Line 1\nLine 3", full_after);

    try std.testing.expectEqual(@as(usize, 2), table.lineCount());
    const new_l1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 3", new_l1);
}

test "PieceTable: consecutive newline inserts (simulating Enter key)" {
    // start from text that ends with a newline
    var table = try PieceTable.initFromBuffer(std.testing.allocator, "Press hello\n");
    defer table.deinit();

    var buffer: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    // press Enter at the end
    try table.insert(11, "\n");
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());
    const l0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Press hello\n", l0);
    const l1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", l1);

    // Cursor now at offset 12 (start of line 3), press Enter again
    try table.insert(12, "\n");
    try std.testing.expectEqual(@as(usize, 4), table.lineCount());
    const l1b = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", l1b);
    const l2b = try table.getLine(2, &buffer);
    try std.testing.expectEqualStrings("\n", l2b);
    const l3b = try table.getLine(3, &buffer);
    try std.testing.expectEqualStrings("", l3b);

    // Press Enter again, offset 13
    try table.insert(13, "\n");
    try std.testing.expectEqual(@as(usize, 5), table.lineCount());

    // Verify full text
    const full = try table.getText(0, table.total_length, &buffer);
    try std.testing.expectEqualStrings("Press hello\n\n\n\n", full);
}

test "PieceTable: insert newline at line start" {
    // Test scenario: text 'ABC', insert \n at offset 0 repeatedly
    var table = try PieceTable.initFromBuffer(std.testing.allocator, "ABC");
    defer table.deinit();

    var buffer: [256]u8 = undefined;

    // Insert \n at offset 0 -> '\nABC'
    try table.insert(0, "\n");
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());
    const l0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("\n", l0);
    const l1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("ABC", l1);

    // Cursor at offset 1 (start of line 2), insert \n again -> '\n\nABC'
    try table.insert(1, "\n");
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());
    const l1b = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", l1b);
    const l2b = try table.getLine(2, &buffer);
    try std.testing.expectEqualStrings("ABC", l2b);

    const full = try table.getText(0, table.total_length, &buffer);
    try std.testing.expectEqualStrings("\n\nABC", full);
}
