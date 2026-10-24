const std = @import("std");
const Allocator = std.mem.Allocator;

/// Edit operation type
pub const OpType = enum {
    insert,
    delete,
};

/// Edit operation record
pub const Operation = struct {
    op_type: OpType,
    position: usize,
    length: usize,
    text: ?[]const u8, // For delete operations, store deleted text
    group_id: u32 = 0, // When nonzero, operations with same group_id undo/redo together

    pub fn deinit(self: *Operation, allocator: Allocator) void {
        if (self.text) |text| {
            allocator.free(text);
        }
    }
};

/// Undo/Redo stack
/// Based on Piece Table immutability, we can store operation history lightweight
pub const UndoStack = struct {
    allocator: Allocator,
    undo_stack: std.ArrayList(Operation),
    redo_stack: std.ArrayList(Operation),
    max_size: usize,
    next_group_id: u32 = 1,
    version: u32 = 0,

    pub fn init(allocator: Allocator, max_size: usize) UndoStack {
        return UndoStack{
            .allocator = allocator,
            .undo_stack = @as(std.ArrayList(Operation), .empty),
            .redo_stack = @as(std.ArrayList(Operation), .empty),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *UndoStack) void {
        for (self.undo_stack.items) |*op| {
            op.deinit(self.allocator);
        }
        for (self.redo_stack.items) |*op| {
            op.deinit(self.allocator);
        }
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    /// Push new operation (also clear redo stack).
    /// Ownership: success -> op (with its text) owned by stack; error -> caller still owns
    /// (but redo stack cleared, redo invalidated - conservative and harmless).
    pub fn push(self: *UndoStack, op: Operation) !void {
        // Clear redo stack
        for (self.redo_stack.items) |*redo_op| {
            redo_op.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();

        // Push undo stack
        try self.undo_stack.append(self.allocator, op);
        self.version +%= 1;

        // Limit stack size
        if (self.undo_stack.items.len > self.max_size) {
            var removed = self.undo_stack.orderedRemove(0);
            removed.deinit(self.allocator);
        }
    }

    /// Single undo.
    /// Ownership: returned Operation transferred to caller (call op.deinit(allocator)); redo stack
    /// keeps independent copy, not shared (contrast textarea snapshot stack ownership).
    /// Transient OOM returns null, state unchanged: op stays in undo stack, can retry.
    pub fn undo(self: *UndoStack) ?Operation {
        if (self.undo_stack.items.len == 0) return null;

        // Finish all possibly-failing allocations first; any fail -> no state mutation (op not
        // lost, not leaked).
        self.redo_stack.ensureUnusedCapacity(self.allocator, 1) catch return null;
        const top = self.undo_stack.items[self.undo_stack.items.len - 1];
        var stack_copy = top;
        if (top.text) |text| {
            stack_copy.text = self.allocator.dupe(u8, text) catch return null;
        }

        const op = self.undo_stack.pop().?;
        self.redo_stack.appendAssumeCapacity(stack_copy);
        self.version +%= 1;
        return op;
    }

    /// Single redo. Ownership contract same as undo: return to caller, undo stack stores
    /// independent copy;
    /// transient OOM returns null, state unchanged.
    pub fn redo(self: *UndoStack) ?Operation {
        if (self.redo_stack.items.len == 0) return null;

        self.undo_stack.ensureUnusedCapacity(self.allocator, 1) catch return null;
        const top = self.redo_stack.items[self.redo_stack.items.len - 1];
        var stack_copy = top;
        if (top.text) |text| {
            stack_copy.text = self.allocator.dupe(u8, text) catch return null;
        }

        const op = self.redo_stack.pop().?;
        self.undo_stack.appendAssumeCapacity(stack_copy);
        self.version +%= 1;
        return op;
    }

    pub fn canUndo(self: *UndoStack) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *UndoStack) bool {
        return self.redo_stack.items.len > 0;
    }
};

/// One-shot failing allocator: armed (fail_next=true) causes next allocation to fail once,
/// then normal. std.testing.FailingAllocator on first fail **permanently** fails
/// (alloc_index increments only on success), to simulate 'transient OOM then recover' use this
/// kind.
const OneShotFailingAllocator = struct {
    backing: Allocator,
    fail_next: bool = false,

    fn allocator(self: *OneShotFailingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn consumeArm(self: *OneShotFailingAllocator) bool {
        if (self.fail_next) {
            self.fail_next = false;
            return true;
        }
        return false;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.consumeArm()) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.consumeArm()) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.consumeArm()) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "UndoStack: 瞬时 OOM 下 undo 不丢操作" {
    var one_shot = OneShotFailingAllocator{ .backing = std.testing.allocator };
    const alloc = one_shot.allocator();

    var stack = UndoStack.init(alloc, 100);
    defer stack.deinit();

    const text = try alloc.dupe(u8, "hello");
    try stack.push(.{ .op_type = .delete, .position = 0, .length = 5, .text = text });

    // Make undo's next allocation fail once (transient OOM, then recover).
    one_shot.fail_next = true;
    try std.testing.expect(stack.undo() == null);

    // op must still in undo stack: neither lose operation nor leak text.
    try std.testing.expect(stack.canUndo());
    try std.testing.expect(!stack.canRedo());

    // Retry after OOM recovery must succeed.
    var op = stack.undo() orelse return error.TestUnexpectedResult;
    defer op.deinit(alloc);
    try std.testing.expectEqualStrings("hello", op.text.?);
    try std.testing.expect(!stack.canUndo());
    try std.testing.expect(stack.canRedo());
}

test "UndoStack: undo/redo 返回的 op 所有权归调用方,与栈内副本不共享内存" {
    var stack = UndoStack.init(std.testing.allocator, 100);
    defer stack.deinit();

    const text = try std.testing.allocator.dupe(u8, "abc");
    try stack.push(.{ .op_type = .delete, .position = 0, .length = 3, .text = text });

    var undone = stack.undo() orelse return error.TestUnexpectedResult;
    // Caller frees their copy. If returned value and redo stack share same text pointer,
    // later redo/deinit double-free, testing.allocator catches.
    undone.deinit(std.testing.allocator);

    try std.testing.expect(stack.canRedo());

    var redone = stack.redo() orelse return error.TestUnexpectedResult;
    redone.deinit(std.testing.allocator);

    try std.testing.expect(stack.canUndo());
    try std.testing.expect(!stack.canRedo());
}

test "UndoStack: 返回的 op 在后续 push 清空 redo 栈后仍有效" {
    var stack = UndoStack.init(std.testing.allocator, 100);
    defer stack.deinit();

    const t1 = try std.testing.allocator.dupe(u8, "first");
    try stack.push(.{ .op_type = .delete, .position = 0, .length = 5, .text = t1 });

    var undone = stack.undo() orelse return error.TestUnexpectedResult;
    defer undone.deinit(std.testing.allocator);

    // push clears redo stack. If undone.text shared pointer with redo entry,
    // reading undone.text later is use-after-free.
    const t2 = try std.testing.allocator.dupe(u8, "second");
    try stack.push(.{ .op_type = .insert, .position = 0, .length = 6, .text = t2 });

    try std.testing.expectEqualStrings("first", undone.text.?);
}

test "UndoStack: basic operations" {
    var stack = UndoStack.init(std.testing.allocator, 100);
    defer stack.deinit();

    try std.testing.expect(!stack.canUndo());
    try std.testing.expect(!stack.canRedo());

    try stack.push(Operation{
        .op_type = .insert,
        .position = 0,
        .length = 5,
        .text = null,
    });

    try std.testing.expect(stack.canUndo());
    try std.testing.expect(!stack.canRedo());

    _ = stack.undo();
    try std.testing.expect(!stack.canUndo());
    try std.testing.expect(stack.canRedo());
}
