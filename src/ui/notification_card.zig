//! One compact summary contract for every notification source and surface.
const std = @import("std");
const Event = @import("../host/notification_coordinator.zig").NotificationEvent;
pub fn extraDetail(event: Event) []const u8 {
    const detail = std.mem.trim(u8, event.detail, " \t\r\n");
    for ([_][]const u8{ event.title, event.owner_name, event.object_name }) |value| {
        if (std.mem.eql(u8, detail, std.mem.trim(u8, value, " \t\r\n"))) return "";
    }
    return detail;
}
pub fn summary(allocator: std.mem.Allocator, event: Event, ended: bool) ![]u8 {
    const detail = extraDetail(event);
    const first_line = std.mem.trim(u8, detail[0 .. std.mem.indexOfScalar(u8, detail, '\n') orelse detail.len], " \t\r");
    const preview = if (event.object_name.len > 0 and !std.mem.eql(u8, event.object_name, event.owner_name)) event.object_name else first_line;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ event.owner_name, if (event.owner_name.len > 0 and (preview.len > 0 or ended)) " · " else "", if (ended) "会话已结束" else preview, if (ended and preview.len > 0) " · 详情已保留" else "" });
}
