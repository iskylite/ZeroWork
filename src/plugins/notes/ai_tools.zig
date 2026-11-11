//! Built-in, read-only notes capabilities. The only data source is committed
//! notes that the knowledge base owner has enabled for assistant access.
const std = @import("std");
const host = @import("../../ai/host_tools.zig");
const assets = @import("assets.zig");
const query = @import("queries.zig");
const Allocator = std.mem.Allocator;

const id_schema = "{\"type\":\"string\",\"minLength\":32,\"maxLength\":32}";
const library = "\"library_id\":" ++ id_schema;
const folder = "\"folder_id\":" ++ id_schema;
const note = "\"note_id\":" ++ id_schema;
const revision = "\"expected_revision\":{\"type\":\"integer\",\"minimum\":1}";
const cursor = "\"cursor\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":256}";
const object = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{";

pub const contributions = [_]host.Contribution{
    tool(.list, "List authorized knowledge bases, or one folder's immediate children. Pass the returned cursor to continue.", object ++ library ++ "," ++ folder ++ "," ++ cursor ++ "}}"),
    tool(.search, "Find committed notes by short literal keywords, such as a configuration name or two Chinese characters. Results include source_ref for citation.", object ++ "\"query\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":256},\"library_ids\":{\"type\":\"array\",\"maxItems\":64,\"uniqueItems\":true,\"items\":" ++ id_schema ++ "}," ++ folder ++ "," ++ cursor ++ ",\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":20}},\"required\":[\"query\"]}"),
    tool(.read, "Read committed Markdown from an authorized note. To continue, pass next_byte as start_byte with the same expected_revision.", object ++ note ++ "," ++ revision ++ ",\"start_byte\":{\"type\":\"integer\",\"minimum\":0},\"max_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":32768}},\"required\":[\"note_id\"]}"),
    tool(.read_image, "Read one image explicitly referenced by the committed, authorized note at expected_revision.", object ++ note ++ "," ++ revision ++ ",\"asset_ref\":{\"type\":\"string\",\"maxLength\":128}},\"required\":[\"note_id\",\"expected_revision\",\"asset_ref\"]}"),
};

const Kind = enum { list, search, read, read_image };
fn tool(comptime kind: Kind, description: []const u8, schema: []const u8) host.Contribution {
    return .{ .authority = .conversation_context, .definition = .{
        .id = "host.notes_" ++ @tagName(kind),
        .description = description,
        .schema = schema,
        .effect = if (kind == .read_image) .observe_image else .read_state,
    } };
}

fn kindFor(id: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, std.mem.cutPrefix(u8, id, "host.notes_") orelse return null);
}

pub fn supports(id: []const u8) bool {
    return kindFor(id) != null;
}

pub fn available(queries: query.Queries, a: Allocator, vision: bool) ![]const host.Contribution {
    if (!try queries.hasReadableLibrary(a, null)) return &.{};
    return contributions[0 .. contributions.len - @intFromBool(!vision)];
}

pub const Validate = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) anyerror!void,
};

pub fn execute(queries: query.Queries, invocation: host.Invocation, a: Allocator, cancel: ?*const query.CancelToken, validate: ?Validate) !host.Result {
    if (invocation.authority != .conversation_context) return error.InvalidHostAuthority;
    const kind = kindFor(invocation.tool_id) orelse return error.ToolNotAvailable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var guard: query.Guard = undefined;
    var result = switch (kind) {
        .list => try text(a, invocation, try queries.list(scratch, .assistant, try parse(query.ListArgs, scratch, invocation.arguments), cancel), &guard),
        .search => try text(a, invocation, try queries.search(scratch, .assistant, try parse(query.SearchArgs, scratch, invocation.arguments), cancel), &guard),
        .read => try text(a, invocation, try queries.read(scratch, .assistant, try parse(query.ReadArgs, scratch, invocation.arguments), cancel), &guard),
        .read_image => try image(queries, a, scratch, invocation, cancel, &guard),
    };
    errdefer result.deinit(a);
    if (validate) |callback| try callback.run(callback.context);
    try queries.revalidate(.assistant, guard, cancel);
    const packet = try a.create(Delivery);
    errdefer a.destroy(packet);
    packet.* = .{
        .queries = queries,
        .guard = .{ .access = guard.access, .target = guard.target, .fences = try a.dupe(@import("store.zig").QueryFence, guard.fences) },
    };
    result.delivery_check = .{ .context = packet, .verify = Delivery.verify, .release = Delivery.release };
    return result;
}

const Delivery = struct {
    queries: query.Queries,
    guard: query.Guard,

    fn verify(raw: *anyopaque) !void {
        const self: *Delivery = @ptrCast(@alignCast(raw));
        try self.queries.revalidate(.assistant, self.guard, null);
    }

    fn release(raw: *anyopaque, a: Allocator) void {
        const self: *Delivery = @ptrCast(@alignCast(raw));
        a.free(self.guard.fences);
        a.destroy(self);
    }
};

fn parse(comptime T: type, a: Allocator, value: std.json.Value) !T {
    return std.json.parseFromValueLeaky(T, a, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArguments,
    };
}

fn success(invocation: host.Invocation) host.Result {
    return .{ .status = .succeeded, .receipt = .{
        .conversation_id = invocation.context.conversation_id,
        .task_id = invocation.context.task_id,
        .binding_revision = invocation.context.binding_revision,
        .operation_id = invocation.operation_id,
    } };
}

fn text(a: Allocator, invocation: host.Invocation, checked: anytype, guard: *query.Guard) !host.Result {
    const body = try std.json.Stringify.valueAlloc(a, checked.value, .{});
    errdefer a.free(body);
    if (body.len > 64 * 1024) return error.ResultLimit;
    const blocks = try a.alloc(host.Block, 1);
    blocks[0] = .{ .structured = body };
    guard.* = checked.guard;
    var result = success(invocation);
    result.blocks = blocks;
    return result;
}

fn image(queries: query.Queries, a: Allocator, scratch: Allocator, invocation: host.Invocation, cancel: ?*const query.CancelToken, guard: *query.Guard) !host.Result {
    const args = try parse(query.ImageArgs, scratch, invocation.arguments);
    const checked = try queries.prepareImage(scratch, .assistant, args, cancel);
    const never_cancel: query.CancelToken = .{};
    var reference = try assets.readReferenced(a, queries.store, checked.value.key.library_id, checked.value.body_md, checked.value.asset_ref, cancel orelse &never_cancel, .{});
    errdefer reference.release();
    const images = try a.alloc(@TypeOf(reference), 1);
    images[0] = reference;
    guard.* = checked.guard;
    var result = success(invocation);
    result.images = images;
    return result;
}

test "notes host tools hide unavailable libraries and revoke a prepared result" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try @import("store.zig").Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library_id = try store.createLibrary("工作");
    const key = try store.createNote(library_id, null, "约定");
    _ = try store.changeNote(key, 1, .{ .save = .{ .title = "约定", .body_md = "证书续期" } });
    const queries: query.Queries = .{ .store = &store };
    try std.testing.expectEqual(@as(usize, 0), (try available(queries, a, true)).len);

    const payload = try std.json.Stringify.valueAlloc(a, .{ .note_id = key.note_id }, .{});
    defer a.free(payload);
    const args = try std.json.parseFromSlice(std.json.Value, a, payload, .{});
    defer args.deinit();
    const invocation: host.Invocation = .{
        .context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 },
        .authority = .conversation_context,
        .operation_id = 1,
        .turn_id = 1,
        .call_id = "call",
        .tool_id = contributions[@backingInt(Kind.read)].definition.id,
        .arguments = args.value,
        .arguments_json = payload,
        .arguments_hash = @splat(0),
        .canonical_arguments_hash = @splat(0),
    };
    try std.testing.expectError(error.Unavailable, execute(queries, invocation, a, null, null));
    _ = try store.changeLibrary(library_id, 1, .{ .ai_readable = true });
    try std.testing.expectEqual(@as(usize, 3), (try available(queries, a, false)).len);
    try std.testing.expectEqual(@as(usize, 4), (try available(queries, a, true)).len);
    var result = try execute(queries, invocation, a, null, null);
    var result_owned = true;
    defer if (result_owned) result.deinit(a);
    try result.validate(invocation.context, invocation.operation_id);
    try std.testing.expect(std.mem.indexOf(u8, result.blocks[0].structured, "证书续期") != null);
    const loop_mod = @import("../../ai/tool_loop.zig");
    var loop = loop_mod.Loop.init(a, .{ .owner = invocation.context.binding, .members = .{} }, invocation.turn_id, .{});
    defer loop.deinit();
    try loop.start(.{ .model = "fixture", .system = "", .messages = &.{} });
    try loop.messages.append(loop.arena.allocator(), .{ .role = .tool, .content = result.blocks[0].structured, .tool_call_id = invocation.call_id });
    try loop.records.append(loop.arena.allocator(), .{
        .key = .{ .owner = invocation.context.binding, .turn_id = invocation.turn_id, .call_id = invocation.call_id },
        .name = invocation.tool_id,
        .arguments = invocation.arguments_json,
        .arguments_hash = invocation.arguments_hash,
        .host_result = result,
    });
    result_owned = false;
    const allowed_wire = try loop.nextRequest();
    try std.testing.expect(std.mem.indexOf(u8, allowed_wire.messages[0].content, "证书续期") != null);

    const Revoke = struct {
        store: *@import("store.zig").Store,
        library_id: @import("model.zig").LibraryId,

        fn run(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.store.changeLibrary(self.library_id, 2, .{ .ai_readable = false });
        }
    };
    var revoke: Revoke = .{ .store = &store, .library_id = library_id };
    try std.testing.expectError(error.Unavailable, execute(queries, invocation, a, null, .{ .context = &revoke, .run = Revoke.run }));
    const delivery = result.delivery_check.?;
    try std.testing.expectError(error.Unavailable, delivery.verify(delivery.context));
    const blocked_wire = try loop.nextRequest();
    try std.testing.expectEqualStrings("{\"status\":\"rejected\",\"error_code\":\"Unavailable\"}", blocked_wire.messages[0].content);
}
