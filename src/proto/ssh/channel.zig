const worker_io = @import("../../vt/worker_io.zig");
const std = @import("std");
const channel_pump = @import("../../vt/channel_pump.zig");
const c = @import("generated_ssh_channel");

pub const Channel = struct {
    handle: *c.LIBSSH2_CHANNEL,
    pub fn reader(self: *Channel) worker_io.ChannelReader {
        return .{ .ctx = self, .read_fn = read };
    }
    pub fn writer(self: *Channel) channel_pump.ChannelWriter {
        return .{ .ctx = self, .write_fn = write };
    }
    pub fn resize(self: *Channel, cols: u16, rows: u16) !void {
        if (c.zw_libssh2_channel_resize(self.handle, cols, rows) != 0) return error.ResizeFailed;
    }
    fn read(ctx: *anyopaque, buffer: []u8) !worker_io.Read {
        const self: *Channel = @ptrCast(@alignCast(ctx));
        const count = c.zw_libssh2_channel_read(self.handle, buffer.ptr, buffer.len);
        // LIBSSH2_ERROR_EAGAIN: the nonblocking session has no fully-decrypted
        // packet ready right now. It is flow, not EOF — the tagged result
        // lets the kqueue loop wait for the next
        // readable event instead of tearing the connection down. Returning an
        // error here turned every drained read (and each Enter's echo burst)
        // into a reconnect: the "terminal freezes under dmesg" regression.
        if (count == libssh2_eagain) return .would_block;
        if (count < 0) return error.ChannelReadFailed;
        if (count == 0) return if (c.zw_libssh2_channel_eof(self.handle) != 0) .eof else .would_block;
        return .{ .bytes = @intCast(count) };
    }
    fn write(ctx: *anyopaque, bytes: []const u8) !usize {
        const self: *Channel = @ptrCast(@alignCast(ctx));
        const count = c.zw_libssh2_channel_write(self.handle, bytes.ptr, bytes.len);
        // Same EAGAIN contract: 0 = would block, the input queue keeps the
        // bytes and the pump retries on the next writable event.
        if (count == libssh2_eagain) return 0;
        if (count < 0) return error.ChannelWriteFailed;
        return @intCast(count);
    }
};

/// LIBSSH2_ERROR_EAGAIN (public libssh2 contract, libssh2.h) — not exposed
/// through the shim headers, so pinned here with its documented value.
const libssh2_eagain: c_long = -37;
