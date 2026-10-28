//! The Local provider alone owns its concrete PTY/process adapter.
const std = @import("std");
const service = @import("../../host/process_service.zig");
const adapter = @import("../../local/adapter.zig");
pub fn create(allocator: std.mem.Allocator) !*service.Service {
    const engine = try adapter.LocalAdapter.init(std.heap.c_allocator, .{ .retain_raw_output = false });
    errdefer engine.deinit() catch {};
    return service.Service.bind(allocator, engine);
}

pub const validateQuick = @import("config.zig").validate;

pub const newSessionPayload = @import("config.zig").newSessionPayload;

pub const encodeCreationPayload = @import("config.zig").encodeCreationPayload;
