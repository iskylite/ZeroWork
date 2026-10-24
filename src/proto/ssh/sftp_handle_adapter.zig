const SftpHandle = @import("session.zig").SftpHandle;
const Io = @import("sftp_pipeline.zig").Io;
const Chunk = @import("transfer_window.zig").Chunk;

pub const Adapter = struct {
    handle: *SftpHandle,

    pub fn io(self: *Adapter) Io {
        return .{ .ctx = self, .read_chunk = read, .write_chunk = write };
    }

    fn read(ctx: *anyopaque, _: Chunk, bytes: []u8) !usize {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        return self.handle.read(bytes);
    }

    fn write(ctx: *anyopaque, _: Chunk, bytes: []const u8) !void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = try self.handle.write(bytes[offset..]);
            if (count == 0) return error.SftpWriteStalled;
            offset += count;
        }
    }
};
