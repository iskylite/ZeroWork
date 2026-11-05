//! Only terminal providers contribute these tools; images are display-only UI IO.
const std = @import("std");
const tools = @import("plugin_tools.zig");
const files = @import("../host/terminal_files.zig");
pub const Arguments = struct {
    session_ids: []const u64,
    path: []const u8,
    text: []const u8 = "",
    mode: enum { create, replace } = .create,
    expected_version: []const u8 = "",
    edits: []const files.Edit = &.{},
    offset: usize = 0,
    max_bytes: usize = 4096,
};
const target = "\"session_ids\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":1,\"uniqueItems\":true,\"items\":{\"type\":\"integer\",\"minimum\":1}},\"path\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4096}";
const expected = "\"expected_version\":{\"type\":\"string\",\"minLength\":64,\"maxLength\":64}";
pub const definitions = [_]tools.ToolDefinition{
    .{ .id = "file.read_text", .description = "Read one UTF-8 text file on the selected Local/SSH terminal host, without SFTP or the interactive PTY. Files are limited to 65536 bytes. Returns a page and an exact host/path/content version; continue with offset and expected_version. Relative paths require a known captured cwd. This does not access files inside a foreground sudo/container/nested SSH environment.", .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ target ++ "," ++ expected ++ ",\"offset\":{\"type\":\"integer\",\"minimum\":0},\"max_bytes\":{\"type\":\"integer\",\"minimum\":4,\"maximum\":8192}},\"required\":[\"session_ids\",\"path\"]}", .validate = validate },
    .{ .id = "file.write_text", .description = "Create or fully replace one UTF-8 text file (65536 bytes maximum) on a Local/SSH terminal host. Default mode=create fails if the target exists. mode=replace requires expected_version from file.read_text. Never overwrite a file using a truncated page as its full contents. Permissions and exact target are checked; no sudo/SFTP. Returns committed/verified/outcome-unknown facts; never retry an uncertain write automatically.", .effect = .resource_write, .approval_policy = .confirm, .max_argument_bytes = 512 * 1024, .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ target ++ "," ++ expected ++ ",\"mode\":{\"type\":\"string\",\"enum\":[\"create\",\"replace\"]},\"text\":{\"type\":\"string\",\"maxLength\":65536}},\"required\":[\"session_ids\",\"path\",\"text\"]}", .validate = validate },
    .{ .id = "file.edit_text", .description = "Edit one Local/SSH UTF-8 text file using an exact expected_version. Each nonempty old_text must match exactly once in the original file; edits must not overlap. All edits are validated before a single staged commit. Preserves unchanged bytes, BOM and line endings; no fuzzy matching, implicit privilege escalation or SFTP. A stale version rejects the entire operation.", .effect = .resource_write, .approval_policy = .confirm, .max_argument_bytes = 512 * 1024, .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ target ++ "," ++ expected ++ ",\"edits\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":128,\"items\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"old_text\":{\"type\":\"string\",\"minLength\":1},\"new_text\":{\"type\":\"string\"}},\"required\":[\"old_text\",\"new_text\"]}}},\"required\":[\"session_ids\",\"path\",\"expected_version\",\"edits\"]}", .validate = validate },
};
fn validate(value: std.json.Value) !void {
    const path = value.object.get("path").?.string;
    if (std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return error.InvalidToolArguments;
    if (value.object.get("mode")) |mode| if (std.mem.eql(u8, mode.string, "replace") and value.object.get("expected_version") == null) return error.InvalidToolArguments;
    if (value.object.get("offset")) |offset| if (offset.integer != 0 and value.object.get("expected_version") == null) return error.InvalidToolArguments;
}
pub fn request(name: []const u8, args: Arguments) !files.Request {
    const kind: files.Kind = if (std.mem.eql(u8, name, "file.read_text")) .read_text else if (std.mem.eql(u8, name, "file.write_text")) .write_text else if (std.mem.eql(u8, name, "file.edit_text")) .edit_text else return error.UnsupportedTool;
    if (args.max_bytes < 4 or args.max_bytes > 8192 or args.session_ids.len != 1) return error.InvalidToolArguments;
    return .{ .kind = kind, .path = args.path, .text = args.text, .mode = @fromBackingInt(@intCast(@backingInt(args.mode))), .expected_version = args.expected_version, .edits = args.edits, .offset = args.offset, .max_bytes = args.max_bytes };
}
pub fn invoke(raw: *anyopaque, invocation: tools.Invocation, a: std.mem.Allocator) !tools.ToolResult {
    const captured: *@import("legacy_adapter.zig").InvocationContext = @ptrCast(@alignCast(raw));
    const execute = captured.host.execute_file orelse return error.UnsupportedTool;
    return execute(captured.host.context, invocation, a, captured.cancel);
}
pub fn approvalText(a: std.mem.Allocator, name: []const u8, json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Arguments, a, json, .{});
    defer parsed.deinit();
    const args = parsed.value;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, args.path);
    if (std.mem.eql(u8, name, "file.edit_text")) {
        try out.appendSlice(a, "\n精确编辑；文件版本变化时拒绝提交\n");
        for (args.edits) |edit| {
            try out.appendSlice(a, "\n− ");
            try out.appendSlice(a, edit.old_text);
            try out.appendSlice(a, "\n+ ");
            try out.appendSlice(a, edit.new_text);
        }
    } else {
        try out.appendSlice(a, if (args.mode == .create) "\n创建文件；目标存在时拒绝\n\n" else "\n覆盖文件；文件版本变化时拒绝\n\n");
        try out.appendSlice(a, args.text);
    }
    return out.toOwnedSlice(a);
}
