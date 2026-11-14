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
    .{ .id = "file.write_text", .description = "Create or fully replace one UTF-8 text file (65536 bytes maximum) on a Local/SSH terminal host. For SSH, writes run on the connected SSH host. They do not follow a nested SSH, sudo, or container shell. The parent directory must already exist. Default mode=create fails if the target exists. mode=replace requires expected_version from file.read_text. Never overwrite a file using a truncated page as its full contents. Permissions and exact target are checked; no sudo/SFTP. Returns committed/verified/outcome-unknown facts; never retry an uncertain write automatically.", .effect = .resource_write, .approval_policy = .confirm, .max_argument_bytes = 512 * 1024, .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ target ++ "," ++ expected ++ ",\"mode\":{\"type\":\"string\",\"enum\":[\"create\",\"replace\"]},\"text\":{\"type\":\"string\",\"maxLength\":65536}},\"required\":[\"session_ids\",\"path\",\"text\"]}", .validate = validate },
    .{ .id = "file.edit_text", .description = "Edit one Local/SSH UTF-8 text file using an exact expected_version. For SSH, edits run on the connected SSH host. They do not follow a nested SSH, sudo, or container shell. Each nonempty old_text must match exactly once in the original file; edits must not overlap. All edits are validated before a single staged commit. Preserves unchanged bytes, BOM and line endings; no fuzzy matching, implicit privilege escalation or SFTP. A stale version rejects the entire operation.", .effect = .resource_write, .approval_policy = .confirm, .max_argument_bytes = 512 * 1024, .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ target ++ "," ++ expected ++ ",\"edits\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":128,\"items\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"old_text\":{\"type\":\"string\",\"minLength\":1},\"new_text\":{\"type\":\"string\"}},\"required\":[\"old_text\",\"new_text\"]}}},\"required\":[\"session_ids\",\"path\",\"expected_version\",\"edits\"]}", .validate = validate },
};
/// Map only the builtin terminal file tools. A provider manifest cannot
/// advertise the host authority or supply the SessionHandle for this bridge.
pub fn managedHostId(id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, id, "file.read_text")) return "host.local_read_text";
    if (std.mem.eql(u8, id, "file.write_text")) return "host.local_write_text";
    if (std.mem.eql(u8, id, "file.edit_text")) return "host.local_edit_text";
    return null;
}

pub fn managedContribution(contributions: []const tools.host.Contribution, id: []const u8) ?tools.host.Contribution {
    const host_id = managedHostId(id) orelse return null;
    for (contributions) |contribution| {
        if (contribution.authority == .local_files and std.mem.eql(u8, contribution.definition.id, host_id)) return contribution;
    }
    return null;
}

/// The mixed Local/SSH catalog must accept the union of their property
/// constraints. Dispatch applies the schema for the actual captured target.
pub fn managedDefinition(a: std.mem.Allocator, terminal: tools.ToolDefinition, host_definition: tools.ToolDefinition, mixed: bool) !tools.ToolDefinition {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const legacy_schema = try std.json.parseFromSliceLeaky(std.json.Value, scratch, terminal.schema, .{});
    var schema = try std.json.parseFromSliceLeaky(std.json.Value, scratch, host_definition.schema, .{});
    const legacy_props = legacy_schema.object.get("properties").?.object;
    const properties = &schema.object.getPtr("properties").?.object;
    try properties.put(scratch, "session_ids", legacy_props.get("session_ids").?);
    if (mixed) {
        var iterator = legacy_props.iterator();
        while (iterator.next()) |field| {
            if (!properties.contains(field.key_ptr.*)) try properties.put(scratch, field.key_ptr.*, field.value_ptr.*);
        }
        if (properties.getPtr("expected_version")) |version| {
            // SSH versions are 64 characters. Local uses the tagged version
            // emitted by either Local read entry. The target validates it.
            _ = version.object.swapRemove("minLength");
            if (version.object.getPtr("maxLength")) |maximum| maximum.integer = @max(64, maximum.integer);
        }
        if (properties.getPtr("path")) |path| if (path.object.getPtr("maxLength")) |maximum| {
            maximum.integer = @max(4096, maximum.integer);
        };
        if (properties.getPtr("text")) |text| if (text.object.getPtr("maxLength")) |maximum| {
            maximum.integer = @max(65536, maximum.integer);
        };
        if (properties.getPtr("edits")) |edits| if (edits.object.getPtr("maxItems")) |maximum| {
            maximum.integer = @max(128, maximum.integer);
        };
    }
    var required: std.array_list.Managed(std.json.Value) = .init(scratch);
    try required.append(.{ .string = "session_ids" });
    if (schema.object.get("required")) |fields| for (fields.array.items) |field| {
        // Terminal writes retain their existing default create mode.
        if (std.mem.eql(u8, field.string, "mode")) continue;
        if (mixed) {
            const shared = for (legacy_schema.object.get("required").?.array.items) |legacy_field| {
                if (std.mem.eql(u8, legacy_field.string, field.string)) break true;
            } else false;
            if (!shared) continue;
        }
        try required.append(field);
    };
    try schema.object.put(scratch, "required", .{ .array = required });
    var definition = terminal;
    definition.schema = try std.json.Stringify.valueAlloc(a, schema, .{});
    definition.validate = null;
    definition.max_argument_bytes = @max(terminal.max_argument_bytes, host_definition.max_argument_bytes);
    definition.description = if (mixed)
        try std.fmt.allocPrint(a, "{s} Select one authorized session_id. For Local, use the local workspace rules and a request_key for writes; for SSH, use a path on the connected SSH host and the original SSH file version. SSH file operations do not follow a nested SSH, sudo, or container shell. Use an absolute path if the interactive shell changed environments. Local-only fields do not apply to SSH.", .{host_definition.description})
    else
        try std.fmt.allocPrint(a, "{s} Select one authorized Local session_id. Local path and file version rules match the host-local file tools.", .{host_definition.description});
    return definition;
}

pub fn validateLegacyArguments(a: std.mem.Allocator, id: []const u8, value: std.json.Value, raw_len: usize) !void {
    for (definitions) |definition| {
        if (!std.mem.eql(u8, definition.id, id)) continue;
        if (raw_len > definition.max_argument_bytes) return error.InvalidToolArguments;
        const schema = try std.json.parseFromSlice(std.json.Value, a, definition.schema, .{});
        defer schema.deinit();
        try tools.validateArguments(schema.value, value);
        try validate(value);
        return;
    }
    return error.UnsupportedTool;
}

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

test "terminal files mixed catalog validates each target's file version and write fields" {
    const a = std.testing.allocator;
    const legacy = definitions[2];
    const local: tools.ToolDefinition = .{
        .id = "host.local_edit_text",
        .description = "Use a current Local version.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\",\"maxLength\":4095},\"file_ref\":{\"type\":\"string\"},\"request_key\":{\"type\":\"string\"},\"expected_version\":{\"type\":\"string\",\"minLength\":68,\"maxLength\":68},\"edits\":{\"type\":\"array\",\"maxItems\":128,\"items\":{\"type\":\"object\"}}},\"required\":[\"request_key\",\"expected_version\",\"edits\"]}",
    };
    const mixed = try managedDefinition(a, legacy, local, true);
    defer a.free(mixed.schema);
    defer a.free(mixed.description);
    const schema = try std.json.parseFromSlice(std.json.Value, a, mixed.schema, .{});
    defer schema.deinit();
    const ssh_wire = "{\"session_ids\":[1],\"path\":\"/note\",\"expected_version\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"edits\":[{\"old_text\":\"x\",\"new_text\":\"y\"}]}";
    const ssh = try std.json.parseFromSlice(std.json.Value, a, ssh_wire, .{});
    defer ssh.deinit();
    try tools.validateArguments(schema.value, ssh.value);
    try validateLegacyArguments(a, legacy.id, ssh.value, ssh_wire.len);
    const local_wire = "{\"session_ids\":[2],\"file_ref\":\"bound-ref\",\"request_key\":\"same-write\",\"expected_version\":\"zw1:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"edits\":[{\"old_text\":\"x\",\"new_text\":\"y\"}]}";
    const local_call = try std.json.parseFromSlice(std.json.Value, a, local_wire, .{});
    defer local_call.deinit();
    try tools.validateArguments(schema.value, local_call.value);
    try std.testing.expectError(error.InvalidToolArguments, validateLegacyArguments(a, legacy.id, local_call.value, local_wire.len));
    const local_only = try managedDefinition(a, legacy, local, false);
    defer a.free(local_only.schema);
    defer a.free(local_only.description);
    const local_schema = try std.json.parseFromSlice(std.json.Value, a, local_only.schema, .{});
    defer local_schema.deinit();
    try tools.validateArguments(local_schema.value, local_call.value);
    try std.testing.expectError(error.InvalidToolArguments, tools.validateArguments(local_schema.value, ssh.value));
}
