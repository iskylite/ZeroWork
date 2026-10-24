//! Owned tool transcript and per-turn dispatch ledger. Host callbacks run only
//! after a complete provider round, on the Manager worker, never in its sink.
const std = @import("std");
const dynamic = @import("plugin_tools.zig");
const provider = @import("provider.zig");
const scope_mod = @import("tool_scope.zig");
const permission = @import("permission.zig");

pub const Limits = struct {
    max_rounds: u16 = 8,
    max_calls: u16 = 64,
    max_transcript_bytes: usize = 512 * 1024,
    max_retained_output_bytes: usize = 4 * 1024 * 1024,
    context_window: u32 = 8192,
};
pub const Key = struct { owner: scope_mod.Owner, turn_id: u64, call_id: []const u8 };
pub const Status = enum { succeeded, failed, rejected, cancelled, timed_out, unknown, skipped };
pub const Transport = enum { local, ssh, sftp, unknown };
pub const TargetResult = struct {
    session_id: u64,
    status: Status,
    transport: Transport = .unknown,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit: ?i32 = null,
    signal: ?u8 = null,
    cwd: ?[]const u8 = null,
    elapsed_ms: u64 = 0,
    truncated: bool = false,
    local_released: bool = true,
    remote_effect_unknown: bool = false,
    error_code: ?[]const u8 = null,
};
pub const Outcome = struct {
    targets: []TargetResult,

    pub fn copy(allocator: std.mem.Allocator, values: []const TargetResult) !Outcome {
        if (values.len > scope_mod.max_targets) return error.TooManyToolTargets;
        const targets = try allocator.alloc(TargetResult, values.len);
        var initialized: usize = 0;
        errdefer {
            for (targets[0..initialized]) |value| freeTarget(allocator, value);
            allocator.free(targets);
        }
        for (values, targets) |value, *target| {
            if (value.stdout.len + value.stderr.len > 64 * 1024) return error.ToolOutputTooLarge;
            if (value.cwd) |text| if (text.len > 4096 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidToolOutcome;
            if (value.error_code) |text| if (text.len > 256 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidToolOutcome;
            const stdout = try allocator.dupe(u8, value.stdout);
            errdefer allocator.free(stdout);
            const stderr = try allocator.dupe(u8, value.stderr);
            errdefer allocator.free(stderr);
            const cwd = if (value.cwd) |text| try allocator.dupe(u8, text) else null;
            errdefer if (cwd) |text| allocator.free(text);
            const error_code = if (value.error_code) |text| try allocator.dupe(u8, text) else null;
            target.* = value;
            target.stdout = stdout;
            target.stderr = stderr;
            target.cwd = cwd;
            target.error_code = error_code;
            initialized += 1;
        }
        return .{ .targets = targets };
    }
    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        for (self.targets) |value| freeTarget(allocator, value);
        allocator.free(self.targets);
        self.* = undefined;
    }
    fn freeTarget(allocator: std.mem.Allocator, value: TargetResult) void {
        allocator.free(value.stdout);
        allocator.free(value.stderr);
        if (value.cwd) |text| allocator.free(text);
        if (value.error_code) |text| allocator.free(text);
    }
};
pub const Invocation = struct {
    key: Key,
    scope: scope_mod.Scope,
    round_index: u16,
    call_index: u16,
    arguments: []const u8,
    arguments_hash: [32]u8,
    call: scope_mod.Call,
    verdict: permission.Verdict,
    policy_revision: u64,
    timeout_ms: u32 = 60_000,
    capture_bytes: u32 = 64 * 1024,
};
pub const Host = struct {
    context: *anyopaque,
    /// Borrow Invocation only until return. Capture exact generation, service
    /// and cwd on submission; preflight all targets and revalidate each start.
    /// Approval can wait here, but must honor cancel and never return as done
    /// while still pending. Outcome owns all strings via this allocator.
    /// After dispatch, errors are uncertain: return an explicit actual outcome
    /// (including unknown) and wait for release or transfer cleanup ownership.
    execute: *const fn (*anyopaque, Invocation, std.mem.Allocator, ?*provider.CancelToken) anyerror!Outcome,
    execute_dynamic: ?*const fn (*anyopaque, dynamic.DynamicInvocation, std.mem.Allocator, ?*provider.CancelToken) anyerror![]dynamic.ToolResult = null,
};

pub const Record = struct {
    key: Key,
    name: []const u8,
    arguments: []const u8,
    arguments_hash: [32]u8,
    dispatched: bool = false,
    outcome: ?Outcome = null,
    generic_results: ?[]dynamic.ToolResult = null,
    result_body: ?[]const u8 = null,
};
pub const Loop = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    scope: scope_mod.Scope,
    turn_id: u64,
    limits: Limits,
    request: provider.ChatRequest,
    messages: std.ArrayList(provider.Message) = .empty,
    records: std.ArrayList(Record) = .empty,
    round_index: u16 = 0,
    uncertain: bool = false,
    retained_output_bytes: usize = 0,
    tool_table: ?dynamic.RequestTable = null,

    pub fn init(allocator: std.mem.Allocator, scope: scope_mod.Scope, turn_id: u64, limits: Limits) Loop {
        return .{ .allocator = allocator, .arena = .init(allocator), .scope = scope, .turn_id = turn_id, .limits = limits, .request = undefined };
    }
    pub fn deinit(self: *Loop) void {
        for (self.records.items) |*record| {
            if (record.outcome) |*outcome| outcome.deinit(self.allocator);
            if (record.generic_results) |results| {
                for (results) |*result| result.deinit(self.allocator);
                self.allocator.free(results);
            }
        }
        if (self.tool_table) |*table| table.deinit();
        for (self.messages.items) |message| for (message.images) |reference| {
            var owned = reference;
            owned.release();
        };
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn start(self: *Loop, input: provider.ChatRequest) !void {
        if (self.limits.max_rounds == 0 or self.limits.max_rounds > 32 or self.limits.max_calls == 0 or self.limits.max_calls > 64 or self.limits.max_transcript_bytes == 0 or self.limits.max_transcript_bytes > 1024 * 1024 or self.limits.max_retained_output_bytes == 0 or self.limits.max_retained_output_bytes > 4 * 1024 * 1024 or self.limits.context_window == 0) return error.InvalidToolLoopLimits;
        var initial_bytes = input.system.len + input.model.len;
        for (input.messages) |message| {
            initial_bytes = std.math.add(usize, initial_bytes, message.content.len) catch return error.ToolTranscriptLimit;
            for (message.tool_calls) |call| initial_bytes = std.math.add(usize, initial_bytes, call.id.len + call.name.len + call.arguments.len) catch return error.ToolTranscriptLimit;
        }
        if (initial_bytes > self.limits.max_transcript_bytes) return error.ToolTranscriptLimit;
        const a = self.arena.allocator();
        self.request = input;
        self.request.model = try a.dupe(u8, input.model);
        self.request.system = try a.dupe(u8, input.system);
        if (input.tools.len > provider.max_tool_definitions) return error.InvalidToolDefinition;
        const definitions = try a.alloc(provider.ToolDefinition, input.tools.len);
        for (input.tools, definitions, 0..) |definition, *owned, definition_index| {
            for (input.tools[0..definition_index]) |previous| if (std.mem.eql(u8, previous.name(), definition.name())) return error.InvalidToolDefinition;
            _ = try self.scope.validate(definition.session_ids);
            owned.* = .{ .tool = definition.tool, .session_ids = try a.dupe(u64, definition.session_ids) };
            if (definition.dynamic) |wire| owned.dynamic = .{ .id = try a.dupe(u8, wire.id), .name = try a.dupe(u8, wire.name), .schema = try a.dupe(u8, wire.schema), .description = try a.dupe(u8, wire.description) };
        }
        self.request.tools = definitions;
        if (input.tool_table) |table| {
            self.tool_table = try dynamic.cloneTable(table, self.allocator);
            self.request.tool_table = &self.tool_table.?;
        }
        if (input.messages.len > 512) return error.ToolTranscriptLimit;
        for (input.messages) |message| {
            var owned = message;
            owned.content = try a.dupe(u8, message.content);
            if (message.tool_call_id) |id| owned.tool_call_id = try a.dupe(u8, id);
            owned.tool_calls = try self.copyCalls(message.tool_calls);
            owned.images = try a.dupe(@import("image_attachments.zig").ContentRef, message.images);
            try self.messages.append(a, owned);
            for (owned.images) |reference| _ = reference.retain();
        }
        self.request.messages = self.messages.items;
        try self.checkBudget();
    }
    pub fn nextRequest(self: *Loop) !provider.ChatRequest {
        if (self.round_index >= self.limits.max_rounds) return error.ToolRoundLimit;
        if (self.uncertain) return error.ToolOutcomeUnknown;
        try self.checkBudget();
        self.request.messages = self.messages.items;
        self.round_index += 1;
        return self.request;
    }
    pub fn checkRequestBudget(self: *const Loop) !void {
        try self.checkBudget();
    }
    /// Retains results even when Stop wins or the next request exceeds budget.
    pub fn complete(self: *Loop, text: []const u8, calls: []const provider.ToolCall, host: Host, policy: permission.Engine, policy_revision: u64, cancel: ?*provider.CancelToken) !void {
        if (calls.len == 0 or calls.len > provider.max_tool_calls) return error.InvalidToolCall;
        const a = self.arena.allocator();
        const owned_calls = try self.copyCalls(calls);
        for (owned_calls, 0..) |call, index| {
            try validateIdentity(call);
            for (owned_calls[0..index]) |previous| if (std.mem.eql(u8, previous.id, call.id)) return error.DuplicateToolCall;
        }
        try self.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, text), .tool_calls = owned_calls });
        for (owned_calls, 0..) |call, index| {
            const body = try self.resolve(call, @intCast(index), host, policy, policy_revision, cancel);
            var refs: std.ArrayList(@import("image_attachments.zig").ContentRef) = .empty;
            for (self.records.items) |resolved| if (std.mem.eql(u8, resolved.key.call_id, call.id)) {
                if (resolved.generic_results) |results| for (results) |result| for (result.blocks) |block| if (block == .image_ref) try refs.append(a, block.image_ref);
                break;
            };
            const captured_images = try refs.toOwnedSlice(a);
            try self.messages.append(a, .{ .role = .tool, .content = body, .tool_call_id = call.id, .images = captured_images });
            for (captured_images) |reference| _ = reference.retain();
        }
        self.request.messages = self.messages.items;
    }
    fn copyCalls(self: *Loop, calls: []const provider.ToolCall) ![]provider.ToolCall {
        if (calls.len > provider.max_tool_calls) return error.InvalidToolCall;
        const a = self.arena.allocator();
        const owned = try a.alloc(provider.ToolCall, calls.len);
        for (calls, owned) |call, *copy| {
            try validateIdentity(call);
            copy.* = .{ .id = try a.dupe(u8, call.id), .name = try a.dupe(u8, call.name), .arguments = try a.dupe(u8, call.arguments) };
        }
        return owned;
    }
    fn resolve(self: *Loop, call: provider.ToolCall, index: u16, host: Host, policy: permission.Engine, policy_revision: u64, cancel: ?*provider.CancelToken) ![]const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(call.arguments, &hash, .{});
        for (self.records.items) |record| if (std.mem.eql(u8, record.key.call_id, call.id)) {
            if (!std.mem.eql(u8, record.name, call.name) or !std.mem.eql(u8, &record.arguments_hash, &hash) or !std.mem.eql(u8, record.arguments, call.arguments)) return self.errorBody("CallIdentityConflict", null);
            return record.result_body orelse return error.ToolOutcomeUnknown;
        };
        if (self.records.items.len >= self.limits.max_calls) return self.errorBody("ToolCallLimit", null);
        const a = self.arena.allocator();
        try self.records.append(a, .{ .key = .{ .owner = self.scope.owner, .turn_id = self.turn_id, .call_id = call.id }, .name = call.name, .arguments = call.arguments, .arguments_hash = hash });
        const record = &self.records.items[self.records.items.len - 1];
        if (self.tool_table) |*table| {
            if (table.lookup(call.name) != null) return self.resolveDynamic(record, table, call, host, cancel);
            // A request table is the whole authority; no fallback to a global
            // legacy parser can invoke a tool omitted from this request.
            record.result_body = try self.errorBody("ToolNotInRequest", null);
            return record.result_body.?;
        }
        var parsed = parseStrict(self.allocator, self.scope, call.name, call.arguments) catch |err| {
            record.result_body = try self.errorBody(@errorName(err), null);
            return record.result_body.?;
        };
        defer parsed.deinit();
        const selected = parsed.call;
        var declared = false;
        for (self.request.tools) |definition| if (definition.tool == selected.tool) {
            declared = true;
            for (selected.targets.slice()) |id| if (std.mem.indexOfScalar(u64, definition.session_ids, id) == null) {
                record.result_body = try self.errorBody("ToolCapabilityUnavailable", &selected.targets);
                return record.result_body.?;
            };
        };
        if (!declared) {
            record.result_body = try self.errorBody("ToolCapabilityUnavailable", &selected.targets);
            return record.result_body.?;
        }
        const verdict = if (selected.tool == .run_command) permission.classify(policy, selected.command, self.scope.owner == .group) else permission.Verdict.allow_auto;
        if (verdict == .deny_exec_copy_only) {
            record.result_body = try self.errorBody("ToolExecutionDenied", &selected.targets);
            return record.result_body.?;
        }
        if (cancel) |token| if (token.isCancelled()) {
            record.result_body = try std.json.Stringify.valueAlloc(a, .{ .status = Status.cancelled, .error_code = "CancelledBeforeDispatch", .session_ids = selected.targets.slice() }, .{});
            return record.result_body.?;
        };
        if (self.uncertain) {
            record.result_body = try self.errorBody("EarlierToolOutcomeUnknown", &selected.targets);
            return record.result_body.?;
        }
        // Reserve the worst permitted per-target output before crossing the
        // effect boundary. Known results are never dropped to make room.
        if (selected.targets.len * 64 * 1024 > self.limits.max_retained_output_bytes -| self.retained_output_bytes) {
            record.result_body = try self.errorBody("ToolResultCapacity", &selected.targets);
            return record.result_body.?;
        }
        record.dispatched = true; // Set before crossing the effect boundary.
        const outcome = host.execute(host.context, .{ .key = record.key, .scope = self.scope, .round_index = self.round_index, .call_index = index, .arguments = call.arguments, .arguments_hash = hash, .call = selected, .verdict = verdict, .policy_revision = policy_revision }, self.allocator, cancel) catch |err| {
            self.uncertain = true;
            record.result_body = try self.unknownBody(@errorName(err), selected.targets);
            return record.result_body.?;
        };
        // Take ownership before validation; unknown data must remain inspectable.
        record.outcome = outcome;
        validateOutcome(selected, outcome) catch |err| {
            self.uncertain = true;
            record.result_body = try self.unknownBody(@errorName(err), selected.targets);
            return record.result_body.?;
        };
        for (outcome.targets) |target| if (target.status == .unknown or !target.local_released or target.remote_effect_unknown) {
            self.uncertain = true;
        };
        for (outcome.targets) |target| self.retained_output_bytes += target.stdout.len + target.stderr.len;
        record.result_body = try self.outcomeBody(outcome);
        return record.result_body.?;
    }
    fn resolveDynamic(self: *Loop, record: *Record, table: *const dynamic.RequestTable, call: provider.ToolCall, host: Host, cancel: ?*provider.CancelToken) ![]const u8 {
        @import("tool_trace.zig").emit(.{ .event = "dynamic_invocation", .call_id = call.id, .tool_id = call.name, .owner = self.scope.owner, .arguments_hash = std.fmt.bytesToHex(record.arguments_hash, .lower) });
        var parsed = table.parse(self.allocator, call.name, call.arguments) catch |err| {
            record.result_body = try self.errorBody(@errorName(err), null);
            return record.result_body.?;
        };
        defer parsed.deinit();
        if (cancel) |token| if (token.isCancelled()) {
            record.result_body = try self.errorBody("CancelledBeforeDispatch", &parsed.targets);
            return record.result_body.?;
        };
        if (self.uncertain) {
            record.result_body = try self.errorBody("EarlierToolOutcomeUnknown", &parsed.targets);
            return record.result_body.?;
        }
        const execute = host.execute_dynamic orelse {
            record.result_body = try self.errorBody("DynamicToolHostUnavailable", &parsed.targets);
            return record.result_body.?;
        };
        if (parsed.entry.definition.effect == .observe_image and (!self.request.vision or !self.request.tool_images)) {
            record.result_body = try self.errorBody("ModelDoesNotSupportToolImages", &parsed.targets);
            return record.result_body.?;
        }
        record.dispatched = true;
        // Monotonic identity belongs to the local operation history; provider
        // call IDs remain correlation strings and never become network handles.
        const operation_id = next_dynamic_operation.fetchAdd(1, .monotonic);
        if (operation_id == 0 or operation_id == std.math.maxInt(u64)) return error.IdentityExhausted;
        const results = execute(host.context, .{ .table = table, .parsed = parsed, .turn_id = self.turn_id, .call_id = call.id, .arguments = call.arguments, .operation_id = operation_id }, self.allocator, cancel) catch |err| {
            // Policy and approval rejection happen before any dispatch. Other
            // failures are conservatively unknown and never automatically replay.
            const preflight = err == error.ToolApprovalRequired or err == error.ToolApprovalRejected or err == error.ToolApprovalExpired or err == error.ToolApprovalChanged or err == error.StaleToolAuthority or err == error.ToolExecutionDenied or err == error.CancelledBeforeDispatch or err == error.ToolOperationAlreadyRecorded;
            if (!preflight) self.uncertain = true;
            record.dispatched = !preflight;
            @import("tool_trace.zig").emit(.{ .event = "dynamic_rejected", .call_id = call.id, .tool_id = call.name, .owner = self.scope.owner, .reason = @errorName(err), .dispatched = !preflight });
            record.result_body = if (preflight) try self.errorBody(@errorName(err), &parsed.targets) else try self.unknownBody(@errorName(err), parsed.targets);
            return record.result_body.?;
        };
        record.generic_results = results;
        if (results.len != parsed.targets.len) {
            self.uncertain = true;
            record.result_body = try self.unknownBody("InvalidToolOutcome", parsed.targets);
            return record.result_body.?;
        }
        const EncodedBlock = struct { type: []const u8, text: ?[]const u8 = null, image_mime: ?[]const u8 = null, width: ?u32 = null, height: ?u32 = null };
        const Encoded = struct { session_id: u64, status: dynamic.Status, content: []EncodedBlock, operation_id: u64, local_released: bool, remote_effect_unknown: bool };
        const a = self.arena.allocator();
        const encoded = try a.alloc(Encoded, results.len);
        for (results, encoded, parsed.targets.slice()) |result, *target, id| {
            const owner = for (parsed.entry.targets) |bound| {
                if (@backingInt(bound.owner.session_id) == id) break bound.owner;
            } else unreachable;
            result.validate(owner, operation_id) catch {
                self.uncertain = true;
                record.result_body = try self.unknownBody("InvalidToolOutcome", parsed.targets);
                return record.result_body.?;
            };
            const blocks = try a.alloc(EncodedBlock, result.blocks.len);
            for (result.blocks, blocks) |block, *output| output.* = switch (block) {
                .text => |text| .{ .type = "text", .text = text },
                .structured => |text| .{ .type = "structured", .text = text },
                .image_ref => |reference| blk: {
                    if (!self.request.vision or !self.request.tool_images) return error.ModelDoesNotSupportToolImages;
                    const image = reference.content() orelse return error.EmptyAttachmentResult;
                    break :blk .{ .type = "image_ref", .image_mime = image.mime.name(), .width = image.width, .height = image.height };
                },
            };
            if (result.status == .outcome_unknown or result.receipt.remote_effect_unknown or !result.receipt.local_released) self.uncertain = true;
            target.* = .{ .session_id = id, .status = result.status, .content = blocks, .operation_id = result.receipt.operation_id, .local_released = result.receipt.local_released, .remote_effect_unknown = result.receipt.remote_effect_unknown };
        }
        record.result_body = try std.json.Stringify.valueAlloc(a, .{ .targets = encoded }, .{ .emit_null_optional_fields = false });
        return record.result_body.?;
    }
    var next_dynamic_operation: std.atomic.Value(u64) = .init(1);
    fn checkBudget(self: *const Loop) !void {
        var bytes: usize = self.request.system.len + self.request.model.len;
        for (self.messages.items) |message| {
            bytes = std.math.add(usize, bytes, message.content.len + 32) catch return error.ToolTranscriptLimit;
            if (message.tool_call_id) |id| bytes += id.len;
            for (message.tool_calls) |call| bytes += call.id.len + call.name.len + call.arguments.len + 64;
        }
        // Tool schemas and message framing also occupy context. This is the
        // existing byte/4 estimate, not fabricated provider usage accounting.
        for (self.request.tools) |definition| if (definition.dynamic) |wire| {
            bytes = std.math.add(usize, bytes, wire.schema.len + wire.description.len + wire.name.len) catch return error.ToolTranscriptLimit;
        };
        const image_tokens = try @import("image_budget.zig").validate(self.request);
        const estimated = (bytes + 3) / 4 + self.request.tools.len * 256 + image_tokens;
        if (bytes > self.limits.max_transcript_bytes) return error.ToolTranscriptLimit;
        if (estimated + self.request.max_output > self.limits.context_window) return error.ToolContextBudget;
    }
    fn errorBody(self: *Loop, code: []const u8, targets: ?*const scope_mod.Targets) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.arena.allocator(), .{ .status = Status.rejected, .error_code = code, .session_ids = if (targets) |ids| ids.slice() else &.{} }, .{});
    }
    fn unknownBody(self: *Loop, code: []const u8, targets: scope_mod.Targets) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.arena.allocator(), .{ .status = Status.unknown, .error_code = code, .session_ids = targets.slice() }, .{});
    }
    fn outcomeBody(self: *Loop, outcome: Outcome) ![]const u8 {
        const Encoded = struct { session_id: u64, status: Status, transport: Transport, stdout: []const u8, stderr: []const u8, stdout_encoding: []const u8, stderr_encoding: []const u8, exit: ?i32, signal: ?u8, cwd: ?[]const u8, elapsed_ms: u64, truncated: bool, local_released: bool, remote_effect_unknown: bool, error_code: ?[]const u8 };
        const a = self.arena.allocator();
        const encoded = try a.alloc(Encoded, outcome.targets.len);
        for (outcome.targets, encoded) |target, *value| {
            const stdout_utf8 = std.unicode.utf8ValidateSlice(target.stdout);
            const stderr_utf8 = std.unicode.utf8ValidateSlice(target.stderr);
            value.* = .{ .session_id = target.session_id, .status = target.status, .transport = target.transport, .stdout = if (stdout_utf8) target.stdout else try base64(a, target.stdout), .stderr = if (stderr_utf8) target.stderr else try base64(a, target.stderr), .stdout_encoding = if (stdout_utf8) "utf-8" else "base64", .stderr_encoding = if (stderr_utf8) "utf-8" else "base64", .exit = target.exit, .signal = target.signal, .cwd = target.cwd, .elapsed_ms = target.elapsed_ms, .truncated = target.truncated, .local_released = target.local_released, .remote_effect_unknown = target.remote_effect_unknown, .error_code = target.error_code };
        }
        return std.json.Stringify.valueAlloc(a, .{ .targets = encoded }, .{});
    }
};

fn validateIdentity(call: provider.ToolCall) !void {
    if (call.id.len == 0 or call.id.len > provider.max_tool_call_id_bytes or std.mem.indexOfScalar(u8, call.id, 0) != null or !std.unicode.utf8ValidateSlice(call.id)) return error.InvalidToolCall;
    if (call.name.len == 0 or call.name.len > provider.max_tool_name_bytes or call.arguments.len > provider.max_tool_arguments_bytes or !std.unicode.utf8ValidateSlice(call.arguments)) return error.InvalidToolCall;
    for (call.name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidToolCall;
}
fn parseStrict(allocator: std.mem.Allocator, scope: scope_mod.Scope, name: []const u8, arguments: []const u8) !scope_mod.ParsedCall {
    const tool = std.meta.stringToEnum(scope_mod.Tool, name) orelse return error.UnsupportedTool;
    const value = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer value.deinit();
    if (value.value != .object) return error.InvalidToolArguments;
    var fields = value.value.object.iterator();
    while (fields.next()) |field| {
        const key = field.key_ptr.*;
        const allowed = std.mem.eql(u8, key, "session_ids") or switch (tool) {
            .run_command => std.mem.eql(u8, key, "command"),
            .read_terminal => false,
            .list_remote_files => std.mem.eql(u8, key, "path"),
            .read_remote_file => std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "max_bytes"),
        };
        if (!allowed) return error.InvalidToolArguments;
    }
    var parsed = try scope_mod.parse(allocator, scope, name, arguments);
    errdefer parsed.deinit();
    if (std.mem.indexOfScalar(u8, parsed.call.command, 0) != null) return error.InvalidToolArguments;
    if (parsed.call.command.len > 65534) return error.CommandTooLarge;
    return parsed;
}
fn validateOutcome(call: scope_mod.Call, outcome: Outcome) !void {
    if (outcome.targets.len != call.targets.len) return error.InvalidToolOutcome;
    for (outcome.targets, 0..) |target, index| {
        if (target.session_id != call.targets.ids[index] or target.stdout.len + target.stderr.len > 64 * 1024) return error.InvalidToolOutcome;
        if (target.exit != null and target.signal != null) return error.InvalidToolOutcome;
        if (target.status == .succeeded and (target.signal != null or (call.tool == .run_command and (target.exit == null or target.exit.? != 0)))) return error.InvalidToolOutcome;
    }
}
fn base64(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const output = try allocator.alloc(u8, encoder.calcSize(value.len));
    return encoder.encode(output, value);
}
