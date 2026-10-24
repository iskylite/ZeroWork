const std = @import("std");
const remote = @import("host/ai_remote_file_snapshot.zig");

test "remote snapshot controller public API compiles without a UI or native window" {
    std.testing.refAllDecls(remote.Reader);
    std.testing.refAllDecls(remote.ResultRef);
}

test "remote paths preserve raw absolute data and never infer a local or root path" {
    try remote.validatePath("/var/log/file with 'quotes' $() & spaces");
    try std.testing.expectError(error.InvalidRemotePath, remote.validatePath("logs/worker"));
    try std.testing.expectError(error.InvalidRemotePath, remote.validatePath(""));
    try std.testing.expectError(error.InvalidRemotePath, remote.validatePath("/var/log\x00ignored"));
    var long_path: [4097]u8 = @splat('a');
    long_path[0] = '/';
    try std.testing.expectError(error.RemotePathTooLong, remote.validatePath(&long_path));
    try std.testing.expectEqual(@as(u32, 4096), remote.default_read_bytes);
    try std.testing.expectEqual(@as(u32, 65536), remote.max_read_bytes);
}

test "native remote picker public methods compile against installed zenit" {
    std.testing.refAllDecls(@import("ui/ai_remote_picker.zig").View);
    std.testing.refAllDecls(@import("ui/ai_attachments_view.zig").View);
    std.testing.refAllDecls(@import("ai/local_text_attachments.zig").ContentRef);
}
