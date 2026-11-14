//! Complete captured-text prompt assembly; source bytes are never truncated.
const std = @import("std");
const attachments = @import("local_text_attachments.zig");
const provider = @import("provider.zig");
const references = @import("../host/local_file_reference.zig");
/// The provider receives the full reference. Transcript readers show only
/// prompt text when a model message contains the generated reference suffix.
pub fn displayPrompt(wire: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, wire, "\n\n<local_file_reference>\nsource_kind=host_local\nsource_name=本机\nlocator=") orelse return wire;
    const suffix = wire[start..];
    if (!std.mem.endsWith(u8, suffix, "</local_file_reference>") and
        std.mem.indexOf(u8, suffix, "</local_file_reference>\n\n<") == null) return wire;
    if (std.mem.indexOf(u8, suffix, "\nreference_only=true\ncontent_included=false\n") == null) return wire;
    return wire[0..start];
}

test "local binary references stay out of displayed prompts" {
    const wire = "检查这个压缩包\n\n<local_file_reference>\nsource_kind=host_local\nsource_name=本机\nlocator={}\nreference_only=true\ncontent_included=false\nreason=binary\n</local_file_reference>";
    try std.testing.expectEqualStrings("检查这个压缩包", displayPrompt(wire));
    try std.testing.expectEqualStrings("literal <local_file_reference>", displayPrompt("literal <local_file_reference>"));
}

pub fn compose(allocator: std.mem.Allocator, prompt: []const u8, bundle: *const attachments.Bundle, max_bytes: usize) ![]u8 {
    return composeWithFileReferences(allocator, prompt, bundle, max_bytes, null);
}

pub const Projected = struct {
    wire: []u8,
    file_reference_spans: []const references.Span,

    pub fn deinit(self: Projected, allocator: std.mem.Allocator) void {
        allocator.free(self.wire);
        allocator.free(self.file_reference_spans);
    }
};

pub fn composeWithFileReferences(allocator: std.mem.Allocator, prompt: []const u8, bundle: *const attachments.Bundle, max_bytes: usize, key: ?references.Key) ![]u8 {
    const projected = try composeProjected(allocator, prompt, bundle, max_bytes, key);
    allocator.free(projected.file_reference_spans);
    return projected.wire;
}
pub fn composeProjected(allocator: std.mem.Allocator, prompt: []const u8, bundle: *const attachments.Bundle, max_bytes: usize, key: ?references.Key) !Projected {
    var size = prompt.len;
    const headers = try allocator.alloc([]u8, bundle.items.len);
    var header_count: usize = 0;
    defer {
        for (headers[0..header_count]) |header| allocator.free(header);
        allocator.free(headers);
    }
    var spans: std.ArrayList(references.Span) = .empty;
    defer spans.deinit(allocator);
    for (bundle.items, headers) |item, *header| {
        const content = item.reference.content() orelse return error.EmptyAttachmentResult;
        const ref = if (bundle.conversation_id) |conversation| content.fileReference(conversation) else null;
        const token = if (key != null and ref != null) try references.seal(allocator, key.?, ref.?) else null;
        defer if (token) |value| allocator.free(value);
        header.* = try attachmentHeader(allocator, content, token);
        header_count += 1;
        if (token) |value| {
            const offset = std.mem.lastIndexOf(u8, header.*, value).?;
            const start = std.math.cast(u32, size +| offset) orelse return error.RequestTooLarge;
            try spans.append(allocator, .{ .start = start, .len = @intCast(value.len) });
        }
        size = std.math.add(usize, size, header.len + attachmentEnd(content).len) catch return error.RequestTooLarge;
        size = std.math.add(usize, size, content.bytes.len) catch return error.RequestTooLarge;
        if (size > max_bytes) return error.RequestTooLarge;
    }
    if (size > max_bytes) return error.RequestTooLarge;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try writer.writeAll(prompt);
    for (bundle.items, headers) |item, header| {
        const content = item.reference.content().?;
        try writer.writeAll(header);
        try writer.writeAll(content.bytes);
        try writer.writeAll(attachmentEnd(content));
    }
    try references.validateSpans(bytes, spans.items);
    return .{ .wire = bytes, .file_reference_spans = try spans.toOwnedSlice(allocator) };
}

fn attachmentHeader(allocator: std.mem.Allocator, content: attachments.Content, token: ?[]const u8) ![]u8 {
    return switch (content.source) {
        .local_file => localTextHeader(allocator, content, token),
        .local_reference => localReferenceHeader(allocator, content, token),
        .remote_file => |source| if (source.reference_only)
            std.fmt.allocPrint(allocator, "\n\n<remote_file_reference>\nsource_session={d}\nsource_generation={d}\nsource_name={s}\npath={s}\nFile contents are not included. If needed, read with an available file tool for this source session. This is a remote path, not a local file.\n", .{ @backingInt(source.owner.session_id), source.owner.generation, source.source_name, content.path })
        else
            std.fmt.allocPrint(allocator, "\n\n<remote_file_attachment>\nsource_session={d}\nsource_generation={d}\nsource_name={s}\nsource_revision={d}\noperation={d}\nrequested_path={s}\nactual_path={s}\ncaptured_at_ms={d}\noriginal_size={?d}\nread_bytes={d}\nreturned_bytes={d}\nread_limit={d}\ntruncated={}\nencoding=utf8\ntext:\n", .{ @backingInt(source.owner.session_id), source.owner.generation, source.source_name, source.source_revision, (source.operation orelse return error.InvalidRemoteSource).operation_id, content.path, source.actual_path orelse content.path, content.captured_at_ms, source.original_size, source.read_bytes, content.bytes.len, source.read_limit, source.truncated }),
        .terminal => |source| switch (source.origin) {
            .selection => |selected| std.fmt.allocPrint(allocator, "\n\n<terminal_selection_attachment>\nsource_session={d}\nsource_generation={d}\nsource_name={s}\ncaptured_at_ms={d}\nselected_rows={d}\nsource_version={d}\nrectangle={}\ntext:\n", .{ @backingInt(source.owner.session_id), source.owner.generation, source.source_name, content.captured_at_ms, source.line_count, selected.source_version, selected.selection.rectangle }),
            .command => |command| std.fmt.allocPrint(allocator, "\n\n<terminal_command_context>\nsource_session={d}\nsource_generation={d}\nsource_name={s}\ncaptured_at_ms={d}\ncontext_rows={d}\ncommand_id={d}\ncommand_end={d}\nexit_code={d}\ncommand={s}\ntext:\n", .{ @backingInt(source.owner.session_id), source.owner.generation, source.source_name, content.captured_at_ms, source.line_count, command.command_id, command.end_sequence, command.exit_code, command.command }),
        },
    };
}
fn localFileLocator(allocator: std.mem.Allocator, content: attachments.Content, token: ?[]const u8) ![]u8 {
    const absolute = if (content.pinned_local) |pin| pin.absolute else if (std.fs.path.isAbsolute(content.path)) content.path else null;
    return std.json.Stringify.valueAlloc(allocator, .{ .selected_path = content.path, .absolute_path = absolute, .file_ref = token }, .{ .emit_null_optional_fields = false });
}
fn localTextHeader(allocator: std.mem.Allocator, content: attachments.Content, token: ?[]const u8) ![]u8 {
    const locator = try localFileLocator(allocator, content, token);
    defer allocator.free(locator);
    return std.fmt.allocPrint(allocator, "\n\n<local_text_attachment>\nlocator={s}\ntext:\n", .{locator});
}
fn localReferenceHeader(allocator: std.mem.Allocator, content: attachments.Content, token: ?[]const u8) ![]u8 {
    const reference = content.source.local_reference;
    const image_limits = @import("image_attachments.zig").Limits{};
    const byte_limit: ?usize = switch (reference.reason) {
        .text_limit => attachments.max_bytes,
        .size_limit, .image_limit => image_limits.bytes,
        else => null,
    };
    const locator = try localFileLocator(allocator, content, token);
    defer allocator.free(locator);
    return std.fmt.allocPrint(allocator, "\n\n<local_file_reference>\nsource_kind=host_local\nsource_name=本机\nlocator={s}\nreference_only=true\ncontent_included=false\nreason={s}\nfile_size_bytes={?d}\ncontent_limit_bytes={?d}\nimage_max_dimension={?d}\nimage_max_pixels={?d}\nsuggested_max_read_bytes=4096\nFile contents are not included. The reason and limits above explain why only a path was attached. Do not automatically read, load, upload or decode the entire file. If the user's task requires inspection, first inspect metadata and use bounded reads of at most 4096 bytes per call; do not automatically paginate through the entire file. Use an authorized tool explicitly targeting this host's local filesystem. Never pass this path to SSH, SFTP or another remote session's file tools. If no host-local tool is available, explain that you cannot read this file; do not substitute a remote path.\n", .{
        locator,                                                                             @tagName(reference.reason),                                                       reference.size_bytes, byte_limit,
        if (reference.reason == .image_limit) @as(?usize, image_limits.dimension) else null, if (reference.reason == .image_limit) @as(?usize, image_limits.pixels) else null,
    });
}
fn attachmentEnd(content: attachments.Content) []const u8 {
    return switch (content.source) {
        .local_file => "\n</local_text_attachment>",
        .local_reference => "</local_file_reference>",
        .remote_file => |source| if (source.reference_only) "</remote_file_reference>" else "\n</remote_file_attachment>",
        .terminal => |source| switch (source.origin) {
            .selection => "\n</terminal_selection_attachment>",
            .command => "\n</terminal_command_context>",
        },
    };
}

/// The documented bytes/4 estimate, not provider-reported actual usage.
/// Includes message framing, tool arguments/results/IDs and declared schemas.
pub fn textTokens(bytes: usize) usize {
    return (bytes +| 3) / 4;
}
pub fn toolTokens(definitions: []const provider.ToolDefinition) !usize {
    return textTokens(try @import("provider_http.zig").toolCatalogBytes(definitions));
}
pub fn fixedTokens(request: provider.ChatRequest) !usize {
    return std.math.add(usize, textTokens(request.system.len), try toolTokens(request.tools)) catch error.RequestTooLarge;
}
pub fn draftTokens(text: []const u8) usize {
    return if (text.len == 0) 0 else textTokens(text.len +| 32);
}
pub fn outputTokens(max_output: u32, window: u32) u32 {
    const planned = @max(window / 4, 1);
    return if (max_output == 0) 0 else @min(max_output, planned);
}
/// A summary cannot reduce system/tool definitions or other reserved input.
pub fn checkFixedBudget(reserve: usize, output: usize, window: u32) !void {
    if (window == 0) return error.InvalidContextWindow;
    if (reserve > window or output > window - reserve) return error.ContextFixedOverhead;
}
pub fn checkFixedContext(request: provider.ChatRequest, window: u32) !void {
    try checkFixedBudget(try fixedTokens(request), outputTokens(request.max_output, window), window);
}
pub fn inputTokens(request: provider.ChatRequest) !usize {
    var bytes: usize = 0;
    for (request.messages) |message| {
        bytes = std.math.add(usize, bytes, message.content.len) catch return error.RequestTooLarge;
        bytes = std.math.add(usize, bytes, 32) catch return error.RequestTooLarge;
        if (message.tool_call_id) |id| bytes = std.math.add(usize, bytes, id.len) catch return error.RequestTooLarge;
        for (message.tool_calls) |call| {
            bytes = std.math.add(usize, bytes, call.id.len + call.name.len + call.arguments.len + 64) catch return error.RequestTooLarge;
        }
    }
    const image_tokens = try @import("image_budget.zig").validate(request);
    const text_tokens = std.math.add(usize, textTokens(bytes), try fixedTokens(request)) catch return error.RequestTooLarge;
    return std.math.add(usize, text_tokens, image_tokens) catch error.RequestTooLarge;
}
pub fn checkContext(request: provider.ChatRequest, window: u32) !void {
    try checkFixedContext(request, window);
    const input = try inputTokens(request);
    // Match the actual serializer's reserved output clamp.
    const output = outputTokens(request.max_output, window);
    if (input > window or output > window - input) return error.ContextBudgetExceeded;
}
