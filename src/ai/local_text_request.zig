//! Complete captured-text prompt assembly; source bytes are never truncated.
const std = @import("std");
const attachments = @import("local_text_attachments.zig");
const provider = @import("provider.zig");
pub fn compose(allocator: std.mem.Allocator, prompt: []const u8, bundle: *const attachments.Bundle, max_bytes: usize) ![]u8 {
    var size = prompt.len;
    const headers = try allocator.alloc([]u8, bundle.items.len);
    var header_count: usize = 0;
    defer {
        for (headers[0..header_count]) |header| allocator.free(header);
        allocator.free(headers);
    }
    for (bundle.items, headers) |item, *header| {
        const content = item.reference.content() orelse return error.EmptyAttachmentResult;
        header.* = try attachmentHeader(allocator, content);
        header_count += 1;
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
    return bytes;
}

fn attachmentHeader(allocator: std.mem.Allocator, content: attachments.Content) ![]u8 {
    return switch (content.source) {
        .local_file => std.fmt.allocPrint(allocator, "\n\n<local_text_attachment path=\"{s}\">\n", .{content.path}),
        .remote_file => |source| std.fmt.allocPrint(allocator, "\n\n<remote_file_attachment>\nsource_session={d}\nsource_generation={d}\nsource_name={s}\nsource_revision={d}\noperation={d}\nrequested_path={s}\nactual_path={s}\ncaptured_at_ms={d}\noriginal_size={?d}\nread_bytes={d}\nreturned_bytes={d}\nread_limit={d}\ntruncated={}\nencoding=utf8\ntext:\n", .{ @backingInt(source.owner.session_id), source.owner.generation, source.source_name, source.source_revision, source.operation.operation_id, content.path, source.actual_path orelse content.path, content.captured_at_ms, source.original_size, source.read_bytes, content.bytes.len, source.read_limit, source.truncated }),
        .terminal => |source| switch (source.origin) {
            .selection => |selected| std.fmt.allocPrint(allocator, "\n\n<terminal_selection_attachment>\nsource_session={d}\nsource_generation={d}\nsource_name={s}\ncaptured_at_ms={d}\nselected_rows={d}\nsource_version={d}\nrectangle={}\ntext:\n", .{ @backingInt(source.owner.session_id), source.owner.generation, source.source_name, content.captured_at_ms, source.line_count, selected.source_version, selected.selection.rectangle }),
            .command => |command| std.fmt.allocPrint(allocator, "\n\n<terminal_command_context>\nsource_session={d}\nsource_generation={d}\nsource_name={s}\ncaptured_at_ms={d}\ncontext_rows={d}\ncommand_id={d}\ncommand_end={d}\nexit_code={d}\ncommand={s}\ntext:\n", .{ @backingInt(source.owner.session_id), source.owner.generation, source.source_name, content.captured_at_ms, source.line_count, command.command_id, command.end_sequence, command.exit_code, command.command }),
        },
    };
}
fn attachmentEnd(content: attachments.Content) []const u8 {
    return switch (content.source) {
        .local_file => "\n</local_text_attachment>",
        .remote_file => "\n</remote_file_attachment>",
        .terminal => |source| switch (source.origin) {
            .selection => "\n</terminal_selection_attachment>",
            .command => "\n</terminal_command_context>",
        },
    };
}

/// The documented bytes/4 estimate, not provider-reported actual usage.
/// Includes message framing, tool arguments/results/IDs and declared schemas.
pub fn inputTokens(request: provider.ChatRequest) !usize {
    var bytes = request.system.len;
    for (request.messages) |message| {
        bytes = std.math.add(usize, bytes, message.content.len) catch return error.RequestTooLarge;
        bytes = std.math.add(usize, bytes, 32) catch return error.RequestTooLarge;
        if (message.tool_call_id) |id| bytes = std.math.add(usize, bytes, id.len) catch return error.RequestTooLarge;
        for (message.tool_calls) |call| {
            bytes = std.math.add(usize, bytes, call.id.len + call.name.len + call.arguments.len + 64) catch return error.RequestTooLarge;
        }
    }
    const image_tokens = try @import("image_budget.zig").validate(request);
    return std.math.add(usize, (bytes +| 3) / 4 + request.tools.len * 256, image_tokens) catch error.RequestTooLarge;
}
pub fn checkContext(request: provider.ChatRequest, window: u32) !void {
    if (window == 0) return error.InvalidContextWindow;
    const input = try inputTokens(request);
    // Match the actual serializer's reserved output clamp.
    const output = @min(request.max_output, @max(window / 4, 1));
    if (input > window or output > window - input) return error.ContextBudgetExceeded;
}
