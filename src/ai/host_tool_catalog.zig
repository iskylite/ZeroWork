//! Maximum catalog is derived from the actual contributions, including group
//! lifecycle tools and optional extensions. Runtime filtering only narrows it.
const host = @import("host_tools.zig");
pub const all = [_]host.Contribution{@import("user_interaction.zig").contribution} ++
    @import("host_queries.zig").contributions ++
    @import("host_local_files.zig").contributions ++
    @import("host_local_file_mutation.zig").contributions ++
    [_]host.Contribution{@import("local_file_change_query.zig").contribution} ++
    @import("host_catalog.zig").contributions ++
    @import("host_transfer.zig").contributions ++
    [_]host.Contribution{@import("child_gateway.zig").contribution} ++
    @import("extension_gateway.zig").contributions ++
    [_]host.Contribution{@import("builtin_tools.zig").contribution} ++
    @import("host_queries.zig").terminal_contributions ++
    @import("fetch_url.zig").contributions ++
    [_]host.Contribution{@import("batch_output.zig").contribution} ++
    @import("host_execution.zig").contributions ++
    @import("host_lifecycle.zig").contributions;
pub const Buffer = [all.len]host.Contribution;

test "AI group host catalog fits every contribution and builds a valid request table" {
    const std = @import("std");
    const tools = @import("plugin_tools.zig");
    const buffer: Buffer = all;
    var table = try tools.RequestTable.initWithHost(std.testing.allocator, .{ .owner = .{ .group = 7 }, .members = .{} }, &.{}, &.{}, .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .group = 7 }, .binding_revision = 2, .grant_revision = 1 }, &buffer);
    defer table.deinit();
    try std.testing.expect(table.lookup("host__run_uin_uterminal") != null);
    try std.testing.expect(table.lookup("host__close_usession") != null);
    try std.testing.expect(table.lookup("host__get_ucurrent_ucontext") != null);
    try std.testing.expect(table.lookup("host__upload_ufile") != null);
    try std.testing.expect(table.lookup("host__download_ufile") != null);
    try std.testing.expect(table.lookup("host__get_utransfer") != null);
    try std.testing.expect(table.lookup("host__wait_utransfer") != null);
    try std.testing.expect(table.lookup("host__cancel_utransfer") != null);
    try std.testing.expectEqual(buffer.len, table.entries.len);
}
