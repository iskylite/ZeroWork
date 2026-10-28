//! Native allocation + owned loopback proof for SSH release receipts.
//! The fixture accepts exec packets but never starts a process.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const c = @import("generated_ssh_session");
const realtime = @import("platform/realtime.zig");

const Native = struct {
    extern "c" fn libssh2_session_method_pref(*c.LIBSSH2_SESSION, c_int, [*:0]const u8) c_int;
    extern "c" fn libssh2_session_init_ex(
        *const fn (usize, *?*anyopaque) callconv(.c) ?*anyopaque,
        *const fn (?*anyopaque, *?*anyopaque) callconv(.c) void,
        *const fn (?*anyopaque, usize, *?*anyopaque) callconv(.c) ?*anyopaque,
        ?*anyopaque,
    ) ?*c.LIBSSH2_SESSION;
};

const Tracker = struct {
    const Allocation = struct { pointer: ?*anyopaque = null, size: usize = 0, caller: usize = 0 };
    active: usize = 0,
    allocations: usize = 0,
    session: ?*anyopaque = null,
    child: ?*anyopaque = null,
    session_freed: bool = false,
    child_freed: bool = false,
    live: [1024]Allocation = @splat(.{}),

    fn get(abstract: *?*anyopaque) *Tracker {
        return @ptrCast(@alignCast(abstract.*.?));
    }
    fn alloc(size: usize, abstract: *?*anyopaque) callconv(.c) ?*anyopaque {
        const result = std.c.malloc(size) orelse return null;
        const self = get(abstract);
        self.active += 1;
        self.allocations += 1;
        for (&self.live) |*slot| if (slot.pointer == null) {
            slot.* = .{ .pointer = result, .size = size, .caller = @returnAddress() };
            return result;
        };
        @panic("native fixture allocation tracker exhausted");
    }
    fn free(pointer: ?*anyopaque, abstract: *?*anyopaque) callconv(.c) void {
        if (pointer == null) return;
        const self = get(abstract);
        std.debug.assert(self.active != 0);
        self.active -= 1;
        if (pointer == self.session) self.session_freed = true;
        if (pointer == self.child) self.child_freed = true;
        var found = false;
        for (&self.live) |*slot| if (slot.pointer == pointer) {
            slot.pointer = null;
            found = true;
            break;
        };
        std.debug.assert(found);
        std.c.free(pointer);
    }
    fn realloc(pointer: ?*anyopaque, size: usize, abstract: *?*anyopaque) callconv(.c) ?*anyopaque {
        if (size == 0) {
            free(pointer, abstract);
            return null;
        }
        const result = std.c.realloc(pointer, size) orelse return null;
        if (pointer == null) {
            const self = get(abstract);
            self.active += 1;
            self.allocations += 1;
            for (&self.live) |*slot| if (slot.pointer == null) {
                slot.* = .{ .pointer = result, .size = size, .caller = @returnAddress() };
                return result;
            };
            @panic("native fixture allocation tracker exhausted");
        } else {
            const self = get(abstract);
            for (&self.live) |*slot| if (slot.pointer == pointer) {
                slot.pointer = result;
                slot.size = size;
                return result;
            };
            @panic("native fixture realloc of untracked allocation");
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const mode = args.next() orelse return error.MissingMode;
    var library = try ssh.Library.init();
    defer library.deinit();
    const fd = c.zw_ssh_socket_connect("127.0.0.1", port, 1000);
    if (fd < 0) return error.ConnectFailed;
    var tracker: Tracker = .{};
    var ledger = try ssh.ResourceLedger.init(null, 1);
    var session: ssh.Session = .{ .state = .connecting, .socket_fd = fd, .resource_ledger = &ledger };
    defer session.close();
    session.recordResource(.transport, .owned);
    session.handle = Native.libssh2_session_init_ex(Tracker.alloc, Tracker.free, Tracker.realloc, &tracker) orelse return error.SessionCreateFailed;
    tracker.session = session.handle;
    session.recordResource(.session, .owned);
    // The existing mbedTLS ECDH backend allocates its private-key struct via
    // LIBSSH2_ALLOC but frees it directly via mbedtls_free, bypassing this
    // observation callback. Group14 keeps this targeted allocation count exact
    // without changing production crypto or pretending to cover every KEX.
    if (Native.libssh2_session_method_pref(session.handle.?, 0, "diffie-hellman-group14-sha256") != 0) return error.KexPreferenceFailed;
    c.zw_libssh2_session_set_timeout(session.handle.?, 1000);
    if (c.zw_ssh_socket_set_nonblocking(fd) != 0) return error.NonblockingFailed;
    c.zw_libssh2_session_nonblocking(session.handle.?);
    const drive: c.ZW_SSH_DRIVE = .{ .socket_fd = fd, .timeout_ms = 1000, .deadline_ms = null, .cancelled = null, .ctx = null };
    if (c.zw_libssh2_session_handshake_driven(session.handle.?, &drive) != 0) return error.HandshakeFailed;
    if (c.zw_libssh2_auth_password_driven(session.handle.?, "fixture", "fixture-password", &drive) != 0) return error.AuthFailed;
    session.state = .active;
    session.setBlocking();
    var child = try session.openExec("fixture-no-process-first");
    tracker.child = @ptrCast(child.handle);
    c.zw_libssh2_session_nonblocking(session.handle.?);
    const started = realtime.monotonicNs();
    if (std.mem.eql(u8, mode, "child-isolation")) {
        // The server intentionally withholds CHANNEL_CLOSE acknowledgement.
        if (session.closeChannelReceipt(&child) != .awaiting) return error.ExpectedActualEagain;
        if (tracker.child_freed or tracker.session_freed) return error.AwaitingOwnerWasFreed;
        if (session.state != .active or std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)) < 0) return error.SharedSessionWasInterrupted;
        // This real second channel request has to cross the same transport
        // after the first close. The fixture counts both exec acknowledgements.
        session.setBlocking();
        _ = try session.openExec("fixture-no-process-second");
        if (tracker.session_freed) return error.SharedSessionWasFreed;
    } else if (std.mem.eql(u8, mode, "native-awaiting")) {
        if (c.zw_libssh2_session_release(session.handle.?) != 1) return error.ExpectedActualSessionEagain;
        if (tracker.session_freed or tracker.child_freed) return error.AwaitingOwnerWasFreed;
    } else return error.UnknownMode;
    if (session.closeReceipt() != .released) return error.FinalReleaseDidNotComplete;
    if (!tracker.session_freed or !tracker.child_freed or tracker.active != 0) {
        std.debug.print("native release diagnostics: live={d} session_freed={any} child_freed={any}\n", .{ tracker.active, tracker.session_freed, tracker.child_freed });
        for (tracker.live) |slot| if (slot.pointer != null) {
            std.debug.print("remaining native allocation bytes={d}\n", .{slot.size});
            var addresses = [_]usize{slot.caller};
            std.debug.dumpStackTrace(&.{ .return_addresses = &addresses, .skipped = .none });
        };
        return error.NativeAllocationNotFreed;
    }
    if (session.handle != null or session.socket_fd != -1 or session.state != .closed) return error.OwnerNotClearedAfterRelease;
    if (std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)) != -1 or std.c._errno().* != @as(c_int, @backingInt(std.c.E.BADF))) return error.OwnedFdNotClosed;
    if (session.closeReceipt() != .released or tracker.active != 0) return error.ReleaseWasNotIdempotent;
    const snapshot = ledger.snapshot();
    if (!snapshot.released() or snapshot.entry(0, .session).released_sequence >= snapshot.entry(0, .transport).released_sequence) return error.ReleaseLedgerOrderInvalid;
    std.debug.print("PASS mode={s} native_allocations={d} native_live=0 child_freed=true session_freed=true fd_closed=true ledger_released=true elapsed_ms={d}\n", .{ mode, tracker.allocations, @divTrunc(realtime.monotonicNs() - started, std.time.ns_per_ms) });
}
