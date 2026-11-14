//! Owned tool transcript and per-turn dispatch ledger. Host callbacks run only
//! after a complete provider round, on the Manager worker, never in its sink.
const std = @import("std");
const dynamic = @import("plugin_tools.zig");
const provider = @import("provider.zig");
const scope_mod = @import("tool_scope.zig");
const permission = @import("permission.zig");
const file_references = @import("../host/local_file_reference.zig");

pub const Limits = struct {
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
    output_ref: ?[]const u8 = null,
    next_output_cursor: ?usize = null,
    retained_truncated: bool = false,
    local_released: bool = true,
    remote_effect_unknown: bool = false,
    error_code: ?[]const u8 = null,
};
pub const Outcome = struct {
    targets: []TargetResult,
    verification: ?@import("readonly_verification.zig").Anchor = null,

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
            target.output_ref = if (value.output_ref) |reference| try allocator.dupe(u8, reference) else null;
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
        if (value.output_ref) |text| allocator.free(text);
    }
};
pub const Invocation = struct {
    dispatch_fence: ?provider.DispatchFence = null,
    key: Key,
    scope: scope_mod.Scope,
    round_index: u64,
    call_index: usize,
    arguments: []const u8,
    arguments_hash: [32]u8,
    call: scope_mod.Call,
    verdict: permission.Verdict,
    policy_revision: u64,
    capture_bytes: u32 = 64 * 1024,
    output_context: ?@import("batch_output.zig").Context = null,
};
pub fn retainedPage(invocation: Invocation, original: TargetResult, reference: *[32]u8) !TargetResult {
    const context = invocation.output_context orelse return original;
    if (invocation.call.tool != .run_command or original.stdout.len + original.stderr.len == 0) return original;
    reference.* = try context.store.put(context, original);
    const chunk = try @import("batch_output.zig").page(original.stdout, original.stderr, 0, @max(4, invocation.call.max_bytes));
    var result = original;
    result.stdout = chunk.stdout;
    result.stderr = chunk.stderr;
    result.output_ref = reference;
    result.next_output_cursor = chunk.next;
    result.retained_truncated = original.truncated;
    result.truncated = chunk.next != null or original.truncated;
    return result;
}
pub const Host = struct {
    context: *anyopaque,
    /// Borrow Invocation only until return. Capture exact generation, service
    /// and cwd on submission; preflight all targets and revalidate each start.
    /// Approval can wait here, but must honor cancel and never return as done
    /// while still pending. Outcome owns all strings via this allocator.
    /// After dispatch, errors are uncertain: return an explicit actual outcome
    /// (including unknown) and wait for release or transfer cleanup ownership.
    execute: *const fn (*anyopaque, Invocation, std.mem.Allocator, ?*provider.CancelToken) anyerror!Outcome,
    execute_file: ?*const fn (*anyopaque, dynamic.Invocation, std.mem.Allocator, ?*provider.CancelToken) anyerror!dynamic.ToolResult = null,
    current_permission: ?*const fn (*anyopaque) permission.Engine = null,
    execute_dynamic: ?*const fn (*anyopaque, dynamic.DynamicInvocation, std.mem.Allocator, ?*provider.CancelToken) anyerror![]dynamic.ToolResult = null,
    /// A separate host gateway must revalidate conversation/task, binding and
    /// grants before dispatch. It never receives a fabricated SessionHandle.
    execute_host: ?*const fn (*anyopaque, dynamic.host.Invocation, std.mem.Allocator, ?*provider.CancelToken) anyerror!dynamic.host.Result = null,
    refresh_authority: ?*const fn (*anyopaque, *const dynamic.RequestTable, std.mem.Allocator, ?*provider.CancelToken) anyerror!?AuthorityRefresh = null,
    acknowledge_notice: ?*const fn (*anyopaque, u64, ?*provider.CancelToken) anyerror!void = null,
    accepted_host_result: ?*const fn (*anyopaque, dynamic.host.Context, []const u8, *const dynamic.host.Result, ?*provider.CancelToken) anyerror!void = null,
};
pub const AuthorityRefresh = struct {
    table: dynamic.RequestTable,
    notice: []const u8 = "",
    notice_revision: u64 = 0,
    system: ?[]const u8 = null,
    workspace_revision: ?u64 = null,
    publication: ?Publication = null,

    /// The host prepares an owned candidate without advancing live authority.
    /// publish adopts exactly that candidate or leaves live authority intact.
    pub const Publication = struct {
        context: *anyopaque,
        publish: *const fn (*anyopaque, ?*provider.CancelToken) anyerror!void,
        destroy: *const fn (*anyopaque) void,
    };
};

pub const Record = struct {
    key: Key,
    name: []const u8,
    arguments: []const u8,
    arguments_hash: [32]u8,
    dispatched: bool = false,
    outcome: ?Outcome = null,
    generic_results: ?[]dynamic.ToolResult = null,
    host_result: ?dynamic.host.Result = null,
    result_body: ?[]const u8 = null,
    file_reference_spans: []const file_references.Span = &.{},
};
pub const DispatchGate = provider.DispatchFence;
pub const Loop = struct {
    pub const revoked_result_body = "{\"status\":\"rejected\",\"error_code\":\"Unavailable\"}";

    read_only: bool = false,
    dispatch_gate: ?DispatchGate = null,
    operation_observation_gate: ?DispatchGate = null,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    scope: scope_mod.Scope,
    turn_id: u64,
    limits: Limits,
    request: provider.ChatRequest,
    unfiltered_tools: ?[]const provider.ToolDefinition = null,
    messages: std.ArrayList(provider.Message) = .empty,
    records: std.ArrayList(Record) = .empty,
    round_index: u64 = 0,
    verification_notes: std.ArrayList(u8) = .empty,
    uncertain: bool = false,
    /// Valid unknown receipts permit observation and targeted terminal recovery.
    /// An unaccounted dispatch retains the stop gate.
    host_observation_only: bool = false,
    retained_output_bytes: usize = 0,
    tool_table: ?dynamic.RequestTable = null,
    compaction_config: ?@import("provider_config.zig").ProviderConfig = null,
    compacted: @import("wire_history.zig").History = .{},
    compaction_failure: ?anyerror = null,
    /// Borrowed only for the current Manager call, cleared before it returns.
    compaction_provider: ?provider.Provider = null,
    notice_revision: u64 = 0,
    wire_notice_revision: u64 = 0,
    /// Keep undelivered notices in the transcript through further compaction.
    pending_notice_start: ?usize = null,

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
            if (record.host_result) |*result| result.deinit(self.allocator);
        }
        if (self.tool_table) |*table| table.deinit();
        for (self.messages.items) |message| for (message.images) |reference| {
            var owned = reference;
            owned.release();
        };
        for (self.messages.items) |message| for (message.offloaded_images) |image| {
            var owned = image.reference;
            owned.release();
        };
        self.compacted.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn start(self: *Loop, input: provider.ChatRequest) !void {
        if (self.limits.context_window == 0) return error.InvalidToolLoopLimits;
        const a = self.arena.allocator();
        self.scope = try self.scope.clone(a);
        self.request = input;
        self.request.model = try a.dupe(u8, input.model);
        self.request.system = try a.dupe(u8, input.system);
        const definitions = try a.alloc(provider.ToolDefinition, input.tools.len);
        for (input.tools, definitions, 0..) |definition, *owned, definition_index| {
            for (input.tools[0..definition_index]) |previous| if (std.mem.eql(u8, previous.name(), definition.name())) return error.InvalidToolDefinition;
            if (definition.authority == .session_targets) {
                if (definition.dynamic != null) try self.scope.validateDirectory(definition.session_ids) else _ = try self.scope.validate(definition.session_ids);
            } else {
                const table = input.tool_table orelse return error.InvalidHostAuthority;
                const context = table.host_context orelse return error.InvalidHostAuthority;
                try context.validate();
                const entry = table.lookup(definition.name()) orelse return error.InvalidHostAuthority;
                const wire = definition.dynamic orelse return error.InvalidHostAuthority;
                if (!context.binding.eql(self.scope.owner) or entry.authority != definition.authority or definition.session_ids.len != 0 or !std.mem.eql(u8, entry.definition.schema, wire.schema) or !std.mem.eql(u8, entry.definition.id, wire.id)) return error.InvalidHostAuthority;
            }
            owned.* = definition;
            owned.session_ids = try a.dupe(u64, definition.session_ids);
            if (definition.dynamic) |wire| owned.dynamic = .{ .id = try a.dupe(u8, wire.id), .name = try a.dupe(u8, wire.name), .schema = try a.dupe(u8, wire.schema), .description = try a.dupe(u8, wire.description) };
        }
        self.request.tools = definitions;
        if (input.tool_table) |table| {
            self.tool_table = try dynamic.cloneTable(table, self.allocator);
            self.request.tool_table = &self.tool_table.?;
        }
        for (input.messages) |message| {
            var owned = message;
            owned.content = try a.dupe(u8, message.content);
            owned.file_reference_spans = try a.dupe(file_references.Span, message.file_reference_spans);
            if (message.tool_call_id) |id| owned.tool_call_id = try a.dupe(u8, id);
            owned.tool_calls = try self.copyCalls(message.tool_calls);
            owned.images = try a.dupe(@import("image_attachments.zig").ContentRef, message.images);
            owned.offloaded_images = try a.dupe(provider.OffloadedImage, message.offloaded_images);
            try self.messages.append(a, owned);
            for (owned.images) |reference| _ = reference.retain();
            for (owned.offloaded_images) |image| _ = image.reference.retain();
        }
        self.request.messages = self.messages.items;
        try self.checkBudget();
    }
    pub fn nextRequest(self: *Loop) !provider.ChatRequest {
        try self.prepareNextRequest();
        return self.frozenNextRequest();
    }
    pub fn prepareNextRequest(self: *Loop) !void {
        if (self.uncertain and !self.host_observation_only) return error.ToolOutcomeUnknown;
        if (self.host_observation_only or self.read_only) {
            if (self.unfiltered_tools == null) self.unfiltered_tools = self.request.tools;
            var visible: std.ArrayList(provider.ToolDefinition) = .empty;
            const uncertain_terminal = self.hasUncertainTerminal(null);
            const independent_group_work = if (self.tool_table) |table|
                table.host_context != null and table.host_context.?.binding == .group and uncertain_terminal
            else
                false;
            for (self.unfiltered_tools.?) |definition| {
                if (self.tool_table == null) {
                    if (definition.dynamic == null and definition.tool != .run_command) try visible.append(self.arena.allocator(), definition);
                    continue;
                }
                const entry = if (self.tool_table) |*table| table.lookup(definition.name()) orelse continue else continue;
                const read = entry.definition.effect == .read_state or entry.definition.effect == .observe_image;
                if (read or (!self.read_only and (std.mem.eql(u8, entry.definition.id, "host.stop_execution") or
                    (std.mem.eql(u8, entry.definition.id, "host.reconnect_session") and uncertain_terminal) or
                    (std.mem.eql(u8, entry.definition.id, "host.run_in_terminal") and independent_group_work) or
                    (std.mem.eql(u8, entry.definition.id, "run_command") and independent_group_work)))) try visible.append(self.arena.allocator(), definition);
            }
            self.request.tools = try visible.toOwnedSlice(self.arena.allocator());
        }
        try self.checkBudget();
    }
    /// After the dispatch boundary, the request cannot compact, grow its
    /// transcript, or replace its workspace snapshot. Recheck volatile
    /// results after input consumption; this can only redact existing data.
    pub fn frozenNextRequest(self: *Loop) provider.ChatRequest {
        _ = self.discardRevokedResults();
        self.request.messages = self.messages.items;
        self.round_index +|= 1;
        return self.request;
    }
    /// Called between provider requests, with every previous tool pair closed.
    /// Historical keys keep their original owner and call IDs.
    pub fn refreshAuthority(self: *Loop, host: Host, cancel: ?*provider.CancelToken) !void {
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        const refresh = host.refresh_authority orelse return;
        const previous = if (self.tool_table) |*table| table else return;
        var next = (try refresh(host.context, previous, self.allocator, cancel)) orelse return;
        defer if (next.publication) |publication| publication.destroy(publication.context);
        var accepted = false;
        defer if (!accepted) next.table.deinit();
        defer self.allocator.free(next.notice);
        defer if (next.system) |system| self.allocator.free(system);
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        const old_context = previous.host_context orelse return error.InvalidHostAuthority;
        const context = next.table.host_context orelse return error.InvalidHostAuthority;
        try context.validate();
        if (!context.conversation_id.eql(old_context.conversation_id) or !context.task_id.eql(old_context.task_id) or !context.binding.eql(next.table.captured_scope.owner)) return error.InvalidHostAuthority;
        if (context.grant_revision != old_context.grant_revision) return error.AiGrantChanged;
        if (context.binding_revision < old_context.binding_revision) return error.InvalidBindingHandoff;
        if (!context.binding.eql(old_context.binding) and (old_context.binding != .session or context.binding != .group or context.binding_revision != old_context.binding_revision +| 1)) return error.InvalidBindingHandoff;
        if (context.binding_revision == old_context.binding_revision and !context.binding.eql(old_context.binding)) return error.InvalidBindingHandoff;
        if (next.notice.len != 0 and (next.notice_revision == 0 or next.notice_revision <= self.notice_revision)) return error.StaleNotice;
        const a = self.arena.allocator();
        const next_scope = try next.table.captured_scope.clone(a);
        const definitions = try dynamic.providerDefinitions(&next.table, a);
        _ = try provider.catalogTextBytes(definitions);
        var candidate = self.request;
        candidate.tools = definitions;
        candidate.tool_table = &next.table;
        if (next.system) |system| candidate.system = try a.dupe(u8, system);
        if (next.workspace_revision) |revision| candidate.workspace_revision = revision;
        const notice: ?provider.Message = if (next.notice.len != 0) .{ .role = .user, .content = try a.dupe(u8, next.notice), .origin = .host_context_notice } else null;
        const with_notice = if (notice) |message| try self.transcriptWithTail(self.compactableMessages(), message) else null;
        candidate.messages = with_notice orelse self.messages.items;
        try @import("provider_http.zig").validateToolMessages(candidate);

        var compacted: @import("wire_history.zig").History = .{};
        defer compacted.deinit();
        var compacted_messages: ?[]provider.Message = null;
        const budget = @import("local_text_request.zig");
        budget.checkContext(candidate, self.limits.context_window) catch |err| {
            if (err != error.ContextBudgetExceeded or self.compaction_config == null) return err;
            var reserve = try budget.fixedTokens(candidate);
            if (notice) |message| reserve += budget.draftTokens(message.content);
            const output = budget.outputTokens(candidate.max_output, self.limits.context_window);
            try budget.checkFixedBudget(reserve, output, self.limits.context_window);
            // The new prompt, catalog and notice must fit alongside the summary.
            // The summary itself receives only the previous transcript.
            compacted = try self.generateCompaction(reserve + output, cancel);
            const messages = try self.transcriptWithTail(compacted.messages, notice);
            candidate.messages = messages;
            budget.checkContext(candidate, self.limits.context_window) catch |reason| {
                self.compaction_failure = reason;
                return error.ContextCompactionFailed;
            };
            compacted_messages = messages;
        };
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        if (next.publication) |publication| try publication.publish(publication.context, cancel);
        self.unfiltered_tools = null;
        // No fallible work remains after the host adopts this authority.
        if (compacted_messages) |messages| {
            self.installCompaction(&compacted, messages);
        } else if (with_notice) |messages| {
            self.messages = .fromOwnedSlice(messages);
        }
        self.tool_table.?.deinit();
        self.tool_table = next.table;
        accepted = true;
        self.scope = next_scope;
        self.request.tools = definitions;
        self.request.tool_table = &self.tool_table.?;
        self.request.system = candidate.system;
        self.request.workspace_revision = candidate.workspace_revision;
        if (notice != null) {
            self.notice_revision = next.notice_revision;
            if (self.pending_notice_start == null) self.pending_notice_start = self.messages.items.len - 1;
        }
        self.request.messages = self.messages.items;
    }
    pub fn acknowledgeNotice(self: *Loop, host: Host, cancel: ?*provider.CancelToken) !void {
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        if (self.notice_revision <= self.wire_notice_revision) return;
        if (host.acknowledge_notice) |acknowledge| try acknowledge(host.context, self.notice_revision, cancel);
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        self.wire_notice_revision = self.notice_revision;
        self.pending_notice_start = null;
    }
    /// Called by the execution-side child gateway while its own call is still
    /// open. Excludes that ENTIRE assistant batch, including results of earlier
    /// siblings, so the child sees consumed input and only closed tool pairs.
    pub fn snapshotForChild(self: *Loop, allocator: std.mem.Allocator, call_id: []const u8, child_scope: scope_mod.Scope, targets: []const @import("../host/identity.zig").SessionHandle) !@import("wire_history.zig").History {
        _ = self.discardRevokedResults();
        if (!self.scope.owner.eql(child_scope.owner) or self.scope.memberIds().len != child_scope.memberIds().len) return error.InheritanceScopeProjectionRequired;
        for (self.scope.memberIds()) |id| child_scope.validateDirectory(&.{id}) catch return error.InheritanceScopeProjectionRequired;
        var offset = self.messages.items.len;
        while (offset > 0) {
            offset -= 1;
            const message = self.messages.items[offset];
            if (message.role != .assistant or message.tool_calls.len == 0) continue;
            const owns_call = for (message.tool_calls) |call| {
                if (std.mem.eql(u8, call.id, call_id)) break true;
            } else false;
            if (!owns_call) return error.InvalidInheritanceSnapshot;
            for (self.messages.items[offset + 1 ..]) |result| if (result.tool_call_id) |id| {
                if (std.mem.eql(u8, id, call_id)) return error.InvalidInheritanceSnapshot;
            };
            for (self.messages.items[0..offset]) |prior| {
                if (prior.image_owner) |owner| {
                    const permitted = for (targets) |target| {
                        if (target.eql(owner)) break true;
                    } else false;
                    if (!permitted) return error.InheritanceScopeProjectionRequired;
                }
                for (prior.offloaded_images) |image| if (image.owner) |owner| {
                    const permitted = for (targets) |target| {
                        if (target.eql(owner)) break true;
                    } else false;
                    if (!permitted) return error.InheritanceScopeProjectionRequired;
                };
            }
            return @import("wire_history.zig").History.copyForChild(allocator, self.messages.items[0..offset]);
        }
        return error.InvalidInheritanceSnapshot;
    }
    pub fn checkRequestBudget(self: *Loop) !void {
        try self.checkBudget();
    }
    /// Reserve and own the entire message before committing its input receipt.
    /// appendPrepared cannot fail, so an accepted input is never duplicated by
    /// a retry after a partial history allocation.
    pub fn prepareMessage(self: *Loop, message: provider.Message) !provider.Message {
        if (message.tool_calls.len != 0 or message.tool_call_id != null) return error.InvalidToolCall;
        const a = self.arena.allocator();
        try self.messages.ensureUnusedCapacity(a, 1);
        var owned = message;
        owned.content = try a.dupe(u8, message.content);
        owned.file_reference_spans = try a.dupe(file_references.Span, message.file_reference_spans);
        owned.images = try a.dupe(@import("image_attachments.zig").ContentRef, message.images);
        owned.offloaded_images = try a.dupe(provider.OffloadedImage, message.offloaded_images);
        var candidate = self.request;
        candidate.messages = self.preparedTranscript(owned);
        @import("local_text_request.zig").checkContext(candidate, self.limits.context_window) catch |err| {
            if (err != error.ContextBudgetExceeded or self.compaction_config == null) return err;
            const budget = @import("local_text_request.zig");
            const reserve = (try budget.fixedTokens(self.request)) + (try budget.inputTokens(.{ .model = self.request.model, .system = "", .messages = &.{owned}, .max_output = self.request.max_output }));
            try self.compact(reserve);
            try self.messages.ensureUnusedCapacity(a, 1);
            candidate.messages = self.preparedTranscript(owned);
            try budget.checkContext(candidate, self.limits.context_window);
        };
        return owned;
    }
    pub fn prepareInputBatch(self: *Loop, values: []const provider.Message) ![]provider.Message {
        const a = self.arena.allocator();
        const owned = try a.alloc(provider.Message, values.len);
        for (owned, values) |*out, value| {
            out.* = value;
            out.content = try a.dupe(u8, value.content);
            out.file_reference_spans = try a.dupe(file_references.Span, value.file_reference_spans);
            out.images = try a.dupe(@import("image_attachments.zig").ContentRef, value.images);
            out.offloaded_images = try a.dupe(provider.OffloadedImage, value.offloaded_images);
        }
        if (owned.len == 0) return owned;
        const budget = @import("local_text_request.zig");
        try self.messages.ensureUnusedCapacity(a, owned.len);
        var candidate = self.request;
        candidate.messages = self.preparedInputTranscript(owned);
        budget.checkContext(candidate, self.limits.context_window) catch |err| {
            if (err != error.ContextBudgetExceeded or self.compaction_config == null) return err;
            const extra = try budget.inputTokens(.{ .model = self.request.model, .system = "", .messages = owned, .max_output = self.request.max_output });
            try self.compact((try budget.fixedTokens(self.request)) + extra);
            try self.messages.ensureUnusedCapacity(a, owned.len);
            candidate.messages = self.preparedInputTranscript(owned);
            try budget.checkContext(candidate, self.limits.context_window);
        };
        return owned;
    }
    pub fn preparedInputTranscript(self: *Loop, values: []const provider.Message) []const provider.Message {
        _ = self.discardRevokedResults();
        @memcpy(self.messages.unusedCapacitySlice()[0..values.len], values);
        return self.messages.items.ptr[0 .. self.messages.items.len + values.len];
    }
    pub fn appendPrepared(self: *Loop, message: provider.Message) void {
        for (message.images) |reference| _ = reference.retain();
        for (message.offloaded_images) |entry| _ = entry.reference.retain();
        self.messages.appendAssumeCapacity(message);
        self.request.messages = self.messages.items;
    }
    /// Borrow the already reserved append slot for atomic outbox+transcript
    /// storage. Length and refcounts change only after that commit succeeds.
    pub fn preparedTranscript(self: *Loop, message: provider.Message) []const provider.Message {
        self.messages.unusedCapacitySlice()[0] = message;
        return self.messages.items.ptr[0 .. self.messages.items.len + 1];
    }
    pub fn sealInterrupted(self: *Loop) !void {
        const last = for (self.messages.items, 0..) |message, index| {
            if (message.tool_calls.len != 0) {
                // The final assistant batch is the only one a stopped loop
                // can leave open; earlier batches passed nextRequest checks.
                var later = false;
                for (self.messages.items[index + 1 ..]) |other| if (other.tool_calls.len != 0) {
                    later = true;
                    break;
                };
                if (!later) break index;
            }
        } else return;
        const calls = self.messages.items[last].tool_calls;
        for (calls) |call| {
            var present = false;
            for (self.messages.items[last + 1 ..]) |message| if (message.tool_call_id) |id| if (std.mem.eql(u8, id, call.id)) {
                present = true;
                break;
            };
            if (present) continue;
            var dispatched = false;
            for (self.records.items) |record| if (std.mem.eql(u8, record.key.call_id, call.id)) {
                dispatched = record.dispatched;
                break;
            };
            const body = try std.json.Stringify.valueAlloc(self.arena.allocator(), .{ .status = if (dispatched) "outcome_unknown" else "cancelled_unsent", .error_code = "InterruptedBeforeResult", .operation_may_have_started = dispatched }, .{});
            try self.messages.append(self.arena.allocator(), .{ .role = .tool, .content = body, .tool_call_id = call.id });
            if (dispatched) self.stopForUnknownDispatch();
        }
        self.request.messages = self.messages.items;
    }
    fn planCurrent(self: *Loop) bool {
        return if (self.dispatch_gate) |gate| gate.current(gate.context, gate.revision) else true;
    }
    fn operationObservation(name: []const u8, arguments: std.json.Value) bool {
        return arguments == .object and ((std.mem.eql(u8, name, "host.wait_session_ready") and arguments.object.contains("operation_ref")) or std.mem.eql(u8, name, "host.reconnect_session"));
    }
    fn stopForUnknownDispatch(self: *Loop) void {
        self.uncertain = true;
        self.host_observation_only = false;
    }
    fn hasUncertainTerminal(self: *const Loop, target: ?@import("../host/identity.zig").SessionHandle) bool {
        if (!self.host_observation_only) return false;
        var found = false;
        for (self.records.items) |record| {
            if (record.generic_results) |results| for (results) |result| {
                if (result.status == .outcome_unknown or result.receipt.remote_effect_unknown or !result.receipt.local_released) return false;
            };
            if (record.host_result) |result| {
                if (result.status != .outcome_unknown and !result.receipt.remote_effect_unknown and result.receipt.local_released) continue;
                const owner = result.uncertain_terminal orelse return false;
                found = found or target == null or target.?.eql(owner);
            }
        }
        return found;
    }
    fn hasRecoveredTerminal(self: *const Loop, previous: ?@import("../host/identity.zig").SessionHandle, current: ?@import("../host/identity.zig").SessionHandle) bool {
        for (self.records.items) |record| if (record.host_result) |result| {
            const recovered = result.reconnected orelse continue;
            if (previous != null and !previous.?.eql(recovered.previous)) continue;
            if (current != null and !current.?.eql(recovered.current)) continue;
            if (self.hasUncertainTerminal(recovered.previous)) return true;
        };
        return false;
    }
    fn permitsIndependentGroupTarget(self: *const Loop, id: @import("../host/identity.zig").SessionId) bool {
        if (!self.hasUncertainTerminal(null)) return false;
        for (self.records.items) |record| if (record.host_result) |result| {
            if (result.status != .outcome_unknown and !result.receipt.remote_effect_unknown and result.receipt.local_released) continue;
            if (result.uncertain_terminal.?.session_id == id) return false;
        };
        return true;
    }
    fn permitsRecovery(self: *const Loop, context: dynamic.host.Context, parsed: dynamic.ParsedCall) bool {
        const name = parsed.entry.definition.id;
        const arguments = parsed.json.value;
        if (arguments != .object) return false;
        const ref = arguments.object.get("session_ref") orelse return false;
        if (ref != .string) return false;
        const target = @import("host_lifecycle.zig").sessionHandle(context, ref.string) catch return false;
        if (std.mem.eql(u8, name, "host.reconnect_session")) return self.hasUncertainTerminal(target) and !self.hasRecoveredTerminal(target, null);
        if (!std.mem.eql(u8, name, "host.run_in_terminal")) return false;
        return context.binding == .group and self.permitsIndependentGroupTarget(target.session_id);
    }
    /// Retains results even when Stop wins or the next request exceeds budget.
    pub fn complete(self: *Loop, text: []const u8, calls: []const provider.ToolCall, host: Host, policy: permission.Engine, policy_revision: u64, cancel: ?*provider.CancelToken) !void {
        if (calls.len == 0) return error.InvalidToolCall;
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
            var image_owner: ?@import("../host/identity.zig").SessionHandle = null;
            var image_transform: u64 = 0;
            var reference_spans: []const file_references.Span = &.{};
            for (self.records.items) |resolved| if (std.mem.eql(u8, resolved.key.call_id, call.id)) {
                reference_spans = resolved.file_reference_spans;
                if (self.request.vision and self.request.tool_images) if (resolved.host_result) |result| for (result.images) |ref| try refs.append(a, ref);
                if (resolved.generic_results) |results| for (results) |result| for (result.blocks) |block| if (block == .image_ref) {
                    try refs.append(a, block.image_ref);
                    image_owner = result.receipt.owner;
                };
                if (resolved.generic_results) |results| for (results) |result| for (result.blocks) |block| {
                    if (block != .structured) continue;
                    const parsed = std.json.parseFromSlice(std.json.Value, a, block.structured, .{}) catch continue;
                    defer parsed.deinit();
                    if (parsed.value == .object) if (parsed.value.object.get("transform")) |transform| {
                        const encoded = try std.json.Stringify.valueAlloc(a, transform, .{});
                        image_transform = std.hash.Wyhash.hash(0, encoded);
                    };
                };
                break;
            };
            const captured_images = try refs.toOwnedSlice(a);
            try self.messages.append(a, .{ .role = .tool, .content = body, .tool_call_id = call.id, .images = captured_images, .image_owner = image_owner, .image_transform = image_transform, .file_reference_spans = reference_spans });
            for (captured_images) |reference| _ = reference.retain();
        }
        self.request.messages = self.messages.items;
        if (host.accepted_host_result) |accepted| if (!(if (cancel) |token| token.isCancelled() else false)) {
            const context = if (self.tool_table) |table| table.host_context else null;
            if (context) |captured| for (owned_calls) |call| {
                if (cancel) |token| if (token.isCancelled()) break;
                for (self.records.items) |record| if (std.mem.eql(u8, record.key.call_id, call.id)) {
                    if (record.host_result) |*result| try accepted(host.context, captured, record.name, result, cancel);
                    break;
                };
            };
        };
    }
    fn copyCalls(self: *Loop, calls: []const provider.ToolCall) ![]provider.ToolCall {
        const a = self.arena.allocator();
        const owned = try a.alloc(provider.ToolCall, calls.len);
        for (calls, owned) |call, *copy| {
            try validateIdentity(call);
            copy.* = .{ .id = try a.dupe(u8, call.id), .name = try a.dupe(u8, call.name), .arguments = try a.dupe(u8, call.arguments) };
        }
        return owned;
    }
    fn resolve(self: *Loop, call: provider.ToolCall, index: usize, host: Host, policy: permission.Engine, policy_revision: u64, cancel: ?*provider.CancelToken) ![]const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(call.arguments, &hash, .{});
        for (self.records.items) |record| if (std.mem.eql(u8, record.key.call_id, call.id)) {
            if (!std.mem.eql(u8, record.name, call.name) or !std.mem.eql(u8, &record.arguments_hash, &hash) or !std.mem.eql(u8, record.arguments, call.arguments)) return self.errorBody("CallIdentityConflict", null);
            return record.result_body orelse return error.ToolOutcomeUnknown;
        };
        const a = self.arena.allocator();
        try self.records.append(a, .{ .key = .{ .owner = self.scope.owner, .turn_id = self.turn_id, .call_id = call.id }, .name = call.name, .arguments = call.arguments, .arguments_hash = hash });
        const record = &self.records.items[self.records.items.len - 1];
        if (!self.planCurrent() and !self.mayObserveOperation(tableEntry(self, call.name))) {
            record.result_body = try self.errorBody("not_dispatched_due_to_new_input", null);
            return record.result_body.?;
        }
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
        if (self.read_only and selected.tool == .run_command) {
            record.result_body = try self.errorBody("ObservationOnlyTask", &selected.targets);
            return record.result_body.?;
        }
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
        const live_policy = if (host.current_permission) |read| read(host.context) else policy;
        const verdict = if (selected.tool == .run_command) permission.commandVerdict(live_policy) else permission.Verdict.allow_auto;
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
        if (!self.planCurrent()) {
            record.result_body = try self.errorBody("not_dispatched_due_to_new_input", null);
            return record.result_body.?;
        }
        record.dispatched = true; // Set before crossing the effect boundary.
        const outcome = host.execute(host.context, .{ .dispatch_fence = self.dispatch_gate, .key = record.key, .scope = self.scope, .round_index = self.round_index, .call_index = index, .arguments = call.arguments, .arguments_hash = hash, .call = selected, .verdict = verdict, .policy_revision = policy_revision }, self.allocator, cancel) catch |err| {
            const unsent = err == error.ScopeChanged or err == error.CancelledBeforeDispatch;
            record.dispatched = !unsent;
            if (!unsent) self.uncertain = true;
            record.result_body = if (unsent) try self.errorBody(@errorName(err), &selected.targets) else try self.unknownBody(@errorName(err), selected.targets);
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

    fn tableEntry(self: *Loop, name: []const u8) ?*const dynamic.Entry {
        return if (self.tool_table) |*table| table.lookup(name) else null;
    }
    fn mayObserveOperation(self: *Loop, entry: ?*const dynamic.Entry) bool {
        const item = entry orelse return false;
        if (!std.mem.eql(u8, item.definition.id, "host.wait_session_ready") and !std.mem.eql(u8, item.definition.id, "host.reconnect_session")) return false;
        const gate = self.operation_observation_gate orelse return false;
        return gate.current(gate.context, gate.revision);
    }

    fn resolveHost(self: *Loop, record: *Record, table: *const dynamic.RequestTable, parsed: dynamic.ParsedCall, call: provider.ToolCall, host: Host, cancel: ?*provider.CancelToken) ![]const u8 {
        const context = table.host_context orelse return error.InvalidHostAuthority;
        const execute = host.execute_host orelse {
            record.result_body = try self.errorBody("HostToolGatewayUnavailable", null);
            return record.result_body.?;
        };
        const affecting = parsed.entry.definition.effect == .remote_input or parsed.entry.definition.effect == .resource_write;
        if (self.uncertain and affecting and !std.mem.eql(u8, parsed.entry.definition.id, "host.stop_execution") and !self.permitsRecovery(context, parsed)) {
            record.result_body = try self.errorBody("EarlierToolOutcomeUnknown", null);
            return record.result_body.?;
        }
        const operation_id = next_dynamic_operation.fetchAdd(1, .monotonic);
        if (operation_id == 0 or operation_id == std.math.maxInt(u64)) return error.IdentityExhausted;
        const dispatch_gate = if (operationObservation(parsed.entry.definition.id, parsed.json.value)) self.operation_observation_gate orelse self.dispatch_gate else self.dispatch_gate;
        if (dispatch_gate) |gate| if (!gate.current(gate.context, gate.revision)) {
            record.result_body = try self.errorBody("not_dispatched_due_to_new_input", null);
            return record.result_body.?;
        };
        record.dispatched = true;
        var result = execute(host.context, .{ .dispatch_fence = dispatch_gate, .mutation_fence = if (std.mem.eql(u8, parsed.entry.definition.id, "host.reconnect_session")) self.dispatch_gate else null, .workspace_revision = self.request.workspace_revision, .context = context, .authority = parsed.entry.authority, .operation_id = operation_id, .turn_id = self.turn_id, .call_id = call.id, .tool_id = parsed.entry.definition.id, .arguments = parsed.json.value, .arguments_json = call.arguments, .arguments_hash = parsed.arguments_hash, .canonical_arguments_hash = parsed.canonical_arguments_hash orelse return error.InvalidHostAuthority }, self.allocator, cancel) catch |err| {
            const preflight = err == error.InvalidHostAuthority or err == error.ToolApprovalRequired or err == error.ToolApprovalRejected or err == error.ToolApprovalExpired or err == error.ToolApprovalChanged or err == error.StaleToolAuthority or err == error.ScopeChanged or err == error.WorkspaceChanged or err == error.PermissionDenied or err == error.ToolExecutionDenied or err == error.CancelledBeforeDispatch or err == error.ExecutionDeadlineBeforeDispatch or err == error.ToolNotAvailable or err == error.TargetOutsideScope;
            record.dispatched = !preflight;
            if (!preflight and affecting) self.stopForUnknownDispatch();
            record.result_body = try std.json.Stringify.valueAlloc(self.arena.allocator(), .{ .status = if (preflight) dynamic.Status.rejected else if (!affecting) dynamic.Status.failed else dynamic.Status.outcome_unknown, .error_code = @errorName(err), .message = if (preflight) @as(?[]const u8, @import("step_failure.zig").explanation(@errorName(err))) else null, .conversation_id = context.conversation_id, .task_id = context.task_id, .operation_id = operation_id, .side_effect_started = !preflight and affecting, .request_sent = if (parsed.entry.authority == .local_network_read and preflight) @as(?bool, false) else null, .local_released = preflight or !affecting, .remote_effect_unknown = !preflight and affecting }, .{});
            return record.result_body.?;
        };
        result.validate(context, operation_id) catch {
            result.deinit(self.allocator);
            self.stopForUnknownDispatch();
            record.result_body = try self.errorBody("InvalidHostToolResult", null);
            return record.result_body.?;
        };
        record.host_result = result;
        for (result.blocks) |block| self.retained_output_bytes += switch (block) {
            .text, .structured => |text| text.len,
        };
        if (result.status == .outcome_unknown or result.receipt.remote_effect_unknown or !result.receipt.local_released) {
            if (!self.uncertain) self.host_observation_only = true;
            self.uncertain = true;
        }
        const EncodedBlock = struct { type: []const u8, text: []const u8 };
        const blocks = try self.arena.allocator().alloc(EncodedBlock, result.blocks.len);
        if (@import("../platform/runtime_mode.zig").automation) {
            for (result.blocks, blocks) |block, *encoded| encoded.* = switch (block) {
                .text => |text| .{ .type = "text", .text = text },
                .structured => |text| .{ .type = "structured", .text = text },
            };
            @import("tool_trace.zig").emit(.{ .event = "host_result", .turn_id = self.turn_id, .call_id = call.id, .result = .{ .status = result.status, .content = blocks, .receipt = result.receipt } });
        }
        for (result.blocks, blocks) |block, *encoded| encoded.* = switch (block) {
            .text => |text| .{ .type = "text", .text = text },
            .structured => |text| .{ .type = "structured", .text = try @import("execution_result_projection.zig").modelContent(self.arena.allocator(), parsed.entry.definition.id, text) },
        };
        const a = self.arena.allocator();
        const body = try std.json.Stringify.valueAlloc(a, .{ .status = result.status, .content = blocks, .receipt = result.receipt }, .{ .emit_null_optional_fields = false });
        record.result_body = body;
        if (result.status == .succeeded and std.mem.eql(u8, parsed.entry.definition.id, "host.local_read_text")) {
            var located: file_references.ReceiptSpans = .{};
            for (blocks) |block| try located.observe(a, body, block.text, std.mem.eql(u8, block.type, "structured"));
            record.file_reference_spans = located.spans.items;
        }
        return body;
    }
    fn resolveDynamic(self: *Loop, record: *Record, table: *const dynamic.RequestTable, call: provider.ToolCall, host: Host, cancel: ?*provider.CancelToken) ![]const u8 {
        @import("tool_trace.zig").emit(.{ .event = "dynamic_invocation", .call_id = call.id, .tool_id = call.name, .owner = self.scope.owner, .arguments_hash = std.fmt.bytesToHex(record.arguments_hash, .lower) });
        var parsed = table.parse(self.allocator, call.name, call.arguments) catch |err| {
            record.result_body = (try @import("kvm_tool_feedback.zig").preflightBody(self.arena.allocator(), call.name, @errorName(err), &.{})) orelse try self.errorBody(@errorName(err), null);
            return record.result_body.?;
        };
        defer parsed.deinit();
        if (cancel) |token| if (token.isCancelled()) {
            record.result_body = try self.errorBody("CancelledBeforeDispatch", &parsed.targets);
            return record.result_body.?;
        };
        if (self.read_only and parsed.entry.definition.effect != .read_state and parsed.entry.definition.effect != .observe_image) {
            record.result_body = try self.errorBody("ObservationOnlyTask", &parsed.targets);
            return record.result_body.?;
        }
        if (parsed.entry.authority != .session_targets) return self.resolveHost(record, table, parsed, call, host, cancel);
        const independent_group_batch = independent: {
            if (!self.uncertain or table.host_context == null or table.host_context.?.binding != .group or !std.mem.eql(u8, parsed.entry.definition.id, "run_command")) break :independent false;
            for (parsed.targets.slice()) |id| if (!self.permitsIndependentGroupTarget(@fromBackingInt(id))) break :independent false;
            break :independent true;
        };
        if (self.uncertain and (!self.host_observation_only or (parsed.entry.definition.effect != .read_state and parsed.entry.definition.effect != .observe_image and !independent_group_batch))) {
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
        if (!self.planCurrent()) {
            record.result_body = try self.errorBody("not_dispatched_due_to_new_input", null);
            return record.result_body.?;
        }
        record.dispatched = true;
        // Monotonic identity belongs to the local operation history; provider
        // call IDs remain correlation strings and never become network handles.
        const operation_id = next_dynamic_operation.fetchAdd(1, .monotonic);
        if (operation_id == 0 or operation_id == std.math.maxInt(u64)) return error.IdentityExhausted;
        const results = execute(host.context, .{ .dispatch_fence = self.dispatch_gate, .workspace_revision = self.request.workspace_revision, .table = table, .parsed = parsed, .turn_id = self.turn_id, .call_id = call.id, .arguments = call.arguments, .operation_id = operation_id }, self.allocator, cancel) catch |err| {
            // Policy and approval rejection happen before any dispatch. Other
            // failures are conservatively unknown and never automatically replay.
            const preflight = err == error.ScopeChanged or err == error.AssistantOwnerChanged or err == error.TargetOutsideAssistant or err == error.ToolCapabilityUnavailable or err == error.StaleBinding or err == error.RequiredServiceUnavailable or err == error.ServiceDenied or err == error.ToolApprovalRequired or err == error.ToolApprovalRejected or err == error.ToolApprovalExpired or err == error.ToolApprovalChanged or err == error.StaleToolAuthority or err == error.ToolExecutionDenied or err == error.CancelledBeforeDispatch or err == error.ToolOperationAlreadyRecorded or err == error.OperationHistoryFull or err == error.ModeConflict or err == error.ReconnectTargetChanged or err == error.ReconnectTargetUnavailable;
            if (!preflight) self.stopForUnknownDispatch();
            record.dispatched = !preflight;
            @import("tool_trace.zig").emit(.{ .event = "dynamic_rejected", .call_id = call.id, .tool_id = call.name, .owner = self.scope.owner, .reason = @errorName(err), .dispatched = !preflight });
            record.result_body = if (preflight) try self.errorBody(@errorName(err), &parsed.targets) else try self.unknownBody(@errorName(err), parsed.targets);
            return record.result_body.?;
        };
        record.generic_results = results;
        if (results.len != parsed.targets.len) {
            self.stopForUnknownDispatch();
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
                self.stopForUnknownDispatch();
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
            if (result.status == .outcome_unknown or result.receipt.remote_effect_unknown or !result.receipt.local_released) {
                const can_observe = result.managed_local_file or std.mem.eql(u8, parsed.entry.definition.id, "run_command");
                if (!self.uncertain) self.host_observation_only = can_observe;
                if (!can_observe) self.host_observation_only = false;
                self.uncertain = true;
            }
            target.* = .{ .session_id = id, .status = result.status, .content = blocks, .operation_id = result.receipt.operation_id, .local_released = result.receipt.local_released, .remote_effect_unknown = result.receipt.remote_effect_unknown };
        }
        const body = try std.json.Stringify.valueAlloc(a, .{ .targets = encoded }, .{ .emit_null_optional_fields = false });
        record.result_body = body;
        if (std.mem.eql(u8, parsed.entry.definition.id, "file.read_text")) {
            const has_managed = for (results) |result| {
                if (result.managed_local_file) break true;
            } else false;
            if (has_managed) {
                var located: file_references.ReceiptSpans = .{};
                for (results, encoded) |result, target| for (target.content) |block| {
                    if (block.text) |value| try located.observe(a, body, value, result.managed_local_file and result.status == .succeeded and std.mem.eql(u8, block.type, "structured"));
                };
                record.file_reference_spans = located.spans.items;
            }
        }
        return body;
    }
    var next_dynamic_operation: std.atomic.Value(u64) = .init(1);
    fn checkBudget(self: *Loop) !void {
        _ = self.discardRevokedResults();
        self.request.messages = self.messages.items;
        const budget = @import("local_text_request.zig");
        try budget.checkFixedContext(self.request, self.limits.context_window);
        if (@import("image_offload.zig").enabled(self.request)) {
            const omitted = try @import("image_offload.zig").apply(self.arena.allocator(), self.messages.items, self.request, self.limits.context_window, if (self.compaction_config) |config| config.kind else .openai_compat);
            if (omitted != 0) @import("tool_trace.zig").emit(.{ .event = "image_offload", .count = omitted, .turn_id = self.turn_id, .owner = self.scope.owner });
        }
        // Share the admission calculation with offload and submission; a
        // different output clamp/overhead must not reject a repaired request.
        const estimated = try budget.inputTokens(self.request);
        const output = budget.outputTokens(self.request.max_output, self.limits.context_window);
        if (self.compaction_failure != null) return error.ContextCompactionFailed;
        if (self.compaction_config != null and (self.pending_notice_start == null or estimated + output > self.limits.context_window)) {
            const compaction = @import("context_compaction.zig");
            if (compaction.reachesThreshold(estimated, output, self.limits.context_window) and compaction.cutoff(self.compactableMessages()) != null) {
                try self.compact(try budget.fixedTokens(self.request));
                return;
            }
        }
        if (estimated + output > self.limits.context_window) return error.ToolContextBudget;
    }

    /// Fail closed at wire preparation, including before context compaction
    /// can transmit tool results to its own provider.
    pub fn discardRevokedResults(self: *Loop) bool {
        var discarded = false;
        for (self.records.items) |*record| {
            const result = if (record.host_result) |*value| value else continue;
            const check = result.delivery_check orelse continue;
            check.verify(check.context) catch {
                discarded = true;
                for (self.messages.items) |*message| {
                    const call_id = message.tool_call_id orelse continue;
                    if (!std.mem.eql(u8, call_id, record.key.call_id)) continue;
                    for (message.images) |reference| {
                        var owned = reference;
                        owned.release();
                    }
                    for (message.offloaded_images) |image| {
                        var owned = image.reference;
                        owned.release();
                    }
                    message.content = revoked_result_body;
                    message.images = &.{};
                    message.offloaded_images = &.{};
                    message.image_owner = null;
                    message.image_transform = 0;
                    message.file_reference_spans = &.{};
                }
                record.result_body = revoked_result_body;
                record.file_reference_spans = &.{};
                result.deinit(self.allocator);
                record.host_result = null;
            };
        }
        return discarded;
    }
    /// Completed history can be compacted before admitting new user input.
    fn compact(self: *Loop, reserve: usize) !void {
        const budget = @import("local_text_request.zig");
        const output = if (self.pending_notice_start != null) budget.outputTokens(self.request.max_output, self.limits.context_window) else 0;
        var next = try self.generateCompaction(reserve +| output, self.request.cancel);
        defer next.deinit();
        const owned = try self.transcriptWithTail(next.messages, null);
        var next_request = self.request;
        next_request.messages = owned;
        budget.checkContext(next_request, self.limits.context_window) catch |err| {
            self.compaction_failure = err;
            return error.ContextCompactionFailed;
        };
        self.installCompaction(&next, owned);
    }
    fn compactableMessages(self: *const Loop) []const provider.Message {
        return self.messages.items[0 .. self.pending_notice_start orelse self.messages.items.len];
    }
    fn transcriptWithTail(self: *Loop, prefix: []const provider.Message, extra: ?provider.Message) ![]provider.Message {
        const tail = self.messages.items[self.compactableMessages().len..];
        const messages = try self.arena.allocator().alloc(provider.Message, prefix.len + tail.len + @intFromBool(extra != null));
        @memcpy(messages[0..prefix.len], prefix);
        @memcpy(messages[prefix.len..][0..tail.len], tail);
        if (extra) |message| messages[messages.len - 1] = message;
        return messages;
    }
    fn generateCompaction(self: *Loop, reserve: usize, cancel: ?*provider.CancelToken) !@import("wire_history.zig").History {
        while (true) {
            _ = self.discardRevokedResults();
            const prefix = self.compactableMessages();
            var tail = self.request;
            tail.messages = self.messages.items[prefix.len..];
            tail.system = "";
            tail.tools = &.{};
            const retained = try @import("local_text_request.zig").inputTokens(tail);
            return @import("context_compaction.zig").compactNowWithProvider(self.compaction_config.?, prefix, reserve +| retained, cancel, self.compaction_provider) catch |err| switch (err) {
                // A queued compaction request owns a detached transcript. Its
                // adapter redacted the live copy, so build a fresh snapshot.
                error.ToolResultRevoked => continue,
                error.ContextFixedOverhead => return err,
                else => {
                    self.compaction_failure = err;
                    return error.ContextCompactionFailed;
                },
            };
        }
    }
    fn installCompaction(self: *Loop, next: *@import("wire_history.zig").History, owned: []provider.Message) void {
        // Pending notices and following input already own their references.
        // Only the summarized prefix is replaced here.
        const previous = self.compactableMessages();
        for (previous) |message| for (message.images) |reference| {
            var ref = reference;
            ref.release();
        };
        for (previous) |message| for (message.offloaded_images) |image| {
            var ref = image.reference;
            ref.release();
        };
        self.compacted.deinit();
        self.compacted = next.*;
        next.* = .{};
        self.messages = .fromOwnedSlice(owned);
        if (self.pending_notice_start != null) self.pending_notice_start = self.compacted.messages.len;
        for (self.compacted.messages) |message| for (message.images) |reference| {
            _ = reference.retain();
        };
        for (self.compacted.messages) |message| {
            for (message.offloaded_images) |image| _ = image.reference.retain();
        }
        self.request.messages = self.messages.items;
    }
    fn errorBody(self: *Loop, code: []const u8, targets: ?*const scope_mod.Targets) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.arena.allocator(), .{ .status = Status.rejected, .error_code = code, .session_ids = if (targets) |ids| ids.slice() else &.{} }, .{});
    }
    fn unknownBody(self: *Loop, code: []const u8, targets: scope_mod.Targets) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.arena.allocator(), .{ .status = Status.unknown, .error_code = code, .session_ids = targets.slice() }, .{});
    }
    fn outcomeBody(self: *Loop, outcome: Outcome) ![]const u8 {
        const Encoded = struct { session_id: u64, status: Status, transport: Transport, stdout: []const u8, stderr: []const u8, stdout_encoding: []const u8, stderr_encoding: []const u8, exit: ?i32, signal: ?u8, cwd: ?[]const u8, elapsed_ms: u64, truncated: bool, output_ref: ?[]const u8, next_output_cursor: ?usize, retained_truncated: bool, local_released: bool, remote_effect_unknown: bool, error_code: ?[]const u8 };
        const a = self.arena.allocator();
        const encoded = try a.alloc(Encoded, outcome.targets.len);
        for (outcome.targets, encoded) |target, *value| {
            const stdout_utf8 = std.unicode.utf8ValidateSlice(target.stdout);
            const stderr_utf8 = std.unicode.utf8ValidateSlice(target.stderr);
            value.* = .{ .session_id = target.session_id, .status = target.status, .transport = target.transport, .stdout = if (stdout_utf8) target.stdout else try base64(a, target.stdout), .stderr = if (stderr_utf8) target.stderr else try base64(a, target.stderr), .stdout_encoding = if (stdout_utf8) "utf-8" else "base64", .stderr_encoding = if (stderr_utf8) "utf-8" else "base64", .exit = target.exit, .signal = target.signal, .cwd = target.cwd, .elapsed_ms = target.elapsed_ms, .truncated = target.truncated, .output_ref = target.output_ref, .next_output_cursor = target.next_output_cursor, .retained_truncated = target.retained_truncated, .local_released = target.local_released, .remote_effect_unknown = target.remote_effect_unknown, .error_code = target.error_code };
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
            .run_command => std.mem.eql(u8, key, "command") or std.mem.eql(u8, key, "timeout_ms"),
            .read_terminal => false,
            .list_remote_files => std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "offset") or std.mem.eql(u8, key, "source_version") or std.mem.eql(u8, key, "max_entries"),
            .read_remote_file => std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "max_bytes") or std.mem.eql(u8, key, "offset") or std.mem.eql(u8, key, "source_version"),
        };
        if (!allowed) return error.InvalidToolArguments;
        if (std.mem.eql(u8, key, "timeout_ms")) {
            const timeout = field.value_ptr.*;
            if (timeout != .integer or timeout.integer <= 0 or timeout.integer > std.math.maxInt(u32)) return error.InvalidToolArguments;
        }
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
