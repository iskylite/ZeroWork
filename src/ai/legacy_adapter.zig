//! Compatibility engine bridge contributed by each builtin provider. The public
//! AI host consumes this vtable; it never chooses an engine by plugin identity.
const std = @import("std");
const identity = @import("../host/identity.zig");
const loop = @import("tool_loop.zig");
const scope = @import("tool_scope.zig");
pub const Approval = struct { expired: bool = false, group: bool = false, target: []const u8 = "", tool_id: ?[]const u8 = null, owner: identity.SessionHandle, cwd: ?[]const u8, sequence: u64, arguments_hash: [32]u8, command: []const u8, call_id: []const u8 };
pub const Factory = *const fn (std.mem.Allocator) anyerror!Adapter;
pub const Adapter = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        prepare: *const fn (*anyopaque, *anyopaque, identity.SessionHandle) anyerror!void,
        interface: *const fn (*anyopaque) loop.Host,
        preflight: *const fn (*anyopaque, *anyopaque, loop.Invocation) anyerror!void,
        files: *const fn (*anyopaque, ?*anyopaque) void,
        delegate: *const fn (*anyopaque, ?scope.Owner) void,
        tool_ids: *const fn (*anyopaque, scope.Tool) scope.Targets,
        pending: *const fn (*anyopaque) ?Approval,
        decide: *const fn (*anyopaque, u64, [32]u8, bool) anyerror!void,
        pump: *const fn (*anyopaque, *anyopaque) void,
        stop: *const fn (*anyopaque, identity.SessionHandle) @import("../host/session_host.zig").CloseReceipt,
        risk: *const fn (*anyopaque, identity.SessionHandle) bool,
        impact: *const fn (*anyopaque, identity.SessionHandle) @import("../ui/group_close_controller.zig").Impact,
        shutdown: *const fn (*anyopaque, ?*anyopaque) void,
        clear: *const fn (*anyopaque) anyerror!void,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
        label: *const fn (*anyopaque) []const u8,
        assemble_context: *const fn (std.mem.Allocator, *anyopaque, identity.SessionHandle, u32, bool) anyerror!@import("assembler.zig").Assembled,
    };
    pub fn create(comptime Impl: type, comptime App: type, allocator: std.mem.Allocator) !Adapter {
        const ImplWrapper = struct {
            fn cast(raw: *anyopaque) *Impl {
                return @ptrCast(@alignCast(raw));
            }
            fn app(raw: *anyopaque) *App {
                return @ptrCast(@alignCast(raw));
            }
            fn prepare(raw: *anyopaque, host: *anyopaque, owner: identity.SessionHandle) !void {
                try cast(raw).prepare(app(host), owner);
            }
            fn preflight(raw: *anyopaque, host: *anyopaque, invocation: loop.Invocation) !void {
                try cast(raw).preflight(app(host), invocation);
            }
            fn interface(raw: *anyopaque) loop.Host {
                return cast(raw).interface();
            }
            fn files(raw: *anyopaque, file_host: ?*anyopaque) void {
                if (@hasField(Impl, "files")) cast(raw).files = if (file_host) |value| @ptrCast(@alignCast(value)) else null;
            }
            fn delegate(raw: *anyopaque, owner: ?scope.Owner) void {
                cast(raw).delegated_owner = owner;
            }
            fn ids(raw: *anyopaque, tool: scope.Tool) scope.Targets {
                var output: scope.Targets = .{};
                const capture = cast(raw).capture orelse return output;
                if (tool == .list_remote_files or tool == .read_remote_file) {
                    if (!@hasDecl(Impl, "filesAvailable")) return output;
                    if (@hasDecl(Impl, "filesAvailable")) if (!cast(raw).filesAvailable()) return output;
                }
                output.ids[0] = @backingInt(capture.owner.session_id);
                output.len = 1;
                return output;
            }
            fn pending(raw: *anyopaque) ?Approval {
                return cast(raw).pendingApproval();
            }
            fn decide(raw: *anyopaque, sequence: u64, hash: [32]u8, approved: bool) !void {
                try cast(raw).decide(sequence, hash, approved);
            }
            fn pump(raw: *anyopaque, host: *anyopaque) void {
                cast(raw).pump(app(host));
            }
            fn stop(raw: *anyopaque, owner: identity.SessionHandle) @import("../host/session_host.zig").CloseReceipt {
                return cast(raw).stopOwner(owner);
            }
            fn risk(raw: *anyopaque, owner: identity.SessionHandle) bool {
                return cast(raw).writeRisk(owner);
            }
            fn impact(raw: *anyopaque, owner: identity.SessionHandle) @import("../ui/group_close_controller.zig").Impact {
                return cast(raw).closeImpact(owner);
            }
            fn shutdown(raw: *anyopaque, host: ?*anyopaque) void {
                cast(raw).shutdown(if (host) |value| app(value) else null);
            }
            fn clear(raw: *anyopaque) !void {
                try cast(raw).clear();
            }
            fn destroy(raw: *anyopaque, a: std.mem.Allocator) void {
                cast(raw).deinit();
                a.destroy(cast(raw));
            }
            fn label(raw: *anyopaque) []const u8 {
                const capture = cast(raw).capture orelse return "会话";
                return if (@hasField(@TypeOf(capture), "target")) capture.target else "本机 · zsh";
            }
            const vtable: VTable = .{ .prepare = prepare, .preflight = preflight, .interface = interface, .files = files, .delegate = delegate, .tool_ids = ids, .pending = pending, .decide = decide, .pump = pump, .stop = stop, .risk = risk, .impact = impact, .shutdown = shutdown, .clear = clear, .destroy = destroy, .label = label, .assemble_context = Impl.assembleContext };
        };
        const implementation = try allocator.create(Impl);
        implementation.* = Impl.init(allocator);
        return .{ .context = implementation, .vtable = &ImplWrapper.vtable };
    }
};

const tools = @import("plugin_tools.zig");
pub const InvocationContext = struct {
    host: loop.Host,
    captured_scope: scope.Scope,
    cancel: ?*@import("provider.zig").CancelToken = null,
    policy_revision: u64 = 1,
    output_context: ?@import("batch_output.zig").Context = null,
};
pub fn invoke(raw: *anyopaque, invocation: tools.Invocation, allocator: std.mem.Allocator) !tools.ToolResult {
    const captured: *InvocationContext = @ptrCast(@alignCast(raw));
    var parsed = try scope.parse(allocator, captured.captured_scope, invocation.tool_id, invocation.arguments_json);
    defer parsed.deinit();
    parsed.call.targets = .{};
    parsed.call.targets.ids[0] = @backingInt(invocation.owner.session_id);
    parsed.call.targets.len = 1;
    var outcome = try captured.host.execute(captured.host.context, .{ .key = .{ .owner = captured.captured_scope.owner, .turn_id = invocation.turn_id, .call_id = invocation.call_id }, .scope = captured.captured_scope, .round_index = 0, .call_index = 0, .arguments = invocation.arguments_json, .arguments_hash = invocation.arguments_hash, .call = parsed.call, .verdict = .allow_auto, .policy_revision = captured.policy_revision, .output_context = captured.output_context }, allocator, captured.cancel);
    defer outcome.deinit(allocator);
    if (outcome.targets.len != 1) return error.InvalidToolOutcome;
    const result = outcome.targets[0];
    const blocks = try allocator.alloc(tools.ContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = .{ .structured = try std.json.Stringify.valueAlloc(allocator, result, .{}) };
    return .{ .status = switch (result.status) {
        .succeeded => .succeeded,
        .unknown => .outcome_unknown,
        .cancelled, .timed_out => if (result.remote_effect_unknown) .outcome_unknown else .cancelled_unsent,
        .rejected => .rejected,
        else => .failed,
    }, .blocks = blocks, .receipt = .{ .owner = invocation.owner, .operation_id = invocation.operation_id, .local_released = result.local_released, .remote_effect_unknown = result.remote_effect_unknown } };
}
fn shellPolicy(arguments: std.json.Value, policy: tools.Policy, grouped: bool) !bool {
    const command = arguments.object.get("command") orelse return error.InvalidToolArguments;
    return switch (@import("permission.zig").classify(policy.engine, command.string, grouped)) {
        .deny_exec_copy_only => error.ToolExecutionDenied,
        .need_confirm => true,
        .allow_auto => false,
    };
}
const target_schema = "\"session_ids\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":16,\"uniqueItems\":true,\"items\":{\"type\":\"integer\",\"minimum\":1}}";
const continuation_fields = "\"offset\":{\"type\":\"integer\",\"minimum\":0},\"source_version\":{\"type\":\"string\",\"minLength\":16,\"maxLength\":16}";
pub const builtin_definitions = [_]tools.ToolDefinition{
    .{ .id = "run_command", .description = "Execute a command through each selected session's independent batch exec service, outside the interactive terminal. Host permissions, execution-mode routing and approval still apply. Returns the first 4096 output bytes and an output_ref/next_output_cursor when more retained output exists. Continue through host.read_command_output; never execute this command again to page its output. Retention is bounded at 4 MiB per command; retained_truncated explicitly reports overflow. Never rerun a side-effecting command just to recover missing output. host.run_in_terminal is the separate same-PTY execution path with retained incremental output, only when the chosen mode and capabilities allow it.", .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ target_schema ++ ",\"command\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":65534}},\"required\":[\"session_ids\",\"command\"]}", .approval_policy = .confirm, .effect = .resource_write, .evaluate_policy = shellPolicy },
    .{ .id = "read_terminal", .description = "Legacy compatibility tail read. Prefer host.read_terminal for history ranges and pagination when available.", .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ target_schema ++ "},\"required\":[\"session_ids\"]}" },
    .{ .id = "list_remote_files", .description = "List one remote directory page, default 128 entries. Use next_offset and source_version from stdout with the same path/session to continue. Offset zero starts a new listing. Each page scans and fingerprints the complete native listing; SourceChanged rejects changed contents or iteration order. Never treat a partial page as the entire directory.", .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ target_schema ++ "," ++ continuation_fields ++ ",\"path\":{\"type\":\"string\",\"minLength\":1,\"description\":\"Absolute remote path beginning with /\"},\"max_entries\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":128,\"default\":128}},\"required\":[\"session_ids\",\"path\"]}", .validate = validatePath },
    .{ .id = "read_remote_file", .description = "Read one remote UTF-8 file page, default 4096 bytes, maximum 65536. stdout contains text; stderr contains metadata including next_offset and source_version. Continue using those exact fields with the same absolute remote path/session. Offsets are bytes, not characters; returned offsets preserve UTF-8 boundaries. SourceChanged rejects stale source metadata. Version checks bind the source/path and SFTP size/mtime/permissions; they are not a content checksum. This never reads local files.", .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ target_schema ++ "," ++ continuation_fields ++ ",\"path\":{\"type\":\"string\",\"minLength\":1,\"description\":\"Absolute remote path beginning with /\"},\"max_bytes\":{\"type\":\"integer\",\"minimum\":4,\"maximum\":65536,\"default\":4096}},\"required\":[\"session_ids\",\"path\"]}", .validate = validatePath },
};
pub fn builtinDefinition(tool: scope.Tool) tools.ToolDefinition {
    for (builtin_definitions) |definition| if (std.mem.eql(u8, definition.id, @tagName(tool))) return definition;
    unreachable;
}
fn validatePath(arguments: std.json.Value) !void {
    const path = arguments.object.get("path") orelse return error.InvalidToolArguments;
    if (path != .string or !std.mem.startsWith(u8, path.string, "/")) return error.InvalidToolArguments;
}
pub fn builtinBindings(comptime plugin_id: []const u8, comptime names: []const []const u8) [names.len]tools.ToolBinding {
    var bindings: [names.len]tools.ToolBinding = undefined;
    for (names, 0..) |name, index| bindings[index] = .{ .plugin_id = plugin_id, .definition_id = name, .handler = invoke, .execution = .worker };
    return bindings;
}
