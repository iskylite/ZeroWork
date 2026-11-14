//! Host-local observations use the current conversation's authority and a
//! frozen path. They never masquerade as reads from a connection.
const std = @import("std");
const host = @import("host_tools.zig");
const provider = @import("provider.zig");
const paths = @import("../host/local_path.zig");
const reads = @import("../host/local_file_reads.zig");
const scanning = @import("../host/local_file_search.zig");
const workspace = @import("../host/local_workspace.zig");
const ConversationId = @import("../host/identity.zig").ConversationId;
const reference = @import("../host/local_file_reference.zig");
pub const openReference = reference.open;
const sealReference = reference.seal;

pub const path_fields = "\"path\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4095},\"base_directory\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4095,\"description\":\"Absolute Mac directory for a relative path. Omit with an absolute path, a ~/ path, or file_ref.\"}";
const scan_fields = path_fields ++ ",\"glob\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":256},\"cursor\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8192},\"respect_ignores\":{\"type\":\"boolean\"}";
const Kind = enum { read, list, search };
pub const contributions = [_]host.Contribution{
    .{ .authority = .local_files, .definition = .{
        .id = "host.local_read_text",
        .description = "Read UTF-8 text from the Mac, independent of the bound connection. Supply path or an unchanged file_ref. Use next_offset or next_line with the returned version to continue, and never combine pages from different versions. Choose byte pagination with offset or line pagination with start_line and max_lines. Supply expected_version when offset is nonzero or start_line is greater than 1. Omit base_directory with file_ref. A relative path uses the local workspace unless base_directory is specified.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ path_fields ++ ",\"file_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8192},\"offset\":{\"type\":\"integer\",\"minimum\":0},\"start_line\":{\"type\":\"integer\",\"minimum\":1},\"max_lines\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":1000},\"max_bytes\":{\"type\":\"integer\",\"minimum\":4,\"maximum\":8192},\"expected_version\":{\"type\":\"string\",\"minLength\":68,\"maxLength\":68,\"description\":\"Use the exact zw1: version returned by the local read.\"}}}",
    } },
    .{ .authority = .local_files, .definition = .{
        .id = "host.local_list_files",
        .description = "List a directory on the Mac. Omit path to list the preferred local base, or supply a specific directory. Results are a bounded live scan; use next_cursor with the same path and filters.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ scan_fields ++ ",\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":32}}}",
    } },
    .{ .authority = .local_files, .definition = .{
        .id = "host.local_search_text",
        .description = "Search for literal UTF-8 text under a local directory. Use a single-line pattern of at most 256 UTF-8 bytes. Results include file versions and are a bounded live scan, not a stable snapshot. An incomplete scan does not prove there are no more matches.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ scan_fields ++ ",\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":16},\"pattern\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":256},\"context_lines\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":2},\"follow_directory_symlinks\":{\"type\":\"boolean\"}},\"required\":[\"pattern\"]}",
    } },
};
fn classify(id: []const u8) ?Kind {
    for (contributions, std.enums.values(Kind)) |entry, kind| if (std.mem.eql(u8, id, entry.definition.id)) return kind;
    return null;
}
pub fn supports(id: []const u8) bool {
    return classify(id) != null;
}
pub const State = struct {
    workspace: workspace.Snapshot,
    cwd: ?[]const u8 = null,
    home: ?[]const u8 = null,
    app_data_root: ?[]const u8 = null,
    key: [32]u8,
    reference_key: ?[32]u8 = null,
};
const Args = struct {
    path: ?[]const u8 = null,
    base_directory: ?[]const u8 = null,
    file_ref: ?[]const u8 = null,
    offset: ?u64 = null,
    start_line: ?u64 = null,
    max_lines: ?u32 = null,
    max_bytes: usize = 4096,
    expected_version: ?[]const u8 = null,
    glob: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    respect_ignores: bool = true,
    limit: ?usize = null,
    pattern: ?[]const u8 = null,
    follow_directory_symlinks: bool = false,
    context_lines: u8 = 0,
};

pub fn usesPreferredBase(arguments: std.json.Value) bool {
    if (arguments != .object) return false;
    if (arguments.object.contains("file_ref") or arguments.object.contains("base_directory")) return false;
    const value = arguments.object.get("path") orelse return true;
    if (value != .string) return false;
    return !std.fs.path.isAbsolute(value.string) and !std.mem.startsWith(u8, value.string, "~/");
}

pub fn execute(allocator: std.mem.Allocator, io: std.Io, state: State, invocation: host.Invocation, cancel: ?*const provider.CancelToken) !host.Result {
    if (invocation.authority != .local_files) return error.InvalidHostAuthority;
    const kind = classify(invocation.tool_id) orelse return error.InvalidHostAuthority;
    if (usesPreferredBase(invocation.arguments) and invocation.workspace_revision != state.workspace.revision) return error.WorkspaceChanged;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = (try std.json.parseFromValue(Args, a, invocation.arguments, .{})).value;
    const options: paths.Options = .{
        .path = args.path orelse if (kind == .read) null else ".",
        .file_ref = if (args.file_ref) |ref| try openReference(a, state.reference_key orelse return error.LocalFileReferenceUnavailable, invocation.context.conversation_id, ref) else null,
        .base_directory = args.base_directory,
        .workspace = state.workspace,
        .local_cwd = state.cwd,
        .home = state.home,
        .app_data_root = state.app_data_root,
        .conversation = invocation.context.conversation_id,
    };
    const target = paths.resolve(a, io, options, if (kind == .read) .file else .directory) catch |err| {
        const attempted = paths.attempt(a, options) catch null;
        return result(allocator, invocation, .failed, .{
            .error_code = @errorName(err),
            .requested_path = if (attempted) |value| value.requested else args.path,
            .attempted_path = if (attempted) |value| value.absolute else null,
            .base_directory = if (attempted) |value| value.base_directory else null,
        });
    };
    defer target.deinit(a, io);
    const uncancelled: provider.CancelToken = .{};
    const token = cancel orelse &uncancelled;
    if (kind == .list) {
        const page = scanning.list(a, io, &target, .{ .glob = args.glob, .cursor = args.cursor, .respect_ignores = args.respect_ignores, .limit = args.limit orelse scanning.default_entries }, state.key, token) catch |err| return failed(allocator, invocation, target.absolute, err);
        return result(allocator, invocation, .succeeded, page);
    }
    if (kind == .search) {
        const page = scanning.search(a, io, &target, .{ .pattern = args.pattern orelse return error.InvalidArguments, .glob = args.glob, .cursor = args.cursor, .respect_ignores = args.respect_ignores, .limit = args.limit orelse scanning.default_matches, .follow_directory_symlinks = args.follow_directory_symlinks, .context_lines = args.context_lines }, state.key, token) catch |err| return failed(allocator, invocation, target.absolute, err);
        return result(allocator, invocation, .succeeded, page);
    }
    const page = reads.readText(a, io, &target, .{
        .offset = args.offset,
        .start_line = args.start_line,
        .max_lines = args.max_lines,
        .max_bytes = args.max_bytes,
        .expected_version = args.expected_version,
    }, token) catch |err| return failed(allocator, invocation, target.absolute, err);
    return result(allocator, invocation, .succeeded, .{
        .path = target.absolute,
        .requested_path = target.requested,
        .base_directory = target.base_directory,
        .resolution_source = target.source,
        .workspace_revision = target.workspace_revision,
        .text = page.bytes,
        .version = @as([]const u8, &page.version),
        .file_ref = if (state.reference_key) |key| if (page.file_ref) |ref| try sealReference(a, key, ref) else null else null,
        .start_offset = page.start_offset,
        .end_offset = page.end_offset,
        .start_line = page.start_line,
        .end_line = page.end_line,
        .next_offset = page.next_offset,
        .next_line = page.next_line,
        .line_fragment = page.line_fragment,
        .total_bytes = page.total_bytes,
        .truncated = page.truncated,
    });
}

fn failed(a: std.mem.Allocator, invocation: host.Invocation, path: []const u8, err: anyerror) !host.Result {
    return result(a, invocation, if (err == error.Cancelled) .cancelled_unsent else .failed, .{ .error_code = @errorName(err), .path = path });
}

pub fn result(a: std.mem.Allocator, invocation: host.Invocation, status: @import("plugin_tools.zig").Status, body: anytype) !host.Result {
    const encoded = try std.json.Stringify.valueAlloc(a, body, .{});
    errdefer a.free(encoded);
    if (encoded.len > 60 * 1024) return error.ResultLimit;
    const blocks = try a.alloc(host.Block, 1);
    blocks[0] = .{ .structured = encoded };
    return .{ .status = status, .blocks = blocks, .receipt = .{
        .conversation_id = invocation.context.conversation_id,
        .task_id = invocation.context.task_id,
        .operation_id = invocation.operation_id,
        .binding_revision = invocation.context.binding_revision,
    } };
}

test "v0.4.3 local file references cannot be moved to another conversation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conversation: ConversationId = .{ .bytes = @splat(1) };
    const token = try sealReference(a, @splat(7), .{
        .conversation = conversation,
        .requested = "foo",
        .absolute = "/tmp/foo",
        .identity = .{ .device = 4, .inode = 5 },
    });
    try std.testing.expectEqualStrings("/tmp/foo", (try openReference(a, @splat(7), conversation, token)).absolute);
    try std.testing.expectError(error.InvalidFileReference, openReference(a, @splat(7), .{ .bytes = @splat(2) }, token));
    try std.testing.expectError(error.InvalidFileReference, openReference(a, @splat(8), conversation, token));
}
