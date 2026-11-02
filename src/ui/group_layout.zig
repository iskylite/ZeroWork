//! Binary native splits. Leaves own session identities, never protocol objects.
//! Serialized leaves are ordered member slots, rebound to live IDs on restore.
const std = @import("std");
pub const Layout = enum { side_by_side, stacked };
pub const Edge = enum { left, right, top, bottom };
pub const Split = struct { axis: Layout, ratio: f32 = 0.5, first: u32, second: u32 };
pub const Node = union(enum) { empty, leaf: u64, split: Split };
pub const Snapshot = struct { version: u32 = 2, layout: Layout, root: u32, nodes: []const Node };
pub const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    root: ?u32 = null,
    pub fn deinit(self: *Tree, a: std.mem.Allocator) void {
        self.nodes.deinit(a);
    }
    fn allocate(self: *Tree, a: std.mem.Allocator, node: Node) !u32 {
        for (self.nodes.items, 0..) |entry, i| if (entry == .empty) {
            self.nodes.items[i] = node;
            return @intCast(i);
        };
        const id: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(a, node);
        return id;
    }
    pub fn count(self: *const Tree) usize {
        var total: usize = 0;
        for (self.nodes.items) |node| if (node == .leaf) {
            total += 1;
        };
        return total;
    }
    pub fn find(self: *const Tree, session: u64) ?u32 {
        for (self.nodes.items, 0..) |node, i| if (node == .leaf and node.leaf == session) return @intCast(i);
        return null;
    }
    fn prune(self: *Tree, id: u32, members: []const u64) ?u32 {
        switch (self.nodes.items[id]) {
            .empty => return null,
            .leaf => |session| {
                if (std.mem.indexOfScalar(u64, members, session) != null) return id;
                self.nodes.items[id] = .empty;
                return null;
            },
            .split => |split| {
                const first = self.prune(split.first, members);
                const second = self.prune(split.second, members);
                if (first != null and second != null) {
                    self.nodes.items[id].split.first = first.?;
                    self.nodes.items[id].split.second = second.?;
                    return id;
                }
                self.nodes.items[id] = .empty;
                return first orelse second;
            },
        }
    }
    pub fn sync(self: *Tree, a: std.mem.Allocator, members: []const u64, axis: Layout) !void {
        if (self.root) |id| self.root = self.prune(id, members);
        for (members) |session| if (self.find(session) == null) try self.append(a, session, axis);
    }
    pub fn append(self: *Tree, a: std.mem.Allocator, session: u64, axis: Layout) !void {
        if (self.find(session) != null) return;
        const n: f32 = @floatFromInt(self.count());
        try self.nodes.ensureUnusedCapacity(a, 2);
        const leaf = try self.allocate(a, .{ .leaf = session });
        self.root = if (self.root) |root| try self.allocate(a, .{ .split = .{ .axis = axis, .ratio = n / (n + 1), .first = root, .second = leaf } }) else leaf;
    }
    pub fn arrange(self: *Tree, a: std.mem.Allocator, members: []const u64, axis: Layout) !void {
        try self.nodes.ensureTotalCapacity(a, members.len * 2);
        self.nodes.clearRetainingCapacity();
        self.root = null;
        for (members) |session| try self.append(a, session, axis);
    }
    /// Dock one existing leaf at an edge of another. Removing the old parent
    /// collapses its empty branch; unrelated split ratios remain unchanged.
    pub fn dock(self: *Tree, a: std.mem.Allocator, source: u64, target: u64, edge: Edge) !void {
        if (source == target or self.find(source) == null or self.find(target) == null) return;
        try self.nodes.ensureUnusedCapacity(a, 2);
        var members: std.ArrayList(u64) = .empty;
        defer members.deinit(a);
        for (self.nodes.items) |node| if (node == .leaf and node.leaf != source) try members.append(a, node.leaf);
        self.root = self.prune(self.root.?, members.items);
        const target_id = self.find(target).?;
        const first = try self.allocate(a, .{ .leaf = if (edge == .left or edge == .top) source else target });
        const second = try self.allocate(a, .{ .leaf = if (edge == .left or edge == .top) target else source });
        self.nodes.items[target_id] = .{ .split = .{ .axis = if (edge == .top or edge == .bottom) .stacked else .side_by_side, .first = first, .second = second } };
    }
    pub fn minimum(self: *const Tree, id: u32, axis: Layout) f32 {
        return switch (self.nodes.items[id]) {
            .leaf => if (axis == .stacked) 100 else 160,
            .empty => 0,
            .split => |split| if (split.axis == axis) self.minimum(split.first, axis) + self.minimum(split.second, axis) + 4 else @max(self.minimum(split.first, axis), self.minimum(split.second, axis)),
        };
    }
};
pub fn resized(first: f32, total: f32, delta: f32, first_min: f32, second_min: f32) f32 {
    if (total <= 0) return 0.5;
    const scale = @min(@as(f32, 1), total / @max(1, first_min + second_min));
    return std.math.clamp((first + delta) / total, @max(0.001, first_min * scale / total), @min(0.999, 1 - second_min * scale / total));
}
pub fn leafCount(snapshot: Snapshot) usize {
    var count: usize = 0;
    for (snapshot.nodes) |node| if (node == .leaf) {
        count += 1;
    };
    return count;
}
pub fn valid(snapshot: Snapshot) bool {
    if (snapshot.version != 2 or snapshot.nodes.len == 0 or snapshot.nodes.len > 8192 or snapshot.root >= snapshot.nodes.len) return false;
    var seen = std.bit_set.StaticBitSet(8192).empty;
    const Visit = struct {
        fn visit(s: Snapshot, id: u32, depth: usize, seen_: *std.bit_set.StaticBitSet(8192)) bool {
            if (depth > 128 or id >= s.nodes.len or seen_.isSet(id)) return false;
            seen_.set(id);
            return switch (s.nodes[id]) {
                .empty => false,
                .leaf => |slot| slot > 0 and slot <= leafCount(s),
                .split => |split| std.math.isFinite(split.ratio) and split.ratio >= 0.001 and split.ratio <= 0.999 and visit(s, split.first, depth + 1, seen_) and visit(s, split.second, depth + 1, seen_),
            };
        }
    };
    if (!Visit.visit(snapshot, snapshot.root, 0, &seen)) return false;
    var leaves = std.bit_set.StaticBitSet(8192).empty;
    for (snapshot.nodes, 0..) |node, i| {
        if (node != .empty and !seen.isSet(i)) return false;
        if (node == .leaf) {
            const slot: usize = @intCast(node.leaf - 1);
            if (leaves.isSet(slot)) return false;
            leaves.set(slot);
        }
    }
    return true;
}
pub fn path(a: std.mem.Allocator, hosts_path: []const u8, name: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(a, "{s}/session-group-layouts/{s}.json", .{ std.fs.path.dirname(hosts_path) orelse ".", hex });
}
pub fn save(a: std.mem.Allocator, io: std.Io, file_path: []const u8, snapshot: Snapshot) !void {
    if (!valid(snapshot)) return error.InvalidGroupLayout;
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, file_path, .{ .make_path = true, .replace = true, .permissions = .fromMode(0o600) });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}
test "mixed group tree docks four sessions into independent left and right stacks" {
    const a = std.testing.allocator;
    var tree: Tree = .{};
    defer tree.deinit(a);
    try tree.sync(a, &.{ 1, 2, 3, 4 }, .side_by_side);
    try tree.dock(a, 1, 2, .top);
    try tree.dock(a, 3, 4, .top);
    const root = tree.nodes.items[tree.root.?].split;
    try std.testing.expectEqual(Layout.side_by_side, root.axis);
    try std.testing.expectEqual(Layout.stacked, tree.nodes.items[root.first].split.axis);
    try std.testing.expectEqual(Layout.stacked, tree.nodes.items[root.second].split.axis);
    tree.nodes.items[root.first].split.ratio = 0.65;
    tree.nodes.items[root.second].split.ratio = 0.3;
    try std.testing.expectEqual(@as(f32, 0.65), tree.nodes.items[root.first].split.ratio);
    try tree.sync(a, &.{ 1, 3, 4 }, .side_by_side);
    try std.testing.expect(tree.find(2) == null);
    try std.testing.expectEqual(@as(usize, 3), tree.count());
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), resized(300, 600, 90, 160, 160), 0.001);
}
test "mixed group layout rejects cycles and round trips its split tree" {
    const a = std.testing.allocator;
    var tree: Tree = .{};
    defer tree.deinit(a);
    try tree.sync(a, &.{ 1, 2, 3, 4 }, .side_by_side);
    try tree.dock(a, 1, 2, .top);
    const snapshot: Snapshot = .{ .layout = .side_by_side, .root = tree.root.?, .nodes = tree.nodes.items };
    try std.testing.expect(valid(snapshot));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const destination = try std.fs.path.join(a, &.{ directory, "split.json" });
    defer a.free(destination);
    try save(a, std.testing.io, destination, snapshot);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, destination, a, .limited(1024 * 1024));
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Snapshot, a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(valid(parsed.value));
    tree.nodes.items[tree.root.?].split.first = tree.root.?;
    try std.testing.expect(!valid(snapshot));
}
